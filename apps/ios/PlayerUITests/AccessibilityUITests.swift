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
      gesture: .metadataIdentity
    )
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
      gesture: .bookDetailActions
    )
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
    let playPause = revealWithUserScroll(
      { app.buttons["player-play-pause"] },
      targetID: "player-play-pause",
      in: app,
      containerID: "now-playing-scroll",
      gesture: .nowPlayingTransport
    )
    XCTAssertTrue(slider.waitForExistence(timeout: 2))
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
      gesture: .accessibilitySettingsLongForm
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
      ]
    )

    XCTAssertTrue(terminateAndWait(app))
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
        .exists(
          app.buttons["choose-from-files-computer-receiver"],
          "Files remains available as the receiver's secondary import route"
        ),
      ]
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
    return target()
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
      // Clear the cover editor without the prior kinetic gesture's roughly 230-point overshoot.
      directUpwardDrag(in: element, fromY: 0.75, toY: 0.25, velocity: 300)
    case .bookDetailActions:
      // Land near 834 - 257 = 577 points so Play stays fully inside the viewport.
      directUpwardDrag(in: element, fromY: 0.82, toY: 0.16, velocity: 400)
    case .nowPlayingTransport:
      // Bring the transport into view while retaining the title and chapter context.
      directUpwardDrag(in: element, fromY: 0.86, toY: 0.08, velocity: 500)
    case .settingsLongForm:
      // This target sits near the bottom of the Form; finish at the endpoint so it clears chrome.
      element.swipeUp(velocity: .fast)
    case .accessibilitySettingsLongForm:
      // The target is visible around offset 860; the general 2,000 velocity overshot to 1,079.
      element.swipeUp(velocity: 1_600)
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
