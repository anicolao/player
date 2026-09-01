import XCTest

@MainActor
final class SmartRewindUITests: PlayerUITestCase {
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
      narrative: "As a listener returning after time away, I want Bookshelf to rewind by a predictable amount without crossing the current chapter, explain the adjustment, and let me undo it exactly.",
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

    XCTAssertTrue(terminateAndWait(app))

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
    let restoredLayoutReadiness =
      restored.descendants(matching: .any)["now-playing-layout-readiness"]
    let expectedNowPlaying = playerValue(status: "paused", position: 100_000)
    let expectedBanner =
      "rewound|\(bookID)|from=110000|to=100000|by=10000|away=600|clamped=true|status=applied"
    try tester.step(
      "smart-rewind-applied",
      description: "Now Playing explains the durable chapter-clamped rewind before Undo",
      verifications: [
        .valueEquals(
          restoredNowPlaying,
          expectedNowPlaying,
          "Now Playing is paused exactly at the safe 100,000 ms chapter boundary"
        ),
        .valueEquals(
          restoredBanner,
          expectedBanner,
          "The explanation identifies the original position, clamped target, elapsed absence, and applied transaction"
        ),
        .exists(
          restoredUndo,
          "A one-tap Undo remains available after process termination and relaunch"
        ),
      ],
      captureReadiness: CaptureReadiness(
        specification: "At capture, the exact restored rewind state, explanation, and fully visible Undo are settled without a keyboard, alert, or unrelated sheet",
        anchor: restoredLayoutReadiness
      ) {
        let hasUnintendedSheet = restored.sheets.allElementsBoundByIndex.contains { sheet in
          sheet.identifier != "now-playing-screen"
            && !sheet.descendants(matching: .any)["now-playing-screen"].exists
        }
        guard
          restoredNowPlaying.exists,
          restoredNowPlaying.value.map(String.init(describing:)) == expectedNowPlaying,
          restoredBanner.exists,
          restoredBanner.value.map(String.init(describing:)) == expectedBanner,
          elementIsFullyVisible(restoredUndo, within: restoredNowPlaying),
          let layout = LayoutReadinessState(restoredLayoutReadiness.value),
          layout.containerID == "now-playing-screen"
        else { return false }
        return !restored.keyboards.firstMatch.exists
          && !restored.alerts.firstMatch.exists
          && !hasUnintendedSheet
      }
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

  func testSmartRewindNoticeDismissesAfterFiveSecondsOfPlaybackProgress() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let scenario = Scenario(
      name: "chapter-clamp", away: 600, original: 110_000,
      target: 100_000, rewind: 10_000, maximum: 30_000, enabled: true, clamped: true
    )
    let app = makeApplication(scenario: scenario.name, reset: true)
    app.launchArguments.append("-e2e-rewind-expiry-control")
    app.launch()
    _ = try openAndResume(app, scenario: scenario)
    let banner = app.descendants(matching: .any)["smart-rewind-banner"]
    XCTAssertTrue(banner.waitForExistence(timeout: 2))

    app.buttons["e2e-advance-rewind-expiry"].tap()

    XCTAssertTrue(banner.waitForNonExistence(timeout: 2))
    XCTAssertFalse(app.buttons["undo-smart-rewind"].exists)
    _ = try requireProbe(app, latest: "dismissed", position: 105_000)
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
    XCTAssertTrue(terminateAndWait(app))
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
    let twentySecondOptions = configuring.buttons.matching(
      identifier: "smart-rewind-maximum-20"
    )
    let twentySeconds = twentySecondOptions.element
    XCTAssertTrue(twentySeconds.waitForExistence(timeout: 2))
    XCTAssertEqual(twentySecondOptions.count, 1, "The picker option identifier must be unique.")
    twentySeconds.tap()
    try requireValue(initialSettings, settingsValue(enabled: true, maximum: 20))

    let enabledToggle = configuring.switches["smart-rewind-enabled"]
    XCTAssertTrue(enabledToggle.waitForExistence(timeout: 2))
    try setTrailingSwitchControl(
      enabledToggle,
      to: false,
      receipt: initialSettings,
      expectedReceipt: settingsValue(enabled: false, maximum: 20),
      in: configuring
    )
    XCTAssertTrue(terminateAndWait(configuring))

    let disabledRestored = makeApplication(scenario: scenario.name, reset: false)
    disabledRestored.launch()
    let disabledSettings = try openSmartRewindSettings(disabledRestored)
    try requireValue(disabledSettings, settingsValue(enabled: false, maximum: 20))
    let restoredToggle = disabledRestored.switches["smart-rewind-enabled"]
    XCTAssertTrue(restoredToggle.waitForExistence(timeout: 2))
    try setTrailingSwitchControl(
      restoredToggle,
      to: true,
      receipt: disabledSettings,
      expectedReceipt: settingsValue(enabled: true, maximum: 20),
      in: disabledRestored
    )
    XCTAssertTrue(terminateAndWait(disabledRestored))

    let enabledRestored = makeApplication(scenario: scenario.name, reset: false)
    enabledRestored.launch()
    let enabledSettings = try openSmartRewindSettings(enabledRestored)
    try requireValue(enabledSettings, settingsValue(enabled: true, maximum: 20))
    enabledRestored.tabBars.buttons["Library"].tap()
    let probe = try openAndResume(enabledRestored, scenario: scenario)
    try assertApplied(probe, scenario: scenario)
    XCTAssertTrue(terminateAndWait(enabledRestored))
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

  private func setTrailingSwitchControl(
    _ element: XCUIElement,
    to enabled: Bool,
    receipt: XCUIElement,
    expectedReceipt: String,
    in app: XCUIApplication
  ) throws {
    let receiptPredicate = NSPredicate(
      format: "exists == true AND value == %@", expectedReceipt
    )
    if receiptPredicate.evaluate(with: receipt) { return }

    let expectedControlValue = enabled ? "1" : "0"
    let requestedPredicate = NSPredicate(
      format: "exists == true AND value == %@", expectedControlValue
    )
    let interactive = NSPredicate { _, _ in
      guard app.state == .runningForeground,
        element.exists,
        element.isEnabled,
        element.isHittable
      else { return false }
      let appFrame = app.frame
      let elementFrame = element.frame
      return !appFrame.isEmpty
        && !elementFrame.isEmpty
        && appFrame.contains(elementFrame)
    }
    guard waitForPredicate(interactive, on: element, timeout: 2) else {
      XCTFail("The Smart Rewind switch did not expose a contained physical action")
      throw SmartRewindUITestError.switchActionUnavailable
    }

    let elementFrame = element.frame
    let appFrame = app.frame
    let coordinate = app.coordinate(
      withNormalizedOffset: CGVector(
        dx: (elementFrame.minX + elementFrame.width * 0.9 - appFrame.minX) / appFrame.width,
        dy: (elementFrame.midY - appFrame.minY) / appFrame.height
      )
    )
    let acceptedOrCompleted = NSPredicate { _, _ in
      requestedPredicate.evaluate(with: element)
        || receiptPredicate.evaluate(with: receipt)
    }
    var deliveryDeadline: EventDeadline?

    repeat {
      if receiptPredicate.evaluate(with: receipt) { return }
      if requestedPredicate.evaluate(with: element) {
        guard let deliveryDeadline,
          waitForPredicate(
            receiptPredicate,
            on: receipt,
            timeout: deliveryDeadline.remaining
          )
        else {
          XCTFail("The Smart Rewind switch accepted the request without persisting it")
          throw SmartRewindUITestError.switchActionUnavailable
        }
        return
      }
      guard element.exists, element.isEnabled, element.isHittable,
        element.frame == elementFrame
      else {
        guard let deliveryDeadline,
          waitForPredicate(
            receiptPredicate,
            on: receipt,
            timeout: deliveryDeadline.remaining
          )
        else {
          XCTFail("The Smart Rewind switch transitioned without a durable receipt")
          throw SmartRewindUITestError.switchActionUnavailable
        }
        return
      }
      if let deliveryDeadline, deliveryDeadline.remaining <= 0 { break }

      guard performPhysicalInteractionWithoutPostEventQuiescence(
        in: app,
        { coordinate.tap() }
      ) else {
        XCTFail("The pinned XCTest runtime did not expose bounded physical synthesis")
        throw SmartRewindUITestError.switchActionUnavailable
      }
      if deliveryDeadline == nil { deliveryDeadline = EventDeadline() }
      guard let deliveryDeadline else {
        XCTFail("The Smart Rewind switch could not establish its delivery deadline")
        throw SmartRewindUITestError.switchActionUnavailable
      }
      _ = waitForPredicate(
        acceptedOrCompleted,
        on: element,
        timeout: min(0.25, deliveryDeadline.remaining)
      )
    } while (deliveryDeadline?.remaining ?? 0) > 0

    XCTFail("The Smart Rewind switch did not publish requested or durable state")
    throw SmartRewindUITestError.switchActionUnavailable
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
    func matches(_ state: ProbeState) -> Bool {
      (latest == nil || state["latest"] == latest)
        && (position == nil || state["position"] == String(position!))
    }
    let predicate = NSPredicate { object, _ in
      guard let element = object as? XCUIElement,
        let value = element.value as? String,
        let state = ProbeState(value)
      else { return false }
      return matches(state)
    }
    _ = waitForPredicate(predicate, on: element)
    if let value = element.value as? String,
      let state = ProbeState(value),
      matches(state)
    { return state }
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
    "player:\(status):\(bookID):\(chapterIndex(at: position)):\(position)"
  }

  private func chapterIndex(at position: Int64) -> Int {
    switch position {
    case 140_000...: 3
    case 100_000...: 2
    case 60_000...: 1
    default: 0
    }
  }

  private func miniPlayerValue(status: String, position: Int64) -> String {
    playerValue(status: status, position: position)
  }

  private func makeApplication(scenario: String, reset: Bool) -> XCUIApplication {
    let app = bookshelfApplication()
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
  private enum SchemaVersion: String {
    case v1 = "smart-rewind"
  }

  private static let baseKeys: Set<String> = [
    "schema", "enabled", "maximum", "transactions", "latest", "position", "journal",
  ]
  private static let transactionKeys: Set<String> = [
    "transaction", "from", "to", "by", "away", "clamped", "pre", "rewind", "undo",
  ]
  private static let statuses: Set<String> = ["none", "applied", "undone", "superseded", "dismissed"]
  private static let journalReasons: Set<String> = [
    "pause", "preResumeRewind", "resumeRewind", "play", "seek", "undoResumeRewind",
  ]

  private var fields: [String: String]

  init?(_ rawValue: String) {
    let tokens = rawValue.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard let discriminator = tokens.first,
      SchemaVersion(rawValue: discriminator) == .v1
    else { return nil }
    var parsed: [String: String] = [:]
    for token in tokens.dropFirst() {
      guard let separator = token.firstIndex(of: "=") else { return nil }
      let key = String(token[..<separator])
      let value = String(token[token.index(after: separator)...])
      guard !key.isEmpty, (!value.isEmpty || key == "journal"), parsed[key] == nil else {
        return nil
      }
      parsed[key] = value
    }

    guard parsed["schema"] == "1",
      Self.bool(parsed["enabled"]) != nil,
      let maximum = Self.nonnegativeInt64(parsed["maximum"]), maximum <= 30_000,
      let transactionCount = Self.nonnegativeInt(parsed["transactions"]),
      let latest = parsed["latest"], Self.statuses.contains(latest),
      Self.nonnegativeInt64(parsed["position"]) != nil,
      let journal = parsed["journal"], Self.validJournal(journal)
    else { return nil }

    let expectedKeys: Set<String>
    if transactionCount == 0 {
      guard latest == "none" else { return nil }
      expectedKeys = Self.baseKeys
    } else {
      guard latest != "none", !journal.isEmpty,
        Self.uuid(parsed["transaction"]),
        Self.nonnegativeInt64(parsed["from"]) != nil,
        Self.nonnegativeInt64(parsed["to"]) != nil,
        Self.nonnegativeInt64(parsed["by"]) != nil,
        Self.nonnegativeInt(parsed["away"]) != nil,
        Self.bool(parsed["clamped"]) != nil,
        Self.uuid(parsed["pre"]),
        Self.uuid(parsed["rewind"]),
        parsed["undo"] == "none" || Self.uuid(parsed["undo"])
      else { return nil }
      expectedKeys = Self.baseKeys.union(Self.transactionKeys)
    }
    guard Set(parsed.keys) == expectedKeys else { return nil }
    fields = parsed
  }

  subscript(_ key: String) -> String? { fields[key] }
  var journal: String? { fields["journal"] }

  private static func bool(_ value: String?) -> Bool? {
    switch value {
    case "true": true
    case "false": false
    default: nil
    }
  }

  private static func nonnegativeInt(_ value: String?) -> Int? {
    guard let value, let parsed = Int(value), parsed >= 0, String(parsed) == value else { return nil }
    return parsed
  }

  private static func nonnegativeInt64(_ value: String?) -> Int64? {
    guard let value, let parsed = Int64(value), parsed >= 0, String(parsed) == value else {
      return nil
    }
    return parsed
  }

  private static func uuid(_ value: String?) -> Bool {
    guard let value, let parsed = UUID(uuidString: value) else { return false }
    return parsed.uuidString.lowercased() == value
  }

  private static func validJournal(_ value: String) -> Bool {
    // A current book can render before its first acknowledged position event,
    // so an empty journal is a valid v1 state only when no rewind exists.
    if value.isEmpty { return true }
    let events = value.split(separator: ",", omittingEmptySubsequences: false)
    guard !events.isEmpty else { return false }
    var previousSequence = 0
    for event in events {
      let sequenceAndEvent = event.split(
        separator: ":",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      guard sequenceAndEvent.count == 2,
        let sequence = nonnegativeInt(String(sequenceAndEvent[0])),
        sequence > previousSequence
      else { return false }
      let reasonAndPosition = sequenceAndEvent[1].split(
        separator: "@",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      guard reasonAndPosition.count == 2,
        journalReasons.contains(String(reasonAndPosition[0])),
        nonnegativeInt64(String(reasonAndPosition[1])) != nil
      else { return false }
      previousSequence = sequence
    }
    return true
  }
}

private enum SmartRewindUITestError: Error {
  case probeUnavailable
  case switchActionUnavailable
}
