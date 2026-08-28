import XCTest

@MainActor
final class AccessibilityUITests: XCTestCase {
  private let secondBookID = "90000000-0000-0000-0000-000000000002"

  func testAccessibilityPreferenceTogglesUpdateAndPersist() throws {
    continueAfterFailure = false
    let namespace = "accessibility-preferences-persistence"
    let app = makeApplication(
      fixture: "metadata-rich-book",
      reset: true,
      metadataRichNamespace: namespace
    )
    app.launch()
    let initial = openAccessibilityPreferences(in: app)
    assertAccessibilityPreferences(
      initial,
      switchValues: (highContrast: "0", reduceArtwork: "0"),
      modelValue: "high-contrast=false:reduce-artwork=false"
    )

    let highContrastDeadline = EventDeadline()
    tapSwitchControl(initial.highContrast, deadline: highContrastDeadline)
    XCTAssertTrue(
      initial.preferences.waitForStringValue(
        "high-contrast=true:reduce-artwork=false",
        timeout: highContrastDeadline.remaining
      )
    )
    XCTAssertTrue(
      initial.highContrast.waitForStringValue("1", timeout: highContrastDeadline.remaining)
    )

    let reduceArtworkDeadline = EventDeadline()
    tapSwitchControl(initial.reduceArtwork, deadline: reduceArtworkDeadline)
    assertAccessibilityPreferences(
      initial,
      switchValues: (highContrast: "1", reduceArtwork: "1"),
      modelValue: "high-contrast=true:reduce-artwork=true",
      deadline: reduceArtworkDeadline
    )

    XCTAssertTrue(terminateAndWait(app))
    let restoredApp = makeApplication(
      fixture: "metadata-rich-book",
      reset: false,
      metadataRichNamespace: namespace
    )
    restoredApp.launch()
    let restored = openAccessibilityPreferences(in: restoredApp)
    assertAccessibilityPreferences(
      restored,
      switchValues: (highContrast: "1", reduceArtwork: "1"),
      modelValue: "high-contrast=true:reduce-artwork=true"
    )
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
    let reviewScreen = anyElement(app, "review-import-screen")
    let reviewScrollReadiness = anyElement(app, "review-import-scroll-readiness")
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
      ],
      captureReadiness: accessibilityCaptureReadiness(
        app: app,
        specification: "At capture, the exact import proposal is idle at the top with placeholder artwork, title, and pinned Add action fully visible",
        anchor: reviewScrollReadiness
      ) {
        self.hasExactValue(
          reviewScreen,
          "proposal:ready:1-book:1-tracks:0-warnings"
        )
          && self.hasSettledScroll(
            reviewScrollReadiness,
            containerID: "review-import-scroll",
            atTop: true
          )
          && elementIsFullyVisible(
            app.descendants(matching: .any)["placeholder-artwork"],
            within: reviewScreen,
            requiresHittable: false
          )
          && elementIsFullyVisible(
            app.staticTexts["The Lighthouse Signal"],
            within: reviewScreen,
            requiresHittable: false
          )
          && elementIsFullyVisible(add, within: reviewScreen)
      }
    )

    let edit = revealWithUserScroll(
      { app.buttons["edit-metadata"] },
      targetID: "edit-metadata",
      in: app,
      containerID: "review-import-scroll"
    )
    edit.tap()
    let titleField = revealWithUserScroll(
      { app.textFields["metadata-title-input"] },
      targetID: "metadata-title-input",
      in: app,
      containerID: "metadata-editor-scroll",
      gesture: .metadataIdentity,
      captureFraming: AccessibilityCaptureFraming(
        anchor: { app.staticTexts["Identity"] },
        allowedMinY: 90...135
      )
    )
    let metadataScreen = anyElement(app, "metadata-editor-screen")
    let metadataScrollReadiness = anyElement(app, "metadata-editor-scroll-readiness")
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
      ],
      captureReadiness: accessibilityCaptureReadiness(
        app: app,
        specification: "At capture, the exact clean metadata proposal is idle with Identity framed below the navigation bar and its Title actions fully visible",
        anchor: metadataScrollReadiness
      ) {
        self.hasExactValue(
          metadataScreen,
          "metadata:proposal:revision=0:dirty=false"
        )
          && self.hasSettledScroll(
            metadataScrollReadiness,
            containerID: "metadata-editor-scroll"
          )
          && self.isFramed(
            app.staticTexts["Identity"],
            allowedMinY: 90...135,
            in: app
          )
          && elementIsFullyVisible(titleField, within: metadataScreen)
          && elementIsFullyVisible(
            app.buttons["metadata-apply-title"], within: metadataScreen
          )
      }
    )

    XCTAssertTrue(terminateAndWait(app))
    app = makeApplication(
      fixture: "metadata-rich-book",
      metadataRichNamespace: "accessibility-core-book-detail"
    )
    app.launch()
    app.staticTexts["Harbor at Dawn"].tap()
    let playBook = revealWithUserScroll(
      { app.buttons["play-book"] },
      targetID: "play-book",
      in: app,
      containerID: "book-detail-scroll",
      gesture: .bookDetailActions,
      captureFraming: AccessibilityCaptureFraming(
        anchor: { app.staticTexts["Narrated by Imani Chen"] },
        allowedMinY: 40...100
      )
    )
    let bookDetailScreen = anyElement(app, "book-detail-screen")
    let bookDetailScrollReadiness = anyElement(app, "book-detail-scroll-readiness")
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
      ],
      captureReadiness: accessibilityCaptureReadiness(
        app: app,
        specification: "At capture, the exact three-chapter book is idle with narrator context framed under the header and all visible primary actions settled",
        anchor: bookDetailScrollReadiness
      ) {
        self.hasExactValue(
          bookDetailScreen,
          "book:ready:30000000-0000-0000-0000-000000000001:3-chapters:m4b"
        )
          && self.hasSettledScroll(
            bookDetailScrollReadiness,
            containerID: "book-detail-scroll"
          )
          && self.isFramed(
            app.staticTexts["Narrated by Imani Chen"],
            allowedMinY: 40...100,
            in: app
          )
          && elementIsFullyVisible(playBook, within: bookDetailScreen)
      }
    )

    playBook.tap()
    let slider = app.sliders["player-position-slider"]
    let playPause = revealWithUserScroll(
      { app.buttons["player-play-pause"] },
      targetID: "player-play-pause",
      in: app,
      containerID: "now-playing-scroll",
      gesture: .nowPlayingTransport,
      captureFraming: AccessibilityCaptureFraming(
        anchor: { app.staticTexts["Mara Vale"] },
        allowedMinY: 75...110
      )
    )
    XCTAssertTrue(slider.waitForExistence(timeout: 2))
    let nowPlayingScreen = anyElement(app, "now-playing-screen")
    let nowPlayingScrollReadiness = anyElement(app, "now-playing-scroll-readiness")
    let nowPlayingLayoutReadiness = anyElement(app, "now-playing-layout-readiness")
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
      ],
      captureReadiness: accessibilityCaptureReadiness(
        app: app,
        specification: "At capture, the exact playing chapter is framed at Mara Vale with idle scroll and settled layout, visible timeline and transport, and no unrelated presentation",
        anchor: nowPlayingLayoutReadiness,
        intendedSheetContentID: "now-playing-screen"
      ) {
        self.hasExactValue(
          nowPlayingScreen,
          "player:playing:30000000-0000-0000-0000-000000000001:0:0"
        )
          && self.hasSettledLayout(
            nowPlayingLayoutReadiness,
            containerID: "now-playing-screen"
          )
          && self.hasSettledScroll(
            nowPlayingScrollReadiness,
            containerID: "now-playing-scroll"
          )
          && self.isFramed(
            app.staticTexts["Mara Vale"],
            allowedMinY: 75...110,
            in: app
          )
          && elementIsFullyVisible(slider, within: nowPlayingScreen)
          && elementIsFullyVisible(playPause, within: nowPlayingScreen)
      }
    )

    XCTAssertTrue(terminateAndWait(app))
    app = try makePopulatedLibraryApplication()
    app.launch()
    let upNext = revealWithUserScroll(
      { app.buttons["open-up-next"] },
      targetID: "open-up-next",
      in: app,
      containerID: "library-root-scroll",
      gesture: .libraryLongForm
    )
    upNext.tap()
    let upNextScreen = anyElement(app, "up-next-screen")
    let upNextProbe = anyElement(app, "up-next-probe")
    let upNextScrollReadiness = anyElement(app, "up-next-scroll-readiness")
    let firstUpNextBook = app.buttons["up-next-book-\(secondBookID)"]
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
      ],
      captureReadiness: accessibilityCaptureReadiness(
        app: app,
        specification: "At capture, the exact three-book Up Next order is visible with its first cover-bearing row and paused mini-player in settled geometry",
        anchor: upNextScrollReadiness
      ) {
        self.hasExactValue(upNextScreen, "ready")
          && self.hasExactValue(
            upNextProbe,
            "up-next:count=3:order=90000000-0000-0000-0000-000000000002,90000000-0000-0000-0000-000000000005,90000000-0000-0000-0000-000000000003"
          )
          && self.hasSettledScroll(
            upNextScrollReadiness,
            containerID: "up-next-scroll",
            atTop: true
          )
          && elementIsFullyVisible(
            firstUpNextBook,
            within: app.windows.firstMatch,
            obscuredBelow: app.otherElements["mini-player"],
            requiresHittable: false
          )
          && firstUpNextBook.label.contains("Embedded cover artwork")
          && self.hasExactValue(
            app.otherElements["mini-player"],
            "player:paused:90000000-0000-0000-0000-000000000001:0:45000"
          )
      }
    )

    XCTAssertTrue(terminateAndWait(app))
    app = makeApplication(fixture: "single-audiobook-ready")
    app.launch()
    app.tabBars.buttons["Settings"].tap()
    let layoutPicker = anyElement(app, "all-books-layout-picker")
    XCTAssertTrue(layoutPicker.waitForExistence(timeout: 2))
    XCTAssertTrue(
      "\(layoutPicker.label) \(layoutPicker.value as? String ?? "")".contains("Shelf"),
      "The Settings layout picker should name Shelf as the active book layout"
    )
    let accessibility = revealWithUserScroll(
      { app.buttons["settings-accessibility"] },
      targetID: "settings-accessibility",
      in: app,
      containerID: "settings-scroll",
      permitsGeometrySettledFallback: true,
      gesture: .settingsLongForm
    )
    accessibility.tap()
    let highContrast = app.switches["accessibility-high-contrast"]
    tapSwitchControl(highContrast)
    let reduceArtwork = app.switches["accessibility-reduce-artwork"]
    tapSwitchControl(reduceArtwork)
    let activeSettings = revealWithUserScroll(
      { app.staticTexts["Active iPhone settings"] },
      targetID: "Active iPhone settings",
      in: app,
      containerID: "accessibility-settings-scroll",
      permitsGeometrySettledFallback: true,
      gesture: .accessibilitySettingsLongForm,
      captureFraming: AccessibilityCaptureFraming(
        anchor: { app.staticTexts["Reduce Motion"] },
        allowedMinY: 90...150
      )
    )
    let accessibilityScreen = anyElement(app, "accessibility-settings-screen")
    let accessibilityScrollReadiness = anyElement(
      app, "accessibility-settings-scroll-readiness"
    )
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
      ],
      captureReadiness: accessibilityCaptureReadiness(
        app: app,
        specification: "At capture, exact app and iPhone accessibility states are idle with Reduce Motion framed below the header and no transient control",
        anchor: accessibilityScrollReadiness
      ) {
        self.hasExactValue(
          accessibilityScreen,
          "accessibility:high-contrast=true:reduce-artwork=true:system-reduce-motion=false:system-increase-contrast=true:system-differentiate=false:system-bold=false:large-text=true"
        )
          && self.hasSettledScroll(
            accessibilityScrollReadiness,
            containerID: "accessibility-settings-scroll"
          )
          && self.isFramed(
            app.staticTexts["Reduce Motion"],
            allowedMinY: 90...150,
            in: app
          )
          && activeSettings.exists
      }
    )

    XCTAssertTrue(terminateAndWait(app))
    app = makeReceiverApplication()
    app.launch()
    app.buttons["receive-from-computer-empty-library"].tap()
    let receiverScreen = app.scrollViews["computer-receiver-screen"]
    let receiverScrollReadiness = anyElement(app, "computer-receiver-scroll-readiness")
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
        .exists(
          app.buttons["choose-from-files-computer-receiver"],
          "Files remains available as the receiver's secondary import route"
        ),
      ],
      captureReadiness: accessibilityCaptureReadiness(
        app: app,
        specification: "At capture, the exact ready receiver is idle at the top with its large-text address and pairing section stably laid out",
        anchor: receiverScrollReadiness,
        intendedSheetContentID: "computer-receiver-screen"
      ) {
        self.hasExactValue(receiverScreen, "receiver:ready")
          && self.hasSettledScroll(
            receiverScrollReadiness,
            containerID: "computer-receiver-scroll",
            atTop: true
          )
          && elementIsFullyVisible(
            app.staticTexts["computer-receiver-address"],
            within: receiverScreen,
            requiresHittable: false
          )
          && app.staticTexts["computer-receiver-pairing-code"].exists
      }
    )

    tester.generateDocs()
  }

  private func makeApplication(
    fixture: String,
    reset: Bool = true,
    metadataRichNamespace: String? = nil
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = baseArguments(
      fixture: fixture,
      reset: reset,
      metadataRichNamespace: metadataRichNamespace
    )
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

  private func baseArguments(
    fixture: String,
    reset: Bool = true,
    metadataRichNamespace: String? = nil
  ) -> [String] {
    var arguments = [
      "-e2e", "-e2e-fixture", fixture,
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset { arguments.insert("-e2e-reset", at: 1) }
    if let metadataRichNamespace {
      arguments += ["-e2e-metadata-rich-namespace", metadataRichNamespace]
    }
    XCTAssertEqual(
      arguments.filter { $0 == "-e2e-metadata-rich-namespace" }.count,
      metadataRichNamespace == nil ? 0 : 1,
      "Each metadata-rich launch must contain exactly one explicit namespace marker"
    )
    return arguments
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

  private func accessibilityCaptureReadiness(
    app: XCUIApplication,
    specification: String,
    anchor: XCUIElement,
    intendedSheetContentID: String? = nil,
    checkNow: @escaping @MainActor () -> Bool
  ) -> CaptureReadiness {
    CaptureReadiness(specification: specification, anchor: anchor) {
      checkNow()
        && !app.keyboards.firstMatch.exists
        && !app.alerts.firstMatch.exists
        && !self.hasUnintendedSheet(app, intendedContentID: intendedSheetContentID)
    }
  }

  private func hasExactValue(_ element: XCUIElement, _ expected: String) -> Bool {
    element.exists && element.value.map(String.init(describing:)) == expected
  }

  private func hasSettledScroll(
    _ probe: XCUIElement,
    containerID: String,
    atTop: Bool = false
  ) -> Bool {
    guard let state = ScrollReadinessState(probe.value) else { return false }
    let completionIsCorrelated = state.interactionID == 0
      ? state.completionID == 0
      : state.completionID == state.interactionID
        && state.completionGeometryID == state.geometryID
    return state.containerID == containerID
      && state.axis == .vertical
      && state.isIdle
      && state.geometryReady
      && completionIsCorrelated
      && (!atTop || state.atTop)
  }

  private func hasSettledLayout(
    _ probe: XCUIElement,
    containerID: String
  ) -> Bool {
    guard let state = LayoutReadinessState(probe.value) else { return false }
    return state.containerID == containerID
  }

  private func isFramed(
    _ element: XCUIElement,
    allowedMinY: ClosedRange<CGFloat>,
    in app: XCUIApplication
  ) -> Bool {
    guard element.exists, app.windows.firstMatch.exists, !element.frame.isEmpty else {
      return false
    }
    let screenY = element.frame.minY - app.windows.firstMatch.frame.minY
    return allowedMinY.contains(screenY)
  }

  private func hasUnintendedSheet(
    _ app: XCUIApplication,
    intendedContentID: String?
  ) -> Bool {
    app.sheets.allElementsBoundByIndex.contains { sheet in
      guard let intendedContentID else { return true }
      return sheet.identifier != intendedContentID
        && !sheet.descendants(matching: .any)[intendedContentID].exists
    }
  }

  private func openAccessibilityPreferences(
    in app: XCUIApplication
  ) -> (highContrast: XCUIElement, reduceArtwork: XCUIElement, preferences: XCUIElement) {
    let settingsDeadline = EventDeadline()
    let settings = app.tabBars.buttons["Settings"]
    XCTAssertTrue(waitForExistence(settings, deadline: settingsDeadline))
    settings.tap()

    let accessibilityDeadline = EventDeadline()
    let accessibility = revealWithUserScroll(
      { app.buttons["settings-accessibility"] },
      targetID: "settings-accessibility",
      in: app,
      containerID: "settings-scroll",
      permitsGeometrySettledFallback: true,
      gesture: .settingsLongForm,
      deadline: accessibilityDeadline
    )
    accessibility.tap()

    let controlsDeadline = EventDeadline()
    let highContrast = app.switches["accessibility-high-contrast"]
    let reduceArtwork = app.switches["accessibility-reduce-artwork"]
    let preferences = anyElement(app, "accessibility-preferences-state")
    XCTAssertTrue(waitForExistence(highContrast, deadline: controlsDeadline))
    XCTAssertTrue(waitForExistence(reduceArtwork, deadline: controlsDeadline))
    XCTAssertTrue(waitForExistence(preferences, deadline: controlsDeadline))
    return (highContrast, reduceArtwork, preferences)
  }

  private func assertAccessibilityPreferences(
    _ controls: (
      highContrast: XCUIElement,
      reduceArtwork: XCUIElement,
      preferences: XCUIElement
    ),
    switchValues: (highContrast: String, reduceArtwork: String),
    modelValue: String,
    deadline: EventDeadline = EventDeadline()
  ) {
    XCTAssertTrue(
      controls.preferences.waitForStringValue(modelValue, timeout: deadline.remaining),
      "The persisted accessibility model should publish \(modelValue)"
    )
    XCTAssertTrue(
      controls.highContrast.waitForStringValue(
        switchValues.highContrast,
        timeout: deadline.remaining
      ),
      "The high-contrast switch should expose \(switchValues.highContrast)"
    )
    XCTAssertTrue(
      controls.reduceArtwork.waitForStringValue(
        switchValues.reduceArtwork,
        timeout: deadline.remaining
      ),
      "The reduce-artwork switch should expose \(switchValues.reduceArtwork)"
    )
  }

  private func tapSwitchControl(
    _ element: XCUIElement,
    deadline: EventDeadline = EventDeadline()
  ) {
    XCTAssertTrue(waitForExistence(element, deadline: deadline))
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
  }

  private func revealWithUserScroll(
    _ target: @escaping @MainActor () -> XCUIElement,
    targetID: String,
    in app: XCUIApplication,
    containerID: String,
    permitsGeometrySettledFallback: Bool = false,
    gesture: AccessibilityScrollGesture = .standard,
    captureFraming: AccessibilityCaptureFraming? = nil,
    deadline: EventDeadline = EventDeadline()
  ) -> XCUIElement {
    let container = anyElement(app, containerID)
    let readiness = anyElement(app, "\(containerID)-readiness")
    XCTAssertTrue(waitForExistence(container, deadline: deadline))
    let surface = ScrollSurface(
      container: container,
      readiness: readiness,
      containerID: containerID,
      axis: .vertical,
      permitsGeometrySettledFallback: permitsGeometrySettledFallback
    )
    let miniPlayer = app.otherElements["mini-player"]
    let targetIsVisible = {
      let element = target()
      return elementIsFullyVisible(
        element,
        within: container,
        obscuredBelow: miniPlayer.exists ? miniPlayer : nil
      )
    }
    let failureContext = {
      let element = target()
      guard element.exists else {
        return "target=\(targetID):missing, container=\(container.frame)"
      }
      return "target=\(targetID):\(element.frame), "
        + "target-hittable=\(element.isHittable), container=\(container.frame)"
    }
    let revealed: Bool
    if permitsGeometrySettledFallback {
      revealed = revealWithSettledListGeometry(
        targetIsVisible,
        on: surface,
        deadline: deadline,
        failureContext: failureContext
      ) {
        performAccessibilityScrollGesture(gesture, in: container)
      }
    } else {
      revealed = scrollUntil(
        targetIsVisible,
        on: surface,
        deadline: deadline,
        requiresInteraction: true,
        requiresScrollableRange: true,
        terminalEndpoint: \.atBottom,
        failureContext: failureContext
      ) {
        performAccessibilityScrollGesture(gesture, in: container)
      }
    }
    XCTAssertTrue(
      revealed,
      "Expected \(targetID) to become fully visible through settled user scrolling"
    )
    if let captureFraming {
      XCTAssertTrue(
        settleCaptureFraming(
          captureFraming,
          on: surface,
          in: app,
          deadline: deadline
        ),
        "Expected \(captureFraming.anchor().identifier) to settle at screen y "
          + "\(captureFraming.allowedMinY)"
      )
    }
    return target()
  }

  private struct AccessibilityCaptureFraming {
    let anchor: @MainActor () -> XCUIElement
    let allowedMinY: ClosedRange<CGFloat>
  }

  private func settleCaptureFraming(
    _ framing: AccessibilityCaptureFraming,
    on surface: ScrollSurface,
    in app: XCUIApplication,
    deadline: EventDeadline
  ) -> Bool {
    guard waitForScrollReadiness(
      surface,
      deadline: deadline,
      matching: { $0.isIdle && $0.geometryReady }
    ) else { return false }

    while deadline.remaining > 0 {
      guard let before = surface.state(), before.isIdle else { return false }
      if isFramed(framing.anchor(), allowedMinY: framing.allowedMinY, in: app) {
        return true
      }

      let anchor = framing.anchor()
      let direction: ScrollProbeDirection
      if !anchor.exists || anchor.frame.minY > framing.allowedMinY.upperBound {
        guard !before.atBottom else { return false }
        direction = .towardEnd
      } else {
        guard !before.atTop else { return false }
        direction = .towardStart
      }
      guard deadline.remaining >= 0.2 else { return false }
      performAccessibilityFramingGesture(direction, in: surface.container)
      let settled = waitForScrollReadiness(
        surface,
        deadline: deadline,
        matching: { after in
          let progressed = direction == .towardEnd
            ? after.offset > before.offset + 0.5
            : after.offset < before.offset - 0.5
          let phaseCompletion = after.interactionID > before.interactionID
            && after.completionID > before.completionID
            && after.completionGeometryID == after.geometryID
          let listGeometryFallback = surface.permitsGeometrySettledFallback
            && self.isFramed(framing.anchor(), allowedMinY: framing.allowedMinY, in: app)
          return after.isIdle && after.geometryID > before.geometryID
            && progressed && (phaseCompletion || listGeometryFallback)
        }
      )
      guard settled else { return false }
    }
    return false
  }

  private func performAccessibilityFramingGesture(
    _ direction: ScrollProbeDirection,
    in element: XCUIElement
  ) {
    let startY: CGFloat = direction == .towardEnd ? 0.56 : 0.44
    let endY: CGFloat = direction == .towardEnd ? 0.47 : 0.53
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: startY))
      .press(
        forDuration: 0.01,
        thenDragTo: element.coordinate(
          withNormalizedOffset: CGVector(dx: 0.82, dy: endY)
        ),
        withVelocity: 300,
        thenHoldForDuration: 0.1
      )
  }

  private func revealWithSettledListGeometry(
    _ condition: @escaping () -> Bool,
    on surface: ScrollSurface,
    deadline: EventDeadline,
    failureContext: () -> String,
    gesture: () -> Void
  ) -> Bool {
    guard waitForScrollReadiness(
      surface,
      deadline: deadline,
      matching: { $0.isIdle && $0.geometryReady }
    ), let before = surface.state(), before.isIdle, before.geometryReady
    else {
      print("List scroll did not expose a ready bound surface: \(failureContext())")
      return false
    }

    if condition(),
      let stable = surface.state(),
      stable.isIdle,
      stable.geometryReady,
      stable.interactionID == before.interactionID,
      stable.completionID == before.completionID,
      stable.geometryID == before.geometryID,
      stable.completionGeometryID == before.completionGeometryID,
      abs(stable.offset - before.offset) <= 0.5,
      abs(stable.minimum - before.minimum) <= 0.5,
      abs(stable.maximum - before.maximum) <= 0.5,
      abs(stable.contentLength - before.contentLength) <= 0.5,
      abs(stable.containerLength - before.containerLength) <= 0.5,
      stable.atLeft == before.atLeft,
      stable.atRight == before.atRight,
      stable.atTop == before.atTop,
      stable.atBottom == before.atBottom,
      condition()
    {
      return true
    }

    var current = before
    while current.hasScrollableRange, !current.atBottom {
      gesture()
      let remainingRange = current.maximum - current.offset
      let requiredProgress = min(current.containerLength * 0.25, remainingRange)
      guard let after = surface.state(),
        after.isIdle,
        after.geometryID > current.geometryID,
        after.offset >= current.offset + max(0.5, requiredProgress - 1),
        let stable = surface.state(),
        stable.isIdle,
        stable.geometryID == after.geometryID,
        abs(stable.offset - after.offset) <= 0.5
      else {
        print(
          "List scroll lacked stable progress-making geometry: "
            + "container=\(surface.containerID), probe=\(surface.readiness.value), "
            + failureContext()
        )
        return false
      }
      if condition(), condition() { return true }
      current = stable
    }

    print("List scroll reached its endpoint before revealing the target: \(failureContext())")
    return false
  }

  private enum AccessibilityScrollGesture {
    case standard
    case metadataIdentity
    case bookDetailActions
    case nowPlayingTransport
    case settingsLongForm
    case accessibilitySettingsLongForm
    case libraryLongForm
  }

  private func performAccessibilityScrollGesture(
    _ gesture: AccessibilityScrollGesture,
    in element: XCUIElement
  ) {
    switch gesture {
    case .standard:
      element.swipeUp(velocity: .fast)
    case .metadataIdentity:
      // Frame Identity immediately below the navigation bar at Accessibility XXXL.
      directUpwardDrag(in: element, fromY: 0.75, toY: 0.18, velocity: 300)
    case .bookDetailActions:
      // Retain narrator context below the header while bringing Play fully into view.
      directUpwardDrag(in: element, fromY: 0.82, toY: 0.32, velocity: 400)
    case .nowPlayingTransport:
      // Bring transport into view with Mara Vale framed immediately below the header.
      directUpwardDrag(in: element, fromY: 0.86, toY: 0.11, velocity: 500)
    case .settingsLongForm:
      // This target sits near the bottom of the Form; finish at the endpoint so it clears chrome.
      element.swipeUp(velocity: .fast)
    case .accessibilitySettingsLongForm:
      // Underlap the Active iPhone heading while framing Reduce Motion below navigation.
      element.swipeUp(velocity: 2_000)
    case .libraryLongForm:
      // This velocity targets the measured 778...985-point Up Next clearance window.
      element.swipeUp(velocity: 1_750)
    }
  }

  private func directUpwardDrag(
    in element: XCUIElement,
    fromY: CGFloat,
    toY: CGFloat,
    velocity: XCUIGestureVelocity,
    holdDuration: TimeInterval = 0.15
  ) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: fromY))
      .press(
        forDuration: 0.01,
        thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: toY)),
        withVelocity: velocity,
        thenHoldForDuration: holdDuration
      )
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
