import Foundation
import XCTest

@MainActor
final class AppStoreListingUITests: PlayerUITestCase {
  func testCapturesCanonicalMarketingSurfaces() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "App Store and website marketing surfaces stay current",
      narrative:
        "As a prospective listener, I want the product page to show the real library, import, playback, and purchase experience.",
      fixture: "marketing-surfaces",
      additionalPreconditions: [
        "Every image uses fixed synthetic audiobook metadata and artwork.",
        "Harbor at Dawn uses committed, generated fictional cover artwork made for this marketing fixture.",
        "The Library capture omits the manually curated Up Next queue so the bookshelf remains prominent.",
        "The listing and website build scripts consume the fresh ActualWalkthrough output from this story.",
        "No marketing screenshot is maintained as a second copied source file.",
      ]
    )

    let library = try makePopulatedLibraryApplication()
    library.launch()
    let libraryScreen = library.otherElements["library-screen"]
    let libraryScrollReadiness = anyElement(library, "library-root-scroll-readiness")
    let recentShelf = library.scrollViews["library-home-recent-shelf-scroll"]
    let recentShelfSection = anyElement(library, "library-home-recently-added-shelf")
    let recentShelfReadiness = anyElement(
      library,
      "library-home-recent-shelf-scroll-readiness"
    )
    let artworkReadiness = anyElement(library, "library-artwork-probe")
    XCTAssertTrue(
      recentShelf.waitForExistence(timeout: TestStepHelper.conditionTimeout),
      "The recent shelf must expose its dedicated ScrollView identifier"
    )
    XCTAssertEqual(
      library.scrollViews.matching(identifier: "library-home-recent-shelf-scroll").count,
      1,
      "The recent shelf must expose exactly one ScrollView"
    )
    XCTAssertEqual(
      library.descendants(matching: .any)
        .matching(identifier: "library-home-recently-added-shelf").count,
      1,
      "The section semantics must remain distinct from its ScrollView"
    )
    try tester.step(
      "library",
      description: "The library gives owned audiobooks a warm, useful home",
      verifications: [
        .exists(libraryScreen, "The Library screen is visible"),
        .exists(library.staticTexts["Continue Listening"], "Listening progress is immediately useful"),
        .exists(library.staticTexts["Recently Added"], "Recent cover artwork is visible"),
        .exists(recentShelfSection, "The recent shelf section has distinct semantics"),
        .exists(library.otherElements["mini-player"], "The current book stays within reach"),
      ],
      captureReadiness: marketingCaptureReadiness(
        app: library,
        specification: "At capture, the exact five-book Library has no Up Next queue, and its decoded cover shelf is idle at the start with four recent cards and a paused mini-player",
        anchor: recentShelfReadiness
      ) {
        let recentCards = library.descendants(matching: .any)
          .matching(NSPredicate(format: "identifier BEGINSWITH %@", "recent-book-"))
          .allElementsBoundByIndex
        return self.hasExactValue(libraryScreen, "ready:library-5-books")
          && self.hasExactValue(
            artworkReadiness,
            "artwork:ready=90000000-0000-0000-0000-000000000001,"
              + "90000000-0000-0000-0000-000000000002,"
              + "90000000-0000-0000-0000-000000000003,"
              + "90000000-0000-0000-0000-000000000004,"
              + "90000000-0000-0000-0000-000000000005:count=5"
          )
          && self.hasExactValue(
            library.otherElements["mini-player"],
            "player:paused:90000000-0000-0000-0000-000000000001:0:45000"
          )
          && self.isSettledAtTop(
            libraryScrollReadiness,
            containerID: "library-root-scroll"
          )
          && self.isSettledAtStart(
            recentShelfReadiness,
            containerID: "library-home-recent-shelf-scroll",
            axis: .horizontal
          )
          && recentShelf.exists
          && recentShelfSection.exists
          && library.scrollViews
            .matching(identifier: "library-home-recent-shelf-scroll").count == 1
          && library.descendants(matching: .any)
            .matching(identifier: "library-home-recently-added-shelf").count == 1
          && recentCards.count == 4
      }
    )
    XCTAssertTrue(terminateAndWait(library))

    let receiver = makeApplication(
      fixture: "empty-library",
      extraArguments: ["-e2e-computer-receiver-ready", "-e2e-show-mirroring-tip"]
    )
    receiver.launch()
    receiver.buttons["receive-from-computer-empty-library"].tap()
    let receiverScreen = receiver.scrollViews["computer-receiver-screen"]
    let receiverScrollReadiness = anyElement(receiver, "computer-receiver-scroll-readiness")
    let pairingCode = receiver.staticTexts["computer-receiver-pairing-code"]
    let chooseFromFiles = receiver.buttons["choose-from-files-computer-receiver"]
    let receiverEvidence = anyElement(receiver, "computer-receiver-production-evidence")
    let mirroringGuidance = receiver.staticTexts["Using a Mac?"]
    try tester.step(
      "receiver-ready",
      description: "The private receiver accepts books through a browser on any computer",
      verifications: [
        .valueEquals(receiverScreen, "receiver:ready", "The receiver is ready"),
        .valueEquals(
          receiverEvidence,
          "event=http:GET:/:status=200",
          "The ready state is backed by the production HTTP server"
        ),
        .exists(pairingCode, "The pairing code is visible"),
        .exists(mirroringGuidance, "Supported locales show iPhone Mirroring guidance"),
        .exists(chooseFromFiles, "Files remains available"),
      ],
      captureReadiness: marketingCaptureReadiness(
        app: receiver,
        specification: "At capture, the ready receiver has settled pairing, Mirroring guidance, and fully visible file controls",
        anchor: receiverScreen,
        intendedSheetContentID: "computer-receiver-screen"
      ) {
        self.hasExactValue(receiverScreen, "receiver:ready")
          && self.hasExactValue(receiverEvidence, "event=http:GET:/:status=200")
          && self.isSettledAtTop(
            receiverScrollReadiness,
            containerID: "computer-receiver-scroll"
          )
          && elementIsFullyVisible(pairingCode, within: receiverScreen, requiresHittable: false)
          && elementIsFullyVisible(
            mirroringGuidance,
            within: receiverScreen,
            requiresHittable: false
          )
          && elementIsFullyVisible(chooseFromFiles, within: receiverScreen)
          && elementIsFullyVisible(
            receiver.buttons["stop-computer-receiver"],
            within: receiverScreen
          )
      }
    )
    XCTAssertTrue(terminateAndWait(receiver))

    let progress = makeApplication(
      fixture: "empty-library",
      extraArguments: [
        "-e2e-computer-receiver-ready", "-e2e-show-mirroring-tip",
        "-e2e-mirroring-drop-progress",
      ]
    )
    progress.launch()
    progress.buttons["receive-from-computer-empty-library"].tap()
    let progressScreen = progress.scrollViews["computer-receiver-screen"]
    let progressScrollReadiness = anyElement(progress, "computer-receiver-scroll-readiness")
    let dropProgress = progress.progressIndicators["mirroring-drop-progress"]
    let incomingTitle = progress.staticTexts["Project Hail Mary"]
    let progressEvidence = anyElement(progress, "computer-receiver-production-evidence")
    try tester.step(
      "mirroring-drop-progress",
      description: "iPhone Mirroring makes Finder drag-and-drop the fastest Mac path",
      verifications: [
        .valueEquals(progressScreen, "receiver:preparing-mirrored-drop", "The mirrored drop is being prepared"),
        .exists(dropProgress, "Import progress is visible"),
        .exists(incomingTitle, "The incoming audiobook is named"),
        .valueEquals(
          progressEvidence,
          "event=drop-progress:name=Project Hail Mary:1-of-3",
          "The visible state is backed by the production drop progress callback"
        ),
      ],
      captureReadiness: marketingCaptureReadiness(
        app: progress,
        specification: "At capture, the exact mirrored-drop phase and item-two-of-three progress layout are settled",
        anchor: progressScreen,
        intendedSheetContentID: "computer-receiver-screen"
      ) {
        self.hasExactValue(progressScreen, "receiver:preparing-mirrored-drop")
          && self.hasExactValue(
            progressEvidence,
            "event=drop-progress:name=Project Hail Mary:1-of-3"
          )
          && self.isSettledAtTop(
            progressScrollReadiness,
            containerID: "computer-receiver-scroll"
          )
          && elementIsFullyVisible(dropProgress, within: progressScreen, requiresHittable: false)
          && elementIsFullyVisible(incomingTitle, within: progressScreen, requiresHittable: false)
          && elementIsFullyVisible(
            progress.staticTexts["Preparing dropped item 2 of 3…"],
            within: progressScreen,
            requiresHittable: false
          )
      }
    )
    XCTAssertTrue(terminateAndWait(progress))

    let playback = makeApplication(
      fixture: "metadata-rich-book",
      extraArguments: [
        "-e2e-metadata-rich-namespace", "app-store-listing-playback",
        "-e2e-start-section", "settings",
      ]
    )
    playback.launchEnvironment["PLAYER_E2E_METADATA_RICH_COVER_BASE64"] = try fixtureData(
      resource: "harbor-at-dawn-cover", extension: "png"
    ).base64EncodedString()
    playback.launch()
    let playbackDefaults = playback.buttons["playback-defaults"]
    XCTAssertTrue(playbackDefaults.waitForExistence(timeout: 2))
    playbackDefaults.tap()
    let preferences = anyElement(playback, "transport-preferences-screen")
    XCTAssertTrue(preferences.waitForExistence(timeout: 2))
    try choose(
      playback, picker: "transport-rate-picker", option: "1.25×", preferences: preferences,
      expected: "transport:scope=global:rate=1.25:back=15:forward=30:seek=chapter"
    )
    try choose(
      playback, picker: "transport-backward-picker", option: "10 seconds",
      preferences: preferences,
      expected: "transport:scope=global:rate=1.25:back=10:forward=30:seek=chapter"
    )
    try choose(
      playback, picker: "transport-forward-picker", option: "45 seconds",
      preferences: preferences,
      expected: "transport:scope=global:rate=1.25:back=10:forward=45:seek=chapter"
    )
    try choose(
      playback, picker: "transport-forward-picker", option: "30 seconds",
      preferences: preferences,
      expected: "transport:scope=global:rate=1.25:back=10:forward=30:seek=chapter"
    )
    let preferencesReadiness = anyElement(playback, "transport-preferences-scroll-readiness")
    try tester.step(
      "playback-settings",
      description: "Playback defaults make speed, skips, and seeking personal",
      verifications: [
        .valueEquals(preferences, "transport:scope=global:rate=1.25:back=10:forward=30:seek=chapter", "The chosen defaults are visible"),
        .exists(playback.buttons["transport-rate-picker"], "Playback speed is configurable"),
        .exists(playback.buttons["transport-backward-picker"], "Backward skip is configurable"),
        .exists(playback.buttons["transport-forward-picker"], "Forward skip is configurable"),
      ],
      captureReadiness: marketingCaptureReadiness(
        app: playback,
        specification: "At capture, the exact personalized playback defaults are idle at the top with every picker fully visible and no menu left open",
        anchor: preferencesReadiness
      ) {
        self.hasExactValue(
          preferences,
          "transport:scope=global:rate=1.25:back=10:forward=30:seek=chapter"
        )
          && self.isSettledAtTop(
            preferencesReadiness,
            containerID: "transport-preferences-screen"
          )
          && elementIsFullyVisible(
            playback.buttons["transport-rate-picker"], within: preferences
          )
          && elementIsFullyVisible(
            playback.buttons["transport-backward-picker"], within: preferences
          )
          && elementIsFullyVisible(
            playback.buttons["transport-forward-picker"], within: preferences
          )
      }
    )
    playback.buttons["save-transport-preferences"].tap()
    playback.tabBars.buttons["Library"].tap()
    playback.staticTexts["Harbor at Dawn"].tap()
    XCTAssertTrue(playback.buttons["chapter-2"].waitForExistence(timeout: 2))
    playback.buttons["chapter-2"].tap()
    let nowPlaying = playback.otherElements["now-playing-screen"]
    let nowPlayingReadiness = anyElement(playback, "now-playing-layout-readiness")
    let nowPlayingArtwork = nowPlaying.descendants(matching: .any)["embedded-cover-artwork"]
    try tester.step(
      "now-playing",
      description: "Now Playing keeps chapters and custom controls close",
      verifications: [
        .exists(nowPlaying, "Now Playing is visible"),
        .exists(playback.buttons["player-previous-chapter"], "Previous chapter is available"),
        .exists(playback.buttons["player-next-chapter"], "Next chapter is available"),
        .exists(playback.buttons["open-transport-preferences"], "Playback settings remain close"),
      ],
      captureReadiness: marketingCaptureReadiness(
        app: playback,
        specification: "At capture, chapter two is playing with exact custom transport values, decoded Harbor artwork, and settled Now Playing geometry",
        anchor: nowPlayingReadiness,
        intendedSheetContentID: "now-playing-screen"
      ) {
        self.hasExactValue(
          nowPlaying,
          "player:playing:30000000-0000-0000-0000-000000000001:1:30000"
        )
          && self.hasExactValue(
            playback.buttons["open-transport-preferences"],
            "rate=1.25:back=10:forward=30:seek=chapter:source=global"
          )
          && self.hasSettledLayout(
            nowPlayingReadiness,
            containerID: "now-playing-screen"
          )
          && elementIsFullyVisible(nowPlayingArtwork, within: nowPlaying, requiresHittable: false)
          && elementIsFullyVisible(playback.buttons["player-previous-chapter"], within: nowPlaying)
          && elementIsFullyVisible(playback.buttons["player-next-chapter"], within: nowPlaying)
          && elementIsFullyVisible(
            playback.buttons["open-transport-preferences"], within: nowPlaying
          )
      }
    )
    playback.buttons["open-sleep-timer"].tap()
    let sleepTimerScreen = anyElement(playback, "sleep-timer-screen")
    let sleepTimerReadiness = anyElement(playback, "sleep-timer-scroll-readiness")
    try tester.step(
      "sleep-timer",
      description: "The sleep timer adapts to minutes, chapters, or tracks",
      verifications: [
        .exists(sleepTimerScreen, "The Sleep Timer screen is visible"),
        .exists(playback.buttons["sleep-timer-preset-30"], "A 30-minute preset is available"),
        .exists(playback.buttons["sleep-timer-end-chapter"], "End of chapter is available"),
        .exists(playback.switches["sleep-timer-fade"], "Gentle fade is configurable"),
      ],
      captureReadiness: marketingCaptureReadiness(
        app: playback,
        specification: "At capture, the inactive gentle-fade timer is idle at the top with minute and boundary choices fully laid out",
        anchor: sleepTimerReadiness,
        intendedSheetContentID: "sleep-timer-screen"
      ) {
        self.hasExactValue(
          sleepTimerScreen,
          "sleep-timer:active=none:fade=true:history=0"
        )
          && self.isSettledAtTop(
            sleepTimerReadiness,
            containerID: "sleep-timer-screen"
          )
          && elementIsFullyVisible(
            playback.switches["sleep-timer-fade"], within: sleepTimerScreen
          )
          && elementIsFullyVisible(
            playback.buttons["sleep-timer-preset-30"], within: sleepTimerScreen
          )
          && elementIsFullyVisible(
            playback.buttons["sleep-timer-end-chapter"], within: sleepTimerScreen
          )
      }
    )
    XCTAssertTrue(terminateAndWait(playback))

    let unlock = makeApplication(
      fixture: "monetization-exhausted",
      extraArguments: [
        "-e2e-start-section", "settings",
        "-e2e-start-settings-route", "full-unlock",
      ]
    )
    unlock.launch()
    let unlockScreen = unlock.scrollViews["full-unlock-screen"]
    let purchase = unlock.buttons["full-unlock-purchase"]
    let unlockReadiness = anyElement(unlock, "full-unlock-scroll-readiness")
    let monetizationState = anyElement(unlock, "e2e-monetization-state")
    XCTAssertTrue(waitForPredicate(
      NSPredicate(format: "value CONTAINS %@", "phase=awaiting-products"),
      on: monetizationState,
      timeout: EventDeadline().remaining
    ))
    let completeProducts = unlock.buttons["e2e-monetization-complete-products"]
    XCTAssertTrue(waitForExistence(completeProducts, deadline: EventDeadline()))
    completeProducts.tap()
    XCTAssertTrue(waitForPredicate(
      NSPredicate(format: "label == %@", "Unlock Forever — $9.99"),
      on: purchase,
      timeout: EventDeadline().remaining
    ))
    try tester.step(
      "full-unlock",
      description: "The one-time Full Unlock is clear and subscription-free",
      verifications: [
        .exists(unlockScreen, "The Full Unlock screen is visible"),
        .exists(purchase, "The one-time purchase is available"),
        .exists(unlock.staticTexts["One-time purchase · No subscription"], "The purchase model is explicit"),
        .exists(unlock.buttons["full-unlock-restore"], "Purchase restoration is available"),
        .exists(
          unlock.buttons["full-unlock-support"], "Support is available before purchase"
        ),
        .exists(
          unlock.buttons["full-unlock-privacy"], "The privacy policy is available before purchase"
        ),
      ],
      captureReadiness: marketingCaptureReadiness(
        app: unlock,
        specification: "At capture, the exhausted allowance and exact $9.99 one-time unlock are settled with all purchase actions visible",
        anchor: purchase
      ) {
        let librarySafety = unlock.staticTexts["full-unlock-library-safety"]
        return purchase.exists
          && purchase.label == "Unlock Forever — $9.99"
          && unlock.staticTexts[
            "0m remaining from the 50 hours included with Bookshelf. Pay once to keep listening without a limit."
          ].exists
          && self.isSettledAtTop(
            unlockReadiness,
            containerID: "full-unlock-screen"
          )
          && elementIsFullyVisible(purchase, within: unlockScreen)
          && elementIsFullyVisible(
            unlock.staticTexts["One-time purchase · No subscription"],
            within: unlockScreen,
            requiresHittable: false
          )
          && elementIsFullyVisible(
            unlock.buttons["full-unlock-restore"], within: unlockScreen
          )
          && elementIsFullyVisible(
            unlock.buttons["full-unlock-redeem-code"], within: unlockScreen
          )
          && elementIsFullyVisible(
            librarySafety,
            within: unlock.windows.element,
            obscuredBelow: unlock.otherElements["mini-player"],
            requiresHittable: false
          )
      }
    )
    XCTAssertTrue(terminateAndWait(unlock))

    tester.generateDocs()
  }

  private func makeApplication(
    fixture: String,
    extraArguments: [String] = []
  ) -> XCUIApplication {
    let app = bookshelfApplication()
    app.launchArguments = [
      "-e2e", "-e2e-reset", "-e2e-fixture", fixture,
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ] + extraArguments
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func makePopulatedLibraryApplication() throws -> XCUIApplication {
    let app = makeApplication(
      fixture: "synthetic-populated-library",
      extraArguments: ["-e2e-computer-receiver-ready"]
    )
    let fixtureDescriptor = try fixtureData(
      resource: "synthetic-populated-library-fixture", extension: "json"
    )
    var marketingDescriptor = try XCTUnwrap(
      JSONSerialization.jsonObject(with: fixtureDescriptor) as? [String: Any]
    )
    marketingDescriptor["upNext"] = []
    app.launchEnvironment["PLAYER_E2E_LIBRARY_DESCRIPTOR_BASE64"] = try JSONSerialization.data(
      withJSONObject: marketingDescriptor,
      options: [.sortedKeys]
    ).base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_LIBRARY_AUDIO_BASE64"] = try fixtureData(
      resource: "library-book-audio", extension: "m4b"
    ).base64EncodedString()
    for index in 1...5 {
      app.launchEnvironment["PLAYER_E2E_LIBRARY_COVER_B\(index)_BASE64"] = try fixtureData(
        resource: "library-cover-b\(index)", extension: "png"
      ).base64EncodedString()
    }
    return app
  }

  private func fixtureData(resource: String, extension fileExtension: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: resource, withExtension: fileExtension)
    )
    return try Data(contentsOf: url)
  }

  private func choose(
    _ app: XCUIApplication,
    picker identifier: String,
    option: String,
    preferences: XCUIElement,
    expected: String
  ) throws {
    let pickerDeadline = EventDeadline()
    let pickers = app.buttons.matching(identifier: identifier)
    let picker = pickers.element
    XCTAssertTrue(waitForExistence(picker, deadline: pickerDeadline))
    XCTAssertEqual(pickers.count, 1, "Picker \(identifier) must be unique")
    picker.tap()
    let choices = app.buttons.matching(NSPredicate(format: "label == %@", option))
    let choice = choices.element
    XCTAssertTrue(waitForExistence(choice, deadline: EventDeadline()))
    XCTAssertEqual(choices.count, 1, "Picker option \(option) must be unique")
    choice.tap()
    guard preferences.waitForStringValue(expected, timeout: EventDeadline().remaining) else {
      XCTFail("Picker \(identifier) did not publish \(expected); actual=\(preferences.value ?? "nil")")
      throw AppStoreListingTestError.valueUnavailable
    }
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    uniquelyIdentifiedElement(app, identifier)
  }

  private func marketingCaptureReadiness(
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

  private func hasExactValue(_ element: XCUIElement, _ expected: String) -> Bool {
    element.exists && element.value.map(String.init(describing:)) == expected
  }

  private func isSettledAtTop(_ probe: XCUIElement, containerID: String) -> Bool {
    isSettledAtStart(probe, containerID: containerID, axis: .vertical)
  }

  private func isSettledAtStart(
    _ probe: XCUIElement,
    containerID: String,
    axis: E2EScrollAxis
  ) -> Bool {
    guard let state = ScrollReadinessState(probe.value) else { return false }
    return state.containerID == containerID
      && state.axis == axis
      && state.isIdle
      && (axis == .vertical ? state.atTop : state.atLeft)
  }

  private func hasSettledLayout(_ probe: XCUIElement, containerID: String) -> Bool {
    guard let state = LayoutReadinessState(probe.value) else { return false }
    return state.containerID == containerID
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

private enum AppStoreListingTestError: Error {
  case valueUnavailable
}
