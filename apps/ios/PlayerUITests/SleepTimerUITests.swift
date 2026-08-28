import XCTest

@MainActor
final class SleepTimerUITests: XCTestCase {
  private let bookID = "52000000-0000-0000-0000-000000000001"
  private let timer101 = "52000000-0000-0000-0000-000000000101"

  func testSleepTimerPersistsFadesStopsAndResumesWithContextExactly() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "Sleep Timer persists, stops exactly, and offers one contextual resume",
      narrative: "As a listener falling asleep, I want a durable timer that stops at the boundary I chose and offers one safe way back when I return soon.",
      fixture: "sleep-timer",
      additionalPreconditions: [
        "The fixture contains one deterministic 180-second book paused at 70,000 milliseconds",
        "Its first track ends at 90,000 milliseconds and its current chapter ends at 120,000 milliseconds",
        "The injected clock is fixed at epoch 1,700,020,000 until the E2E bridge evaluates a boundary",
        "The deterministic playback engine acknowledges seeks and pauses without advancing wall-clock time",
      ]
    )

    try assertEveryProductionSelection()
    try assertReplacementCancellationAndHistoryPersist()
    try assertPersistentFadeCompletionAndSingleUseContextResume(tester: tester)
  }

  private func assertEveryProductionSelection() throws {
    let selections = [
      SelectionCase(namespace: "preset-10", buttonID: "sleep-timer-preset-10", token: "preset-10", remaining: 600, target: nil, fade: true),
      SelectionCase(namespace: "preset-15", buttonID: "sleep-timer-preset-15", token: "preset-15", remaining: 900, target: nil, fade: true),
      SelectionCase(namespace: "preset-30", buttonID: "sleep-timer-preset-30", token: "preset-30", remaining: 1_800, target: nil, fade: true),
      SelectionCase(namespace: "preset-45", buttonID: "sleep-timer-preset-45", token: "preset-45", remaining: 2_700, target: nil, fade: false),
      SelectionCase(namespace: "preset-60", buttonID: "sleep-timer-preset-60", token: "preset-60", remaining: 3_600, target: nil, fade: true),
      SelectionCase(namespace: "custom-25", buttonID: "start-custom-sleep-timer", token: "custom-1500", remaining: 1_500, target: nil, fade: true, custom: true),
      SelectionCase(namespace: "end-chapter", buttonID: "sleep-timer-end-chapter", token: "end-chapter", remaining: 50, target: 120_000, fade: true),
      SelectionCase(namespace: "end-track", buttonID: "sleep-timer-end-track", token: "end-track", remaining: 20, target: 90_000, fade: true),
    ]

    for selection in selections {
      let app = makeApplication(namespace: selection.namespace, reset: true)
      app.launch()
      try openNowPlaying(app)
      let screen = try openSleepTimer(app)
      if !selection.fade {
        let toggle = app.switches["sleep-timer-fade"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        tapTrailingSwitchControl(toggle)
        try requireValue(screen, "sleep-timer:active=none:fade=false:history=0")
      }
      if selection.custom {
        let picker = app.buttons["sleep-timer-custom-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 2))
        picker.tap()
        let option = app.buttons["sleep-timer-custom-25"]
        if option.waitForExistence(timeout: 1) {
          option.tap()
        } else {
          let fallback = app.buttons["25 minutes"]
          XCTAssertTrue(fallback.waitForExistence(timeout: 2))
          fallback.tap()
        }
      }
      try tapWhenHittable(app.buttons[selection.buttonID], in: app)
      let probe = try requireProbe(app, active: timer101)
      XCTAssertEqual(probe["selection"], selection.token)
      XCTAssertEqual(probe["fade"], String(selection.fade))
      XCTAssertEqual(probe["phase"], "active")
      XCTAssertEqual(probe["remaining"], String(selection.remaining))
      XCTAssertEqual(probe["target"], selection.target.map(String.init) ?? "none")
      XCTAssertEqual(probe["history"], "0")
      XCTAssertEqual(probe["rewinds"], "0")
      XCTAssertEqual(probe["position"], "70000")
      XCTAssertEqual(probe.journal, "1:pause@70000")
      app.terminate()
    }
  }

  private func assertReplacementCancellationAndHistoryPersist() throws {
    let app = makeApplication(namespace: "replace-cancel", reset: true)
    app.launch()
    try openNowPlaying(app)
    _ = try openSleepTimer(app)
    try tapWhenHittable(app.buttons["sleep-timer-preset-10"], in: app)
    _ = try requireProbe(app, active: timer101)

    _ = try openSleepTimer(app)
    try tapWhenHittable(app.buttons["sleep-timer-preset-15"], in: app)
    let replaced = try requireProbe(
      app,
      active: "52000000-0000-0000-0000-000000000102"
    )
    XCTAssertEqual(replaced["history"], "1")
    XCTAssertEqual(replaced["latest"], "replaced")
    XCTAssertEqual(replaced["history-id"], "52000000-0000-0000-0000-000000000103")
    XCTAssertEqual(replaced["history-timer"], timer101)
    XCTAssertEqual(replaced["history-selection"], "preset-10")
    XCTAssertEqual(replaced["stop"], "70000")
    XCTAssertEqual(replaced["event"], "none")

    _ = try openSleepTimer(app)
    let cancel = app.buttons["cancel-sleep-timer"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 2))
    cancel.tap()
    let cancelled = try requireProbe(app, active: "none", historyCount: 2)
    XCTAssertEqual(cancelled["rewinds"], "0")
    XCTAssertEqual(cancelled["context"], "none")
    app.terminate()

    let restored = makeApplication(namespace: "replace-cancel", reset: false)
    restored.launch()
    try openNowPlaying(restored)
    let screen = try openSleepTimer(restored)
    try requireValue(screen, "sleep-timer:active=none:fade=true:history=2")
    try requireValueAfterScrolling(
      restored.descendants(matching: .any)["sleep-history-52000000-0000-0000-0000-000000000103"],
      "history=52000000-0000-0000-0000-000000000103:timer=\(timer101):selection=preset-10:status=replaced:stop=70000:event=none:context-used=false",
      in: restored
    )
    try requireValueAfterScrolling(
      restored.descendants(matching: .any)["sleep-history-52000000-0000-0000-0000-000000000104"],
      "history=52000000-0000-0000-0000-000000000104:timer=52000000-0000-0000-0000-000000000102:selection=preset-15:status=cancelled:stop=70000:event=none:context-used=false",
      in: restored
    )
    restored.terminate()
  }

  private func assertPersistentFadeCompletionAndSingleUseContextResume(
    tester: TestStepHelper
  ) throws {
    let app = makeApplication(namespace: "persistent", reset: true)
    app.launch()
    try openNowPlaying(app)
    _ = try openSleepTimer(app)
    try tapWhenHittable(app.buttons["sleep-timer-end-track"], in: app)
    let started = try requireProbe(app, active: timer101)
    XCTAssertEqual(started["selection"], "end-track")
    XCTAssertEqual(started["remaining"], "20")
    XCTAssertEqual(started["target"], "90000")
    XCTAssertEqual(started["fade"], "true")
    app.terminate()

    let restored = makeApplication(namespace: "persistent", reset: false)
    restored.launch()
    let miniPlayer = restored.otherElements["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    try requireValue(
      miniPlayer,
      "player:paused:\(bookID):0:70000|sleep=\(timer101),selection=end-track,remaining=20,fade=true,phase=active"
    )
    miniPlayer.tap()
    let activeScreen = try openSleepTimer(restored)
    try requireValue(
      activeScreen,
      "sleep-timer:active=\(timer101):selection=end-track:remaining=20:target=90000:fade=true:phase=active:history=0"
    )
    try requireValue(
      restored.descendants(matching: .any)["active-sleep-timer"],
      "timer=\(timer101):selection=end-track:remaining=20:target=90000:fade=true:phase=active"
    )
    XCTAssertTrue(restored.buttons["cancel-sleep-timer"].exists)
    try tester.step(
      "persisted-active-sleep-timer",
      description: "The active end-of-track timer remains clear after relaunch",
      verifications: [
        .valueEquals(
          activeScreen,
          "sleep-timer:active=\(timer101):selection=end-track:remaining=20:target=90000:fade=true:phase=active:history=0",
          "The production timer sheet restores the same timer, target, fade preference, and active phase"
        ),
        .valueEquals(
          restored.descendants(matching: .any)["active-sleep-timer"],
          "timer=\(timer101):selection=end-track:remaining=20:target=90000:fade=true:phase=active",
          "The listener sees twenty seconds remaining until the exact 90,000 ms track boundary"
        ),
        .exists(
          restored.buttons["cancel-sleep-timer"],
          "The persisted timer remains cancellable"
        ),
      ]
    )
    let sleepTimerDone = restored.navigationBars["Sleep Timer"].buttons["Done"]
    XCTAssertTrue(sleepTimerDone.waitForExistence(timeout: 2))
    sleepTimerDone.tap()

    let nowPlaying = restored.otherElements["now-playing-screen"]
    let playPause = restored.buttons["player-play-pause"]
    playPause.tap()
    try requireValue(nowPlaying, "player:playing:\(bookID):1:70000")
    var probe = try requireProbe(restored, active: timer101, position: 70_000)
    XCTAssertEqual(probe.journal, "1:pause@70000,2:play@70000")

    let fade = restored.buttons["e2e-sleep-enter-fade"]
    XCTAssertTrue(fade.waitForExistence(timeout: 2))
    fade.tap()
    probe = try requireProbe(restored, active: timer101, phase: "fading", position: 85_000)
    XCTAssertEqual(probe["remaining"], "5")
    XCTAssertEqual(probe["history"], "0")
    XCTAssertEqual(probe["playback"], "playing")
    XCTAssertEqual(probe.journal, "1:pause@70000,2:play@70000,3:seek@85000")

    let complete = restored.buttons["e2e-sleep-complete-boundary"]
    XCTAssertTrue(complete.waitForExistence(timeout: 2))
    complete.tap()
    probe = try requireProbe(restored, active: "none", historyCount: 1, position: 90_000)
    XCTAssertEqual(probe["latest"], "completed")
    XCTAssertEqual(probe["history-id"], "52000000-0000-0000-0000-000000000106")
    XCTAssertEqual(probe["history-timer"], timer101)
    XCTAssertEqual(probe["history-selection"], "end-track")
    XCTAssertEqual(probe["stop"], "90000")
    XCTAssertEqual(probe["event"], "52000000-0000-0000-0000-000000000105")
    XCTAssertEqual(probe["context"], "52000000-0000-0000-0000-000000000106")
    XCTAssertEqual(probe["context-stop"], "90000")
    XCTAssertEqual(probe["context-until"], "1700020600")
    XCTAssertEqual(probe["playback"], "paused")
    XCTAssertEqual(
      probe.journal,
      "1:pause@70000,2:play@70000,3:seek@85000,4:seek@90000,5:sleepTimer@90000"
    )
    restored.terminate()

    let expired = makeApplication(namespace: "persistent", reset: false)
    expired.launch()
    let expiredMiniPlayer = expired.otherElements["mini-player"]
    XCTAssertTrue(expiredMiniPlayer.waitForExistence(timeout: 2))
    try requireValue(expiredMiniPlayer, "player:paused:\(bookID):0:90000")
    expiredMiniPlayer.tap()
    let contextBanner = expired.descendants(matching: .any)["sleep-resume-context"]
    try requireValue(
      contextBanner,
      "history=52000000-0000-0000-0000-000000000106:book=\(bookID):stop=90000:until=1700020600"
    )
    let contextResume = expired.buttons["resume-sleep-context"]
    XCTAssertTrue(contextResume.isHittable)
    try tester.step(
      "sleep-stop-resume-context",
      description: "Now Playing shows the completed sleep stop and one contextual Resume",
      verifications: [
        .valueEquals(
          expired.otherElements["now-playing-screen"],
          "player:paused:\(bookID):1:90000",
          "Playback remains paused at the engine-acknowledged 90,000 ms stop after relaunch"
        ),
        .valueEquals(
          contextBanner,
          "history=52000000-0000-0000-0000-000000000106:book=\(bookID):stop=90000:until=1700020600",
          "The recent completed stop exposes its exact book, position, and ten-minute availability window"
        ),
        .exists(
          contextResume,
          "A prominent contextual Resume action is available exactly once"
        ),
      ]
    )

    let normalPlayPause = expired.buttons["player-play-pause"]
    normalPlayPause.tap()
    try requireValue(expired.otherElements["now-playing-screen"], "player:playing:\(bookID):1:90000")
    probe = try requireProbe(expired, active: "none", position: 90_000)
    XCTAssertEqual(probe["rewinds"], "0")
    XCTAssertEqual(probe["context"], "52000000-0000-0000-0000-000000000106")
    XCTAssertEqual(probe.journal, "1:pause@70000,2:play@70000,3:seek@85000,4:seek@90000,5:sleepTimer@90000,6:play@90000")
    normalPlayPause.tap()
    _ = try requireProbe(expired, active: "none", position: 90_000)

    contextResume.tap()
    try requireValue(expired.otherElements["now-playing-screen"], "player:playing:\(bookID):1:85000")
    probe = try requireProbe(expired, active: "none", position: 85_000, context: "none")
    XCTAssertEqual(probe["context-used"], "true")
    XCTAssertEqual(probe["rewinds"], "1")
    XCTAssertEqual(
      probe.journal,
      "1:pause@70000,2:play@70000,3:seek@85000,4:seek@90000,5:sleepTimer@90000,6:play@90000,7:pause@90000,8:preResumeRewind@90000,9:resumeRewind@85000,10:play@85000"
    )
    XCTAssertFalse(expired.buttons["resume-sleep-context"].exists)
    tester.generateDocs()
  }

  private func openNowPlaying(_ app: XCUIApplication) throws {
    let miniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    miniPlayer.tap()
    XCTAssertTrue(app.otherElements["now-playing-screen"].waitForExistence(timeout: 2))
  }

  private func openSleepTimer(_ app: XCUIApplication) throws -> XCUIElement {
    let button = app.buttons["open-sleep-timer"]
    XCTAssertTrue(button.waitForExistence(timeout: 2))
    button.tap()
    let screen = app.descendants(matching: .any)["sleep-timer-screen"]
    XCTAssertTrue(screen.waitForExistence(timeout: 2))
    return screen
  }

  private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication) throws {
    let deadline = Date().addingTimeInterval(2)
    while !element.isHittable && Date() < deadline {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
    element.tap()
  }

  private func tapTrailingSwitchControl(_ element: XCUIElement) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
  }

  private func requireProbe(
    _ app: XCUIApplication,
    active: String? = nil,
    historyCount: Int? = nil,
    phase: String? = nil,
    position: Int64? = nil,
    context: String? = nil
  ) throws -> SleepProbe {
    let element = app.descendants(matching: .any)["sleep-timer-state-probe"]
    func matches(_ state: SleepProbe) -> Bool {
      (active == nil || state["active"] == active)
        && (historyCount == nil || state["history"] == String(historyCount!))
        && (phase == nil || state["phase"] == phase)
        && (position == nil || state["position"] == String(position!))
        && (context == nil || state["context"] == context)
    }
    let predicate = NSPredicate { object, _ in
      guard let element = object as? XCUIElement,
        let value = element.value as? String,
        let state = SleepProbe(value)
      else { return false }
      return matches(state)
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    _ = XCTWaiter.wait(for: [expectation], timeout: 2)
    if let value = element.value as? String,
      let state = SleepProbe(value),
      matches(state)
    { return state }
    XCTFail("Sleep timer probe did not reach active=\(active ?? "any") history=\(historyCount.map(String.init) ?? "any") phase=\(phase ?? "any") position=\(position.map(String.init) ?? "any") context=\(context ?? "any"); actual=\(String(describing: element.value))")
    throw SleepTimerUITestError.probeUnavailable
  }

  private func requireValue(
    _ element: XCUIElement,
    _ expected: String,
    timeout: TimeInterval = 2
  ) throws {
    guard element.waitForStringValue(expected, timeout: timeout) else {
      XCTFail("Expected \(element) to expose \(expected); actual=\(String(describing: element.value))")
      throw SleepTimerUITestError.probeUnavailable
    }
  }

  private func requireValueAfterScrolling(
    _ element: XCUIElement,
    _ expected: String,
    in app: XCUIApplication
  ) throws {
    let deadline = Date().addingTimeInterval(2)
    while !element.exists && Date() < deadline {
      app.swipeUp()
    }
    XCTAssertTrue(element.waitForExistence(timeout: 1))
    try requireValue(element, expected)
  }

  private func makeApplication(namespace: String, reset: Bool) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e",
      "-e2e-fixture", "sleep-timer",
      "-e2e-sleep-timer-namespace", namespace,
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

private struct SelectionCase {
  var namespace: String
  var buttonID: String
  var token: String
  var remaining: Int
  var target: Int64?
  var fade: Bool
  var custom = false
}

private struct SleepProbe {
  private var fields: [String: String]
  let journal: String

  init?(_ value: String) {
    let tokens = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard tokens.first == "sleep-timer" else { return nil }
    var parsed: [String: String] = [:]
    for token in tokens.dropFirst() {
      guard let separator = token.firstIndex(of: "=") else { continue }
      parsed[String(token[..<separator])] = String(token[token.index(after: separator)...])
    }
    fields = parsed
    journal = parsed["journal"] ?? ""
  }

  subscript(_ key: String) -> String? { fields[key] }
}

private enum SleepTimerUITestError: Error {
  case probeUnavailable
}
