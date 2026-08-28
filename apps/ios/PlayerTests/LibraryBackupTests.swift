import CryptoKit
import UIKit
import XCTest

@testable import Player

@MainActor
final class LibraryBackupTests: XCTestCase {
  func testMediaBackupRoundTripsLibraryArtworkAndAudioWithoutDuplicates() async throws {
    let sourceRoot = temporaryDirectory("backup-source")
    let destinationRoot = temporaryDirectory("backup-destination")
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
    }
    let fixture = try makeFixture(at: sourceRoot)
    let source = FileSystemLibraryBackupManager(
      rootURL: sourceRoot,
      clock: FixedPlayerClock(value: fixture.date)
    )
    let prepared = try await source.prepareExport(
      library: fixture.library,
      kind: .includingMedia
    )
    XCTAssertTrue(prepared.url.lastPathComponent.hasPrefix("Bookshelf Library "))
    XCTAssertEqual(prepared.url.pathExtension, "playerbackup")

    let oldMedia = destinationRoot.appending(path: "Media/old/old.m4b")
    try FileManager.default.createDirectory(
      at: oldMedia.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("old".utf8).write(to: oldMedia)
    let destination = FileSystemLibraryBackupManager(rootURL: destinationRoot)
    let restored = try await destination.restore(from: prepared.url)

    XCTAssertEqual(restored, fixture.library)
    XCTAssertEqual(
      restored.books.first?.renderedArtworkData,
      fixture.library.books.first?.renderedArtworkData
    )
    XCTAssertNotEqual(
      restored.books.first?.renderedArtworkData,
      restored.books.first?.artworkData,
      "Restoring a portable backup must reapply the authoritative crop"
    )
    XCTAssertEqual(
      try Data(contentsOf: destinationRoot.appending(path: fixture.relativeMediaPath)),
      fixture.audio
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldMedia.path))
    XCTAssertEqual(try mediaFiles(beneath: destinationRoot), [fixture.relativeMediaPath])

    let restoredAgain = try await destination.restore(from: prepared.url)
    XCTAssertEqual(restoredAgain, fixture.library)
    XCTAssertEqual(try mediaFiles(beneath: destinationRoot), [fixture.relativeMediaPath])
  }

  func testMetadataOnlyRestoreRequiresMatchingLocalAudio() async throws {
    let root = temporaryDirectory("metadata-backup")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeFixture(at: root)
    let manager = FileSystemLibraryBackupManager(rootURL: root)
    let prepared = try await manager.prepareExport(
      library: fixture.library,
      kind: .metadataOnly
    )
    let manifest = try manifest(at: prepared.url)
    XCTAssertEqual(manifest.kind, .metadataOnly)
    XCTAssertTrue(manifest.media.isEmpty)

    let restored = try await manager.restore(from: prepared.url)
    XCTAssertEqual(restored, fixture.library)

    try FileManager.default.removeItem(at: root.appending(path: fixture.relativeMediaPath))
    do {
      _ = try await manager.restore(from: prepared.url)
      XCTFail("Expected metadata-only restore to require local audio")
    } catch let error as LibraryBackupError {
      XCTAssertEqual(error, .localMediaRequired(fixture.relativeMediaPath))
    }
  }

  func testTamperedMediaFailsBeforeReplacingExistingLibraryOrMedia() async throws {
    let sourceRoot = temporaryDirectory("tamper-source")
    let destinationRoot = temporaryDirectory("tamper-destination")
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
    }
    let fixture = try makeFixture(at: sourceRoot)
    let source = FileSystemLibraryBackupManager(rootURL: sourceRoot)
    let prepared = try await source.prepareExport(
      library: fixture.library,
      kind: .includingMedia
    )
    try Data("tampered".utf8).write(
      to: prepared.url.appending(path: fixture.relativeMediaPath),
      options: .atomic
    )

    let existing = LibrarySnapshot.empty
    let store = CodableLibraryStore(fileURL: destinationRoot.appending(path: "Library.json"))
    try await store.save(existing)
    let oldMedia = destinationRoot.appending(path: "Media/old/old.m4b")
    try FileManager.default.createDirectory(
      at: oldMedia.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("keep me".utf8).write(to: oldMedia)

    do {
      _ = try await FileSystemLibraryBackupManager(rootURL: destinationRoot).restore(
        from: prepared.url
      )
      XCTFail("Expected integrity failure")
    } catch let error as LibraryBackupError {
      XCTAssertEqual(error, .invalidPayload(fixture.relativeMediaPath))
    }
    let persisted = try await store.load()
    XCTAssertEqual(persisted, existing)
    XCTAssertEqual(try Data(contentsOf: oldMedia), Data("keep me".utf8))
  }

  func testRejectsNewerPortableFormatAndLibrarySchemaExplicitly() async throws {
    let root = temporaryDirectory("compatibility")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeFixture(at: root)
    let manager = FileSystemLibraryBackupManager(rootURL: root)
    let prepared = try await manager.prepareExport(
      library: fixture.library,
      kind: .metadataOnly
    )
    var value = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: prepared.url.appending(path: "manifest.json"))
      ) as? [String: Any]
    )
    value["formatVersion"] = 2
    try JSONSerialization.data(withJSONObject: value).write(
      to: prepared.url.appending(path: "manifest.json"),
      options: .atomic
    )
    do {
      _ = try await manager.restore(from: prepared.url)
      XCTFail("Expected unsupported format")
    } catch let error as LibraryBackupError {
      XCTAssertEqual(error, .unsupportedFormat(2))
      XCTAssertTrue(error.localizedDescription.contains("Update Bookshelf"))
    }

    value["formatVersion"] = 1
    value["librarySchemaVersion"] = CodableLibraryStore.currentSchemaVersion + 1
    try JSONSerialization.data(withJSONObject: value).write(
      to: prepared.url.appending(path: "manifest.json"),
      options: .atomic
    )
    do {
      _ = try await manager.restore(from: prepared.url)
      XCTFail("Expected unsupported library schema")
    } catch let error as LibraryBackupError {
      XCTAssertEqual(
        error,
        .unsupportedLibrarySchema(CodableLibraryStore.currentSchemaVersion + 1)
      )
      XCTAssertTrue(error.localizedDescription.contains("Bookshelf cannot read"))
    }
  }

  func testPortableRestoreRejectsSymlinkedRootManifestDirectoryAndPayload() async throws {
    let sourceRoot = temporaryDirectory("backup-symlink-source")
    let destinationRoot = temporaryDirectory("backup-symlink-destination")
    let variantsRoot = temporaryDirectory("backup-symlink-variants")
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
      try? FileManager.default.removeItem(at: variantsRoot)
    }
    let fixture = try makeFixture(at: sourceRoot)
    let prepared = try await FileSystemLibraryBackupManager(rootURL: sourceRoot).prepareExport(
      library: fixture.library,
      kind: .includingMedia
    )
    try FileManager.default.createDirectory(at: variantsRoot, withIntermediateDirectories: true)
    let manager = FileSystemLibraryBackupManager(rootURL: destinationRoot)

    let rootLink = variantsRoot.appending(path: "root-link.playerbackup")
    try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: prepared.url)
    await assertInvalidPackage(manager, restoring: rootLink, label: "root symlink")

    let manifestLink = try copyPackage(prepared.url, into: variantsRoot, named: "manifest-link")
    let manifestURL = manifestLink.appending(path: "manifest.json")
    let manifestTarget = variantsRoot.appending(path: "manifest-target.json")
    try FileManager.default.copyItem(at: manifestURL, to: manifestTarget)
    try FileManager.default.removeItem(at: manifestURL)
    try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: manifestTarget)
    await assertInvalidPackage(manager, restoring: manifestLink, label: "manifest symlink")

    let directoryLink = try copyPackage(prepared.url, into: variantsRoot, named: "directory-link")
    let mediaDirectory = directoryLink.appending(path: "Media")
    let mediaTarget = variantsRoot.appending(path: "media-target")
    try FileManager.default.moveItem(at: mediaDirectory, to: mediaTarget)
    try FileManager.default.createSymbolicLink(at: mediaDirectory, withDestinationURL: mediaTarget)
    await assertInvalidPackage(manager, restoring: directoryLink, label: "directory symlink")

    let payloadLink = try copyPackage(prepared.url, into: variantsRoot, named: "payload-link")
    let payloadURL = payloadLink.appending(path: fixture.relativeMediaPath)
    let payloadTarget = variantsRoot.appending(path: "payload-target.m4b")
    try FileManager.default.copyItem(at: payloadURL, to: payloadTarget)
    try FileManager.default.removeItem(at: payloadURL)
    try FileManager.default.createSymbolicLink(at: payloadURL, withDestinationURL: payloadTarget)
    await assertInvalidPackage(manager, restoring: payloadLink, label: "payload symlink")
  }

  func testPortableRestoreRequiresAnExactDeclaredPackageTree() async throws {
    let sourceRoot = temporaryDirectory("backup-allowlist-source")
    let destinationRoot = temporaryDirectory("backup-allowlist-destination")
    let variantsRoot = temporaryDirectory("backup-allowlist-variants")
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
      try? FileManager.default.removeItem(at: variantsRoot)
    }
    let fixture = try makeFixture(at: sourceRoot)
    let prepared = try await FileSystemLibraryBackupManager(rootURL: sourceRoot).prepareExport(
      library: fixture.library,
      kind: .includingMedia
    )
    try FileManager.default.createDirectory(at: variantsRoot, withIntermediateDirectories: true)
    let manager = FileSystemLibraryBackupManager(rootURL: destinationRoot)

    let extraFile = try copyPackage(prepared.url, into: variantsRoot, named: "extra-file")
    try Data("undeclared".utf8).write(to: extraFile.appending(path: "extra.txt"))
    await assertInvalidPackage(manager, restoring: extraFile, label: "undeclared file")

    let extraDirectory = try copyPackage(prepared.url, into: variantsRoot, named: "extra-directory")
    try FileManager.default.createDirectory(
      at: extraDirectory.appending(path: "Extras"),
      withIntermediateDirectories: true
    )
    await assertInvalidPackage(manager, restoring: extraDirectory, label: "undeclared directory")

    let missingDirectory = try copyPackage(prepared.url, into: variantsRoot, named: "missing")
    try FileManager.default.removeItem(at: missingDirectory.appending(path: "Media"))
    await assertInvalidPackage(manager, restoring: missingDirectory, label: "missing tree")
  }

  func testPortableRestoreRejectsAbsoluteTraversalNoncanonicalAndDuplicatePaths() async throws {
    let sourceRoot = temporaryDirectory("backup-path-source")
    let destinationRoot = temporaryDirectory("backup-path-destination")
    let variantsRoot = temporaryDirectory("backup-path-variants")
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
      try? FileManager.default.removeItem(at: variantsRoot)
    }
    let fixture = try makeFixture(at: sourceRoot)
    let prepared = try await FileSystemLibraryBackupManager(rootURL: sourceRoot).prepareExport(
      library: fixture.library,
      kind: .includingMedia
    )
    try FileManager.default.createDirectory(at: variantsRoot, withIntermediateDirectories: true)
    let manager = FileSystemLibraryBackupManager(rootURL: destinationRoot)
    let invalidPaths = [
      "/\(fixture.relativeMediaPath)",
      "Media/../\(fixture.relativeMediaPath)",
      fixture.relativeMediaPath.replacingOccurrences(
        of: "/", with: "//", options: [], range: fixture.relativeMediaPath.range(of: "/")),
      fixture.relativeMediaPath.replacingOccurrences(
        of: "/", with: "/./", options: [], range: fixture.relativeMediaPath.range(of: "/")),
    ]

    for (index, invalidPath) in invalidPaths.enumerated() {
      let package = try copyPackage(
        prepared.url, into: variantsRoot, named: "invalid-path-\(index)")
      try rewriteManifest(at: package) { manifest in
        manifest.library.books[0].assets[0].managedRelativePath = invalidPath
        manifest.media[0].relativePath = invalidPath
      }
      await assertInvalidPackage(manager, restoring: package, label: invalidPath)
    }

    let duplicate = try copyPackage(prepared.url, into: variantsRoot, named: "duplicate-path")
    try rewriteManifest(at: duplicate) { manifest in
      manifest.media.append(manifest.media[0])
    }
    await assertInvalidPackage(manager, restoring: duplicate, label: "duplicate path")
  }

  func testPortableRestoreEnforcesManifestBookMediaArtworkAndPackageBudgets() async throws {
    let sourceRoot = temporaryDirectory("backup-budget-source")
    let destinationRoot = temporaryDirectory("backup-budget-destination")
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
    }
    let fixture = try makeFixture(at: sourceRoot)
    let prepared = try await FileSystemLibraryBackupManager(rootURL: sourceRoot).prepareExport(
      library: fixture.library,
      kind: .includingMedia
    )
    let manifestByteCount = Int64(
      try Data(contentsOf: prepared.url.appending(path: "manifest.json")).count
    )

    var policy = PortableLibraryBackupPolicy.production
    policy.maximumManifestByteCount = manifestByteCount - 1
    await assertInvalidPackage(
      FileSystemLibraryBackupManager(rootURL: destinationRoot, policy: policy),
      restoring: prepared.url,
      label: "manifest budget"
    )

    policy = .production
    policy.maximumBookCount = 0
    await assertInvalidPackage(
      FileSystemLibraryBackupManager(rootURL: destinationRoot, policy: policy),
      restoring: prepared.url,
      label: "book budget"
    )

    policy = .production
    policy.maximumMediaCount = 0
    await assertInvalidPackage(
      FileSystemLibraryBackupManager(rootURL: destinationRoot, policy: policy),
      restoring: prepared.url,
      label: "media count budget"
    )

    policy = .production
    policy.maximumArtworkCount = 0
    await assertInvalidPackage(
      FileSystemLibraryBackupManager(rootURL: destinationRoot, policy: policy),
      restoring: prepared.url,
      label: "artwork count budget"
    )

    policy = .production
    policy.maximumArtworkByteCount = Int64(fixture.library.books[0].artworkData!.count - 1)
    await assertInvalidPackage(
      FileSystemLibraryBackupManager(rootURL: destinationRoot, policy: policy),
      restoring: prepared.url,
      label: "artwork budget"
    )

    policy = .production
    policy.maximumAggregateArtworkByteCount =
      Int64(fixture.library.books[0].artworkData!.count - 1)
    await assertInvalidPackage(
      FileSystemLibraryBackupManager(rootURL: destinationRoot, policy: policy),
      restoring: prepared.url,
      label: "aggregate artwork budget"
    )

    policy = .production
    policy.maximumMediaByteCount = Int64(fixture.audio.count - 1)
    await assertInvalidPackage(
      FileSystemLibraryBackupManager(rootURL: destinationRoot, policy: policy),
      restoring: prepared.url,
      label: "per-file media budget"
    )

    policy = .production
    policy.maximumAggregateMediaByteCount = Int64(fixture.audio.count - 1)
    await assertInvalidPackage(
      FileSystemLibraryBackupManager(rootURL: destinationRoot, policy: policy),
      restoring: prepared.url,
      label: "media byte budget"
    )

    policy = .production
    policy.maximumPackageByteCount = manifestByteCount + Int64(fixture.audio.count) - 1
    await assertInvalidPackage(
      FileSystemLibraryBackupManager(rootURL: destinationRoot, policy: policy),
      restoring: prepared.url,
      label: "package budget"
    )
  }

  func testPortableRestoreRejectsNegativeAndOverflowingDeclaredSizes() async throws {
    let sourceRoot = temporaryDirectory("backup-size-source")
    let destinationRoot = temporaryDirectory("backup-size-destination")
    let variantsRoot = temporaryDirectory("backup-size-variants")
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
      try? FileManager.default.removeItem(at: variantsRoot)
    }
    let fixture = try makeFixture(at: sourceRoot)
    let prepared = try await FileSystemLibraryBackupManager(rootURL: sourceRoot).prepareExport(
      library: fixture.library,
      kind: .includingMedia
    )
    try FileManager.default.createDirectory(at: variantsRoot, withIntermediateDirectories: true)

    let negative = try copyPackage(prepared.url, into: variantsRoot, named: "negative")
    try rewriteManifest(at: negative) { manifest in
      manifest.library.books[0].assets[0].byteCount = -1
      manifest.media[0].byteCount = -1
    }
    await assertInvalidPackage(
      FileSystemLibraryBackupManager(rootURL: destinationRoot),
      restoring: negative,
      label: "negative size"
    )

    let overflow = try copyPackage(prepared.url, into: variantsRoot, named: "overflow")
    try rewriteManifest(at: overflow) { manifest in
      manifest.library.books[0].assets[0].byteCount = .max
      var secondAsset = manifest.library.books[0].assets[0]
      secondAsset.managedRelativePath = "Media/overflow/second.m4b"
      manifest.library.books[0].assets.append(secondAsset)
      manifest.media[0].byteCount = .max
      manifest.media.append(
        PortableBackupPayload(
          relativePath: secondAsset.managedRelativePath,
          byteCount: .max,
          checksumSHA256: secondAsset.checksumSHA256
        )
      )
    }
    var overflowPolicy = PortableLibraryBackupPolicy.production
    overflowPolicy.maximumMediaByteCount = .max
    overflowPolicy.maximumAggregateMediaByteCount = .max
    overflowPolicy.maximumPackageByteCount = .max
    await assertInvalidPackage(
      FileSystemLibraryBackupManager(rootURL: destinationRoot, policy: overflowPolicy),
      restoring: overflow,
      label: "overflowing aggregate"
    )
  }

  func testCancelledPortableRestoreDoesNotReplaceLibraryOrMedia() async throws {
    let sourceRoot = temporaryDirectory("backup-cancel-source")
    let destinationRoot = temporaryDirectory("backup-cancel-destination")
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
    }
    let fixture = try makeFixture(at: sourceRoot)
    let prepared = try await FileSystemLibraryBackupManager(rootURL: sourceRoot).prepareExport(
      library: fixture.library,
      kind: .includingMedia
    )
    let existing = LibrarySnapshot.empty
    let store = CodableLibraryStore(fileURL: destinationRoot.appending(path: "Library.json"))
    try await store.save(existing)
    let oldMedia = destinationRoot.appending(path: "Media/old/old.m4b")
    try FileManager.default.createDirectory(
      at: oldMedia.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let oldBytes = Data("preserve on cancellation".utf8)
    try oldBytes.write(to: oldMedia)
    let manager = FileSystemLibraryBackupManager(
      rootURL: destinationRoot,
      beforeRestoreCommit: { withUnsafeCurrentTask { $0?.cancel() } }
    )

    let task = Task { () throws -> LibrarySnapshot in
      return try await manager.restore(from: prepared.url)
    }
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Cancellation is the expected terminal state.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }

    let persisted = try await store.load()
    XCTAssertEqual(persisted, existing)
    XCTAssertEqual(try Data(contentsOf: oldMedia), oldBytes)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(
        at: destinationRoot.appending(path: "BackupRestore"),
        includingPropertiesForKeys: nil
      ).contains(where: { _ in true })
    )
  }

  func testAutomaticDatabaseBackupsUseStableEqualTimestampOrderForRotationRecoveryAndDeduplication()
    async throws
  {
    let root = temporaryDirectory("automatic-backups")
    defer { try? FileManager.default.removeItem(at: root) }
    let artifactDate = Date(timeIntervalSince1970: 1_700_000_000)
    let artifactIDs = LockedArtifactIDSequence(values: (1...7).map(artifactUUID))
    let store = CodableLibraryStore(
      fileURL: root.appending(path: "Library.json"),
      artifactNow: { artifactDate },
      artifactID: { artifactIDs.next() }
    )
    for index in 0..<5 {
      var snapshot = LibrarySnapshot.empty
      snapshot.allBooksViewStyle = index.isMultiple(of: 2) ? .shelf : .list
      snapshot.collections = [
        BookCollection(
          id: uuid(index + 20),
          name: "revision-\(index)",
          orderedBookIDs: [],
          createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
          updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
        )
      ]
      try await store.save(snapshot)
      try setAutomaticBackupDates(in: root, to: artifactDate)
    }
    let backups = await store.automaticBackups()
    XCTAssertEqual(backups.count, 3)
    XCTAssertTrue(backups.allSatisfy { $0.byteCount > 0 })
    XCTAssertEqual(
      backups.map { $0.url.lastPathComponent },
      [5, 4, 3].map {
        "library-1700000000000-\(artifactUUID($0).uuidString.lowercased()).json"
      },
      "Equal filesystem timestamps use the artifact name as a stable total-order tie-break."
    )

    try Data("not json".utf8).write(to: root.appending(path: "Library.json"), options: .atomic)
    let restored = try await store.restoreLatestAutomaticBackup()
    XCTAssertEqual(restored.collections.first?.name, "revision-4")
    let loaded = try await store.load()
    XCTAssertEqual(loaded, restored)

    let countBeforeDuplicateSave = await store.automaticBackups().count
    try await store.save(restored)
    let countAfterDuplicateSave = await store.automaticBackups().count
    XCTAssertEqual(countAfterDuplicateSave, countBeforeDuplicateSave)
  }

  func testFreshLibraryUsesInjectedIdentityForQuarantinedEvidence() async throws {
    let root = temporaryDirectory("deterministic-quarantine")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let libraryURL = root.appending(path: "Library.json")
    let corruptBytes = Data("preserve exact corrupt evidence".utf8)
    try corruptBytes.write(to: libraryURL)
    let artifactDate = Date(timeIntervalSince1970: 1_700_000_000)
    let quarantineID = artifactUUID(40)
    let backupID = artifactUUID(41)
    let artifactIDs = LockedArtifactIDSequence(values: [quarantineID, backupID])
    let store = CodableLibraryStore(
      fileURL: libraryURL,
      artifactNow: { artifactDate },
      artifactID: { artifactIDs.next() }
    )

    let fresh = try await store.beginFreshLibraryPreservingPrimary()
    XCTAssertEqual(fresh, .empty)

    let expectedEvidence = root.appending(
      path: "Recovery/Quarantine/library-1700000000000-"
        + "\(quarantineID.uuidString.lowercased()).json"
    )
    XCTAssertEqual(try Data(contentsOf: expectedEvidence), corruptBytes)
    let durableFresh = try await store.load()
    XCTAssertEqual(durableFresh, .empty)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: expectedEvidence.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
      ).map(\.lastPathComponent),
      [expectedEvidence.lastPathComponent]
    )
  }

  func testEverySchemaFourThroughCurrentMigratesAndRoundTripsWithABackup() async throws {
    let root = temporaryDirectory("all-schema-round-trips")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    for version in 4...CodableLibraryStore.currentSchemaVersion {
      let fileURL = root.appending(path: "Library-v\(version).json")
      let libraryData = try JSONEncoder.playerEncoder.encode(LibrarySnapshot.empty)
      let libraryObject = try JSONSerialization.jsonObject(with: libraryData)
      let envelope: [String: Any] = [
        "schemaVersion": version,
        "library": libraryObject,
      ]
      try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL, options: .atomic)
      let store = CodableLibraryStore(fileURL: fileURL)
      let migrated = try await store.load()
      try await store.save(migrated)
      let roundTripped = try await store.load()
      XCTAssertEqual(roundTripped, migrated, "schema v\(version) did not round trip")
      if version < CodableLibraryStore.currentSchemaVersion {
        let backups = await store.automaticBackups()
        XCTAssertFalse(backups.isEmpty, "schema v\(version) was not backed up before migration")
      }
    }
  }

  private func makeFixture(at root: URL) throws -> (
    library: LibrarySnapshot, audio: Data, relativeMediaPath: String, date: Date
  ) {
    let bookID = uuid(1)
    let assetID = uuid(2)
    let bookmarkID = uuid(3)
    let eventID = uuid(4)
    let collectionID = uuid(5)
    let date = Date(timeIntervalSince1970: 1_750_000_000)
    let audio = Data("synthetic portable audio payload".utf8)
    let relativeMediaPath =
      "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
    let mediaURL = root.appending(path: relativeMediaPath)
    try FileManager.default.createDirectory(
      at: mediaURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try audio.write(to: mediaURL)
    let checksum = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
    let artworkFormat = UIGraphicsImageRendererFormat()
    artworkFormat.scale = 1
    let artwork = UIGraphicsImageRenderer(
      size: CGSize(width: 8, height: 4),
      format: artworkFormat
    ).pngData { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
      UIColor.blue.setFill()
      context.fill(CGRect(x: 4, y: 0, width: 4, height: 4))
    }
    var metadata = AudiobookMetadata.imported(
      title: "The Portable Book",
      authors: ["Ada Listener"],
      narrators: ["Nora Reader"],
      seriesName: "Portable Stories",
      seriesPosition: "2",
      artworkData: artwork,
      artworkMediaType: "image/png"
    )
    metadata.cover?.crop = CoverCrop(x: 0.5, y: 0, width: 0.5, height: 1)
    metadata.cover?.source = .userCrop
    let asset = AudioAsset(
      id: assetID,
      originalFilename: "The Portable Book.m4b",
      managedRelativePath: relativeMediaPath,
      checksumSHA256: checksum,
      byteCount: Int64(audio.count),
      durationSeconds: 600,
      container: "M4B"
    )
    let book = Book(
      id: bookID,
      title: "The Portable Book",
      authors: ["Ada Listener"],
      durationSeconds: 600,
      artworkData: artwork,
      assets: [asset],
      dateAdded: date,
      narrators: ["Nora Reader"],
      seriesName: "Portable Stories",
      seriesPosition: "2",
      artworkMediaType: "image/png",
      chapters: [
        Chapter(
          id: "chapter-one", title: "Beginning", startSeconds: 0,
          durationSeconds: 600, source: .embedded, assetID: assetID
        )
      ],
      metadata: metadata,
      listeningState: BookListeningState(
        status: .inProgress,
        positionMilliseconds: 123_000,
        lastListenedAt: date,
        finishedAt: nil
      )
    )
    let event = PositionEvent.acknowledged(
      id: eventID,
      bookID: bookID,
      positionMilliseconds: 123_000,
      sequence: 1,
      reason: .pause,
      acknowledgedAt: date,
      previousEventID: nil
    )
    return (
      LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: bookID,
        playbackPosition: PlaybackPosition(
          bookID: bookID,
          positionMilliseconds: 123_000,
          sequence: 1,
          sourceEventID: eventID,
          updatedAt: date
        ),
        positionJournal: [event],
        upNextBookIDs: [bookID],
        collections: [
          BookCollection(
            id: collectionID,
            name: "Favorites",
            orderedBookIDs: [bookID],
            createdAt: date,
            updatedAt: date
          )
        ],
        allBooksViewStyle: .list,
        searchPreferences: LibrarySearchPreferences(
          sort: .recentlyAdded,
          direction: .descending,
          status: .inProgress,
          formats: ["M4B"],
          missingMetadataOnly: false
        ),
        globalTransportPreferences: TransportPreferences(
          playbackRate: 1.25,
          backwardSkipSeconds: 10,
          forwardSkipSeconds: 20,
          seekContext: .wholeBook
        ),
        bookmarks: [
          Bookmark(
            id: bookmarkID,
            bookID: bookID,
            bookPositionMilliseconds: 123_000,
            assetID: assetID,
            assetPositionMilliseconds: 123_000,
            chapterID: "chapter-one",
            chapterTitleSnapshot: "Beginning",
            label: "Remember this",
            note: "A portable note",
            createdAt: date,
            updatedAt: date
          )
        ]
      ), audio, relativeMediaPath, date
    )
  }

  private func manifest(at packageURL: URL) throws -> PortableLibraryManifest {
    try JSONDecoder.playerDecoder.decode(
      PortableLibraryManifest.self,
      from: Data(contentsOf: packageURL.appending(path: "manifest.json"))
    )
  }

  private func copyPackage(_ packageURL: URL, into root: URL, named name: String) throws -> URL {
    let destination = root.appending(path: "\(name).playerbackup", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: packageURL, to: destination)
    return destination
  }

  private func rewriteManifest(
    at packageURL: URL,
    mutate: (inout PortableLibraryManifest) -> Void
  ) throws {
    var value = try manifest(at: packageURL)
    mutate(&value)
    try JSONEncoder.playerEncoder.encode(value).write(
      to: packageURL.appending(path: "manifest.json"),
      options: .atomic
    )
  }

  private func assertInvalidPackage(
    _ manager: FileSystemLibraryBackupManager,
    restoring packageURL: URL,
    label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await manager.restore(from: packageURL)
      XCTFail("Expected invalid package: \(label)", file: file, line: line)
    } catch LibraryBackupError.invalidPackage {
      // This is the expected trust-boundary rejection.
    } catch {
      XCTFail("Expected invalid package for \(label), got \(error)", file: file, line: line)
    }
  }

  private func mediaFiles(beneath root: URL) throws -> [String] {
    let media = root.appending(path: "Media")
    guard
      let enumerator = FileManager.default.enumerator(
        at: media,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    return try enumerator.compactMap { value -> String? in
      guard let url = value as? URL,
        try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
      else { return nil }
      return String(url.path.dropFirst(root.path.count + 1))
    }.sorted()
  }

  private func setAutomaticBackupDates(in root: URL, to date: Date) throws {
    let directory = root.appending(path: "AutomaticBackups")
    let backups = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    for backup in backups {
      try FileManager.default.setAttributes(
        [.modificationDate: date],
        ofItemAtPath: backup.path
      )
    }
  }

  private func artifactUUID(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "c0000000-0000-0000-0000-%012d", suffix))!
  }

  private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "PlayerTests-\(name)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }

  private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "b0000000-0000-0000-0000-%012d", suffix))!
  }
}

private final class LockedArtifactIDSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [UUID]

  init(values: [UUID]) {
    self.values = values
  }

  func next() -> UUID {
    lock.lock()
    defer { lock.unlock() }
    precondition(!values.isEmpty, "The deterministic artifact ID sequence is exhausted.")
    return values.removeFirst()
  }
}
