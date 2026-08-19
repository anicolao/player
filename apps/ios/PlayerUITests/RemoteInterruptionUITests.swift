import XCTest

@MainActor
final class RemoteInterruptionUITests: XCTestCase {
  private let fixtureBookID = "20000000-0000-0000-0000-000000000001"
  private let registeredCommands: Set<String> = [
    "change-position", "pause", "play", "skip-backward", "skip-forward", "toggle",
  ]

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

    app.buttons["e2e-remote-play"].tap()
    let remotelyPlaying = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 12_000,
      sequence: 2,
      reason: "play"
    )
    assertIdentityAndPersistence(remotelyPlaying, expectedPositionMilliseconds: 12_000)

    app.buttons["e2e-remote-skip-forward"].tap()
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

    app.buttons["e2e-remote-skip-backward"].tap()
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
      reason: "interruption"
    )
    assertIdentityAndPersistence(interrupted, expectedPositionMilliseconds: 27_000)

    app.buttons["e2e-interruption-ended-no-resume"].tap()
    let interruptionEnded = try requireProbe(
      probe,
      status: "paused",
      positionMilliseconds: 27_000,
      sequence: 9,
      reason: "interruption"
    )
    XCTAssertEqual(
      interruptionEnded,
      interrupted,
      "An interruption configured not to resume must not fabricate a position event"
    )

    app.buttons["e2e-remote-play"].tap()
    _ = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 27_000,
      sequence: 10,
      reason: "play"
    )

    XCUIDevice.shared.press(.home)
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    app.activate()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 2),
      "The app must be foreground-interactive before injecting the final remote command"
    )
    let backgrounded = try requireProbe(
      probe,
      status: "playing",
      positionMilliseconds: 27_000,
      sequence: 11,
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
      sequence: 12,
      reason: "pause"
    )
    assertIdentityAndPersistence(finalPause, expectedPositionMilliseconds: 27_000)

    app.terminate()
    let restoredApp = makeApplication(reset: false)
    restoredApp.launch()
    let restoredProbe = restoredApp.otherElements["e2e-playback-probe"]
    let restored = try requireProbe(
      restoredProbe,
      status: "paused",
      positionMilliseconds: 27_000,
      sequence: 12,
      reason: "pause"
    )
    assertIdentityAndPersistence(restored, expectedPositionMilliseconds: 27_000)
    XCTAssertEqual(restored.registeredCommands, registeredCommands)
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
    reason: String
  ) throws -> PlaybackJournalProbe {
    let deadline = Date().addingTimeInterval(2)
    var latestValue: String?
    repeat {
      latestValue = element.value as? String
      if let state = PlaybackJournalProbe(latestValue),
         state.status == status,
         state.positionMilliseconds == positionMilliseconds,
         state.sequence == sequence,
         state.reason == reason {
        return state
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline

    XCTFail(
      "The production playback probe did not report status=\(status), position=\(positionMilliseconds), sequence=\(sequence), reason=\(reason); latest=\(latestValue ?? "nil")"
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

  init?(_ value: String?) {
    guard let value else { return nil }
    let fields = value.split(separator: "|", omittingEmptySubsequences: false)
    guard fields.count == 9,
          fields[0] == "probe",
          fields[1] == "paused" || fields[1] == "playing",
          UUID(uuidString: String(fields[2])) != nil,
          let chapterIndex = Int(fields[3]), chapterIndex >= 0,
          let positionMilliseconds = Int(fields[4]), positionMilliseconds >= 0,
          let sequence = Int(fields[5]), sequence > 0,
          ["background", "interruption", "pause", "periodic", "play", "seek"]
            .contains(String(fields[6])),
          let persistedPositionMilliseconds = Int(fields[7]),
          persistedPositionMilliseconds >= 0
    else { return nil }

    status = String(fields[1])
    bookID = fields[2].lowercased()
    self.chapterIndex = chapterIndex
    self.positionMilliseconds = positionMilliseconds
    self.sequence = sequence
    reason = String(fields[6])
    self.persistedPositionMilliseconds = persistedPositionMilliseconds
    registeredCommands = Set(fields[8].split(separator: ",").map(String.init))
  }
}

private enum RemoteInterruptionTestError: Error {
  case probeUnavailable
}
