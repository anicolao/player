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
    XCTAssertTrue(terminateAndWait(restoredApp))
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    springboard.activate()
    XCTAssertTrue(
      springboard.wait(for: .runningForeground, timeout: 2),
      "SpringBoard should own the foreground after the preference process is terminated"
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

    let reviewPrimaryAction = anyElement(app, "review-import-primary-action")
    let edit = revealWithUserScroll(
      { app.buttons["edit-metadata"] },
      targetID: "edit-metadata",
      in: app,
      containerID: "review-import-scroll",
      obscuredBelow: reviewPrimaryAction,
      targetMode: .minimumUnobscuredHitRegion(
        exactLabel: "Edit Details",
        minimumHeight: 44
      ),
      gesture: .reviewImportActions
    )
    tapCenterOfUnobscuredRegion(
      edit,
      within: anyElement(app, "review-import-scroll"),
      obscuredBelow: reviewPrimaryAction,
      minimumHeight: 44
    )
    let titleField = revealWithUserScroll(
      { app.textFields["metadata-title-input"] },
      targetID: "metadata-title-input",
      in: app,
      containerID: "metadata-editor-scroll",
      gesture: .metadataIdentity,
      captureFraming: AccessibilityCaptureFraming(
        anchor: { app.staticTexts["Identity"] },
        targetMinY: 135
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
            targetMinY: 135,
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
        targetMinY: 100
      )
    )
    let bookDetailScreen = anyElement(app, "book-detail-screen")
    let bookDetailScrollReadiness = anyElement(app, "book-detail-scroll-readiness")
    let bookDetailScreenPixels = ConsecutiveAccessibilityScreenObservation()
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
        anchor: bookDetailScrollReadiness,
        prime: { bookDetailScreenPixels.prime() },
        preparedScreenshot: { bookDetailScreenPixels.takePreparedScreenshot() }
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
            targetMinY: 100,
            in: app
          )
          && elementIsFullyVisible(playBook, within: bookDetailScreen)
          && bookDetailScreenPixels.isStable()
      }
    )

    playBook.tap()
    let slider = app.sliders["player-position-slider"]
    let nowPlayingScroll = app.scrollViews["now-playing-scroll"]
    let playPause = revealWithUserScroll(
      { app.buttons["player-play-pause"] },
      targetID: "player-play-pause",
      in: app,
      containerID: "now-playing-scroll",
      gesture: .nowPlayingTransport,
      captureFraming: AccessibilityCaptureFraming(
        anchor: { nowPlayingScroll.staticTexts["Mara Vale"] },
        targetMinY: 110
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
            nowPlayingScroll.staticTexts["Mara Vale"],
            targetMinY: 110,
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
      targetMode: .minimumUnobscuredHitRegion(
        exactLabel: "Up Next, 3, Embedded cover artwork, Tides Between Stars, Ari Rowan, "
          + "Embedded cover artwork, Quiet Maps, Mina Sol, Embedded cover artwork, "
          + "The Clockwork Orchard, Mina Sol",
        minimumHeight: 44
      ),
      gesture: .libraryLongForm
    )
    tapCenterOfUnobscuredRegion(
      upNext,
      within: anyElement(app, "library-root-scroll"),
      obscuredBelow: app.otherElements["mini-player"],
      minimumHeight: 44
    )
    let upNextScreen = anyElement(app, "up-next-screen")
    let upNextProbe = anyElement(app, "up-next-probe")
    let upNextScrollReadiness = anyElement(app, "up-next-scroll-readiness")
    let firstUpNextBook = app.buttons["up-next-book-\(secondBookID)"]
    let firstUpNextCover = firstUpNextBook.descendants(matching: .other)
      .matching(identifier: "embedded-cover-artwork").element
    let firstUpNextTitle = firstUpNextBook.staticTexts["Tides Between Stars"]
    let firstUpNextAuthor = firstUpNextBook.staticTexts["Ari Rowan"]
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
            firstUpNextCover,
            within: app.windows.element,
            obscuredBelow: app.otherElements["mini-player"],
            requiresHittable: false
          )
          && elementIsFullyVisible(
            firstUpNextTitle,
            within: app.windows.element,
            obscuredBelow: app.otherElements["mini-player"],
            requiresHittable: false
          )
          && firstUpNextAuthor.exists
          && firstUpNextAuthor.frame.minY
            < app.otherElements["mini-player"].frame.minY - 4
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
      targetMode: .uniqueHittableAtBottom,
      gesture: .settingsLongForm
    )
    accessibility.tap()
    let highContrast = app.switches["accessibility-high-contrast"]
    tapSwitchControl(highContrast)
    let reduceArtwork = app.switches["accessibility-reduce-artwork"]
    tapSwitchControl(reduceArtwork)
    _ = revealWithUserScroll(
      { app.staticTexts["Reduce Motion"] },
      targetID: "Reduce Motion",
      in: app,
      containerID: "accessibility-settings-scroll",
      permitsGeometrySettledFallback: true,
      gesture: .accessibilitySettingsLongForm,
      captureFraming: AccessibilityCaptureFraming(
        anchor: { app.staticTexts["Reduce Motion"] },
        targetMinY: 150
      )
    )
    let activeSettings = app.staticTexts["Active iPhone settings"]
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
            targetMinY: 150,
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
    uniquelyIdentifiedElement(app, identifier)
  }

  private func accessibilityCaptureReadiness(
    app: XCUIApplication,
    specification: String,
    anchor: XCUIElement,
    intendedSheetContentID: String? = nil,
    prime: (@MainActor () -> Bool)? = nil,
    preparedScreenshot: (@MainActor () -> XCUIScreenshot?)? = nil,
    checkNow: @escaping @MainActor () -> Bool
  ) -> CaptureReadiness {
    CaptureReadiness(
      specification: specification,
      anchor: anchor,
      prime: prime,
      preparedScreenshot: preparedScreenshot
    ) {
      checkNow()
        && app.keyboards.count == 0
        && app.alerts.count == 0
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
    targetMinY: CGFloat,
    in app: XCUIApplication
  ) -> Bool {
    guard let screenY = anchorScreenY(element, in: app) else { return false }
    return abs(screenY - targetMinY) <= 1
  }

  private func anchorScreenY(
    _ element: XCUIElement,
    in app: XCUIApplication
  ) -> CGFloat? {
    let window = app.windows.element
    guard window.exists else { return nil }
    return anchorScreenY(element, windowMinY: window.frame.minY)
  }

  private func anchorScreenY(
    _ element: XCUIElement,
    windowMinY: CGFloat
  ) -> CGFloat? {
    guard element.exists else { return nil }
    let frame = element.frame
    guard !frame.isEmpty else { return nil }
    return frame.minY - windowMinY
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
      targetMode: .uniqueHittableAtBottom,
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
    obscuredBelow explicitObstruction: XCUIElement? = nil,
    targetMode: AccessibilityRevealTargetMode = .fullyVisible,
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
    let obstruction = explicitObstruction
      ?? (miniPlayer.exists ? miniPlayer : nil)
    let targetIsVisible = {
      switch targetMode {
      case .uniqueHittableAtBottom:
        let aliases = app.buttons.matching(identifier: targetID).allElementsBoundByIndex
        guard let reference = aliases.first else { return false }
        let physicalAliasesMatch = aliases.allSatisfy {
          $0.identifier == targetID
            && $0.label == reference.label
            && $0.frame == reference.frame
        }
        let interactable = aliases.filter {
          $0.exists
            && $0.isEnabled
            && $0.isHittable
            && app.windows.element.frame.intersects($0.frame)
        }
        return physicalAliasesMatch && !interactable.isEmpty
      case .minimumUnobscuredHitRegion(let exactLabel, let minimumHeight):
        let element = target()
        guard element.exists,
          element.identifier == targetID,
          element.label == exactLabel,
          element.isEnabled,
          element.isHittable
        else { return false }
        return self.unobscuredRegion(
          of: element,
          within: container,
          obscuredBelow: obstruction
        ).height >= minimumHeight
      case .fullyVisible:
        let element = target()
        return elementIsFullyVisible(
          element,
          within: container,
          obscuredBelow: obstruction
        )
      }
    }
    let failureContext = {
      let element = target()
      let aliasDescription: String
      if case .uniqueHittableAtBottom = targetMode {
        let aliases = app.buttons.matching(identifier: targetID).allElementsBoundByIndex
        aliasDescription = ", aliases=" + aliases.map {
          "{id=\($0.identifier),label=\($0.label),frame=\($0.frame),"
            + "enabled=\($0.isEnabled),hittable=\($0.isHittable)}"
        }.joined(separator: ",")
      } else {
        aliasDescription = ""
      }
      guard element.exists else {
        return "target=\(targetID):missing, container=\(container.frame), "
          + "readiness=\(String(describing: readiness.value))\(aliasDescription)"
      }
      return "target=\(targetID):\(element.frame), "
        + "target-hittable=\(element.isHittable), container=\(container.frame), "
        + "obstruction=\(String(describing: obstruction?.frame)), "
        + "readiness=\(String(describing: readiness.value))\(aliasDescription)"
    }
    let revealed: Bool
    if permitsGeometrySettledFallback {
      revealed = revealWithSettledListGeometry(
        targetIsVisible,
        on: surface,
        deadline: deadline,
        requiresTerminalEndpoint: targetMode.requiresTerminalEndpoint,
        failureContext: failureContext
      ) {
        performAccessibilityScrollGesture(
          gesture,
          in: container,
          obscuredBelow: obstruction
        )
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
        performAccessibilityScrollGesture(
          gesture,
          in: container,
          obscuredBelow: obstruction
        )
      }
    }
    XCTAssertTrue(
      revealed,
      targetMode.requiresTerminalEndpoint
        ? "Expected \(targetID) to become uniquely interactable at the settled endpoint"
        : "Expected \(targetID) to become safely interactable through settled user scrolling"
    )
    if let captureFraming {
      let framingDeadline = EventDeadline()
      XCTAssertTrue(
        settleCaptureFraming(
          captureFraming,
          on: surface,
          in: app,
          deadline: framingDeadline
        ),
        "Expected \(captureFraming.anchor().identifier) to settle at screen y "
          + "\(captureFraming.targetMinY) ± 1"
      )
    }
    return target()
  }

  private struct AccessibilityCaptureFraming {
    let anchor: @MainActor () -> XCUIElement
    let targetMinY: CGFloat
  }

  private enum AccessibilityRevealTargetMode {
    case fullyVisible
    case uniqueHittableAtBottom
    case minimumUnobscuredHitRegion(exactLabel: String, minimumHeight: CGFloat)

    var requiresTerminalEndpoint: Bool {
      if case .uniqueHittableAtBottom = self { return true }
      return false
    }
  }

  private func unobscuredRegion(
    of element: XCUIElement,
    within container: XCUIElement,
    obscuredBelow obstruction: XCUIElement?
  ) -> CGRect {
    var containerFrame = container.frame
    if let obstruction, obstruction.exists {
      containerFrame.size.height = max(0, min(containerFrame.maxY, obstruction.frame.minY)
        - containerFrame.minY)
    }
    return element.frame.intersection(containerFrame)
  }

  private func tapCenterOfUnobscuredRegion(
    _ element: XCUIElement,
    within container: XCUIElement,
    obscuredBelow obstruction: XCUIElement?,
    minimumHeight: CGFloat
  ) {
    let region = unobscuredRegion(
      of: element,
      within: container,
      obscuredBelow: obstruction?.exists == true ? obstruction : nil
    )
    XCTAssertGreaterThanOrEqual(region.height, minimumHeight)
    guard element.frame.width > 0, element.frame.height > 0, region.height >= minimumHeight
    else { return }
    element.coordinate(withNormalizedOffset: CGVector(
      dx: (region.midX - element.frame.minX) / element.frame.width,
      dy: (region.midY - element.frame.minY) / element.frame.height
    )).tap()
  }

  private func settleCaptureFraming(
    _ framing: AccessibilityCaptureFraming,
    on surface: ScrollSurface,
    in app: XCUIApplication,
    deadline: EventDeadline
  ) -> Bool {
    let window = app.windows.element
    guard window.exists else { return false }
    let windowMinY = window.frame.minY
    guard waitForScrollReadiness(
      surface,
      deadline: deadline,
      matching: { $0.isIdle && $0.geometryReady }
    ) else { return false }

    while deadline.remaining > 0 {
      guard let before = surface.state(), before.isIdle else { return false }
      let anchor = framing.anchor()
      guard let screenY = anchorScreenY(anchor, windowMinY: windowMinY) else {
        return false
      }
      let displacement = screenY - framing.targetMinY
      if abs(displacement) <= 1 { return true }
      let direction: ScrollProbeDirection
      if displacement > 0 {
        if before.atBottom {
          return waitForCaptureAnchor(
            framing,
            windowMinY: windowMinY,
            deadline: deadline,
            matching: { abs($0 - framing.targetMinY) <= 1 },
            failureReason: "the scroll probe reported its bottom endpoint"
          ) != nil
        }
        direction = .towardEnd
      } else {
        if before.atTop {
          return waitForCaptureAnchor(
            framing,
            windowMinY: windowMinY,
            deadline: deadline,
            matching: { abs($0 - framing.targetMinY) <= 1 },
            failureReason: "the scroll probe reported its top endpoint"
          ) != nil
        }
        direction = .towardStart
      }
      guard deadline.remaining >= 0.2 else { return false }
      performAccessibilityFramingGesture(displacement: displacement, in: surface.container)
      var settledState: ScrollReadinessState?
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
          let isSettled = after.isIdle && after.geometryID > before.geometryID
            && progressed && (phaseCompletion || listGeometryFallback)
          if isSettled { settledState = after }
          return isSettled
        }
      )
      guard settled, settledState != nil else { return false }
      let anchorProgressed: (CGFloat) -> Bool = { updatedY in
        if abs(updatedY - framing.targetMinY) <= 1 { return true }
        switch direction {
        case .towardEnd: return updatedY < screenY - 0.5
        case .towardStart: return updatedY > screenY + 0.5
        }
      }
      guard let updatedY = waitForCaptureAnchor(
        framing,
        windowMinY: windowMinY,
        deadline: deadline,
        matching: anchorProgressed,
        failureReason: "the settled scroll geometry did not reach the accessibility tree"
      ) else { return false }
      if abs(updatedY - framing.targetMinY) <= 1 {
        return true
      }
    }
    print(
      "Capture framing deadline expired: target=\(framing.targetMinY), "
        + "actual=\(String(describing: anchorScreenY(framing.anchor(), in: app))), "
        + "container=\(surface.containerID), probe=\(String(describing: surface.readiness.value))"
    )
    return false
  }

  private func waitForCaptureAnchor(
    _ framing: AccessibilityCaptureFraming,
    windowMinY: CGFloat,
    deadline: EventDeadline,
    matching condition: @escaping (CGFloat) -> Bool,
    failureReason: String
  ) -> CGFloat? {
    var latestY: CGFloat?
    func matches() -> Bool {
      latestY = anchorScreenY(framing.anchor(), windowMinY: windowMinY)
      return latestY.map(condition) ?? false
    }
    if matches() { return latestY }
    if deadline.remaining > 0 {
      let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in matches() },
        object: framing.anchor()
      )
      _ = XCTWaiter.wait(for: [expectation], timeout: deadline.remaining)
    }
    if matches() { return latestY }
    print(
      "Capture framing failed because \(failureReason): target=\(framing.targetMinY), "
        + "actual=\(String(describing: latestY))"
    )
    return nil
  }

  private func performAccessibilityFramingGesture(
    displacement: CGFloat,
    in element: XCUIElement
  ) {
    let containerHeight = element.frame.height
    guard containerHeight > 0 else { return }
    let startY: CGFloat = 0.5
    // UIScrollView consumes the first ten points while recognizing a pan. Include
    // that hysteresis in the finger motion so the content moves by the measured
    // anchor-to-target displacement without a momentum-producing release.
    let panHysteresis: CGFloat = displacement > 0 ? 10 : -10
    let fingerDisplacement = displacement + panHysteresis
    let endY = max(0.1, min(0.9, startY - fingerDisplacement / containerHeight))
    let distance = abs(fingerDisplacement)
    let velocity: XCUIGestureVelocity
    if distance < 50 {
      velocity = 50
    } else if distance < 100 {
      velocity = 100
    } else {
      velocity = 300
    }
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: startY))
      .press(
        forDuration: 0.01,
        thenDragTo: element.coordinate(
          withNormalizedOffset: CGVector(dx: 0.82, dy: endY)
        ),
        withVelocity: velocity,
        thenHoldForDuration: 0.1
      )
  }

  private func revealWithSettledListGeometry(
    _ condition: @escaping () -> Bool,
    on surface: ScrollSurface,
    deadline: EventDeadline,
    requiresTerminalEndpoint: Bool = false,
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

    if !requiresTerminalEndpoint && condition() { return true }

    var current = before
    while deadline.remaining >= 0.2, current.hasScrollableRange, !current.atBottom {
      let previous = current
      gesture()
      let remainingRange = previous.maximum - previous.offset
      let requiredProgress = min(previous.containerLength * 0.25, remainingRange)
      var settledState: ScrollReadinessState?
      let observedSettledProgress = waitForScrollReadiness(
        surface,
        deadline: deadline
      ) { after in
        let settled = after.isIdle
          && after.geometryReady
          && after.geometryID > previous.geometryID
          && after.offset >= previous.offset + max(0.5, requiredProgress - 1)
        if settled { settledState = after }
        return settled
      }
      guard observedSettledProgress, let settledState
      else {
        print(
          "List scroll lacked stable progress-making geometry: "
            + "container=\(surface.containerID), probe=\(surface.readiness.value), "
            + failureContext()
        )
        return false
      }
      if condition() && (!requiresTerminalEndpoint || settledState.atBottom) { return true }
      current = settledState
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
    case reviewImportActions
    case libraryLongForm
  }

  private func performAccessibilityScrollGesture(
    _ gesture: AccessibilityScrollGesture,
    in element: XCUIElement,
    obscuredBelow obstruction: XCUIElement?
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
      directUpwardDrag(in: element, fromY: 0.78, toY: 0.22, velocity: 4_000)
    case .accessibilitySettingsLongForm:
      // Underlap the Active iPhone heading while framing Reduce Motion below navigation.
      element.swipeUp(velocity: 2_000)
    case .reviewImportActions:
      obstructionAwareUpwardDrag(in: element, obscuredBelow: obstruction)
    case .libraryLongForm:
      // Keep the touch above the live mini-player instead of guessing where its overlay ends.
      // scrollUntil observes each bounded move and only continues after correlated progress.
      obstructionAwareUpwardDrag(in: element, obscuredBelow: obstruction)
    }
  }

  private func obstructionAwareUpwardDrag(
    in element: XCUIElement,
    obscuredBelow obstruction: XCUIElement?
  ) {
    guard let obstruction, obstruction.exists, element.frame.height > 0 else {
      XCTFail("Expected a scroll surface and its pinned obstruction before scrolling")
      return
    }
    let safeStartScreenY = min(element.frame.maxY - 1, obstruction.frame.minY - 12)
    let safeStartY = (safeStartScreenY - element.frame.minY) / element.frame.height
    guard safeStartY > 0.05 else {
      XCTFail("The pinned obstruction left no safe vertical gesture region")
      return
    }
    directUpwardDrag(
      in: element,
      fromY: safeStartY,
      toY: 0.05,
      velocity: 1_750
    )
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
        && app.windows.element.frame.intersects(element.frame)
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

@MainActor
private final class ConsecutiveAccessibilityScreenObservation {
  private var previousObservation: AccessibilityScreenPixelObservation?
  private var preparedScreenshot: XCUIScreenshot?

  func prime() -> Bool {
    guard let (_, observation) = captureObservation() else {
      print("Accessibility capture could not decode its priming composited screen pixels")
      return false
    }
    previousObservation = observation
    preparedScreenshot = nil
    print("Accessibility capture primed its composited screen observation")
    return true
  }

  func isStable() -> Bool {
    guard let (screenshot, observation) = captureObservation() else {
      print("Accessibility capture could not decode the composited screen pixels")
      return false
    }
    defer { previousObservation = observation }
    guard let previousObservation else {
      print("Accessibility capture observed its first composited screen")
      return false
    }
    if previousObservation == observation {
      preparedScreenshot = screenshot
      return true
    }
    preparedScreenshot = nil
    print("Accessibility capture observed a compositor change")
    return false
  }

  func takePreparedScreenshot() -> XCUIScreenshot? {
    defer { preparedScreenshot = nil }
    return preparedScreenshot
  }

  private func captureObservation() -> (XCUIScreenshot, AccessibilityScreenPixelObservation)? {
    let screenshot = XCUIScreen.main.screenshot()
    guard let observation = AccessibilityScreenPixelObservation(screenshot) else { return nil }
    return (screenshot, observation)
  }
}

@MainActor
private struct AccessibilityScreenPixelObservation: Equatable {
  let width: Int
  let height: Int
  let bytesPerRow: Int
  let bitsPerComponent: Int
  let bitsPerPixel: Int
  let bitmapInfo: UInt32
  let pixels: Data

  init?(_ screenshot: XCUIScreenshot) {
    guard let image = screenshot.image.cgImage,
      let providerData = image.dataProvider?.data
    else { return nil }
    width = image.width
    height = image.height
    bytesPerRow = image.bytesPerRow
    bitsPerComponent = image.bitsPerComponent
    bitsPerPixel = image.bitsPerPixel
    bitmapInfo = image.bitmapInfo.rawValue
    pixels = providerData as Data
  }
}
