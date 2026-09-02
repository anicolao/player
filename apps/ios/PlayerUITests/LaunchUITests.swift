import XCTest

@MainActor
final class LaunchUITests: PlayerUITestCase {
  func testAudioSessionConfigurationWarningDoesNotPresentImportAlertAtStartup() {
    continueAfterFailure = false
    let app = makeApplication(additionalArguments: [
      "-e2e-audio-session-configure-osstatus", "-50",
    ])

    app.launch()

    let setup = anyElement(app, "playback-setup-probe")
    XCTAssertTrue(setup.waitForExistence(timeout: 2))
    XCTAssertEqual(
      setup.value.map(String.init(describing:)),
      "setup=warning:domain=playback:diagnostic=OSStatus -50"
    )
    XCTAssertEqual(app.alerts.count, 0)
    XCTAssertFalse(app.staticTexts["Couldn’t Complete Import"].exists)
    XCTAssertTrue(app.otherElements["library-screen"].exists)
    XCTAssertTrue(
      terminateAndWait(app),
      "The startup-warning journey must leave a completed not-running handoff for the next selector"
    )
  }

  func testRejectsUnknownDynamicTypeConfigurationInsteadOfUsingMedium() {
    continueAfterFailure = false
    let app = bookshelfApplication()
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
    let app = bookshelfApplication()
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

  func testComputerReceiverVisibleActionsDriveProductionState() throws {
    continueAfterFailure = false

    let app = makeApplication()
    app.launch()
    app.buttons["receive-from-computer-empty-library"].tap()
    let receiver = app.scrollViews["computer-receiver-screen"]
    XCTAssertTrue(receiver.waitForStringValue("receiver:ready", timeout: 2))

    app.buttons["copy-computer-receiver-address"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["computer-receiver-address-copied"]
        .waitForExistence(timeout: 2)
    )

    app.buttons["stop-computer-receiver"].tap()
    let stopSheet = app.alerts["Stop receiving from this computer?"]
    XCTAssertTrue(stopSheet.waitForExistence(timeout: 2))
    app.buttons["Keep Receiving"].tap()
    XCTAssertTrue(receiver.waitForStringValue("receiver:ready", timeout: 2))
    app.buttons["stop-computer-receiver"].tap()
    XCTAssertTrue(stopSheet.waitForExistence(timeout: 2))
    app.buttons["Stop and Clean Up"].tap()
    XCTAssertTrue(app.otherElements["library-screen"].waitForExistence(timeout: 2))
    XCTAssertTrue(terminateAndWait(app))
  }

  func testComputerReceiverCloseWhileActiveConfirmsCleanup() {
    continueAfterFailure = false

    let app = makeApplication(additionalArguments: ["-e2e-computer-receiver-paused"])
    app.launch()
    app.buttons["receive-from-computer-empty-library"].tap()
    let activeReceiver = app.scrollViews["computer-receiver-screen"]
    XCTAssertTrue(activeReceiver.waitForStringValue("receiver:paused", timeout: 2))
    app.buttons["Close"].tap()
    let activeCloseSheet = app.alerts["Stop receiving from this computer?"]
    XCTAssertTrue(activeCloseSheet.waitForExistence(timeout: 2))
    app.buttons["Keep Receiving"].tap()
    XCTAssertTrue(activeReceiver.waitForStringValue("receiver:paused", timeout: 2))
    app.buttons["Close"].tap()
    XCTAssertTrue(activeCloseSheet.waitForExistence(timeout: 2))
    app.buttons["Stop and Clean Up"].tap()
    XCTAssertTrue(app.otherElements["library-screen"].waitForExistence(timeout: 2))
    XCTAssertTrue(terminateAndWait(app))
  }

  func testComputerReceiverRetriesListenerAndImportFailures() {
    continueAfterFailure = false

    var app = makeApplication(additionalArguments: ["-e2e-computer-receiver-listener-failure"])
    app.launch()
    app.buttons["receive-from-computer-empty-library"].tap()
    let failedStart = app.scrollViews["computer-receiver-screen"]
    XCTAssertTrue(failedStart.waitForStringValue("receiver:failed", timeout: 2))
    app.buttons["restart-computer-receiver"].tap()
    XCTAssertTrue(failedStart.waitForStringValue("receiver:ready", timeout: 2))
    XCTAssertTrue(terminateAndWait(app))

    app = makeApplication(additionalArguments: ["-e2e-computer-receiver-failed"])
    app.launch()
    app.buttons["receive-from-computer-empty-library"].tap()
    let failedImport = app.scrollViews["computer-receiver-screen"]
    XCTAssertTrue(failedImport.waitForStringValue("receiver:failed", timeout: 2))
    app.buttons["retry-computer-receiver-upload"].tap()
    XCTAssertTrue(failedImport.waitForStringValue("receiver:ready", timeout: 2))
    XCTAssertTrue(terminateAndWait(app))
  }

  func testComputerReceiverRoutesTerminalOutcomes() {
    continueAfterFailure = false

    var app = makeApplication(
      fixture: "receiver-completion-baseline",
      additionalArguments: ["-e2e-computer-receiver-needs-review"]
    )
    app.launch()
    app.tabBars.buttons["Add"].tap()
    let reviewReceiver = app.scrollViews["computer-receiver-screen"]
    XCTAssertTrue(reviewReceiver.waitForStringValue("receiver:needs-review", timeout: 2))
    app.buttons["open-received-import-inbox"].tap()
    XCTAssertTrue(app.tabBars.buttons["Inbox"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.tabBars.buttons["Inbox"].isSelected)
    XCTAssertTrue(terminateAndWait(app))

    app = makeApplication(
      fixture: "receiver-completion-baseline",
      additionalArguments: ["-e2e-computer-receiver-completed"]
    )
    let importingReceipt = DarwinEventReceipt(
      name: namespacedE2EEvent(
        "com.spnss.player.e2e.receiver-importing",
        for: app
      )
    )
    let completedReceipt = DarwinEventReceipt(
      name: namespacedE2EEvent(
        "com.spnss.player.e2e.receiver-completed",
        for: app
      )
    )
    XCTAssertNotNil(importingReceipt)
    XCTAssertNotNil(completedReceipt)
    app.launch()
    app.tabBars.buttons["Add"].tap()
    let completedReceiver = app.scrollViews["computer-receiver-screen"]
    XCTAssertTrue(
      importingReceipt?.wait(timeout: 2) == true,
      "The receiver did not begin the production import within two seconds"
    )
    XCTAssertTrue(
      completedReceipt?.wait(timeout: 2) == true,
      "The receiver did not commit its production import within two seconds of inspection"
    )
    XCTAssertTrue(completedReceiver.waitForStringValue("receiver:completed:1", timeout: 2))
    app.buttons["finish-computer-receiver"].tap()
    XCTAssertTrue(
      app.otherElements["library-screen"].waitForStringValue("ready:library-2-books", timeout: 2)
    )
    XCTAssertTrue(terminateAndWait(app))
  }

  func testRejectsUnknownFixtureWithoutFallingBackToProduction() {
    continueAfterFailure = false
    let app = bookshelfApplication()
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
      title: "Bookshelf launches into an empty local library",
      narrative:
        "As a new listener, I want Bookshelf to open into a ready and understandable library so I can add my first audiobook.",
      fixture: "empty-library"
    )

    app.launch()

    try tester.step(
      "empty-library",
      description: "Bookshelf launches into the ready empty-library state",
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
      ],
      captureReadiness: launchCaptureReadiness(
        app: app,
        specification: "At capture, the exact empty Library layout is settled with every first-run action fully visible and no transient presentation",
        anchor: app.otherElements["library-screen"]
      ) {
        let screen = app.otherElements["library-screen"]
        return self.hasExactValue(screen, "ready:library-empty")
          && self.hasSettledScreenGeometry(screen, in: app)
          && elementIsFullyVisible(
            app.staticTexts["Build your listening library"],
            within: screen,
            requiresHittable: false
          )
          && elementIsFullyVisible(
            app.buttons["receive-from-computer-empty-library"], within: screen
          )
          && elementIsFullyVisible(
            app.buttons["choose-from-files-empty-library"], within: screen
          )
          && app.tabBars.buttons["Library"].isSelected
          && !app.otherElements["mini-player"].exists
      }
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
        .valueEquals(
          anyElement(app, "computer-receiver-production-evidence"),
          "event=http:GET:/:status=200",
          "Ready state is backed by the production server exchange"
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
          app.staticTexts["Using a Mac?"],
          "Supported locales also see the optional iPhone Mirroring path"
        ),
      ],
      captureReadiness: receiverCaptureReadiness(
        app: app,
        specification: "At capture, the exact ready receiver is idle at the top with stable pairing, address, and import guidance",
        state: "receiver:ready"
      ) {
        self.hasExactValue(
          self.anyElement(app, "computer-receiver-http-probe"),
          "http:GET:/:status=200"
        )
          && self.hasExactValue(
            self.anyElement(app, "computer-receiver-production-evidence"),
            "event=http:GET:/:status=200"
          )
          && app.staticTexts["computer-receiver-address"].label
            == "http://192.168.1.42:49152"
          && elementIsFullyVisible(
            app.staticTexts["computer-receiver-pairing-code"],
            within: app.scrollViews["computer-receiver-screen"],
            requiresHittable: false
          )
          && elementIsFullyVisible(
            app.staticTexts["Using a Mac?"],
            within: app.scrollViews["computer-receiver-screen"],
            requiresHittable: false
          )
      }
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
        .valueEquals(
          anyElement(receivingApp, "computer-receiver-production-evidence"),
          "event=drop-progress:name=Project Hail Mary:1-of-3",
          "The state comes from the production drop materializer's progress callback"
        ),
      ],
      captureReadiness: receiverCaptureReadiness(
        app: receivingApp,
        specification: "At capture, the mirrored-drop receiver is idle at the top with its exact preparation phase and visible progress item",
        state: "receiver:preparing-mirrored-drop"
      ) {
        elementIsFullyVisible(
          receivingApp.progressIndicators["mirroring-drop-progress"],
          within: receivingApp.scrollViews["computer-receiver-screen"],
          requiresHittable: false
        )
          && self.hasExactValue(
            self.anyElement(receivingApp, "computer-receiver-production-evidence"),
            "event=drop-progress:name=Project Hail Mary:1-of-3"
          )
          && elementIsFullyVisible(
            receivingApp.staticTexts["Project Hail Mary"],
            within: receivingApp.scrollViews["computer-receiver-screen"],
            requiresHittable: false
          )
      }
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
          "receiving:734003-of-1468006",
          "The iPhone reports the exact confirmed byte count"
        ),
        .valueEquals(
          anyElement(pausedApp, "computer-receiver-production-evidence"),
          "event=http-paused:name=Project Hail Mary:734003-of-1468006",
          "The paused state is backed by the server's interrupted-upload event"
        ),
        .exists(
          pausedApp.staticTexts[
            "The computer can retry from the confirmed progress shown here."
          ],
          "The listener is told that retry continues from confirmed progress"
        ),
      ],
      captureReadiness: receiverCaptureReadiness(
        app: pausedApp,
        specification: "At capture, the paused receiver is idle at the top with its exact confirmed-byte state and retry guidance visible",
        state: "receiver:paused"
      ) {
        self.hasExactValue(
          pausedApp.descendants(matching: .any)["computer-receiver-transfer"],
          "receiving:734003-of-1468006"
        )
          && self.hasExactValue(
            self.anyElement(pausedApp, "computer-receiver-production-evidence"),
            "event=http-paused:name=Project Hail Mary:734003-of-1468006"
          )
          && elementIsFullyVisible(
            pausedApp.staticTexts[
              "The computer can retry from the confirmed progress shown here."
            ],
            within: pausedApp.scrollViews["computer-receiver-screen"],
            requiresHittable: false
          )
      }
    )

    XCTAssertTrue(terminateAndWait(pausedApp))
    let completedApp = makeApplication(
      fixture: "receiver-completion-baseline",
      additionalArguments: ["-e2e-computer-receiver-completed"]
    )
    completedApp.launch()
    completedApp.tabBars.buttons["Add"].tap()
    XCTAssertTrue(
      completedApp.scrollViews["computer-receiver-screen"].waitForExistence(timeout: 2)
    )
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
        .valueEquals(
          anyElement(completedApp, "computer-receiver-production-evidence"),
          "event=http-completed:reported-books=1:model-books=1:committed-jobs=1:corroborated=true",
          "The receiver completion is corroborated by one new Book and committed import job"
        ),
      ],
      captureReadiness: receiverCaptureReadiness(
        app: completedApp,
        specification: "At capture, the completed receiver is idle at the top with its exact completion count and both next actions visible",
        state: "receiver:completed:1"
      ) {
        elementIsFullyVisible(
          completedApp.buttons["receive-another-audiobook"],
          within: completedApp.scrollViews["computer-receiver-screen"]
        )
          && self.hasExactValue(
            self.anyElement(completedApp, "computer-receiver-production-evidence"),
            "event=http-completed:reported-books=1:model-books=1:committed-jobs=1:corroborated=true"
          )
          && elementIsFullyVisible(
            completedApp.buttons["finish-computer-receiver"],
            within: completedApp.scrollViews["computer-receiver-screen"]
          )
      }
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
      ],
      captureReadiness: receiverCaptureReadiness(
        app: completedApp,
        specification: "At capture, Receive Another has returned the same receiver to its idle ready layout with pairing details visible",
        state: "receiver:ready"
      ) {
        elementIsFullyVisible(
          completedApp.staticTexts["computer-receiver-pairing-code"],
          within: completedApp.scrollViews["computer-receiver-screen"],
          requiresHittable: false
        )
          && elementIsFullyVisible(
            completedApp.staticTexts["computer-receiver-address"],
            within: completedApp.scrollViews["computer-receiver-screen"],
            requiresHittable: false
          )
      }
    )

    tester.generateDocs()
  }

  private func makeApplication(
    fixture: String = "empty-library",
    additionalArguments: [String] = []
  ) -> XCUIApplication {
    let app = bookshelfApplication()
    app.launchArguments += [
      "-e2e",
      "-e2e-reset",
      "-e2e-fixture",
      fixture,
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
    uniquelyIdentifiedElement(app, identifier)
  }

  private func launchCaptureReadiness(
    app: XCUIApplication,
    specification: String,
    anchor: XCUIElement,
    intendedSheetContentID: String? = nil,
    checkNow: @escaping @MainActor () -> Bool
  ) -> CaptureReadiness {
    CaptureReadiness(specification: specification, anchor: anchor) {
      checkNow()
        && app.keyboards.count == 0
        && app.alerts.count == 0
        && !self.hasUnintendedSheet(app, intendedContentID: intendedSheetContentID)
    }
  }

  private func receiverCaptureReadiness(
    app: XCUIApplication,
    specification: String,
    state: String,
    checkNow: @escaping @MainActor () -> Bool
  ) -> CaptureReadiness {
    let screen = app.scrollViews["computer-receiver-screen"]
    let readiness = anyElement(app, "computer-receiver-scroll-readiness")
    return launchCaptureReadiness(
      app: app,
      specification: specification,
      anchor: readiness,
      intendedSheetContentID: "computer-receiver-screen"
    ) {
      self.hasExactValue(screen, state)
        && self.isSettledAtTop(
          readiness,
          containerID: "computer-receiver-scroll"
        )
        && checkNow()
    }
  }

  private func hasExactValue(_ element: XCUIElement, _ expected: String) -> Bool {
    element.exists && element.value.map(String.init(describing:)) == expected
  }

  private func hasSettledScreenGeometry(
    _ screen: XCUIElement,
    in app: XCUIApplication
  ) -> Bool {
    let window = app.windows.element
    guard screen.exists, window.exists else { return false }
    let screenFrame = screen.frame
    let windowFrame = window.frame
    return !screenFrame.isEmpty
      && screenFrame.width >= windowFrame.width - 2
      && windowFrame.intersects(screenFrame)
  }

  private func isSettledAtTop(_ probe: XCUIElement, containerID: String) -> Bool {
    guard let state = ScrollReadinessState(probe.value) else { return false }
    let completionIsCorrelated = state.interactionID == 0
      ? state.completionID == 0
      : state.completionID == state.interactionID
        && state.completionGeometryID == state.geometryID
    return state.containerID == containerID
      && state.axis == .vertical
      && state.isIdle
      && state.geometryReady
      && completionIsCorrelated
      && state.atTop
  }

  private func hasUnintendedSheet(
    _ app: XCUIApplication,
    intendedContentID: String?
  ) -> Bool {
    app.sheets.allElementsBoundByIndex.contains { sheet in
      guard let intendedContentID else { return true }
      return sheet.identifier != intendedContentID
        && !sheet.descendants(matching: .any)[intendedContentID].exists
    }
  }
}
