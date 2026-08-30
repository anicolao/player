import XCTest

@MainActor
final class MetadataRepairUITests: PlayerUITestCase {
  private let jobID = "80000000-0000-0000-0000-000000000001"
  private let audioChecksum = "6c5a700ee340ace483b4cd45188403ca9a77fd60d94ba248063ee2c7fc6366f7"

  func testRepairsLocksCommitsAndUndoesMetadataWithoutChangingAudio() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    var app = try makeApplication()
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
    let title = anyElement(app, "metadata-provenance-title")
    let authors = anyElement(app, "metadata-provenance-authors")
    let narrators = anyElement(app, "metadata-provenance-narrators")
    let series = anyElement(app, "metadata-provenance-seriesName")
    let cover = anyElement(app, "metadata-cover-state")
    let coverSelection = anyElement(app, "metadata-cover-selection-state")
    let integrity = anyElement(app, "metadata-integrity-probe")
    let editorScroll = anyElement(app, "metadata-editor-scroll")
    let editorReadiness = anyElement(app, "metadata-editor-scroll-readiness")
    let editorArtwork = editor.descendants(matching: .any)["embedded-cover-artwork"]
    let titleInput = app.textFields["metadata-field-title"]
    try requireValue(
      editor,
      "metadata:proposal:revision=0:dirty=false:saving=false:validation=valid"
    )

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
      ],
      captureReadiness: CaptureReadiness(
        specification:
          "At capture, the exact proposal provenance and integrity state are rendered at the settled top of the editor with decoded artwork and no transient UI",
        anchor: editorReadiness
      ) {
        guard let state = ScrollReadinessState(editorReadiness.value) else { return false }
        return state.containerID == "metadata-editor-scroll"
          && state.axis == .vertical
          && state.isIdle
          && state.atTop
          && self.hasExactValue(
            editor,
            "metadata:proposal:revision=0:dirty=false:saving=false:validation=valid"
          )
          && self.hasExactValue(
            title,
            "value=The Brass Lantern|source=embedded-tag|confidence=high|locked=false|cleared=false"
          )
          && self.hasExactValue(
            authors,
            "value=Mira Sol|source=embedded-tag|confidence=high|locked=false|cleared=false"
          )
          && self.hasExactValue(
            narrators,
            "value=Anika Reed|source=embedded-tag|confidence=high|locked=false|cleared=false"
          )
          && self.hasExactValue(
            series,
            "value=Night Signals #4|source=embedded-tag|confidence=high|locked=false|cleared=false"
          )
          && self.hasExactValue(
            cover,
            "cover=original|source=embedded-artwork|locked=false"
          )
          && self.hasExactValue(
            integrity,
            "audio:source=\(self.audioChecksum):managed=none:source-unchanged=true"
          )
          && elementIsFullyVisible(
            editorArtwork,
            within: editorScroll,
            requiresHittable: false
          )
          && elementIsFullyVisible(titleInput, within: editorScroll)
          && self.hasNoTransientUI(app)
      }
    )

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

    // Cancellation is an observable completed provider outcome, not a delay.
    // It must preserve the original cover and every unrelated draft edit.
    app.buttons["metadata-replace-cover"].tap()
    let choosePhoto = app.buttons["Choose Photo"]
    XCTAssertTrue(choosePhoto.waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["Choose File"].exists)
    choosePhoto.tap()
    try requireValue(coverSelection, "revision=1:outcome=cancelled-photoLibrary")
    try requireValue(cover, "cover=original|source=embedded-artwork|locked=false")
    try requireValue(
      title,
      "value=The Amber Signal|source=user|confidence=user|locked=true|cleared=false"
    )
    try requireValue(
      narrators,
      "value=empty|source=user-clear|confidence=user|locked=true|cleared=true"
    )
    try requireValue(
      series,
      "value=Night Signals #4|source=embedded-tag|confidence=high|locked=true|cleared=false"
    )
    XCTAssertFalse(app.alerts.firstMatch.exists)

    // A provider failure is metadata-editor-owned, actionable, and equally
    // transactional: the cover and unrelated draft fields remain unchanged.
    app.buttons["metadata-replace-cover"].tap()
    let chooseFile = app.buttons["Choose File"]
    XCTAssertTrue(chooseFile.waitForExistence(timeout: 2))
    chooseFile.tap()
    try requireValue(coverSelection, "revision=2:outcome=failed-file")
    let coverFailure = app.alerts["Couldn’t Save Details"]
    XCTAssertTrue(coverFailure.waitForExistence(timeout: 2))
    XCTAssertTrue(coverFailure.staticTexts[
      "The selected cover is stored in iCloud and is not downloaded. Download it in Files or choose another image, then try again."
    ].exists)
    try requireValue(cover, "cover=original|source=embedded-artwork|locked=false")
    try requireValue(
      title,
      "value=The Amber Signal|source=user|confidence=user|locked=true|cleared=false"
    )
    try requireValue(
      narrators,
      "value=empty|source=user-clear|confidence=user|locked=true|cleared=true"
    )
    coverFailure.buttons["OK"].tap()
    XCTAssertTrue(coverFailure.waitForNonExistence(timeout: 2))

    app.buttons["metadata-remove-cover"].tap()
    try requireValue(cover, "cover=none|source=user-clear|locked=true")
    app.buttons["metadata-replace-cover"].tap()
    XCTAssertTrue(choosePhoto.waitForExistence(timeout: 2))
    choosePhoto.tap()
    try requireValue(coverSelection, "revision=3:outcome=selected-photoLibrary")
    try requireValue(cover, "cover=replacement|source=user|locked=true")
    app.buttons["metadata-replace-cover"].tap()
    let cropButton = app.buttons["Crop"]
    XCTAssertTrue(cropButton.waitForExistence(timeout: 2))
    cropButton.tap()
    let cropPreview = anyElement(app, "metadata-crop-preview-state")
    let cropZoom = app.sliders["metadata-crop-zoom"]
    let cropHorizontal = app.sliders["metadata-crop-horizontal"]
    let cropArtwork = anyElement(app, "metadata-crop-preview-artwork")
    XCTAssertTrue(cropZoom.waitForExistence(timeout: 2))
    XCTAssertTrue(cropHorizontal.waitForExistence(timeout: 2))
    let zoomedCrop = "preview=x:0.250:y:0.250:width:0.500:height:0.500:rotation:0.0"
    try adjust(
      cropZoom,
      toNormalizedPosition: 1,
      until: cropPreview,
      hasValue: zoomedCrop
    )
    let expectedCrop = "x:0.500:y:0.250:width:0.500:height:0.500:rotation:0.0"
    try adjust(
      cropHorizontal,
      toNormalizedPosition: 1,
      until: cropPreview,
      hasValue: "preview=\(expectedCrop)"
    )

    try tester.step(
      "cropped-cover-preview",
      description: "Crop previews a visibly different region of the retained original cover",
      verifications: [
        .valueEquals(
          cropPreview,
          "preview=\(expectedCrop)",
          "The crop preview reflects the exact zoom and focal point"
        ),
        .exists(cropArtwork, "The decoded cropped artwork preview is visible"),
      ],
      captureReadiness: CaptureReadiness(
        specification:
          "At capture, the exact half-size crop is rendered from the asymmetric replacement cover and the crop controls are settled",
        anchor: cropPreview
      ) {
        self.hasExactValue(cropPreview, "preview=\(expectedCrop)")
          && cropArtwork.exists
          && cropZoom.exists
          && cropHorizontal.exists
          && !app.keyboards.firstMatch.exists
          && !app.alerts.firstMatch.exists
      }
    )

    app.buttons["metadata-apply-crop"].tap()
    let cropState = anyElement(app, "metadata-crop-state")
    try requireValue(cropState, "crop=\(expectedCrop)")
    try requireValue(
      editor,
      "metadata:proposal:revision=0:dirty=true:saving=false:validation=valid"
    )
    try requireValue(
      integrity,
      "audio:source=\(audioChecksum):managed=none:source-unchanged=true"
    )

    app.buttons["metadata-save"].tap()
    let review = anyElement(app, "review-import-screen")
    try requireValue(review, "proposal:ready:1-book:1-tracks:0-warnings:revision-4")
    app.buttons["add-import-to-library"].tap()
    // The repaired title already exists on the review screen. Wait for the
    // asynchronous commit to leave that screen before resolving the matching
    // title in Library; otherwise a fast host can tap the stale review label.
    XCTAssertTrue(review.waitForNonExistence(timeout: 2))
    let persistence = anyElement(app, "metadata-persistence-probe")
    let persistedBook = "persistence=books:1:titles:The Amber Signal"
    try requireValue(persistence, persistedBook)
    XCTAssertTrue(terminateAndWait(app))
    app = try makeApplication(reset: false)
    app.launch()
    try requireValue(anyElement(app, "metadata-persistence-probe"), persistedBook)
    let repairedBook = app.staticTexts["The Amber Signal"]
    XCTAssertTrue(repairedBook.waitForExistence(timeout: 2))
    repairedBook.tap()

    let bookMetadata = anyElement(app, "book-metadata-probe")
    let bookProvenance = anyElement(app, "book-metadata-provenance-probe")
    let detail = anyElement(app, "book-detail-screen")
    let detailScroll = anyElement(app, "book-detail-scroll")
    let detailReadiness = anyElement(app, "book-detail-scroll-readiness")
    let detailArtwork = detail.descendants(matching: .any)["embedded-cover-artwork"]
    let renderedCover = anyElement(app, "book-cover-render-state")
    let undoRepair = app.buttons["undo-metadata-repair"]
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
        .exists(undoRepair, "The committed repair can be undone"),
        .valueEquals(
          renderedCover,
          "crop=\(expectedCrop):rendered=true",
          "The saved crop survives relaunch and renders from retained original bytes"
        ),
      ],
      captureReadiness: bookDetailCaptureReadiness(
        app: app,
        specification:
          "At capture, the repaired metadata, provenance, byte integrity, and replacement artwork are atomically rendered at the settled top of Book Detail",
        anchor: detailReadiness,
        detail: detail,
        detailScroll: detailScroll,
        detailReadiness: detailReadiness,
        artwork: detailArtwork
      ) {
        self.hasExactValue(
          bookMetadata,
          "metadata:book:title=The Amber Signal:authors=1:narrators=0:series=Night Signals #4:cover=replacement:locked=title,narrators,series,cover"
        )
          && self.hasExactValue(
            bookProvenance,
            "provenance:title=user:authors=embedded-tag:narrators=user-clear:series=embedded-tag:cover=user"
          )
          && self.hasExactValue(
            integrity,
            "audio:source=\(self.audioChecksum):managed=\(self.audioChecksum):source-unchanged=true"
          )
          && self.hasExactValue(renderedCover, "crop=\(expectedCrop):rendered=true")
          && elementIsFullyVisible(undoRepair, within: detailScroll)
      }
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
        .notExists(undoRepair, "The consumed undo action is removed"),
        .valueEquals(
          renderedCover,
          "crop=none:rendered=false",
          "Undo restores the uncropped embedded artwork projection"
        ),
      ],
      captureReadiness: bookDetailCaptureReadiness(
        app: app,
        specification:
          "At capture, undo has atomically restored the original metadata, provenance, cover, and integrity at the settled top of Book Detail",
        anchor: detailReadiness,
        detail: detail,
        detailScroll: detailScroll,
        detailReadiness: detailReadiness,
        artwork: detailArtwork
      ) {
        self.hasExactValue(
          bookMetadata,
          "metadata:book:title=The Brass Lantern:authors=1:narrators=1:series=Night Signals #4:cover=original:locked=none"
        )
          && self.hasExactValue(
            bookProvenance,
            "provenance:title=embedded-tag:authors=embedded-tag:narrators=embedded-tag:series=embedded-tag:cover=embedded-artwork"
          )
          && self.hasExactValue(
            integrity,
            "audio:source=\(self.audioChecksum):managed=\(self.audioChecksum):source-unchanged=true"
          )
          && self.hasExactValue(renderedCover, "crop=none:rendered=false")
          && !undoRepair.exists
      }
    )

    tester.generateDocs()
  }

  private func makeApplication(reset: Bool = true) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "synthetic-metadata-repair",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset { app.launchArguments.insert("-e2e-reset", at: 1) }
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

  private func bookDetailCaptureReadiness(
    app: XCUIApplication,
    specification: String,
    anchor: XCUIElement,
    detail: XCUIElement,
    detailScroll: XCUIElement,
    detailReadiness: XCUIElement,
    artwork: XCUIElement,
    semanticState: @escaping @MainActor () -> Bool
  ) -> CaptureReadiness {
    CaptureReadiness(specification: specification, anchor: anchor) {
      guard let state = ScrollReadinessState(detailReadiness.value) else { return false }
      return state.containerID == "book-detail-scroll"
        && state.axis == .vertical
        && state.isIdle
        && state.atTop
        && detail.exists
        && semanticState()
        && elementIsFullyVisible(artwork, within: detailScroll, requiresHittable: false)
        && self.hasNoTransientUI(app)
    }
  }

  private func hasExactValue(_ element: XCUIElement, _ expected: String) -> Bool {
    element.exists && element.value.map(String.init(describing:)) == expected
  }

  private func hasNoTransientUI(_ app: XCUIApplication) -> Bool {
    !app.keyboards.firstMatch.exists
      && !app.alerts.firstMatch.exists
      && !app.sheets.firstMatch.exists
  }

  private func replaceText(
    in field: XCUIElement,
    with replacement: String,
    app: XCUIApplication
  ) throws {
    let existingValue = try XCTUnwrap(field.value as? String)
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    XCTAssertTrue(
      waitForPredicate(
        NSPredicate(format: "exists == true AND hittable == true AND hasKeyboardFocus == true"),
        on: field,
        timeout: EventDeadline().remaining
      ),
      "The metadata title must acquire focus before replacement text is entered"
    )
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 2),
      "The software keyboard must be ready before replacement text is entered"
    )
    let titleValue = app.descendants(matching: .any)["metadata-title-value-state"]
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingValue.count))
    XCTAssertTrue(
      titleValue.waitForStringValue("empty", timeout: 2),
      "Deleting the observed title must clear the metadata field"
    )
    field.typeText(replacement)
    XCTAssertTrue(
      titleValue.waitForStringValue("value=\(replacement)", timeout: 2),
      "The metadata draft must receive the replacement title"
    )
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

  private func adjust(
    _ slider: XCUIElement,
    toNormalizedPosition position: CGFloat,
    until state: XCUIElement,
    hasValue expected: String
  ) throws {
    let deadline = EventDeadline()
    repeat {
      slider.adjust(toNormalizedSliderPosition: position)
      if state.waitForStringValue(expected, timeout: min(0.25, deadline.remaining)) {
        return
      }
    } while deadline.remaining > 0

    XCTFail(
      "The crop slider did not publish its required semantic state; expected=\(expected) actual=\(String(describing: state.value))"
    )
    throw MetadataRepairTestError.semanticStateUnavailable
  }
}

private enum MetadataRepairTestError: Error {
  case semanticStateUnavailable
}
