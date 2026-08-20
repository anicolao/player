import XCTest
@testable import Player

@MainActor
final class SleepTimerTests: XCTestCase {
  func testEveryPresetAndCustomDurationProduceExactDeadlines() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let book = makeBook()
    for preset in SleepTimerPreset.allCases {
      let timer = try SleepTimerPlanner.makeTimer(
        id: uuid(preset.rawValue),
        book: book,
        selection: .preset(preset),
        fadeEnabled: true,
        currentPositionSeconds: 25,
        now: now
      )
      XCTAssertEqual(timer.deadline, now.addingTimeInterval(preset.durationSeconds))
      XCTAssertNil(timer.boundaryPositionMilliseconds)
      XCTAssertEqual(timer.fadeDurationSeconds, 5)
    }

    let custom = try SleepTimerPlanner.makeTimer(
      id: uuid(90),
      book: book,
      selection: .custom(durationSeconds: 75.5),
      fadeEnabled: false,
      currentPositionSeconds: 25,
      now: now
    )
    XCTAssertEqual(custom.deadline, now.addingTimeInterval(75.5))
    XCTAssertEqual(custom.fadeDurationSeconds, 0)
    XCTAssertThrowsError(try SleepTimerPlanner.makeTimer(
      id: uuid(91),
      book: book,
      selection: .custom(durationSeconds: 0),
      fadeEnabled: false,
      currentPositionSeconds: 25,
      now: now
    ))
  }

  func testEndChapterAndEndTrackResolveCurrentLogicalBoundaries() throws {
    let book = makeBook()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let chapter = try SleepTimerPlanner.makeTimer(
      id: uuid(1),
      book: book,
      selection: .endOfChapter,
      fadeEnabled: true,
      currentPositionSeconds: 50,
      now: now
    )
    XCTAssertEqual(chapter.boundaryPositionMilliseconds, 100_000)

    let firstTrack = try SleepTimerPlanner.makeTimer(
      id: uuid(2),
      book: book,
      selection: .endOfTrack,
      fadeEnabled: false,
      currentPositionSeconds: 50,
      now: now
    )
    XCTAssertEqual(firstTrack.boundaryPositionMilliseconds, 90_000)
    let secondTrack = try SleepTimerPlanner.makeTimer(
      id: uuid(3),
      book: book,
      selection: .endOfTrack,
      fadeEnabled: false,
      currentPositionSeconds: 90,
      now: now
    )
    XCTAssertEqual(secondTrack.boundaryPositionMilliseconds, 120_000)
  }

  func testProjectionAndExpiryUseInjectedClockPositionAndPlaybackRate() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let book = makeBook()
    let duration = try SleepTimerPlanner.makeTimer(
      id: uuid(1),
      book: book,
      selection: .preset(.ten),
      fadeEnabled: true,
      currentPositionSeconds: 10,
      now: now
    )
    XCTAssertEqual(
      SleepTimerPlanner.projection(
        for: duration,
        now: now.addingTimeInterval(125),
        currentPositionSeconds: 10,
        playbackRate: 1
      ).remainingSeconds,
      475
    )
    XCTAssertFalse(SleepTimerPlanner.shouldBeginFade(
      duration,
      now: now.addingTimeInterval(594.999),
      currentPositionSeconds: 10
    ))
    XCTAssertTrue(SleepTimerPlanner.shouldBeginFade(
      duration,
      now: now.addingTimeInterval(595),
      currentPositionSeconds: 10
    ))

    let boundary = try SleepTimerPlanner.makeTimer(
      id: uuid(2),
      book: book,
      selection: .endOfChapter,
      fadeEnabled: false,
      currentPositionSeconds: 50,
      now: now
    )
    let projection = SleepTimerPlanner.projection(
      for: boundary,
      now: now,
      currentPositionSeconds: 60,
      playbackRate: 1.5
    )
    XCTAssertEqual(projection.remainingSeconds ?? 0, 40 / 1.5, accuracy: 0.001)
    XCTAssertFalse(SleepTimerPlanner.shouldBeginFade(
      boundary,
      now: now.addingTimeInterval(10_000),
      currentPositionSeconds: 99.999
    ))
    XCTAssertTrue(SleepTimerPlanner.shouldBeginFade(
      boundary,
      now: now,
      currentPositionSeconds: 100
    ))
    XCTAssertFalse(SleepTimerPlanner.hasReachedStopBoundary(
      duration,
      now: now.addingTimeInterval(599.999),
      currentPositionSeconds: 10
    ))
    XCTAssertTrue(SleepTimerPlanner.hasReachedStopBoundary(
      duration,
      now: now.addingTimeInterval(600),
      currentPositionSeconds: 10
    ))
  }

  func testPersistentTimerRestoresAndProjectsRemainingTime() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = MutableSleepTimerClock(now)
    let book = makeBook()
    let seed = snapshot(book: book, positionMilliseconds: 70_000, at: now)
    let store = InMemoryLibraryStore(snapshot: seed)
    let firstPlayback = SleepTimerPlaybackController()
    let first = makeModel(store: store, playback: firstPlayback, clock: clock)
    await first.restore()

    let timerID = await first.startSleepTimer(selection: .preset(.ten), fadeEnabled: true)
    XCTAssertEqual(timerID, uuid(1))
    XCTAssertEqual(first.activeSleepTimer?.deadline, now.addingTimeInterval(600))
    clock.advance(by: 125)
    XCTAssertEqual(first.activeSleepTimerProjection?.remainingSeconds, 475)

    let restoredPlayback = SleepTimerPlaybackController()
    let restored = makeModel(
      store: store,
      playback: restoredPlayback,
      clock: clock,
      ids: (20...30).map(uuid)
    )
    await restored.restore()
    XCTAssertEqual(restored.activeSleepTimer?.id, timerID)
    XCTAssertEqual(restored.activeSleepTimerProjection?.remainingSeconds, 475)
    let cancelled = await restored.cancelSleepTimer()
    XCTAssertTrue(cancelled)
    let durable = await store.load()
    XCTAssertNil(durable.activeSleepTimer)
    XCTAssertEqual(durable.sleepTimerHistory.last?.status, .cancelled)
  }

  func testBoundaryFadeIsObservableAndCompletionUsesAcknowledgedStop() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = MutableSleepTimerClock(now)
    let book = makeBook()
    let store = InMemoryLibraryStore(snapshot: snapshot(
      book: book,
      positionMilliseconds: 70_000,
      at: now
    ))
    let playback = SleepTimerPlaybackController()
    let model = makeModel(store: store, playback: playback, clock: clock)
    await model.restore()
    let timerID = await model.startSleepTimer(selection: .endOfTrack)
    XCTAssertEqual(timerID, uuid(1))

    playback.setPosition(seconds: 85)
    await model.evaluateSleepTimer()
    XCTAssertEqual(model.activeSleepTimer?.phase, .fading)
    XCTAssertEqual(playback.fadeDurations, [5])
    XCTAssertEqual(playback.completeFadeCount, 0)
    XCTAssertTrue(model.library.sleepTimerHistory.isEmpty)
    XCTAssertFalse(model.library.positionJournal.contains(where: { $0.reason == .sleepTimer }))

    playback.setPosition(seconds: 90)
    await model.evaluateSleepTimer()
    XCTAssertNil(model.activeSleepTimer)
    XCTAssertEqual(playback.completeFadeCount, 1)
    XCTAssertEqual(model.playbackState.status, .paused)
    XCTAssertEqual(model.playbackState.elapsedSeconds, 90, accuracy: 0.001)
    let event = try XCTUnwrap(model.library.positionJournal.last)
    let history = try XCTUnwrap(model.library.sleepTimerHistory.last)
    XCTAssertEqual(event.reason, .sleepTimer)
    XCTAssertEqual(event.positionMilliseconds, 90_000)
    XCTAssertEqual(history.actualStopPositionMilliseconds, 90_000)
    XCTAssertEqual(history.positionEventID, event.id)
    XCTAssertEqual(history.status, .completed)
    XCTAssertNotNil(model.sleepResumeContext)
  }

  func testCompletionFailureLeavesRetryableFadingTimerWithoutPartialHistory() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = MutableSleepTimerClock(now)
    let book = makeBook()
    let seed = snapshot(book: book, positionMilliseconds: 70_000, at: now)
    // Save one starts the timer, save two begins the fade, and save three is
    // the injected atomic event + history + active-clear failure.
    let store = FailingSleepTimerStore(snapshot: seed, failingSaveNumber: 3)
    let playback = SleepTimerPlaybackController()
    let model = makeModel(store: store, playback: playback, clock: clock)
    await model.restore()
    _ = await model.startSleepTimer(selection: .endOfTrack)
    playback.setPosition(seconds: 85)
    await model.evaluateSleepTimer()
    playback.setPosition(seconds: 90)
    await model.evaluateSleepTimer()

    XCTAssertEqual(model.activeSleepTimer?.phase, .fading)
    XCTAssertEqual(model.playbackState.status, .paused)
    XCTAssertTrue(model.library.sleepTimerHistory.isEmpty)
    XCTAssertFalse(model.library.positionJournal.contains(where: { $0.reason == .sleepTimer }))
    let failedDurable = await store.persistedSnapshot()
    XCTAssertEqual(failedDurable.activeSleepTimer?.phase, .fading)
    XCTAssertTrue(failedDurable.sleepTimerHistory.isEmpty)

    await model.evaluateSleepTimer()
    XCTAssertNil(model.activeSleepTimer)
    XCTAssertEqual(model.library.positionJournal.filter { $0.reason == .sleepTimer }.count, 1)
    XCTAssertEqual(model.library.sleepTimerHistory.count, 1)
    XCTAssertEqual(model.library.sleepTimerHistory[0].actualStopPositionMilliseconds, 90_000)
  }

  func testExplicitSleepContextRewindsOnceWhileOrdinaryResumeDoesNotUseIt() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let book = makeBook()
    let seed = completedSleepSnapshot(book: book, at: now)

    let ordinaryStore = InMemoryLibraryStore(snapshot: seed)
    let ordinary = makeModel(
      store: ordinaryStore,
      playback: SleepTimerPlaybackController(),
      clock: MutableSleepTimerClock(now.addingTimeInterval(10))
    )
    await ordinary.restore()
    XCTAssertNil(ordinary.smartRewindPlan(for: book.id))
    await ordinary.play(bookID: book.id)
    XCTAssertEqual(ordinary.playbackState.elapsedSeconds, 90, accuracy: 0.001)
    XCTAssertEqual(ordinary.library.positionJournal.map(\.reason), [.sleepTimer, .play])
    XCTAssertNotNil(ordinary.sleepResumeContext)

    let contextualStore = InMemoryLibraryStore(snapshot: seed)
    let contextual = makeModel(
      store: contextualStore,
      playback: SleepTimerPlaybackController(),
      clock: MutableSleepTimerClock(now.addingTimeInterval(10))
    )
    await contextual.restore()
    let resumed = await contextual.resumeFromSleepWithContext()
    XCTAssertTrue(resumed)
    XCTAssertEqual(contextual.playbackState.elapsedSeconds, 85, accuracy: 0.001)
    XCTAssertEqual(
      contextual.library.positionJournal.map(\.reason),
      [.sleepTimer, .preResumeRewind, .resumeRewind, .play]
    )
    XCTAssertNil(contextual.sleepResumeContext)
    let repeated = await contextual.resumeFromSleepWithContext()
    XCTAssertFalse(repeated)
    XCTAssertNotNil(contextual.library.sleepTimerHistory[0].resumeContextUsedAt)
  }

  func testResumeContextExpiresAfterTenMinutes() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let book = makeBook()
    let model = makeModel(
      store: InMemoryLibraryStore(snapshot: completedSleepSnapshot(book: book, at: now)),
      playback: SleepTimerPlaybackController(),
      clock: MutableSleepTimerClock(now.addingTimeInterval(600.001))
    )
    await model.restore()
    XCTAssertNil(model.sleepResumeContext)
    let resumed = await model.resumeFromSleepWithContext()
    XCTAssertFalse(resumed)
  }

  func testSchemaElevenMigratesSleepDefaultsAndWritesCurrentSchema() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "SleepTimerMigration-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appending(path: "Library.json")
    let store = CodableLibraryStore(fileURL: fileURL)
    try await store.save(LibrarySnapshot(
      books: [makeBook()],
      importJobs: [],
      currentBookID: nil
    ))
    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    envelope["schemaVersion"] = 11
    var library = try XCTUnwrap(envelope["library"] as? [String: Any])
    library.removeValue(forKey: "activeSleepTimer")
    library.removeValue(forKey: "sleepTimerHistory")
    envelope["library"] = library
    try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL, options: .atomic)

    let migrated = try await store.load()
    XCTAssertNil(migrated.activeSleepTimer)
    XCTAssertTrue(migrated.sleepTimerHistory.isEmpty)
    try await store.save(migrated)
    let current = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    XCTAssertEqual(current["schemaVersion"] as? Int, 13)
  }

  private func makeBook() -> Book {
    let bookID = uuid(100)
    let firstAssetID = uuid(101)
    let secondAssetID = uuid(102)
    return Book(
      id: bookID,
      title: "Sleep Boundaries",
      authors: ["Mara Vale"],
      durationSeconds: 120,
      artworkData: nil,
      assets: [
        AudioAsset(
          id: firstAssetID,
          originalFilename: "track-1.m4b",
          managedRelativePath: "Media/track-1.m4b",
          checksumSHA256: "one",
          byteCount: 1,
          durationSeconds: 90,
          container: "M4B",
          timelineStartSeconds: 0,
          importOrder: 0
        ),
        AudioAsset(
          id: secondAssetID,
          originalFilename: "track-2.m4b",
          managedRelativePath: "Media/track-2.m4b",
          checksumSHA256: "two",
          byteCount: 1,
          durationSeconds: 30,
          container: "M4B",
          timelineStartSeconds: 90,
          importOrder: 1
        ),
      ],
      dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
      chapters: [
        Chapter(
          id: "chapter-1",
          title: "First",
          startSeconds: 0,
          durationSeconds: 45,
          source: .embedded,
          assetID: firstAssetID
        ),
        Chapter(
          id: "chapter-2",
          title: "Second",
          startSeconds: 45,
          durationSeconds: 55,
          source: .embedded,
          assetID: firstAssetID
        ),
        Chapter(
          id: "chapter-3",
          title: "Third",
          startSeconds: 100,
          durationSeconds: 20,
          source: .embedded,
          assetID: secondAssetID
        ),
      ]
    )
  }

  private func snapshot(
    book: Book,
    positionMilliseconds: Int64,
    at date: Date,
    reason: PositionEventReason = .pause
  ) -> LibrarySnapshot {
    let event = PositionEvent.acknowledged(
      id: uuid(800),
      bookID: book.id,
      positionMilliseconds: positionMilliseconds,
      sequence: 1,
      reason: reason,
      acknowledgedAt: date,
      previousEventID: nil
    )
    return LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: book.id,
      playbackPosition: PlaybackPosition(
        bookID: book.id,
        positionMilliseconds: positionMilliseconds,
        sequence: 1,
        sourceEventID: event.id,
        updatedAt: date
      ),
      positionJournal: [event]
    )
  }

  private func completedSleepSnapshot(book: Book, at date: Date) -> LibrarySnapshot {
    var result = snapshot(
      book: book,
      positionMilliseconds: 90_000,
      at: date,
      reason: .sleepTimer
    )
    result.sleepTimerHistory = [SleepTimerHistoryEntry(
      id: uuid(802),
      timerID: uuid(801),
      bookID: book.id,
      selection: .endOfTrack,
      fadeEnabled: true,
      startedAt: date.addingTimeInterval(-20),
      expectedDeadline: nil,
      expectedBoundaryPositionMilliseconds: 90_000,
      actualStopPositionMilliseconds: 90_000,
      completedAt: date,
      status: .completed,
      positionEventID: result.positionJournal[0].id,
      resumeContextUsedAt: nil
    )]
    return result
  }

  private func makeModel(
    store: any LibraryPersisting,
    playback: SleepTimerPlaybackController,
    clock: MutableSleepTimerClock,
    ids: [UUID]? = nil
  ) -> PlayerModel {
    PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: SleepTimerMediaManager(),
      inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
      playback: playback,
      clock: clock,
      ids: DeterministicPlayerIDGenerator(values: ids ?? (1...40).map(uuid))
    ))
  }

  private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "d0000000-0000-0000-0000-%012d", suffix))!
  }
}

private final class MutableSleepTimerClock: PlayerClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) { self.value = value }
  func now() -> Date { lock.withLock { value } }
  func advance(by seconds: TimeInterval) {
    lock.withLock { value = value.addingTimeInterval(seconds) }
  }
}

@MainActor
private final class SleepTimerPlaybackController: AudioPlaybackControlling {
  private(set) var state: PlaybackState = .unloaded
  private(set) var playbackRate = 1.0
  private(set) var fadeDurations: [TimeInterval] = []
  private(set) var completeFadeCount = 0
  private(set) var cancelFadeCount = 0

  var currentPositionSeconds: Double { state.elapsedSeconds }

  func load(url: URL, bookID: UUID, at seconds: Double) async throws {
    state = PlaybackState(status: .paused, loadedBookID: bookID, elapsedSeconds: seconds)
  }

  func seek(to seconds: Double) async { state.elapsedSeconds = max(0, seconds) }
  func setPlaybackRate(_ rate: Double) { playbackRate = rate }
  func play() { state.status = .playing }
  func pause() { state.status = .paused }
  func beginSleepFade(durationSeconds: TimeInterval) { fadeDurations.append(durationSeconds) }
  func completeSleepFadeAndPause() {
    completeFadeCount += 1
    pause()
  }
  func cancelSleepFade() { cancelFadeCount += 1 }
  func setPosition(seconds: Double) { state.elapsedSeconds = seconds }
}

private actor SleepTimerMediaManager: MediaManaging {
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

private actor FailingSleepTimerStore: LibraryPersisting {
  private var snapshot: LibrarySnapshot
  private let failingSaveNumber: Int
  private var saveCount = 0

  init(snapshot: LibrarySnapshot, failingSaveNumber: Int) {
    self.snapshot = snapshot
    self.failingSaveNumber = failingSaveNumber
  }

  func load() -> LibrarySnapshot { snapshot }
  func save(_ snapshot: LibrarySnapshot) throws {
    saveCount += 1
    if saveCount == failingSaveNumber {
      throw PlayerCoreError.fileOperation("Injected atomic sleep timer save failure.")
    }
    self.snapshot = snapshot
  }
  func persistedSnapshot() -> LibrarySnapshot { snapshot }
}
