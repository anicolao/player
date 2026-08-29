import XCTest

@MainActor
final class RemoteInterruptionUITests: XCTestCase {
  private let fixtureBookID = "20000000-0000-0000-0000-000000000001"
  private let registeredCommands: Set<String> = [
    "change-position", "change-rate", "next-track-skip-forward", "pause", "play",
    "previous-track-skip-backward", "skip-backward", "skip-forward", "toggle",
  ]
  private let registeredAudioNotifications: Set<String> = ["interruption", "route-change"]

  func testRemoteInterruptionAndBackgroundEventsJournalAcknowledgedPositions() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = makeApplication(reset: true)
    app.launch()
    let probe = app.otherElements["e2e-playback-probe"]
    XCTAssertTrue(probe.waitForExistence(timeout: 2))

    let initial = try requireProbe(
      probe,
      status: "paused",
      positionMilliseconds: 12_000,
      sequence: 1,
      reason: "pause"
    )
    assertIdentityAndPersistence(initial, expectedPositionMilliseconds: 12_000)
    XCTAssertEqual(initial.registeredCommands, registeredCommands)
    assertProductionAdapterEvidence(initial, postedAudioEvent: "none")

    app.buttons["e2e-remote-play"].tap()
    let remotelyPlaying = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 12_000,
      sequence: 2,
      reason: "play"
    )
    assertIdentityAndPersistence(remotelyPlaying, expectedPositionMilliseconds: 12_000)
    XCTAssertGreaterThanOrEqual(
      remotelyPlaying.audioSession.activationCount,
      1,
      "A remote Play command must activate the injected production audio-session platform"
    )

    app.buttons["e2e-remote-next-track"].tap()
    let skippedForward = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 42_000,
      sequence: 3,
      reason: "seek"
    )
    assertIdentityAndPersistence(skippedForward, expectedPositionMilliseconds: 42_000)

    app.buttons["e2e-remote-pause"].tap()
    let remotelyPaused = try requireProbe(
      probe,
      status: "paused",
      positionMilliseconds: 42_000,
      sequence: 4,
      reason: "pause"
    )
    assertIdentityAndPersistence(remotelyPaused, expectedPositionMilliseconds: 42_000)

    app.buttons["e2e-remote-toggle"].tap()
    let toggledPlaying = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 42_000,
      sequence: 5,
      reason: "play"
    )
    assertIdentityAndPersistence(toggledPlaying, expectedPositionMilliseconds: 42_000)

    app.buttons["e2e-remote-previous-track"].tap()
    let skippedBackward = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 27_000,
      sequence: 6,
      reason: "seek"
    )
    assertIdentityAndPersistence(skippedBackward, expectedPositionMilliseconds: 27_000)

    app.buttons["e2e-remote-toggle"].tap()
    let toggledPaused = try requireProbe(
      probe,
      status: "paused",
      positionMilliseconds: 27_000,
      sequence: 7,
      reason: "pause"
    )
    assertIdentityAndPersistence(toggledPaused, expectedPositionMilliseconds: 27_000)

    app.buttons["e2e-remote-play"].tap()
    _ = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 27_000,
      sequence: 8,
      reason: "play"
    )

    app.buttons["e2e-interruption-began"].tap()
    let interrupted = try requireProbe(
      probe,
      status: "paused",
      positionMilliseconds: 27_000,
      sequence: 9,
      reason: "interruption",
      postedAudioEvent: "interruption-began"
    )
    assertIdentityAndPersistence(interrupted, expectedPositionMilliseconds: 27_000)

    app.buttons["e2e-interruption-ended-no-resume"].tap()
    let interruptionEnded = try requireProbe(
      probe,
      status: "paused",
      positionMilliseconds: 27_000,
      sequence: 9,
      reason: "interruption",
      postedAudioEvent: "interruption-ended-no-resume"
    )
    XCTAssertEqual(interruptionEnded.status, interrupted.status)
    XCTAssertEqual(interruptionEnded.bookID, interrupted.bookID)
    XCTAssertEqual(interruptionEnded.chapterIndex, interrupted.chapterIndex)
    XCTAssertEqual(interruptionEnded.positionMilliseconds, interrupted.positionMilliseconds)
    XCTAssertEqual(interruptionEnded.sequence, interrupted.sequence)
    XCTAssertEqual(interruptionEnded.reason, interrupted.reason)
    XCTAssertEqual(
      interruptionEnded.persistedPositionMilliseconds,
      interrupted.persistedPositionMilliseconds,
      "An interruption configured not to resume must not fabricate a position event"
    )
    XCTAssertEqual(interruptionEnded.registeredCommands, interrupted.registeredCommands)
    XCTAssertEqual(
      interruptionEnded.audioSession.configureCount,
      interrupted.audioSession.configureCount
    )
    XCTAssertEqual(
      interruptionEnded.audioSession.activationCount,
      interrupted.audioSession.activationCount
    )
    XCTAssertEqual(
      interruptionEnded.audioSession.registeredNotifications,
      interrupted.audioSession.registeredNotifications
    )

    app.buttons["e2e-remote-play"].tap()
    _ = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 27_000,
      sequence: 10,
      reason: "play"
    )

    app.buttons["e2e-interruption-began"].tap()
    _ = try requireProbe(
      probe,
      status: "paused",
      positionMilliseconds: 27_000,
      sequence: 11,
      reason: "interruption",
      postedAudioEvent: "interruption-began"
    )

    app.buttons["e2e-interruption-ended-resume"].tap()
    let resumedAfterInterruption = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 27_000,
      sequence: 12,
      reason: "play",
      postedAudioEvent: "interruption-ended-resume"
    )
    assertIdentityAndPersistence(resumedAfterInterruption, expectedPositionMilliseconds: 27_000)

    app.buttons["e2e-old-device-unavailable"].tap()
    let routeLost = try requireProbe(
      probe,
      status: "paused",
      positionMilliseconds: 27_000,
      sequence: 13,
      reason: "routeChange",
      postedAudioEvent: "old-device-unavailable"
    )
    assertIdentityAndPersistence(routeLost, expectedPositionMilliseconds: 27_000)

    app.buttons["e2e-remote-play"].tap()
    _ = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 27_000,
      sequence: 14,
      reason: "play"
    )

    XCUIDevice.shared.press(.home)
    let backgroundState = XCTNSPredicateExpectation(
      predicate: NSPredicate { object, _ in
        guard let application = object as? XCUIApplication else { return false }
        return application.state == .runningBackground
          || application.state == .runningBackgroundSuspended
      },
      object: app
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [backgroundState], timeout: 2),
      .completed,
      "The app must enter a running or suspended background state before reactivation"
    )
    app.activate()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 2),
      "The app must be foreground-interactive before injecting the final remote command"
    )
    let backgrounded = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 27_000,
      sequence: 15,
      reason: "background"
    )
    assertIdentityAndPersistence(backgrounded, expectedPositionMilliseconds: 27_000)

    let finalPauseButton = app.buttons["e2e-remote-pause"]
    let hittable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"),
      object: finalPauseButton
    )
    XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 2), .completed)
    finalPauseButton.tap()
    let finalPause = try requireProbe(
      probe,
      status: "paused",
      positionMilliseconds: 27_000,
      sequence: 16,
      reason: "pause"
    )
    assertIdentityAndPersistence(finalPause, expectedPositionMilliseconds: 27_000)

    XCTAssertTrue(terminateAndWait(app))
    let restoredApp = makeApplication(reset: false)
    restoredApp.launch()
    let restoredProbe = restoredApp.otherElements["e2e-playback-probe"]
    let restored = try requireProbe(
      restoredProbe,
      status: "paused",
      positionMilliseconds: 27_000,
      sequence: 16,
      reason: "pause"
    )
    assertIdentityAndPersistence(restored, expectedPositionMilliseconds: 27_000)
    XCTAssertEqual(restored.registeredCommands, registeredCommands)
    assertProductionAdapterEvidence(restored, postedAudioEvent: "none")
  }

  private func makeApplication(reset: Bool) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e",
      "-e2e-event-controls",
      "-e2e-fixture", "committed-current-book",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset {
      app.launchArguments.insert("-e2e-reset", at: 1)
    }
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func requireProbe(
    _ element: XCUIElement,
    status: String,
    positionMilliseconds: Int,
    sequence: Int,
    reason: String,
    postedAudioEvent: String? = nil
  ) throws -> PlaybackJournalProbe {
    func matches(_ state: PlaybackJournalProbe) -> Bool {
      state.status == status
        && state.positionMilliseconds == positionMilliseconds
        && state.sequence == sequence
        && state.reason == reason
        && (postedAudioEvent == nil || state.audioSession.latestPostedEvent == postedAudioEvent)
    }
    let predicate = NSPredicate { object, _ in
      guard let element = object as? XCUIElement,
        let state = PlaybackJournalProbe(element.value as? String)
      else { return false }
      return matches(state)
    }
    _ = waitForPredicate(predicate, on: element)
    if let state = PlaybackJournalProbe(element.value as? String),
      matches(state)
    { return state }

    XCTFail(
      "The production playback probe did not report status=\(status), position=\(positionMilliseconds), sequence=\(sequence), reason=\(reason); latest=\(String(describing: element.value))"
    )
    throw RemoteInterruptionTestError.probeUnavailable
  }

  private func assertIdentityAndPersistence(
    _ state: PlaybackJournalProbe,
    expectedPositionMilliseconds: Int
  ) {
    XCTAssertEqual(state.bookID, fixtureBookID)
    XCTAssertEqual(state.chapterIndex, 0)
    XCTAssertEqual(state.positionMilliseconds, expectedPositionMilliseconds)
    XCTAssertEqual(state.persistedPositionMilliseconds, expectedPositionMilliseconds)
  }

  private func assertProductionAdapterEvidence(
    _ state: PlaybackJournalProbe,
    postedAudioEvent: String
  ) {
    XCTAssertEqual(state.registeredCommands, registeredCommands)
    XCTAssertEqual(state.audioSession.configureCount, 1)
    XCTAssertGreaterThanOrEqual(state.audioSession.activationCount, 0)
    XCTAssertEqual(state.audioSession.registeredNotifications, registeredAudioNotifications)
    XCTAssertEqual(state.audioSession.latestPostedEvent, postedAudioEvent)
  }
}

private struct PlaybackJournalProbe: Equatable {
  let status: String
  let bookID: String
  let chapterIndex: Int
  let positionMilliseconds: Int
  let sequence: Int
  let reason: String
  let persistedPositionMilliseconds: Int
  let registeredCommands: Set<String>
  let audioSession: AudioSessionProbeEvidence

  init?(_ value: String?) {
    guard let value else { return nil }
    let fields = value.split(separator: "|", omittingEmptySubsequences: false)
    guard
      fields.count == 10,
      fields[0] == "probe",
      fields[1] == "paused" || fields[1] == "playing",
      UUID(uuidString: String(fields[2])) != nil,
      let chapterIndex = Int(fields[3]), chapterIndex >= 0,
      let positionMilliseconds = Int(fields[4]), positionMilliseconds >= 0,
      let sequence = Int(fields[5]), sequence > 0,
      [
        "background",
        "interruption",
        "pause",
        "periodic",
        "play",
        "routeChange",
        "seek",
      ].contains(String(fields[6])),
      let persistedPositionMilliseconds = Int(fields[7]),
      persistedPositionMilliseconds >= 0,
      let audioSession = AudioSessionProbeEvidence(String(fields[9]))
    else { return nil }

    status = String(fields[1])
    bookID = fields[2].lowercased()
    self.chapterIndex = chapterIndex
    self.positionMilliseconds = positionMilliseconds
    self.sequence = sequence
    reason = String(fields[6])
    self.persistedPositionMilliseconds = persistedPositionMilliseconds
    registeredCommands = Set(fields[8].split(separator: ",").map(String.init))
    self.audioSession = audioSession
  }
}

private struct AudioSessionProbeEvidence: Equatable {
  let configureCount: Int
  let activationCount: Int
  let registeredNotifications: Set<String>
  let latestPostedEvent: String

  init?(_ value: String) {
    let fields = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 4,
      fields[0].hasPrefix("configured="),
      fields[1].hasPrefix("activated="),
      fields[2].hasPrefix("observers="),
      fields[3].hasPrefix("posted="),
      let configureCount = Int(fields[0].dropFirst("configured=".count)),
      configureCount >= 0,
      let activationCount = Int(fields[1].dropFirst("activated=".count)),
      activationCount >= 0
    else { return nil }

    self.configureCount = configureCount
    self.activationCount = activationCount
    registeredNotifications = Set(
      fields[2].dropFirst("observers=".count).split(separator: ",").map(String.init)
    )
    latestPostedEvent = String(fields[3].dropFirst("posted=".count))
  }
}

private enum RemoteInterruptionTestError: Error {
  case probeUnavailable
}
