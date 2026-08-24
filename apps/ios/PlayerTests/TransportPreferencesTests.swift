import XCTest
@testable import Player

@MainActor
final class TransportPreferencesTests: XCTestCase {
  func testPreferenceValidationAndPartialOverrideResolution() {
    XCTAssertTrue(TransportPreferences.isValidPlaybackRate(0.5))
    XCTAssertTrue(TransportPreferences.isValidPlaybackRate(1.75))
    XCTAssertTrue(TransportPreferences.isValidPlaybackRate(3))
    XCTAssertFalse(TransportPreferences.isValidPlaybackRate(0.45))
    XCTAssertFalse(TransportPreferences.isValidPlaybackRate(1.03))
    XCTAssertFalse(TransportPreferences.isValidPlaybackRate(.nan))

    let defaults = TransportPreferences(
      playbackRate: 1.1,
      backwardSkipSeconds: 12,
      forwardSkipSeconds: 24,
      seekContext: .wholeBook
    )
    let resolved = TransportPreferenceOverride(
      playbackRate: 1.5,
      seekContext: .chapter
    ).resolved(over: defaults)
    XCTAssertEqual(resolved.playbackRate, 1.5)
    XCTAssertEqual(resolved.backwardSkipSeconds, 12)
    XCTAssertEqual(resolved.forwardSkipSeconds, 24)
    XCTAssertEqual(resolved.seekContext, .chapter)
  }

  func testTimelineMapsAssetBoundariesAndClampsChapterAndBookSeeks() throws {
    let book = makeBook()

    let beforeBoundary = try XCTUnwrap(PlaybackTimeline.location(in: book, at: 59.75))
    XCTAssertEqual(beforeBoundary.asset.id, book.assets[0].id)
    XCTAssertEqual(beforeBoundary.assetSeconds, 59.75, accuracy: 0.001)
    let boundary = try XCTUnwrap(PlaybackTimeline.location(in: book, at: 60))
    XCTAssertEqual(boundary.asset.id, book.assets[1].id)
    XCTAssertEqual(boundary.assetSeconds, 0, accuracy: 0.001)
    let afterEnd = try XCTUnwrap(PlaybackTimeline.location(in: book, at: 999))
    XCTAssertEqual(afterEnd.asset.id, book.assets[1].id)
    XCTAssertEqual(afterEnd.bookSeconds, 120)
    XCTAssertEqual(afterEnd.assetSeconds, 60)

    XCTAssertEqual(
      PlaybackTimeline.seekPosition(10, context: .chapter, in: book, from: 45),
      40
    )
    XCTAssertEqual(
      PlaybackTimeline.seekPosition(100, context: .chapter, in: book, from: 45),
      75
    )
    XCTAssertEqual(
      PlaybackTimeline.seekPosition(999, context: .wholeBook, in: book, from: 45),
      120
    )
    XCTAssertEqual(PlaybackTimeline.previousChapterPosition(in: book, at: 75), 30)
    XCTAssertEqual(PlaybackTimeline.nextChapterPosition(in: book, at: 30), 75)
    XCTAssertNil(PlaybackTimeline.previousChapterPosition(in: book, at: 0))
    XCTAssertNil(PlaybackTimeline.nextChapterPosition(in: book, at: 119))
  }

  func testPerBookTransportPersistsAndControlsMultiAssetChapterSeeking() async throws {
    let harness = makeHarness()
    await harness.model.restore()
    let global = TransportPreferences(
      playbackRate: 1.1,
      backwardSkipSeconds: 12,
      forwardSkipSeconds: 24,
      seekContext: .wholeBook
    )
    let changedGlobal = await harness.model.setGlobalTransportPreferences(global)
    let changedBook = await harness.model.setTransportPreferenceOverride(
      TransportPreferenceOverride(
        playbackRate: 1.5,
        backwardSkipSeconds: 10,
        forwardSkipSeconds: 25,
        seekContext: .chapter
      ),
      for: harness.book.id
    )
    XCTAssertTrue(changedGlobal)
    XCTAssertTrue(changedBook)

    await harness.model.play(bookID: harness.book.id, at: 45)
    XCTAssertEqual(harness.playback.playbackRate, 1.5)
    XCTAssertEqual(harness.remote.transportPreferences.playbackRate, 1.5)
    XCTAssertEqual(harness.playback.loadedURL?.lastPathComponent, "part-1.m4b")

    await harness.model.seek(to: 10, context: .chapter)
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 40, accuracy: 0.001)
    await harness.model.nextChapter()
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 75, accuracy: 0.001)
    XCTAssertEqual(harness.playback.loadedURL?.lastPathComponent, "part-2.m4b")
    XCTAssertEqual(harness.playback.currentPositionSeconds, 15, accuracy: 0.001)
    await harness.model.skipForward()
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 100, accuracy: 0.001)
    await harness.model.skipBackward()
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 90, accuracy: 0.001)

    let durable = await harness.store.load()
    XCTAssertEqual(durable.globalTransportPreferences, global)
    XCTAssertEqual(
      durable.books.first?.transportPreferenceOverride?.playbackRate,
      1.5
    )
    XCTAssertEqual(durable.playbackPosition?.positionMilliseconds, 90_000)

    let restoredPlayback = DeterministicPlaybackController()
    let restoredRemote = DeterministicRemoteCommandController()
    let restoredModel = PlayerModel(environment: PlayerEnvironment(
      persistence: harness.store,
      media: TransportMediaManager(),
      inspector: DeterministicAudioInspector(
        result: .failure(.unreadableAudio("unused"))
      ),
      playback: restoredPlayback,
      remoteCommands: restoredRemote,
      ids: DeterministicPlayerIDGenerator(values: [])
    ))
    await restoredModel.restore()
    XCTAssertEqual(restoredModel.currentTransportPreferences.playbackRate, 1.5)
    XCTAssertEqual(restoredPlayback.playbackRate, 1.5)
    XCTAssertEqual(restoredRemote.transportPreferences.forwardSkipSeconds, 25)
    XCTAssertEqual(restoredPlayback.loadedURL?.lastPathComponent, "part-2.m4b")
    XCTAssertEqual(restoredPlayback.currentPositionSeconds, 30, accuracy: 0.001)
  }

  func testRemoteCommandsUseConfiguredSkipsChaptersRateAndDurableSeekPaths() async throws {
    let harness = makeHarness()
    await harness.model.restore()
    harness.model.configurePlaybackIntegrations()
    let changed = await harness.model.setTransportPreferenceOverride(
      TransportPreferenceOverride(
        playbackRate: 1.25,
        backwardSkipSeconds: 10,
        forwardSkipSeconds: 25,
        seekContext: .chapter
      ),
      for: harness.book.id
    )
    XCTAssertTrue(changed)
    await harness.model.play(bookID: harness.book.id, at: 45)

    await harness.remote.send(.skipForward(seconds: 25))
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 70, accuracy: 0.001)
    await harness.remote.send(.skipBackward(seconds: 10))
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 60, accuracy: 0.001)
    await harness.remote.send(.previousChapter)
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 0, accuracy: 0.001)
    await harness.remote.send(.nextChapter)
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 30, accuracy: 0.001)
    await harness.remote.send(.changePosition(seconds: 119))
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 119, accuracy: 0.001)
    await harness.remote.send(.changePlaybackRate(1.75))
    XCTAssertEqual(harness.playback.playbackRate, 1.75)
    XCTAssertEqual(harness.remote.transportPreferences.playbackRate, 1.75)

    let durable = await harness.store.load()
    XCTAssertEqual(durable.playbackPosition?.positionMilliseconds, 119_000)
    XCTAssertEqual(durable.books.first?.transportPreferenceOverride?.playbackRate, 1.75)
  }

  func testSchemaNineMigratesTransportDefaultsAndWritesCurrentSchema() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "TransportMigration-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appending(path: "Library.json")
    let store = CodableLibraryStore(fileURL: fileURL)
    try await store.save(LibrarySnapshot(
      books: [makeBook()],
      importJobs: [],
      currentBookID: nil,
      globalTransportPreferences: TransportPreferences(
        playbackRate: 2,
        backwardSkipSeconds: 7,
        forwardSkipSeconds: 11,
        seekContext: .wholeBook
      )
    ))

    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    envelope["schemaVersion"] = 9
    var library = try XCTUnwrap(envelope["library"] as? [String: Any])
    library.removeValue(forKey: "globalTransportPreferences")
    var books = try XCTUnwrap(library["books"] as? [[String: Any]])
    books[0].removeValue(forKey: "transportPreferenceOverride")
    library["books"] = books
    envelope["library"] = library
    try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL, options: .atomic)

    let migrated = try await store.load()
    XCTAssertEqual(migrated.globalTransportPreferences, .default)
    XCTAssertNil(migrated.books.first?.transportPreferenceOverride)
    try await store.save(migrated)
    let current = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    XCTAssertEqual(current["schemaVersion"] as? Int, 15)
  }

  private func makeHarness() -> TransportHarness {
    let book = makeBook()
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: nil
    ))
    let playback = DeterministicPlaybackController()
    let remote = DeterministicRemoteCommandController()
    let identifiers = (1...30).map {
      UUID(uuidString: String(format: "b0000000-0000-0000-0000-%012d", $0))!
    }
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: TransportMediaManager(),
      inspector: DeterministicAudioInspector(
        result: .failure(.unreadableAudio("unused"))
      ),
      playback: playback,
      remoteCommands: remote,
      clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_800_100_000)),
      ids: DeterministicPlayerIDGenerator(values: identifiers)
    ))
    return TransportHarness(
      book: book,
      store: store,
      playback: playback,
      remote: remote,
      model: model
    )
  }

  private func makeBook() -> Book {
    let bookID = UUID(uuidString: "b1000000-0000-0000-0000-000000000001")!
    let firstID = UUID(uuidString: "b1000000-0000-0000-0000-000000000101")!
    let secondID = UUID(uuidString: "b1000000-0000-0000-0000-000000000102")!
    return Book(
      id: bookID,
      title: "Transport Atlas",
      authors: ["Mara Vale"],
      durationSeconds: 120,
      artworkData: nil,
      assets: [
        AudioAsset(
          id: firstID,
          originalFilename: "part-1.m4b",
          managedRelativePath: "Media/part-1.m4b",
          checksumSHA256: "one",
          byteCount: 1,
          durationSeconds: 60,
          container: "M4B",
          timelineStartSeconds: 0,
          importOrder: 0
        ),
        AudioAsset(
          id: secondID,
          originalFilename: "part-2.m4b",
          managedRelativePath: "Media/part-2.m4b",
          checksumSHA256: "two",
          byteCount: 1,
          durationSeconds: 60,
          container: "M4B",
          timelineStartSeconds: 60,
          importOrder: 1
        ),
      ],
      dateAdded: Date(timeIntervalSince1970: 1_800_000_000),
      chapters: [
        Chapter(
          id: "chapter-1",
          title: "First",
          startSeconds: 0,
          durationSeconds: 30,
          source: .embedded,
          assetID: firstID
        ),
        Chapter(
          id: "chapter-2",
          title: "Second",
          startSeconds: 30,
          durationSeconds: 45,
          source: .embedded,
          assetID: firstID
        ),
        Chapter(
          id: "chapter-3",
          title: "Third",
          startSeconds: 75,
          durationSeconds: 45,
          source: .embedded,
          assetID: secondID
        ),
      ]
    )
  }

}

@MainActor
private struct TransportHarness {
  var book: Book
  var store: InMemoryLibraryStore
  var playback: DeterministicPlaybackController
  var remote: DeterministicRemoteCommandController
  var model: PlayerModel
}

private actor TransportMediaManager: MediaManaging {
  func stage(sourceURL: URL, jobID: UUID) throws -> StagedAudio {
    throw PlayerCoreError.fileOperation("unused")
  }

  func stagedURL(for relativePath: String) throws -> URL {
    throw PlayerCoreError.fileOperation("unused")
  }

  func commit(_ staged: StagedAudio, bookID: UUID, assetID: UUID) throws -> ManagedAudio {
    throw PlayerCoreError.fileOperation("unused")
  }

  func rollback(_ managed: ManagedAudio) {}

  func managedURL(for relativePath: String) -> URL {
    URL(filePath: "/tmp").appending(path: relativePath)
  }

  func discardStaging(for jobID: UUID) {}
}
