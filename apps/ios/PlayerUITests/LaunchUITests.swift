import XCTest

@MainActor
final class LaunchUITests: XCTestCase {
  func testRejectsUnknownDynamicTypeConfigurationInsteadOfUsingMedium() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-reset", "-e2e-fixture", "empty-library",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launchEnvironment["PLAYER_E2E_DYNAMIC_TYPE"] = "accessibility-5"
    app.launch()

    XCTAssertTrue(app.staticTexts["Local Storage Unavailable"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.descendants(matching: .any)["library-screen"].exists)
  }

  func testRejectsInvalidNavigationBeforeConstructingTheFixtureEnvironment() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-reset", "-e2e-fixture", "empty-library",
      "-e2e-start-section", "inbox",
      "-e2e-start-settings-route", "backup",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launch()

    XCTAssertTrue(app.staticTexts["Local Storage Unavailable"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.descendants(matching: .any)["library-screen"].exists)
  }

  func testRejectsUnknownFixtureWithoutFallingBackToProduction() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-reset", "-e2e-fixture", "misspelled-fixture",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launch()

    XCTAssertTrue(app.staticTexts["Local Storage Unavailable"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.descendants(matching: .any)["library-screen"].exists)
  }

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
        .valueEquals(
          anyElement(app, "computer-receiver-http-probe"),
          "http:GET:/:status=200",
          "The production receiver parsed and served a deterministic raw browser request"
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

    XCTAssertTrue(terminateAndWait(app))
    let receivingApp = makeApplication(additionalArguments: ["-e2e-mirroring-drop-progress"])
    receivingApp.launch()
    receivingApp.buttons["receive-from-computer-empty-library"].tap()
    try tester.step(
      "mirroring-drop-progress",
      description: "A mirrored folder drop reports deterministic preparation progress on iPhone",
      verifications: [
        .valueEquals(
          receivingApp.scrollViews["computer-receiver-screen"],
          "receiver:preparing-mirrored-drop",
          "The receiver reports the native mirrored-drop state"
        ),
        .exists(
          receivingApp.progressIndicators["mirroring-drop-progress"],
          "The listener sees progress while the dropped folder is materialized"
        ),
        .exists(
          receivingApp.staticTexts["Project Hail Mary"],
          "The progress view identifies the book currently being received"
        ),
      ]
    )

    XCTAssertTrue(terminateAndWait(receivingApp))
    let pausedApp = makeApplication(additionalArguments: ["-e2e-computer-receiver-paused"])
    pausedApp.launch()
    pausedApp.buttons["receive-from-computer-empty-library"].tap()
    try tester.step(
      "computer-receiver-paused",
      description: "Interrupted web transfer progress agrees with the server-confirmed bytes",
      verifications: [
        .valueEquals(
          pausedApp.scrollViews["computer-receiver-screen"],
          "receiver:paused",
          "The receiver identifies the paused, resumable state"
        ),
        .valueEquals(
          pausedApp.descendants(matching: .any)["computer-receiver-transfer"],
          "receiving:734003200-of-1468006400",
          "The iPhone reports the exact confirmed byte count"
        ),
        .exists(
          pausedApp.staticTexts[
            "The computer can retry from the confirmed progress shown here."
          ],
          "The listener is told that retry continues from confirmed progress"
        ),
      ]
    )

    XCTAssertTrue(terminateAndWait(pausedApp))
    let completedApp = makeApplication(additionalArguments: ["-e2e-computer-receiver-completed"])
    completedApp.launch()
    completedApp.buttons["receive-from-computer-empty-library"].tap()
    try tester.step(
      "computer-receiver-completed",
      description: "A completed transfer remains actionable for repeated imports",
      verifications: [
        .valueEquals(
          completedApp.scrollViews["computer-receiver-screen"],
          "receiver:completed:1",
          "The receiver reports one completed book without dismissing itself"
        ),
        .exists(
          completedApp.buttons["receive-another-audiobook"],
          "The listener can keep the receiver open for another book"
        ),
        .exists(
          completedApp.buttons["finish-computer-receiver"],
          "The listener explicitly decides when receiving is finished"
        ),
      ]
    )

    completedApp.buttons["receive-another-audiobook"].tap()
    try tester.step(
      "computer-receiver-repeat-ready",
      description: "Receive Another returns to the same paired receiver",
      verifications: [
        .valueEquals(
          completedApp.scrollViews["computer-receiver-screen"],
          "receiver:ready",
          "The existing receiver is immediately ready for the next book"
        ),
        .exists(
          completedApp.staticTexts["computer-receiver-pairing-code"],
          "The active receiver keeps its discoverable pairing details"
        ),
      ]
    )

    tester.generateDocs()
  }

  private func makeApplication(additionalArguments: [String] = []) -> XCUIApplication {
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
    app.launchArguments += additionalArguments
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }
}
