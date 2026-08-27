import XCTest

@MainActor
final class BackupUITests: XCTestCase {
  func testExportsClearsAndRestoresAVerifiedPortableLibrary() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "portable-backup", "-e2e-reset",
      "-e2e-start-section", "settings",
      "-e2e-start-settings-route", "backup",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launchEnvironment["PLAYER_E2E_DYNAMIC_TYPE"] = "medium"
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "A complete local library travels in one verified backup",
      narrative:
        "As a listener, I want to export my library, clear this device, and restore the same playable book, progress, and bookmark without duplicate audio.",
      fixture: "portable-backup",
      additionalPreconditions: [
        "The fixture contains one synthetic M4B payload, artwork, progress, organization, and a bookmark",
        "Export and restore call the production package writer, streaming checksum verifier, and atomic media replacement",
        "The system document picker itself is represented by deterministic E2E controls; its production entry points remain visible above",
      ]
    )
    app.launch()

    requireBackupTopVisible(app)
    try tester.step(
      "backup-settings",
      description: "Backup choices explain portable media and local automatic copies",
      verifications: [
        .exists(anyElement(app, "backup-purpose"), "Backup leads with why a listener needs it"),
        .valueEquals(
          anyElement(app, "backup-choice-with-audio"),
          "A self-contained copy of your books, artwork, edits, listening positions, preferences, and audio.",
          "With audio is identified as the self-contained recovery choice"
        ),
        .valueEquals(
          anyElement(app, "backup-choice-metadata-only"),
          "A smaller copy of your organization, edits, listening positions, and preferences. You will still need the original audio files.",
          "Metadata only makes its dependency on the original audio explicit"
        ),
        .valueEquals(
          anyElement(app, "backup-choice-automatic"),
          "Up to three safety copies stay on this iPhone. They are not portable and do not duplicate your audio.",
          "Automatic copies are distinguished from portable exports"
        ),
        .exists(app.buttons["backup-export"], "A system-destination export begins here"),
        .exists(app.buttons["backup-restore"], "A Player backup can be selected from Files"),
        .exists(
          app.buttons["e2e-backup-export"],
          "The deterministic production export action is available"),
      ]
    )

    tapWalkthroughAction("e2e-backup-export", in: app)
    try requireProbeValue(
      "backup:exported:books=1:bookmarks=1:position=42000:media=1:audio=true",
      in: app
    )
    requireBackupTopVisible(app)
    try tester.step(
      "verified-export",
      description: "A media-inclusive package preserves one checksum-verified audio payload",
      verifications: [
        .valueEquals(
          anyElement(app, "backup-e2e-probe"),
          "backup:exported:books=1:bookmarks=1:position=42000:media=1:audio=true",
          "The prepared package retains the complete catalog and exactly one managed audio file"
        )
      ]
    )

    tapWalkthroughAction("e2e-backup-clear", in: app)
    try requireProbeValue(
      "backup:cleared:books=0:bookmarks=0:position=-1:media=0:audio=false",
      in: app
    )
    requireBackupTopVisible(app)
    try tester.step(
      "cleared-library",
      description: "The fixture library and managed media are absent before restore",
      verifications: [
        .valueEquals(
          anyElement(app, "backup-e2e-probe"),
          "backup:cleared:books=0:bookmarks=0:position=-1:media=0:audio=false",
          "No catalog record or managed audio copy remains"
        )
      ]
    )

    tapWalkthroughAction("e2e-backup-restore", in: app)
    try requireProbeValue(
      "backup:restored:books=1:bookmarks=1:position=42000:media=1:audio=true",
      in: app
    )
    requireBackupTopVisible(app)
    try tester.step(
      "restored-library",
      description: "Restore returns the identical library only after integrity verification",
      verifications: [
        .valueEquals(
          anyElement(app, "backup-e2e-probe"),
          "backup:restored:books=1:bookmarks=1:position=42000:media=1:audio=true",
          "Book, bookmark, listening position, and exactly one audio file are restored"
        )
      ]
    )

    app.tabBars.buttons["Library"].tap()
    let resume = app.buttons["resume-book-a1000000-0000-0000-0000-000000000001"]
    XCTAssertTrue(resume.waitForExistence(timeout: 2))
    resume.tap()
    try requireValue(
      anyElement(app, "now-playing-screen"),
      "player:paused:a1000000-0000-0000-0000-000000000001:0:42000",
      in: app
    )
    tester.generateDocs()
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func requireBackupTopVisible(_ app: XCUIApplication) {
    let scrollView = app.scrollViews["backup-scroll"]
    XCTAssertTrue(scrollView.waitForExistence(timeout: 2))
    let heading = app.staticTexts["Protect your library"]
    let purpose = anyElement(app, "backup-purpose")
    let aligned = NSPredicate { _, _ in
      guard heading.exists, purpose.exists else { return false }
      let viewport = scrollView.frame
      let headingFrame = heading.frame
      return headingFrame.minY >= viewport.minY
        && headingFrame.maxY <= viewport.maxY
        && purpose.frame.maxY <= viewport.maxY
    }
    if aligned.evaluate(with: purpose) { return }
    let expectation = XCTNSPredicateExpectation(predicate: aligned, object: purpose)
    if XCTWaiter.wait(for: [expectation], timeout: 2) == .completed { return }
    XCTAssertTrue(
      aligned.evaluate(with: purpose),
      "The Backup heading and purpose row must be inside the visible viewport"
    )
  }

  private func tapWalkthroughAction(_ identifier: String, in app: XCUIApplication) {
    let trigger = app.buttons["e2e-trigger-\(identifier)"]
    XCTAssertTrue(trigger.waitForExistence(timeout: 2))
    let enabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: trigger
    )
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 2), .completed)
    trigger.tap()
  }

  private func requireValue(
    _ element: XCUIElement,
    _ expected: String,
    in app: XCUIApplication
  ) throws {
    guard element.waitForStringValue(expected, timeout: 2) else {
      let alert = app.alerts.firstMatch
      let alertDiagnostic =
        alert.exists
        ? "; alert=\(alert.label): \(alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))"
        : ""
      XCTFail(
        "The backup journey did not reach \(expected); actual=\(String(describing: element.value))\(alertDiagnostic)"
      )
      throw BackupUITestError.semanticStateUnavailable
    }
  }

  private func requireProbeValue(_ expected: String, in app: XCUIApplication) throws {
    let probe = anyElement(app, "backup-e2e-probe")
    guard probe.waitForStringValue(expected, timeout: 2) else {
      XCTFail(
        "The backup journey did not reach \(expected); actual=\(String(describing: probe.value))"
      )
      throw BackupUITestError.semanticStateUnavailable
    }
  }
}

private enum BackupUITestError: Error { case semanticStateUnavailable }
