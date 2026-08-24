import XCTest

@testable import Player

@MainActor
final class MVPScaleTests: XCTestCase {
  func testReadyStateStartupMeetsOneAndTenThousandRecordBudgets() async throws {
    for (recordCount, budget) in [(1_000, Duration.seconds(1)), (10_000, .seconds(2))] {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerStartupScale-\(recordCount)-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      defer { try? FileManager.default.removeItem(at: root) }
      let store = CodableLibraryStore(fileURL: root.appending(path: "Library.json"))
      let books = (0..<recordCount).map(makeScaleBook)
      try await store.save(LibrarySnapshot(books: books, importJobs: [], currentBookID: nil))
      let model = PlayerModel(environment: PlayerEnvironment(
        persistence: store,
        media: ScaleMediaManager(),
        inspector: ScaleUnusedInspector(),
        playback: ScalePlaybackController()
      ))

      let start = ContinuousClock.now
      await model.restore()
      let elapsed = start.duration(to: .now)

      XCTAssertTrue(model.isRestored)
      XCTAssertEqual(model.library.books.count, recordCount)
      XCTAssertLessThan(
        elapsed,
        budget,
        "A durable \(recordCount)-record library must reach the ready state within \(budget)."
      )
    }
  }

  func testMultiGigabyteImportAndBackupStreamsStayWithinOneMiB() throws {
    let simulatedByteCount = Int64(2) * 1_024 * 1_024 * 1_024 + 17
    var importRemaining = simulatedByteCount
    var importMaximumRead = 0
    var importMaximumWrite = 0
    var importedByteCount: Int64 = 0
    let importDigest = try StreamingFileIO.copyAndHash(
      read: { requested in
        importMaximumRead = max(importMaximumRead, requested)
        guard importRemaining > 0 else { return nil }
        let count = min(requested, Int(importRemaining))
        importRemaining -= Int64(count)
        return Data(repeating: 0x5a, count: count)
      },
      write: { chunk in
        importMaximumWrite = max(importMaximumWrite, chunk.count)
        importedByteCount += Int64(chunk.count)
      }
    )

    var backupRemaining = simulatedByteCount
    var backupMaximumRead = 0
    let backupDigest = try StreamingFileIO.hash { requested in
      backupMaximumRead = max(backupMaximumRead, requested)
      guard backupRemaining > 0 else { return nil }
      let count = min(requested, Int(backupRemaining))
      backupRemaining -= Int64(count)
      return Data(repeating: 0x5a, count: count)
    }

    XCTAssertEqual(importDigest.byteCount, simulatedByteCount)
    XCTAssertEqual(importedByteCount, simulatedByteCount)
    XCTAssertEqual(backupDigest, importDigest)
    XCTAssertLessThanOrEqual(importMaximumRead, StreamingFileIO.maximumChunkByteCount)
    XCTAssertLessThanOrEqual(importMaximumWrite, StreamingFileIO.maximumChunkByteCount)
    XCTAssertLessThanOrEqual(backupMaximumRead, StreamingFileIO.maximumChunkByteCount)
  }

  func testEveryCommittedSchemaFixtureMigratesAndRoundTrips() async throws {
    let fixtures = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "Schemas", withExtension: nil)
    )
    for version in 1...CodableLibraryStore.currentSchemaVersion {
      let name = String(format: "library-v%02d.json", version)
      let source = fixtures.appending(path: name)
      XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Missing \(name)")
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerSchemaFixture-\(version)-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let destination = root.appending(path: "Library.json")
      try FileManager.default.copyItem(at: source, to: destination)
      let store = CodableLibraryStore(fileURL: destination)

      let migrated = try await store.load()
      XCTAssertEqual(migrated, .empty, "Schema v\(version) did not migrate deterministically")
      try await store.save(migrated)
      let roundTripped = try await store.load()
      XCTAssertEqual(roundTripped, migrated, "Schema v\(version) did not round trip")
      let envelope = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
      )
      XCTAssertEqual(envelope["schemaVersion"] as? Int, CodableLibraryStore.currentSchemaVersion)
    }
  }

  private func makeScaleBook(_ index: Int) -> Book {
    let id = UUID(uuidString: String(format: "c0000000-0000-0000-0000-%012d", index + 1))!
    return Book(
      id: id,
      title: "Scale Volume \(index)",
      authors: ["Author \(index % 250)"],
      durationSeconds: 3_600,
      artworkData: nil,
      assets: [],
      dateAdded: Date(timeIntervalSince1970: TimeInterval(index))
    )
  }
}

private actor ScaleMediaManager: MediaManaging {
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

private struct ScaleUnusedInspector: AudioInspecting {
  func inspect(url: URL) async throws -> InspectedAudio {
    throw PlayerCoreError.unreadableAudio("unused")
  }
}

@MainActor
private final class ScalePlaybackController: AudioPlaybackControlling {
  private(set) var state = PlaybackState.unloaded
  private(set) var currentPositionSeconds = 0.0
  func load(url: URL, bookID: UUID, at seconds: Double) async throws {}
  func play() { state.status = .playing }
  func pause() { state.status = .paused }
  func seek(to seconds: Double) async { currentPositionSeconds = seconds }
}
