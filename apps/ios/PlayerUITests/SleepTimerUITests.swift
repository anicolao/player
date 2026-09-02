import XCTest

@MainActor
final class SleepTimerUITests: PlayerUITestCase {
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
      SelectionCase(buttonID: "sleep-timer-preset-10", token: "preset-10", remaining: 600, target: nil, fade: true),
      SelectionCase(buttonID: "sleep-timer-preset-15", token: "preset-15", remaining: 900, target: nil, fade: true),
      SelectionCase(buttonID: "sleep-timer-preset-30", token: "preset-30", remaining: 1_800, target: nil, fade: true),
      SelectionCase(buttonID: "sleep-timer-preset-45", token: "preset-45", remaining: 2_700, target: nil, fade: false),
      SelectionCase(buttonID: "sleep-timer-preset-60", token: "preset-60", remaining: 3_600, target: nil, fade: true),
      SelectionCase(buttonID: "start-custom-sleep-timer", token: "custom-1500", remaining: 1_500, target: nil, fade: true, custom: true),
      SelectionCase(buttonID: "sleep-timer-end-chapter", token: "end-chapter", remaining: 50, target: 120_000, fade: true),
      SelectionCase(buttonID: "sleep-timer-end-track", token: "end-track", remaining: 20, target: 90_000, fade: true),
    ]

    let app = makeApplication(namespace: "all-selections", reset: true)
    app.launch()
    try openNowPlaying(app)
    var currentFade = true
    var previousTimerID: String?

    for (index, selection) in selections.enumerated() {
      _ = try openSleepTimer(app)
      if selection.fade != currentFade {
        let toggle = app.switches["sleep-timer-fade"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        tapTrailingSwitchControl(toggle)
        XCTAssertTrue(
          toggle.waitForStringValue(selection.fade ? "1" : "0", timeout: 2),
          "The production fade toggle must publish its selected state"
        )
        currentFade = selection.fade
      }
      if selection.custom {
        let picker = app.buttons["sleep-timer-custom-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 2))
        picker.tap()
        let options = app.buttons.matching(identifier: "sleep-timer-custom-25")
        let option = options.element
        XCTAssertTrue(option.waitForExistence(timeout: 2))
        XCTAssertEqual(options.count, 1, "The custom-duration option identifier must be unique.")
        option.tap()
      }
      try tapWhenFullyVisible(app.buttons[selection.buttonID], in: app)
      let timerID = sleepTimerID(suffix: index == 0 ? 101 : 100 + (index * 2))
      let probe = try requireProbe(app, active: timerID, historyCount: index)
      XCTAssertEqual(probe["selection"], selection.token)
      XCTAssertEqual(probe["fade"], String(selection.fade))
      XCTAssertEqual(probe["phase"], "active")
      XCTAssertEqual(probe["remaining"], String(selection.remaining))
      XCTAssertEqual(probe["target"], selection.target.map(String.init) ?? "none")
      XCTAssertEqual(probe["history"], String(index))
      XCTAssertEqual(probe["rewinds"], "0")
      XCTAssertEqual(probe["position"], "70000")
      XCTAssertEqual(probe.journal, "1:pause@70000")
      if let previousTimerID {
        XCTAssertEqual(probe["latest"], "replaced")
        XCTAssertEqual(probe["history-id"], sleepTimerID(suffix: 101 + (index * 2)))
        XCTAssertEqual(probe["history-timer"], previousTimerID)
      } else {
        XCTAssertEqual(probe["latest"], "none")
      }
      previousTimerID = timerID
    }
    XCTAssertTrue(terminateAndWait(app))
  }

  private func assertReplacementCancellationAndHistoryPersist() throws {
    let app = makeApplication(namespace: "replace-cancel", reset: true)
    app.launch()
    try openNowPlaying(app)
    _ = try openSleepTimer(app)
    try tapWhenFullyVisible(app.buttons["sleep-timer-preset-10"], in: app)
    _ = try requireProbe(app, active: timer101)

    _ = try openSleepTimer(app)
    try tapWhenFullyVisible(app.buttons["sleep-timer-preset-15"], in: app)
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
    XCTAssertTrue(terminateAndWait(app))

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
    XCTAssertTrue(terminateAndWait(restored))
  }

  private func assertPersistentFadeCompletionAndSingleUseContextResume(
    tester: TestStepHelper
  ) throws {
    let app = makeApplication(namespace: "persistent", reset: true)
    app.launch()
    try openNowPlaying(app)
    _ = try openSleepTimer(app)
    try tapWhenFullyVisible(app.buttons["sleep-timer-end-track"], in: app)
    let started = try requireProbe(app, active: timer101)
    XCTAssertEqual(started["selection"], "end-track")
    XCTAssertEqual(started["remaining"], "20")
    XCTAssertEqual(started["target"], "90000")
    XCTAssertEqual(started["fade"], "true")
    XCTAssertTrue(terminateAndWait(app))

    let restored = makeApplication(namespace: "persistent", reset: false)
    restored.launch()
    let miniPlayer = restored.otherElements["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    try requireValue(
      miniPlayer,
      "player:paused:\(bookID):1:70000|sleep=\(timer101),selection=end-track,remaining=20,fade=true,phase=active"
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
    let cancelSleepTimer = restored.buttons["cancel-sleep-timer"]
    let activeCaptureDeadline = EventDeadline()
    let activeSurface = ScrollSurface(
      application: restored,
      container: activeScreen,
      readiness: restored.descendants(matching: .any)["sleep-timer-scroll-readiness"],
      containerID: "sleep-timer-screen",
      axis: .vertical,
      permitsGeometrySettledFallback: true
    )
    XCTAssertTrue(
      waitForScrollReadiness(
        activeSurface,
        deadline: activeCaptureDeadline,
        matching: { state in
          state.isIdle && elementIsFullyVisible(cancelSleepTimer, within: activeScreen)
        }
      ),
      "The persisted timer and Cancel action must settle fully inside the Sleep Timer viewport"
    )
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
        StepVerification(specification: "The persisted timer remains cancellable") {
          elementIsFullyVisible(cancelSleepTimer, within: activeScreen)
        },
      ],
      captureReadiness: CaptureReadiness(
        specification:
          "At capture, the exact persisted end-of-track timer and Cancel action are idle, fully visible, and free of unrelated transient UI",
        anchor: activeSurface.readiness
      ) {
        guard let state = activeSurface.state() else { return false }
        return state.isIdle
          && activeScreen.exists
          && activeScreen.value.map(String.init(describing:))
            == "sleep-timer:active=\(self.timer101):selection=end-track:remaining=20:target=90000:fade=true:phase=active:history=0"
          && restored.descendants(matching: .any)["active-sleep-timer"].value
            .map(String.init(describing:))
            == "timer=\(self.timer101):selection=end-track:remaining=20:target=90000:fade=true:phase=active"
          && elementIsFullyVisible(cancelSleepTimer, within: activeScreen)
          && !restored.keyboards.firstMatch.exists
          && !restored.alerts.firstMatch.exists
          && !self.hasUnintendedSheet(restored, intendedContentID: "sleep-timer-screen")
      }
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
    XCTAssertTrue(terminateAndWait(restored))

    let expired = makeApplication(namespace: "persistent", reset: false)
    expired.launch()
    let expiredMiniPlayer = expired.otherElements["mini-player"]
    XCTAssertTrue(expiredMiniPlayer.waitForExistence(timeout: 2))
    try requireValue(expiredMiniPlayer, "player:paused:\(bookID):1:90000")
    expiredMiniPlayer.tap()
    let contextBanner = expired.descendants(matching: .any)["sleep-resume-context"]
    try requireValue(
      contextBanner,
      "history=52000000-0000-0000-0000-000000000106:book=\(bookID):stop=90000:until=1700020600"
    )
    let contextResume = expired.buttons["resume-sleep-context"]
    let nowPlayingViewport = expired.otherElements["now-playing-screen"]
    XCTAssertTrue(
      waitForLayoutCondition(
        probe: expired.descendants(matching: .any)["now-playing-layout-readiness"],
        containerID: "now-playing-screen",
        deadline: EventDeadline()
      ) {
        elementIsFullyVisible(
          contextBanner,
          within: nowPlayingViewport,
          requiresHittable: false
        ) && elementIsFullyVisible(contextResume, within: nowPlayingViewport)
      },
      "The completed-stop context and Resume action must settle fully inside Now Playing"
    )
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
        StepVerification(specification: "The completed-stop context is fully visible before capture") {
          elementIsFullyVisible(
            contextBanner,
            within: nowPlayingViewport,
            requiresHittable: false
          )
        },
        StepVerification(specification: "A prominent contextual Resume action is available exactly once") {
          elementIsFullyVisible(contextResume, within: nowPlayingViewport)
        },
      ],
      captureReadiness: CaptureReadiness(
        specification:
          "At capture, the exact paused sleep-stop context and single Resume action have settled in Now Playing with no transient UI",
        anchor: expired.descendants(matching: .any)["now-playing-layout-readiness"]
      ) {
        guard
          let layout = LayoutReadinessState(
            expired.descendants(matching: .any)["now-playing-layout-readiness"].value
          )
        else { return false }
        return layout.containerID == "now-playing-screen"
          && expired.otherElements["now-playing-screen"].value.map(String.init(describing:))
            == "player:paused:\(self.bookID):1:90000"
          && contextBanner.value.map(String.init(describing:))
            == "history=52000000-0000-0000-0000-000000000106:book=\(self.bookID):stop=90000:until=1700020600"
          && elementIsFullyVisible(
            contextBanner, within: nowPlayingViewport, requiresHittable: false
          )
          && elementIsFullyVisible(contextResume, within: nowPlayingViewport)
          && !expired.keyboards.firstMatch.exists
          && !expired.alerts.firstMatch.exists
          && !expired.sheets.firstMatch.exists
      }
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

  private func tapWhenFullyVisible(_ element: XCUIElement, in app: XCUIApplication) throws {
    let screen = app.descendants(matching: .any)["sleep-timer-screen"]
    let deadline = EventDeadline()
    XCTAssertTrue(waitForExistence(screen, deadline: deadline))
    let surface = ScrollSurface(
      application: app,
      container: screen,
      readiness: app.descendants(matching: .any)["sleep-timer-scroll-readiness"],
      containerID: "sleep-timer-screen",
      axis: .vertical,
      permitsGeometrySettledFallback: true
    )
    XCTAssertTrue(
      scrollUntil(
        {
          guard surface.state()?.isIdle == true else { return false }
          return elementIsFullyVisible(
            element,
            within: screen,
            requiresHittable: false
          )
        },
        on: surface,
        deadline: deadline,
        terminalEndpoint: \.atBottom
      ) {
        screen.swipeUp(velocity: .fast)
      },
      "Expected \(element.identifier) to become fully visible through progress-making Sleep Timer scrolling"
    )
    let elementFrame = element.frame
    let screenFrame = screen.frame
    XCTAssertFalse(elementFrame.isEmpty)
    XCTAssertFalse(screenFrame.isEmpty)
    guard !elementFrame.isEmpty, !screenFrame.isEmpty else { return }
    screen.coordinate(withNormalizedOffset: CGVector(
      dx: (elementFrame.midX - screenFrame.minX) / screenFrame.width,
      dy: (elementFrame.midY - screenFrame.minY) / screenFrame.height
    )).tap()
  }

  private func tapTrailingSwitchControl(_ element: XCUIElement) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
  }

  private func hasUnintendedSheet(
    _ app: XCUIApplication,
    intendedContentID: String
  ) -> Bool {
    app.sheets.allElementsBoundByIndex.contains { sheet in
      sheet.identifier != intendedContentID
        && !sheet.descendants(matching: .any)[intendedContentID].exists
    }
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
    let screen = app.descendants(matching: .any)["sleep-timer-screen"]
    XCTAssertTrue(waitForExistence(screen, deadline: EventDeadline()))
    let surface = ScrollSurface(
      application: app,
      container: screen,
      readiness: app.descendants(matching: .any)["sleep-timer-scroll-readiness"],
      containerID: "sleep-timer-screen",
      axis: .vertical,
      permitsGeometrySettledFallback: true
    )
    XCTAssertTrue(
      scrollUntil(
        {
          elementIsFullyVisible(
            element,
            within: screen,
            requiresHittable: false
          )
        },
        on: surface,
        deadline: EventDeadline(),
        terminalEndpoint: \.atBottom
      ) {
        screen.swipeUp(velocity: .fast)
      },
      "Expected \(element.identifier) to become visible through progress-making Sleep Timer scrolling"
    )
    try requireValue(element, expected)
  }

  private func makeApplication(namespace: String, reset: Bool) -> XCUIApplication {
    let app = bookshelfApplication()
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

  private func sleepTimerID(suffix: Int) -> String {
    String(format: "52000000-0000-0000-0000-%012d", suffix)
  }
}

private struct SelectionCase {
  var buttonID: String
  var token: String
  var remaining: Int
  var target: Int64?
  var fade: Bool
  var custom = false
}

private struct SleepProbe {
  private static let baseKeys: Set<String> = [
    "schema", "active", "selection", "fade", "phase", "remaining", "target", "history",
    "latest", "rewinds", "context", "position", "playback", "journal",
  ]
  private static let historyKeys: Set<String> = [
    "history-id", "history-timer", "history-selection", "stop", "event", "context-used",
  ]
  private static let contextKeys: Set<String> = [
    "context-book", "context-stop", "context-until",
  ]
  private static let historyStatuses: Set<String> = ["completed", "cancelled", "replaced"]
  private static let phases: Set<String> = ["active", "fading"]
  private static let playbackStatuses: Set<String> = ["unloaded", "paused", "playing"]
  private static let journalReasons: Set<String> = [
    "play", "periodic", "pause", "seek", "background", "interruption", "routeChange",
    "preResumeRewind", "resumeRewind", "undoResumeRewind", "sleepTimer",
  ]

  private var fields: [String: String]
  let journal: String

  init?(_ value: String) {
    let tokens = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard tokens.first == "sleep-timer" else { return nil }
    var parsed: [String: String] = [:]
    for token in tokens.dropFirst() {
      guard let separator = token.firstIndex(of: "=") else { return nil }
      let key = String(token[..<separator])
      let fieldValue = String(token[token.index(after: separator)...])
      guard !key.isEmpty, (!fieldValue.isEmpty || key == "journal"), parsed[key] == nil else {
        return nil
      }
      parsed[key] = fieldValue
    }
    guard parsed["schema"] == "1",
      let active = parsed["active"], active == "none" || Self.uuid(active),
      let selection = parsed["selection"], Self.selection(selection, permitsNone: true),
      let fade = parsed["fade"], fade == "none" || Self.bool(fade) != nil,
      let phase = parsed["phase"], phase == "none" || Self.phases.contains(phase),
      let remaining = parsed["remaining"], Self.optionalNonnegativeInt(remaining),
      let target = parsed["target"], Self.optionalNonnegativeInt64(target),
      let historyCount = Self.nonnegativeInt(parsed["history"]),
      let latest = parsed["latest"],
      let rewindCount = Self.nonnegativeInt(parsed["rewinds"]),
      let context = parsed["context"], context == "none" || Self.uuid(context),
      Self.nonnegativeInt64(parsed["position"]) != nil,
      let playback = parsed["playback"], Self.playbackStatuses.contains(playback),
      let journal = parsed["journal"], Self.validJournal(journal)
    else { return nil }

    if active == "none" {
      guard selection == "none", fade == "none", phase == "none", remaining == "none",
        target == "none"
      else { return nil }
    } else {
      guard selection != "none", fade != "none", phase != "none",
        remaining != "none" || target != "none"
      else { return nil }
    }

    var expectedKeys = Self.baseKeys
    if historyCount == 0 {
      guard latest == "none" else { return nil }
    } else {
      guard Self.historyStatuses.contains(latest),
        Self.uuid(parsed["history-id"]), Self.uuid(parsed["history-timer"]),
        let historySelection = parsed["history-selection"],
        Self.selection(historySelection, permitsNone: false),
        Self.nonnegativeInt64(parsed["stop"]) != nil,
        parsed["event"] == "none" || Self.uuid(parsed["event"]),
        Self.bool(parsed["context-used"]) != nil
      else { return nil }
      expectedKeys.formUnion(Self.historyKeys)
    }
    if context == "none" {
      guard parsed.keys.allSatisfy({ !Self.contextKeys.contains($0) }) else { return nil }
    } else {
      guard Self.uuid(parsed["context-book"]),
        Self.nonnegativeInt64(parsed["context-stop"]) != nil,
        Self.canonicalInt(parsed["context-until"]) != nil
      else { return nil }
      expectedKeys.formUnion(Self.contextKeys)
    }
    guard !journal.isEmpty || (active == "none" && historyCount == 0 && rewindCount == 0),
      Set(parsed.keys) == expectedKeys
    else { return nil }
    fields = parsed
    self.journal = journal
  }

  subscript(_ key: String) -> String? { fields[key] }

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

  private static func canonicalInt(_ value: String?) -> Int? {
    guard let value, let parsed = Int(value), String(parsed) == value else { return nil }
    return parsed
  }

  private static func optionalNonnegativeInt(_ value: String) -> Bool {
    value == "none" || nonnegativeInt(value) != nil
  }

  private static func optionalNonnegativeInt64(_ value: String) -> Bool {
    value == "none" || nonnegativeInt64(value) != nil
  }

  private static func uuid(_ value: String?) -> Bool {
    guard let value, let parsed = UUID(uuidString: value) else { return false }
    return parsed.uuidString.lowercased() == value
  }

  private static func selection(_ value: String, permitsNone: Bool) -> Bool {
    if permitsNone, value == "none" { return true }
    if ["preset-10", "preset-15", "preset-30", "preset-45", "preset-60", "end-chapter", "end-track"]
      .contains(value)
    { return true }
    guard value.hasPrefix("custom-"),
      let seconds = nonnegativeInt(String(value.dropFirst("custom-".count)))
    else { return false }
    return seconds > 0
  }

  private static func validJournal(_ value: String) -> Bool {
    if value.isEmpty { return true }
    var previousSequence = 0
    for event in value.split(separator: ",", omittingEmptySubsequences: false) {
      let sequenceAndEvent = event.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard sequenceAndEvent.count == 2,
        let sequence = nonnegativeInt(String(sequenceAndEvent[0])), sequence > previousSequence
      else { return false }
      let reasonAndPosition = sequenceAndEvent[1].split(
        separator: "@", maxSplits: 1, omittingEmptySubsequences: false
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

private enum SleepTimerUITestError: Error {
  case probeUnavailable
}
