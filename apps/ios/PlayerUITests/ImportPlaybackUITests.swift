import XCTest

@MainActor
final class ImportPlaybackUITests: XCTestCase {
  private let jobID = "10000000-0000-0000-0000-000000000001"

  func testAbandonsReadyImportAndClearsInbox() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = makeApplication()
    app.launch()
    app.tabBars.buttons["Inbox"].tap()
    app.buttons["review-import-job-\(jobID)"].tap()
    XCTAssertTrue(app.buttons["abandon-import"].waitForExistence(timeout: 2))

    app.buttons["abandon-import"].tap()
    let confirmation = app.sheets.buttons["Abandon Import"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
    confirmation.tap()

    let inbox = app.descendants(matching: .any)["inbox-screen"]
    XCTAssertTrue(inbox.waitForStringValue("import:0-review:0-processing:0", timeout: 2))
    XCTAssertTrue(app.staticTexts["Inbox is clear"].exists)
  }

  func testNowPlayingRendersWhenImportedDurationIsUnavailable() {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = makeApplication(fixture: "zero-duration-current-book")
    app.launch()
    let miniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    miniPlayer.tap()

    XCTAssertTrue(
      app.otherElements["now-playing-screen"].waitForExistence(timeout: 2),
      "Now Playing must not crash while an imported duration is unavailable"
    )
    XCTAssertTrue(app.sliders["player-position-slider"].exists)
    XCTAssertTrue(app.buttons["player-play-pause"].exists)
  }

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
    let readyRow = app.descendants(matching: .any)["import-job-\(jobID)"]
    XCTAssertTrue(readyRow.waitForExistence(timeout: 2))
    XCTAssertEqual(readyRow.value as? String, "ready:action=review-and-add")
    XCTAssertTrue(
      app.descendants(matching: .any)["ready-import-action-\(jobID)"].exists,
      "A ready Inbox row must name its Review & Add action"
    )
    app.buttons["review-import-job-\(jobID)"].tap()

    let addToLibrary = app.buttons["add-import-to-library"]

    try tester.step(
      "review-import",
      description: "The inspected audiobook is ready for review",
      verifications: [
        .exists(
          app.descendants(matching: .any)["review-import-screen"],
          "The Review Import screen is visible"
        ),
        .exists(app.staticTexts["The Lighthouse Signal"], "The inspected title is presented"),
        .exists(app.staticTexts["Mara Vale"], "The inspected author is presented"),
        .valueEquals(
          addToLibrary,
          "ready:enabled",
          "The pinned Add to Library action reports that it is ready"
        ),
        StepVerification(specification: "The primary action is visible, enabled, and directly tappable") {
          addToLibrary.exists && addToLibrary.isEnabled && addToLibrary.isHittable
        },
      ]
    )

    addToLibrary.tap()
    let libraryScreen = app.descendants(matching: .any)["library-screen"]
    XCTAssertTrue(libraryScreen.waitForExistence(timeout: 2))
    let addAudiobook = app.tabBars.buttons["Add"]
    XCTAssertTrue(addAudiobook.waitForExistence(timeout: 2))
    XCTAssertTrue(addAudiobook.isHittable)

    app.tabBars.buttons["Inbox"].tap()
    let inboxScreen = app.descendants(matching: .any)["inbox-screen"]
    let clearInbox = app.staticTexts["Inbox is clear"]
    let completedImport = app.buttons["review-import-job-\(jobID)"]
    let inboxSettledWithoutCompletedImport = waitForPredicate(
        NSPredicate { _, _ in
          inboxScreen.exists
            && inboxScreen.value.map(String.init(describing:))
              == "import:0-review:0-processing:0"
            && clearInbox.exists
            && !completedImport.exists
        },
        on: inboxScreen
      )
    XCTAssertTrue(
      inboxSettledWithoutCompletedImport,
      "The active Inbox must settle empty without retaining a successful import"
    )
    app.tabBars.buttons["Library"].tap()
    XCTAssertTrue(libraryScreen.waitForStringValue("ready:library-1-books", timeout: 2))

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
        StepVerification(
          specification: "The completed import is absent from Inbox and its triage state is clear"
        ) {
          inboxSettledWithoutCompletedImport
        },
        StepVerification(
          specification: "The larger Add Audiobook action is available beside the tab switcher"
        ) {
          addAudiobook.exists && addAudiobook.isHittable
        },
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

  private func makeApplication(fixture: String = "single-audiobook-ready") -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-e2e", "-e2e-reset", "-e2e-fixture", fixture,
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }
}
