import XCTest
@testable import Player

@MainActor
final class BookmarkTests: XCTestCase {
  func testOneTapBookmarkCapturesExactBookAssetAndChapterPosition() throws {
    let book = makeBook()
    let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
    let bookmark = try BookmarkPlanner.makeBookmark(
      id: uuid(1),
      book: book,
      positionSeconds: 59.999,
      note: "  Remember the signal  ",
      createdAt: createdAt
    )

    XCTAssertEqual(bookmark.bookPositionMilliseconds, 59_999)
    XCTAssertEqual(bookmark.assetID, uuid(101))
    XCTAssertEqual(bookmark.assetPositionMilliseconds, 59_999)
    XCTAssertEqual(bookmark.chapterID, "opening")
    XCTAssertEqual(bookmark.chapterTitleSnapshot, "Opening Signal")
    XCTAssertEqual(bookmark.label, "Opening Signal · 0:59")
    XCTAssertEqual(bookmark.note, "Remember the signal")
    XCTAssertEqual(bookmark.createdAt, createdAt)
    XCTAssertEqual(bookmark.updatedAt, createdAt)
  }

  func testExactMultiAssetBoundaryMapsToFollowingAssetAndChapter() throws {
    let bookmark = try BookmarkPlanner.makeBookmark(
      id: uuid(1),
      book: makeBook(),
      positionSeconds: 60,
      createdAt: .distantPast
    )

    XCTAssertEqual(bookmark.bookPositionMilliseconds, 60_000)
    XCTAssertEqual(bookmark.assetID, uuid(102))
    XCTAssertEqual(bookmark.assetPositionMilliseconds, 0)
    XCTAssertEqual(bookmark.chapterID, "crossing")
    XCTAssertEqual(bookmark.label, "The Crossing · 1:00")
  }

  func testGeneratedLabelsAreDeterministicAndHoursDoNotWrap() {
    XCTAssertEqual(
      BookmarkPlanner.generatedLabel(chapterTitle: nil, positionMilliseconds: 90_999),
      "Bookmark · 1:30"
    )
    XCTAssertEqual(
      BookmarkPlanner.generatedLabel(
        chapterTitle: "  Long Night  ",
        positionMilliseconds: 3_661_999
      ),
      "Long Night · 1:01:01"
    )
  }

  func testEditNormalizesNoteAndRejectsEmptyLabel() throws {
    let original = try BookmarkPlanner.makeBookmark(
      id: uuid(1),
      book: makeBook(),
      positionSeconds: 25,
      note: "old",
      createdAt: .distantPast
    )
    let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let edited = try BookmarkPlanner.edited(
      original,
      label: "  Important clue  ",
      note: "   ",
      updatedAt: updatedAt
    )
    XCTAssertEqual(edited.label, "Important clue")
    XCTAssertNil(edited.note)
    XCTAssertEqual(edited.createdAt, original.createdAt)
    XCTAssertEqual(edited.updatedAt, updatedAt)
    XCTAssertThrowsError(try BookmarkPlanner.edited(
      original,
      label: " \n ",
      note: nil,
      updatedAt: updatedAt
    ))
  }

  func testLocalSearchNormalizesNotesLabelsAndChapterSnapshots() throws {
    let book = makeBook()
    let first = try BookmarkPlanner.edited(
      BookmarkPlanner.makeBookmark(
        id: uuid(1), book: book, positionSeconds: 20,
        note: "Return to the café clue", createdAt: .distantPast
      ),
      label: "Écho marker",
      note: "Return to the café clue",
      updatedAt: .distantPast
    )
    let second = try BookmarkPlanner.makeBookmark(
      id: uuid(2), book: book, positionSeconds: 80,
      note: "Ordinary note", createdAt: .distantFuture
    )
    let index = BookmarkIndex(bookmarks: [second, first])

    XCTAssertEqual(index.search(query: "echo cafe", sort: .positionAscending).map(\.id), [first.id])
    XCTAssertEqual(index.search(query: "crossing", sort: .positionAscending).map(\.id), [second.id])
    XCTAssertTrue(index.search(query: "missing", sort: .positionAscending).isEmpty)
  }

  func testEverySortHasStableDeterministicOrdering() throws {
    let book = makeBook()
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let first = try BookmarkPlanner.edited(
      BookmarkPlanner.makeBookmark(
        id: uuid(1), book: book, positionSeconds: 20, createdAt: date
      ),
      label: "Zulu", note: nil, updatedAt: date
    )
    let second = try BookmarkPlanner.edited(
      BookmarkPlanner.makeBookmark(
        id: uuid(2), book: book, positionSeconds: 80,
        createdAt: date.addingTimeInterval(1)
      ),
      label: "Alpha", note: nil, updatedAt: date.addingTimeInterval(1)
    )
    let index = BookmarkIndex(bookmarks: [second, first])

    XCTAssertEqual(index.search(query: "", sort: .positionAscending).map(\.id), [first.id, second.id])
    XCTAssertEqual(index.search(query: "", sort: .positionDescending).map(\.id), [second.id, first.id])
    XCTAssertEqual(index.search(query: "", sort: .dateNewest).map(\.id), [second.id, first.id])
    XCTAssertEqual(index.search(query: "", sort: .dateOldest).map(\.id), [first.id, second.id])
    XCTAssertEqual(index.search(query: "", sort: .label).map(\.id), [second.id, first.id])
  }

  func testModelAddsAndEditsExactBookmarkDurably() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = MutableBookmarkClock(now)
    let book = makeBook()
    let store = InMemoryLibraryStore(snapshot: snapshot(
      book: book,
      positionMilliseconds: 59_999,
      at: now
    ))
    let playback = BookmarkPlaybackController()
    let model = makeModel(store: store, playback: playback, clock: clock)
    await model.restore()

    let bookmarkID = await model.addBookmark(note: "  first note  ")
    XCTAssertEqual(bookmarkID, uuid(1))
    let added = try XCTUnwrap(model.bookmarks(for: book.id).first)
    XCTAssertEqual(added.bookPositionMilliseconds, 59_999)
    XCTAssertEqual(added.assetID, uuid(101))
    XCTAssertEqual(added.note, "first note")

    clock.advance(by: 10)
    let edited = await model.editBookmark(
      id: added.id,
      label: "  Essential signal  ",
      note: nil
    )
    XCTAssertTrue(edited)
    let durable = await store.load()
    XCTAssertEqual(durable.bookmarks[0].label, "Essential signal")
    XCTAssertNil(durable.bookmarks[0].note)
    XCTAssertEqual(durable.bookmarks[0].updatedAt, now.addingTimeInterval(10))
  }

  func testDeleteAndUndoAreAtomicAndRestoreOriginalOrder() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let book = makeBook()
    let first = try BookmarkPlanner.makeBookmark(
      id: uuid(10), book: book, positionSeconds: 20, createdAt: now
    )
    let second = try BookmarkPlanner.makeBookmark(
      id: uuid(11), book: book, positionSeconds: 80, createdAt: now
    )
    var seed = snapshot(book: book, positionMilliseconds: 20_000, at: now)
    seed.bookmarks = [first, second]
    let store = FailingBookmarkStore(snapshot: seed)
    let model = makeModel(
      store: store,
      playback: BookmarkPlaybackController(),
      clock: MutableBookmarkClock(now),
      ids: (20...30).map(uuid)
    )
    await model.restore()

    await store.failNextSave()
    let failedTransaction = await model.deleteBookmark(id: first.id)
    XCTAssertNil(failedTransaction)
    XCTAssertEqual(model.library.bookmarks.map(\.id), [first.id, second.id])
    XCTAssertTrue(model.library.bookmarkDeletionTransactions.isEmpty)

    let deletedTransaction = await model.deleteBookmark(id: first.id)
    let transactionID = try XCTUnwrap(deletedTransaction)
    XCTAssertEqual(model.library.bookmarks.map(\.id), [second.id])
    XCTAssertEqual(model.library.bookmarkDeletionTransactions.last?.status, .deleted)
    let undone = await model.undoDeleteBookmark(transactionID: transactionID)
    XCTAssertTrue(undone)
    XCTAssertEqual(model.library.bookmarks.map(\.id), [first.id, second.id])
    XCTAssertEqual(model.library.bookmarkDeletionTransactions.last?.status, .undone)
    let repeatedUndo = await model.undoDeleteBookmark(transactionID: transactionID)
    XCTAssertFalse(repeatedUndo)
  }

  func testJumpMapsAcrossAssetsAndPersistsAcknowledgedBookPosition() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let book = makeBook()
    let bookmark = try BookmarkPlanner.makeBookmark(
      id: uuid(10), book: book, positionSeconds: 60, createdAt: now
    )
    var seed = snapshot(book: book, positionMilliseconds: 20_000, at: now)
    seed.bookmarks = [bookmark]
    let store = InMemoryLibraryStore(snapshot: seed)
    let playback = BookmarkPlaybackController()
    let model = makeModel(store: store, playback: playback, clock: MutableBookmarkClock(now))
    await model.restore()

    let jumped = await model.jumpToBookmark(id: bookmark.id)
    XCTAssertTrue(jumped)
    XCTAssertEqual(model.playbackState.elapsedSeconds, 60, accuracy: 0.001)
    XCTAssertEqual(playback.currentPositionSeconds, 0, accuracy: 0.001)
    XCTAssertEqual(playback.loadedURL?.lastPathComponent, "disc-2.m4b")
    let durable = await store.load()
    XCTAssertEqual(durable.playbackPosition?.positionMilliseconds, 60_000)
    XCTAssertEqual(durable.positionJournal.last?.reason, .seek)
  }

  func testPersistedBookmarkFieldsJoinLibraryFullTextSearch() throws {
    let book = makeBook()
    let bookmark = try BookmarkPlanner.edited(
      BookmarkPlanner.makeBookmark(
        id: uuid(10), book: book, positionSeconds: 80,
        note: "Return to the café window", createdAt: .distantPast
      ),
      label: "Écho clue", note: "Return to the café window", updatedAt: .distantPast
    )
    let library = LibrarySnapshot(
      books: [book], importJobs: [], currentBookID: nil, bookmarks: [bookmark]
    )
    let index = LibrarySearchIndex(library: library)

    for query in ["echo clue", "cafe window", "the crossing"] {
      XCTAssertEqual(index.search(query: query, preferences: .default).books.map(\.id), [book.id])
    }
  }

  func testSchemaTwelveMigratesBookmarkDefaultsAndWritesSchemaThirteen() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "BookmarkMigration-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appending(path: "Library.json")
    let store = CodableLibraryStore(fileURL: fileURL)
    try await store.save(LibrarySnapshot(
      books: [makeBook()], importJobs: [], currentBookID: nil
    ))
    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    envelope["schemaVersion"] = 12
    var library = try XCTUnwrap(envelope["library"] as? [String: Any])
    library.removeValue(forKey: "bookmarks")
    library.removeValue(forKey: "bookmarkDeletionTransactions")
    envelope["library"] = library
    try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL, options: .atomic)

    let migrated = try await store.load()
    XCTAssertTrue(migrated.bookmarks.isEmpty)
    XCTAssertTrue(migrated.bookmarkDeletionTransactions.isEmpty)
    try await store.save(migrated)
    let current = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    XCTAssertEqual(current["schemaVersion"] as? Int, 13)
  }

  private func makeBook() -> Book {
    Book(
      id: uuid(100),
      title: "Mapped Signals",
      authors: ["Mara Vale"],
      durationSeconds: 120,
      artworkData: nil,
      assets: [
        AudioAsset(
          id: uuid(101), originalFilename: "disc-1.m4b",
          managedRelativePath: "Media/disc-1.m4b", checksumSHA256: "one",
          byteCount: 1, durationSeconds: 60, container: "M4B",
          timelineStartSeconds: 0, importOrder: 0
        ),
        AudioAsset(
          id: uuid(102), originalFilename: "disc-2.m4b",
          managedRelativePath: "Media/disc-2.m4b", checksumSHA256: "two",
          byteCount: 1, durationSeconds: 60, container: "M4B",
          timelineStartSeconds: 60, importOrder: 1
        ),
      ],
      dateAdded: .distantPast,
      chapters: [
        Chapter(
          id: "opening", title: "Opening Signal", startSeconds: 0,
          durationSeconds: 60, source: .embedded, assetID: uuid(101)
        ),
        Chapter(
          id: "crossing", title: "The Crossing", startSeconds: 60,
          durationSeconds: 60, source: .embedded, assetID: uuid(102)
        ),
      ]
    )
  }

  private func snapshot(
    book: Book,
    positionMilliseconds: Int64,
    at date: Date
  ) -> LibrarySnapshot {
    let event = PositionEvent.acknowledged(
      id: uuid(900),
      bookID: book.id,
      positionMilliseconds: positionMilliseconds,
      sequence: 1,
      reason: .pause,
      acknowledgedAt: date,
      previousEventID: nil
    )
    return LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: book.id,
      playbackPosition: PlaybackPosition(
        bookID: book.id,
        positionMilliseconds: positionMilliseconds,
        sequence: 1,
        sourceEventID: event.id,
        updatedAt: date
      ),
      positionJournal: [event]
    )
  }

  private func makeModel(
    store: any LibraryPersisting,
    playback: BookmarkPlaybackController,
    clock: MutableBookmarkClock,
    ids: [UUID]? = nil
  ) -> PlayerModel {
    PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: BookmarkMediaManager(),
      inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
      playback: playback,
      clock: clock,
      ids: DeterministicPlayerIDGenerator(values: ids ?? (1...40).map(uuid))
    ))
  }

  private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "e0000000-0000-0000-0000-%012d", suffix))!
  }
}

private final class MutableBookmarkClock: PlayerClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) { self.value = value }
  func now() -> Date { lock.withLock { value } }
  func advance(by interval: TimeInterval) {
    lock.withLock { value = value.addingTimeInterval(interval) }
  }
}

@MainActor
private final class BookmarkPlaybackController: AudioPlaybackControlling {
  private(set) var state: PlaybackState = .unloaded
  private(set) var loadedURL: URL?
  private(set) var playbackRate = 1.0

  var currentPositionSeconds: Double { state.elapsedSeconds }
  func load(url: URL, bookID: UUID, at seconds: Double) async throws {
    loadedURL = url
    state = PlaybackState(status: .paused, loadedBookID: bookID, elapsedSeconds: seconds)
  }
  func seek(to seconds: Double) async { state.elapsedSeconds = max(0, seconds) }
  func setPlaybackRate(_ rate: Double) { playbackRate = rate }
  func play() { state.status = .playing }
  func pause() { state.status = .paused }
}

private actor BookmarkMediaManager: MediaManaging {
  func stage(sourceURL: URL, jobID: UUID) throws -> StagedAudio {
    throw PlayerCoreError.fileOperation("unused")
  }
  func stagedURL(for relativePath: String) throws -> URL {
    throw PlayerCoreError.fileOperation("unused")
  }
  func commit(_ staged: StagedAudio, bookID: UUID, assetID: UUID) throws -> ManagedAudio {
    throw PlayerCoreError.fileOperation("unused")
  }
  func rollback(_ managed: ManagedAudio) {}
  func managedURL(for relativePath: String) -> URL {
    URL(filePath: "/tmp").appending(path: relativePath)
  }
  func discardStaging(for jobID: UUID) {}
}

private actor FailingBookmarkStore: LibraryPersisting {
  private var snapshot: LibrarySnapshot
  private var shouldFailNextSave = false

  init(snapshot: LibrarySnapshot) { self.snapshot = snapshot }
  func load() -> LibrarySnapshot { snapshot }
  func save(_ snapshot: LibrarySnapshot) throws {
    if shouldFailNextSave {
      shouldFailNextSave = false
      throw PlayerCoreError.fileOperation("Injected bookmark save failure.")
    }
    self.snapshot = snapshot
  }
  func failNextSave() { shouldFailNextSave = true }
}
