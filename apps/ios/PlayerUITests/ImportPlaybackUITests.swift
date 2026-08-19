import XCTest

@MainActor
final class ImportPlaybackUITests: XCTestCase {
  func testReviewsCommitsAndPlaysOneAudiobook() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = makeApplication()
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "A local audiobook moves from Inbox to playback",
      narrative:
        "As a listener, I want to review one imported audiobook, add it to my library, and know its managed audio is ready to play.",
      fixture: "single-audiobook-ready",
      additionalPreconditions: [
        "Identifiers, metadata, duration, and import timestamps are fixed",
        "Playback uses the deterministic engine behind the production playback boundary",
      ]
    )

    app.launch()
    app.tabBars.buttons["Inbox"].tap()
    XCTAssertTrue(app.staticTexts["The Lighthouse Signal"].waitForExistence(timeout: 2))
    app.staticTexts["The Lighthouse Signal"].tap()

    try tester.step(
      "review-import",
      description: "The inspected audiobook is ready for review",
      verifications: [
        .exists(app.otherElements["review-import-screen"], "The Review Import screen is visible"),
        .exists(app.staticTexts["The Lighthouse Signal"], "The inspected title is presented"),
        .exists(app.staticTexts["Mara Vale"], "The inspected author is presented"),
        .exists(app.buttons["add-import-to-library"], "The import can be committed"),
      ]
    )

    app.buttons["add-import-to-library"].tap()
    let libraryScreen = app.descendants(matching: .any)["library-screen"]
    XCTAssertTrue(libraryScreen.waitForExistence(timeout: 2))

    try tester.step(
      "committed-library",
      description: "The committed audiobook appears in the local library",
      verifications: [
        .valueEquals(
          libraryScreen,
          "ready:library-1-books",
          "The Library reports exactly one committed book"
        ),
        .exists(app.staticTexts["The Lighthouse Signal"], "The committed title is visible"),
        .exists(app.staticTexts["Mara Vale"], "The committed author is visible"),
      ]
    )

    app.staticTexts["The Lighthouse Signal"].tap()
    try tester.step(
      "book-detail",
      description: "Book Detail exposes the playable managed audiobook",
      verifications: [
        .exists(
          app.descendants(matching: .any)["book-detail-screen"],
          "The Book Detail screen is visible"
        ),
        .exists(app.buttons["play-book"], "The audiobook has a Play action"),
        .exists(app.staticTexts["1 file · 18m"], "The inspected asset count and duration are retained"),
      ]
    )

    app.buttons["play-book"].tap()
    XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 2))
    app.buttons["player-play-pause"].tap()

    try tester.step(
      "paused-now-playing",
      description: "Now Playing has loaded and paused the managed audio",
      verifications: [
        .valueEquals(
          app.otherElements["now-playing-screen"],
          "player:paused:10000000-0000-0000-0000-000000000004:0:0",
          "The deterministic engine acknowledges a paused loaded book"
        ),
        .exists(app.staticTexts["The Lighthouse Signal"], "Now Playing retains the book identity"),
        .exists(app.buttons["player-play-pause"], "The transport remains available"),
      ]
    )

    tester.generateDocs()
  }

  private func makeApplication() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-e2e", "-e2e-reset", "-e2e-fixture", "single-audiobook-ready",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }
}
