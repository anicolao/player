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
    XCTAssertEqual(object["schemaVersion"] as? Int, 3)
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
