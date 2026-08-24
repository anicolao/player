import XCTest

@MainActor
final class BackupUITests: XCTestCase {
  func testExportsClearsAndRestoresAVerifiedPortableLibrary() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e-fixture", "portable-backup", "-e2e-reset",
      "-e2e-start-section", "settings",
      "-e2e-start-settings-route", "backup",
    ]
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

    let probe = anyElement(app, "backup-e2e-probe")
    scrollBackupToTop(app)
    try tester.step(
      "backup-settings",
      description: "Backup choices explain portable media and local automatic copies",
      verifications: [
        .exists(app.buttons["backup-export"], "A system-destination export begins here"),
        .exists(app.buttons["backup-restore"], "A Player backup can be selected from Files"),
        .exists(
          app.buttons["e2e-backup-export"],
          "The deterministic production export action is available"),
      ]
    )

    tapWalkthroughAction("e2e-backup-export", in: app)
    try requireValue(
      probe,
      "backup:exported:books=1:bookmarks=1:position=42000:media=1:audio=true",
      in: app
    )
    scrollBackupToTop(app)
    try tester.step(
      "verified-export",
      description: "A media-inclusive package preserves one checksum-verified audio payload",
      verifications: [
        .valueEquals(
          probe,
          "backup:exported:books=1:bookmarks=1:position=42000:media=1:audio=true",
          "The prepared package retains the complete catalog and exactly one managed audio file"
        )
      ]
    )

    tapWalkthroughAction("e2e-backup-clear", in: app)
    try requireValue(
      probe,
      "backup:cleared:books=0:bookmarks=0:position=-1:media=0:audio=false",
      in: app
    )
    scrollBackupToTop(app)
    try tester.step(
      "cleared-library",
      description: "The fixture library and managed media are absent before restore",
      verifications: [
        .valueEquals(
          probe,
          "backup:cleared:books=0:bookmarks=0:position=-1:media=0:audio=false",
          "No catalog record or managed audio copy remains"
        )
      ]
    )

    tapWalkthroughAction("e2e-backup-restore", in: app)
    try requireValue(
      probe,
      "backup:restored:books=1:bookmarks=1:position=42000:media=1:audio=true",
      in: app
    )
    scrollBackupToTop(app)
    try tester.step(
      "restored-library",
      description: "Restore returns the identical library only after integrity verification",
      verifications: [
        .valueEquals(
          probe,
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

  private func scrollBackupToTop(_ app: XCUIApplication) {
    let list = app.collectionViews.firstMatch
    XCTAssertTrue(list.waitForExistence(timeout: 2))
    let export = app.buttons["backup-export"]
    // The E2E build anchors this List programmatically after launch and every
    // fixture mutation. Gestures at SwiftUI's elastic boundary settle at
    // host-dependent offsets and cannot define a canonical screenshot.
    XCTAssertTrue(export.isHittable)
    // Let the initial navigation hierarchy finish rasterizing before capture.
    RunLoop.current.run(until: Date().addingTimeInterval(3))
  }

  private func tapWalkthroughAction(_ identifier: String, in app: XCUIApplication) {
    let list = app.collectionViews.firstMatch
    XCTAssertTrue(list.waitForExistence(timeout: 2))
    for _ in 0..<3 { list.swipeUp(velocity: .fast) }
    let button = app.buttons[identifier]
    XCTAssertTrue(button.waitForExistence(timeout: 2))
    button.tap()
  }

  private func requireValue(
    _ element: XCUIElement,
    _ expected: String,
    in app: XCUIApplication
  ) throws {
    guard element.waitForStringValue(expected, timeout: 3) else {
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
}

private enum BackupUITestError: Error { case semanticStateUnavailable }
