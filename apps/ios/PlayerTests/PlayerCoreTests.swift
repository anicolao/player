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
    model.pause()
    XCTAssertEqual(model.playbackState.status, .paused)
  }

  func testVersionedStoreRoundTripsSchemaOne() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "PlayerStoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CodableLibraryStore(fileURL: directory.appending(path: "Library.json"))

    try await store.save(.empty)

    let restored = try await store.load()
    XCTAssertEqual(restored, .empty)
    let data = try Data(contentsOf: directory.appending(path: "Library.json"))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["schemaVersion"] as? Int, 1)
  }

  private func checksum(_ url: URL) throws -> String {
    let digest = SHA256.hash(data: try Data(contentsOf: url))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
