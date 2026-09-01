import XCTest

@MainActor
final class SafeZIPImportUITests: PlayerUITestCase {
  private let jobID = "60000000-0000-0000-0000-000000000001"

  func testRejectsHostileZIPsThenCancelsAndRetriesAValidArchive() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "ZIP imports reject unsafe entries and keep recovery actionable",
      narrative:
        "As a listener importing archives, I want Bookshelf to reject unsafe content without touching my source and help me cancel, choose another file, or retry a temporary failure.",
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
    let traversalProbe = anyElement(traversalApp, "zip-safety-probe")
    try requireZipSelectionDelivery(
      in: traversalApp,
      probe: traversalProbe,
      zipCase: "traversal",
      expected:
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
      ],
      captureReadiness: zipCaptureReadiness(
        app: traversalApp,
        specification: "At capture, the exact terminal path-traversal failure and zero-extraction safety evidence are settled with both valid recovery actions visible and no retry or transient presentation",
        anchor: traversalError
      ) {
        self.hasExactValue(
          traversalError,
          "zip-error:path-traversal:terminal:change-selection"
        )
          && self.hasExactValue(
            traversalProbe,
            "zip:traversal:rejected:path-traversal:entries=3:extracted=0:source-unchanged=true:outside-writes=0"
          )
          && elementIsFullyVisible(
            traversalApp.staticTexts["This archive wasn’t imported"],
            within: traversalError,
            requiresHittable: false
          )
          && elementIsFullyVisible(
            traversalApp.buttons["change-import-selection"],
            within: traversalError
          )
          && elementIsFullyVisible(
            traversalApp.buttons["cancel-import"],
            within: traversalError
          )
          && !traversalApp.buttons["retry-import"].exists
      }
    )
    traversalApp.buttons["cancel-import"].tap()
    try requireValue(
      traversalProbe,
      "zip:traversal:cancelled:extracted=0:staging=0:source-unchanged=true:outside-writes=0"
    )
    XCTAssertTrue(terminateAndWait(traversalApp))

    let hostileCases: [(fixture: String, reason: String, entries: Int)] = [
      ("symlink", "symlink", 2),
      ("ratio", "compression-ratio", 1),
      ("count", "entry-count", 33),
      ("size", "entry-size", 1),
    ]
    for hostileCase in hostileCases {
      let app = try makeApplication(zipCase: hostileCase.fixture)
      app.launch()
      let probe = anyElement(app, "zip-safety-probe")
      try requireZipSelectionDelivery(
        in: app,
        probe: probe,
        zipCase: hostileCase.fixture,
        expected:
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
      XCTAssertTrue(terminateAndWait(app))
    }

    let validApp = try makeApplication(zipCase: "valid", failInspectionOnce: true)
    validApp.launch()
    let validProbe = anyElement(validApp, "zip-safety-probe")
    try requireZipSelectionDelivery(
      in: validApp,
      probe: validProbe,
      zipCase: "valid",
      expected:
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
    let reviewScrollReadiness = anyElement(validApp, "review-import-scroll-readiness")
    let addToLibrary = validApp.buttons["add-import-to-library"]
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
        .exists(addToLibrary, "The safe proposal can continue"),
      ],
      captureReadiness: zipCaptureReadiness(
        app: validApp,
        specification: "At capture, the exact warning-free two-track proposal is idle at the top with placeholder artwork, review metadata, and pinned Add action fully visible",
        anchor: reviewScrollReadiness
      ) {
        self.hasExactValue(
          reviewImport,
          "proposal:ready:1-book:2-tracks:0-warnings"
        )
          && self.hasExactValue(
            validProbe,
            "zip:valid:ready:entries=2:extracted=2:books=1:source-unchanged=true:outside-writes=0"
          )
          && self.hasSettledAtTop(
            reviewScrollReadiness,
            containerID: "review-import-scroll"
          )
          && elementIsFullyVisible(
            validApp.descendants(matching: .any)["placeholder-artwork"],
            within: reviewImport,
            requiresHittable: false
          )
          && elementIsFullyVisible(
            validApp.staticTexts["Safe Signals"],
            within: reviewImport,
            requiresHittable: false
          )
          && elementIsFullyVisible(addToLibrary, within: reviewImport)
      }
    )

    tester.generateDocs()
  }

  private func makeApplication(
    zipCase: String,
    failInspectionOnce: Bool = false
  ) throws -> XCUIApplication {
    let app = bookshelfApplication()
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

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    guard element.waitForStringValue(expected, timeout: 2) else {
      XCTFail(
        "The ZIP safety journey expected \(expected), latest=\(String(describing: element.value))"
      )
      throw SafeZIPImportTestError.semanticStateUnavailable
    }
  }

  /// Delivers the injected Files selection against an exact origin state and
  /// requires its independently published terminal ZIP receipt. The deadline
  /// starts after synthesis. A missed gesture may be redelivered only while
  /// the same Library button, screen, and idle safety probe remain unchanged.
  private func requireZipSelectionDelivery(
    in app: XCUIApplication,
    probe: XCUIElement,
    zipCase: String,
    expected: String
  ) throws {
    let action = app.buttons["choose-from-files-empty-library"]
    let library = app.descendants(matching: .any)["library-screen"]
    let idle =
      "zip:\(zipCase):idle:entries=0:extracted=0:source-unchanged=true:outside-writes=0"
    let completion = NSPredicate(format: "exists == true AND value == %@", expected)
    if completion.evaluate(with: probe) { return }

    let interactiveOrigin = NSPredicate { _, _ in
      guard app.state == .runningForeground,
        action.exists,
        action.isEnabled,
        action.isHittable,
        library.exists,
        library.value.map(String.init(describing:)) == "ready:library-empty",
        probe.exists,
        probe.value.map(String.init(describing:)) == idle
      else { return false }
      let appFrame = app.frame
      let actionFrame = action.frame
      return !appFrame.isEmpty
        && !actionFrame.isEmpty
        && appFrame.contains(actionFrame)
    }
    guard waitForPredicate(interactiveOrigin, on: action, timeout: 2) else {
      XCTFail("The ZIP selection origin did not become foreground-interactive for \(zipCase)")
      throw SafeZIPImportTestError.semanticStateUnavailable
    }

    let appFrame = app.frame
    let actionFrame = action.frame
    let coordinate = app.coordinate(
      withNormalizedOffset: CGVector(
        dx: (actionFrame.midX - appFrame.minX) / appFrame.width,
        dy: (actionFrame.midY - appFrame.minY) / appFrame.height
      )
    )
    var deliveryDeadline: EventDeadline?

    repeat {
      if completion.evaluate(with: probe) { return }
      if let deliveryDeadline {
        let exactOriginRemains = interactiveOrigin.evaluate(with: action)
          && action.frame == actionFrame
        if !exactOriginRemains {
          if waitForPredicate(completion, on: probe, timeout: deliveryDeadline.remaining) {
            return
          }
          break
        }
        if deliveryDeadline.remaining <= 0 { break }
      }

      guard performPhysicalInteractionWithoutPostEventQuiescence(
        in: app,
        { coordinate.tap() }
      ) else {
        XCTFail("The pinned XCTest runtime could not synthesize ZIP selection")
        throw SafeZIPImportTestError.semanticStateUnavailable
      }
      if deliveryDeadline == nil { deliveryDeadline = EventDeadline() }
      guard let deliveryDeadline else {
        throw SafeZIPImportTestError.semanticStateUnavailable
      }
      if waitForPredicate(
        completion,
        on: probe,
        timeout: min(0.25, deliveryDeadline.remaining)
      ) { return }
    } while (deliveryDeadline?.remaining ?? 0) > 0

    XCTFail(
      "The ZIP selection for \(zipCase) did not publish \(expected), "
        + "latest=\(String(describing: probe.value))"
    )
    throw SafeZIPImportTestError.semanticStateUnavailable
  }

  private func zipCaptureReadiness(
    app: XCUIApplication,
    specification: String,
    anchor: XCUIElement,
    checkNow: @escaping @MainActor () -> Bool
  ) -> CaptureReadiness {
    CaptureReadiness(specification: specification, anchor: anchor) {
      checkNow()
        && !app.keyboards.firstMatch.exists
        && !app.alerts.firstMatch.exists
        && !app.sheets.firstMatch.exists
        && !app.menus.firstMatch.exists
    }
  }

  private func hasExactValue(_ element: XCUIElement, _ expected: String) -> Bool {
    element.exists && element.value.map(String.init(describing:)) == expected
  }

  private func hasSettledAtTop(_ probe: XCUIElement, containerID: String) -> Bool {
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
      && state.atTop
  }
}

private enum SafeZIPImportTestError: Error {
  case semanticStateUnavailable
  case unknownFixture
}
