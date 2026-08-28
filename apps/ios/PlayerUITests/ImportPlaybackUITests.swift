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
    let reviewScreen = anyElement(app, "review-import-screen")
    let expectedReview = "proposal:ready:1-book:1-tracks:0-warnings"
    let reviewArtwork = anyElement(app, "placeholder-artwork")

    try tester.step(
      "review-import",
      description: "The inspected audiobook is ready for review",
      verifications: [
        .exists(
          reviewScreen,
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
      ],
      captureReadiness: importCaptureReadiness(
        app: app,
        specification: "At capture, the exact ready one-book/one-track proposal, placeholder artwork, metadata, and enabled pinned commit action are fully settled",
        anchor: reviewScreen
      ) {
        self.hasExactValue(reviewScreen, expectedReview)
          && self.hasExactValue(addToLibrary, "ready:enabled")
          && addToLibrary.isEnabled
          && elementIsFullyVisible(addToLibrary, within: reviewScreen)
          && elementIsFullyVisible(
            reviewArtwork,
            within: reviewScreen,
            requiresHittable: false
          )
          && app.staticTexts["The Lighthouse Signal"].exists
          && app.staticTexts["Mara Vale"].exists
      }
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
    let organizer = anyElement(app, "library-organizer-probe")
    let artwork = anyElement(app, "library-artwork-probe")
    let libraryScroll = anyElement(app, "library-root-scroll")
    let libraryReadiness = anyElement(app, "library-root-scroll-readiness")
    let recentShelf = anyElement(app, "library-home-recent-shelf-scroll")
    let recentReadiness = anyElement(app, "library-home-recent-shelf-scroll-readiness")
    let recentBook = anyElement(
      app,
      "recent-book-10000000-0000-0000-0000-000000000004"
    )
    let expectedOrganizer =
      "library:books=1:continue=:up-next=:finished=:collections=0:trash=0:view=shelf:current=none:position=0"

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
      ],
      captureReadiness: importCaptureReadiness(
        app: app,
        specification: "At capture, the exact one-book committed Library and no-artwork evidence are idle at the Library and Recently Added starts with the book card fully visible",
        anchor: recentReadiness
      ) {
        self.hasExactValue(libraryScreen, "ready:library-1-books")
          && self.hasExactValue(organizer, expectedOrganizer)
          && self.hasExactValue(artwork, "artwork:ready=:count=0")
          && self.isSettled(
            libraryReadiness,
            containerID: "library-root-scroll",
            axis: .vertical,
            endpoint: \.atTop
          )
          && self.isSettled(
            recentReadiness,
            containerID: "library-home-recent-shelf-scroll",
            axis: .horizontal,
            endpoint: \.atLeft
          )
          && elementIsFullyVisible(
            recentBook,
            within: recentShelf,
            requiresHittable: false
          )
          && elementIsFullyVisible(addAudiobook, within: app.tabBars.element)
      }
    )

    app.staticTexts["The Lighthouse Signal"].tap()
    let bookDetail = anyElement(app, "book-detail-screen")
    let bookScroll = anyElement(app, "book-detail-scroll")
    let bookReadiness = anyElement(app, "book-detail-scroll-readiness")
    let playBook = app.buttons["play-book"]
    try tester.step(
      "book-detail",
      description: "Book Detail exposes the playable managed audiobook",
      verifications: [
        .exists(
          bookDetail,
          "The Book Detail screen is visible"
        ),
        .exists(playBook, "The audiobook has a Play action"),
        .exists(app.staticTexts["1 file · 18m"], "The inspected asset count and duration are retained"),
      ],
      captureReadiness: importCaptureReadiness(
        app: app,
        specification: "At capture, the exact committed book detail is idle at its production scroll start with playable metadata and action fully visible",
        anchor: bookReadiness
      ) {
        self.hasExactValue(
          bookDetail,
          "book:ready:10000000-0000-0000-0000-000000000004:0-chapters:m4a"
        )
          && self.isSettled(
            bookReadiness,
            containerID: "book-detail-scroll",
            axis: .vertical,
            endpoint: \.atTop
          )
          && elementIsFullyVisible(playBook, within: bookScroll)
          && app.staticTexts["The Lighthouse Signal"].exists
          && app.staticTexts["1 file · 18m"].exists
      }
    )

    app.buttons["play-book"].tap()
    XCTAssertTrue(app.buttons["player-play-pause"].waitForExistence(timeout: 2))
    app.buttons["player-play-pause"].tap()
    let nowPlaying = app.otherElements["now-playing-screen"]
    let nowPlayingLayout = anyElement(app, "now-playing-layout-readiness")
    let playerButton = app.buttons["player-play-pause"]
    let playerSlider = app.sliders["player-position-slider"]
    let expectedPlayer =
      "player:paused:10000000-0000-0000-0000-000000000004:0:0"

    try tester.step(
      "paused-now-playing",
      description: "Now Playing has loaded and paused the managed audio",
      verifications: [
        .valueEquals(
          nowPlaying,
          expectedPlayer,
          "The deterministic engine acknowledges a paused loaded book"
        ),
        .exists(app.staticTexts["The Lighthouse Signal"], "Now Playing retains the book identity"),
        .exists(playerButton, "The transport remains available"),
      ],
      captureReadiness: importCaptureReadiness(
        app: app,
        specification: "At capture, the exact paused zero-position player state and transport are fully laid out without transient presentation",
        anchor: nowPlayingLayout
      ) {
        self.hasExactValue(nowPlaying, expectedPlayer)
          && self.hasSettledLayout(nowPlayingLayout, containerID: "now-playing-screen")
          && elementIsFullyVisible(playerButton, within: nowPlaying)
          && elementIsFullyVisible(playerSlider, within: nowPlaying)
          && app.staticTexts["The Lighthouse Signal"].exists
      }
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

  private func importCaptureReadiness(
    app: XCUIApplication,
    specification: String,
    anchor: XCUIElement,
    checkNow: @escaping @MainActor () -> Bool
  ) -> CaptureReadiness {
    CaptureReadiness(specification: specification, anchor: anchor) {
      checkNow()
        && app.keyboards.count == 0
        && app.alerts.count == 0
        && app.sheets.count == 0
    }
  }

  private func hasExactValue(_ element: XCUIElement, _ expected: String) -> Bool {
    element.exists && element.value.map(String.init(describing:)) == expected
  }

  private func isSettled(
    _ readiness: XCUIElement,
    containerID: String,
    axis: E2EScrollAxis,
    endpoint: KeyPath<ScrollReadinessState, Bool>? = nil
  ) -> Bool {
    guard
      let state = ScrollReadinessState(readiness.value),
      state.containerID == containerID,
      state.axis == axis,
      state.geometryReady,
      state.isIdle
    else { return false }
    let hasCorrelatedCompletion = state.interactionID == 0
      ? state.completionID == 0
      : state.completionID == state.interactionID && state.completionGeometryID > 0
    guard hasCorrelatedCompletion else { return false }
    return endpoint.map { state[keyPath: $0] } ?? true
  }

  private func hasSettledLayout(_ readiness: XCUIElement, containerID: String) -> Bool {
    guard let state = LayoutReadinessState(readiness.value) else { return false }
    return state.containerID == containerID
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    uniquelyIdentifiedElement(app, identifier)
  }
}
