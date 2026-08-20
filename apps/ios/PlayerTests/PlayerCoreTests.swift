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
    XCTAssertEqual(readyJob.proposal?.chapters.count, 1)
    XCTAssertEqual(readyJob.proposal?.chapters.first?.source, .file)
    XCTAssertEqual(try checksum(source), sourceBefore, "The source must remain byte-identical")

    let committedBookID = await model.addImportToLibrary(jobID: jobID)
    let bookID = try XCTUnwrap(committedBookID)
    let book = try XCTUnwrap(model.library.books.first(where: { $0.id == bookID }))
    let asset = try XCTUnwrap(book.assets.first)
    XCTAssertEqual(asset.timelineStartSeconds, 0)
    XCTAssertEqual(book.chapters.first?.assetID, asset.id)
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

  func testVersionedStoreMigratesSchemaOneAndWritesCurrentSchema() async throws {
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
    XCTAssertEqual(object["schemaVersion"] as? Int, 13)
  }

  func testVersionedStoreMigratesSchemaTwoMetadataAndTimelineDefaults() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "PlayerV2StoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appending(path: "Library.json")
    let store = CodableLibraryStore(fileURL: fileURL)
    let versionTwo = """
      {
        "schemaVersion": 2,
        "library": {
          "books": [{
            "id": "70000000-0000-0000-0000-000000000001",
            "title": "Migrated Book",
            "authors": ["Legacy Author"],
            "durationSeconds": 60,
            "assets": [{
              "id": "70000000-0000-0000-0000-000000000002",
              "originalFilename": "legacy.m4b",
              "managedRelativePath": "Media/legacy.m4b",
              "checksumSHA256": "legacy",
              "byteCount": 100,
              "durationSeconds": 60,
              "container": "M4B"
            }],
            "dateAdded": "2023-11-14T22:13:20Z"
          }],
          "importJobs": [],
          "currentBookID": null,
          "playbackPosition": null,
          "positionJournal": []
        }
      }
      """
    try Data(versionTwo.utf8).write(to: fileURL)

    let migrated = try await store.load()

    let book = try XCTUnwrap(migrated.books.first)
    XCTAssertEqual(book.narrators, [])
    XCTAssertNil(book.seriesName)
    XCTAssertEqual(book.assets.first?.timelineStartSeconds, 0)
    XCTAssertEqual(book.chapters.count, 1)
    XCTAssertEqual(book.chapters.first?.title, "legacy")
    XCTAssertEqual(book.chapters.first?.source, .file)
    XCTAssertEqual(book.chapters.first?.assetID, book.assets.first?.id)
  }

  func testVersionedStoreMigratesSchemaThreeImportGroupingDefaults() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "PlayerV3StoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "Library.json")
    let store = CodableLibraryStore(fileURL: fileURL)
    let assetID = UUID(uuidString: "71000000-0000-0000-0000-000000000002")!
    let asset = AudioAsset(
      id: assetID,
      originalFilename: "legacy.m4b",
      managedRelativePath: "",
      checksumSHA256: "legacy",
      byteCount: 100,
      durationSeconds: 60,
      container: "M4B"
    )
    let proposal = BookProposal(
      id: UUID(uuidString: "71000000-0000-0000-0000-000000000003")!,
      proposedBookID: UUID(uuidString: "71000000-0000-0000-0000-000000000004")!,
      title: "Legacy Import",
      authors: [],
      durationSeconds: 60,
      artworkData: nil,
      asset: asset,
      warnings: []
    )
    let job = ImportJob(
      id: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!,
      sourceFilename: "legacy.m4b",
      phase: .ready,
      progress: ImportProgress(completed: 100, total: 100),
      stagedRelativePath: "Staging/legacy/source.m4b",
      proposal: proposal,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try await store.save(
      LibrarySnapshot(books: [], importJobs: [job], currentBookID: nil)
    )
    let data = try Data(contentsOf: fileURL)
    var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    envelope["schemaVersion"] = 3
    var library = try XCTUnwrap(envelope["library"] as? [String: Any])
    var jobs = try XCTUnwrap(library["importJobs"] as? [[String: Any]])
    jobs[0].removeValue(forKey: "stagedAssets")
    jobs[0].removeValue(forKey: "additionalProposals")
    jobs[0].removeValue(forKey: "reviewRevision")
    library["importJobs"] = jobs
    envelope["library"] = library
    try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL)

    let migrated = try await store.load()
    let migratedJob = try XCTUnwrap(migrated.importJobs.first)
    XCTAssertEqual(migratedJob.reviewRevision, 0)
    XCTAssertEqual(migratedJob.proposals.count, 1)
    XCTAssertEqual(
      migratedJob.stagedAssets,
      [
        StagedImportAsset(
          assetID: assetID,
          stagedRelativePath: "Staging/legacy/source.m4b",
          sourceRelativePath: "legacy.m4b"
        )
      ]
    )
  }

  func testVersionedStoreMigratesSchemaSixMetadataRepairDefaults() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "PlayerV6MetadataStoreTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "Library.json")
    let store = CodableLibraryStore(fileURL: fileURL)
    let legacyBook = Book(
      id: UUID(uuidString: "71500000-0000-0000-0000-000000000001")!,
      title: "Schema Six Book",
      authors: ["Legacy Author"],
      durationSeconds: 60,
      artworkData: Data([1, 2, 3]),
      assets: [],
      dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
      narrators: ["Legacy Narrator"],
      seriesName: "Legacy Series",
      seriesPosition: "6",
      artworkMediaType: "image/png"
    )
    try await store.save(LibrarySnapshot(
      books: [legacyBook], importJobs: [], currentBookID: nil
    ))
    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    envelope["schemaVersion"] = 6
    var library = try XCTUnwrap(envelope["library"] as? [String: Any])
    var books = try XCTUnwrap(library["books"] as? [[String: Any]])
    books[0].removeValue(forKey: "metadata")
    library["books"] = books
    library.removeValue(forKey: "metadataTransactions")
    envelope["library"] = library
    try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL)

    let migrated = try await store.load()

    let book = try XCTUnwrap(migrated.books.first)
    XCTAssertEqual(book.metadata.title, "Schema Six Book")
    XCTAssertEqual(book.metadata.authors.map(\.displayName), ["Legacy Author"])
    XCTAssertEqual(book.metadata.narrators.map(\.displayName), ["Legacy Narrator"])
    XCTAssertEqual(book.metadata.seriesMemberships.first?.position, "6")
    XCTAssertEqual(book.metadata.cover?.originalData, Data([1, 2, 3]))
    XCTAssertEqual(book.metadata.state(for: .title)?.provenance, .legacyLibrary)
    XCTAssertTrue(migrated.metadataTransactions.isEmpty)
    try await store.save(migrated)
    let current = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    XCTAssertEqual(current["schemaVersion"] as? Int, 13)
  }

  func testAVFoundationInspectorBuildsFileChapterWithoutReadingPayload() async throws {
    let bundled = try XCTUnwrap(
      Bundle(for: PlayerCoreTests.self).url(forResource: "01-opening-tone", withExtension: "m4a")
    )

    let inspected = try await AVFoundationAudioInspector().inspect(url: bundled)

    XCTAssertEqual(inspected.container, "M4A")
    XCTAssertEqual(inspected.durationSeconds, 1.8, accuracy: 0.02)
    XCTAssertEqual(inspected.chapters.count, 1)
    XCTAssertEqual(inspected.chapters.first?.source, .file)
    XCTAssertEqual(inspected.chapters.first?.startSeconds, 0)
    XCTAssertEqual(inspected.chapters.first?.durationSeconds ?? 0, 1.8, accuracy: 0.02)
  }

  func testAVFoundationInspectorSupportsSyntheticMP3AndM4B() async throws {
    let fixtureBundle = Bundle(for: PlayerCoreTests.self)
    let mp3 = try XCTUnwrap(
      fixtureBundle.url(forResource: "01-synthetic-chapter", withExtension: "mp3")
    )
    let m4b = try XCTUnwrap(
      fixtureBundle.url(forResource: "synthetic-single-book", withExtension: "m4b")
    )

    let inspectedMP3 = try await AVFoundationAudioInspector().inspect(url: mp3)
    XCTAssertEqual(inspectedMP3.container, "MP3")
    XCTAssertEqual(inspectedMP3.title, "Synthetic MP3 Chapter")
    XCTAssertEqual(inspectedMP3.authors, ["Player Test Generator"])
    XCTAssertEqual(inspectedMP3.durationSeconds, 1.8, accuracy: 0.02)
    XCTAssertEqual(inspectedMP3.chapters.map(\.source), [.file])

    let inspectedM4B = try await AVFoundationAudioInspector().inspect(url: m4b)
    XCTAssertEqual(inspectedM4B.container, "M4B")
    XCTAssertEqual(inspectedM4B.durationSeconds, 2.1, accuracy: 0.02)
    XCTAssertEqual(inspectedM4B.chapters.map(\.source), [.file])
  }

  func testEmbeddedChapterTimelineIsStableOrderedAndClamped() throws {
    let chapters = ChapterTimeline.embeddedChapters(
      [
        EmbeddedChapterCandidate(title: " Third ", startSeconds: 20, durationSeconds: 30),
        EmbeddedChapterCandidate(title: "First", startSeconds: 0, durationSeconds: 25),
        EmbeddedChapterCandidate(title: nil, startSeconds: 10, durationSeconds: 0),
        EmbeddedChapterCandidate(title: "Invalid", startSeconds: 99, durationSeconds: 1),
      ],
      assetDurationSeconds: 30
    )

    XCTAssertEqual(chapters.map(\.id), ["embedded-0-0", "embedded-1-10000", "embedded-2-20000"])
    XCTAssertEqual(chapters.map(\.title), ["First", "Chapter 2", "Third"])
    XCTAssertEqual(chapters.map(\.startSeconds), [0, 10, 20])
    XCTAssertEqual(chapters.map(\.durationSeconds), [10, 10, 10])
    XCTAssertTrue(chapters.allSatisfy { $0.source == .embedded })
  }

  func testContributorParserPreservesCommaNamesAndSplitsExplicitSeparators() {
    XCTAssertEqual(
      ContributorParser.names(from: "Doe, Jane; Roe, Richard\nAlex Smith"),
      ["Doe, Jane", "Roe, Richard", "Alex Smith"]
    )
  }

  func testInspectedMetadataAndChaptersReachCommittedBook() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory.appending(
      path: "PlayerMetadataTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let bundled = try XCTUnwrap(
      Bundle(for: PlayerCoreTests.self).url(forResource: "01-opening-tone", withExtension: "m4a")
    )
    let source = temporaryRoot.appending(path: "source.m4a")
    try FileManager.default.copyItem(at: bundled, to: source)
    let ids = (1...4).map {
      UUID(uuidString: String(format: "80000000-0000-0000-0000-%012d", $0))!
    }
    let chapter = Chapter(
      id: "embedded-0-0",
      title: "Opening",
      startSeconds: 0,
      durationSeconds: 1.8,
      source: .embedded,
      assetID: nil
    )
    let model = PlayerModel(
      environment: PlayerEnvironment(
        persistence: InMemoryLibraryStore(),
        media: FileSystemMediaManager(rootURL: temporaryRoot.appending(path: "Storage")),
        inspector: DeterministicAudioInspector(
          result: .success(
            InspectedAudio(
              title: "Synthetic Journey",
              authors: ["Mara Vale"],
              durationSeconds: 1.8,
              artworkData: Data([0x89, 0x50, 0x4E, 0x47]),
              container: "M4A",
              narrators: ["Alex Reader"],
              seriesName: "Signal Archives",
              seriesPosition: "2.5",
              artworkMediaType: "image/png",
              chapters: [chapter]
            )
          )
        ),
        playback: DeterministicPlaybackController(),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    )

    await model.restore()
    let importedJobID = await model.importAudio(from: source)
    let jobID = try XCTUnwrap(importedJobID)
    let proposal = try XCTUnwrap(model.library.importJobs.first?.proposal)
    XCTAssertEqual(proposal.narrators, ["Alex Reader"])
    XCTAssertEqual(proposal.seriesName, "Signal Archives")
    XCTAssertEqual(proposal.seriesPosition, "2.5")
    XCTAssertEqual(proposal.chapters.first?.assetID, proposal.asset.id)

    let committedBookID = await model.addImportToLibrary(jobID: jobID)
    let bookID = try XCTUnwrap(committedBookID)
    let book = try XCTUnwrap(model.library.books.first(where: { $0.id == bookID }))
    XCTAssertEqual(book.narrators, ["Alex Reader"])
    XCTAssertEqual(book.seriesName, "Signal Archives")
    XCTAssertEqual(book.seriesPosition, "2.5")
    XCTAssertEqual(book.artworkMediaType, "image/png")
    XCTAssertEqual(book.chapters.first?.title, "Opening")
  }

  func testMetadataRepairCoversEveryMVPFieldAndUndoRestoresOneAtomicSnapshot() async throws {
    let bookID = UUID(uuidString: "81000000-0000-0000-0000-000000000001")!
    let asset = AudioAsset(
      id: UUID(uuidString: "81000000-0000-0000-0000-000000000002")!,
      originalFilename: "immutable.m4b",
      managedRelativePath: "Media/immutable.m4b",
      checksumSHA256: "immutable-checksum",
      byteCount: 123,
      durationSeconds: 60,
      container: "M4B"
    )
    let embeddedCover = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
    let originalMetadata = AudiobookMetadata.imported(
      title: "The Brass Lantern",
      authors: ["Mira Sol"],
      narrators: ["Anika Reed"],
      seriesName: "Night Signals",
      seriesPosition: "4",
      artworkData: embeddedCover,
      artworkMediaType: "image/png"
    )
    let book = Book(
      id: bookID,
      title: originalMetadata.title,
      authors: originalMetadata.authors.map(\.displayName),
      durationSeconds: 60,
      artworkData: embeddedCover,
      assets: [asset],
      dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
      narrators: originalMetadata.narrators.map(\.displayName),
      seriesName: "Night Signals",
      seriesPosition: "4",
      artworkMediaType: "image/png",
      metadata: originalMetadata
    )
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [book], importJobs: [], currentBookID: nil
    ))
    let transactionID = UUID(uuidString: "81000000-0000-0000-0000-000000000003")!
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: FileSystemMediaManager(rootURL: FileManager.default.temporaryDirectory),
      inspector: AVFoundationAudioInspector(),
      playback: DeterministicPlaybackController(),
      clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_100)),
      ids: DeterministicPlayerIDGenerator(values: [transactionID])
    ))
    await model.restore()

    let replacementCover = CoverArtwork(
      originalData: Data([0x89, 0x50, 0x4E, 0x47, 0x02]),
      mediaType: "image/png",
      source: .file,
      crop: CoverCrop(x: 0.1, y: 0.2, width: 0.8, height: 0.7, rotationDegrees: 90)
    )
    let repairedID = await model.repairBookMetadata(bookID: bookID, mutations: [
      .set(.title, value: .text("The Amber Signal")),
      .set(.sortTitle, value: .text("Amber Signal, The")),
      .set(.subtitle, value: .text("A Night Signals Story")),
      .set(.authors, value: .contributors([
        Contributor(displayName: "Mira Sol", sortName: "Sol, Mira"),
        Contributor(displayName: "Ivo Quill"),
      ])),
      .clear(.narrators),
      .set(.seriesName, value: .seriesMemberships([
        SeriesMembership(name: "Night Signals", position: "4.5")
      ])),
      .setLocked(.seriesName, locked: true),
      .set(.description, value: .text("A repaired local description.")),
      .set(.genres, value: .textList(["Mystery", "Science Fiction"])),
      .set(.tags, value: .textList(["Favorite", "Night"])),
      .set(.language, value: .text("en-CA")),
      .set(.publicationYear, value: .publicationYear(2026)),
      .set(.publisher, value: .text("Signal House")),
      .set(.edition, value: .text("Anniversary")),
      .set(.abridgement, value: .abridgement(.unabridged)),
      .clear(.cover),
      .set(.cover, value: .cover(replacementCover)),
    ])

    XCTAssertEqual(repairedID, transactionID)
    let repaired = try XCTUnwrap(model.library.books.first)
    XCTAssertEqual(repaired.title, "The Amber Signal")
    XCTAssertEqual(repaired.authors, ["Mira Sol", "Ivo Quill"])
    XCTAssertEqual(repaired.narrators, [])
    XCTAssertEqual(repaired.seriesPosition, "4.5")
    XCTAssertEqual(repaired.metadata.sortTitle, "Amber Signal, The")
    XCTAssertEqual(repaired.metadata.subtitle, "A Night Signals Story")
    XCTAssertEqual(repaired.metadata.description, "A repaired local description.")
    XCTAssertEqual(repaired.metadata.genres, ["Mystery", "Science Fiction"])
    XCTAssertEqual(repaired.metadata.tags, ["Favorite", "Night"])
    XCTAssertEqual(repaired.metadata.language, "en-CA")
    XCTAssertEqual(repaired.metadata.publicationYear, 2026)
    XCTAssertEqual(repaired.metadata.publisher, "Signal House")
    XCTAssertEqual(repaired.metadata.edition, "Anniversary")
    XCTAssertEqual(repaired.metadata.abridgement, .unabridged)
    XCTAssertEqual(repaired.metadata.cover, replacementCover)
    XCTAssertEqual(repaired.metadata.state(for: .title)?.provenance, .user)
    XCTAssertTrue(repaired.metadata.state(for: .title)?.isLocked == true)
    XCTAssertTrue(repaired.metadata.state(for: .narrators)?.isExplicitlyCleared == true)
    XCTAssertTrue(repaired.metadata.state(for: .seriesName)?.isLocked == true)
    XCTAssertEqual(repaired.metadata.state(for: .cover)?.lastTransactionID, transactionID)
    XCTAssertEqual(repaired.assets, [asset], "Metadata repair must not mutate managed-audio state")
    XCTAssertEqual(model.library.metadataTransactions.count, 1)

    let didUndo = await model.undoLastMetadataTransaction(for: .book(bookID))
    XCTAssertTrue(didUndo)
    let restored = try XCTUnwrap(model.library.books.first)
    XCTAssertEqual(restored.metadata, originalMetadata)
    XCTAssertEqual(restored.title, "The Brass Lantern")
    XCTAssertEqual(restored.narrators, ["Anika Reed"])
    XCTAssertEqual(restored.artworkData, embeddedCover)
    XCTAssertEqual(restored.assets, [asset])
    XCTAssertEqual(model.library.metadataTransactions.first?.status, .undone)
    let didUndoTwice = await model.undoLastMetadataTransaction(for: .book(bookID))
    XCTAssertFalse(didUndoTwice)
  }

  func testProposalMetadataTransactionRetargetsToCommittedBookAndUndoPreservesAudio() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "PlayerMetadataCommitTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "proposal.m4a")
    try FileManager.default.copyItem(at: try fixtureToneURL(), to: source)
    let originalChecksum = try checksum(source)
    let ids = (1...5).map {
      UUID(uuidString: String(format: "82000000-0000-0000-0000-%012d", $0))!
    }
    let media = FileSystemMediaManager(rootURL: root.appending(path: "Storage"))
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: InMemoryLibraryStore(),
      media: media,
      inspector: DeterministicAudioInspector(result: .success(InspectedAudio(
        title: "Original Proposal",
        authors: ["Embedded Author"],
        durationSeconds: 1.8,
        artworkData: Data([1, 2, 3]),
        container: "M4A",
        narrators: ["Embedded Narrator"],
        artworkMediaType: "image/png"
      ))),
      playback: DeterministicPlaybackController(),
      ids: DeterministicPlayerIDGenerator(values: ids)
    ))
    await model.restore()
    let importedJobID = await model.importAudio(from: source)
    let jobID = try XCTUnwrap(importedJobID)
    let originalProposal = try XCTUnwrap(model.library.importJobs.first?.proposal)
    let repairedTransactionID = await model.repairProposalMetadata(
      jobID: jobID,
      proposalID: originalProposal.id,
      mutations: [
        .set(.title, value: .text("Repaired Proposal")),
        .clear(.narrators),
      ]
    )
    let transactionID = try XCTUnwrap(repairedTransactionID)
    let committedBookID = await model.addImportToLibrary(jobID: jobID)
    let bookID = try XCTUnwrap(committedBookID)

    XCTAssertEqual(model.library.metadataTransactions.first?.id, transactionID)
    XCTAssertEqual(model.library.metadataTransactions.first?.target, .book(bookID))
    XCTAssertEqual(model.library.books.first?.title, "Repaired Proposal")
    XCTAssertEqual(model.library.books.first?.narrators, [])
    let managedPath = try XCTUnwrap(model.library.books.first?.assets.first?.managedRelativePath)
    let managedURL = try await media.managedURL(for: managedPath)
    XCTAssertEqual(try checksum(source), originalChecksum)
    XCTAssertEqual(try checksum(managedURL), originalChecksum)

    let didUndo = await model.undoLastMetadataTransaction(for: .book(bookID))
    XCTAssertTrue(didUndo)
    XCTAssertEqual(model.library.books.first?.metadata, originalProposal.metadata)
    XCTAssertEqual(model.library.books.first?.title, "Original Proposal")
    XCTAssertEqual(model.library.books.first?.narrators, ["Embedded Narrator"])
    XCTAssertEqual(try checksum(source), originalChecksum)
    XCTAssertEqual(try checksum(managedURL), originalChecksum)
  }

  func testLockedExplicitClearCannotBeRepopulatedByAutomatedMetadata() throws {
    var metadata = AudiobookMetadata.imported(
      title: "Locked Book",
      authors: [],
      narrators: ["Original Narrator"],
      seriesName: nil,
      seriesPosition: nil,
      artworkData: nil,
      artworkMediaType: nil
    )
    let clearTransaction = UUID(uuidString: "82500000-0000-0000-0000-000000000001")!
    try metadata.apply(.clear(.narrators), transactionID: clearTransaction)

    XCTAssertTrue(metadata.narrators.isEmpty)
    XCTAssertTrue(metadata.state(for: .narrators)?.isExplicitlyCleared == true)
    XCTAssertThrowsError(try metadata.apply(
      .set(
        .narrators,
        value: .contributors([Contributor(displayName: "Rescan Narrator")]),
        provenance: .embeddedTag,
        confidence: .high,
        lock: false
      ),
      transactionID: UUID(uuidString: "82500000-0000-0000-0000-000000000002")!
    )) { error in
      XCTAssertEqual(error as? MetadataRepairError, .fieldLocked(.narrators))
    }
    XCTAssertTrue(metadata.narrators.isEmpty)
    XCTAssertEqual(metadata.state(for: .narrators)?.lastTransactionID, clearTransaction)
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

  func testRemoteCommandsUseTheSameDurablePlaybackPaths() async throws {
    let harness = makeBackgroundPlaybackHarness()
    await harness.model.restore()
    harness.model.configurePlaybackIntegrations()
    harness.model.configurePlaybackIntegrations()

    XCTAssertEqual(harness.audioSession.configureCount, 1)
    XCTAssertEqual(harness.remoteCommands.installationCount, 1)

    await harness.remoteCommands.send(.play)
    XCTAssertEqual(harness.model.playbackState.status, .playing)
    await harness.remoteCommands.send(.pause)
    XCTAssertEqual(harness.model.playbackState.status, .paused)
    await harness.remoteCommands.send(.togglePlayPause)
    XCTAssertEqual(harness.model.playbackState.status, .playing)
    await harness.remoteCommands.send(.skipForward(seconds: 30))
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 30)
    await harness.remoteCommands.send(.skipBackward(seconds: 15))
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 15)
    await harness.remoteCommands.send(.changePosition(seconds: 42))
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 42)
    await harness.remoteCommands.send(.togglePlayPause)
    XCTAssertEqual(harness.model.playbackState.status, .paused)

    XCTAssertEqual(harness.audioSession.activateCount, 2)
    XCTAssertEqual(
      harness.model.library.positionJournal.map(\.reason),
      [.play, .pause, .play, .seek, .seek, .seek, .pause]
    )
    let persisted = await harness.store.load()
    XCTAssertEqual(persisted.playbackPosition?.positionMilliseconds, 42_000)
  }

  func testBackgroundCheckpointPersistsAcknowledgedEnginePosition() async throws {
    let harness = makeBackgroundPlaybackHarness()
    await harness.model.restore()
    harness.model.configurePlaybackIntegrations()
    await harness.model.play(bookID: harness.book.id)
    await harness.playback.seek(to: 63.4567)

    await harness.model.checkpointForBackground()

    XCTAssertEqual(harness.model.library.positionJournal.last?.reason, .background)
    XCTAssertEqual(harness.model.library.playbackPosition?.positionMilliseconds, 63_456)
    let persisted = await harness.store.load()
    XCTAssertEqual(persisted.playbackPosition?.positionMilliseconds, 63_456)
    XCTAssertEqual(
      try XCTUnwrap(harness.nowPlaying.latest?.elapsedSeconds),
      63.456,
      accuracy: 0.000_1
    )
    XCTAssertEqual(harness.nowPlaying.latest?.playbackRate, 1)
  }

  func testBackgroundTransitionDoesNotDuplicateAnAlreadyDurablePause() async throws {
    let harness = makeBackgroundPlaybackHarness()
    await harness.model.restore()
    harness.model.configurePlaybackIntegrations()
    await harness.model.play(bookID: harness.book.id)
    await harness.model.pause()
    let eventsBeforeBackground = harness.model.library.positionJournal

    await harness.model.checkpointForBackground()

    XCTAssertEqual(harness.model.library.positionJournal, eventsBeforeBackground)
    XCTAssertEqual(harness.model.library.positionJournal.last?.reason, .pause)
  }

  func testInterruptionAndOldDeviceLossPauseAndCheckpoint() async throws {
    let harness = makeBackgroundPlaybackHarness()
    await harness.model.restore()
    harness.model.configurePlaybackIntegrations()
    await harness.model.play(bookID: harness.book.id)

    await harness.audioSession.send(.interruptionBegan)
    XCTAssertEqual(harness.model.playbackState.status, .paused)
    XCTAssertEqual(harness.model.library.positionJournal.last?.reason, .interruption)
    XCTAssertEqual(harness.nowPlaying.latest?.playbackRate, 0)

    await harness.audioSession.send(.interruptionEnded(shouldResume: true))
    XCTAssertEqual(harness.model.playbackState.status, .playing)
    XCTAssertEqual(harness.model.library.positionJournal.last?.reason, .play)

    await harness.audioSession.send(.oldDeviceUnavailable)
    XCTAssertEqual(harness.model.playbackState.status, .paused)
    XCTAssertEqual(harness.model.library.positionJournal.last?.reason, .routeChange)
    XCTAssertEqual(harness.nowPlaying.latest?.playbackRate, 0)
    XCTAssertEqual(harness.audioSession.activateCount, 2)
  }

  func testNowPlayingPublishesBookChapterElapsedAndRate() async throws {
    let harness = makeBackgroundPlaybackHarness()
    await harness.model.restore()
    harness.model.configurePlaybackIntegrations()
    await harness.model.play(bookID: harness.book.id)
    await harness.model.seek(to: 42.25)

    let playing = try XCTUnwrap(harness.nowPlaying.latest)
    XCTAssertEqual(playing.bookID, harness.book.id)
    XCTAssertEqual(playing.title, "Background Journey")
    XCTAssertEqual(playing.authors, ["Mara Vale"])
    XCTAssertEqual(playing.narrators, ["Alex Reader"])
    XCTAssertEqual(playing.seriesName, "Signal Archives")
    XCTAssertEqual(playing.chapterTitle, "Middle")
    XCTAssertEqual(playing.durationSeconds, 120)
    XCTAssertEqual(playing.elapsedSeconds, 42.25)
    XCTAssertEqual(playing.playbackRate, 1)

    await harness.model.pause()
    let paused = try XCTUnwrap(harness.nowPlaying.latest)
    XCTAssertEqual(paused.elapsedSeconds, 42.25)
    XCTAssertEqual(paused.playbackRate, 0)
  }

  func testAudioSessionConfigurationAndActivationFailuresAreObservable() async throws {
    let configurationHarness = makeBackgroundPlaybackHarness()
    await configurationHarness.model.restore()
    configurationHarness.audioSession.configureError = PlayerCoreError.fileOperation(
      "Audio session configuration failed."
    )

    configurationHarness.model.configurePlaybackIntegrations()

    XCTAssertEqual(configurationHarness.audioSession.configureCount, 1)
    XCTAssertEqual(configurationHarness.remoteCommands.installationCount, 0)
    XCTAssertEqual(
      configurationHarness.model.lastErrorMessage,
      "Audio session configuration failed."
    )

    let activationHarness = makeBackgroundPlaybackHarness()
    await activationHarness.model.restore()
    activationHarness.model.configurePlaybackIntegrations()
    activationHarness.audioSession.activationError = PlayerCoreError.fileOperation(
      "Audio session activation failed."
    )

    await activationHarness.remoteCommands.send(.play)

    XCTAssertEqual(activationHarness.model.playbackState.status, .paused)
    XCTAssertTrue(activationHarness.model.library.positionJournal.isEmpty)
    XCTAssertEqual(activationHarness.model.lastErrorMessage, "Audio session activation failed.")
  }

  func testInterruptionWithoutResumePermissionRemainsPaused() async throws {
    let harness = makeBackgroundPlaybackHarness()
    await harness.model.restore()
    harness.model.configurePlaybackIntegrations()
    await harness.model.play(bookID: harness.book.id)

    await harness.audioSession.send(.interruptionBegan)
    await harness.audioSession.send(.interruptionEnded(shouldResume: false))

    XCTAssertEqual(harness.model.playbackState.status, .paused)
    XCTAssertEqual(harness.audioSession.activateCount, 1)
    XCTAssertEqual(harness.model.library.positionJournal.map(\.reason), [.play, .interruption])
  }

  func testRemoteSkipAndPositionCommandsClampToBookBounds() async throws {
    let harness = makeBackgroundPlaybackHarness()
    await harness.model.restore()
    harness.model.configurePlaybackIntegrations()
    await harness.remoteCommands.send(.play)

    await harness.remoteCommands.send(.skipBackward(seconds: 15))
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 0)
    await harness.remoteCommands.send(.skipForward(seconds: 1_000))
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 120)
    await harness.remoteCommands.send(.changePosition(seconds: -20))
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 0)
    await harness.remoteCommands.send(.changePosition(seconds: 50.25))
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 50.25)
    XCTAssertEqual(harness.model.library.playbackPosition?.positionMilliseconds, 50_250)
  }

  func testNaturalTrackOrderingUsesEmbeddedNumbersThenStableFilenameOrder() {
    func asset(_ suffix: Int, _ name: String, disc: Int? = nil, track: Int? = nil) -> AudioAsset {
      AudioAsset(
        id: UUID(uuidString: String(format: "a0000000-0000-0000-0000-%012d", suffix))!,
        originalFilename: name,
        managedRelativePath: "",
        checksumSHA256: "\(suffix)",
        byteCount: 1,
        durationSeconds: 10,
        container: "M4A",
        discNumber: disc,
        trackNumber: track
      )
    }
    let explicitSecond = asset(1, "z.m4a", disc: 1, track: 2)
    let explicitFirst = asset(2, "y.m4a", disc: 1, track: 1)
    let ten = asset(3, "Signal Part 10.m4a")
    let prelude = asset(4, "Prélude.m4a")
    let two = asset(5, "Signal Part 2.m4a")
    let stableA = asset(6, "same.m4a")
    let stableB = asset(7, "same.m4a")

    let result = NaturalTrackOrdering.order([
      ten, explicitSecond, prelude, stableA, explicitFirst, two, stableB,
    ])

    XCTAssertEqual(
      result.assets.map(\.id),
      [explicitFirst.id, explicitSecond.id, two.id, ten.id, prelude.id, stableA.id, stableB.id]
    )
    XCTAssertEqual(result.assets.map(\.importOrder), Array(0..<7))
    XCTAssertEqual(result.evidence.prefix(2).map(\.source), [.embeddedDiscTrack, .embeddedDiscTrack])
    XCTAssertEqual(result.evidence[2].source, .filenameNumbers)
  }

  func testFolderAndLooseSelectionProducesExplainableGroupsAndDurableRepairs() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "PlayerMultifileTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeMessySelection(at: root)
    let media = FileSystemMediaManager(rootURL: root.appending(path: "Storage"))
    let store = InMemoryLibraryStore()
    let ids = (1...40).map {
      UUID(uuidString: String(format: "b0000000-0000-0000-0000-%012d", $0))!
    }
    let inspected = InspectedAudio(
      title: nil,
      authors: ["Fixture Author"],
      durationSeconds: 10,
      artworkData: nil,
      container: "M4A",
      chapters: [
        Chapter(
          id: "file-0",
          title: "Track",
          startSeconds: 0,
          durationSeconds: 10,
          source: .file,
          assetID: nil
        )
      ]
    )
    let model = PlayerModel(
      environment: PlayerEnvironment(
        persistence: store,
        media: media,
        inspector: DeterministicAudioInspector(result: .success(inspected)),
        playback: DeterministicPlaybackController(),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    )

    await model.restore()
    let importedJobID = await model.importAudioSelection(from: [fixture.folder] + fixture.looseFiles)
    let jobID = try XCTUnwrap(importedJobID)
    var job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.phase, .needsReview)
    XCTAssertEqual(job.reviewRevision, 0)
    XCTAssertEqual(job.stagedAssets.count, 8)
    XCTAssertEqual(job.proposals.count, 2)
    XCTAssertEqual(job.proposals.flatMap(\.warnings).count, 2)
    XCTAssertEqual(
      job.proposals[0].assets.map(\.originalFilename),
      ["Signal Part 1.m4a", "Signal Part 2.m4a", "Signal Part 10.m4a", "Prélude.m4a"]
    )
    XCTAssertEqual(
      job.proposals[1].assets.map(\.originalFilename),
      ["L’Écho piste 3.m4a", "L’Écho piste 4 café.m4a", "L’Écho piste 5.m4a", "L’Écho piste 6 fin.m4a"]
    )
    XCTAssertTrue(job.proposals[0].groupingEvidence.contains { $0.kind == .commonFolder })
    XCTAssertTrue(job.proposals[1].groupingEvidence.contains { $0.kind == .filenameStem })
    XCTAssertEqual(job.proposals.flatMap(\.assets).map(\.timelineStartSeconds), [0, 10, 20, 30, 0, 10, 20, 30])
    XCTAssertTrue(job.proposals.flatMap(\.chapters).allSatisfy { $0.assetID != nil })

    let proposalA = job.proposals[0]
    let proposalB = job.proposals[1]
    let b4 = proposalB.assets[1]
    let moved = await model.moveAssets(
      jobID: jobID,
      assetIDs: [b4.id],
      from: proposalB.id,
      to: proposalA.id
    )
    XCTAssertTrue(moved)
    job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.reviewRevision, 1)

    let reorderedA = try XCTUnwrap(job.proposals.first(where: { $0.id == proposalA.id }))
    let manualOrder = [reorderedA.assets[3].id] + reorderedA.assets.enumerated()
      .filter { $0.offset != 3 }.map(\.element.id)
    let reordered = await model.reorderAssets(
      jobID: jobID,
      proposalID: proposalA.id,
      assetIDs: manualOrder
    )
    XCTAssertTrue(reordered)
    job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.reviewRevision, 2)

    let currentB = try XCTUnwrap(job.proposals.first(where: { $0.id == proposalB.id }))
    let didSplit = await model.splitProposal(
      jobID: jobID,
      proposalID: proposalB.id,
      assetIDs: [currentB.assets[0].id]
    )
    XCTAssertTrue(didSplit)
    job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.reviewRevision, 3)
    XCTAssertEqual(job.proposals.count, 3)
    let splitID = job.proposals[2].id
    let mergedSplit = await model.mergeProposals(
      jobID: jobID,
      sourceProposalID: splitID,
      into: proposalB.id
    )
    XCTAssertTrue(mergedSplit)
    let mergedAll = await model.mergeProposals(
      jobID: jobID,
      sourceProposalID: proposalB.id,
      into: proposalA.id
    )
    XCTAssertTrue(mergedAll)

    job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.reviewRevision, 5)
    XCTAssertEqual(job.phase, .ready)
    XCTAssertEqual(job.proposals.count, 1)
    XCTAssertEqual(job.proposals[0].assets.count, 8)
    XCTAssertTrue(job.proposals[0].warnings.isEmpty)
    XCTAssertEqual(job.proposals[0].assets.map(\.timelineStartSeconds), stride(from: 0.0, to: 80, by: 10).map { $0 })
    XCTAssertEqual(job.proposals[0].chapters.map(\.startSeconds), stride(from: 0.0, to: 80, by: 10).map { $0 })
    let persisted = await store.load()
    XCTAssertEqual(persisted.importJobs.first?.reviewRevision, 5)

    let sourceChecksums = try fixture.allFiles.map(checksum)
    let committedBookID = await model.addImportToLibrary(jobID: jobID)
    let bookID = try XCTUnwrap(committedBookID)
    let book = try XCTUnwrap(model.library.books.first(where: { $0.id == bookID }))
    XCTAssertEqual(book.assets.count, 8)
    XCTAssertEqual(book.chapters.count, 8)
    XCTAssertEqual(try fixture.allFiles.map(checksum), sourceChecksums)
    for asset in book.assets {
      _ = try await media.managedURL(for: asset.managedRelativePath)
    }
  }

  func testMultifileCommitRollsBackEveryMovedAssetBeforePublishingBook() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "PlayerAtomicImportTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tone = try fixtureToneURL()
    let first = root.appending(path: "Book Part 1.m4a")
    let second = root.appending(path: "Book Part 2.m4a")
    try FileManager.default.copyItem(at: tone, to: first)
    try FileManager.default.copyItem(at: tone, to: second)
    let media = FileSystemMediaManager(rootURL: root.appending(path: "Storage"))
    let store = InMemoryLibraryStore()
    let ids = (1...8).map {
      UUID(uuidString: String(format: "c0000000-0000-0000-0000-%012d", $0))!
    }
    let model = PlayerModel(
      environment: PlayerEnvironment(
        persistence: store,
        media: media,
        inspector: DeterministicAudioInspector(
          result: .success(
            InspectedAudio(
              title: "Book",
              authors: [],
              durationSeconds: 10,
              artworkData: nil,
              container: "M4A"
            )
          )
        ),
        playback: DeterministicPlaybackController(),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    )
    await model.restore()
    let importedJobID = await model.importAudioSelection(from: [first, second])
    let jobID = try XCTUnwrap(importedJobID)
    let ready = try XCTUnwrap(model.library.importJobs.first)
    XCTAssertEqual(ready.phase, .ready)
    let firstStaged = try XCTUnwrap(ready.stagedAssets.first)
    let secondStaged = ready.stagedAssets[1]
    let missingURL = try await media.stagedURL(for: secondStaged.stagedRelativePath)
    try FileManager.default.removeItem(at: missingURL)

    let committedBookID = await model.addImportToLibrary(jobID: jobID)
    XCTAssertNil(committedBookID)
    XCTAssertTrue(model.library.books.isEmpty)
    XCTAssertEqual(model.library.importJobs.first?.phase, .ready)
    let rolledBackURL = try await media.stagedURL(for: firstStaged.stagedRelativePath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: rolledBackURL.path))
    let persisted = await store.load()
    XCTAssertTrue(persisted.books.isEmpty)
    XCTAssertEqual(persisted.importJobs.first?.phase, .ready)
  }

  func testRestoreAutomaticallyResumesInterruptedDocumentOpenAcquisition() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "PlayerResumeTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "airdrop-book.m4a")
    try FileManager.default.copyItem(at: try fixtureToneURL(), to: source)
    let jobID = UUID(uuidString: "92000000-0000-0000-0000-000000000001")!
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let interrupted = ImportJob(
      id: jobID,
      sourceFilename: source.lastPathComponent,
      phase: .acquiring,
      progress: .none,
      createdAt: now,
      updatedAt: now,
      queueCheckpoint: ImportQueueCheckpoint(
        entryPoint: .documentOpen,
        sources: [DurableImportSource(
          displayName: source.lastPathComponent,
          bookmarkData: nil,
          fallbackURLString: source.absoluteString,
          isDirectory: false
        )]
      )
    )
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [], importJobs: [interrupted], currentBookID: nil
    ))
    let ids = (2...5).map {
      UUID(uuidString: String(format: "92000000-0000-0000-0000-%012d", $0))!
    }
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: FileSystemMediaManager(rootURL: root.appending(path: "Storage")),
      inspector: AVFoundationAudioInspector(),
      playback: DeterministicPlaybackController(),
      clock: FixedPlayerClock(value: now),
      ids: DeterministicPlayerIDGenerator(values: ids)
    ))

    await model.restore()

    let resumed = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(resumed.phase, .ready)
    XCTAssertEqual(resumed.queueCheckpoint?.entryPoint, .documentOpen)
    XCTAssertTrue(resumed.queueCheckpoint?.acquisitionComplete == true)
    XCTAssertEqual(resumed.queueCheckpoint?.inspected.count, 1)
    XCTAssertEqual(resumed.proposals.first?.assets.count, 1)
  }

  func testShareHandoffValidatesContentAndDeduplicatesDurableReceipt() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "PlayerShareQueueTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "temporary-provider-name.m4a")
    try FileManager.default.copyItem(at: try fixtureToneURL(), to: source)
    let handoffID = UUID(uuidString: "93000000-0000-0000-0000-000000000001")!
    let queue = AppGroupImportHandoffQueue(containerURL: root.appending(path: "Group"))
    try await queue.enqueueCopying(
      [source],
      id: handoffID,
      originalFilenames: ["Suggested Book.m4a"]
    )
    let claimedFirst = try await queue.claimNext()
    let firstClaim = try XCTUnwrap(claimedFirst)
    XCTAssertEqual(firstClaim.handoff.items.first?.originalFilename, "Suggested Book.m4a")
    XCTAssertEqual(firstClaim.handoff.items.first?.byteCount, Int64(try Data(contentsOf: source).count))
    // Multiple scene/task drains can overlap while the first consumer imports.
    // The same Processing request must not be leased twice in one process.
    let concurrentClaim = try await queue.claimNext()
    XCTAssertNil(concurrentClaim)

    let store = InMemoryLibraryStore()
    let ids = (2...5).map {
      UUID(uuidString: String(format: "93000000-0000-0000-0000-%012d", $0))!
    }
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: FileSystemMediaManager(rootURL: root.appending(path: "Storage")),
      inspector: AVFoundationAudioInspector(),
      playback: DeterministicPlaybackController(),
      clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
      ids: DeterministicPlayerIDGenerator(values: ids)
    ))
    let importedFirstJobID = await model.importSharedHandoff(firstClaim, from: queue)
    let firstJobID = try XCTUnwrap(importedFirstJobID)
    XCTAssertEqual(model.library.shareImportReceipts.count, 1)
    XCTAssertEqual(model.library.shareImportReceipts.first?.jobID, firstJobID)

    try await queue.enqueueCopying(
      [source],
      id: handoffID,
      originalFilenames: ["Suggested Book.m4a"]
    )
    let claimedReplay = try await queue.claimNext()
    let replay = try XCTUnwrap(claimedReplay)
    let replayJobID = await model.importSharedHandoff(replay, from: queue)
    XCTAssertEqual(replayJobID, firstJobID)
    XCTAssertEqual(model.library.importJobs.count, 1)
    XCTAssertEqual(model.library.shareImportReceipts.count, 1)
    let emptyClaim = try await queue.claimNext()
    XCTAssertNil(emptyClaim)
  }

  func testShareHandoffRejectsPayloadChangedAfterPublication() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "PlayerShareTamperTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.m4a")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: source)
    let handoffID = UUID(uuidString: "94000000-0000-0000-0000-000000000001")!
    let group = root.appending(path: "Group")
    let queue = AppGroupImportHandoffQueue(containerURL: group)
    try await queue.enqueueCopying([source], id: handoffID)
    let item = group.appending(
      path: "ImportHandoffs/Pending/\(handoffID.uuidString.lowercased())/Items/00000.m4a"
    )
    try Data("changed".utf8).write(to: item)

    do {
      _ = try await queue.claimNext()
      XCTFail("A changed handoff payload must not be claimed")
    } catch let error as ShareImportHandoffError {
      XCTAssertEqual(error, .invalidPayload)
    }
  }

  private func checksum(_ url: URL) throws -> String {
    let digest = SHA256.hash(data: try Data(contentsOf: url))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func fixtureToneURL() throws -> URL {
    try XCTUnwrap(
      Bundle(for: PlayerCoreTests.self).url(forResource: "01-opening-tone", withExtension: "m4a")
    )
  }

  private func makeMessySelection(
    at root: URL
  ) throws -> (folder: URL, looseFiles: [URL], allFiles: [URL]) {
    let tone = try fixtureToneURL()
    let folder = root.appending(path: "Signal Folder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let folderNames = [
      "Signal Part 10.m4a", "Prélude.m4a", "Signal Part 2.m4a", "Signal Part 1.m4a",
    ]
    let looseNames = [
      "L’Écho piste 3.m4a", "L’Écho piste 4 café.m4a",
      "L’Écho piste 5.m4a", "L’Écho piste 6 fin.m4a",
    ]
    let folderFiles = try folderNames.map { name in
      let destination = folder.appending(path: name)
      try FileManager.default.copyItem(at: tone, to: destination)
      return destination
    }
    let looseFiles = try looseNames.map { name in
      let destination = root.appending(path: name)
      try FileManager.default.copyItem(at: tone, to: destination)
      return destination
    }
    return (folder, looseFiles, folderFiles + looseFiles)
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

  private func makeBackgroundPlaybackHarness() -> BackgroundPlaybackHarness {
    let bookID = UUID(uuidString: "90000000-0000-0000-0000-000000000001")!
    let assetID = UUID(uuidString: "90000000-0000-0000-0000-000000000002")!
    let book = Book(
      id: bookID,
      title: "Background Journey",
      authors: ["Mara Vale"],
      durationSeconds: 120,
      artworkData: nil,
      assets: [
        AudioAsset(
          id: assetID,
          originalFilename: "background.m4b",
          managedRelativePath: "Media/background.m4b",
          checksumSHA256: "fixture",
          byteCount: 1,
          durationSeconds: 120,
          container: "M4B"
        )
      ],
      dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
      narrators: ["Alex Reader"],
      seriesName: "Signal Archives",
      seriesPosition: "1",
      chapters: [
        Chapter(
          id: "opening",
          title: "Opening",
          startSeconds: 0,
          durationSeconds: 40,
          source: .embedded,
          assetID: assetID
        ),
        Chapter(
          id: "middle",
          title: "Middle",
          startSeconds: 40,
          durationSeconds: 80,
          source: .embedded,
          assetID: assetID
        ),
      ]
    )
    let store = InMemoryLibraryStore(
      snapshot: LibrarySnapshot(books: [book], importJobs: [], currentBookID: book.id)
    )
    let playback = DeterministicPlaybackController()
    let audioSession = DeterministicAudioSessionController()
    let remoteCommands = DeterministicRemoteCommandController()
    let nowPlaying = DeterministicNowPlayingPublisher()
    let identifiers = (1...20).map {
      UUID(uuidString: String(format: "91000000-0000-0000-0000-%012d", $0))!
    }
    let model = PlayerModel(
      environment: PlayerEnvironment(
        persistence: store,
        media: StubMediaManager(),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: playback,
        audioSession: audioSession,
        remoteCommands: remoteCommands,
        nowPlaying: nowPlaying,
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: identifiers)
      )
    )
    return BackgroundPlaybackHarness(
      book: book,
      model: model,
      store: store,
      playback: playback,
      audioSession: audioSession,
      remoteCommands: remoteCommands,
      nowPlaying: nowPlaying
    )
  }
}

@MainActor
private struct BackgroundPlaybackHarness {
  let book: Book
  let model: PlayerModel
  let store: InMemoryLibraryStore
  let playback: DeterministicPlaybackController
  let audioSession: DeterministicAudioSessionController
  let remoteCommands: DeterministicRemoteCommandController
  let nowPlaying: DeterministicNowPlayingPublisher
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
