import XCTest

@MainActor
final class BackupRestoreUITests: XCTestCase {
  private let book1 = "a1000000-0000-0000-0000-000000000001"
  private let book2 = "a1000000-0000-0000-0000-000000000002"
  private let asset1 = "a1000000-0000-0000-0000-000000000101"
  private let bookmark = "a1000000-0000-0000-0000-000000000301"
  private let collection = "a1000000-0000-0000-0000-000000000401"
  private let metadataExportOperation = "a1000000-0000-0000-0000-000000000501"
  private let mediaExportOperation = "a1000000-0000-0000-0000-000000000502"
  private let restoreOperation = "a1000000-0000-0000-0000-000000000503"

  func testExportsRestoresRejectsHostilePackagesAndRecoversDatabaseBackup() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "Backup and restore preserves a complete listening library safely",
      narrative:
        "As a listener, I want a portable backup and a trustworthy recovery path so my books, listening context, organization, and preferences survive a reset or damaged database.",
      fixture: "synthetic-backup-restore",
      additionalPreconditions: [
        "Two books, two generated managed M4Bs, progress, one bookmark, one collection, and listening preferences are deterministic invented data",
        "Metadata-only, media-inclusive, tampered, traversal, and too-new packages are generated locally and covered by one SHA-256 manifest",
        "The injected clock is fixed at 2026-08-20T13:41:00Z and the network is unused",
        "Package and managed-media checksums are asserted as booleans without exposing paths or digest values",
      ]
    )

    var app = try makeApplication(reset: true)
    app.launch()
    try assertCompleteLibrary(in: app)
    try openBackupSettings(in: app)

    app.buttons["export-backup-metadata"].tap()
    try requireValue(
      anyElement(app, "backup-export-probe"),
      "export:operation=\(metadataExportOperation):mode=metadata-only:format=1:reader=1:library-schema=14:books=2:assets=2:media-files=0:media-bytes=0:manifest-valid=true:payload-valid=true:source-unchanged=true"
    )
    app.buttons["export-backup-media"].tap()
    try requireValue(
      anyElement(app, "backup-export-probe"),
      "export:operation=\(mediaExportOperation):mode=including-media:format=1:reader=1:library-schema=14:books=2:assets=2:media-files=2:media-bytes=16922:manifest-valid=true:payload-valid=true:source-unchanged=true"
    )

    app.buttons["erase-library-data"].tap()
    let erase = app.buttons["confirm-erase-library-data"]
    XCTAssertTrue(erase.waitForExistence(timeout: 2))
    erase.tap()
    try assertEmptyLibrary(in: app)
    app.terminate()

    app = try makeApplication(reset: false, input: "last-exported-media")
    app.launch()
    try openBackupSettings(in: app)
    app.buttons["restore-backup"].tap()
    let review = anyElement(app, "restore-review-screen")
    try tester.step(
      "restore-review",
      description: "Restore review explains exactly what will replace the empty library",
      verifications: [
        .valueEquals(
          anyElement(app, "restore-review-probe"),
          "restore:operation=\(restoreOperation):mode=including-media:format=1:reader=1:library-schema=14:books=2:assets=2:bookmarks=1:collections=1:media-files=2:media-bytes=16922:conflicts=0:strategy=replace-library:validated=true",
          "The validated package exposes exact library and media scope before mutation"
        ),
        .exists(review, "The restore review is visible"),
        .exists(app.buttons["restore-replace-library"], "Replace Library is explicit"),
        .notExists(
          app.buttons["confirm-restore-replace-library"],
          "Replacement confirmation is not bypassed"
        ),
      ]
    )
    app.buttons["restore-replace-library"].tap()
    let confirmRestore = app.buttons["confirm-restore-replace-library"]
    XCTAssertTrue(confirmRestore.waitForExistence(timeout: 2))
    confirmRestore.tap()
    try requireValue(
      anyElement(app, "restore-result-probe"),
      "restore:completed:operation=\(restoreOperation):books=2:assets=2:bookmarks=1:collections=1:managed-files=2:managed-bytes=16922:checksums-valid=true"
    )
    try assertCompleteLibrary(in: app)
    try assertRestoredBookmarkAndCollection(in: app)
    app.terminate()

    let durable = try makeApplication(reset: false)
    durable.launch()
    try assertCompleteLibrary(in: durable)
    durable.terminate()

    try assertRejected(
      input: "tampered",
      expected:
        "restore-error:code=checksum-mismatch:recoverable=true:library-unchanged=true:managed-unchanged=true:source-unchanged=true"
    )
    try assertRejected(
      input: "traversal",
      expected:
        "restore-error:code=unsafe-path:recoverable=false:library-unchanged=true:managed-unchanged=true:source-unchanged=true"
    )
    try assertRejected(
      input: "too-new",
      expected:
        "restore-error:code=library-schema-too-new:supported=14:found=999:recoverable=false:library-unchanged=true:managed-unchanged=true:source-unchanged=true"
    )

    let recovered = try makeApplication(reset: false, damagePrimaryDatabase: true)
    recovered.launch()
    try requireValue(
      anyElement(recovered, "database-recovery-probe"),
      "database-recovery:recovered=true:generation=1:books=2:assets=2:source=automatic:primary-replaced=true:managed-checksums-valid=true"
    )
    XCTAssertTrue(anyElement(recovered, "database-recovery-banner").exists)
    XCTAssertTrue(recovered.buttons["dismiss-database-recovery"].exists)
    try assertCompleteLibrary(in: recovered)
    tester.generateDocs()
  }

  private func assertCompleteLibrary(in app: XCUIApplication) throws {
    try requireValue(
      anyElement(app, "backup-library-probe"),
      "library:books=2:order=\(book1),\(book2):assets=2:current=\(book1):up-next=\(book1),\(book2)"
    )
    try requireValue(
      anyElement(app, "backup-metadata-probe"),
      "metadata:positions=\(book1)@45000,\(book2)@120000:finished=\(book2):bookmarks=\(bookmark)@\(book1)@42000:collections=\(collection)(\(book2),\(book1))"
    )
    try requireValue(
      anyElement(app, "backup-settings-probe"),
      "settings:rate=1.25:back=15:forward=30:rewind=true:rewind-max=20:fade=true:view=list"
    )
    try requireValue(
      anyElement(app, "backup-integrity-probe"),
      "integrity:managed-files=2:managed-bytes=16922:checksums-valid=true:package-sources-unchanged=true"
    )
  }

  private func assertEmptyLibrary(in app: XCUIApplication) throws {
    try requireValue(
      anyElement(app, "backup-library-probe"),
      "library:books=0:order=none:assets=0:current=none:up-next=none"
    )
    try requireValue(
      anyElement(app, "backup-metadata-probe"),
      "metadata:positions=none:finished=none:bookmarks=none:collections=none"
    )
    try requireValue(
      anyElement(app, "backup-integrity-probe"),
      "integrity:managed-files=0:managed-bytes=0:checksums-valid=true:package-sources-unchanged=true"
    )
  }

  private func assertRestoredBookmarkAndCollection(in app: XCUIApplication) throws {
    app.buttons["Library"].tap()
    app.buttons["browse-all-books"].tap()
    let firstBook = app.buttons["all-books-book-\(book1)"]
    XCTAssertTrue(firstBook.waitForExistence(timeout: 2))
    firstBook.tap()
    app.buttons["bookmarks-segment"].tap()
    try requireValue(
      anyElement(app, "bookmark-row-\(bookmark)"),
      "book=\(book1)|asset=\(asset1)|chapter=none|bookMs=42000|assetMs=42000|label=Opening Signal · 0:42|note=Return to the quiet clue."
    )
    navigateBack(app)
    navigateBack(app)
    app.buttons["browse-collections"].tap()
    let collectionRow = app.buttons["collection-\(collection)"]
    XCTAssertTrue(collectionRow.waitForExistence(timeout: 2))
    collectionRow.tap()
    try requireValue(
      anyElement(app, "collection-probe"),
      "collection:\(collection):name=Weekend Signals:count=2:order=\(book2),\(book1)"
    )
  }

  private func assertRejected(input: String, expected: String) throws {
    let app = try makeApplication(reset: false, input: input)
    app.launch()
    try openBackupSettings(in: app)
    app.buttons["restore-backup"].tap()
    XCTAssertTrue(anyElement(app, "backup-error-screen").waitForExistence(timeout: 2))
    try requireValue(anyElement(app, "backup-error-probe"), expected)
    XCTAssertTrue(app.buttons["choose-another-backup"].exists)
    XCTAssertTrue(app.buttons["cancel-backup-restore"].exists)
    try assertCompleteLibrary(in: app)
    app.terminate()
  }

  private func openBackupSettings(in app: XCUIApplication) throws {
    let settings = app.buttons["Settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 2))
    settings.tap()
    let backup = app.buttons["settings-backup-restore"]
    XCTAssertTrue(backup.waitForExistence(timeout: 2))
    backup.tap()
    XCTAssertTrue(anyElement(app, "backup-restore-screen").waitForExistence(timeout: 2))
  }

  private func makeApplication(
    reset: Bool,
    input: String? = nil,
    damagePrimaryDatabase: Bool = false
  ) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "synthetic-backup-restore",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset { app.launchArguments.insert("-e2e-reset", at: 1) }
    if let input {
      app.launchArguments.insert(contentsOf: ["-e2e-backup-input", input], at: 2)
    }
    if damagePrimaryDatabase {
      app.launchArguments.insert("-e2e-damage-primary-database", at: 2)
    }
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launchEnvironment["PLAYER_E2E_BACKUP_DESCRIPTOR_BASE64"] = try fixtureData(
      resource: "synthetic-backup-restore-fixture", extension: "json"
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_BACKUP_AUDIO_BASE64"] = try fixtureData(
      resource: "backup-restore-audio", extension: "m4b"
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_BACKUP_METADATA_PACKAGE_BASE64"] = try fixtureData(
      resource: "known-good-metadata", extension: "playerbackup"
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_BACKUP_MEDIA_PACKAGE_BASE64"] = try fixtureData(
      resource: "known-good-media", extension: "playerbackup"
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_BACKUP_TAMPERED_PACKAGE_BASE64"] = try fixtureData(
      resource: "tampered-media", extension: "playerbackup"
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_BACKUP_TRAVERSAL_PACKAGE_BASE64"] = try fixtureData(
      resource: "path-traversal", extension: "playerbackup"
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_BACKUP_TOO_NEW_PACKAGE_BASE64"] = try fixtureData(
      resource: "too-new-schema", extension: "playerbackup"
    ).base64EncodedString()
    return app
  }

  private func fixtureData(resource: String, extension fileExtension: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: resource, withExtension: fileExtension),
      "The generated synthetic backup/restore fixture must be in the UI-test bundle"
    )
    return try Data(contentsOf: url)
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func navigateBack(_ app: XCUIApplication) {
    let back = app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(back.waitForExistence(timeout: 2))
    back.tap()
  }

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    let predicate = NSPredicate(format: "value == %@", expected)
    let result = XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
      timeout: 3
    )
    guard result == .completed else {
      let latest = element.value.map(String.init(describing:)) ?? "nil"
      XCTFail("Expected \(element.identifier) value \(expected), latest=\(latest)")
      throw BackupRestoreTestError.semanticStateUnavailable
    }
  }
}

private enum BackupRestoreTestError: Error {
  case semanticStateUnavailable
}
