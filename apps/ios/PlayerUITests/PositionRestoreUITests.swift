import XCTest

@MainActor
final class PositionRestoreUITests: XCTestCase {
  private let fixtureBookID = "20000000-0000-0000-0000-000000000001"
  private let initialPositionMilliseconds = 12_000
  private let seekPositionMilliseconds = 60_000
  private let restoreToleranceMilliseconds = 500

  func testRestoresAnAcknowledgedPausedPositionAfterTermination() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = makeApplication(reset: true)
    app.launch()

    let initialMiniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(initialMiniPlayer.waitForExistence(timeout: 2))
    let initialState = try requirePlaybackState(initialMiniPlayer, status: "paused")
    XCTAssertEqual(initialState.bookID, fixtureBookID)
    XCTAssertEqual(initialState.chapterIndex, 0)
    XCTAssertEqual(initialState.positionMilliseconds, initialPositionMilliseconds)
    let initialTimeline = app.staticTexts["mini-player-timeline"]
    XCTAssertTrue(initialTimeline.waitForExistence(timeout: 2))
    XCTAssertEqual(initialTimeline.value as? String, "0m12s of 2m00s")

    initialMiniPlayer.tap()
    let nowPlaying = app.otherElements["now-playing-screen"]
    XCTAssertTrue(nowPlaying.waitForExistence(timeout: 2))
    XCTAssertEqual(try requirePlaybackState(nowPlaying, status: "paused"), initialState)

    let positionSlider = app.sliders["player-position-slider"]
    XCTAssertTrue(positionSlider.waitForExistence(timeout: 2))
    let seekedState = try adjustSliderUntilAcknowledged(
      positionSlider,
      to: 0.5,
      reportingThrough: nowPlaying,
      expectedPositionMilliseconds: seekPositionMilliseconds
    )
    XCTAssertEqual(seekedState.bookID, fixtureBookID)
    XCTAssertEqual(seekedState.chapterIndex, 0)

    let playPause = app.buttons["player-play-pause"]
    playPause.tap()
    let playingState = try requirePlaybackState(
      nowPlaying,
      status: "playing",
      positionMilliseconds: seekPositionMilliseconds
    )
    XCTAssertEqual(playingState.bookID, fixtureBookID)

    playPause.tap()
    let acknowledgedPausedState = try requirePlaybackState(nowPlaying, status: "paused")
    XCTAssertEqual(acknowledgedPausedState.bookID, fixtureBookID)
    XCTAssertEqual(acknowledgedPausedState.chapterIndex, 0)
    XCTAssertGreaterThanOrEqual(
      acknowledgedPausedState.positionMilliseconds,
      seekPositionMilliseconds
    )

    app.terminate()

    let restoredApp = makeApplication(reset: false)
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "A paused listening position survives app termination",
      narrative:
        "As a listener, I want Player to return at audio I have already heard after I close and reopen the app.",
      fixture: "committed-current-book",
      additionalPreconditions: [
        "The fixture contains one committed 120-second book at chapter 1 and 12 seconds",
        "The first launch resets the fixture; the restore launch reuses the same durable E2E store",
        "The deterministic playback engine does not advance with wall-clock time",
        "A 50 percent slider seek resolves exactly to 60,000 milliseconds",
        "An orderly pause acknowledges and journals the position before returning",
      ]
    )
    restoredApp.launch()

    let libraryScreen = restoredApp.descendants(matching: .any)["library-screen"]
    let restoredMiniPlayer = restoredApp.otherElements["mini-player"]
    try tester.step(
      "restored-library",
      description: "Library restores the paused current book in its mini-player",
      verifications: [
        .exists(libraryScreen, "The restored Library screen is visible"),
        .valueEquals(
          libraryScreen,
          "ready:library-1-books",
          "The durable library still contains exactly one book"
        ),
        .exists(restoredMiniPlayer, "The current book is available in the mini-player"),
        restoredPositionVerification(
          restoredMiniPlayer,
          acknowledged: acknowledgedPausedState.positionMilliseconds,
          "The mini-player is paused at most 500 ms behind and never ahead of the acknowledged position"
        ),
      ]
    )

    let restoredMiniState = try requirePlaybackState(restoredMiniPlayer, status: "paused")
    assertRestoredPosition(
      restoredMiniState.positionMilliseconds,
      acknowledged: acknowledgedPausedState.positionMilliseconds
    )
    restoredMiniPlayer.tap()

    let restoredNowPlaying = restoredApp.otherElements["now-playing-screen"]
    try tester.step(
      "restored-now-playing",
      description: "Now Playing opens paused at the safely restored position",
      verifications: [
        .exists(restoredNowPlaying, "The restored Now Playing screen is visible"),
        restoredPositionVerification(
          restoredNowPlaying,
          acknowledged: acknowledgedPausedState.positionMilliseconds,
          "Now Playing is paused at most 500 ms behind and never ahead of the acknowledged position"
        ),
        .exists(
          restoredApp.buttons["player-play-pause"],
          "The restored Play control is available"
        ),
        .exists(
          restoredApp.sliders["player-position-slider"],
          "The restored position remains adjustable"
        ),
      ]
    )

    let restoredNowPlayingState = try requirePlaybackState(
      restoredNowPlaying,
      status: "paused"
    )
    assertRestoredPosition(
      restoredNowPlayingState.positionMilliseconds,
      acknowledged: acknowledgedPausedState.positionMilliseconds
    )
    XCTAssertEqual(restoredNowPlayingState, restoredMiniState)

    tester.generateDocs()
  }

  private func makeApplication(reset: Bool) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e",
      "-e2e-fixture", "committed-current-book",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset {
      app.launchArguments.insert("-e2e-reset", at: 1)
    }
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func requirePlaybackState(
    _ element: XCUIElement,
    status: String,
    positionMilliseconds: Int? = nil
  ) throws -> PlaybackSemanticState {
    if let state = waitForPlaybackState(
      element,
      status: status,
      positionMilliseconds: positionMilliseconds
    ) {
      return state
    }

    XCTFail(
      "The player did not report status=\(status), position=\(positionMilliseconds.map(String.init) ?? "any"); latest=\(String(describing: element.value))"
    )
    throw PositionRestoreTestError.semanticStateUnavailable
  }

  private func adjustSliderUntilAcknowledged(
    _ slider: XCUIElement,
    to normalizedPosition: CGFloat,
    reportingThrough element: XCUIElement,
    expectedPositionMilliseconds: Int
  ) throws -> PlaybackSemanticState {
    for _ in 0..<3 {
      slider.adjust(toNormalizedSliderPosition: normalizedPosition)
      if let state = waitForPlaybackState(
        element,
        status: "paused",
        positionMilliseconds: expectedPositionMilliseconds
      ) {
        return state
      }
    }

    XCTFail(
      "The slider did not acknowledge position=\(expectedPositionMilliseconds) after 3 attempts; latest=\(String(describing: element.value))"
    )
    throw PositionRestoreTestError.semanticStateUnavailable
  }

  private func waitForPlaybackState(
    _ element: XCUIElement,
    status: String,
    positionMilliseconds: Int? = nil
  ) -> PlaybackSemanticState? {
    let deadline = Date().addingTimeInterval(2)
    repeat {
      if let state = PlaybackSemanticState(element.value as? String),
         state.status == status,
         positionMilliseconds == nil || state.positionMilliseconds == positionMilliseconds {
        return state
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return nil
  }

  private func restoredPositionVerification(
    _ element: XCUIElement,
    acknowledged: Int,
    _ specification: String
  ) -> StepVerification {
    StepVerification(specification: specification) {
      guard let state = PlaybackSemanticState(element.value as? String) else { return false }
      return state.status == "paused"
        && state.bookID == self.fixtureBookID
        && state.chapterIndex == 0
        && state.positionMilliseconds <= acknowledged
        && state.positionMilliseconds >= acknowledged - self.restoreToleranceMilliseconds
    }
  }

  private func assertRestoredPosition(_ restored: Int, acknowledged: Int) {
    XCTAssertLessThanOrEqual(
      restored,
      acknowledged,
      "Restoration must never move beyond audio acknowledged at pause"
    )
    XCTAssertGreaterThanOrEqual(
      restored,
      acknowledged - restoreToleranceMilliseconds,
      "Restoration must be no more than 500 ms behind the acknowledged position"
    )
  }
}

private struct PlaybackSemanticState: Equatable {
  let status: String
  let bookID: String
  let chapterIndex: Int
  let positionMilliseconds: Int

  init?(_ value: String?) {
    guard let value else { return nil }
    let fields = value.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 5,
          fields[0] == "player",
          fields[1] == "paused" || fields[1] == "playing",
          UUID(uuidString: String(fields[2])) != nil,
          let chapterIndex = Int(fields[3]),
          chapterIndex >= 0,
          let positionMilliseconds = Int(fields[4]),
          positionMilliseconds >= 0
    else { return nil }

    status = String(fields[1])
    bookID = fields[2].lowercased()
    self.chapterIndex = chapterIndex
    self.positionMilliseconds = positionMilliseconds
  }
}

private enum PositionRestoreTestError: Error {
  case semanticStateUnavailable
}
