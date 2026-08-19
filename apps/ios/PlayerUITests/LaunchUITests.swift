import XCTest

@MainActor
final class LaunchUITests: XCTestCase {
  func testLaunchesIntoEmptyLibrary() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = makeApplication()
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "Player launches into an empty local library",
      narrative:
        "As a new listener, I want Player to open into a ready and understandable library so I can add my first audiobook.",
      fixture: "empty-library"
    )

    app.launch()

    try tester.step(
      "empty-library",
      description: "Player launches into the ready empty-library state",
      verifications: [
        .exists(app.otherElements["library-screen"], "The Library screen is visible"),
        .valueEquals(
          app.otherElements["library-screen"],
          "ready:library-empty",
          "The application reports the ready empty-library state"
        ),
        .exists(
          app.staticTexts["Build your listening library"],
          "The empty state explains the next action"
        ),
        .exists(app.buttons["add-audiobook"], "The Add Audiobook action is available"),
        .exists(app.tabBars.buttons["Library"], "The Library tab is selected and available"),
        .exists(app.tabBars.buttons["Inbox"], "The Inbox tab is available"),
        .exists(app.tabBars.buttons["Settings"], "The Settings tab is available"),
        .notExists(app.otherElements["mini-player"], "No mini-player appears without a book"),
      ]
    )

    tester.generateDocs()
  }

  private func makeApplication() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-e2e",
      "-e2e-reset",
      "-e2e-fixture",
      "empty-library",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }
}
