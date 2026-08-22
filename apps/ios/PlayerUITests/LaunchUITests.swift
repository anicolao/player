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
        .exists(
          app.buttons["receive-from-computer-empty-library"],
          "The primary computer receiver action is available"
        ),
        .exists(
          app.buttons["choose-from-files-empty-library"],
          "The on-device Files fallback is available"
        ),
        .exists(app.tabBars.buttons["Library"], "The Library tab is selected and available"),
        .exists(app.tabBars.buttons["Inbox"], "The Inbox tab is available"),
        .exists(app.tabBars.buttons["Settings"], "The Settings tab is available"),
        .notExists(app.otherElements["mini-player"], "No mini-player appears without a book"),
      ]
    )

    app.buttons["receive-from-computer-empty-library"].tap()
    try tester.step(
      "computer-receiver-ready",
      description: "The receiver gives the computer one address and one short pairing code",
      verifications: [
        .valueEquals(
          app.scrollViews["computer-receiver-screen"],
          "receiver:ready",
          "The receiver is ready before the listener visits the computer"
        ),
        StepVerification(specification: "A copyable local-network address is shown") {
          let address = app.staticTexts["computer-receiver-address"]
          return address.waitForExistence(timeout: TestStepHelper.conditionTimeout)
            && address.label == "http://192.168.1.42:49152"
        },
        .exists(
          app.staticTexts["computer-receiver-pairing-code"],
          "A six-digit pairing code is shown"
        ),
        .exists(
          anyElement(app, "mirroring-import-tip"),
          "Supported locales also see the optional iPhone Mirroring path"
        ),
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
      "-e2e-computer-receiver-ready",
      "-e2e-show-mirroring-tip",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }
}
