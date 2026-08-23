import XCTest

@MainActor
final class MetadataChapterUITests: XCTestCase {
  private let bookID = "30000000-0000-0000-0000-000000000001"

  func testShowsEmbeddedMetadataAndStartsAChapter() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-reset", "-e2e-fixture", "metadata-rich-book",
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
      ]
    )

    XCTAssertTrue(
      app.buttons["chapter-3"].waitForExistence(timeout: 2),
      "The third embedded chapter is present below the fold"
    )
    app.buttons["chapter-2"].tap()
    XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 2))
    app.buttons["player-play-pause"].tap()

    try tester.step(
      "chapter-now-playing",
      description: "Starting an embedded chapter opens Now Playing at its exact boundary",
      verifications: [
        .valueEquals(
          app.otherElements["now-playing-screen"],
          "player:paused:\(bookID):1:30000",
          "The deterministic engine acknowledges chapter 2 at 30,000 milliseconds"
        ),
        .exists(app.staticTexts["Crossing the Bar"], "Now Playing names the current chapter"),
        .exists(app.staticTexts["Chapter 2 of 3"], "Now Playing gives chapter context"),
        .exists(app.sliders["player-position-slider"], "The chapter position remains adjustable"),
      ]
    )

    tester.generateDocs()
  }
}
