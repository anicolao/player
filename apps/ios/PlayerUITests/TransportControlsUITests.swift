import XCTest

@MainActor
final class TransportControlsUITests: XCTestCase {
  private let bookID = "30000000-0000-0000-0000-000000000001"

  func testCustomizesAndRestoresListeningControls() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = makeApplication(reset: true, startInSettings: true)
    app.launch()

    let globalPreferences = app.buttons["playback-defaults"]
    XCTAssertTrue(globalPreferences.waitForExistence(timeout: 2))
    globalPreferences.tap()
    let preferencesScreen = app.descendants(matching: .any)["transport-preferences-screen"]
    XCTAssertTrue(preferencesScreen.waitForExistence(timeout: 2))
    try requireValue(
      preferencesScreen,
      "transport:scope=global:rate=1.00:back=15:forward=30:seek=chapter"
    )
    try choose(
      app, picker: "transport-rate-picker", option: "1.10×", preferences: preferencesScreen,
      expected: "transport:scope=global:rate=1.10:back=15:forward=30:seek=chapter"
    )
    try choose(
      app, picker: "transport-backward-picker", option: "20 seconds",
      preferences: preferencesScreen,
      expected: "transport:scope=global:rate=1.10:back=20:forward=30:seek=chapter"
    )
    try choose(
      app, picker: "transport-forward-picker", option: "45 seconds",
      preferences: preferencesScreen,
      expected: "transport:scope=global:rate=1.10:back=20:forward=45:seek=chapter"
    )
    app.buttons["Whole book"].tap()
    try requireValue(
      preferencesScreen,
      "transport:scope=global:rate=1.10:back=20:forward=45:seek=whole-book"
    )
    app.buttons["save-transport-preferences"].tap()

    app.tabBars.buttons["Library"].tap()
    XCTAssertTrue(app.staticTexts["Harbor at Dawn"].waitForExistence(timeout: 2))
    app.staticTexts["Harbor at Dawn"].tap()
    XCTAssertTrue(app.buttons["chapter-2"].waitForExistence(timeout: 2))
    app.buttons["chapter-2"].tap()
    XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 2))
    app.buttons["player-play-pause"].tap()

    let nowPlaying = app.otherElements["now-playing-screen"]
    let transport = app.buttons["open-transport-preferences"]
    try requireValue(transport, "rate=1.10:back=20:forward=45:seek=whole-book:source=global")
    app.buttons["player-next-chapter"].tap()
    try requireValue(nowPlaying, "player:paused:\(bookID):2:75000")
    app.buttons["player-previous-chapter"].tap()
    try requireValue(nowPlaying, "player:paused:\(bookID):1:30000")
    app.buttons["player-skip-forward"].tap()
    try requireValue(nowPlaying, "player:paused:\(bookID):2:75000")
    app.buttons["player-skip-backward"].tap()
    try requireValue(nowPlaying, "player:paused:\(bookID):1:55000")

    transport.tap()
    XCTAssertTrue(preferencesScreen.waitForExistence(timeout: 2))
    try choose(
      app, picker: "transport-rate-picker", option: "1.25×", preferences: preferencesScreen,
      expected: "transport:scope=book:rate=1.25:back=20:forward=45:seek=whole-book"
    )
    try choose(
      app, picker: "transport-backward-picker", option: "10 seconds",
      preferences: preferencesScreen,
      expected: "transport:scope=book:rate=1.25:back=10:forward=45:seek=whole-book"
    )
    try choose(
      app, picker: "transport-forward-picker", option: "30 seconds",
      preferences: preferencesScreen,
      expected: "transport:scope=book:rate=1.25:back=10:forward=30:seek=whole-book"
    )
    app.buttons["Current chapter"].tap()
    try requireValue(
      preferencesScreen,
      "transport:scope=book:rate=1.25:back=10:forward=30:seek=chapter"
    )
    app.buttons["save-transport-preferences"].tap()
    try requireValue(transport, "rate=1.25:back=10:forward=30:seek=chapter:source=book")

    XCTAssertTrue(terminateAndWait(app))

    let restored = makeApplication(reset: false)
    restored.launch()
    let miniPlayer = restored.descendants(matching: .any)["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    miniPlayer.tap()
    let restoredTransport = restored.buttons["open-transport-preferences"]
    try requireValue(
      restoredTransport,
      "rate=1.25:back=10:forward=30:seek=chapter:source=book"
    )
    try requireValue(
      restored.otherElements["now-playing-screen"],
      "player:paused:\(bookID):1:55000"
    )

    let tester = TestStepHelper(testCase: self, startIndex: 2)
    tester.setMetadata(
      title: "Listening controls follow durable global and per-book preferences",
      narrative:
        "As a listener, I want chapter navigation, configurable skips, speed, and scrubber context to stay tailored to each audiobook.",
      fixture: "metadata-rich-book",
      additionalPreconditions: [
        "The fixture contains one deterministic 120-second book with three chapters",
        "The deterministic playback engine acknowledges every transport seek without advancing wall-clock time",
        "The first launch writes library defaults and a complete per-book override through production persistence",
        "The second launch reuses the same durable store and managed media",
      ]
    )
    try tester.step(
      "transport-controls",
      description: "Now Playing restores the custom speed, skips, chapter scrubber, and position",
      verifications: [
        .valueEquals(
          restoredTransport,
          "rate=1.25:back=10:forward=30:seek=chapter:source=book",
          "The complete per-book override survived termination"
        ),
        .valueEquals(
          restored.otherElements["now-playing-screen"],
          "player:paused:\(bookID):1:55000",
          "The configured skip result restored at the acknowledged book position"
        ),
        .exists(restored.buttons["player-previous-chapter"], "Previous chapter is available"),
        .exists(restored.buttons["player-next-chapter"], "Next chapter is available"),
        .exists(restored.buttons["player-skip-backward"], "The custom backward skip is available"),
        .exists(restored.buttons["player-skip-forward"], "The custom forward skip is available"),
        .exists(restored.sliders["player-position-slider"], "The chapter scrubber is available"),
      ]
    )
    tester.generateDocs()
  }

  private func makeApplication(
    reset: Bool,
    startInSettings: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "metadata-rich-book",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset { app.launchArguments.insert("-e2e-reset", at: 1) }
    if startInSettings {
      app.launchArguments.append(contentsOf: ["-e2e-start-section", "settings"])
    }
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func choose(
    _ app: XCUIApplication,
    picker identifier: String,
    option: String,
    preferences: XCUIElement,
    expected: String
  ) throws {
    let deadline = EventDeadline()
    let pickers = app.buttons.matching(identifier: identifier)
    let picker = pickers.element
    XCTAssertTrue(waitForExistence(picker, deadline: deadline), "Missing picker \(identifier)")
    XCTAssertEqual(pickers.count, 1, "Picker \(identifier) must be unique")
    picker.tap()
    let choices = app.buttons.matching(NSPredicate(format: "label == %@", option))
    let choice = choices.element
    XCTAssertTrue(waitForExistence(choice, deadline: deadline), "Missing picker option \(option)")
    XCTAssertEqual(choices.count, 1, "Picker option \(option) must be unique")
    choice.tap()
    XCTAssertTrue(
      choice.waitForNonExistence(timeout: deadline.remaining),
      "Picker option \(option) must disappear after selection"
    )
    guard preferences.waitForStringValue(expected, timeout: deadline.remaining) else {
      XCTFail("Picker \(identifier) did not publish \(expected); actual=\(preferences.value ?? "nil")")
      throw TransportControlsTestError.valueUnavailable
    }
  }

  private func requireValue(
    _ element: XCUIElement,
    _ expected: String,
    timeout: TimeInterval = 2
  ) throws {
    guard element.waitForStringValue(expected, timeout: timeout) else {
      XCTFail("Expected \(element) to expose \(expected); actual=\(element.value ?? "nil")")
      throw TransportControlsTestError.valueUnavailable
    }
  }
}

private enum TransportControlsTestError: Error {
  case valueUnavailable
}
