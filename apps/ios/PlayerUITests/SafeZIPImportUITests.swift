import XCTest

@MainActor
final class SafeZIPImportUITests: XCTestCase {
  private let jobID = "60000000-0000-0000-0000-000000000001"

  func testRejectsHostileZIPsThenCancelsAndRetriesAValidArchive() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "ZIP imports reject unsafe entries and keep recovery actionable",
      narrative:
        "As a listener importing archives, I want Player to reject unsafe content without touching my source and help me cancel, choose another file, or retry a temporary failure.",
      fixture: "safe-zip-import",
      additionalPreconditions: [
        "Every archive and payload is deterministic, synthetic, legal test material",
        "Archive limits are 32 entries, 131,072 bytes per entry, and a 20:1 expansion ratio",
        "Central-directory safety validation runs before any archive entry is extracted",
        "Source checksums and writes outside the isolated extraction root are observed by read-only probes",
      ]
    )

    let traversalApp = try makeApplication(zipCase: "traversal")
    traversalApp.launch()
    traversalApp.buttons["choose-from-files-empty-library"].tap()
    let traversalProbe = anyElement(traversalApp, "zip-safety-probe")
    try requireValue(
      traversalProbe,
      "zip:traversal:rejected:path-traversal:entries=3:extracted=0:source-unchanged=true:outside-writes=0"
    )
    traversalApp.buttons["view-import-error-\(jobID)"].tap()
    let traversalError = anyElement(traversalApp, "import-error-screen")
    try tester.step(
      "traversal-rejected",
      description: "An escaping archive path is rejected before extraction with safe next actions",
      verifications: [
        .valueEquals(
          traversalError,
          "zip-error:path-traversal:terminal:change-selection",
          "The error identifies an unsafe path without exposing raw archive internals"
        ),
        .valueEquals(
          traversalProbe,
          "zip:traversal:rejected:path-traversal:entries=3:extracted=0:source-unchanged=true:outside-writes=0",
          "No entry was extracted, the source is unchanged, and nothing escaped staging"
        ),
        .exists(
          traversalApp.buttons["change-import-selection"],
          "The listener can choose a different archive"
        ),
        .exists(traversalApp.buttons["cancel-import"], "The listener can cancel safely"),
        .notExists(
          traversalApp.buttons["retry-import"],
          "An unchanged path-traversal archive is not offered a meaningless retry"
        ),
      ]
    )
    traversalApp.buttons["cancel-import"].tap()
    try requireValue(
      traversalProbe,
      "zip:traversal:cancelled:extracted=0:staging=0:source-unchanged=true:outside-writes=0"
    )
    terminateAndWait(traversalApp)

    let hostileCases: [(fixture: String, reason: String, entries: Int)] = [
      ("symlink", "symlink", 2),
      ("ratio", "compression-ratio", 1),
      ("count", "entry-count", 33),
      ("size", "entry-size", 1),
    ]
    for hostileCase in hostileCases {
      let app = try makeApplication(zipCase: hostileCase.fixture)
      app.launch()
      app.buttons["choose-from-files-empty-library"].tap()
      let probe = anyElement(app, "zip-safety-probe")
      try requireValue(
        probe,
        "zip:\(hostileCase.fixture):rejected:\(hostileCase.reason):entries=\(hostileCase.entries):extracted=0:source-unchanged=true:outside-writes=0"
      )
      app.buttons["view-import-error-\(jobID)"].tap()
      XCTAssertTrue(app.buttons["change-import-selection"].waitForExistence(timeout: 2))
      XCTAssertTrue(app.buttons["cancel-import"].exists)
      XCTAssertFalse(app.buttons["retry-import"].exists)
      app.buttons["cancel-import"].tap()
      try requireValue(
        probe,
        "zip:\(hostileCase.fixture):cancelled:extracted=0:staging=0:source-unchanged=true:outside-writes=0"
      )
      terminateAndWait(app)
    }

    let validApp = try makeApplication(zipCase: "valid", failInspectionOnce: true)
    validApp.launch()
    validApp.buttons["choose-from-files-empty-library"].tap()
    let validProbe = anyElement(validApp, "zip-safety-probe")
    try requireValue(
      validProbe,
      "zip:valid:failed:inspection-transient:entries=2:extracted=2:source-unchanged=true:outside-writes=0"
    )
    validApp.buttons["view-import-error-\(jobID)"].tap()
    let transientError = anyElement(validApp, "import-error-screen")
    try requireValue(transientError, "zip-error:inspection-transient:recoverable:retry")
    XCTAssertTrue(validApp.buttons["retry-import"].waitForExistence(timeout: 2))
    XCTAssertTrue(validApp.buttons["cancel-import"].exists)
    validApp.buttons["retry-import"].tap()

    try requireValue(
      validProbe,
      "zip:valid:ready:entries=2:extracted=2:books=1:source-unchanged=true:outside-writes=0"
    )
    validApp.buttons["review-import-job-\(jobID)"].tap()
    let reviewImport = anyElement(validApp, "review-import-screen")
    try tester.step(
      "retry-ready",
      description: "Retrying a temporary inspection failure produces one safe reviewable book",
      verifications: [
        .valueEquals(
          reviewImport,
          "proposal:ready:1-book:2-tracks:0-warnings",
          "Both safe archive tracks form one warning-free proposal"
        ),
        .valueEquals(
          validProbe,
          "zip:valid:ready:entries=2:extracted=2:books=1:source-unchanged=true:outside-writes=0",
          "Retry retains source integrity and never writes outside extraction staging"
        ),
        .exists(validApp.buttons["add-import-to-library"], "The safe proposal can continue"),
      ]
    )

    tester.generateDocs()
  }

  private func makeApplication(
    zipCase: String,
    failInspectionOnce: Bool = false
  ) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-reset",
      "-e2e-fixture", "safe-zip-import",
      "-e2e-zip-case", zipCase,
      "-e2e-zip-limits", "32,131072,20",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if failInspectionOnce {
      app.launchArguments.insert(contentsOf: ["-e2e-zip-fail-once", "inspection"], at: 2)
    }
    app.launchEnvironment["TZ"] = "America/Toronto"
    let fixtureName: String
    switch zipCase {
    case "valid": fixtureName = "valid-multifile"
    case "traversal": fixtureName = "path-traversal"
    case "symlink": fixtureName = "symlink-escape"
    case "ratio": fixtureName = "ratio-limit"
    case "count": fixtureName = "count-limit"
    case "size": fixtureName = "size-limit"
    default: throw SafeZIPImportTestError.unknownFixture
    }
    let fixtureURL = try XCTUnwrap(
      Bundle(for: SafeZIPImportUITests.self).url(
        forResource: fixtureName,
        withExtension: "zip"
      ),
      "The checked-in ZIP fixture must be present in the UI-test bundle"
    )
    app.launchEnvironment["PLAYER_E2E_ZIP_FIXTURE_BASE64"] =
      try Data(contentsOf: fixtureURL).base64EncodedString()
    return app
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func terminateAndWait(_ app: XCUIApplication) {
    app.terminate()
    XCTAssertTrue(
      app.wait(for: .notRunning, timeout: 2),
      "A fixture process must stop before the next launch resets its isolated storage."
    )
  }

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    // Archive inspection runs on production async paths. A cold hosted
    // simulator can remain in the observable processing state for several
    // seconds even though the same fixture completes immediately when warm.
    let deadline = Date().addingTimeInterval(10)
    var latest: String?
    repeat {
      latest = element.value as? String
      if element.exists, latest == expected { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    XCTFail(
      "The ZIP safety journey expected \(expected), latest=\(latest ?? "nil")"
    )
    throw SafeZIPImportTestError.semanticStateUnavailable
  }
}

private enum SafeZIPImportTestError: Error {
  case semanticStateUnavailable
  case unknownFixture
}
