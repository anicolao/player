import CryptoKit
import XCTest
@testable import Player

@MainActor
final class PlayerCoreTests: XCTestCase {
  func testRealImporterCommitsImmutableCopyAndLoadsPlayback() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appending(
      path: "PlayerCoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let bundled = try XCTUnwrap(
      Bundle(for: PlayerCoreTests.self).url(forResource: "01-opening-tone", withExtension: "m4a")
    )
    let source = temporaryRoot.appending(path: "source.m4a")
    try FileManager.default.copyItem(at: bundled, to: source)
    let sourceBefore = try checksum(source)
    let storageRoot = temporaryRoot.appending(path: "Storage", directoryHint: .isDirectory)
    let media = FileSystemMediaManager(rootURL: storageRoot)
    let playback = DeterministicPlaybackController()
    let ids = [
      "20000000-0000-0000-0000-000000000001",
      "20000000-0000-0000-0000-000000000002",
      "20000000-0000-0000-0000-000000000003",
      "20000000-0000-0000-0000-000000000004",
      "20000000-0000-0000-0000-000000000005",
      "20000000-0000-0000-0000-000000000006",
    ].map { UUID(uuidString: $0)! }
    let model = PlayerModel(
      environment: PlayerEnvironment(
        persistence: InMemoryLibraryStore(),
        media: media,
        inspector: AVFoundationAudioInspector(),
        playback: playback,
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    )

    await model.restore()
    let importedJobID = await model.importAudio(from: source)
    let jobID = try XCTUnwrap(importedJobID)
    let readyJob = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(readyJob.phase, .ready)
    XCTAssertEqual(readyJob.proposal?.durationSeconds ?? 0, 1.8, accuracy: 0.02)
    XCTAssertEqual(try checksum(source), sourceBefore, "The source must remain byte-identical")

    let committedBookID = await model.addImportToLibrary(jobID: jobID)
    let bookID = try XCTUnwrap(committedBookID)
    let book = try XCTUnwrap(model.library.books.first(where: { $0.id == bookID }))
    let asset = try XCTUnwrap(book.assets.first)
    let managedURL = try await media.managedURL(for: asset.managedRelativePath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
    XCTAssertEqual(try checksum(managedURL), sourceBefore)
    XCTAssertEqual(try checksum(source), sourceBefore)

    await model.play(bookID: bookID)
    XCTAssertEqual(model.playbackState.status, .playing)
    XCTAssertEqual(playback.loadedURL, managedURL)
    await model.pause()
    XCTAssertEqual(model.playbackState.status, .paused)
    XCTAssertEqual(model.library.positionJournal.map(\.reason), [.play, .pause])
  }

  func testVersionedStoreMigratesSchemaOneAndWritesSchemaTwo() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "PlayerStoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appending(path: "Library.json")
    let store = CodableLibraryStore(fileURL: fileURL)
    let versionOne = """
      {
        "schemaVersion": 1,
        "library": {
          "books": [],
          "importJobs": [],
          "currentBookID": null
        }
      }
      """
    try Data(versionOne.utf8).write(to: fileURL)

    let migrated = try await store.load()
    XCTAssertEqual(migrated, .empty)
    try await store.save(migrated)
    let data = try Data(contentsOf: fileURL)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["schemaVersion"] as? Int, 2)
  }

  func testSeekPauseAndInjectedAcknowledgementsAppendDurableEvents() async throws {
    let book = makeBook(duration: 120)
    let playback = DeterministicPlaybackController()
    let ids = (1...4).map {
      UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", $0))!
    }
    let model = PlayerModel(
      environment: PlayerEnvironment(
        persistence: InMemoryLibraryStore(
          snapshot: LibrarySnapshot(books: [book], importJobs: [], currentBookID: nil)
        ),
        media: StubMediaManager(),
        inspector: DeterministicAudioInspector(
          result: .failure(.unreadableAudio("unused"))
        ),
        playback: playback,
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    )

    await model.restore()
    await model.play(bookID: book.id)
    await model.seek(to: 42.9876)
    await model.pause()
    await model.acknowledgePlaybackPosition(43.4329, reason: .background)

    XCTAssertEqual(
      model.library.positionJournal.map(\.reason),
      [.play, .seek, .pause, .background]
    )
    XCTAssertEqual(model.library.positionJournal.map(\.sequence), [1, 2, 3, 4])
    XCTAssertEqual(model.library.playbackPosition?.positionMilliseconds, 43_432)
    XCTAssertEqual(model.playbackState.elapsedSeconds, 43.432, accuracy: 0.000_1)
  }

  func testRestoreUsesAcknowledgedPauseNeverAheadAndWithinTolerance() async throws {
    let book = makeBook(duration: 120)
    let eventID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    let acknowledged = 42.9876
    let event = PositionEvent.acknowledged(
      id: eventID,
      bookID: book.id,
      positionMilliseconds: Int64((acknowledged * 1_000).rounded(.down)),
      sequence: 1,
      reason: .pause,
      acknowledgedAt: Date(timeIntervalSince1970: 1_700_000_000),
      previousEventID: nil
    )
    let tornSnapshot = PlaybackPosition(
      bookID: book.id,
      positionMilliseconds: 90_000,
      sequence: 2,
      sourceEventID: UUID(),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let store = InMemoryLibraryStore(
      snapshot: LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: book.id,
        playbackPosition: tornSnapshot,
        positionJournal: [event]
      )
    )
    let model = PlayerModel(
      environment: PlayerEnvironment(
        persistence: store,
        media: StubMediaManager(),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        ids: DeterministicPlayerIDGenerator(values: [])
      )
    )

    await model.restore()

    let recovered = try XCTUnwrap(model.library.playbackPosition)
    XCTAssertLessThanOrEqual(recovered.seconds, acknowledged)
    XCTAssertLessThanOrEqual(acknowledged - recovered.seconds, 0.5)
    XCTAssertEqual(recovered.sourceEventID, eventID)
    XCTAssertEqual(model.playbackState.loadedBookID, book.id)
    XCTAssertEqual(model.playbackState.status, .paused)
  }

  func testRecoveryIgnoresTornLatestJournalEvent() throws {
    let book = makeBook(duration: 120)
    let first = PositionEvent.acknowledged(
      id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
      bookID: book.id,
      positionMilliseconds: 10_000,
      sequence: 1,
      reason: .periodic,
      acknowledgedAt: Date(timeIntervalSince1970: 1_700_000_000),
      previousEventID: nil
    )
    let second = PositionEvent.acknowledged(
      id: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
      bookID: book.id,
      positionMilliseconds: 20_000,
      sequence: 2,
      reason: .pause,
      acknowledgedAt: Date(timeIntervalSince1970: 1_700_000_001),
      previousEventID: first.id
    )
    var torn = PositionEvent.acknowledged(
      id: UUID(uuidString: "50000000-0000-0000-0000-000000000003")!,
      bookID: book.id,
      positionMilliseconds: 30_000,
      sequence: 3,
      reason: .periodic,
      acknowledgedAt: Date(timeIntervalSince1970: 1_700_000_002),
      previousEventID: second.id
    )
    torn.positionMilliseconds = 90_000
    let library = LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: book.id,
      playbackPosition: nil,
      positionJournal: [first, second, torn]
    )

    let recovered = try XCTUnwrap(PositionJournalRecovery.recover(from: library))
    XCTAssertEqual(recovered.sourceEventID, second.id)
    XCTAssertEqual(recovered.positionMilliseconds, 20_000)
  }

  func testPositionIntegritySurvivesStoreRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "PlayerPositionStoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CodableLibraryStore(fileURL: directory.appending(path: "Library.json"))
    let book = makeBook(duration: 120)
    let event = PositionEvent.acknowledged(
      id: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
      bookID: book.id,
      positionMilliseconds: 12_345,
      sequence: 1,
      reason: .pause,
      acknowledgedAt: Date(timeIntervalSince1970: 1_700_000_000.987),
      previousEventID: nil
    )
    let snapshot = LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: book.id,
      playbackPosition: PlaybackPosition(
        bookID: book.id,
        positionMilliseconds: event.positionMilliseconds,
        sequence: event.sequence,
        sourceEventID: event.id,
        updatedAt: event.acknowledgedAt
      ),
      positionJournal: [event]
    )

    try await store.save(snapshot)
    let loaded = try await store.load()

    XCTAssertTrue(try XCTUnwrap(loaded.positionJournal.first).hasValidIntegrity)
    XCTAssertEqual(PositionJournalRecovery.recover(from: loaded)?.positionMilliseconds, 12_345)
  }

  private func checksum(_ url: URL) throws -> String {
    let digest = SHA256.hash(data: try Data(contentsOf: url))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func makeBook(duration: Double) -> Book {
    let bookID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    return Book(
      id: bookID,
      title: "Position Test",
      authors: ["Fixture Author"],
      durationSeconds: duration,
      artworkData: nil,
      assets: [
        AudioAsset(
          id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
          originalFilename: "position-test.m4a",
          managedRelativePath: "Media/position-test.m4a",
          checksumSHA256: "fixture",
          byteCount: 1,
          durationSeconds: duration,
          container: "M4A"
        )
      ],
      dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }
}

private actor StubMediaManager: MediaManaging {
  func stage(sourceURL: URL, jobID: UUID) throws -> StagedAudio {
    throw PlayerCoreError.fileOperation("Unused in position tests.")
  }

  func stagedURL(for relativePath: String) throws -> URL {
    throw PlayerCoreError.fileOperation("Unused in position tests.")
  }

  func commit(_ staged: StagedAudio, bookID: UUID, assetID: UUID) throws -> ManagedAudio {
    throw PlayerCoreError.fileOperation("Unused in position tests.")
  }

  func rollback(_ managed: ManagedAudio) {}

  func managedURL(for relativePath: String) -> URL {
    URL(filePath: "/tmp/\(relativePath)")
  }

  func discardStaging(for jobID: UUID) {}
}
