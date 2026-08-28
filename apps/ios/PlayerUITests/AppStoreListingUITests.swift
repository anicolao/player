import XCTest

@MainActor
final class AppStoreListingUITests: XCTestCase {
  func testCapturesCanonicalMarketingSurfaces() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "App Store and website marketing surfaces stay current",
      narrative:
        "As a prospective listener, I want the product page to show the real library, import, playback, and purchase experience.",
      fixture: "marketing-surfaces",
      additionalPreconditions: [
        "Every image uses fixed synthetic audiobook metadata and artwork.",
        "Harbor at Dawn uses committed, generated fictional cover artwork made for this marketing fixture.",
        "The listing and website build scripts consume the fresh ActualWalkthrough output from this story.",
        "No marketing screenshot is maintained as a second copied source file.",
      ]
    )

    let library = try makePopulatedLibraryApplication()
    library.launch()
    try tester.step(
      "library",
      description: "The library gives owned audiobooks a warm, useful home",
      verifications: [
        .exists(library.otherElements["library-screen"], "The Library screen is visible"),
        .exists(library.staticTexts["Continue Listening"], "Listening progress is immediately useful"),
        .exists(library.staticTexts["Recently Added"], "Recent cover artwork is visible"),
        .exists(library.otherElements["mini-player"], "The current book stays within reach"),
      ]
    )
    XCTAssertTrue(terminateAndWait(library))

    let receiver = makeApplication(
      fixture: "empty-library",
      extraArguments: ["-e2e-computer-receiver-ready", "-e2e-show-mirroring-tip"]
    )
    receiver.launch()
    receiver.buttons["receive-from-computer-empty-library"].tap()
    try tester.step(
      "receiver-ready",
      description: "The private receiver accepts books through a browser on any computer",
      verifications: [
        .valueEquals(receiver.scrollViews["computer-receiver-screen"], "receiver:ready", "The receiver is ready"),
        .exists(receiver.staticTexts["computer-receiver-pairing-code"], "The pairing code is visible"),
        .exists(receiver.buttons["choose-from-files-computer-receiver"], "Files remains available"),
      ]
    )
    XCTAssertTrue(terminateAndWait(receiver))

    let progress = makeApplication(
      fixture: "empty-library",
      extraArguments: [
        "-e2e-computer-receiver-ready", "-e2e-show-mirroring-tip",
        "-e2e-mirroring-drop-progress",
      ]
    )
    progress.launch()
    progress.buttons["receive-from-computer-empty-library"].tap()
    try tester.step(
      "mirroring-drop-progress",
      description: "iPhone Mirroring makes Finder drag-and-drop the fastest Mac path",
      verifications: [
        .valueEquals(progress.scrollViews["computer-receiver-screen"], "receiver:preparing-mirrored-drop", "The mirrored drop is being prepared"),
        .exists(progress.progressIndicators["mirroring-drop-progress"], "Import progress is visible"),
        .exists(progress.staticTexts["Project Hail Mary"], "The incoming audiobook is named"),
      ]
    )
    XCTAssertTrue(terminateAndWait(progress))

    let playback = makeApplication(
      fixture: "metadata-rich-book",
      extraArguments: [
        "-e2e-metadata-rich-namespace", "app-store-listing-playback",
        "-e2e-start-section", "settings",
      ]
    )
    playback.launchEnvironment["PLAYER_E2E_METADATA_RICH_COVER_BASE64"] = try fixtureData(
      resource: "harbor-at-dawn-cover", extension: "png"
    ).base64EncodedString()
    playback.launch()
    let playbackDefaults = playback.buttons["playback-defaults"]
    XCTAssertTrue(playbackDefaults.waitForExistence(timeout: 2))
    playbackDefaults.tap()
    let preferences = anyElement(playback, "transport-preferences-screen")
    XCTAssertTrue(preferences.waitForExistence(timeout: 2))
    try choose(
      playback, picker: "transport-rate-picker", option: "1.25×", preferences: preferences,
      expected: "transport:scope=global:rate=1.25:back=15:forward=30:seek=chapter"
    )
    try choose(
      playback, picker: "transport-backward-picker", option: "10 seconds",
      preferences: preferences,
      expected: "transport:scope=global:rate=1.25:back=10:forward=30:seek=chapter"
    )
    try choose(
      playback, picker: "transport-forward-picker", option: "45 seconds",
      preferences: preferences,
      expected: "transport:scope=global:rate=1.25:back=10:forward=45:seek=chapter"
    )
    try choose(
      playback, picker: "transport-forward-picker", option: "30 seconds",
      preferences: preferences,
      expected: "transport:scope=global:rate=1.25:back=10:forward=30:seek=chapter"
    )
    try tester.step(
      "playback-settings",
      description: "Playback defaults make speed, skips, and seeking personal",
      verifications: [
        .valueEquals(preferences, "transport:scope=global:rate=1.25:back=10:forward=30:seek=chapter", "The chosen defaults are visible"),
        .exists(playback.buttons["transport-rate-picker"], "Playback speed is configurable"),
        .exists(playback.buttons["transport-backward-picker"], "Backward skip is configurable"),
        .exists(playback.buttons["transport-forward-picker"], "Forward skip is configurable"),
      ]
    )
    playback.buttons["save-transport-preferences"].tap()
    playback.tabBars.buttons["Library"].tap()
    playback.staticTexts["Harbor at Dawn"].tap()
    XCTAssertTrue(playback.buttons["chapter-2"].waitForExistence(timeout: 2))
    playback.buttons["chapter-2"].tap()
    try tester.step(
      "now-playing",
      description: "Now Playing keeps chapters and custom controls close",
      verifications: [
        .exists(playback.otherElements["now-playing-screen"], "Now Playing is visible"),
        .exists(playback.buttons["player-previous-chapter"], "Previous chapter is available"),
        .exists(playback.buttons["player-next-chapter"], "Next chapter is available"),
        .exists(playback.buttons["open-transport-preferences"], "Playback settings remain close"),
      ]
    )
    playback.buttons["open-sleep-timer"].tap()
    try tester.step(
      "sleep-timer",
      description: "The sleep timer adapts to minutes, chapters, or tracks",
      verifications: [
        .exists(anyElement(playback, "sleep-timer-screen"), "The Sleep Timer screen is visible"),
        .exists(playback.buttons["sleep-timer-preset-30"], "A 30-minute preset is available"),
        .exists(playback.buttons["sleep-timer-end-chapter"], "End of chapter is available"),
        .exists(playback.switches["sleep-timer-fade"], "Gentle fade is configurable"),
      ]
    )
    XCTAssertTrue(terminateAndWait(playback))

    let unlock = makeApplication(
      fixture: "monetization-exhausted",
      extraArguments: [
        "-e2e-start-section", "settings",
        "-e2e-start-settings-route", "full-unlock",
      ]
    )
    unlock.launch()
    try tester.step(
      "full-unlock",
      description: "The one-time Full Unlock is clear and subscription-free",
      verifications: [
        .exists(unlock.scrollViews["full-unlock-screen"], "The Full Unlock screen is visible"),
        .exists(unlock.buttons["full-unlock-purchase"], "The one-time purchase is available"),
        .exists(unlock.staticTexts["One-time purchase · No subscription"], "The purchase model is explicit"),
        .exists(unlock.buttons["full-unlock-restore"], "Purchase restoration is available"),
      ]
    )
    XCTAssertTrue(terminateAndWait(unlock))

    tester.generateDocs()
  }

  private func makeApplication(
    fixture: String,
    extraArguments: [String] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-reset", "-e2e-fixture", fixture,
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ] + extraArguments
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func makePopulatedLibraryApplication() throws -> XCUIApplication {
    let app = makeApplication(
      fixture: "synthetic-populated-library",
      extraArguments: ["-e2e-computer-receiver-ready"]
    )
    app.launchEnvironment["PLAYER_E2E_LIBRARY_DESCRIPTOR_BASE64"] = try fixtureData(
      resource: "synthetic-populated-library-fixture", extension: "json"
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_LIBRARY_AUDIO_BASE64"] = try fixtureData(
      resource: "library-book-audio", extension: "m4b"
    ).base64EncodedString()
    for index in 1...5 {
      app.launchEnvironment["PLAYER_E2E_LIBRARY_COVER_B\(index)_BASE64"] = try fixtureData(
        resource: "library-cover-b\(index)", extension: "png"
      ).base64EncodedString()
    }
    return app
  }

  private func fixtureData(resource: String, extension fileExtension: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: resource, withExtension: fileExtension)
    )
    return try Data(contentsOf: url)
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
    XCTAssertTrue(waitForExistence(picker, deadline: deadline))
    XCTAssertEqual(pickers.count, 1, "Picker \(identifier) must be unique")
    picker.tap()
    let choices = app.buttons.matching(NSPredicate(format: "label == %@", option))
    let choice = choices.element
    XCTAssertTrue(waitForExistence(choice, deadline: deadline))
    XCTAssertEqual(choices.count, 1, "Picker option \(option) must be unique")
    choice.tap()
    guard preferences.waitForStringValue(expected, timeout: deadline.remaining) else {
      XCTFail("Picker \(identifier) did not publish \(expected); actual=\(preferences.value ?? "nil")")
      throw AppStoreListingTestError.valueUnavailable
    }
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }
}

private enum AppStoreListingTestError: Error {
  case valueUnavailable
}
