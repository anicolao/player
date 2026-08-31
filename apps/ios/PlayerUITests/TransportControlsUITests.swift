import XCTest

@MainActor
final class TransportControlsUITests: PlayerUITestCase {
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
    let restoredNowPlaying = restored.otherElements["now-playing-screen"]
    let layoutReadiness = restored.descendants(matching: .any)["now-playing-layout-readiness"]
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
          restoredNowPlaying,
          "player:paused:\(bookID):1:55000",
          "The configured skip result restored at the acknowledged book position"
        ),
        .exists(restored.buttons["player-previous-chapter"], "Previous chapter is available"),
        .exists(restored.buttons["player-next-chapter"], "Next chapter is available"),
        .exists(restored.buttons["player-skip-backward"], "The custom backward skip is available"),
        .exists(restored.buttons["player-skip-forward"], "The custom forward skip is available"),
        .exists(restored.sliders["player-position-slider"], "The chapter scrubber is available"),
      ],
      captureReadiness: CaptureReadiness(
        specification:
          "At capture, the durable per-book transport override and exact paused position are rendered with decoded artwork, settled geometry, and no transient UI",
        anchor: layoutReadiness
      ) {
        guard let layout = LayoutReadinessState(layoutReadiness.value) else { return false }
        return layout.containerID == "now-playing-screen"
          && restoredNowPlaying.exists
          && restoredNowPlaying.value.map(String.init(describing:))
            == "player:paused:\(self.bookID):1:55000"
          && restoredTransport.exists
          && restoredTransport.value.map(String.init(describing:))
            == "rate=1.25:back=10:forward=30:seek=chapter:source=book"
          && elementIsFullyVisible(
            restoredNowPlaying.descendants(matching: .any)["embedded-cover-artwork"],
            within: restoredNowPlaying,
            requiresHittable: false
          )
          && elementIsFullyVisible(
            restored.sliders["player-position-slider"], within: restoredNowPlaying
          )
          && elementIsFullyVisible(
            restored.buttons["player-play-pause"], within: restoredNowPlaying
          )
          && elementIsFullyVisible(restoredTransport, within: restoredNowPlaying)
          && !restored.keyboards.firstMatch.exists
          && !restored.alerts.firstMatch.exists
          && !restored.sheets.firstMatch.exists
      }
    )
    tester.generateDocs()
  }

  func testUsesCurrentLibraryDefaultsAcrossPlaybackRemoteControlsAndRelaunch() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let namespace = "transport-use-library-defaults"

    var app = makeApplication(reset: true, namespace: namespace)
    app.launch()
    try createPerBookOverride(in: app)
    XCTAssertTrue(terminateAndWait(app))

    app = makeApplication(reset: false, startInSettings: true, namespace: namespace)
    app.launch()
    try changeLibraryDefaults(in: app)
    XCTAssertTrue(terminateAndWait(app))

    app = makeApplication(reset: false, namespace: namespace, eventControls: true)
    app.launch()
    let miniPlayer = app.descendants(matching: .any)["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    miniPlayer.tap()
    let nowPlaying = app.otherElements["now-playing-screen"]
    let transport = app.buttons["open-transport-preferences"]
    try requireValue(nowPlaying, "player:paused:\(bookID):1:30000")
    try requireValue(transport, "rate=1.25:back=10:forward=30:seek=chapter:source=book")

    transport.tap()
    let preferences = app.descendants(matching: .any)["transport-preferences-screen"]
    try requireValue(
      preferences,
      "transport:scope=book:rate=1.25:back=10:forward=30:seek=chapter"
    )
    app.buttons["transport-use-library-defaults"].tap()
    XCTAssertTrue(preferences.waitForNonExistence(timeout: 2))
    try requireValue(transport, "rate=1.50:back=15:forward=45:seek=whole-book:source=global")

    let slider = app.sliders["player-position-slider"]
    XCTAssertTrue(slider.waitForExistence(timeout: 2))
    XCTAssertTrue(
      adjustSliderAcknowledged(
        slider,
        toNormalizedPosition: 0.5,
        in: app,
        receipt: nowPlaying,
        satisfies: NSPredicate(
          format: "value == %@",
          "player:paused:\(bookID):1:60000"
        )
      ),
      "The position slider must publish its exact playback receipt"
    )
    try requireValue(nowPlaying, "player:paused:\(bookID):1:60000")
    app.buttons["player-skip-forward"].tap()
    try requireValue(nowPlaying, "player:paused:\(bookID):2:105000")
    app.buttons["player-skip-backward"].tap()
    try requireValue(nowPlaying, "player:paused:\(bookID):2:90000")

    let closeNowPlaying = app.buttons["close-now-playing"]
    XCTAssertTrue(closeNowPlaying.waitForExistence(timeout: 2))
    XCTAssertTrue(
      waitForPredicate(NSPredicate(format: "hittable == true"), on: closeNowPlaying)
    )
    closeNowPlaying.tap()
    let configuration = app.otherElements["e2e-transport-configuration-probe"]
    try requireValue(
      configuration,
      "transport|rate=1.50|engine=1.50|back=15|forward=45|remote-back=15|remote-forward=45|seek=whole-book|source=global"
    )
    app.buttons["e2e-remote-previous-track"].tap()
    try requireValue(miniPlayer, "player:paused:\(bookID):2:75000")
    app.buttons["e2e-remote-next-track"].tap()
    try requireValue(miniPlayer, "player:paused:\(bookID):2:120000")
    XCTAssertTrue(terminateAndWait(app))

    let restored = makeApplication(
      reset: false,
      namespace: namespace,
      eventControls: true
    )
    restored.launch()
    let restoredMiniPlayer = restored.descendants(matching: .any)["mini-player"]
    try requireValue(restoredMiniPlayer, "player:paused:\(bookID):2:120000")
    restoredMiniPlayer.tap()
    let restoredTransport = restored.buttons["open-transport-preferences"]
    try requireValue(
      restoredTransport,
      "rate=1.50:back=15:forward=45:seek=whole-book:source=global"
    )
    restoredTransport.tap()
    let restoredPreferences = restored.descendants(matching: .any)[
      "transport-preferences-screen"
    ]
    try requireValue(
      restoredPreferences,
      "transport:scope=global:rate=1.50:back=15:forward=45:seek=whole-book"
    )
    XCTAssertFalse(restored.buttons["transport-use-library-defaults"].exists)
  }

  func testFailedLibraryDefaultsClearKeepsEditorAndOverrideTruthful() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let namespace = "transport-use-library-defaults-failure"

    var app = makeApplication(reset: true, namespace: namespace)
    app.launch()
    try createPerBookOverride(in: app)
    XCTAssertTrue(terminateAndWait(app))

    app = makeApplication(
      reset: false,
      namespace: namespace,
      failsTransportOverrideClear: true
    )
    app.launch()
    let miniPlayer = app.descendants(matching: .any)["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    miniPlayer.tap()
    let transport = app.buttons["open-transport-preferences"]
    try requireValue(transport, "rate=1.25:back=10:forward=30:seek=chapter:source=book")
    transport.tap()
    let preferences = app.descendants(matching: .any)["transport-preferences-screen"]
    try requireValue(
      preferences,
      "transport:scope=book:rate=1.25:back=10:forward=30:seek=chapter"
    )

    app.buttons["transport-use-library-defaults"].tap()
    let failure = app.alerts["Couldn’t Save Playback Settings"]
    XCTAssertTrue(failure.waitForExistence(timeout: 2))
    let expectedMessage =
      "Bookshelf couldn’t save these playback settings. Check that your device has free space, then try again. Your current settings are unchanged."
    XCTAssertTrue(
      failure.staticTexts.matching(NSPredicate(format: "label == %@", expectedMessage))
        .firstMatch.exists
    )
    XCTAssertTrue(preferences.exists, "A failed clear must not dismiss the production editor")
    failure.buttons["OK"].tap()
    try requireValue(
      preferences,
      "transport:scope=book:rate=1.25:back=10:forward=30:seek=chapter"
    )
    XCTAssertTrue(app.buttons["transport-use-library-defaults"].exists)
    app.buttons["Cancel"].tap()
    XCTAssertTrue(preferences.waitForNonExistence(timeout: 2))
    try requireValue(transport, "rate=1.25:back=10:forward=30:seek=chapter:source=book")
    XCTAssertTrue(terminateAndWait(app))

    let restored = makeApplication(reset: false, namespace: namespace)
    restored.launch()
    let restoredMiniPlayer = restored.descendants(matching: .any)["mini-player"]
    XCTAssertTrue(restoredMiniPlayer.waitForExistence(timeout: 2))
    restoredMiniPlayer.tap()
    try requireValue(
      restored.buttons["open-transport-preferences"],
      "rate=1.25:back=10:forward=30:seek=chapter:source=book"
    )
  }

  private func makeApplication(
    reset: Bool,
    startInSettings: Bool = false,
    namespace: String = "transport-controls-persistence",
    eventControls: Bool = false,
    failsTransportOverrideClear: Bool = false
  ) -> XCUIApplication {
    let app = bookshelfApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "metadata-rich-book",
      "-e2e-metadata-rich-namespace", namespace,
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset { app.launchArguments.insert("-e2e-reset", at: 1) }
    if eventControls { app.launchArguments.append("-e2e-event-controls") }
    if failsTransportOverrideClear {
      app.launchArguments.append("-e2e-transport-clear-failure")
    }
    if startInSettings {
      app.launchArguments.append(contentsOf: ["-e2e-start-section", "settings"])
    }
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func createPerBookOverride(in app: XCUIApplication) throws {
    XCTAssertTrue(app.staticTexts["Harbor at Dawn"].waitForExistence(timeout: 2))
    app.staticTexts["Harbor at Dawn"].tap()
    XCTAssertTrue(app.buttons["chapter-2"].waitForExistence(timeout: 2))
    app.buttons["chapter-2"].tap()
    XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 2))
    app.buttons["player-play-pause"].tap()
    let nowPlaying = app.otherElements["now-playing-screen"]
    try requireValue(nowPlaying, "player:paused:\(bookID):1:30000")

    let transport = app.buttons["open-transport-preferences"]
    transport.tap()
    let preferences = app.descendants(matching: .any)["transport-preferences-screen"]
    XCTAssertTrue(preferences.waitForExistence(timeout: 2))
    try choose(
      app,
      picker: "transport-rate-picker",
      option: "1.25×",
      preferences: preferences,
      expected: "transport:scope=book:rate=1.25:back=15:forward=30:seek=chapter"
    )
    try choose(
      app,
      picker: "transport-backward-picker",
      option: "10 seconds",
      preferences: preferences,
      expected: "transport:scope=book:rate=1.25:back=10:forward=30:seek=chapter"
    )
    app.buttons["save-transport-preferences"].tap()
    try requireValue(transport, "rate=1.25:back=10:forward=30:seek=chapter:source=book")
  }

  private func changeLibraryDefaults(in app: XCUIApplication) throws {
    let globalPreferences = app.buttons["playback-defaults"]
    XCTAssertTrue(globalPreferences.waitForExistence(timeout: 2))
    globalPreferences.tap()
    let preferences = app.descendants(matching: .any)["transport-preferences-screen"]
    XCTAssertTrue(preferences.waitForExistence(timeout: 2))
    try choose(
      app,
      picker: "transport-rate-picker",
      option: "1.50×",
      preferences: preferences,
      expected: "transport:scope=global:rate=1.50:back=15:forward=30:seek=chapter"
    )
    try choose(
      app,
      picker: "transport-forward-picker",
      option: "45 seconds",
      preferences: preferences,
      expected: "transport:scope=global:rate=1.50:back=15:forward=45:seek=chapter"
    )
    app.buttons["Whole book"].tap()
    try requireValue(
      preferences,
      "transport:scope=global:rate=1.50:back=15:forward=45:seek=whole-book"
    )
    app.buttons["save-transport-preferences"].tap()
    XCTAssertTrue(preferences.waitForNonExistence(timeout: 2))
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
