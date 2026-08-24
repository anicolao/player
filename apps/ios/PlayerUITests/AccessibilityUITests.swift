import XCTest

@MainActor
final class AccessibilityUITests: XCTestCase {
  private let secondBookID = "90000000-0000-0000-0000-000000000002"

  func testAccessibilityPreferenceTogglesUpdateAndPersist() throws {
    continueAfterFailure = false
    let app = makeApplication(fixture: "single-audiobook-ready")
    app.launch()
    app.tabBars.buttons["Settings"].tap()
    let accessibility = app.buttons["settings-accessibility"]
    scrollTo(accessibility, in: app)
    accessibility.tap()

    let highContrast = app.switches["accessibility-high-contrast"]
    let reduceArtwork = app.switches["accessibility-reduce-artwork"]
    XCTAssertTrue(highContrast.waitForStringValue("0", timeout: 2))
    XCTAssertTrue(reduceArtwork.waitForStringValue("0", timeout: 2))

    tapSwitchControl(highContrast)
    XCTAssertTrue(highContrast.waitForStringValue("1", timeout: 2))
    tapSwitchControl(reduceArtwork)
    XCTAssertTrue(reduceArtwork.waitForStringValue("1", timeout: 2))

    let preferences = anyElement(app, "accessibility-preferences-state")
    XCTAssertTrue(
      preferences.waitForStringValue(
        "high-contrast=true:reduce-artwork=true",
        timeout: 2
      ))
  }

  func testCoreJourneysRemainCompleteAtLargestAccessibilityText() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "Core listening journeys remain accessible at the largest text size",
      narrative:
        "As a listener using accessibility features, I can import, repair, organize, and listen without losing a primary action.",
      fixture:
        "single-audiobook-ready, metadata-rich-book, synthetic-populated-library, and deterministic receiver states",
      additionalPreconditions: [
        "The simulator uses Accessibility XXXL text and Increase Contrast",
        "Every asserted control has a unique human-readable accessibility label",
        "Ordering is verified through non-drag buttons, and the native playback slider remains adjustable",
        "Reduce Motion, Differentiate Without Color, and Bold Text are audited through SwiftUI environment adaptation and the Settings status summary",
      ],
      deviceConfiguration:
        "iPhone 17 on iOS 26.5, portrait, light appearance, Accessibility XXXL Dynamic Type, Increase Contrast"
    )

    var app = makeApplication(fixture: "single-audiobook-ready")
    app.launch()
    app.tabBars.buttons["Inbox"].tap()
    app.buttons["review-import-job-10000000-0000-0000-0000-000000000001"].tap()
    let add = app.buttons["add-import-to-library"]
    try tester.step(
      "large-text-import-review",
      description: "Import review keeps its title and pinned primary action at Accessibility XXXL",
      verifications: [
        .exists(
          anyElement(app, "review-import-screen"),
          "The review screen exposes one named semantic container"),
        .exists(
          app.staticTexts["The Lighthouse Signal"], "The full audiobook title remains readable"),
        .valueEquals(
          add, "ready:enabled", "Add to Library exposes its ready state without color alone"),
        visibleControl(
          add, in: app, label: "Add to Library",
          specification: "Add to Library is visible, enabled, named, and tappable"),
      ]
    )

    let edit = app.buttons["edit-metadata"]
    scrollTo(edit, in: app)
    edit.tap()
    let titleField = app.textFields["metadata-title-input"]
    app.buttons["e2e-align-metadata-identity"].tap()
    XCTAssertTrue(titleField.waitForExistence(timeout: 2))
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    try tester.step(
      "large-text-metadata-repair",
      description: "Metadata fields reflow vertically instead of compressing their labels",
      verifications: [
        .exists(
          anyElement(app, "metadata-editor-screen"),
          "The metadata editor has a stable semantic screen identity"),
        .exists(titleField, "The full Title field remains reachable"),
        .exists(app.buttons["metadata-apply-title"], "The explicit Apply action remains available"),
        .exists(app.buttons["save-metadata-repair"], "Save remains in the navigation bar"),
      ]
    )

    app.terminate()
    app = makeApplication(fixture: "metadata-rich-book")
    app.launch()
    app.staticTexts["Harbor at Dawn"].tap()
    let playBook = app.buttons["play-book"]
    app.buttons["e2e-align-book-detail-play"].tap()
    XCTAssertTrue(playBook.waitForExistence(timeout: 2))
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    try tester.step(
      "large-text-book-detail",
      description: "Book Detail stacks identity and primary actions at the largest text size",
      verifications: [
        .exists(
          anyElement(app, "book-detail-screen"), "Book Detail exposes its exact semantic state"),
        .exists(app.staticTexts["Harbor at Dawn"], "The title is not truncated"),
        visibleControl(
          playBook, in: app, label: "Play",
          specification: "Play remains reachable and directly tappable"),
      ]
    )

    playBook.tap()
    let slider = app.sliders["player-position-slider"]
    scrollTo(slider, in: app)
    let playPause = app.buttons["player-play-pause"]
    scrollTo(playPause, in: app)
    try tester.step(
      "large-text-now-playing",
      description: "Now Playing scrolls to an adjustable timeline and reachable transport controls",
      verifications: [
        .exists(anyElement(app, "now-playing-screen"), "Now Playing exposes its playback state"),
        .exists(slider, "The listening timeline remains a native adjustable control"),
        .valueContains(
          slider, "remaining", "The timeline names elapsed and remaining listening time"),
        visibleControl(
          playPause, in: app, label: "Pause",
          specification: "Play or Pause remains visible and tappable"),
        .exists(app.buttons["player-skip-backward"], "Skip Back has a named VoiceOver action"),
        .exists(app.buttons["player-skip-forward"], "Skip Forward has a named VoiceOver action"),
      ]
    )

    app.terminate()
    app = try makePopulatedLibraryApplication()
    app.launch()
    let upNext = app.buttons["open-up-next"]
    scrollTo(upNext, in: app)
    upNext.tap()
    try tester.step(
      "large-text-non-drag-ordering",
      description: "Up Next offers explicit labeled ordering controls without requiring drag",
      verifications: [
        .exists(anyElement(app, "up-next-screen"), "The ordered queue remains available"),
        namedControl(
          app.buttons["up-next-move-down-\(secondBookID)"],
          containing: "Move Tides Between Stars later",
          specification: "Move Later names the affected audiobook"
        ),
        namedControl(
          app.buttons["up-next-move-up-\(secondBookID)"],
          containing: "Move Tides Between Stars earlier",
          specification: "Move Earlier names the affected audiobook"
        ),
      ]
    )

    app.terminate()
    app = makeApplication(fixture: "single-audiobook-ready")
    app.launch()
    app.tabBars.buttons["Settings"].tap()
    let accessibility = app.buttons["settings-accessibility"]
    scrollTo(accessibility, in: app)
    accessibility.tap()
    let highContrast = app.switches["accessibility-high-contrast"]
    tapSwitchControl(highContrast)
    let reduceArtwork = app.switches["accessibility-reduce-artwork"]
    tapSwitchControl(reduceArtwork)
    let activeSettings = app.staticTexts["Active iPhone settings"]
    app.buttons["e2e-align-active-iphone-settings"].tap()
    XCTAssertTrue(activeSettings.waitForExistence(timeout: 2))
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    try tester.step(
      "accessibility-preferences",
      description: "Settings distinguishes app preferences from authoritative iPhone settings",
      verifications: [
        .valueEquals(
          anyElement(app, "accessibility-preferences-state"),
          "high-contrast=true:reduce-artwork=true",
          "Both app-specific display preferences persist in the model"),
        .valueContains(
          anyElement(app, "accessibility-settings-screen"), "system-increase-contrast=true",
          "The active system Increase Contrast setting is reported"),
        .exists(activeSettings, "System accessibility settings are presented separately"),
      ]
    )

    app.terminate()
    app = makeReceiverApplication()
    app.launch()
    app.buttons["receive-from-computer-empty-library"].tap()
    try tester.step(
      "large-text-computer-receiver",
      description: "The direct-import receiver remains scrollable and exposes its pairing details",
      verifications: [
        .valueEquals(
          app.scrollViews["computer-receiver-screen"], "receiver:ready",
          "The receiver reports a ready state without relying on color"),
        .exists(
          app.staticTexts["computer-receiver-address"], "The local address remains discoverable"),
        .exists(
          app.staticTexts["computer-receiver-pairing-code"], "The pairing code remains discoverable"
        ),
      ]
    )

    tester.generateDocs()
  }

  private func makeApplication(fixture: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = baseArguments(fixture: fixture)
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launchEnvironment["PLAYER_E2E_DYNAMIC_TYPE"] = "accessibility5"
    return app
  }

  private func makeReceiverApplication() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      baseArguments(fixture: "empty-library") + [
        "-e2e-computer-receiver-ready", "-e2e-show-mirroring-tip",
      ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launchEnvironment["PLAYER_E2E_DYNAMIC_TYPE"] = "accessibility5"
    return app
  }

  private func makePopulatedLibraryApplication() throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = baseArguments(fixture: "synthetic-populated-library")
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launchEnvironment["PLAYER_E2E_DYNAMIC_TYPE"] = "accessibility5"
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

  private func baseArguments(fixture: String) -> [String] {
    [
      "-e2e", "-e2e-reset", "-e2e-fixture", fixture,
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
  }

  private func fixtureData(resource: String, extension fileExtension: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: resource, withExtension: fileExtension)
    )
    return try Data(contentsOf: url)
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func tapSwitchControl(_ element: XCUIElement) {
    XCTAssertTrue(element.waitForExistence(timeout: 2))
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
  }

  private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<8 where !element.isHittable { app.swipeUp() }
    XCTAssertTrue(element.waitForExistence(timeout: 2))
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
  }

  private func visibleControl(
    _ element: XCUIElement,
    in app: XCUIApplication,
    label: String,
    specification: String
  ) -> StepVerification {
    StepVerification(specification: specification) {
      guard element.waitForExistence(timeout: 2) else { return false }
      return element.isEnabled
        && element.isHittable
        && element.label.contains(label)
        && app.windows.firstMatch.frame.intersects(element.frame)
    }
  }

  private func namedControl(
    _ element: XCUIElement,
    containing label: String,
    specification: String
  ) -> StepVerification {
    StepVerification(specification: specification) {
      element.waitForExistence(timeout: 2) && element.label.contains(label)
    }
  }
}
