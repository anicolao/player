import XCTest

@testable import Player

final class OfflineRecoveryTests: XCTestCase {
  func testCorruptPrimaryRestoresLatestValidCopyWithoutOverwritingEvidence() async throws {
    let root = temporaryDirectory("restore")
    defer { try? FileManager.default.removeItem(at: root) }
    let primary = root.appending(path: "Library.json")
    let store = CodableLibraryStore(fileURL: primary)
    let expected = LibrarySnapshot(
      books: [makeBook(id: uuid(1), title: "Recovered")],
      importJobs: [],
      currentBookID: nil
    )
    try await store.save(expected)
    let corruptBytes = Data("private corrupt catalog evidence".utf8)
    try corruptBytes.write(to: primary, options: .atomic)
    let backupDirectory = root.appending(path: "AutomaticBackups")
    try Data("invalid backup".utf8).write(
      to: backupDirectory.appending(path: "invalid.json")
    )

    let status = await store.startupRecoveryStatus()
    XCTAssertEqual(status.issue, .unreadableLibrary)
    XCTAssertEqual(status.validAutomaticBackupCount, 1)
    XCTAssertEqual(status.invalidAutomaticBackupCount, 1)

    let recovered = try await store.recoverLatestAutomaticBackupPreservingPrimary()
    XCTAssertEqual(recovered, expected)
    let durableRecovered = try await store.load()
    XCTAssertEqual(durableRecovered, expected)
    let quarantine = root.appending(path: "Recovery/Quarantine")
    let evidence = try FileManager.default.contentsOfDirectory(
      at: quarantine,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(evidence.count, 1)
    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(evidence.first)), corruptBytes)
  }

  func testFreshLibraryQuarantinesUnreadablePrimaryAndLeavesItRecoverable() async throws {
    let root = temporaryDirectory("fresh")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let primary = root.appending(path: "Library.json")
    let corruptBytes = Data("unreadable but preserved".utf8)
    try corruptBytes.write(to: primary)
    let store = CodableLibraryStore(fileURL: primary)

    let fresh = try await store.beginFreshLibraryPreservingPrimary()
    XCTAssertEqual(fresh, .empty)
    let durableFresh = try await store.load()
    XCTAssertEqual(durableFresh, .empty)
    let quarantine = root.appending(path: "Recovery/Quarantine")
    let evidence = try FileManager.default.contentsOfDirectory(
      at: quarantine,
      includingPropertiesForKeys: nil
    )
    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(evidence.first)), corruptBytes)
  }

  func testStartupStorageReconciliationUsesOwnedIDsAndQuarantinesOrphans() async throws {
    let root = temporaryDirectory("orphans")
    defer { try? FileManager.default.removeItem(at: root) }
    let knownBook = makeBook(id: uuid(10), title: "Known")
    let orphanBookID = uuid(11)
    let orphanJobID = uuid(12)
    let orphanTrashID = uuid(13)
    try writePrivateFile(
      root.appending(path: knownBook.assets[0].managedRelativePath),
      contents: "known media"
    )
    try writePrivateFile(
      root.appending(path: "Media/\(orphanBookID.uuidString.lowercased())/private-title.m4b"),
      contents: "orphan media"
    )
    try writePrivateFile(
      root.appending(path: "Staging/\(orphanJobID.uuidString.lowercased())/private-source.partial"),
      contents: "orphan staging"
    )
    try writePrivateFile(
      root.appending(path: "Trash/\(orphanTrashID.uuidString.lowercased())/private-trash.m4b"),
      contents: "orphan trash"
    )
    let manager = FileSystemMediaManager(rootURL: root)
    let result = try await manager.reconcileStartupStorage(
      with: LibrarySnapshot(books: [knownBook], importJobs: [], currentBookID: nil)
    )

    XCTAssertEqual(result.quarantinedManagedBookCount, 1)
    XCTAssertEqual(result.quarantinedStagingJobCount, 1)
    XCTAssertEqual(result.quarantinedTrashTransactionCount, 1)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appending(path: knownBook.assets[0].managedRelativePath).path
      ))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appending(path: "Media/\(orphanBookID.uuidString.lowercased())").path
      ))
    let quarantineNames = try FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: "Recovery/Orphans").path
    )
    XCTAssertEqual(
      Set(quarantineNames),
      [
        "managed-\(orphanBookID.uuidString.lowercased())",
        "staging-\(orphanJobID.uuidString.lowercased())",
        "trash-\(orphanTrashID.uuidString.lowercased())",
      ])
  }

  func testSupportBundleContainsOnlyAllowlistedAggregateFacts() async throws {
    let root = temporaryDirectory("diagnostics")
    defer { try? FileManager.default.removeItem(at: root) }
    let forbidden = [
      "Private Book Title", "Private Contributor", "private-source-name.m4b",
      "private-checksum", "Private bookmark note", "/private/library/path",
      "pairing-secret", "123456",
    ]
    let bookID = uuid(20)
    let assetID = uuid(21)
    var book = makeBook(id: bookID, title: forbidden[0])
    book.authors = [forbidden[1]]
    book.assets[0].originalFilename = forbidden[2]
    book.assets[0].managedRelativePath = forbidden[5]
    book.assets[0].checksumSHA256 = forbidden[3]
    let snapshot = LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: bookID,
      bookmarks: [
        Bookmark(
          id: uuid(22),
          bookID: bookID,
          bookPositionMilliseconds: 88_000,
          assetID: assetID,
          assetPositionMilliseconds: 88_000,
          chapterID: "private-chapter",
          chapterTitleSnapshot: "Private chapter title",
          label: "Private bookmark label",
          note: forbidden[4],
          createdAt: .distantPast,
          updatedAt: .distantPast
        )
      ]
    )
    let manager = FileSystemSupportDiagnosticsManager(
      rootURL: root,
      clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
      appVersion: "0.1.0",
      appBuild: "17"
    )
    let prepared = try await manager.prepareBundle(
      library: snapshot,
      recovery: StartupRecoveryStatus(
        issue: .unreadableLibrary,
        validAutomaticBackupCount: 2,
        invalidAutomaticBackupCount: 1
      ),
      reconciliation: StartupStorageReconciliation(
        library: snapshot,
        quarantinedManagedBookCount: 1,
        quarantinedStagingJobCount: 2,
        quarantinedTrashTransactionCount: 3
      ),
      automaticBackupCount: 2
    )
    let data = try Data(contentsOf: prepared.url)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    for value in forbidden {
      XCTAssertFalse(text.localizedCaseInsensitiveContains(value), value)
    }
    XCTAssertFalse(text.contains("positionMilliseconds"))
    XCTAssertFalse(text.contains("playbackPosition"))
    XCTAssertFalse(text.contains("sleepTimer"))
    let report = try JSONDecoder.playerDecoder.decode(SanitizedSupportReport.self, from: data)
    XCTAssertEqual(report.bookCount, 1)
    XCTAssertEqual(report.audioAssetCount, 1)
    XCTAssertEqual(report.bookmarkCount, 1)
    XCTAssertEqual(report.quarantinedTrashTransactionCount, 3)
    XCTAssertFalse(report.localFeaturesRequireInternet)
  }

  private func makeBook(id: UUID, title: String) -> Book {
    Book(
      id: id,
      title: title,
      authors: ["Author"],
      durationSeconds: 120,
      artworkData: nil,
      assets: [
        AudioAsset(
          id: id,
          originalFilename: "book.m4b",
          managedRelativePath: "Media/\(id.uuidString.lowercased())/book.m4b",
          checksumSHA256: "fixture",
          byteCount: 15,
          durationSeconds: 120,
          container: "M4B"
        )
      ],
      dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
    )
  }

  private func writePrivateFile(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
  }

  private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "PlayerOfflineRecoveryTests-\(name)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }

  private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "c0000000-0000-0000-0000-%012d", suffix))!
  }
}
