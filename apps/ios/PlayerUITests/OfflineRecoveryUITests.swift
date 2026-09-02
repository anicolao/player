import XCTest

@MainActor
final class OfflineRecoveryUITests: PlayerUITestCase {
  func testRecoversStartupAndExportsOnlySanitizedOfflineDiagnostics() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = bookshelfApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "offline-recovery", "-e2e-reset",
      "-e2e-start-section", "settings",
      "-e2e-start-settings-route", "diagnostics",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launchEnvironment["PLAYER_E2E_DYNAMIC_TYPE"] = "medium"
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "A damaged offline library recovers without exposing private data",
      narrative:
        "As a listener, I want Bookshelf to preserve a damaged catalog, recover the latest valid copy, reconcile interrupted storage, and create a support report that contains no audiobook identity or listening history.",
      fixture: "offline-recovery",
      additionalPreconditions: [
        "The primary catalog is corrupt and one rotating automatic copy is valid",
        "One app-owned managed-media directory, staging job, and trash transaction are absent from the catalog",
        "The fixture embeds forbidden private strings across title, contributor, bookmark, filename, and checksum fields",
        "No network interface or remote service is used by the recovery or diagnostic path",
      ]
    )
    app.launch()

    let recoveryProbe = anyElement(app, "startup-recovery-probe")
    let expectedRecovery =
      "recovery:unreadable-library:valid=1:invalid=0:preserved=true"
    XCTAssertTrue(recoveryProbe.waitForStringValue(expectedRecovery, timeout: 2))
    try tester.step(
      "startup-recovery",
      description: "A corrupt catalog opens a truthful recovery screen instead of terminating",
      verifications: [
        .valueEquals(
          recoveryProbe,
          expectedRecovery,
          "The primary remains preserved and one independently validated local copy is offered"
        ),
        .exists(
          app.buttons["startup-recovery-restore"],
          "Recovery is explicit and does not silently replace the primary catalog"
        ),
        .exists(
          app.buttons["startup-recovery-diagnostics"],
          "A sanitized support report remains available before recovery"
        ),
      ],
      captureReadiness: offlineCaptureReadiness(
        app: app,
        specification:
          "At capture, the exact preserved recovery state is laid out with every recovery choice fully visible and no working indicator or transient presentation",
        anchor: recoveryProbe
      ) {
        self.hasExactValue(recoveryProbe, expectedRecovery)
          && elementIsFullyVisible(
            app.staticTexts["Your library needs recovery"],
            within: app.windows.element,
            requiresHittable: false
          )
          && elementIsFullyVisible(
            app.buttons["startup-recovery-restore"],
            within: app.windows.element
          )
          && elementIsFullyVisible(
            app.buttons["startup-recovery-diagnostics"],
            within: app.windows.element
          )
          && elementIsFullyVisible(
            app.buttons["startup-recovery-fresh"],
            within: app.windows.element
          )
          && app.progressIndicators.count == 0
      }
    )

    let diagnosticsProbe = anyElement(app, "diagnostics-probe")
    try tapRecoveryAction("startup-recovery-restore", in: app)
    let restoreDeadline = EventDeadline()
    XCTAssertTrue(
      waitForPredicate(
        NSPredicate(
          format: "exists == true AND value == %@",
          "diagnostics:sanitized=true:offline=true:quarantined=3"
        ),
        on: diagnosticsProbe,
        timeout: restoreDeadline.remaining
      )
    )
    try tester.step(
      "reconciled-offline-library",
      description: "The valid library returns and unowned app directories move to quarantine",
      verifications: [
        .valueEquals(
          diagnosticsProbe,
          "diagnostics:sanitized=true:offline=true:quarantined=3",
          "Managed, staging, and trash ownership is reconciled from IDs without filename guesses"
        ),
        .exists(
          app.buttons["diagnostics-export"],
          "The recovered library can create a sanitized support bundle"
        ),
      ],
      captureReadiness: offlineCaptureReadiness(
        app: app,
        specification:
          "At capture, the exact reconciled offline diagnostics are fully laid out with the quarantined count and export action visible and idle",
        anchor: diagnosticsProbe
      ) {
        self.hasExactValue(
          diagnosticsProbe,
          "diagnostics:sanitized=true:offline=true:quarantined=3"
        )
          && elementIsFullyVisible(
            app.staticTexts["Core library works without Internet"],
            within: app.windows.element,
            requiresHittable: false
          )
          && elementIsFullyVisible(
            app.staticTexts["Quarantined app-owned items"],
            within: app.windows.element,
            requiresHittable: false
          )
          && elementIsFullyVisible(
            app.buttons["diagnostics-export"],
            within: app.windows.element
          )
          && app.progressIndicators.count == 0
      }
    )

    let verify = app.buttons["e2e-verify-diagnostics"]
    XCTAssertTrue(verify.waitForExistence(timeout: 2))
    let sanitizedProbe = anyElement(app, "offline-recovery-diagnostics-probe")
    let expectedSanitized =
      "diagnostics:sanitized=true:forbidden=absent:offline=true:quarantined=3"
    let completed = NSPredicate(
      format: "exists == true AND value == %@",
      expectedSanitized
    )
    let verificationFinished = DarwinEventReceipt(
      name: namespacedE2EEvent(
        "com.spnss.player.e2e.support-verification-finished",
        for: app
      )
    )
    XCTAssertNotNil(verificationFinished)
    XCTAssertTrue(
      deliverPhysicalActionAcknowledgedByDisabling(
        verify,
        until: sanitizedProbe,
        satisfies: completed,
        in: app
      ),
      "Verify sanitized support bundle did not acknowledge delivery within two seconds"
    )
    XCTAssertTrue(
      verificationFinished?.wait(timeout: 2) == true,
      "Sanitized support bundle verification did not finish within two seconds of delivery"
    )
    XCTAssertTrue(
      waitForPredicate(completed, on: sanitizedProbe, timeout: EventDeadline().remaining),
      "Sanitized support bundle did not publish its completion receipt within two seconds"
    )
    try tester.step(
      "sanitized-support-bundle",
      description:
        "The exported report proves offline readiness with allowlisted aggregate facts only",
      verifications: [
        .valueEquals(
          sanitizedProbe,
          expectedSanitized,
          "Title, contributor, bookmark text, filename, checksum, path, secret, and listening history are absent"
        )
      ],
      captureReadiness: offlineCaptureReadiness(
        app: app,
        specification:
          "At capture, the verified allowlisted diagnostics remain in the same settled offline layout with no exporter, progress, or system presentation",
        anchor: sanitizedProbe
      ) {
        self.hasExactValue(sanitizedProbe, expectedSanitized)
          && self.hasExactValue(
            diagnosticsProbe,
            "diagnostics:sanitized=true:offline=true:quarantined=3"
          )
          && elementIsFullyVisible(
            app.buttons["diagnostics-export"],
            within: app.windows.element
          )
          && app.progressIndicators.count == 0
      }
    )

    XCTAssertTrue(terminateAndWait(app))
    try proveEveryRecoveryChoice()
    tester.generateDocs()
  }

  private func proveEveryRecoveryChoice() throws {
    try proveRetrySuccess(scenario: "retry-succeeds", issue: "unreadable-library")
    try proveRetrySuccess(scenario: "storage-unavailable", issue: "storage-unavailable")
    try proveRetryRemainsFailedWithoutMutation()
    try proveFreshLibraryPreservesRecoveryMaterial()
    try proveDistinctRecoveryExplanations()
    try proveLaunchStorageRetry()
    try proveSupportBundleExportOutcomes()
  }

  private func proveRetrySuccess(scenario: String, issue: String) throws {
    let app = launchRecoveryApp(scenario: scenario)
    let recovery = anyElement(app, "startup-recovery-probe")
    XCTAssertTrue(
      recovery.waitForStringValue(
        "recovery:\(issue):valid=0:invalid=0:preserved=true",
        timeout: 2
      )
    )
    app.buttons["startup-recovery-retry"].tap()
    XCTAssertTrue(
      anyElement(app, "diagnostics-probe").waitForStringValue(
        "diagnostics:sanitized=true:offline=true:quarantined=3",
        timeout: 2
      )
    )
    XCTAssertTrue(terminateAndWait(app))
  }

  private func proveRetryRemainsFailedWithoutMutation() throws {
    let app = launchRecoveryApp(scenario: "retry-remains-failed")
    let evidence = anyElement(app, "offline-recovery-action-probe")
    let expected =
      "recovery-evidence:primary=corrupt:catalog=0:orphans=0:audio=true:"
      + "files=0:prepared=0:revision=0"
    XCTAssertTrue(evidence.waitForStringValue(expected, timeout: 2))
    app.buttons["startup-recovery-retry"].tap()
    let action = anyElement(app, "startup-recovery-action-state")
    XCTAssertTrue(action.waitForStringValue("retry-failed", timeout: 2))
    let alert = app.alerts["Couldn’t Restore Library"]
    XCTAssertTrue(alert.waitForExistence(timeout: 2))
    XCTAssertTrue(
      exactStaticText(
        alert,
        label:
          "Bookshelf still cannot open this library. No library files were changed; you can try again, export a support bundle, or choose another recovery option."
      ).exists
    )
    alert.buttons["OK"].tap()
    XCTAssertTrue(evidence.waitForStringValue(expected, timeout: 2))
    XCTAssertTrue(terminateAndWait(app))
  }

  private func proveFreshLibraryPreservesRecoveryMaterial() throws {
    let app = launchRecoveryApp(scenario: "fresh-library")
    app.buttons["startup-recovery-fresh"].tap()
    let confirmation = app.buttons["Preserve Old Database and Start Fresh"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
    confirmation.tap()
    XCTAssertTrue(
      anyElement(app, "diagnostics-probe").waitForStringValue(
        "diagnostics:sanitized=true:offline=true:quarantined=4",
        timeout: 2
      )
    )
    XCTAssertTrue(
      anyElement(app, "offline-recovery-action-probe").waitForStringValue(
        "recovery-evidence:primary=readable:catalog=1:orphans=4:audio=true:"
          + "files=0:prepared=0:revision=0",
        timeout: 2
      )
    )
    XCTAssertTrue(terminateAndWait(app))
  }

  private func proveDistinctRecoveryExplanations() throws {
    let corrupt = launchRecoveryApp(scenario: "retry-remains-failed")
    XCTAssertTrue(
      exactStaticText(
        corrupt,
        label:
          "Bookshelf could not validate the local catalog. Your audio and every recovery copy remain untouched."
      ).waitForExistence(timeout: 2)
    )
    XCTAssertTrue(terminateAndWait(corrupt))

    let newer = launchRecoveryApp(scenario: "newer-schema")
    XCTAssertTrue(
      exactStaticText(
        newer,
        label:
          "This catalog was written by a newer Bookshelf version. Reinstall that version or restore a compatible local copy."
      ).waitForExistence(timeout: 2)
    )
    XCTAssertTrue(
      anyElement(newer, "startup-recovery-probe").waitForStringValue(
        "recovery:newer-library-version:valid=0:invalid=0:preserved=true",
        timeout: 2
      )
    )
    XCTAssertTrue(terminateAndWait(newer))

    let unavailable = launchRecoveryApp(scenario: "storage-unavailable")
    XCTAssertTrue(
      exactStaticText(
        unavailable,
        label:
          "Bookshelf cannot currently reach its protected local storage. This does not mean the catalog is damaged; unlock storage and try again."
      ).waitForExistence(timeout: 2)
    )
    XCTAssertTrue(terminateAndWait(unavailable))
  }

  private func proveLaunchStorageRetry() throws {
    let app = launchRecoveryApp(
      scenario: "launch-storage-retry",
      expectsRecoveryPresentation: false
    )
    XCTAssertTrue(
      exactStaticText(
        app,
        label:
          "Bookshelf could not reach its private local folder. No library files were changed."
      ).waitForExistence(timeout: 2)
    )
    app.buttons["Try Again"].tap()
    XCTAssertTrue(
      anyElement(app, "diagnostics-probe").waitForStringValue(
        "diagnostics:sanitized=true:offline=true:quarantined=3",
        timeout: 2
      )
    )
    XCTAssertTrue(terminateAndWait(app))
  }

  private func proveSupportBundleExportOutcomes() throws {
    var app = launchRecoveryApp(scenario: "support-export")
    try tapRecoveryAction("startup-recovery-diagnostics", in: app)
    XCTAssertTrue(
      anyElement(app, "startup-recovery-action-state").waitForStringValue(
        "awaiting-files",
        timeout: 2
      )
    )
    XCTAssertTrue(app.buttons["e2e-files-save-support-bundle"].waitForExistence(timeout: 2))
    app.buttons["e2e-files-save-support-bundle"].tap()
    XCTAssertTrue(
      anyElement(app, "startup-recovery-action-state").waitForStringValue(
        "support-saved",
        timeout: 2
      )
    )
    XCTAssertTrue(
      app.staticTexts["startup-recovery-support-export-result"].waitForExistence(timeout: 2)
    )
    XCTAssertTrue(
      anyElement(app, "offline-recovery-action-probe").waitForStringValue(
        "recovery-evidence:primary=corrupt:catalog=0:orphans=0:audio=true:"
          + "files=1:prepared=0:revision=2",
        timeout: 2
      )
    )
    XCTAssertTrue(terminateAndWait(app))

    app = launchRecoveryApp(scenario: "support-export")
    try tapRecoveryAction("startup-recovery-diagnostics", in: app)
    XCTAssertTrue(
      anyElement(app, "startup-recovery-action-state").waitForStringValue(
        "awaiting-files",
        timeout: 2
      )
    )
    XCTAssertTrue(app.buttons["e2e-files-cancel-support-bundle"].waitForExistence(timeout: 2))
    app.buttons["e2e-files-cancel-support-bundle"].tap()
    XCTAssertTrue(
      anyElement(app, "startup-recovery-action-state").waitForStringValue(
        "support-cancelled",
        timeout: 2
      )
    )
    XCTAssertTrue(
      anyElement(app, "offline-recovery-action-probe").waitForStringValue(
        "recovery-evidence:primary=corrupt:catalog=0:orphans=0:audio=true:"
          + "files=0:prepared=0:revision=1",
        timeout: 2
      )
    )
    XCTAssertTrue(terminateAndWait(app))

    app = launchRecoveryApp(scenario: "support-preparation-fails")
    try tapRecoveryAction("startup-recovery-diagnostics", in: app)
    let alert = app.alerts["Couldn’t Create Support Bundle"]
    XCTAssertTrue(alert.waitForExistence(timeout: 2))
    XCTAssertTrue(
      exactStaticText(
        alert,
        label:
          "The deterministic support report could not be written to local storage."
      ).exists
    )
    XCTAssertTrue(
      anyElement(app, "startup-recovery-action-state").waitForStringValue(
        "support-preparation-failed",
        timeout: 2
      )
    )
    XCTAssertTrue(terminateAndWait(app))
  }

  private func tapRecoveryAction(
    _ identifier: String,
    in app: XCUIApplication
  ) throws {
    let action = app.buttons[identifier]
    XCTAssertTrue(action.waitForExistence(timeout: 2))
    let actionFrame = action.frame
    let appFrame = app.frame
    guard action.isEnabled,
      actionFrame.width >= 44,
      actionFrame.height >= 44,
      !appFrame.isEmpty,
      appFrame.contains(actionFrame)
    else {
      XCTFail("Expected recovery action \(identifier) to be an enabled 44-point target")
      throw OfflineRecoveryTestError.semanticStateUnavailable
    }
    let coordinate = action.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
    )
    guard performPhysicalInteractionWithoutPostEventQuiescence(
      in: app,
      { coordinate.tap() }
    ) else {
      XCTFail("The pinned XCTest runtime did not expose bounded recovery-action synthesis")
      throw OfflineRecoveryTestError.semanticStateUnavailable
    }
  }

  private func launchRecoveryApp(
    scenario: String,
    expectsRecoveryPresentation: Bool = true
  ) -> XCUIApplication {
    let app = bookshelfApplication()
    let presentationReceipt = expectsRecoveryPresentation
      ? DarwinEventReceipt(
        name: namespacedE2EEvent(
          "com.spnss.player.e2e.startup-recovery-presented",
          for: app
        )
      )
      : nil
    if expectsRecoveryPresentation {
      XCTAssertNotNil(presentationReceipt)
    }
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "offline-recovery", "-e2e-reset",
      "-e2e-offline-recovery-scenario", scenario,
      "-e2e-start-section", "settings",
      "-e2e-start-settings-route", "diagnostics",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launchEnvironment["PLAYER_E2E_DYNAMIC_TYPE"] = "medium"
    app.launch()
    if expectsRecoveryPresentation {
      XCTAssertTrue(
        presentationReceipt?.wait(timeout: 2) == true,
        "Expected the production startup-recovery surface within two seconds of launch"
      )
    }
    return app
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    uniquelyIdentifiedElement(app, identifier)
  }

  private func exactStaticText(_ container: XCUIElement, label: String) -> XCUIElement {
    container.staticTexts.matching(NSPredicate(format: "label == %@", label)).element
  }

  private func exactStaticText(_ app: XCUIApplication, label: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label == %@", label)).element
  }

  private func offlineCaptureReadiness(
    app: XCUIApplication,
    specification: String,
    anchor: XCUIElement,
    checkNow: @escaping @MainActor () -> Bool
  ) -> CaptureReadiness {
    CaptureReadiness(specification: specification, anchor: anchor) {
      checkNow()
        && app.keyboards.count == 0
        && app.alerts.count == 0
        && app.sheets.count == 0
    }
  }

  private func hasExactValue(_ element: XCUIElement, _ expected: String) -> Bool {
    element.exists && element.value.map(String.init(describing:)) == expected
  }
}

private enum OfflineRecoveryTestError: Error {
  case semanticStateUnavailable
}
