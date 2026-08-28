import CryptoKit
import XCTest
@testable import Player

@MainActor
final class MetadataEditingTests: XCTestCase {
  func testPlannerMapsEveryMVPFieldIndependentlyAndPreservesContributorIdentity() throws {
    let retainedAuthor = Contributor(
      id: "author-durable-id",
      displayName: "Existing Author",
      sortName: "Author, Existing"
    )
    let retainedNarrator = Contributor(
      id: "narrator-durable-id",
      displayName: "Existing Narrator",
      sortName: "Narrator, Existing"
    )
    let initial = AudiobookMetadata(
      title: "Old Title",
      sortTitle: "Old Title",
      subtitle: "Old Subtitle",
      authors: [retainedAuthor],
      narrators: [retainedNarrator],
      seriesMemberships: [SeriesMembership(name: "Old Series", position: "1")],
      description: "Old description",
      genres: ["Old Genre"],
      tags: ["Old Tag"],
      language: "en",
      publicationYear: 2001,
      publisher: "Old Publisher",
      edition: "First",
      abridgement: .unknown,
      cover: CoverArtwork(originalData: Data([1]), mediaType: "image/png", source: .embedded)
    )
    var draft = MetadataEditDraft(metadata: initial)
    draft.title = " New Title "
    draft.sortTitle = "Title, New"
    draft.subtitle = "New Subtitle"
    draft.authors = "Existing Author, New Author"
    draft.narrators = " existing narrator "
    draft.seriesName = "New Series"
    draft.seriesPosition = "2.5"
    draft.description = "New description"
    draft.genres = "Mystery; Science Fiction, mystery"
    draft.tags = "Favorite\nNight"
    draft.language = "fr-CA"
    draft.publicationYear = "2026"
    draft.publisher = "New Publisher"
    draft.edition = "Anniversary"
    draft.abridgement = AbridgementStatus.unabridged.rawValue
    draft.cover = CoverArtwork(originalData: Data([2]), mediaType: "image/png", source: .file)

    let plan = try MetadataEditPlanner.plan(
      initial: initial,
      draft: draft,
      lockOverrides: [.seriesName: true, .genres: true]
    )
    XCTAssertEqual(
      Set(plan.mutations.map(\.field)),
      Set(MetadataField.allCases),
      "One plan must cover every editable MVP field"
    )
    XCTAssertTrue(plan.mutations.contains { $0.field == .seriesName && $0.value == .text("New Series") })
    XCTAssertTrue(plan.mutations.contains { $0.field == .seriesPosition && $0.value == .text("2.5") })
    let authorMutation = try XCTUnwrap(plan.mutations.first { $0.field == .authors })
    guard case .contributors(let authors) = authorMutation.value else {
      return XCTFail("Expected contributor mutation")
    }
    XCTAssertEqual(authors.first, retainedAuthor)
    XCTAssertEqual(authors.last?.displayName, "New Author")
    let narratorMutation = try XCTUnwrap(plan.mutations.first { $0.field == .narrators })
    guard case .contributors(let narrators) = narratorMutation.value else {
      return XCTFail("Expected contributor mutation")
    }
    XCTAssertEqual(narrators, [retainedNarrator], "Case/spacing-only edits preserve ID and sort name")

    let transactionID = UUID()
    var repaired = initial
    for mutation in plan.mutations { try repaired.apply(mutation, transactionID: transactionID) }
    XCTAssertEqual(repaired.title, "New Title")
    XCTAssertEqual(repaired.sortTitle, "Title, New")
    XCTAssertEqual(repaired.subtitle, "New Subtitle")
    XCTAssertEqual(repaired.seriesMemberships.first, SeriesMembership(name: "New Series", position: "2.5"))
    XCTAssertEqual(repaired.description, "New description")
    XCTAssertEqual(repaired.genres, ["Mystery", "Science Fiction"])
    XCTAssertEqual(repaired.tags, ["Favorite", "Night"])
    XCTAssertEqual(repaired.language, "fr-CA")
    XCTAssertEqual(repaired.publicationYear, 2026)
    XCTAssertEqual(repaired.publisher, "New Publisher")
    XCTAssertEqual(repaired.edition, "Anniversary")
    XCTAssertEqual(repaired.abridgement, .unabridged)
    XCTAssertEqual(repaired.cover, draft.cover)
    XCTAssertTrue(repaired.state(for: .seriesName)?.isLocked == true)
    XCTAssertTrue(repaired.state(for: .genres)?.isLocked == true)
  }

  func testPlannerRejectsBlankTitleAndMalformedOrOutOfRangeYear() {
    let initial = AudiobookMetadata(title: "Required", publicationYear: 2000)
    var draft = MetadataEditDraft(metadata: initial)
    draft.title = "  "
    XCTAssertEqual(
      MetadataEditPlanner.validationError(initial: initial, draft: draft),
      .titleRequired
    )
    draft.title = "Required"
    for invalid in ["twenty", "0", "10000", "-1"] {
      draft.publicationYear = invalid
      XCTAssertEqual(
        MetadataEditPlanner.validationError(initial: initial, draft: draft),
        .invalidPublicationYearText(invalid)
      )
    }
    XCTAssertThrowsError(try metadataApplying(initial, [.clear(.title)])) {
      XCTAssertEqual($0 as? MetadataRepairError, .titleRequired)
    }
    XCTAssertThrowsError(try metadataApplying(initial, [.set(.title, value: .text("  "))])) {
      XCTAssertEqual($0 as? MetadataRepairError, .titleRequired)
    }
  }

  func testQuotedContributorParsingIsLosslessAndRejectsMalformedQuotes() throws {
    let retained = Contributor(
      id: "smith-jane-durable",
      displayName: "Smith, Jane",
      sortName: "Smith, Jane"
    )
    let initial = AudiobookMetadata(title: "Quoted", authors: [retained])
    var draft = MetadataEditDraft(metadata: initial)
    XCTAssertEqual(draft.authors, "\"Smith, Jane\"")
    draft.authors = "\"Smith, Jane\", \"O\"\"Brien, Pat\"; Another Author"
    let plan = try MetadataEditPlanner.plan(initial: initial, draft: draft)
    guard case .contributors(let contributors) = plan.mutations.first(where: {
      $0.field == .authors
    })?.value else { return XCTFail("Expected authors") }
    XCTAssertEqual(contributors.map(\.displayName), [
      "Smith, Jane", "O\"Brien, Pat", "Another Author",
    ])
    XCTAssertEqual(contributors.first, retained)

    draft.authors = "\"Smith, Jane"
    XCTAssertEqual(
      MetadataEditPlanner.validationError(initial: initial, draft: draft),
      .malformedDelimitedValue(.authors)
    )
    draft.authors = "\"Smith, Jane\" trailing text"
    XCTAssertEqual(
      MetadataEditPlanner.validationError(initial: initial, draft: draft),
      .malformedDelimitedValue(.authors)
    )
  }

  func testSeriesClearIsPlannedCoherentlyWithIndependentProvenance() throws {
    let initial = AudiobookMetadata(
      title: "Series Book",
      seriesMemberships: [SeriesMembership(name: "Signals", position: "4")]
    )
    var draft = MetadataEditDraft(metadata: initial)
    draft.seriesName = ""
    draft.seriesPosition = ""
    let plan = try MetadataEditPlanner.plan(initial: initial, draft: draft)
    XCTAssertEqual(plan.mutations.map(\.field), [.seriesPosition, .seriesName])
    XCTAssertEqual(plan.explicitlyClearedFields, [.seriesName, .seriesPosition])

    let transactionID = UUID()
    let repaired = try metadataApplying(initial, plan.mutations, transactionID: transactionID)
    XCTAssertTrue(repaired.seriesMemberships.isEmpty)
    for field in [MetadataField.seriesName, .seriesPosition] {
      XCTAssertTrue(repaired.state(for: field)?.isExplicitlyCleared == true)
      XCTAssertEqual(repaired.state(for: field)?.lastTransactionID, transactionID)
    }
  }

  func testPlannedClearsIncludeGenericDeletesAndUntouchedPriorExplicitClears() throws {
    let priorClearID = UUID()
    var initial = AudiobookMetadata(
      title: "Clear State",
      sortTitle: "Clear State",
      authors: [Contributor(displayName: "Remove Me")]
    )
    try initial.apply(.clear(.sortTitle), transactionID: priorClearID)
    var draft = MetadataEditDraft(metadata: initial)
    draft.title = "Edited Elsewhere"
    draft.authors = ""

    let plan = try MetadataEditPlanner.plan(initial: initial, draft: draft)
    XCTAssertTrue(plan.explicitlyClearedFields.contains(.sortTitle))
    XCTAssertTrue(plan.explicitlyClearedFields.contains(.authors))
    XCTAssertFalse(plan.mutations.contains { $0.field == .sortTitle })
    XCTAssertTrue(plan.mutations.contains {
      $0.field == .authors && $0.operation == .clear
    })
  }

  func testOneSaveCreatesOneTransactionAndPersistenceFailureRollsBack() async throws {
    let book = makeBook(title: "Before")
    let failedTransactionID = UUID()
    let transactionID = UUID()
    let store = MetadataFailingStore(snapshot: LibrarySnapshot(
      books: [book], importJobs: [], currentBookID: nil
    ))
    let model = makeModel(store: store, ids: [failedTransactionID, transactionID])
    await model.restore()
    await store.failNextSave()

    let failed = await model.repairBookMetadata(bookID: book.id, mutations: [
      .set(.title, value: .text("After")),
      .set(.subtitle, value: .text("Atomic")),
    ])
    XCTAssertNil(failed)
    XCTAssertEqual(model.library.books.first?.title, "Before")
    XCTAssertTrue(model.library.metadataTransactions.isEmpty)
    let persistedAfterFailure = await store.load()
    XCTAssertEqual(persistedAfterFailure.books.first?.title, "Before")

    let saved = await model.repairBookMetadata(bookID: book.id, mutations: [
      .set(.title, value: .text("After")),
      .set(.subtitle, value: .text("Atomic")),
    ])
    XCTAssertEqual(saved, transactionID)
    XCTAssertEqual(model.library.metadataTransactions.count, 1)
    XCTAssertEqual(model.library.metadataTransactions.first?.mutations.count, 2)
  }

  func testModelRejectsACommitThatWouldRetainAnEmptyTitle() async {
    let book = Book(
      id: UUID(), title: "", authors: [], durationSeconds: 60,
      artworkData: nil, assets: [], dateAdded: .distantPast,
      metadata: AudiobookMetadata(title: "")
    )
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [book], importJobs: [], currentBookID: nil
    ))
    let model = makeModel(store: store, ids: [UUID()])
    await model.restore()
    let result = await model.repairBookMetadata(
      bookID: book.id,
      mutations: [.set(.authors, value: .contributors([Contributor(displayName: "Author")]))]
    )
    XCTAssertNil(result)
    XCTAssertTrue(model.library.metadataTransactions.isEmpty)
    XCTAssertTrue(model.library.books.first?.authors.isEmpty == true)
  }

  func testSaveIsSingleFlightPerTarget() async throws {
    let book = makeBook(title: "Before")
    let store = MetadataGatedStore(snapshot: LibrarySnapshot(
      books: [book], importJobs: [], currentBookID: nil
    ))
    let model = makeModel(store: store, ids: [UUID(), UUID()])
    await model.restore()

    let first = Task { await model.repairBookMetadata(
      bookID: book.id,
      mutations: [.set(.title, value: .text("First"))]
    ) }
    await store.waitUntilSaveStarts()
    let second = await model.repairBookMetadata(
      bookID: book.id,
      mutations: [.set(.title, value: .text("Second"))]
    )
    XCTAssertNil(second)
    await store.releaseSave()
    let firstResult = await first.value
    XCTAssertNotNil(firstResult)
    XCTAssertEqual(model.library.books.first?.title, "First")
    XCTAssertEqual(model.library.metadataTransactions.count, 1)
  }

  func testSearchRevisionAndResultsFollowApplyAndAtomicUndo() async throws {
    let book = makeBook(title: "Before")
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [book], importJobs: [], currentBookID: nil
    ))
    let model = makeModel(store: store, ids: [UUID()])
    await model.restore()
    let beforeRevision = LibrarySearchRevision(library: model.library)
    XCTAssertEqual(model.library.metadataRevision(for: .book(book.id)), "0")
    XCTAssertEqual(
      LibrarySearchIndex(library: model.library).search(query: "before", preferences: .default).books.map(\.id),
      [book.id]
    )

    let applied = await model.repairBookMetadata(bookID: book.id, mutations: [
      .set(.title, value: .text("After")),
      .set(.authors, value: .contributors([Contributor(displayName: "New Author")]))
    ])
    XCTAssertNotNil(applied)
    let appliedID = try XCTUnwrap(applied)
    XCTAssertEqual(
      model.library.metadataRevision(for: .book(book.id)),
      "\(appliedID.uuidString.lowercased()):applied"
    )
    let appliedRevision = LibrarySearchRevision(library: model.library)
    XCTAssertNotEqual(appliedRevision, beforeRevision)
    let appliedIndex = LibrarySearchIndex(library: model.library)
    XCTAssertEqual(appliedIndex.search(query: "new author", preferences: .default).books.map(\.id), [book.id])
    XCTAssertTrue(appliedIndex.search(query: "before", preferences: .default).books.isEmpty)
    XCTAssertEqual(model.library.books.first?.authors, ["New Author"])
    XCTAssertEqual(model.library.browseGroups(for: .authors).map(\.displayName), ["New Author"])

    let didUndo = await model.undoLastMetadataTransaction(for: .book(book.id))
    XCTAssertTrue(didUndo)
    XCTAssertEqual(
      model.library.metadataRevision(for: .book(book.id)),
      "\(appliedID.uuidString.lowercased()):undone"
    )
    XCTAssertEqual(LibrarySearchRevision(library: model.library), beforeRevision)
    XCTAssertEqual(model.library.books.first?.authors, ["Original Author"])
    XCTAssertEqual(model.library.browseGroups(for: .authors).map(\.displayName), ["Original Author"])
    XCTAssertEqual(
      LibrarySearchIndex(library: model.library).search(query: "before", preferences: .default).books.map(\.id),
      [book.id]
    )
  }

  func testLatestSearchBuildRejectsStaleAndCancelledWork() async {
    let gate = MetadataBuildGate()
    let oldBook = makeBook(title: "Old Search Value")
    let newBook = makeBook(title: "New Search Value")
    let oldLibrary = LibrarySnapshot(books: [oldBook], importJobs: [], currentBookID: nil)
    let newLibrary = LibrarySnapshot(books: [newBook], importJobs: [], currentBookID: nil)
    let builder = LibrarySearchIndexBuilder { library, notes in
      if library.books.first?.title == "Old Search Value" {
        await gate.blockUntilReleased()
      }
      return LibrarySearchIndex(library: library, bookmarkNotesByBookID: notes)
    }

    let staleTask = Task {
      await builder.buildLatest(
        library: oldLibrary,
        revision: LibrarySearchRevision(library: oldLibrary)
      )
    }
    await gate.waitUntilBlocked()
    let newest = await builder.buildLatest(
      library: newLibrary,
      revision: LibrarySearchRevision(library: newLibrary)
    )
    await gate.release()
    let stale = await staleTask.value
    XCTAssertNil(stale)
    XCTAssertEqual(
      newest?.index.search(query: "new search", preferences: .default).books.map(\.id),
      [newBook.id]
    )

    let cancellationGate = MetadataBuildGate()
    let cancellationBuilder = LibrarySearchIndexBuilder { library, notes in
      await cancellationGate.blockUntilReleased()
      return LibrarySearchIndex(library: library, bookmarkNotesByBookID: notes)
    }
    let cancelledTask = Task {
      await cancellationBuilder.buildLatest(
        library: oldLibrary,
        revision: LibrarySearchRevision(library: oldLibrary)
      )
    }
    await cancellationGate.waitUntilBlocked()
    cancelledTask.cancel()
    await cancellationGate.release()
    let cancelled = await cancelledTask.value
    XCTAssertNil(cancelled)
  }

  func testMetadataSaveAndUndoLeaveManagedAudioByteIdentical() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "MetadataEditingTests-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let bookID = UUID()
    let relativePath = "Media/\(bookID.uuidString.lowercased())/audio.m4b"
    let managedURL = root.appending(path: relativePath)
    try FileManager.default.createDirectory(
      at: managedURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let bytes = Data((0..<4096).map { UInt8($0 % 251) })
    try bytes.write(to: managedURL)
    let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    var book = makeBook(title: "Before")
    book = Book(
      id: bookID,
      title: book.title,
      authors: book.authors,
      durationSeconds: 60,
      artworkData: nil,
      assets: [AudioAsset(
        id: UUID(), originalFilename: "audio.m4b", managedRelativePath: relativePath,
        checksumSHA256: checksum, byteCount: Int64(bytes.count), durationSeconds: 60,
        container: "M4B"
      )],
      dateAdded: .distantPast,
      metadata: book.metadata
    )
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [book], importJobs: [], currentBookID: nil
    ))
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: FileSystemMediaManager(rootURL: root),
      inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
      playback: DeterministicPlaybackController(),
      ids: DeterministicPlayerIDGenerator(values: [UUID()])
    ))
    await model.restore()
    let before = try Data(contentsOf: managedURL)
    let saved = await model.repairBookMetadata(
      bookID: bookID, mutations: [.set(.title, value: .text("After"))]
    )
    XCTAssertNotNil(saved)
    XCTAssertEqual(try Data(contentsOf: managedURL), before)
    let didUndo = await model.undoLastMetadataTransaction(for: .book(bookID))
    XCTAssertTrue(didUndo)
    XCTAssertEqual(try Data(contentsOf: managedURL), before)
    XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: managedURL)).description, SHA256.hash(data: bytes).description)
  }

  private func metadataApplying(
    _ metadata: AudiobookMetadata,
    _ mutations: [MetadataMutation],
    transactionID: UUID = UUID()
  ) throws -> AudiobookMetadata {
    var result = metadata
    for mutation in mutations { try result.apply(mutation, transactionID: transactionID) }
    return result
  }

  private func makeBook(title: String) -> Book {
    Book(
      id: UUID(), title: title, authors: ["Original Author"], durationSeconds: 60,
      artworkData: nil, assets: [], dateAdded: .distantPast,
      metadata: AudiobookMetadata(
        title: title,
        authors: [Contributor(id: "original-author", displayName: "Original Author", sortName: "Author, Original")]
      )
    )
  }

  private func makeModel(
    store: any LibraryPersisting,
    ids: [UUID]
  ) -> PlayerModel {
    PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: FileSystemMediaManager(rootURL: FileManager.default.temporaryDirectory),
      inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
      playback: DeterministicPlaybackController(),
      ids: DeterministicPlayerIDGenerator(values: ids)
    ))
  }
}

private actor MetadataFailingStore: LibraryPersisting {
  private var snapshot: LibrarySnapshot
  private var shouldFail = false

  init(snapshot: LibrarySnapshot) { self.snapshot = snapshot }
  func load() -> LibrarySnapshot { snapshot }
  func failNextSave() { shouldFail = true }
  func save(_ snapshot: LibrarySnapshot) throws {
    if shouldFail {
      shouldFail = false
      throw PlayerCoreError.fileOperation("Injected metadata save failure")
    }
    self.snapshot = snapshot
  }
}

private actor MetadataGatedStore: LibraryPersisting {
  private var snapshot: LibrarySnapshot
  private var saveStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  init(snapshot: LibrarySnapshot) { self.snapshot = snapshot }
  func load() -> LibrarySnapshot { snapshot }
  func waitUntilSaveStarts() async {
    guard !saveStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }
  func releaseSave() { releaseContinuation?.resume(); releaseContinuation = nil }
  func save(_ snapshot: LibrarySnapshot) async {
    saveStarted = true
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    await withCheckedContinuation { releaseContinuation = $0 }
    self.snapshot = snapshot
  }
}

private actor MetadataBuildGate {
  private var blocked = false
  private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func blockUntilReleased() async {
    blocked = true
    blockedWaiters.forEach { $0.resume() }
    blockedWaiters.removeAll()
    await withCheckedContinuation { releaseContinuation = $0 }
  }

  func waitUntilBlocked() async {
    guard !blocked else { return }
    await withCheckedContinuation { blockedWaiters.append($0) }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
