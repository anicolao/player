import AVFAudio
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

  func testExternalTrackButtonsUseConfiguredSkipIntervals() {
    let preferences = TransportPreferences(
      playbackRate: 1.25,
      backwardSkipSeconds: 10,
      forwardSkipSeconds: 25,
      seekContext: .wholeBook
    )

    XCTAssertEqual(
      RemoteTrackButton.previous.playbackCommand(using: preferences),
      .skipBackward(seconds: 10)
    )
    XCTAssertEqual(
      RemoteTrackButton.next.playbackCommand(using: preferences),
      .skipForward(seconds: 25)
    )
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

  func testClearingOverrideAtomicallyAppliesCurrentLibraryDefaultsToEveryTransportSurface()
    async throws
  {
    let harness = makeHarness()
    await harness.model.restore()
    harness.model.configurePlaybackIntegrations()
    let originalGlobal = TransportPreferences(
      playbackRate: 1.1,
      backwardSkipSeconds: 20,
      forwardSkipSeconds: 45,
      seekContext: .wholeBook
    )
    let override = TransportPreferenceOverride(
      playbackRate: 1.25,
      backwardSkipSeconds: 10,
      forwardSkipSeconds: 30,
      seekContext: .chapter
    )
    let savedOriginalGlobal = await harness.model.setGlobalTransportPreferences(originalGlobal)
    let savedOverride = await harness.model.setTransportPreferenceOverride(
      override,
      for: harness.book.id
    )
    XCTAssertTrue(savedOriginalGlobal)
    XCTAssertTrue(savedOverride)
    await harness.model.play(bookID: harness.book.id, at: 45)
    XCTAssertEqual(harness.playback.playbackRate, 1.25)
    XCTAssertEqual(harness.remote.transportPreferences, override.resolved(over: originalGlobal))

    let currentGlobal = TransportPreferences(
      playbackRate: 1.5,
      backwardSkipSeconds: 15,
      forwardSkipSeconds: 45,
      seekContext: .wholeBook
    )
    let savedCurrentGlobal = await harness.model.setGlobalTransportPreferences(currentGlobal)
    XCTAssertTrue(savedCurrentGlobal)
    XCTAssertEqual(
      harness.model.transportPreferences(for: harness.book.id),
      override.resolved(over: currentGlobal),
      "Changing library defaults must not alter a durable per-book override"
    )

    let clearedOverride = await harness.model.clearTransportPreferenceOverride(for: harness.book.id)
    XCTAssertTrue(clearedOverride)
    XCTAssertNil(harness.model.library.books.first?.transportPreferenceOverride)
    XCTAssertEqual(harness.model.currentTransportPreferences, currentGlobal)
    XCTAssertEqual(harness.playback.playbackRate, currentGlobal.playbackRate)
    XCTAssertEqual(harness.remote.transportPreferences, currentGlobal)

    await harness.model.skipForward()
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 90, accuracy: 0.001)
    await harness.remote.send(.skipBackward(seconds: currentGlobal.backwardSkipSeconds))
    XCTAssertEqual(harness.model.playbackState.elapsedSeconds, 75, accuracy: 0.001)
    await harness.model.seek(to: 10, context: harness.model.currentTransportPreferences.seekContext)
    XCTAssertEqual(
      harness.model.playbackState.elapsedSeconds,
      10,
      accuracy: 0.001,
      "The active scrubber must switch from chapter-relative to whole-book seeking"
    )

    let durable = await harness.store.load()
    XCTAssertNil(durable.books.first?.transportPreferenceOverride)
    XCTAssertEqual(durable.globalTransportPreferences, currentGlobal)

    let restoredPlayback = DeterministicPlaybackController()
    let restoredRemote = DeterministicRemoteCommandController()
    let restoredModel = PlayerModel(environment: PlayerEnvironment(
      persistence: harness.store,
      media: TransportMediaManager(),
      inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
      playback: restoredPlayback,
      remoteCommands: restoredRemote,
      ids: DeterministicPlayerIDGenerator(values: [])
    ))
    await restoredModel.restore()
    restoredModel.configurePlaybackIntegrations()
    XCTAssertNil(restoredModel.library.books.first?.transportPreferenceOverride)
    XCTAssertEqual(restoredModel.currentTransportPreferences, currentGlobal)
    XCTAssertEqual(restoredPlayback.playbackRate, currentGlobal.playbackRate)
    XCTAssertEqual(restoredRemote.transportPreferences, currentGlobal)
  }

  func testFailedOverrideClearKeepsPublishedDurableAndExternalConfigurationCoherent()
    async throws
  {
    var book = makeBook()
    let global = TransportPreferences(
      playbackRate: 1.5,
      backwardSkipSeconds: 15,
      forwardSkipSeconds: 45,
      seekContext: .wholeBook
    )
    let override = TransportPreferenceOverride(
      playbackRate: 1.25,
      backwardSkipSeconds: 10,
      forwardSkipSeconds: 30,
      seekContext: .chapter
    )
    book.transportPreferenceOverride = override
    let seed = LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: book.id,
      globalTransportPreferences: global
    )
    let store = FailingTransportPreferenceStore(snapshot: seed)
    let playback = DeterministicPlaybackController()
    let remote = DeterministicRemoteCommandController()
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: TransportMediaManager(),
      inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
      playback: playback,
      remoteCommands: remote,
      ids: DeterministicPlayerIDGenerator(values: [])
    ))
    await model.restore()
    model.configurePlaybackIntegrations()
    XCTAssertEqual(playback.playbackRate, 1.25)
    XCTAssertEqual(remote.transportPreferences, override.resolved(over: global))

    let clearedOverride = await model.clearTransportPreferenceOverride(for: book.id)
    let durable = await store.load()
    XCTAssertFalse(clearedOverride)
    XCTAssertEqual(model.library, seed)
    XCTAssertEqual(durable, seed)
    XCTAssertEqual(model.currentTransportPreferences, override.resolved(over: global))
    XCTAssertEqual(playback.playbackRate, 1.25)
    XCTAssertEqual(remote.transportPreferences, override.resolved(over: global))
    let error = model.presentationError(in: .transportPreferences)
    XCTAssertEqual(error?.title, "Couldn’t Save Playback Settings")
    XCTAssertTrue(error?.message.contains("Your current settings are unchanged") == true)
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

  func testProductionRemoteAdapterRegistersAndDispatchesEverySystemCommand() async {
    let source = RecordingRemoteCommandCenterSource()
    let controller = MPRemoteCommandController(source: source)
    let preferences = TransportPreferences(
      playbackRate: 1.25,
      backwardSkipSeconds: 12,
      forwardSkipSeconds: 24,
      seekContext: .chapter
    )
    controller.updateTransportConfiguration(preferences)

    let dispatched = expectation(description: "All registered remote commands dispatch")
    dispatched.expectedFulfillmentCount = RemoteCommandRegistration.allCases.count
    var received: [RemotePlaybackCommand] = []
    controller.installCommandHandler { command in
      received.append(command)
      dispatched.fulfill()
    }

    XCTAssertTrue(source.beganReceivingRemoteControlEvents)
    XCTAssertEqual(source.registrations, Set(RemoteCommandRegistration.allCases))
    XCTAssertEqual(source.preferredIntervals[.skipBackward], [12])
    XCTAssertEqual(source.preferredIntervals[.skipForward], [24])
    XCTAssertEqual(source.supportedPlaybackRates.first, 0.5)
    XCTAssertEqual(source.supportedPlaybackRates.last, 3)

    let invocations: [(RemoteCommandRegistration, RemoteCommandInvocation)] = [
      (.play, .init()),
      (.pause, .init()),
      (.toggle, .init()),
      (.previousTrack, .init()),
      (.nextTrack, .init()),
      (.skipForward, .init(interval: 33)),
      (.skipBackward, .init()),
      (.changePosition, .init(positionTime: 44)),
      (.changeRate, .init(playbackRate: 1.5)),
    ]
    for (registration, invocation) in invocations {
      assertDispatchSucceeded(source.send(registration, invocation: invocation))
    }

    await fulfillment(of: [dispatched], timeout: 2)
    XCTAssertEqual(
      received,
      [
        .play,
        .pause,
        .togglePlayPause,
        .skipBackward(seconds: 12),
        .skipForward(seconds: 24),
        .skipForward(seconds: 33),
        .skipBackward(seconds: 12),
        .changePosition(seconds: 44),
        .changePlaybackRate(1.5),
      ]
    )
  }

  func testProductionAudioAdapterConfiguresAndTranslatesInjectedNotifications() async throws {
    let platform = RecordingAudioSessionPlatform()
    let notifications = RecordingAudioSessionNotificationSource()
    let controller = AVAudioSessionController(
      platform: platform,
      notificationSource: notifications
    )

    try controller.configure()
    try controller.activate()
    let dispatched = expectation(description: "All audio-session notifications dispatch")
    dispatched.expectedFulfillmentCount = 3
    var received: [AudioSessionEvent] = []
    controller.installEventHandler { event in
      received.append(event)
      dispatched.fulfill()
    }

    XCTAssertEqual(platform.configuredOptions, [AVAudioSessionController.playbackCategoryOptions])
    XCTAssertEqual(platform.activationCount, 1)
    XCTAssertEqual(notifications.registrations, Set(AudioSessionNotificationKind.allCases))

    notifications.send(
      .interruption,
      payload: AudioSessionNotificationPayload(
        interruptionType: AVAudioSession.InterruptionType.began.rawValue
      )
    )
    notifications.send(
      .interruption,
      payload: AudioSessionNotificationPayload(
        interruptionType: AVAudioSession.InterruptionType.ended.rawValue,
        interruptionOptions: AVAudioSession.InterruptionOptions.shouldResume.rawValue
      )
    )
    notifications.send(
      .routeChange,
      payload: AudioSessionNotificationPayload(
        routeChangeReason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
      )
    )

    await fulfillment(of: [dispatched], timeout: 2)
    XCTAssertEqual(
      received,
      [
        .interruptionBegan,
        .interruptionEnded(shouldResume: true),
        .oldDeviceUnavailable,
      ]
    )
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

  private func assertDispatchSucceeded(
    _ result: RemoteCommandDispatchResult,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .success = result else {
      XCTFail("Expected the registered production command to dispatch", file: file, line: line)
      return
    }
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
private final class RecordingRemoteCommandCenterSource: RemoteCommandCenterSource {
  private final class Target {}

  private var targets: [
    RemoteCommandRegistration: (
      target: Target,
      handler: (RemoteCommandInvocation) -> RemoteCommandDispatchResult
    )
  ] = [:]
  private(set) var beganReceivingRemoteControlEvents = false
  private(set) var registrations: Set<RemoteCommandRegistration> = []
  private(set) var preferredIntervals: [RemoteCommandRegistration: [Double]] = [:]
  private(set) var supportedPlaybackRates: [Double] = []

  func beginReceivingRemoteControlEvents() {
    beganReceivingRemoteControlEvents = true
  }

  func setEnabled(_ enabled: Bool, for command: RemoteCommandRegistration) {
    if !enabled { registrations.remove(command) }
  }

  func addTarget(
    for command: RemoteCommandRegistration,
    handler: @escaping (RemoteCommandInvocation) -> RemoteCommandDispatchResult
  ) -> Any {
    let target = Target()
    targets[command] = (target, handler)
    registrations.insert(command)
    return target
  }

  func removeTarget(_ target: Any, for command: RemoteCommandRegistration) {
    guard
      let target = target as? Target,
      targets[command]?.target === target
    else { return }
    targets.removeValue(forKey: command)
    registrations.remove(command)
  }

  func setPreferredIntervals(_ intervals: [Double], for command: RemoteCommandRegistration) {
    preferredIntervals[command] = intervals
  }

  func setSupportedPlaybackRates(_ rates: [Double]) {
    supportedPlaybackRates = rates
  }

  func send(
    _ command: RemoteCommandRegistration,
    invocation: RemoteCommandInvocation
  ) -> RemoteCommandDispatchResult {
    targets[command]?.handler(invocation) ?? .commandFailed
  }
}

@MainActor
private final class RecordingAudioSessionPlatform: AudioSessionPlatform {
  private(set) var configuredOptions: [AVAudioSession.CategoryOptions] = []
  private(set) var activationCount = 0

  var notificationObject: AnyObject { self }

  func configureForSpokenAudio(options: AVAudioSession.CategoryOptions) throws {
    configuredOptions.append(options)
  }

  func activate() throws {
    activationCount += 1
  }
}

private final class RecordingAudioSessionObservation: AudioSessionNotificationObservation {}

@MainActor
private final class RecordingAudioSessionNotificationSource: AudioSessionNotificationSource {
  private var handlers: [
    AudioSessionNotificationKind: @Sendable (AudioSessionNotificationPayload) -> Void
  ] = [:]
  private(set) var registrations: Set<AudioSessionNotificationKind> = []

  func observe(
    _ kind: AudioSessionNotificationKind,
    object: AnyObject,
    using handler: @escaping @Sendable (AudioSessionNotificationPayload) -> Void
  ) -> any AudioSessionNotificationObservation {
    handlers[kind] = handler
    registrations.insert(kind)
    return RecordingAudioSessionObservation()
  }

  func send(_ kind: AudioSessionNotificationKind, payload: AudioSessionNotificationPayload) {
    handlers[kind]?(payload)
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

private actor FailingTransportPreferenceStore: LibraryPersisting {
  private var snapshot: LibrarySnapshot

  init(snapshot: LibrarySnapshot) {
    self.snapshot = snapshot
  }

  func load() -> LibrarySnapshot {
    snapshot
  }

  func save(_ candidate: LibrarySnapshot) throws {
    let hadOverride = snapshot.books.first?.transportPreferenceOverride != nil
    let clearsOverride = candidate.books.first?.transportPreferenceOverride == nil
    if hadOverride && clearsOverride {
      throw CocoaError(.fileWriteUnknown)
    }
    snapshot = candidate
  }
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
