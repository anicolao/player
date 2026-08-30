import XCTest

@MainActor
final class MetadataChapterUITests: PlayerUITestCase {
  private let bookID = "30000000-0000-0000-0000-000000000001"

  func testInjectedProgressCrossesVisibleChapterBoundariesAndCompletes() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let setup = XCUIApplication()
    setup.launchArguments = [
      "-e2e", "-e2e-reset", "-e2e-fixture", "metadata-rich-book",
      "-e2e-metadata-rich-namespace", "metadata-live-progress",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    setup.launchEnvironment["TZ"] = "America/Toronto"
    setup.launch()

    XCTAssertTrue(setup.staticTexts["Harbor at Dawn"].waitForExistence(timeout: 2))
    setup.staticTexts["Harbor at Dawn"].tap()
    XCTAssertTrue(setup.buttons["chapter-1"].waitForExistence(timeout: 2))
    setup.buttons["chapter-1"].tap()
    XCTAssertTrue(setup.otherElements["now-playing-screen"].waitForExistence(timeout: 2))
    XCTAssertTrue(terminateAndWait(setup))

    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-event-controls", "-e2e-fixture", "metadata-rich-book",
      "-e2e-metadata-rich-namespace", "metadata-live-progress",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launch()

    let miniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    app.buttons["mini-player-play-pause"].tap()
    XCTAssertTrue(miniPlayer.waitForStringValue("player:playing:\(bookID):0:0", timeout: 2))
    miniPlayer.tap()
    let nowPlaying = app.otherElements["now-playing-screen"]
    XCTAssertTrue(nowPlaying.waitForExistence(timeout: 2))
    XCTAssertTrue(tapHittableButton("e2e-engine-progress-45", in: app))
    XCTAssertTrue(
      nowPlaying.waitForStringValue("player:playing:\(bookID):1:45000", timeout: 2)
    )
    XCTAssertTrue(app.staticTexts["Crossing the Bar"].exists)
    XCTAssertTrue(app.staticTexts["Chapter 2 of 3"].exists)
    XCTAssertTrue(app.staticTexts["player-elapsed-time"].waitForStringValue("0m15s", timeout: 2))
    XCTAssertTrue(app.staticTexts["player-remaining-time"].waitForStringValue("0m30s", timeout: 2))
    let crossingSlider = String(describing: app.sliders["player-position-slider"].value)
    XCTAssertTrue(crossingSlider.contains("Crossing the Bar"))
    XCTAssertTrue(crossingSlider.contains("33 percent"))

    XCTAssertTrue(tapHittableButton("e2e-engine-progress-75", in: app))
    XCTAssertTrue(
      nowPlaying.waitForStringValue("player:playing:\(bookID):2:75000", timeout: 2)
    )
    XCTAssertTrue(app.staticTexts["Safe Harbor"].exists)
    XCTAssertTrue(app.staticTexts["Chapter 3 of 3"].exists)
    XCTAssertTrue(app.staticTexts["player-elapsed-time"].waitForStringValue("0m00s", timeout: 2))
    XCTAssertTrue(app.staticTexts["player-remaining-time"].waitForStringValue("0m45s", timeout: 2))
    let harborSlider = String(describing: app.sliders["player-position-slider"].value)
    XCTAssertTrue(harborSlider.contains("Safe Harbor"))
    XCTAssertTrue(harborSlider.contains("0 percent"))

    XCTAssertTrue(tapHittableButton("e2e-engine-reached-end", in: app))
    XCTAssertTrue(
      nowPlaying.waitForStringValue("player:paused:\(bookID):2:120000", timeout: 2)
    )
    XCTAssertTrue(app.staticTexts["player-elapsed-time"].waitForStringValue("0m45s", timeout: 2))
    XCTAssertTrue(app.staticTexts["player-remaining-time"].waitForStringValue("0m00s", timeout: 2))
  }

  func testShowsEmbeddedMetadataAndStartsAChapter() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-reset", "-e2e-fixture", "metadata-rich-book",
      "-e2e-metadata-rich-namespace", "metadata-chapters",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"

    let tester = TestStepHelper(testCase: self, startIndex: 4)
    tester.setMetadata(
      title: "Embedded audiobook metadata and chapters remain useful after import",
      narrative:
        "As a listener, I want an imported audiobook to retain its cover, contributors, series, and chapter boundaries so I can understand it and start at a chapter.",
      fixture: "metadata-rich-book",
      additionalPreconditions: [
        "The fixture models metadata parsed from a deterministic synthetic M4B",
        "The committed book has one asset and three embedded chapters",
        "Identifiers, chapter boundaries, artwork, duration, and contributors are fixed",
        "Playback uses the deterministic engine behind the production playback boundary",
      ]
    )

    app.launch()
    XCTAssertTrue(app.staticTexts["Harbor at Dawn"].waitForExistence(timeout: 2))
    app.staticTexts["Harbor at Dawn"].tap()

    let detail = app.descendants(matching: .any)["book-detail-screen"]
    let detailScroll = app.descendants(matching: .any)["book-detail-scroll"]
    let detailReadiness = app.descendants(matching: .any)["book-detail-scroll-readiness"]
    let detailArtwork = detail.descendants(matching: .any)["embedded-cover-artwork"]
    try tester.step(
      "metadata-and-chapters",
      description: "Book Detail presents embedded contributors, series, cover, and chapters",
      verifications: [
        .exists(detail, "The metadata-rich Book Detail screen is visible"),
        .valueEquals(
          detail,
          "book:ready:\(bookID):3-chapters:m4b",
          "The book exposes one M4B asset and three embedded chapters"
        ),
        .exists(app.staticTexts["Harbor at Dawn"], "The embedded title is visible"),
        .exists(app.staticTexts["Mara Vale"], "The embedded author is visible"),
        .exists(app.staticTexts["Narrated by Imani Chen"], "The embedded narrator is visible"),
        .exists(app.staticTexts["Harbor Signals · Book 2"], "The embedded series is visible"),
        .exists(
          app.descendants(matching: .any)["embedded-cover-artwork"],
          "The embedded cover artwork is retained"
        ),
        .exists(app.buttons["chapter-1"], "The first embedded chapter is navigable"),
        .exists(app.buttons["chapter-2"], "The second embedded chapter is navigable"),
      ],
      captureReadiness: CaptureReadiness(
        specification:
          "At capture, the exact embedded M4B metadata, decoded cover, and first two chapter actions are settled at the top with no transient UI",
        anchor: detailReadiness
      ) {
        guard let state = ScrollReadinessState(detailReadiness.value) else { return false }
        return self.hasExactValue(detail, "book:ready:\(self.bookID):3-chapters:m4b")
          && state.containerID == "book-detail-scroll"
          && state.axis == .vertical
          && state.isIdle
          && state.atTop
          && elementIsFullyVisible(detailArtwork, within: detailScroll, requiresHittable: false)
          && app.buttons["chapter-1"].exists
          && app.buttons["chapter-2"].exists
          && !app.keyboards.firstMatch.exists
          && !app.alerts.firstMatch.exists
          && !app.sheets.firstMatch.exists
      }
    )

    XCTAssertTrue(
      app.buttons["chapter-3"].waitForExistence(timeout: 2),
      "The third embedded chapter is present below the fold"
    )
    app.buttons["chapter-2"].tap()
    XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 2))
    app.buttons["player-play-pause"].tap()

    let nowPlaying = app.otherElements["now-playing-screen"]
    let nowPlayingReadiness = app.descendants(matching: .any)["now-playing-layout-readiness"]
    try tester.step(
      "chapter-now-playing",
      description: "Starting an embedded chapter opens Now Playing at its exact boundary",
      verifications: [
        .valueEquals(
          nowPlaying,
          "player:paused:\(bookID):1:30000",
          "The deterministic engine acknowledges chapter 2 at 30,000 milliseconds"
        ),
        .exists(app.staticTexts["Crossing the Bar"], "Now Playing names the current chapter"),
        .exists(app.staticTexts["Chapter 2 of 3"], "Now Playing gives chapter context"),
        .exists(app.sliders["player-position-slider"], "The chapter position remains adjustable"),
      ],
      captureReadiness: CaptureReadiness(
        specification:
          "At capture, chapter two is paused at exactly 30 seconds with decoded artwork, settled Now Playing geometry, and no transient UI",
        anchor: nowPlayingReadiness
      ) {
        guard let layout = LayoutReadinessState(nowPlayingReadiness.value) else { return false }
        return layout.containerID == "now-playing-screen"
          && self.hasExactValue(nowPlaying, "player:paused:\(self.bookID):1:30000")
          && elementIsFullyVisible(
            nowPlaying.descendants(matching: .any)["embedded-cover-artwork"],
            within: nowPlaying,
            requiresHittable: false
          )
          && elementIsFullyVisible(app.sliders["player-position-slider"], within: nowPlaying)
          && elementIsFullyVisible(app.buttons["player-play-pause"], within: nowPlaying)
          && !app.keyboards.firstMatch.exists
          && !app.alerts.firstMatch.exists
          && !app.sheets.firstMatch.exists
      }
    )

    tester.generateDocs()
  }

  private func hasExactValue(_ element: XCUIElement, _ expected: String) -> Bool {
    element.exists && element.value.map(String.init(describing:)) == expected
  }

  private func tapHittableButton(_ identifier: String, in app: XCUIApplication) -> Bool {
    let query = app.buttons.matching(identifier: identifier)
    guard let button = query.allElementsBoundByIndex.first(where: \.isHittable) else { return false }
    button.tap()
    return true
  }
}
