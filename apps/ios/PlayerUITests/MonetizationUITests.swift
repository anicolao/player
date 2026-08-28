import XCTest

@MainActor
final class MonetizationUITests: XCTestCase {
  func testExplainsExhaustionAndCompletesAOneTimeUnlock() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e",
      "-e2e-reset",
      "-e2e-fixture", "monetization-exhausted",
      "-e2e-start-section", "settings",
      "-e2e-start-settings-route", "full-unlock",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"

    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "Bookshelf offers a clear one-time Full Unlock",
      narrative:
        "As a listener who used all included playback, I want a calm explanation, one-time price, restore path, and code redemption so I can keep listening without a subscription.",
      fixture: "monetization-exhausted",
      additionalPreconditions: [
        "The playback-only allowance is deterministically set to exactly 50 consumed hours.",
        "The StoreKit test double supplies a localized $9.99 price and a permanent unlock transaction.",
      ]
    )

    app.launch()
    let unlockScreen = app.scrollViews["full-unlock-screen"]
    let scrollReadiness = app.descendants(matching: .any)["full-unlock-scroll-readiness"]

    try tester.step(
      "included-playback-exhausted",
      description: "The exhausted state explains the permanent purchase without threatening library data",
      verifications: [
        .exists(app.scrollViews["full-unlock-screen"], "The Full Unlock screen is visible"),
        .exists(app.staticTexts["0m remaining from the 50 hours included with Bookshelf. Pay once to keep listening without a limit."], "The exact playback allowance is explained"),
        .exists(app.buttons["full-unlock-purchase"], "The one-time purchase action is available"),
        .exists(app.buttons["full-unlock-restore"], "Purchase restoration is available"),
        .exists(app.buttons["full-unlock-redeem-code"], "Offer-code redemption is available"),
        .exists(app.staticTexts["One-time purchase · No subscription"], "The purchase model is explicit"),
      ],
      captureReadiness: fullUnlockCaptureReadiness(
        app,
        screen: unlockScreen,
        readiness: scrollReadiness,
        specification:
          "At capture, the exhausted 50-hour allowance and exact $9.99 one-time purchase actions are settled at the top with no transient UI"
      ) {
        let purchase = app.buttons["full-unlock-purchase"]
        return purchase.exists
          && purchase.isEnabled
          && purchase.label == "Unlock Forever — $9.99"
          && elementIsFullyVisible(purchase, within: unlockScreen)
          && elementIsFullyVisible(app.buttons["full-unlock-restore"], within: unlockScreen)
          && elementIsFullyVisible(app.buttons["full-unlock-redeem-code"], within: unlockScreen)
          && app.staticTexts[
            "0m remaining from the 50 hours included with Bookshelf. Pay once to keep listening without a limit."
          ].exists
      }
    )

    app.buttons["full-unlock-purchase"].tap()
    try tester.step(
      "full-unlock-purchased",
      description: "A successful non-consumable transaction permanently unlocks playback",
      verifications: [
        .exists(app.staticTexts["full-unlock-purchased"], "The purchased entitlement is visible"),
        .exists(app.staticTexts["Bookshelf is unlocked"], "The screen confirms ownership"),
        .notExists(app.buttons["full-unlock-purchase"], "The app no longer offers a duplicate purchase"),
      ],
      captureReadiness: fullUnlockCaptureReadiness(
        app,
        screen: unlockScreen,
        readiness: scrollReadiness,
        specification:
          "At capture, the permanent entitlement and purchase feedback are settled at the top with no purchase action or transient UI"
      ) {
        app.staticTexts["full-unlock-purchased"].exists
          && app.staticTexts["Bookshelf is unlocked"].exists
          && app.staticTexts["Bookshelf is unlocked on this device."].exists
          && !app.buttons["full-unlock-purchase"].exists
          && elementIsFullyVisible(
            app.staticTexts["full-unlock-purchased"], within: unlockScreen, requiresHittable: false
          )
      }
    )

    tester.generateDocs()
  }

  private func fullUnlockCaptureReadiness(
    _ app: XCUIApplication,
    screen: XCUIElement,
    readiness: XCUIElement,
    specification: String,
    state: @escaping @MainActor () -> Bool
  ) -> CaptureReadiness {
    CaptureReadiness(specification: specification, anchor: readiness) {
      guard let scroll = ScrollReadinessState(readiness.value) else { return false }
      return screen.exists
        && scroll.containerID == "full-unlock-screen"
        && scroll.axis == .vertical
        && scroll.isIdle
        && scroll.atTop
        && state()
        && !app.keyboards.firstMatch.exists
        && !app.alerts.firstMatch.exists
        && !app.sheets.firstMatch.exists
    }
  }
}
