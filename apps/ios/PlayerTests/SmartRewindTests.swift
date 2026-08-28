import Foundation
import XCTest
@testable import Player

@MainActor
final class SmartRewindTests: XCTestCase {
  func testE2ESmartRewindScenarioAcceptsEveryCanonicalValue() throws {
    for scenario in E2ESmartRewindScenario.allCases {
      let parsed = try E2ESmartRewindScenario.parseRequired(arguments: [
        "Player",
        "-e2e",
        "-e2e-smart-rewind-scenario", scenario.rawValue,
        "-AppleLanguages", "(en)",
      ])
      XCTAssertEqual(parsed, scenario)
    }
  }

  func testE2ESmartRewindScenarioRequiresExactlyOneValue() {
    let invalidArguments = [
      ["Player", "-e2e"],
      ["Player", "-e2e-smart-rewind-scenario"],
      ["Player", "-e2e-smart-rewind-scenario", "-e2e-reset"],
      [
        "Player",
        "-e2e-smart-rewind-scenario", "chapter-clamp",
        "-e2e-smart-rewind-scenario", "medium",
      ],
    ]

    for arguments in invalidArguments {
      XCTAssertThrowsError(
        try E2ESmartRewindScenario.parseRequired(arguments: arguments),
        "Expected strict scenario parsing to reject \(arguments)"
      )
    }
  }

  func testE2ESmartRewindScenarioRejectsUnknownAndMalformedValues() {
    let invalidValues = [
      "medium-ish",
      "Chapter-Clamp",
      "../chapter-clamp",
      "chapter-clamp/other",
      "",
      String(repeating: "a", count: 65),
    ]

    for value in invalidValues {
      XCTAssertThrowsError(
        try E2ESmartRewindScenario.parseRequired(arguments: [
          "Player", "-e2e-smart-rewind-scenario", value,
        ]),
        "Expected strict scenario parsing to reject \(value.debugDescription)"
      )
    }
  }

  func testPlannerUsesEveryDocumentedThresholdBoundaryAndMaximum() throws {
    let book = makeBook(chapters: [])
    let pausedAt = Date(timeIntervalSince1970: 1_800_000_000)

    XCTAssertNil(plan(book: book, pausedAt: pausedAt, away: 29.999))
    XCTAssertEqual(
      try XCTUnwrap(plan(book: book, pausedAt: pausedAt, away: 30)).rewindSeconds,
      5
    )
    XCTAssertEqual(
      try XCTUnwrap(plan(book: book, pausedAt: pausedAt, away: 599.999)).rewindSeconds,
      5
    )
    XCTAssertEqual(
      try XCTUnwrap(plan(book: book, pausedAt: pausedAt, away: 600)).rewindSeconds,
      15
    )
    XCTAssertEqual(
      try XCTUnwrap(plan(book: book, pausedAt: pausedAt, away: 3_600)).rewindSeconds,
      15
    )
    XCTAssertEqual(
      try XCTUnwrap(plan(book: book, pausedAt: pausedAt, away: 3_600.001)).rewindSeconds,
      30
    )

    var bounded = SmartRewindPreferences.default
    bounded.maximumRewindSeconds = 20
    bounded.longRewindSeconds = 45
    XCTAssertEqual(
      try XCTUnwrap(plan(
        book: book,
        pausedAt: pausedAt,
        away: 7_200,
        preferences: bounded
      )).rewindSeconds,
      20
    )
    bounded.isEnabled = false
    XCTAssertNil(plan(
      book: book,
      pausedAt: pausedAt,
      away: 7_200,
      preferences: bounded
    ))
  }

  func testPlannerClampsAtLogicalChapterStart() throws {
    let book = makeBook()
    let pausedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let result = try XCTUnwrap(SmartRewindPlanner.plan(
      for: book,
      positionMilliseconds: 110_000,
      pausedAt: pausedAt,
      resumedAt: pausedAt.addingTimeInterval(600),
      preferences: .default
    ))

    XCTAssertEqual(result.originalPositionMilliseconds, 110_000)
    XCTAssertEqual(result.targetPositionMilliseconds, 100_000)
    XCTAssertEqual(result.rewindMilliseconds, 10_000)
    XCTAssertEqual(result.chapterStartMilliseconds, 100_000)
    XCTAssertTrue(result.wasClampedToChapterStart)
    XCTAssertFalse(result.crossedRecentChapterStart)
  }

  func testImplicitResumeJournalsPreRewindAndSupportsDurableExactUndo() async throws {
    let clock = MutableSmartRewindClock(Date(timeIntervalSince1970: 1_800_000_000))
    let book = makeBook()
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: nil
    ))
    let playback = DeterministicPlaybackController()
    let model = makeModel(store: store, playback: playback, clock: clock)
    await model.restore()

    await model.play(bookID: book.id, at: 110)
    await model.pause()
    clock.advance(by: 600)
    let preview = try XCTUnwrap(model.smartRewindPlan(for: book.id))
    XCTAssertEqual(preview.targetPositionMilliseconds, 100_000)
    XCTAssertTrue(preview.wasClampedToChapterStart)

    await model.play(bookID: book.id)

    XCTAssertEqual(model.playbackState.status, .playing)
    XCTAssertEqual(model.playbackState.elapsedSeconds, 100, accuracy: 0.001)
    let applied = try XCTUnwrap(model.pendingResumeRewind)
    XCTAssertEqual(applied.plan.originalPositionMilliseconds, 110_000)
    XCTAssertEqual(applied.plan.targetPositionMilliseconds, 100_000)
    XCTAssertEqual(applied.status, .applied)
    XCTAssertEqual(
      model.library.positionJournal.map(\.reason),
      [.play, .pause, .preResumeRewind, .resumeRewind, .play]
    )
    XCTAssertEqual(
      applied.preRewindEventID,
      model.library.positionJournal[2].id
    )
    XCTAssertEqual(
      applied.rewindEventID,
      model.library.positionJournal[3].id
    )

    let undone = await model.undoResumeRewind()
    XCTAssertTrue(undone)
    XCTAssertEqual(model.playbackState.elapsedSeconds, 110, accuracy: 0.001)
    XCTAssertNil(model.pendingResumeRewind)
    let durable = await store.load()
    XCTAssertEqual(durable.playbackPosition?.positionMilliseconds, 110_000)
    XCTAssertEqual(durable.positionJournal.last?.reason, .undoResumeRewind)
    XCTAssertEqual(durable.resumeRewindTransactions.last?.status, .undone)
    XCTAssertEqual(
      durable.resumeRewindTransactions.last?.undoEventID,
      durable.positionJournal.last?.id
    )

    let restoredPlayback = DeterministicPlaybackController()
    let restored = makeModel(
      store: store,
      playback: restoredPlayback,
      clock: clock,
      ids: []
    )
    await restored.restore()
    XCTAssertEqual(restored.playbackState.elapsedSeconds, 110, accuracy: 0.001)
    XCTAssertEqual(restoredPlayback.currentPositionSeconds, 110, accuracy: 0.001)
    XCTAssertNil(restored.pendingResumeRewind)
  }

  func testDisabledAndMaximumPreferencesPersistAndControlPreview() async throws {
    let clock = MutableSmartRewindClock(Date(timeIntervalSince1970: 1_800_000_000))
    let book = makeBook(chapters: [])
    let pauseEvent = PositionEvent.acknowledged(
      id: uuid(80),
      bookID: book.id,
      positionMilliseconds: 200_000,
      sequence: 1,
      reason: .pause,
      acknowledgedAt: clock.now(),
      previousEventID: nil
    )
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: book.id,
      playbackPosition: PlaybackPosition(
        bookID: book.id,
        positionMilliseconds: 200_000,
        sequence: 1,
        sourceEventID: pauseEvent.id,
        updatedAt: pauseEvent.acknowledgedAt
      ),
      positionJournal: [pauseEvent]
    ))
    let model = makeModel(
      store: store,
      playback: DeterministicPlaybackController(),
      clock: clock
    )
    await model.restore()
    clock.advance(by: 7_200)

    let changedMaximum = await model.setSmartRewindMaximum(12)
    XCTAssertTrue(changedMaximum)
    XCTAssertEqual(try XCTUnwrap(model.smartRewindPlan(for: book.id)).rewindSeconds, 12)
    let disabled = await model.setSmartRewindEnabled(false)
    XCTAssertTrue(disabled)
    XCTAssertNil(model.smartRewindPlan(for: book.id))
    let durable = await store.load()
    XCTAssertFalse(durable.smartRewindPreferences.isEnabled)
    XCTAssertEqual(durable.smartRewindPreferences.maximumRewindSeconds, 12)
  }

  func testRewindUndoNoticeDismissesDurablyAfterFiveSecondsOfListening() async throws {
    let clock = MutableSmartRewindClock(Date(timeIntervalSince1970: 1_800_000_000))
    let book = makeBook()
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: nil
    ))
    let playback = DeterministicPlaybackController()
    let model = makeModel(store: store, playback: playback, clock: clock)
    await model.restore()
    await model.play(bookID: book.id, at: 110)
    await model.pause()
    clock.advance(by: 600)
    await model.play(bookID: book.id)
    XCTAssertNotNil(model.pendingResumeRewind)

    await playback.seek(to: 104.9)
    await model.synchronizePlaybackProgress()
    XCTAssertNotNil(model.pendingResumeRewind)

    clock.advance(by: 5)
    await playback.seek(to: 105)
    await model.synchronizePlaybackProgress()

    XCTAssertNil(model.pendingResumeRewind)
    let durable = await store.load()
    XCTAssertEqual(durable.resumeRewindTransactions.last?.status, .dismissed)
    XCTAssertEqual(durable.resumeRewindTransactions.last?.dismissedAt, clock.now())
  }

  func testFailedAtomicRewindSaveRollsEngineBackWithoutOrphanTransaction() async throws {
    let pauseDate = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = MutableSmartRewindClock(pauseDate.addingTimeInterval(600))
    let book = makeBook()
    let pauseEvent = PositionEvent.acknowledged(
      id: uuid(80),
      bookID: book.id,
      positionMilliseconds: 110_000,
      sequence: 1,
      reason: .pause,
      acknowledgedAt: pauseDate,
      previousEventID: nil
    )
    let seed = LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: book.id,
      playbackPosition: PlaybackPosition(
        bookID: book.id,
        positionMilliseconds: 110_000,
        sequence: 1,
        sourceEventID: pauseEvent.id,
        updatedAt: pauseDate
      ),
      positionJournal: [pauseEvent]
    )
    // Save one is the separately durable pre-rewind checkpoint. Save two is
    // the intentionally failed atomic rewind-event + Undo transaction write.
    let store = FailingSmartRewindStore(snapshot: seed, failingSaveNumber: 2)
    let playback = DeterministicPlaybackController()
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: SmartRewindMediaManager(),
      inspector: DeterministicAudioInspector(
        result: .failure(.unreadableAudio("unused"))
      ),
      playback: playback,
      clock: clock,
      ids: DeterministicPlayerIDGenerator(values: (1...10).map { uuid($0) })
    ))
    await model.restore()

    await model.play(bookID: book.id)

    XCTAssertEqual(model.playbackState.status, .playing)
    XCTAssertEqual(model.playbackState.elapsedSeconds, 110, accuracy: 0.001)
    XCTAssertEqual(playback.currentPositionSeconds, 110, accuracy: 0.001)
    XCTAssertNil(model.pendingResumeRewind)
    let durable = await store.persistedSnapshot()
    XCTAssertEqual(durable.playbackPosition?.positionMilliseconds, 110_000)
    XCTAssertEqual(
      durable.positionJournal.map(\.reason),
      [.pause, .preResumeRewind, .play]
    )
    XCTAssertFalse(durable.positionJournal.contains(where: { $0.reason == .resumeRewind }))
    XCTAssertTrue(durable.resumeRewindTransactions.isEmpty)
  }

  func testSchemaTenMigratesSmartRewindDefaultsAndWritesCurrentSchema() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "SmartRewindMigration-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appending(path: "Library.json")
    let store = CodableLibraryStore(fileURL: fileURL)
    var preferences = SmartRewindPreferences.default
    preferences.isEnabled = false
    try await store.save(LibrarySnapshot(
      books: [makeBook()],
      importJobs: [],
      currentBookID: nil,
      smartRewindPreferences: preferences
    ))

    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    envelope["schemaVersion"] = 10
    var library = try XCTUnwrap(envelope["library"] as? [String: Any])
    library.removeValue(forKey: "smartRewindPreferences")
    library.removeValue(forKey: "resumeRewindTransactions")
    envelope["library"] = library
    try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL, options: .atomic)

    let migrated = try await store.load()
    XCTAssertEqual(migrated.smartRewindPreferences, .default)
    XCTAssertTrue(migrated.resumeRewindTransactions.isEmpty)
    try await store.save(migrated)
    let current = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    XCTAssertEqual(current["schemaVersion"] as? Int, 15)
  }

  private func plan(
    book: Book,
    pausedAt: Date,
    away: TimeInterval,
    preferences: SmartRewindPreferences = .default
  ) -> SmartRewindPlan? {
    SmartRewindPlanner.plan(
      for: book,
      positionMilliseconds: 200_000,
      pausedAt: pausedAt,
      resumedAt: pausedAt.addingTimeInterval(away),
      preferences: preferences
    )
  }

  private func makeModel(
    store: InMemoryLibraryStore,
    playback: DeterministicPlaybackController,
    clock: MutableSmartRewindClock,
    ids: [UUID]? = nil
  ) -> PlayerModel {
    PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: SmartRewindMediaManager(),
      inspector: DeterministicAudioInspector(
        result: .failure(.unreadableAudio("unused"))
      ),
      playback: playback,
      clock: clock,
      ids: DeterministicPlayerIDGenerator(values: ids ?? (1...30).map { uuid($0) })
    ))
  }

  private func makeBook(chapters: [Chapter]? = nil) -> Book {
    let bookID = uuid(100)
    let assetID = uuid(101)
    return Book(
      id: bookID,
      title: "A Context to Return To",
      authors: ["Mara Vale"],
      durationSeconds: 300,
      artworkData: nil,
      assets: [AudioAsset(
        id: assetID,
        originalFilename: "context.m4b",
        managedRelativePath: "Media/context.m4b",
        checksumSHA256: "fixture",
        byteCount: 1,
        durationSeconds: 300,
        container: "M4B"
      )],
      dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
      chapters: chapters ?? [
        Chapter(
          id: "first",
          title: "First",
          startSeconds: 0,
          durationSeconds: 100,
          source: .embedded,
          assetID: assetID
        ),
        Chapter(
          id: "second",
          title: "Second",
          startSeconds: 100,
          durationSeconds: 100,
          source: .embedded,
          assetID: assetID
        ),
        Chapter(
          id: "third",
          title: "Third",
          startSeconds: 200,
          durationSeconds: 100,
          source: .embedded,
          assetID: assetID
        ),
      ]
    )
  }

  private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "c0000000-0000-0000-0000-%012d", suffix))!
  }

}

private final class MutableSmartRewindClock: PlayerClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date {
    lock.withLock { value }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock { value = value.addingTimeInterval(interval) }
  }
}

private actor SmartRewindMediaManager: MediaManaging {
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

private actor FailingSmartRewindStore: LibraryPersisting {
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
      throw PlayerCoreError.fileOperation("Injected atomic Smart Rewind save failure.")
    }
    self.snapshot = snapshot
  }

  func persistedSnapshot() -> LibrarySnapshot { snapshot }
}
