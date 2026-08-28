import XCTest

@MainActor
final class ImportRecoveryStorageUITests: XCTestCase {
  private let lowSpaceJobID = "61000000-0000-0000-0000-000000000001"
  private let mixedJobID = "61000000-0000-0000-0000-000000000002"
  private let stagingJobID = "61000000-0000-0000-0000-000000000003"
  private let validFileID = "61000000-0000-0000-0000-000000000101"
  private let corruptFileID = "61000000-0000-0000-0000-000000000102"
  private let unsupportedFileID = "61000000-0000-0000-0000-000000000103"
  private let selectionDuplicateFileID = "61000000-0000-0000-0000-000000000104"
  private let libraryDuplicateFileID = "61000000-0000-0000-0000-000000000105"
  private let existingBookID = "61000000-0000-0000-0000-000000000201"

  func testRecoversMixedImportsAndExplainsStorageWithoutTouchingSources() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let tester = TestStepHelper(testCase: self, startIndex: 2)
    tester.setMetadata(
      title: "Import recovery keeps every source safe and makes storage actionable",
      narrative:
        "As a listener importing a messy selection, I want Player to explain each problem, preserve the usable files, and show exactly what storage I can safely reclaim.",
      fixture: "import-recovery-storage",
      additionalPreconditions: [
        "All filenames, checksums, byte counts, and library records are deterministic synthetic fixtures",
        "The low-space preflight requires 8,700 bytes with 8,192 available until 768 bytes of orphan staging is cleared",
        "The mixed selection contains valid, transiently corrupt, unsupported, selection-duplicate, and library-duplicate files",
        "Every source checksum is observed before and after production retry, remove, cancel, and commit boundaries",
      ]
    )

    try proveLowSpaceRecoveryAndStorage(tester: tester)
    try proveMixedPartialRecovery()
    try proveCancelPreservesAllCorruptSources()
    tester.generateDocs()
  }

  private func proveLowSpaceRecoveryAndStorage(tester: TestStepHelper) throws {
    let app = makeApplication(scenario: "low-space")
    app.launch()
    openInbox(app)
    app.buttons["view-import-error-\(lowSpaceJobID)"].tap()

    try requireValue(
      anyElement(app, "import-recovery-screen"),
      "recovery:job=\(lowSpaceJobID):phase=failedRecoverable:accepted=1:duplicates=0:failed=0:global=insufficient-storage:continue=false:source-unchanged=true"
    )
    try requireValue(
      anyElement(app, "import-storage-issue"),
      "required=8700:available=8192:source-unchanged=true"
    )
    XCTAssertTrue(app.buttons["free-import-storage"].exists)
    XCTAssertTrue(app.buttons["change-import-selection"].exists)
    XCTAssertTrue(app.buttons["cancel-import"].exists)

    app.buttons["Settings"].tap()
    XCTAssertTrue(app.buttons["settings-storage"].waitForExistence(timeout: 2))
    app.buttons["settings-storage"].tap()
    let storage = anyElement(app, "storage-screen")
    let expectedStorage =
      "storage:used=5632:managed=4096:staging=768:trash=512:database=256:available=8192:reclaimable=1280:books=1"
    let storageBook = anyElement(app, "storage-book-\(existingBookID)")
    let clearStaging = app.buttons["clear-staging-\(stagingJobID)"]
    try tester.step(
      "storage-recovery",
      description: "Settings shows what Player uses and what can be reclaimed safely",
      verifications: [
        .valueEquals(
          storage,
          expectedStorage,
          "Managed, staging, trash, database, available, and reclaimable bytes are exact"
        ),
        .valueEquals(
          storageBook,
          "book=\(existingBookID):bytes=4096:files=2",
          "Per-book managed usage is visible without exposing private metadata"
        ),
        .exists(
          clearStaging,
          "Recoverable orphan staging has an explicit cleanup action"
        ),
        .notExists(
          app.buttons["clear-managed-\(existingBookID)"],
          "Managed book media cannot be cleared from the recoverable-storage surface"
        ),
        .notExists(
          app.buttons["clear-storage-database"],
          "The library database cannot be cleared from the recoverable-storage surface"
        ),
      ],
      captureReadiness: recoveryCaptureReadiness(
        app: app,
        specification: "At capture, the exact storage accounting, per-book usage, and safe staging cleanup are fully visible while managed media/database cleanup remains unavailable",
        anchor: storage
      ) {
        self.hasExactValue(storage, expectedStorage)
          && self.hasExactValue(
            storageBook,
            "book=\(self.existingBookID):bytes=4096:files=2"
          )
          && elementIsFullyVisible(storageBook, within: storage, requiresHittable: false)
          && elementIsFullyVisible(clearStaging, within: storage)
          && !app.buttons["clear-managed-\(self.existingBookID)"].exists
          && !app.buttons["clear-storage-database"].exists
      }
    )

    app.buttons["clear-staging-\(stagingJobID)"].tap()
    try requireValue(
      storage,
      "storage:used=4864:managed=4096:staging=0:trash=512:database=256:available=8960:reclaimable=512:books=1"
    )
    try requireValue(
      anyElement(app, "import-recovery-integrity-probe"),
      "scenario=low-space:source-unchanged=true:staging-cleared=768:managed-unchanged=true:database-unchanged=true"
    )

    navigateBack(app, label: "Settings", destination: app.buttons["settings-storage"])
    app.buttons["Inbox"].tap()
    try requireValue(
      anyElement(app, "import-recovery-screen"),
      "recovery:job=\(lowSpaceJobID):phase=failedRecoverable:accepted=1:duplicates=0:failed=0:global=insufficient-storage:continue=false:source-unchanged=true"
    )
    XCTAssertTrue(app.buttons["retry-import"].waitForExistence(timeout: 2))
    app.buttons["retry-import"].tap()
    try requireValue(
      anyElement(app, "import-recovery-probe"),
      "scenario=low-space:job=\(lowSpaceJobID):phase=ready:accepted=1:source-unchanged=true"
    )
    XCTAssertTrue(terminateAndWait(app))
  }

  private func proveMixedPartialRecovery() throws {
    let app = makeApplication(scenario: "mixed")
    app.launch()
    openInbox(app)
    app.buttons["review-import-job-\(mixedJobID)"].tap()

    let screen = anyElement(app, "import-recovery-screen")
    try requireValue(
      screen,
      "recovery:job=\(mixedJobID):phase=needsReview:accepted=1:duplicates=2:failed=2:global=none:continue=true:source-unchanged=true"
    )
    try requireValue(
      anyElement(app, "recovery-file-\(validFileID)"),
      "file=\(validFileID):disposition=accepted:issue=none:recoverable=false:actions=none:source-unchanged=true"
    )
    try requireValue(
      anyElement(app, "recovery-file-\(corruptFileID)"),
      "file=\(corruptFileID):disposition=failed:issue=corrupt-audio:recoverable=true:actions=retryFile,removeFile,changeSelection:source-unchanged=true"
    )
    try requireValue(
      anyElement(app, "recovery-file-\(unsupportedFileID)"),
      "file=\(unsupportedFileID):disposition=failed:issue=unsupported-format:recoverable=false:actions=removeFile,changeSelection:source-unchanged=true"
    )
    try requireValue(
      anyElement(app, "recovery-file-\(selectionDuplicateFileID)"),
      "file=\(selectionDuplicateFileID):disposition=duplicate:issue=duplicate-in-selection:recoverable=false:actions=removeFile,changeSelection:source-unchanged=true"
    )
    try requireValue(
      anyElement(app, "recovery-file-\(libraryDuplicateFileID)"),
      "file=\(libraryDuplicateFileID):disposition=duplicate:issue=duplicate-in-library:recoverable=false:actions=openExistingBook,removeFile,changeSelection:source-unchanged=true"
    )

    app.buttons["retry-import-file-\(corruptFileID)"].tap()
    try requireValue(
      screen,
      "recovery:job=\(mixedJobID):phase=needsReview:accepted=2:duplicates=2:failed=1:global=none:continue=true:source-unchanged=true"
    )
    app.buttons["remove-import-file-\(unsupportedFileID)"].tap()
    try requireValue(
      screen,
      "recovery:job=\(mixedJobID):phase=needsReview:accepted=2:duplicates=2:failed=0:global=none:continue=true:source-unchanged=true"
    )

    app.buttons["open-existing-book-\(libraryDuplicateFileID)"].tap()
    try requireValue(
      anyElement(app, "book-detail-screen"),
      "book:ready:\(existingBookID):1-chapters:m4b"
    )
    navigateBack(
      app,
      label: "Review Import",
      destination: anyElement(app, "import-recovery-screen")
    )

    app.buttons["continue-partial-import"].tap()
    try requireValue(
      anyElement(app, "review-import-screen"),
      "proposal:ready:1-book:2-tracks:0-warnings"
    )
    try requireValue(
      anyElement(app, "import-recovery-integrity-probe"),
      "scenario=mixed:accepted=2:excluded=3:managed-duplicates=0:source-unchanged=true:order=\(validFileID),\(corruptFileID)"
    )
    XCTAssertTrue(app.buttons["add-import-to-library"].exists)
    XCTAssertTrue(terminateAndWait(app))
  }

  private func proveCancelPreservesAllCorruptSources() throws {
    let app = makeApplication(scenario: "all-corrupt")
    app.launch()
    openInbox(app)
    app.buttons["view-import-error-\(mixedJobID)"].tap()
    try requireValue(
      anyElement(app, "import-recovery-screen"),
      "recovery:job=\(mixedJobID):phase=failedRecoverable:accepted=0:duplicates=0:failed=2:global=none:continue=false:source-unchanged=true"
    )
    XCTAssertTrue(app.buttons["retry-import-file-\(corruptFileID)"].exists)
    XCTAssertTrue(app.buttons["cancel-import"].exists)
    app.buttons["cancel-import"].tap()
    try requireValue(
      anyElement(app, "import-recovery-probe"),
      "scenario=all-corrupt:job=\(mixedJobID):phase=cancelled:staging=0:sources=2:source-unchanged=true"
    )
  }

  private func makeApplication(scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-reset",
      "-e2e-fixture", "import-recovery-storage",
      "-e2e-recovery-scenario", scenario,
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func openInbox(_ app: XCUIApplication) {
    let inbox = app.buttons["Inbox"]
    XCTAssertTrue(inbox.waitForExistence(timeout: 2))
    inbox.tap()
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    uniquelyIdentifiedElement(app, identifier)
  }

  private func recoveryCaptureReadiness(
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

  private func navigateBack(
    _ app: XCUIApplication,
    label: String,
    destination: XCUIElement
  ) {
    let back = app.navigationBars.buttons[label]
    XCTAssertTrue(back.waitForExistence(timeout: 2))
    back.tap()
    XCTAssertTrue(
      destination.waitForExistence(timeout: 2),
      "Expected Back to \(label) to reveal \(destination.identifier)"
    )
  }

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    guard element.waitForStringValue(expected, timeout: 2) else {
      let latest = element.value.map(String.init(describing:)) ?? "nil"
      XCTFail("Expected \(element.identifier) value \(expected), latest=\(latest)")
      throw ImportRecoveryStorageTestError.semanticStateUnavailable
    }
  }
}

private enum ImportRecoveryStorageTestError: Error {
  case semanticStateUnavailable
}
