import XCTest

@MainActor
final class SmartRewindUITests: XCTestCase {
  private let bookID = "51000000-0000-0000-0000-000000000001"
  private let preEventID = "51000000-0000-0000-0000-000000000101"
  private let rewindEventID = "51000000-0000-0000-0000-000000000102"
  private let transactionID = "51000000-0000-0000-0000-000000000103"
  private let undoEventID = "51000000-0000-0000-0000-000000000105"

  func testSmartRewindAdaptsClampsPersistsAndUndoesExactly() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let tester = TestStepHelper(testCase: self, startIndex: 3)
    tester.setMetadata(
      title: "Smart Rewind resumes safely and remains exactly undoable",
      narrative: "As a listener returning after time away, I want Player to rewind by a predictable amount without crossing the current chapter, explain the adjustment, and let me undo it exactly.",
      fixture: "smart-rewind",
      additionalPreconditions: [
        "The fixture contains one deterministic 180-second book with a logical chapter beginning at 100,000 milliseconds",
        "The injected clock reports exactly 600 seconds away for the photographed chapter-clamp case",
        "The durable paused position is 110,000 milliseconds and the 15-second tier clamps to the chapter start at 100,000 milliseconds",
        "The deterministic playback engine does not advance with wall-clock time",
      ]
    )

    try assertScenario(.init(
      name: "below-threshold", away: 29, original: 120_000,
      target: 120_000, rewind: 0, maximum: 30_000, enabled: true, clamped: false
    ))
    try assertScenario(.init(
      name: "short", away: 30, original: 120_000,
      target: 115_000, rewind: 5_000, maximum: 30_000, enabled: true, clamped: false
    ))
    try assertScenario(.init(
      name: "medium", away: 600, original: 120_000,
      target: 105_000, rewind: 15_000, maximum: 30_000, enabled: true, clamped: false
    ))
    try assertScenario(.init(
      name: "long", away: 3_601, original: 170_000,
      target: 140_000, rewind: 30_000, maximum: 30_000, enabled: true, clamped: false
    ))
    try assertConfiguredMaximumScenario()
    try assertScenario(.init(
      name: "disabled", away: 3_601, original: 120_000,
      target: 120_000, rewind: 0, maximum: 30_000, enabled: false, clamped: false
    ))

    let clamp = Scenario(
      name: "chapter-clamp", away: 600, original: 110_000,
      target: 100_000, rewind: 10_000, maximum: 30_000, enabled: true, clamped: true
    )
    let app = makeApplication(scenario: clamp.name, reset: true)
    app.launch()
    let applied = try openAndResume(app, scenario: clamp)
    try assertApplied(applied, scenario: clamp)

    let banner = app.descendants(matching: .any)["smart-rewind-banner"]
    try requireValue(
      banner,
      "rewound|\(bookID)|from=110000|to=100000|by=10000|away=600|clamped=true|status=applied"
    )
    let undo = app.buttons["undo-smart-rewind"]
    XCTAssertTrue(undo.exists)
    XCTAssertTrue(undo.isHittable)
    XCTAssertEqual(
      (undo.value as? String)?.replacingOccurrences(of: ",", with: ""),
      "restore=110000"
    )

    app.terminate()

    let restored = makeApplication(scenario: clamp.name, reset: false)
    restored.launch()
    let restoredMiniPlayer = restored.otherElements["mini-player"]
    XCTAssertTrue(restoredMiniPlayer.waitForExistence(timeout: 2))
    try requireValue(restoredMiniPlayer, miniPlayerValue(status: "paused", position: 100_000))
    restoredMiniPlayer.tap()

    let restoredProbe = try requireProbe(restored)
    try assertApplied(restoredProbe, scenario: clamp)
    XCTAssertEqual(restoredProbe.journal, applied.journal)
    let restoredUndo = restored.buttons["undo-smart-rewind"]
    XCTAssertTrue(restoredUndo.waitForExistence(timeout: 2))
    let restoredNowPlaying = restored.otherElements["now-playing-screen"]
    let restoredBanner = restored.descendants(matching: .any)["smart-rewind-banner"]
    try tester.step(
      "smart-rewind-applied",
      description: "Now Playing explains the durable chapter-clamped rewind before Undo",
      verifications: [
        .valueEquals(
          restoredNowPlaying,
          playerValue(status: "paused", position: 100_000),
          "Now Playing is paused exactly at the safe 100,000 ms chapter boundary"
        ),
        .valueEquals(
          restoredBanner,
          "rewound|\(bookID)|from=110000|to=100000|by=10000|away=600|clamped=true|status=applied",
          "The explanation identifies the original position, clamped target, elapsed absence, and applied transaction"
        ),
        .exists(
          restoredUndo,
          "A one-tap Undo remains available after process termination and relaunch"
        ),
      ]
    )
    restoredUndo.tap()

    try requireValue(
      restored.otherElements["now-playing-screen"],
      playerValue(status: "paused", position: 110_000)
    )
    let undone = try requireProbe(restored, latest: "undone", position: 110_000)
    XCTAssertEqual(undone["transactions"], "1")
    XCTAssertEqual(undone["transaction"], transactionID)
    XCTAssertEqual(undone["undo"], undoEventID)
    XCTAssertEqual(
      undone.journal,
      "1:pause@110000,2:preResumeRewind@110000,3:resumeRewind@100000,4:play@100000,5:undoResumeRewind@110000"
    )
    let confirmation = restored.descendants(matching: .any)["smart-rewind-undo-confirmation"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
    XCTAssertEqual(
      (confirmation.value as? String)?.replacingOccurrences(of: ",", with: ""),
      "restored=110000"
    )
    XCTAssertFalse(restored.buttons["undo-smart-rewind"].exists)
    tester.generateDocs()
  }

  private func assertScenario(_ scenario: Scenario) throws {
    let app = makeApplication(scenario: scenario.name, reset: true)
    app.launch()
    let probe = try openAndResume(app, scenario: scenario)
    if scenario.rewind == 0 {
      XCTAssertEqual(probe["enabled"], String(scenario.enabled))
      XCTAssertEqual(probe["maximum"], String(scenario.maximum))
      XCTAssertEqual(probe["transactions"], "0")
      XCTAssertEqual(probe["latest"], "none")
      XCTAssertEqual(probe["position"], String(scenario.original))
      XCTAssertEqual(
        probe.journal,
        "1:pause@\(scenario.original),2:play@\(scenario.original)"
      )
      XCTAssertFalse(app.descendants(matching: .any)["smart-rewind-banner"].exists)
    } else {
      try assertApplied(probe, scenario: scenario)
    }
    app.terminate()
  }

  private func assertConfiguredMaximumScenario() throws {
    let scenario = Scenario(
      name: "maximum", away: 3_601, original: 170_000,
      target: 150_000, rewind: 20_000, maximum: 20_000, enabled: true, clamped: false
    )
    let configuring = makeApplication(scenario: scenario.name, reset: true)
    configuring.launch()
    let initialSettings = try openSmartRewindSettings(configuring)
    try requireValue(
      initialSettings,
      settingsValue(enabled: true, maximum: 30)
    )

    let maximumPicker = configuring.buttons["smart-rewind-maximum"]
    XCTAssertTrue(maximumPicker.waitForExistence(timeout: 2))
    maximumPicker.tap()
    let twentySeconds = configuring.buttons["smart-rewind-maximum-20"]
    if twentySeconds.waitForExistence(timeout: 1) {
      twentySeconds.tap()
    } else {
      let fallback = configuring.buttons["20 seconds"]
      XCTAssertTrue(fallback.waitForExistence(timeout: 2))
      fallback.tap()
    }
    try requireValue(initialSettings, settingsValue(enabled: true, maximum: 20))

    let enabledToggle = configuring.switches["smart-rewind-enabled"]
    XCTAssertTrue(enabledToggle.waitForExistence(timeout: 2))
    tapTrailingSwitchControl(enabledToggle)
    try requireValue(initialSettings, settingsValue(enabled: false, maximum: 20))
    configuring.terminate()

    let disabledRestored = makeApplication(scenario: scenario.name, reset: false)
    disabledRestored.launch()
    let disabledSettings = try openSmartRewindSettings(disabledRestored)
    try requireValue(disabledSettings, settingsValue(enabled: false, maximum: 20))
    let restoredToggle = disabledRestored.switches["smart-rewind-enabled"]
    XCTAssertTrue(restoredToggle.waitForExistence(timeout: 2))
    tapTrailingSwitchControl(restoredToggle)
    try requireValue(disabledSettings, settingsValue(enabled: true, maximum: 20))
    disabledRestored.terminate()

    let enabledRestored = makeApplication(scenario: scenario.name, reset: false)
    enabledRestored.launch()
    let enabledSettings = try openSmartRewindSettings(enabledRestored)
    try requireValue(enabledSettings, settingsValue(enabled: true, maximum: 20))
    enabledRestored.tabBars.buttons["Library"].tap()
    let probe = try openAndResume(enabledRestored, scenario: scenario)
    try assertApplied(probe, scenario: scenario)
    enabledRestored.terminate()
  }

  private func openSmartRewindSettings(_ app: XCUIApplication) throws -> XCUIElement {
    app.tabBars.buttons["Settings"].tap()
    let link = app.buttons["smart-rewind-settings"]
    XCTAssertTrue(link.waitForExistence(timeout: 2))
    link.tap()
    let screen = app.descendants(matching: .any)["smart-rewind-settings-screen"]
    XCTAssertTrue(screen.waitForExistence(timeout: 2))
    return screen
  }

  private func tapTrailingSwitchControl(_ element: XCUIElement) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
  }

  private func settingsValue(enabled: Bool, maximum: Int) -> String {
    "smart-rewind:enabled=\(enabled):maximum=\(maximum):thresholds=30,600,3600:rewinds=5,15,30"
  }

  private func openAndResume(_ app: XCUIApplication, scenario: Scenario) throws -> ProbeState {
    let miniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2), "Missing mini-player for \(scenario.name)")
    try requireValue(miniPlayer, miniPlayerValue(status: "paused", position: scenario.original))
    miniPlayer.tap()

    let nowPlaying = app.otherElements["now-playing-screen"]
    XCTAssertTrue(nowPlaying.waitForExistence(timeout: 2))
    let probe = app.descendants(matching: .any)["smart-rewind-state-probe"]
    XCTAssertTrue(probe.waitForExistence(timeout: 2))
    app.buttons["player-play-pause"].tap()
    try requireValue(nowPlaying, playerValue(status: "playing", position: scenario.target))
    return try requireProbe(app, latest: scenario.rewind == 0 ? "none" : "applied", position: scenario.target)
  }

  private func assertApplied(_ probe: ProbeState, scenario: Scenario) throws {
    XCTAssertEqual(probe["enabled"], String(scenario.enabled))
    XCTAssertEqual(probe["maximum"], String(scenario.maximum))
    XCTAssertEqual(probe["transactions"], "1")
    XCTAssertEqual(probe["latest"], "applied")
    XCTAssertEqual(probe["transaction"], transactionID)
    XCTAssertEqual(probe["from"], String(scenario.original))
    XCTAssertEqual(probe["to"], String(scenario.target))
    XCTAssertEqual(probe["by"], String(scenario.rewind))
    XCTAssertEqual(probe["away"], String(scenario.away))
    XCTAssertEqual(probe["clamped"], String(scenario.clamped))
    XCTAssertEqual(probe["pre"], preEventID)
    XCTAssertEqual(probe["rewind"], rewindEventID)
    XCTAssertEqual(probe["undo"], "none")
    XCTAssertEqual(probe["position"], String(scenario.target))
    XCTAssertEqual(
      probe.journal,
      "1:pause@\(scenario.original),2:preResumeRewind@\(scenario.original),3:resumeRewind@\(scenario.target),4:play@\(scenario.target)"
    )
  }

  private func requireProbe(
    _ app: XCUIApplication,
    latest: String? = nil,
    position: Int64? = nil
  ) throws -> ProbeState {
    let element = app.descendants(matching: .any)["smart-rewind-state-probe"]
    let deadline = Date().addingTimeInterval(2)
    repeat {
      if let value = element.value as? String,
        let state = ProbeState(value),
        latest == nil || state["latest"] == latest,
        position == nil || state["position"] == String(position!)
      {
        return state
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    XCTFail("Smart Rewind probe did not reach latest=\(latest ?? "any") position=\(position.map(String.init) ?? "any"); actual=\(String(describing: element.value))")
    throw SmartRewindUITestError.probeUnavailable
  }

  private func requireValue(
    _ element: XCUIElement,
    _ expected: String,
    timeout: TimeInterval = 2
  ) throws {
    guard element.waitForStringValue(expected, timeout: timeout) else {
      XCTFail("Expected \(element) to expose \(expected); actual=\(String(describing: element.value))")
      throw SmartRewindUITestError.probeUnavailable
    }
  }

  private func playerValue(status: String, position: Int64) -> String {
    let chapter: Int
    switch position {
    case 140_000...: chapter = 3
    case 100_000...: chapter = 2
    case 60_000...: chapter = 1
    default: chapter = 0
    }
    return "player:\(status):\(bookID):\(chapter):\(position)"
  }

  private func miniPlayerValue(status: String, position: Int64) -> String {
    "player:\(status):\(bookID):0:\(position)"
  }

  private func makeApplication(scenario: String, reset: Bool) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e",
      "-e2e-fixture", "smart-rewind",
      "-e2e-smart-rewind-scenario", scenario,
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset { app.launchArguments.insert("-e2e-reset", at: 1) }
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }
}

private struct Scenario {
  var name: String
  var away: Int
  var original: Int64
  var target: Int64
  var rewind: Int64
  var maximum: Int64
  var enabled: Bool
  var clamped: Bool
}

private struct ProbeState {
  var fields: [String: String]

  init?(_ rawValue: String) {
    let tokens = rawValue.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard tokens.first == "smart-rewind" else { return nil }
    fields = Dictionary(uniqueKeysWithValues: tokens.dropFirst().compactMap { token in
      guard let separator = token.firstIndex(of: "=") else { return nil }
      return (String(token[..<separator]), String(token[token.index(after: separator)...]))
    })
  }

  subscript(_ key: String) -> String? { fields[key] }
  var journal: String? { fields["journal"] }
}

private enum SmartRewindUITestError: Error {
  case probeUnavailable
}
