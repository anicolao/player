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
        "The production Export and Restore buttons drive deterministic adapters only at the otherwise unavailable Files boundary",
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
        .exists(app.buttons["backup-restore"], "A Bookshelf backup can be selected from Files"),
      ],
      captureReadiness: backupCaptureReadiness(
        app,
        expectedProbe:
          "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=true:files=0:kind=none:payloads=0:prepared=0",
        specification:
          "At capture, the verified one-book library and production backup choices are idle at the top with no transient UI"
      )
    )

    tapProductionAction("backup-export", in: app)
    try requireOperation("awaiting-files-includingMedia", in: app)
    let save = app.buttons["e2e-files-save-backup"]
    XCTAssertTrue(save.waitForExistence(timeout: 2))
    save.tap()
    try requireOperation("succeeded-export-includingMedia", in: app)
    try requireProbeValue(
      "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=true:files=1:kind=includingMedia:payloads=1:prepared=0",
      in: app
    )
    requireBackupTopVisible(app)
    try tester.step(
      "verified-export",
      description: "A media-inclusive package preserves one checksum-verified audio payload",
      verifications: [
        .valueEquals(
          anyElement(app, "backup-e2e-probe"),
          "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=true:files=1:kind=includingMedia:payloads=1:prepared=0",
          "The prepared package retains the complete catalog and exactly one managed audio file"
        )
      ],
      captureReadiness: backupCaptureReadiness(
        app,
        expectedProbe:
          "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=true:files=1:kind=includingMedia:payloads=1:prepared=0",
        specification:
          "At capture, the checksum-verified portable export and unchanged source library are settled at the top with no transient UI"
      )
    )

    tapWalkthroughAction("e2e-fixture-clear-library", in: app)
    try requireProbeValue(
      "backup:books=0:bookmarks=0:position=-1:media=0:audio=false:catalog=false:files=1:kind=includingMedia:payloads=1:prepared=0",
      in: app
    )
    requireBackupTopVisible(app)
    try tester.step(
      "cleared-library",
      description: "The fixture library and managed media are absent before restore",
      verifications: [
        .valueEquals(
          anyElement(app, "backup-e2e-probe"),
          "backup:books=0:bookmarks=0:position=-1:media=0:audio=false:catalog=false:files=1:kind=includingMedia:payloads=1:prepared=0",
          "No catalog record or managed audio copy remains"
        )
      ],
      captureReadiness: backupCaptureReadiness(
        app,
        expectedProbe:
          "backup:books=0:bookmarks=0:position=-1:media=0:audio=false:catalog=false:files=1:kind=includingMedia:payloads=1:prepared=0",
        specification:
          "At capture, the cleared catalog and absent managed audio are settled at the top with no transient UI"
      )
    )

    tapProductionAction("backup-restore", in: app)
    try requireOperation("awaiting-restore-selection", in: app)
    let selectedBackup = app.buttons["e2e-files-select-backup"]
    XCTAssertTrue(selectedBackup.waitForExistence(timeout: 2))
    selectedBackup.tap()
    let restore = app.buttons["Restore Backup"].firstMatch
    XCTAssertTrue(restore.waitForExistence(timeout: 2))
    restore.tap()
    try requireOperation("succeeded-portable-restore", in: app)
    try requireProbeValue(
      "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=true:files=1:kind=includingMedia:payloads=1:prepared=0",
      in: app
    )
    requireBackupTopVisible(app)
    try tester.step(
      "restored-library",
      description: "Restore returns the identical library only after integrity verification",
      verifications: [
        .valueEquals(
          anyElement(app, "backup-e2e-probe"),
          "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=true:files=1:kind=includingMedia:payloads=1:prepared=0",
          "Book, bookmark, listening position, and exactly one audio file are restored"
        )
      ],
      captureReadiness: backupCaptureReadiness(
        app,
        expectedProbe:
          "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=true:files=1:kind=includingMedia:payloads=1:prepared=0",
        specification:
          "At capture, the integrity-verified catalog, position, bookmark, and one managed audio file are restored and settled at the top with no transient UI"
      )
    )

    tapWalkthroughAction("e2e-fixture-replace-catalog", in: app)
    try requireProbeValue(
      "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=false:files=1:kind=includingMedia:payloads=1:prepared=0",
      in: app
    )
    let automaticRestore = app.buttons["backup-restore-automatic"]
    revealBackupAction(automaticRestore, in: app)
    automaticRestore.tap()
    try requireOperation("confirming-automatic-restore", in: app)
    let cancelAutomatic = app.buttons["backup-cancel-automatic-restore"].firstMatch
    XCTAssertTrue(cancelAutomatic.waitForExistence(timeout: 2))
    cancelAutomatic.tap()
    try requireOperation("cancelled", in: app)
    try requireProbeValue(
      "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=false:files=1:kind=includingMedia:payloads=1:prepared=0",
      in: app
    )

    revealBackupAction(automaticRestore, in: app)
    automaticRestore.tap()
    try requireOperation("confirming-automatic-restore", in: app)
    let confirmAutomatic = app.buttons["Restore Database"].firstMatch
    XCTAssertTrue(confirmAutomatic.waitForExistence(timeout: 2))
    confirmAutomatic.tap()
    try requireOperation("succeeded-automatic-restore", in: app)
    try requireProbeValue(
      "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=true:files=1:kind=includingMedia:payloads=1:prepared=0",
      in: app
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

  func testProductionBackupCancellationKindsAndFailuresPreserveTheLibrary() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = launchBackupFixture()
    let original =
      "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=true:files=0:kind=none:payloads=0:prepared=0"
    try requireProbeValue(original, in: app)

    tapProductionAction("backup-export", in: app)
    try requireOperation("awaiting-files-includingMedia", in: app)
    let cancelExport = app.buttons["e2e-files-cancel-export"]
    XCTAssertTrue(cancelExport.waitForExistence(timeout: 2))
    cancelExport.tap()
    try requireOperation("cancelled", in: app)
    try requireProbeValue(original, in: app)

    tapProductionAction("backup-export", in: app)
    try requireOperation("awaiting-files-includingMedia", in: app)
    let failExport = app.buttons["e2e-files-fail-export"]
    XCTAssertTrue(failExport.waitForExistence(timeout: 2))
    failExport.tap()
    try requireOperation("failed-export", in: app)
    try requireProbeValue(original, in: app)
    dismissBackupAlert(in: app)

    selectExportKind("Metadata only", in: app)
    tapProductionAction("backup-export", in: app)
    try requireOperation("awaiting-files-metadataOnly", in: app)
    let save = app.buttons["e2e-files-save-backup"]
    XCTAssertTrue(save.waitForExistence(timeout: 2))
    save.tap()
    try requireOperation("succeeded-export-metadataOnly", in: app)
    let metadataExport =
      "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=true:files=1:kind=metadataOnly:payloads=0:prepared=0"
    try requireProbeValue(metadataExport, in: app)

    tapProductionAction("backup-restore", in: app)
    try requireOperation("awaiting-restore-selection", in: app)
    let cancelSelection = app.buttons["e2e-files-cancel-restore"]
    XCTAssertTrue(cancelSelection.waitForExistence(timeout: 2))
    cancelSelection.tap()
    try requireOperation("cancelled", in: app)
    try requireProbeValue(metadataExport, in: app)

    tapProductionAction("backup-restore", in: app)
    try requireOperation("awaiting-restore-selection", in: app)
    let selectBackup = app.buttons["e2e-files-select-backup"]
    XCTAssertTrue(selectBackup.waitForExistence(timeout: 2))
    selectBackup.tap()
    try requireOperation("confirming-portable-restore", in: app)
    let cancelRestore = app.buttons["backup-cancel-portable-restore"].firstMatch
    XCTAssertTrue(cancelRestore.waitForExistence(timeout: 2))
    cancelRestore.tap()
    try requireOperation("cancelled", in: app)
    try requireProbeValue(metadataExport, in: app)

    selectExportKind("With audio", in: app)
    tapProductionAction("backup-export", in: app)
    try requireOperation("awaiting-files-includingMedia", in: app)
    XCTAssertTrue(save.waitForExistence(timeout: 2))
    save.tap()
    try requireOperation("succeeded-export-includingMedia", in: app)
    let mediaExport =
      "backup:books=1:bookmarks=1:position=42000:media=1:audio=true:catalog=true:files=1:kind=includingMedia:payloads=1:prepared=0"
    try requireProbeValue(mediaExport, in: app)

    try assertRejectedRestore(
      selectionIdentifier: "e2e-files-select-tampered-backup",
      unchangedProbe: mediaExport,
      in: app
    )
    try assertRejectedRestore(
      selectionIdentifier: "e2e-files-select-incompatible-backup",
      unchangedProbe: mediaExport,
      in: app
    )
  }

  private func launchBackupFixture() -> XCUIApplication {
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
    app.launch()
    requireBackupTopVisible(app)
    return app
  }

  private func selectExportKind(_ label: String, in app: XCUIApplication) {
    let picker = app.buttons["backup-export-kind"]
    XCTAssertTrue(picker.waitForExistence(timeout: 2))
    if !picker.label.contains(label) {
      picker.tap()
      let choice = app.buttons[label]
      XCTAssertTrue(choice.waitForExistence(timeout: 2))
      choice.tap()
    }
    XCTAssertTrue(
      waitForPredicate(NSPredicate(format: "label CONTAINS %@", label), on: picker),
      "The visible Backup contents picker must select \(label)"
    )
  }

  private func assertRejectedRestore(
    selectionIdentifier: String,
    unchangedProbe: String,
    in app: XCUIApplication
  ) throws {
    tapProductionAction("backup-restore", in: app)
    try requireOperation("awaiting-restore-selection", in: app)
    let selection = app.buttons[selectionIdentifier]
    XCTAssertTrue(selection.waitForExistence(timeout: 2))
    selection.tap()
    try requireOperation("confirming-portable-restore", in: app)
    let restore = app.buttons["Restore Backup"].firstMatch
    XCTAssertTrue(restore.waitForExistence(timeout: 2))
    restore.tap()
    try requireOperation("failed-restore", in: app)
    try requireProbeValue(unchangedProbe, in: app)
    dismissBackupAlert(in: app)
  }

  private func dismissBackupAlert(in app: XCUIApplication) {
    let alert = app.alerts.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 2))
    XCTAssertFalse(alert.label.isEmpty)
    let dismiss = alert.buttons["OK"]
    XCTAssertTrue(dismiss.waitForExistence(timeout: 2))
    dismiss.tap()
    XCTAssertTrue(
      waitForPredicate(NSPredicate(format: "exists == false"), on: alert),
      "The backup error must dismiss after acknowledging it"
    )
  }

  private func revealBackupAction(_ element: XCUIElement, in app: XCUIApplication) {
    let scroll = app.scrollViews["backup-scroll"]
    let surface = ScrollSurface(
      application: app,
      container: scroll,
      readiness: anyElement(app, "backup-scroll-readiness"),
      containerID: "backup-scroll",
      axis: .vertical,
      permitsGeometrySettledFallback: true
    )
    XCTAssertTrue(element.waitForExistence(timeout: 2))
    XCTAssertTrue(
      scrollUntil(
        { element.isHittable },
        on: surface,
        deadline: EventDeadline(),
        direction: .towardEnd,
        terminalEndpoint: \.atBottom
      ) {
        upwardDrag(in: scroll, velocity: .fast)
      },
      "The requested Backup action must scroll into view"
    )
  }

  private func upwardDrag(in element: XCUIElement, velocity: XCUIGestureVelocity) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.72))
      .press(
        forDuration: 0.05,
        thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.28)),
        withVelocity: velocity,
        thenHoldForDuration: 0
      )
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func backupCaptureReadiness(
    _ app: XCUIApplication,
    expectedProbe: String,
    specification: String
  ) -> CaptureReadiness {
    let scroll = app.scrollViews["backup-scroll"]
    let readiness = anyElement(app, "backup-scroll-readiness")
    let probe = anyElement(app, "backup-e2e-probe")
    let heading = app.staticTexts["Protect your library"]
    let purpose = anyElement(app, "backup-purpose")
    return CaptureReadiness(specification: specification, anchor: probe) {
      guard let state = ScrollReadinessState(readiness.value) else { return false }
      return probe.exists
        && probe.value.map(String.init(describing:)) == expectedProbe
        && state.containerID == "backup-scroll"
        && state.axis == .vertical
        && state.isIdle
        && state.atTop
        && elementIsFullyVisible(heading, within: scroll, requiresHittable: false)
        && elementIsFullyVisible(purpose, within: scroll, requiresHittable: false)
        && !app.keyboards.firstMatch.exists
        && !app.alerts.firstMatch.exists
        && !app.sheets.firstMatch.exists
    }
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
    XCTAssertTrue(
      waitForPredicate(aligned, on: purpose),
      "The Backup heading and purpose row must be inside the visible viewport"
    )
  }

  private func tapWalkthroughAction(_ identifier: String, in app: XCUIApplication) {
    let trigger = app.buttons["e2e-trigger-\(identifier)"]
    XCTAssertTrue(trigger.waitForExistence(timeout: 2))
    XCTAssertTrue(
      waitForPredicate(NSPredicate(format: "enabled == true"), on: trigger),
      "Expected \(identifier) to become enabled"
    )
    trigger.tap()
  }

  private func tapProductionAction(_ identifier: String, in app: XCUIApplication) {
    let button = app.buttons[identifier]
    XCTAssertTrue(button.waitForExistence(timeout: 2))
    XCTAssertTrue(
      waitForPredicate(NSPredicate(format: "enabled == true"), on: button),
      "Expected production action \(identifier) to become enabled"
    )
    guard identifier == "backup-export" else {
      button.tap()
      return
    }
    let operation = anyElement(app, "backup-operation-state")
    XCTAssertTrue(operation.waitForExistence(timeout: 2))
    guard let initialOperation = operation.value as? String else {
      XCTFail("Expected the backup operation probe to publish a string token")
      return
    }
    let operationChanged = NSPredicate(
      format: "exists == true AND value != %@", initialOperation
    )
    let deliveryDeadline = EventDeadline()
    repeat {
      let buttonFrame = button.frame
      let appFrame = app.frame
      guard buttonFrame.width >= 44,
        buttonFrame.height >= 44,
        !appFrame.isEmpty,
        appFrame.contains(buttonFrame)
      else {
        XCTFail("Expected production action \(identifier) to be a visible 44-point target")
        return
      }
      let coordinate = app.coordinate(
        withNormalizedOffset: CGVector(
          dx: (buttonFrame.midX - appFrame.minX) / appFrame.width,
          dy: (buttonFrame.midY - appFrame.minY) / appFrame.height
        )
      )
      guard performPhysicalInteractionWithoutPostEventQuiescence(
        in: app,
        { coordinate.tap() }
      ) else {
        XCTFail("The pinned XCTest runtime did not expose bounded physical synthesis")
        return
      }
      if waitForPredicate(
        operationChanged,
        on: operation,
        timeout: min(0.25, deliveryDeadline.remaining)
      ) {
        return
      }
    } while deliveryDeadline.remaining > 0

    XCTFail(
      "Production action \(identifier) did not publish a state transition; "
        + "actual=\(String(describing: operation.value))"
    )
  }

  private func requireOperation(_ expected: String, in app: XCUIApplication) throws {
    try requireValue(anyElement(app, "backup-operation-state"), expected, in: app)
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
