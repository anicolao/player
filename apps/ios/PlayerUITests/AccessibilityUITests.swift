import XCTest

/// Story 009 is intentionally written against accessibility semantics rather than pixels.
/// The test is not part of the generated Xcode project until the production accessibility
/// contract in tests/e2e/009-accessibility/CONTRACT.md has been implemented.
@MainActor
final class AccessibilityUITests: XCTestCase {
  private let recoveryJobID = "61000000-0000-0000-0000-000000000002"
  private let recoveryFileID = "61000000-0000-0000-0000-000000000102"
  private let metadataJobID = "80000000-0000-0000-0000-000000000001"
  private let bookmarkBookID = "53000000-0000-0000-0000-000000000001"
  private let bookmarkID = "53000000-0000-0000-0000-000000000101"
  private let preludeAssetID = "30000000-0000-0000-0000-000000000111"

  func testCoreJourneysRemainOperableAcrossAccessibilityProfiles() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    try proveLargestTextImportRecovery()
    try proveLargestTextMetadataRepair()
    try proveVoiceOverReorderWithoutDragging()
    try proveNowPlayingAndBookmarksWithAssistiveDisplayPreferences()
  }

  private func proveLargestTextImportRecovery() throws {
    let app = application(
      fixture: "import-recovery-storage",
      extraArguments: [
        "-e2e-recovery-scenario", "mixed",
        "-e2e-accessibility-profile", "largest-text",
      ])
    app.launch()
    try requireValue(
      anyElement(app, "accessibility-environment-probe"),
      "accessibility:dynamic-type=accessibility5:reduce-motion=false:contrast=standard:differentiate=false"
    )

    app.buttons["Inbox"].tap()
    app.buttons["review-import-job-\(recoveryJobID)"].tap()
    let screen = anyElement(app, "import-recovery-screen")
    try requireValue(
      screen,
      "recovery:job=\(recoveryJobID):phase=needsReview:accepted=1:duplicates=2:failed=2:global=none:continue=true:source-unchanged=true"
    )
    XCTAssertEqual(screen.label, "Review Import")
    try assertReadingOrder(
      [
        anyElement(app, "recovery-summary"),
        anyElement(app, "recovery-files-heading"),
        anyElement(app, "recovery-file-61000000-0000-0000-0000-000000000101"),
        anyElement(app, "recovery-file-\(recoveryFileID)"),
      ], in: app)

    let retry = app.buttons["retry-import-file-\(recoveryFileID)"]
    let remove = app.buttons["remove-import-file-\(recoveryFileID)"]
    try makeHittable(retry, in: app)
    assertMinimumHitTarget(retry)
    try makeHittable(remove, in: app)
    assertMinimumHitTarget(remove)
    XCTAssertEqual(retry.label, "Retry File")
    XCTAssertEqual(remove.label, "Remove 02-retry-signal.m4a")
    try audit(app)
    app.terminate()
  }

  private func proveLargestTextMetadataRepair() throws {
    let app = try metadataApplication()
    app.launch()
    try requireValue(
      anyElement(app, "accessibility-environment-probe"),
      "accessibility:dynamic-type=accessibility5:reduce-motion=false:contrast=standard:differentiate=false"
    )
    app.buttons["Inbox"].tap()
    app.buttons["review-import-job-\(metadataJobID)"].tap()
    app.buttons["edit-metadata"].tap()

    let editor = anyElement(app, "metadata-editor-screen")
    try requireValue(editor, "metadata:proposal:revision=0:dirty=false")
    XCTAssertEqual(editor.label, "Edit Details")
    let title = anyElement(app, "metadata-field-title")
    try makeHittable(title, in: app)
    XCTAssertEqual(title.label, "Title")
    XCTAssertEqual(
      title.value as? String,
      "The Brass Lantern. Embedded tag, high confidence. Unlocked."
    )
    let clearNarrators = app.buttons["metadata-clear-narrators"]
    try makeHittable(clearNarrators, in: app)
    assertMinimumHitTarget(clearNarrators)
    XCTAssertEqual(clearNarrators.label, "Clear narrators")
    try audit(app)
    app.terminate()
  }

  private func proveVoiceOverReorderWithoutDragging() throws {
    let app = application(
      fixture: "messy-multifile-unicode",
      extraArguments: [
        "-e2e-acquisition", "SyntheticMessyMultifile",
        "-e2e-accessibility-profile", "voiceover",
      ])
    app.launch()
    try requireValue(
      anyElement(app, "accessibility-environment-probe"),
      "accessibility:dynamic-type=accessibility5:reduce-motion=false:contrast=standard:differentiate=false"
    )
    app.buttons["add-audiobook"].tap()
    app.buttons["Inbox"].tap()
    app.buttons["review-import-job-30000000-0000-0000-0000-000000000001"].tap()
    app.buttons["review-order-button"].tap()

    let row = anyElement(app, "order-track-\(preludeAssetID)")
    try makeHittable(row, in: app)
    XCTAssertEqual(row.label, "Track 4, Prélude – été.m4a")
    XCTAssertTrue(
      (row.value as? String)?.contains("Natural filename order for Prélude – été.m4a") == true
    )
    app.buttons["order-select-\(preludeAssetID)"].tap()
    let moveEarlier = app.buttons["order-move-up-\(preludeAssetID)"]
    try makeHittable(moveEarlier, in: app)
    assertMinimumHitTarget(moveEarlier)
    moveEarlier.tap()
    try requireValue(
      anyElement(app, "order-probe"),
      "order|revision|1|a|a1,a2,ap,a10|b|b3,b4,b5,b6"
    )
    try audit(app)
    app.terminate()
  }

  private func proveNowPlayingAndBookmarksWithAssistiveDisplayPreferences() throws {
    let app = application(
      fixture: "bookmarks",
      extraArguments: [
        "-e2e-accessibility-profile", "assistive-display",
      ])
    app.launch()
    try requireValue(
      anyElement(app, "accessibility-environment-probe"),
      "accessibility:dynamic-type=accessibility5:reduce-motion=true:contrast=increased:differentiate=true"
    )
    try requireValue(
      anyElement(app, "accessibility-rendering-probe"),
      "rendering:motion=reduced:contrast=increased:status=shape-symbol-text"
    )

    let miniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    miniPlayer.tap()
    let nowPlaying = app.otherElements["now-playing-screen"]
    XCTAssertTrue(nowPlaying.waitForExistence(timeout: 2))

    let slider = app.sliders["player-position-slider"]
    try makeHittable(slider, in: app)
    XCTAssertEqual(slider.label, "Listening position")
    XCTAssertEqual(slider.value as? String, "1:00 of 2:00")

    // Capture the boundary bookmark before seek appends its deterministic position-event ID.
    // This preserves the fixture's already-established bookmark UUID contract.
    let addBookmark = app.buttons["add-bookmark"]
    try makeHittable(addBookmark, in: app)
    addBookmark.tap()
    let saved = anyElement(app, "bookmark-saved")
    XCTAssertTrue(saved.waitForExistence(timeout: 2))

    try makeHittable(slider, in: app)
    slider.adjust(toNormalizedSliderPosition: 0.25)
    try requireValue(nowPlaying, "player:paused:\(bookmarkBookID):0:30000")
    app.buttons["Done"].tap()
    try openBookmarks(app)

    let row = anyElement(app, "bookmark-row-\(bookmarkID)")
    try makeHittable(row, in: app)
    XCTAssertEqual(row.label, "The Crossing · 1:00")
    XCTAssertEqual(row.value as? String, "1:00. The Crossing. No note.")
    let jump = app.buttons["jump-to-bookmark-\(bookmarkID)"]
    let edit = app.buttons["edit-bookmark-\(bookmarkID)"]
    let delete = app.buttons["delete-bookmark-\(bookmarkID)"]
    for action in [jump, edit, delete] {
      try makeHittable(action, in: app)
      assertMinimumHitTarget(action)
    }
    XCTAssertEqual(jump.label, "Jump to The Crossing · 1:00")
    XCTAssertEqual(edit.label, "Edit The Crossing · 1:00")
    XCTAssertEqual(delete.label, "Delete The Crossing · 1:00")
    try audit(app)
    app.terminate()
  }

  private func metadataApplication() throws -> XCUIApplication {
    let app = application(
      fixture: "synthetic-metadata-repair",
      extraArguments: [
        "-e2e-accessibility-profile", "largest-text",
      ])
    app.launchEnvironment["PLAYER_E2E_METADATA_AUDIO_BASE64"] = try fixtureData(
      resource: "metadata-repair-source", extension: "m4b"
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_METADATA_ORIGINAL_COVER_BASE64"] = try fixtureData(
      resource: "metadata-repair-original-cover", extension: "png"
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_METADATA_REPLACEMENT_COVER_BASE64"] = try fixtureData(
      resource: "metadata-repair-replacement-cover", extension: "png"
    ).base64EncodedString()
    return app
  }

  private func application(fixture: String, extraArguments: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      [
        "-e2e", "-e2e-reset", "-e2e-fixture", fixture,
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_CA",
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        "-NSTreatUnknownArgumentsAsOpen", "NO",
      ] + extraArguments
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func openBookmarks(_ app: XCUIApplication) throws {
    try makeHittable(app.buttons["browse-all-books"], in: app)
    app.buttons["browse-all-books"].tap()
    let book = app.buttons["all-books-book-\(bookmarkBookID)"]
    XCTAssertTrue(book.waitForExistence(timeout: 2))
    book.tap()
    let bookmarks = app.buttons["bookmarks-segment"]
    try makeHittable(bookmarks, in: app)
    bookmarks.tap()
    try requireValue(bookmarks, "selected")
  }

  private func fixtureData(resource: String, extension fileExtension: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: resource, withExtension: fileExtension),
      "The checked-in synthetic fixture must be in the UI-test bundle"
    )
    return try Data(contentsOf: url)
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func makeHittable(_ element: XCUIElement, in app: XCUIApplication) throws {
    let deadline = Date().addingTimeInterval(3)
    repeat {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    } while Date() < deadline
    XCTFail("Expected \(element.identifier) to remain reachable without drag-and-drop")
    throw AccessibilityUITestError.elementUnavailable
  }

  private func assertReadingOrder(_ elements: [XCUIElement], in app: XCUIApplication) throws {
    for element in elements { try makeHittable(element, in: app) }
    let orderedFrames = elements.map(\.frame)
    for pair in zip(orderedFrames, orderedFrames.dropFirst()) {
      XCTAssertLessThan(
        pair.0.minY, pair.1.minY, "Accessibility content order must match visual order")
    }
  }

  private func assertMinimumHitTarget(_ element: XCUIElement) {
    XCTAssertGreaterThanOrEqual(element.frame.width, 44)
    XCTAssertGreaterThanOrEqual(element.frame.height, 44)
  }

  private func audit(_ app: XCUIApplication) throws {
    try app.performAccessibilityAudit(for: [
      .contrast, .dynamicType, .elementDetection, .hitRegion,
      .sufficientElementDescription, .textClipped, .trait,
    ]) { issue in
      // One-point read-only E2E probes deliberately are not production controls.
      // Audit every other element; never suppress based on an issue description.
      issue.element?.identifier.hasSuffix("-probe") == true
    }
  }

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    let result = XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", expected), object: element
        )
      ],
      timeout: 3
    )
    guard result == .completed else {
      XCTFail(
        "Expected \(element.identifier) value \(expected), actual=\(String(describing: element.value))"
      )
      throw AccessibilityUITestError.semanticStateUnavailable
    }
  }
}

private enum AccessibilityUITestError: Error {
  case elementUnavailable
  case semanticStateUnavailable
}
