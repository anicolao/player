import XCTest

@MainActor
final class MetadataRepairUITests: XCTestCase {
  private let jobID = "80000000-0000-0000-0000-000000000001"
  private let audioChecksum = "6c5a700ee340ace483b4cd45188403ca9a77fd60d94ba248063ee2c7fc6366f7"

  func testRepairsLocksCommitsAndUndoesMetadataWithoutChangingAudio() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = try makeApplication()
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "Metadata repair is explainable, reversible, and audio-safe",
      narrative:
        "As a listener, I want to understand proposed metadata, correct and lock it, replace its cover, and undo those changes without rewriting my audiobook audio.",
      fixture: "synthetic-metadata-repair",
      additionalPreconditions: [
        "The M4B and both covers are generated, checksum-verified legal test material",
        "All proposal values, provenance, confidence, locks, identifiers, and timestamps are fixed",
        "The source and managed audio checksums are observed from production storage",
        "No private metadata, local book, network provider, or photo library is used",
      ]
    )

    app.launch()
    app.tabBars.buttons["Inbox"].tap()
    app.buttons["review-import-job-\(jobID)"].tap()
    app.buttons["edit-metadata"].tap()

    let editor = anyElement(app, "metadata-editor-screen")
    let title = anyElement(app, "metadata-field-title")
    let authors = anyElement(app, "metadata-field-authors")
    let narrators = anyElement(app, "metadata-field-narrators")
    let series = anyElement(app, "metadata-field-series")
    let cover = anyElement(app, "metadata-cover-state")
    let integrity = anyElement(app, "metadata-integrity-probe")
    try requireValue(editor, "metadata:proposal:revision=0:dirty=false")

    try tester.step(
      "metadata-provenance",
      description: "The editor explains every proposed value before repair",
      verifications: [
        .valueEquals(
          title,
          "value=The Brass Lantern|source=embedded-tag|confidence=high|locked=false|cleared=false",
          "Title provenance and confidence are explicit"
        ),
        .valueEquals(
          authors,
          "value=Mira Sol|source=embedded-tag|confidence=high|locked=false|cleared=false",
          "Author provenance and confidence are explicit"
        ),
        .valueEquals(
          narrators,
          "value=Anika Reed|source=embedded-tag|confidence=high|locked=false|cleared=false",
          "Narrator provenance and confidence are explicit"
        ),
        .valueEquals(
          series,
          "value=Night Signals #4|source=embedded-tag|confidence=high|locked=false|cleared=false",
          "Series provenance and confidence are explicit"
        ),
        .valueEquals(
          cover,
          "cover=original|source=embedded-artwork|locked=false",
          "The embedded synthetic cover identifies its source"
        ),
        .valueEquals(
          integrity,
          "audio:source=\(audioChecksum):managed=none:source-unchanged=true",
          "Opening metadata repair does not rewrite source audio"
        ),
      ]
    )

    let titleInput = app.textFields["metadata-title-input"]
    XCTAssertTrue(titleInput.waitForExistence(timeout: 2))
    try replaceText(in: titleInput, with: "The Amber Signal", app: app)
    app.buttons["metadata-apply-title"].tap()
    try requireValue(
      title,
      "value=The Amber Signal|source=user|confidence=user|locked=true|cleared=false"
    )

    app.buttons["metadata-clear-narrators"].tap()
    try requireValue(
      narrators,
      "value=empty|source=user-clear|confidence=user|locked=true|cleared=true"
    )
    app.buttons["metadata-lock-series"].tap()
    try requireValue(
      series,
      "value=Night Signals #4|source=embedded-tag|confidence=high|locked=true|cleared=false"
    )

    app.buttons["metadata-remove-cover"].tap()
    try requireValue(cover, "cover=none|source=user-clear|locked=true")
    app.buttons["metadata-replace-cover"].tap()
    try requireValue(cover, "cover=replacement|source=user|locked=true")
    try requireValue(editor, "metadata:proposal:revision=0:dirty=true")
    try requireValue(
      integrity,
      "audio:source=\(audioChecksum):managed=none:source-unchanged=true"
    )

    app.buttons["save-metadata-repair"].tap()
    let review = anyElement(app, "review-import-screen")
    try requireValue(review, "proposal:ready:1-book:1-tracks:0-warnings:revision-5")
    app.buttons["add-import-to-library"].tap()
    // The repaired title already exists on the review screen. Wait for the
    // asynchronous commit to leave that screen before resolving the matching
    // title in Library; otherwise a fast host can tap the stale review label.
    XCTAssertTrue(review.waitForNonExistence(timeout: 10))
    let repairedBook = app.staticTexts["The Amber Signal"]
    XCTAssertTrue(repairedBook.waitForExistence(timeout: 5))
    repairedBook.tap()

    let bookMetadata = anyElement(app, "book-metadata-probe")
    let bookProvenance = anyElement(app, "book-metadata-provenance-probe")
    try tester.step(
      "repaired-book-detail",
      description: "The committed book retains the repaired values and locks",
      verifications: [
        .valueEquals(
          bookMetadata,
          "metadata:book:title=The Amber Signal:authors=1:narrators=0:series=Night Signals #4:cover=replacement:locked=title,narrators,series,cover",
          "Book Detail reflects the exact repaired metadata state"
        ),
        .valueEquals(
          bookProvenance,
          "provenance:title=user:authors=embedded-tag:narrators=user-clear:series=embedded-tag:cover=user",
          "Book Detail retains provenance after commit"
        ),
        .valueEquals(
          integrity,
          "audio:source=\(audioChecksum):managed=\(audioChecksum):source-unchanged=true",
          "Commit copied audio byte-for-byte without rewriting the source"
        ),
        .exists(app.buttons["undo-metadata-repair"], "The committed repair can be undone"),
      ]
    )

    app.buttons["undo-metadata-repair"].tap()
    try tester.step(
      "undo-restored-book-detail",
      description: "Undo restores the prior metadata and embedded cover",
      verifications: [
        .valueEquals(
          bookMetadata,
          "metadata:book:title=The Brass Lantern:authors=1:narrators=1:series=Night Signals #4:cover=original:locked=none",
          "Undo restores every previous value and lock state"
        ),
        .valueEquals(
          bookProvenance,
          "provenance:title=embedded-tag:authors=embedded-tag:narrators=embedded-tag:series=embedded-tag:cover=embedded-artwork",
          "Undo restores the original provenance"
        ),
        .valueEquals(
          integrity,
          "audio:source=\(audioChecksum):managed=\(audioChecksum):source-unchanged=true",
          "Undo changes metadata only and leaves both audio copies byte-identical"
        ),
        .notExists(app.buttons["undo-metadata-repair"], "The consumed undo action is removed"),
      ]
    )

    tester.generateDocs()
  }

  private func makeApplication() throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-reset", "-e2e-fixture", "synthetic-metadata-repair",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launchEnvironment["PLAYER_E2E_METADATA_AUDIO_BASE64"] = try fixtureData(
      resource: "metadata-repair-source",
      extension: "m4b"
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_METADATA_ORIGINAL_COVER_BASE64"] = try fixtureData(
      resource: "metadata-repair-original-cover",
      extension: "png"
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_METADATA_REPLACEMENT_COVER_BASE64"] = try fixtureData(
      resource: "metadata-repair-replacement-cover",
      extension: "png"
    ).base64EncodedString()
    return app
  }

  private func fixtureData(resource: String, extension fileExtension: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: resource, withExtension: fileExtension),
      "The checked-in synthetic metadata-repair fixture must be in the UI-test bundle"
    )
    return try Data(contentsOf: url)
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func replaceText(
    in field: XCUIElement,
    with replacement: String,
    app: XCUIApplication
  ) throws {
    for _ in 0..<3 {
      field.tap()
      XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
      field.typeKey("a", modifierFlags: .command)
      field.typeText(replacement)
      if field.waitForStringValue(replacement, timeout: 1) { return }
    }
    try requireValue(field, replacement)
  }

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    guard element.waitForStringValue(expected, timeout: 2) else {
      XCTFail(
        "The metadata-repair journey did not reach its required semantic state; actual=\(String(describing: element.value))"
      )
      throw MetadataRepairTestError.semanticStateUnavailable
    }
  }
}

private enum MetadataRepairTestError: Error {
  case semanticStateUnavailable
}
