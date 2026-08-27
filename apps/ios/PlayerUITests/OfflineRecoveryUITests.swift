import XCTest

@MainActor
final class OfflineRecoveryUITests: XCTestCase {
  func testRecoversStartupAndExportsOnlySanitizedOfflineDiagnostics() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
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
        "As a listener, I want Player to preserve a damaged catalog, recover the latest valid copy, reconcile interrupted storage, and create a support report that contains no audiobook identity or listening history.",
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
      ]
    )

    app.buttons["startup-recovery-restore"].tap()
    let settingsDiagnostics = app.buttons["settings-diagnostics"]
    if settingsDiagnostics.waitForExistence(timeout: 2) {
      settingsDiagnostics.tap()
    }
    let diagnosticsProbe = anyElement(app, "diagnostics-probe")
    XCTAssertTrue(
      diagnosticsProbe.waitForStringValue(
        "diagnostics:sanitized=true:offline=true:quarantined=3",
        timeout: 2
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
      ]
    )

    let verify = app.buttons["e2e-verify-diagnostics"]
    XCTAssertTrue(verify.waitForExistence(timeout: 2))
    verify.tap()
    let sanitizedProbe = anyElement(app, "offline-recovery-diagnostics-probe")
    let expectedSanitized =
      "diagnostics:sanitized=true:forbidden=absent:offline=true:quarantined=3"
    XCTAssertTrue(sanitizedProbe.waitForStringValue(expectedSanitized, timeout: 2))
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
      ]
    )
    tester.generateDocs()
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
