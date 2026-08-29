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
        "The production monetization manager uses a scripted sandbox StoreKit transport with isolated persistence.",
        "The simulator cannot deterministically complete Apple's offer-code sheet, so the test taps the production Redeem action and injects only its completion result.",
      ]
    )

    app.launch()
    let unlockScreen = app.scrollViews["full-unlock-screen"]
    let scrollReadiness = app.descendants(matching: .any)["full-unlock-scroll-readiness"]
    let state = app.descendants(matching: .any)["e2e-monetization-state"]
    XCTAssertTrue(waitForExistence(state, deadline: EventDeadline()))
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "e2e-monetization-state").count, 1)
    XCTAssertTrue(waitForValue(state, containing: "loading=true"))
    XCTAssertTrue(waitForValue(state, containing: "phase=awaiting-products"))
    XCTAssertFalse(app.buttons["full-unlock-purchase"].isEnabled)
    let completeProducts = app.buttons["e2e-monetization-complete-products"]
    XCTAssertTrue(waitForExistence(completeProducts, deadline: EventDeadline()))
    completeProducts.tap()
    XCTAssertTrue(waitForValue(state, containing: "price=$9.99"))
    XCTAssertTrue(waitForValue(state, containing: "family=true"))
    XCTAssertTrue(waitForValue(state, containing: libraryInvariant))

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

    tapPhysicalAction(
      app.buttons["full-unlock-restore"],
      within: unlockScreen,
      in: app
    )
    let completeRestore = app.buttons["e2e-monetization-complete-restore-empty"]
    XCTAssertTrue(waitForExistence(completeRestore, deadline: EventDeadline()))
    XCTAssertTrue(waitForValue(state, containing: "action=true"))
    XCTAssertFalse(app.buttons["full-unlock-purchase"].isEnabled)
    XCTAssertFalse(app.buttons["full-unlock-redeem-code"].isEnabled)
    completeRestore.tap()
    XCTAssertTrue(waitForExistence(
      app.staticTexts["No Full Unlock was found for this Apple Account."],
      deadline: EventDeadline()
    ))
    XCTAssertTrue(waitForValue(state, containing: "action=false"))
    XCTAssertTrue(waitForValue(state, containing: libraryInvariant))

    app.buttons["full-unlock-redeem-code"].tap()
    let completeOffer = app.buttons["e2e-monetization-complete-offer-failure"]
    XCTAssertTrue(waitForExistence(completeOffer, deadline: EventDeadline()))
    XCTAssertTrue(waitForValue(state, containing: "phase=awaiting-offer-completion"))
    completeOffer.tap()
    XCTAssertTrue(waitForExistence(
      app.staticTexts["The offer-code sheet couldn't be completed. No Bookshelf access was changed."],
      deadline: EventDeadline()
    ))
    XCTAssertTrue(waitForValue(state, containing: libraryInvariant))

    app.buttons["full-unlock-purchase"].tap()
    let completePurchase = app.buttons["e2e-monetization-complete-purchase"]
    XCTAssertTrue(waitForExistence(completePurchase, deadline: EventDeadline()))
    XCTAssertTrue(waitForValue(state, containing: "action=true"))
    XCTAssertFalse(app.buttons["full-unlock-purchase"].isEnabled)
    completePurchase.tap()
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

    XCTAssertTrue(waitForValue(state, containing: libraryInvariant))
    let prepareOffline = app.buttons["e2e-monetization-prepare-offline"]
    XCTAssertTrue(waitForExistence(prepareOffline, deadline: EventDeadline()))
    prepareOffline.tap()
    XCTAssertTrue(waitForValue(state, containing: "phase=offline"))
    XCTAssertTrue(terminateAndWait(app))
    app.launchArguments.removeAll { $0 == "-e2e-reset" }
    app.launch()

    let relaunchedState = app.descendants(matching: .any)["e2e-monetization-state"]
    XCTAssertTrue(waitForExistence(relaunchedState, deadline: EventDeadline()))
    XCTAssertTrue(waitForValue(relaunchedState, containing: libraryInvariant))
    XCTAssertTrue(waitForValue(relaunchedState, containing: "entitlement=fullUnlock"))
    XCTAssertTrue(waitForValue(relaunchedState, containing: "phase=offline"))
    XCTAssertTrue(waitForExistence(app.staticTexts["Bookshelf is unlocked"], deadline: EventDeadline()))
    XCTAssertTrue(waitForExistence(
      app.staticTexts[
        "The App Store could not be reached. You can keep using your included playback and try again later."
      ],
      deadline: EventDeadline()
    ))
    XCTAssertFalse(app.staticTexts["Eligible for Apple Family Sharing"].exists)

    tester.generateDocs()
  }

  private var libraryInvariant: String {
    "restored=true|books=1|current=20000000-0000-0000-0000-000000000001"
  }

  private func waitForValue(_ element: XCUIElement, containing token: String) -> Bool {
    waitForPredicate(
      NSPredicate(format: "value CONTAINS %@", token),
      on: element,
      timeout: EventDeadline().remaining
    )
  }

  private func tapPhysicalAction(
    _ action: XCUIElement,
    within container: XCUIElement,
    in app: XCUIApplication
  ) {
    let actionFrame = action.frame
    let appFrame = app.frame
    guard action.exists,
      action.isEnabled,
      elementIsFullyVisible(action, within: container),
      !actionFrame.isEmpty,
      !appFrame.isEmpty,
      appFrame.contains(actionFrame)
    else {
      XCTFail("Expected the monetization action to be enabled and fully visible")
      return
    }
    app.coordinate(
      withNormalizedOffset: CGVector(
        dx: (actionFrame.midX - appFrame.minX) / appFrame.width,
        dy: (actionFrame.midY - appFrame.minY) / appFrame.height
      )
    ).tap()
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
