import Foundation
import XCTest
@testable import Player

@MainActor
final class TrashDeletionTests: XCTestCase {
  func testPermanentDeletionPurgesOnlySelectedManagedMediaAndRecoveryPayload() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let playback = DeterministicPlaybackController()
    let nowPlaying = DeterministicNowPlayingPublisher()
    let model = makeModel(fixture: fixture, playback: playback, nowPlaying: nowPlaying)
    await model.restore()
    await model.play(bookID: fixture.selected.id)
    XCTAssertEqual(playback.state.loadedBookID, fixture.selected.id)

    let removedID = await model.removeBook(
      bookID: fixture.selected.id,
      mediaPolicy: .moveManagedMediaToTrash
    )
    let transactionID = try XCTUnwrap(removedID)
    XCTAssertNil(playback.state.loadedBookID)
    XCTAssertNil(playback.loadedURL)
    XCTAssertGreaterThan(nowPlaying.clearCount, 0)

    let deleted = await model.clearRecoverableStorage(scope: .trashTransaction(transactionID))
    XCTAssertTrue(deleted)
    let tombstone = try XCTUnwrap(model.library.trashTransactions.first)
    XCTAssertEqual(tombstone.status, .purged)
    XCTAssertEqual(tombstone.purgedBookID, fixture.selected.id)
    XCTAssertNil(tombstone.book)
    XCTAssertNil(tombstone.mediaManifest)
    XCTAssertTrue(tombstone.positionEvents.isEmpty)
    XCTAssertTrue(tombstone.metadataTransactions.isEmpty)
    XCTAssertFalse(model.library.bookmarks.contains { $0.bookID == fixture.selected.id })
    XCTAssertFalse(model.library.resumeRewindTransactions.contains { $0.bookID == fixture.selected.id })
    XCTAssertNil(model.library.activeSleepTimer)
    XCTAssertEqual(model.storageSummary?.trashBytes, 0)
    XCTAssertEqual(model.storageSummary?.managedMediaBytes, Int64(fixture.siblingBytes.count))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.selectedMedia.path))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: fixture.storage.appending(path: "Trash/\(transactionID.uuidString.lowercased())").path
    ))
    XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.siblingMedia), fixture.siblingBytes)

    let relaunched = makeModel(fixture: fixture, playback: DeterministicPlaybackController())
    await relaunched.restore()
    XCTAssertTrue(relaunched.isRestored)
    XCTAssertEqual(relaunched.library.trashTransactions.first?.status, .purged)
    let restoredAfterPurge = await relaunched.restoreTrashedBook(transactionID: transactionID)
    XCTAssertFalse(restoredAfterPurge)
    XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.siblingMedia), fixture.siblingBytes)
  }

  func testMissingAndNonrecoverableTransactionsDoNotMutateStorage() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let model = makeModel(fixture: fixture, playback: DeterministicPlaybackController())
    await model.restore()
    let missing = UUID(uuidString: "60000000-0000-0000-0000-000000000099")!
    let deletedMissing = await model.clearRecoverableStorage(scope: .trashTransaction(missing))
    XCTAssertFalse(deletedMissing)
    XCTAssertEqual(try Data(contentsOf: fixture.selectedMedia), fixture.selectedBytes)

    let removedID = await model.removeBook(
      bookID: fixture.selected.id,
      mediaPolicy: .moveManagedMediaToTrash
    )
    let transactionID = try XCTUnwrap(removedID)
    let restored = await model.restoreTrashedBook(transactionID: transactionID)
    XCTAssertTrue(restored)
    let deletedRestored = await model.clearRecoverableStorage(scope: .trashTransaction(transactionID))
    XCTAssertFalse(deletedRestored)
    XCTAssertEqual(try Data(contentsOf: fixture.selectedMedia), fixture.selectedBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.siblingMedia), fixture.siblingBytes)
  }

  func testCatalogCommitFailureRollsPreparedMediaBackByteIdentically() async throws {
    let fixture = try makeFixture(failingStore: true)
    defer { fixture.remove() }
    let store = try XCTUnwrap(fixture.store as? FailingTrashStore)
    let model = makeModel(fixture: fixture, playback: DeterministicPlaybackController())
    await model.restore()
    let removedID = await model.removeBook(
      bookID: fixture.selected.id,
      mediaPolicy: .moveManagedMediaToTrash
    )
    let transactionID = try XCTUnwrap(removedID)
    await store.failPurgedSave()

    let deleted = await model.clearRecoverableStorage(scope: .trashTransaction(transactionID))
    XCTAssertFalse(deleted)
    XCTAssertEqual(model.library.trashTransactions.first?.status, .recoverable)
    let trashMedia = fixture.storage.appending(
      path: "Trash/\(transactionID.uuidString.lowercased())/Media/"
        + fixture.selected.id.uuidString.lowercased() + "/book.m4b"
    )
    XCTAssertEqual(try Data(contentsOf: trashMedia), fixture.selectedBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.siblingMedia), fixture.siblingBytes)
  }

  func testPurgingIntentPersistenceFailureDoesNotTouchFilesystem() async throws {
    let fixture = try makeFixture(failingStore: true)
    defer { fixture.remove() }
    let store = try XCTUnwrap(fixture.store as? FailingTrashStore)
    let model = makeModel(fixture: fixture, playback: DeterministicPlaybackController())
    await model.restore()
    let removedID = await model.removeBook(
      bookID: fixture.selected.id,
      mediaPolicy: .moveManagedMediaToTrash
    )
    let transactionID = try XCTUnwrap(removedID)
    await store.failPurgingSave()

    let deleted = await model.clearRecoverableStorage(scope: .trashTransaction(transactionID))
    XCTAssertFalse(deleted)
    XCTAssertEqual(model.library.trashTransactions.first?.status, .recoverable)
    let trashMedia = fixture.storage.appending(
      path: "Trash/\(transactionID.uuidString.lowercased())/Media/"
        + fixture.selected.id.uuidString.lowercased() + "/book.m4b"
    )
    XCTAssertEqual(try Data(contentsOf: trashMedia), fixture.selectedBytes)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: fixture.storage.appending(path: "PendingTrashDeletion/"
        + transactionID.uuidString.lowercased()).path
    ))
  }

  func testPrepareFailureRestoresRecoverableCatalogWithoutMovingBytes() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let media = FaultMediaManager(
      base: FileSystemMediaManager(rootURL: fixture.storage),
      failPrepare: true
    )
    let model = makeModel(
      fixture: fixture,
      playback: DeterministicPlaybackController(),
      media: media
    )
    await model.restore()
    let removedID = await model.removeBook(
      bookID: fixture.selected.id,
      mediaPolicy: .moveManagedMediaToTrash
    )
    let transactionID = try XCTUnwrap(removedID)

    let deleted = await model.clearRecoverableStorage(scope: .trashTransaction(transactionID))
    XCTAssertFalse(deleted)
    XCTAssertEqual(model.library.trashTransactions.first?.status, .recoverable)
    let trashMedia = fixture.storage.appending(
      path: "Trash/\(transactionID.uuidString.lowercased())/Media/"
        + fixture.selected.id.uuidString.lowercased() + "/book.m4b"
    )
    XCTAssertEqual(try Data(contentsOf: trashMedia), fixture.selectedBytes)
  }

  func testRestoreCannotRacePermanentDeletionPastSingleFlightGuard() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let media = FaultMediaManager(
      base: FileSystemMediaManager(rootURL: fixture.storage),
      blockPrepare: true
    )
    let model = makeModel(
      fixture: fixture,
      playback: DeterministicPlaybackController(),
      media: media
    )
    await model.restore()
    let removedID = await model.removeBook(
      bookID: fixture.selected.id,
      mediaPolicy: .moveManagedMediaToTrash
    )
    let transactionID = try XCTUnwrap(removedID)

    let deletionTask = Task { @MainActor in
      await model.clearRecoverableStorage(scope: .trashTransaction(transactionID))
    }
    await media.waitUntilPrepareStarted()
    let racedRestore = await model.restoreTrashedBook(transactionID: transactionID)
    XCTAssertFalse(racedRestore)
    await media.releasePrepare()
    let deleted = await deletionTask.value
    XCTAssertTrue(deleted)
    XCTAssertEqual(model.library.trashTransactions.first?.status, .purged)
  }

  func testRollbackFailureLeavesDurablePurgingIntentThatRelaunchRecovers() async throws {
    let fixture = try makeFixture(failingStore: true)
    defer { fixture.remove() }
    let store = try XCTUnwrap(fixture.store as? FailingTrashStore)
    let media = FaultMediaManager(
      base: FileSystemMediaManager(rootURL: fixture.storage),
      failRollback: true
    )
    let model = makeModel(
      fixture: fixture,
      playback: DeterministicPlaybackController(),
      media: media
    )
    await model.restore()
    let removedID = await model.removeBook(
      bookID: fixture.selected.id,
      mediaPolicy: .moveManagedMediaToTrash
    )
    let transactionID = try XCTUnwrap(removedID)
    await store.failPurgedSave()

    let deleted = await model.clearRecoverableStorage(scope: .trashTransaction(transactionID))
    XCTAssertFalse(deleted)
    XCTAssertEqual(model.library.trashTransactions.first?.status, .purging)

    let relaunched = makeModel(fixture: fixture, playback: DeterministicPlaybackController())
    await relaunched.restore()
    XCTAssertTrue(relaunched.isRestored)
    XCTAssertEqual(relaunched.library.trashTransactions.first?.status, .recoverable)
    let manifest = try XCTUnwrap(relaunched.library.trashTransactions.first?.mediaManifest)
    let trashMedia = fixture.storage.appending(path: manifest.trashDirectoryRelativePath + "/book.m4b")
    XCTAssertEqual(try Data(contentsOf: trashMedia), fixture.selectedBytes)
  }

  func testRetainedMediaPermanentDeletionIsConfinedToSelectedBook() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let model = makeModel(fixture: fixture, playback: DeterministicPlaybackController())
    await model.restore()
    let removedID = await model.removeBook(
      bookID: fixture.selected.id,
      mediaPolicy: .retainManagedMedia
    )
    let transactionID = try XCTUnwrap(removedID)
    XCTAssertEqual(try Data(contentsOf: fixture.selectedMedia), fixture.selectedBytes)

    let deleted = await model.clearRecoverableStorage(scope: .trashTransaction(transactionID))
    XCTAssertTrue(deleted)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.selectedMedia.path))
    XCTAssertEqual(try Data(contentsOf: fixture.siblingMedia), fixture.siblingBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
  }

  func testRetainedMediaSurvivesRelaunchAndCanBeRestored() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let model = makeModel(fixture: fixture, playback: DeterministicPlaybackController())
    await model.restore()
    let removedID = await model.removeBook(
      bookID: fixture.selected.id,
      mediaPolicy: .retainManagedMedia
    )
    let transactionID = try XCTUnwrap(removedID)

    let relaunched = makeModel(fixture: fixture, playback: DeterministicPlaybackController())
    await relaunched.restore()
    XCTAssertTrue(relaunched.isRestored)
    XCTAssertEqual(try Data(contentsOf: fixture.selectedMedia), fixture.selectedBytes)
    let restored = await relaunched.restoreTrashedBook(transactionID: transactionID)
    XCTAssertTrue(restored)
    XCTAssertEqual(relaunched.library.books.map(\.id).sorted { $0.uuidString < $1.uuidString }, [
      fixture.selected.id, fixture.sibling.id,
    ])
  }

  func testMissingRecoverableTrashFromStaleBackupFailsStartupWithoutTouchingSibling() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let media: any MediaManaging = FileSystemMediaManager(rootURL: fixture.storage)
    let transactionID = UUID(uuidString: "60000000-0000-0000-0000-000000000081")!
    let manifest = TrashedMediaManifest(
      transactionID: transactionID,
      bookID: fixture.selected.id,
      originalDirectoryRelativePath: "Media/\(fixture.selected.id.uuidString.lowercased())",
      trashDirectoryRelativePath: "Trash/\(transactionID.uuidString.lowercased())/Media/"
        + fixture.selected.id.uuidString.lowercased(),
      byteCount: Int64(fixture.selectedBytes.count)
    )
    let staleBackup = snapshotForTrash(
      fixture: fixture,
      transactionID: transactionID,
      manifest: manifest
    )

    do {
      _ = try await media.reconcileStartupStorage(with: staleBackup)
      XCTFail("Expected stale missing Trash media to fail startup reconciliation.")
    } catch {
      // Preserving the catalog evidence and entering startup recovery is safer
      // than falsely advertising Restore for bytes that no longer exist.
    }
    XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.siblingMedia), fixture.siblingBytes)
  }

  func testRecoverableStatusCannotDecodeAsPurgedIDOnlyPayloadAtStartup() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let media: any MediaManaging = FileSystemMediaManager(rootURL: fixture.storage)
    let transactionID = UUID(uuidString: "60000000-0000-0000-0000-000000000083")!
    let manifest = try await media.moveManagedMediaToTrash(
      bookID: fixture.selected.id,
      transactionID: transactionID
    )
    var corrupt = snapshotForTrash(
      fixture: fixture,
      transactionID: transactionID,
      manifest: manifest
    )
    corrupt.trashTransactions[0].finishPurging(at: .distantPast)
    corrupt.trashTransactions[0].status = .recoverable
    let decoded = try JSONDecoder().decode(
      LibrarySnapshot.self,
      from: JSONEncoder().encode(corrupt)
    )
    XCTAssertNil(decoded.trashTransactions.first?.book)

    do {
      _ = try await media.reconcileStartupStorage(with: decoded)
      XCTFail("Expected a recoverable ID-only tombstone to fail startup validation.")
    } catch {
      // Expected; the app must not expose a Restore action without recovery data.
    }
    XCTAssertEqual(try Data(contentsOf: fixture.siblingMedia), fixture.siblingBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
  }

  func testUnknownPendingDeletionDirectoryIsQuarantined() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let unknownID = UUID(uuidString: "60000000-0000-0000-0000-000000000082")!
    let pending = fixture.storage.appending(
      path: "PendingTrashDeletion/\(unknownID.uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
    try Data("unknown-journal".utf8).write(to: pending.appending(path: "journal.json"))
    let media: any MediaManaging = FileSystemMediaManager(rootURL: fixture.storage)

    let result = try await media.reconcileStartupStorage(with: LibrarySnapshot(
      books: [fixture.selected, fixture.sibling],
      importJobs: [],
      currentBookID: nil
    ))
    XCTAssertEqual(result.quarantinedTrashTransactionCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    XCTAssertEqual(try Data(contentsOf: fixture.selectedMedia), fixture.selectedBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.siblingMedia), fixture.siblingBytes)
  }

  func testManifestMustAgreeWithTransactionBookAndCanonicalPaths() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let media: any MediaManaging = FileSystemMediaManager(rootURL: fixture.storage)
    let transactionID = UUID(uuidString: "60000000-0000-0000-0000-000000000077")!
    let manifest = try await media.moveManagedMediaToTrash(
      bookID: fixture.selected.id,
      transactionID: transactionID
    )
    var forged = manifest
    forged.originalDirectoryRelativePath = "Media/../Source"

    do {
      _ = try await media.preparePermanentTrashDeletion(
        transactionID: transactionID,
        bookID: fixture.selected.id,
        mediaPolicy: .moveManagedMediaToTrash,
        manifest: forged
      )
      XCTFail("Expected forged manifest to be rejected.")
    } catch {
      // Expected.
    }
    XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.siblingMedia), fixture.siblingBytes)
  }

  func testStartupCancelsJournalCreatedBeforePayloadMove() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let media: any MediaManaging = FileSystemMediaManager(rootURL: fixture.storage)
    let transactionID = UUID(uuidString: "60000000-0000-0000-0000-000000000078")!
    let manifest = try await media.moveManagedMediaToTrash(
      bookID: fixture.selected.id,
      transactionID: transactionID
    )
    var snapshot = snapshotForTrash(fixture: fixture, transactionID: transactionID, manifest: manifest)
    snapshot.trashTransactions[0].beginPurging(at: .distantPast)
    let pending = fixture.storage.appending(
      path: "PendingTrashDeletion/\(transactionID.uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
    let deletion = PreparedTrashDeletion(
      transactionID: transactionID,
      bookID: fixture.selected.id,
      originalDirectoryRelativePath: "Trash/\(transactionID.uuidString.lowercased())",
      pendingDirectoryRelativePath:
        "PendingTrashDeletion/\(transactionID.uuidString.lowercased())/Payload"
    )
    try JSONEncoder().encode(deletion).write(to: pending.appending(path: "journal.json"))

    let result = try await media.reconcileStartupStorage(with: snapshot)
    XCTAssertEqual(result.library.trashTransactions.first?.status, .recoverable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    let trashedMedia = fixture.storage.appending(path: manifest.trashDirectoryRelativePath + "/book.m4b")
    XCTAssertEqual(try Data(contentsOf: trashedMedia), fixture.selectedBytes)
  }

  func testStartupRollsPreparedUncommittedDeletionBack() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let media: any MediaManaging = FileSystemMediaManager(rootURL: fixture.storage)
    let transactionID = UUID(uuidString: "60000000-0000-0000-0000-000000000079")!
    let manifest = try await media.moveManagedMediaToTrash(
      bookID: fixture.selected.id,
      transactionID: transactionID
    )
    var snapshot = snapshotForTrash(fixture: fixture, transactionID: transactionID, manifest: manifest)
    snapshot.trashTransactions[0].beginPurging(at: .distantPast)
    _ = try await media.preparePermanentTrashDeletion(
      transactionID: transactionID,
      bookID: fixture.selected.id,
      mediaPolicy: .moveManagedMediaToTrash,
      manifest: manifest
    )

    let result = try await media.reconcileStartupStorage(with: snapshot)
    XCTAssertEqual(result.library.trashTransactions.first?.status, .recoverable)
    let trashedMedia = fixture.storage.appending(path: manifest.trashDirectoryRelativePath + "/book.m4b")
    XCTAssertEqual(try Data(contentsOf: trashedMedia), fixture.selectedBytes)
  }

  func testStartupFinishesCommittedDeletionEvenWithPartiallyRemovedJournal() async throws {
    let fixture = try makeFixture()
    defer { fixture.remove() }
    let media: any MediaManaging = FileSystemMediaManager(rootURL: fixture.storage)
    let transactionID = UUID(uuidString: "60000000-0000-0000-0000-000000000080")!
    let manifest = try await media.moveManagedMediaToTrash(
      bookID: fixture.selected.id,
      transactionID: transactionID
    )
    var snapshot = snapshotForTrash(fixture: fixture, transactionID: transactionID, manifest: manifest)
    snapshot.trashTransactions[0].beginPurging(at: .distantPast)
    _ = try await media.preparePermanentTrashDeletion(
      transactionID: transactionID,
      bookID: fixture.selected.id,
      mediaPolicy: .moveManagedMediaToTrash,
      manifest: manifest
    )
    snapshot.trashTransactions[0].finishPurging(at: .distantPast)
    let pending = fixture.storage.appending(
      path: "PendingTrashDeletion/\(transactionID.uuidString.lowercased())"
    )
    try FileManager.default.removeItem(at: pending.appending(path: "journal.json"))

    let result = try await media.reconcileStartupStorage(with: snapshot)
    XCTAssertEqual(result.library.trashTransactions.first?.status, .purged)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    XCTAssertEqual(try Data(contentsOf: fixture.siblingMedia), fixture.siblingBytes)
  }

  private func makeFixture(failingStore: Bool = false) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "TrashDeletionTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let storage = root.appending(path: "Storage", directoryHint: .isDirectory)
    let source = root.appending(path: "Source/book.m4b")
    let selected = makeBook(id: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!)
    let sibling = makeBook(id: UUID(uuidString: "60000000-0000-0000-0000-000000000002")!)
    let selectedMedia = storage.appending(path: selected.assets[0].managedRelativePath)
    let siblingMedia = storage.appending(path: sibling.assets[0].managedRelativePath)
    let sourceBytes = Data("external-source-must-not-change".utf8)
    let selectedBytes = Data("selected-managed-audio".utf8)
    let siblingBytes = Data("sibling-managed-audio".utf8)
    for file in [source, selectedMedia, siblingMedia] {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }
    try sourceBytes.write(to: source)
    try selectedBytes.write(to: selectedMedia)
    try siblingBytes.write(to: siblingMedia)
    let initial = LibrarySnapshot(
      books: [selected, sibling],
      importJobs: [],
      currentBookID: selected.id,
      resumeRewindTransactions: [ResumeRewindTransaction(
        id: UUID(uuidString: "60000000-0000-0000-0000-000000000010")!,
        plan: SmartRewindPlan(
          bookID: selected.id,
          pausedAt: .distantPast,
          resumedAt: .distantPast,
          secondsAway: 60,
          originalPositionMilliseconds: 10_000,
          targetPositionMilliseconds: 5_000,
          rewindMilliseconds: 5_000,
          chapterStartMilliseconds: nil,
          crossedRecentChapterStart: false,
          wasClampedToChapterStart: false
        ),
        preRewindEventID: UUID(uuidString: "60000000-0000-0000-0000-000000000011")!,
        rewindEventID: UUID(uuidString: "60000000-0000-0000-0000-000000000012")!,
        status: .applied,
        undoneAt: nil,
        undoEventID: nil
      )],
      activeSleepTimer: ActiveSleepTimer(
        id: UUID(uuidString: "60000000-0000-0000-0000-000000000013")!,
        bookID: selected.id,
        selection: .custom(durationSeconds: 60),
        fadeEnabled: true,
        startedAt: .distantPast,
        deadline: .distantFuture,
        boundaryPositionMilliseconds: nil,
        startedPositionMilliseconds: 0,
        phase: .active
      ),
      bookmarks: [Bookmark(
        id: UUID(uuidString: "60000000-0000-0000-0000-000000000014")!,
        bookID: selected.id,
        bookPositionMilliseconds: 1_000,
        assetID: selected.id,
        assetPositionMilliseconds: 1_000,
        chapterID: nil,
        chapterTitleSnapshot: nil,
        label: "Selected bookmark",
        note: nil,
        createdAt: .distantPast,
        updatedAt: .distantPast
      )]
    )
    let resolvedStore: any LibraryPersisting = failingStore
      ? FailingTrashStore(snapshot: initial)
      : InMemoryLibraryStore(snapshot: initial)
    return Fixture(
      root: root,
      storage: storage,
      source: source,
      sourceBytes: sourceBytes,
      selected: selected,
      selectedMedia: selectedMedia,
      selectedBytes: selectedBytes,
      sibling: sibling,
      siblingMedia: siblingMedia,
      siblingBytes: siblingBytes,
      store: resolvedStore
    )
  }

  private func makeModel(
    fixture: Fixture,
    playback: DeterministicPlaybackController,
    nowPlaying: DeterministicNowPlayingPublisher = DeterministicNowPlayingPublisher(),
    media: (any MediaManaging)? = nil
  ) -> PlayerModel {
    PlayerModel(environment: PlayerEnvironment(
      persistence: fixture.store,
      media: media ?? FileSystemMediaManager(rootURL: fixture.storage),
      inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
      playback: playback,
      nowPlaying: nowPlaying,
      clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 2_000_000_000)),
      ids: DeterministicPlayerIDGenerator(values: (50...99).map {
        UUID(uuidString: String(format: "60000000-0000-0000-0000-%012d", $0))!
      })
    ))
  }

  private func snapshotForTrash(
    fixture: Fixture,
    transactionID: UUID,
    manifest: TrashedMediaManifest
  ) -> LibrarySnapshot {
    LibrarySnapshot(
      books: [fixture.sibling],
      importJobs: [],
      currentBookID: nil,
      trashTransactions: [LibraryTrashTransaction(
        id: transactionID,
        book: fixture.selected,
        originalBookIndex: 0,
        mediaPolicy: .moveManagedMediaToTrash,
        mediaManifest: manifest,
        upNextIndex: nil,
        collectionPlacements: [],
        wasCurrentBook: false,
        playbackPosition: nil,
        positionEvents: [],
        metadataTransactions: [],
        removedAt: .distantPast,
        status: .recoverable,
        restoredAt: nil
      )]
    )
  }

  private func makeBook(id: UUID) -> Book {
    Book(
      id: id,
      title: id.uuidString,
      authors: ["Author"],
      durationSeconds: 60,
      artworkData: nil,
      assets: [AudioAsset(
        id: id,
        originalFilename: "book.m4b",
        managedRelativePath: "Media/\(id.uuidString.lowercased())/book.m4b",
        checksumSHA256: "fixture",
        byteCount: 32,
        durationSeconds: 60,
        container: "M4B"
      )],
      dateAdded: .distantPast
    )
  }
}

private struct Fixture {
  let root: URL
  let storage: URL
  let source: URL
  let sourceBytes: Data
  let selected: Book
  let selectedMedia: URL
  let selectedBytes: Data
  let sibling: Book
  let siblingMedia: URL
  let siblingBytes: Data
  let store: any LibraryPersisting

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor FailingTrashStore: LibraryPersisting {
  private var snapshot: LibrarySnapshot
  private var rejectsPurged = false
  private var rejectsPurging = false

  init(snapshot: LibrarySnapshot) { self.snapshot = snapshot }

  func load() -> LibrarySnapshot { snapshot }

  func save(_ snapshot: LibrarySnapshot) throws {
    if rejectsPurging && snapshot.trashTransactions.contains(where: { $0.status == .purging }) {
      rejectsPurging = false
      throw PlayerCoreError.fileOperation("Injected purge-intent failure.")
    }
    if rejectsPurged && snapshot.trashTransactions.contains(where: { $0.status == .purged }) {
      rejectsPurged = false
      throw PlayerCoreError.fileOperation("Injected catalog commit failure.")
    }
    self.snapshot = snapshot
  }

  func failPurgedSave() { rejectsPurged = true }
  func failPurgingSave() { rejectsPurging = true }
}

private actor FaultMediaManager: MediaManaging {
  let base: FileSystemMediaManager
  let failPrepare: Bool
  let failRollback: Bool
  let blockPrepare: Bool
  private var prepareStarted = false
  private var prepareStartedWaiters: [CheckedContinuation<Void, Never>] = []
  private var prepareRelease: CheckedContinuation<Void, Never>?
  private var delegate: any MediaManaging { base }

  init(
    base: FileSystemMediaManager,
    failPrepare: Bool = false,
    failRollback: Bool = false,
    blockPrepare: Bool = false
  ) {
    self.base = base
    self.failPrepare = failPrepare
    self.failRollback = failRollback
    self.blockPrepare = blockPrepare
  }

  func stage(sourceURL: URL, jobID: UUID) async throws -> StagedAudio {
    try await delegate.stage(sourceURL: sourceURL, jobID: jobID)
  }
  func stagedURL(for relativePath: String) async throws -> URL {
    try await delegate.stagedURL(for: relativePath)
  }
  func commit(_ staged: StagedAudio, bookID: UUID, assetID: UUID) async throws -> ManagedAudio {
    try await delegate.commit(staged, bookID: bookID, assetID: assetID)
  }
  func rollback(_ managed: ManagedAudio) async throws { try await delegate.rollback(managed) }
  func managedURL(for relativePath: String) async throws -> URL {
    try await delegate.managedURL(for: relativePath)
  }
  func discardStaging(for jobID: UUID) async { await delegate.discardStaging(for: jobID) }
  func moveManagedMediaToTrash(bookID: UUID, transactionID: UUID) async throws
    -> TrashedMediaManifest
  {
    try await delegate.moveManagedMediaToTrash(bookID: bookID, transactionID: transactionID)
  }
  func restoreManagedMediaFromTrash(_ manifest: TrashedMediaManifest) async throws {
    try await delegate.restoreManagedMediaFromTrash(manifest)
  }
  func preparePermanentTrashDeletion(
    transactionID: UUID,
    bookID: UUID,
    mediaPolicy: LibraryRemovalMediaPolicy,
    manifest: TrashedMediaManifest?
  ) async throws -> PreparedTrashDeletion {
    if failPrepare { throw PlayerCoreError.fileOperation("Injected prepare failure.") }
    prepareStarted = true
    prepareStartedWaiters.forEach { $0.resume() }
    prepareStartedWaiters = []
    if blockPrepare {
      await withCheckedContinuation { continuation in
        prepareRelease = continuation
      }
    }
    return try await delegate.preparePermanentTrashDeletion(
      transactionID: transactionID,
      bookID: bookID,
      mediaPolicy: mediaPolicy,
      manifest: manifest
    )
  }
  func waitUntilPrepareStarted() async {
    if prepareStarted { return }
    await withCheckedContinuation { continuation in
      prepareStartedWaiters.append(continuation)
    }
  }
  func releasePrepare() {
    prepareRelease?.resume()
    prepareRelease = nil
  }
  func commitPermanentTrashDeletion(_ deletion: PreparedTrashDeletion) async throws {
    try await delegate.commitPermanentTrashDeletion(deletion)
  }
  func rollbackPermanentTrashDeletion(_ deletion: PreparedTrashDeletion) async throws {
    if failRollback { throw PlayerCoreError.fileOperation("Injected rollback failure.") }
    try await delegate.rollbackPermanentTrashDeletion(deletion)
  }
  func storageInventory() async throws -> StorageInventorySnapshot {
    try await delegate.storageInventory()
  }
  func discardStagedFile(relativePath: String) async throws {
    try await delegate.discardStagedFile(relativePath: relativePath)
  }
  func discardStorage(scope: StorageScope) async throws {
    try await delegate.discardStorage(scope: scope)
  }
  func reconcileStartupStorage(with library: LibrarySnapshot) async throws
    -> StartupStorageReconciliation
  {
    try await delegate.reconcileStartupStorage(with: library)
  }
}
