import XCTest
@testable import Player

@MainActor
final class LibraryOrganizationTests: XCTestCase {
  func testFinishingBookAtomicallyStoresDurationAndRemovesDailyQueues() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let book = makeBook(
      id: uuid(1),
      title: "The Long Way Home",
      duration: 120.25,
      listeningState: BookListeningState(
        status: .inProgress,
        positionMilliseconds: 35_000,
        lastListenedAt: now.addingTimeInterval(-10),
        finishedAt: nil
      )
    )
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: nil,
      upNextBookIDs: [book.id]
    ))
    let model = makeModel(store: store, now: now)

    await model.restore()
    XCTAssertEqual(model.continueListeningBooks.map(\.id), [book.id])

    let didFinish = await model.setBookFinished(bookID: book.id, isFinished: true)
    XCTAssertTrue(didFinish)

    let finished = try XCTUnwrap(model.library.books.first)
    XCTAssertEqual(finished.listeningState.status, .finished)
    XCTAssertEqual(finished.listeningState.positionMilliseconds, 120_250)
    XCTAssertEqual(finished.listeningState.finishedAt, now)
    XCTAssertTrue(model.continueListeningBooks.isEmpty)
    XCTAssertTrue(model.upNextBooks.isEmpty)
    let durable = await store.load()
    XCTAssertEqual(durable.books.first?.listeningState, finished.listeningState)
    XCTAssertTrue(durable.upNextBookIDs.isEmpty)
  }

  func testUpNextCollectionsAndViewPreferenceAreOrderedValidatedAndDurable() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_100)
    let books = [
      makeBook(id: uuid(1), title: "One"),
      makeBook(id: uuid(2), title: "Two"),
      makeBook(id: uuid(3), title: "Three"),
    ]
    let collectionID = uuid(90)
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: books,
      importJobs: [],
      currentBookID: nil
    ))
    let model = makeModel(store: store, now: now, ids: [collectionID])
    await model.restore()

    let addedFirst = await model.addToUpNext(bookID: books[0].id)
    let addedSecond = await model.addToUpNext(bookID: books[1].id)
    let reorderedUpNext = await model.reorderUpNext(bookIDs: [books[1].id, books[0].id])
    XCTAssertTrue(addedFirst)
    XCTAssertTrue(addedSecond)
    XCTAssertTrue(reorderedUpNext)
    XCTAssertEqual(model.upNextBooks.map(\.id), [books[1].id, books[0].id])
    let acceptedDuplicateOrder = await model.reorderUpNext(bookIDs: [books[0].id, books[0].id])
    XCTAssertFalse(acceptedDuplicateOrder)
    XCTAssertEqual(model.upNextBooks.map(\.id), [books[1].id, books[0].id])

    let createdCollectionID = await model.createCollection(name: "  Road Trips  ")
    let addedBookOne = await model.addBook(books[0].id, toCollection: collectionID)
    let addedBookThree = await model.addBook(books[2].id, toCollection: collectionID)
    let reorderedCollection = await model.reorderCollection(
      collectionID,
      bookIDs: [books[2].id, books[0].id]
    )
    let renamedCollection = await model.renameCollection(id: collectionID, name: "Favorites")
    let changedStyle = await model.setAllBooksViewStyle(.list)
    XCTAssertEqual(createdCollectionID, collectionID)
    XCTAssertTrue(addedBookOne)
    XCTAssertTrue(addedBookThree)
    XCTAssertTrue(reorderedCollection)
    XCTAssertTrue(renamedCollection)
    XCTAssertTrue(changedStyle)

    let durable = await store.load()
    XCTAssertEqual(durable.upNextBookIDs, [books[1].id, books[0].id])
    XCTAssertEqual(durable.collections.first?.name, "Favorites")
    XCTAssertEqual(durable.collections.first?.orderedBookIDs, [books[2].id, books[0].id])
    XCTAssertEqual(durable.allBooksViewStyle, .list)
  }

  func testAcknowledgedPlaybackEntersContinueListeningWithoutUnfinishingAReplay() async throws {
    let book = makeBook(id: uuid(1), title: "Replayable", duration: 90)
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: nil
    ))
    let model = makeModel(store: store, ids: [uuid(70), uuid(71)])
    await model.restore()

    await model.play(bookID: book.id, at: 12.5)
    XCTAssertEqual(model.library.books.first?.listeningState.status, .inProgress)
    XCTAssertEqual(model.library.books.first?.listeningState.positionMilliseconds, 12_500)
    XCTAssertEqual(model.continueListeningBooks.map(\.id), [book.id])

    let markedFinished = await model.setBookFinished(bookID: book.id, isFinished: true)
    XCTAssertTrue(markedFinished)
    await model.play(bookID: book.id, at: 0)
    XCTAssertEqual(model.library.books.first?.listeningState.status, .finished)
    XCTAssertEqual(model.library.books.first?.listeningState.positionMilliseconds, 90_000)
    XCTAssertTrue(model.continueListeningBooks.isEmpty)
  }

  func testBrowseProjectionsUseStableContributorIdentityAndNaturalSeriesOrder() async {
    let author = Contributor(id: "author:mara", displayName: "Mara Vale", sortName: "Vale, Mara")
    let narrator = Contributor(id: "narrator:alex", displayName: "Alex Reader")
    let seriesID = "series:signal"
    let metadataTwo = AudiobookMetadata(
      title: "Second",
      authors: [author],
      narrators: [narrator],
      seriesMemberships: [SeriesMembership(seriesID: seriesID, name: "Signal", position: "2")]
    )
    let metadataTen = AudiobookMetadata(
      title: "Tenth",
      authors: [author],
      narrators: [narrator],
      seriesMemberships: [SeriesMembership(seriesID: seriesID, name: "Signal", position: "10")]
    )
    let second = makeBook(id: uuid(2), title: "Second", metadata: metadataTwo)
    let tenth = makeBook(id: uuid(10), title: "Tenth", metadata: metadataTen)
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [tenth, second],
      importJobs: [],
      currentBookID: nil
    ))
    let model = makeModel(store: store)
    await model.restore()

    XCTAssertEqual(model.browseGroups(for: .series), [
      LibraryBrowseGroup(
        id: seriesID,
        displayName: "Signal",
        sortName: nil,
        bookIDs: [second.id, tenth.id]
      )
    ])
    XCTAssertEqual(model.browseGroups(for: .authors).first?.id, author.id)
    XCTAssertEqual(model.browseGroups(for: .authors).first?.sortName, "Vale, Mara")
    XCTAssertEqual(Set(model.browseGroups(for: .narrators).first?.bookIDs ?? []), [second.id, tenth.id])
  }

  func testManagedMediaTrashRemovalAndRestorePreserveBookAndMembershipOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "LibraryOrganizationTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let book = makeBook(id: uuid(1), title: "Recover Me")
    let mediaDirectory = root.appending(
      path: "Media/\(book.id.uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    let bytes = Data("immutable-audio".utf8)
    let managedURL = root.appending(path: book.assets[0].managedRelativePath)
    try bytes.write(to: managedURL)

    let collection = BookCollection(
      id: uuid(80),
      name: "Keepers",
      orderedBookIDs: [uuid(2), book.id, uuid(3)],
      createdAt: .distantPast,
      updatedAt: .distantPast
    )
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: nil,
      upNextBookIDs: [book.id],
      collections: [collection]
    ))
    let transactionID = uuid(99)
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: FileSystemMediaManager(rootURL: root),
      inspector: OrganizationUnusedInspector(),
      playback: OrganizationPlaybackController(),
      clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_800_000_200)),
      ids: DeterministicPlayerIDGenerator(values: [transactionID])
    ))
    await model.restore()

    let removedTransactionID = await model.removeBook(
      bookID: book.id,
      mediaPolicy: .moveManagedMediaToTrash
    )
    XCTAssertEqual(removedTransactionID, transactionID)
    XCTAssertTrue(model.library.books.isEmpty)
    XCTAssertTrue(model.library.upNextBookIDs.isEmpty)
    XCTAssertEqual(model.library.collections.first?.orderedBookIDs, [uuid(2), uuid(3)])
    XCTAssertFalse(FileManager.default.fileExists(atPath: managedURL.path))
    let trash = try XCTUnwrap(model.library.trashTransactions.first)
    XCTAssertEqual(trash.status, .recoverable)
    XCTAssertEqual(trash.mediaManifest?.byteCount, Int64(bytes.count))

    let restored = await model.restoreTrashedBook(transactionID: transactionID)
    XCTAssertTrue(restored)
    XCTAssertEqual(model.library.books, [book])
    XCTAssertEqual(model.library.upNextBookIDs, [book.id])
    XCTAssertEqual(model.library.collections.first?.orderedBookIDs, [uuid(2), book.id, uuid(3)])
    XCTAssertEqual(model.library.trashTransactions.first?.status, .restored)
    XCTAssertEqual(try Data(contentsOf: managedURL), bytes)
  }

  func testSchemaSevenMigratesListeningPositionAndOrganizationDefaultsToEight() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "LibraryOrganizationMigration-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fileURL = root.appending(path: "Library.json")
    let store = CodableLibraryStore(fileURL: fileURL)
    let book = makeBook(id: uuid(1), title: "Legacy")
    let position = PlaybackPosition(
      bookID: book.id,
      positionMilliseconds: 45_500,
      sequence: 4,
      sourceEventID: uuid(70),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try await store.save(LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: book.id,
      playbackPosition: position
    ))

    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    envelope["schemaVersion"] = 7
    var library = try XCTUnwrap(envelope["library"] as? [String: Any])
    library.removeValue(forKey: "upNextBookIDs")
    library.removeValue(forKey: "collections")
    library.removeValue(forKey: "allBooksViewStyle")
    library.removeValue(forKey: "trashTransactions")
    var books = try XCTUnwrap(library["books"] as? [[String: Any]])
    books[0].removeValue(forKey: "listeningState")
    library["books"] = books
    envelope["library"] = library
    try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL, options: .atomic)

    let migrated = try await store.load()
    XCTAssertEqual(migrated.books.first?.listeningState.status, .inProgress)
    XCTAssertEqual(migrated.books.first?.listeningState.positionMilliseconds, 45_500)
    XCTAssertEqual(migrated.books.first?.listeningState.lastListenedAt, position.updatedAt)
    XCTAssertTrue(migrated.upNextBookIDs.isEmpty)
    XCTAssertTrue(migrated.collections.isEmpty)
    XCTAssertEqual(migrated.allBooksViewStyle, .grid)
    XCTAssertTrue(migrated.trashTransactions.isEmpty)

    try await store.save(migrated)
    let current = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    XCTAssertEqual(current["schemaVersion"] as? Int, 8)
  }

  private func makeModel(
    store: InMemoryLibraryStore,
    now: Date = Date(timeIntervalSince1970: 1_800_000_000),
    ids: [UUID] = []
  ) -> PlayerModel {
    PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: OrganizationMediaManager(),
      inspector: OrganizationUnusedInspector(),
      playback: OrganizationPlaybackController(),
      clock: FixedPlayerClock(value: now),
      ids: DeterministicPlayerIDGenerator(values: ids)
    ))
  }

  private func makeBook(
    id: UUID,
    title: String,
    duration: Double = 100,
    metadata: AudiobookMetadata? = nil,
    listeningState: BookListeningState = .unplayed
  ) -> Book {
    return Book(
      id: id,
      title: title,
      authors: metadata?.authors.map(\.displayName) ?? ["Author"],
      durationSeconds: duration,
      artworkData: nil,
      assets: [AudioAsset(
        id: id,
        originalFilename: "book.m4b",
        managedRelativePath: "Media/\(id.uuidString.lowercased())/book.m4b",
        checksumSHA256: "fixture",
        byteCount: 15,
        durationSeconds: duration,
        container: "M4B"
      )],
      dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
      metadata: metadata,
      listeningState: listeningState
    )
  }

  private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "a0000000-0000-0000-0000-%012d", suffix))!
  }
}

private actor OrganizationMediaManager: MediaManaging {
  func stage(sourceURL: URL, jobID: UUID) throws -> StagedAudio {
    throw PlayerCoreError.fileOperation("unused")
  }

  func stagedURL(for relativePath: String) throws -> URL { URL(filePath: "/tmp/unused") }

  func commit(_ staged: StagedAudio, bookID: UUID, assetID: UUID) throws -> ManagedAudio {
    throw PlayerCoreError.fileOperation("unused")
  }

  func rollback(_ managed: ManagedAudio) {}

  func managedURL(for relativePath: String) throws -> URL { URL(filePath: "/tmp/unused") }

  func discardStaging(for jobID: UUID) {}
}

private struct OrganizationUnusedInspector: AudioInspecting {
  func inspect(url: URL) async throws -> InspectedAudio {
    throw PlayerCoreError.fileOperation("unused")
  }
}

@MainActor
private final class OrganizationPlaybackController: AudioPlaybackControlling {
  var state = PlaybackState.unloaded
  var currentPositionSeconds = 0.0

  func load(url: URL, bookID: UUID, at seconds: Double) async throws {
    currentPositionSeconds = seconds
    state = PlaybackState(status: .paused, loadedBookID: bookID, elapsedSeconds: seconds)
  }

  func seek(to seconds: Double) async {
    currentPositionSeconds = seconds
    state.elapsedSeconds = seconds
  }

  func play() { state.status = .playing }
  func pause() { state.status = .paused }
}
