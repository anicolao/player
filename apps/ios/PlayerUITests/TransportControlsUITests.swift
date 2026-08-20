import XCTest

@MainActor
final class TransportControlsUITests: XCTestCase {
  private let bookID = "30000000-0000-0000-0000-000000000001"

  func testCustomizesAndRestoresListeningControls() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = makeApplication(reset: true)
    app.launch()

    app.tabBars.buttons["Settings"].tap()
    app.buttons["playback-defaults"].tap()
    let preferencesScreen = app.descendants(matching: .any)["transport-preferences-screen"]
    XCTAssertTrue(preferencesScreen.waitForExistence(timeout: 2))
    try requireValue(
      preferencesScreen,
      "transport:scope=global:rate=1.00:back=15:forward=30:seek=chapter"
    )
    choose(app, picker: "transport-rate-picker", option: "1.10×")
    choose(app, picker: "transport-backward-picker", option: "20 seconds")
    choose(app, picker: "transport-forward-picker", option: "45 seconds")
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
    choose(app, picker: "transport-rate-picker", option: "1.25×")
    choose(app, picker: "transport-backward-picker", option: "10 seconds")
    choose(app, picker: "transport-forward-picker", option: "30 seconds")
    app.buttons["Current chapter"].tap()
    try requireValue(
      preferencesScreen,
      "transport:scope=book:rate=1.25:back=10:forward=30:seek=chapter"
    )
    app.buttons["save-transport-preferences"].tap()
    try requireValue(transport, "rate=1.25:back=10:forward=30:seek=chapter:source=book")

    app.terminate()

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

  private func makeApplication(reset: Bool) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "metadata-rich-book",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset { app.launchArguments.insert("-e2e-reset", at: 1) }
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func choose(_ app: XCUIApplication, picker identifier: String, option: String) {
    let picker = app.buttons[identifier]
    XCTAssertTrue(picker.waitForExistence(timeout: 2), "Missing picker \(identifier)")
    picker.tap()
    let choice = app.buttons[option]
    XCTAssertTrue(choice.waitForExistence(timeout: 2), "Missing picker option \(option)")
    choice.tap()
  }

  private func requireValue(
    _ element: XCUIElement,
    _ expected: String,
    timeout: TimeInterval = 2
  ) throws {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", expected),
      object: element
    )
    guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
      XCTFail("Expected \(element) to expose \(expected); actual=\(element.value ?? "nil")")
      throw TransportControlsTestError.valueUnavailable
    }
  }
}

private enum TransportControlsTestError: Error {
  case valueUnavailable
}
