import CryptoKit
import XCTest

@testable import Player

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
    }
  }

  func testAutomaticDatabaseBackupsAreValidDeduplicatedAndRotated() async throws {
    let root = temporaryDirectory("automatic-backups")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CodableLibraryStore(fileURL: root.appending(path: "Library.json"))
    for index in 0..<5 {
      var snapshot = LibrarySnapshot.empty
      snapshot.allBooksViewStyle = index.isMultiple(of: 2) ? .grid : .list
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
    }
    let backups = await store.automaticBackups()
    XCTAssertEqual(backups.count, 3)
    XCTAssertTrue(backups.allSatisfy { $0.byteCount > 0 })

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
    let artwork = Data([0x89, 0x50, 0x4e, 0x47, 0x01, 0x02])
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
