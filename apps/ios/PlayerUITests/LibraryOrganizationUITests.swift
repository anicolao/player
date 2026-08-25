import XCTest

@MainActor
final class LibraryOrganizationUITests: XCTestCase {
  private let books = (1...5).map {
    String(format: "90000000-0000-0000-0000-%012d", $0)
  }
  private let collectionID = "90000000-0000-0000-0000-000000000501"
  private let trashID = "90000000-0000-0000-0000-000000000601"

  func testOrganizesDailyLibraryAndRestoresATrashedBook() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    var app = try makeApplication(reset: true)
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "A populated audiobook library stays useful and recoverable",
      narrative:
        "As a listener, I want to resume, order, browse, collect, finish, and safely remove my books without losing my organization.",
      fixture: "synthetic-populated-library",
      additionalPreconditions: [
        "Five books, five covers, contributors, series, progress, and identifiers are fixed synthetic data",
        "All five managed assets are byte-identical copies of one tiny generated M4B; seeded book timelines are 120 seconds",
        "The fixture begins with two resumable books, three Up Next books, and one finished book",
        "The deterministic playback boundary does not advance with wall-clock time",
        "Collection, view-preference, finished, queue, and Trash changes use production persistence",
      ]
    )

    app.launch()
    app.tabBars.buttons["Library"].tap()
    let organizer = anyElement(app, "library-organizer-probe")
    let initialOrganizer = organizerValue(
      books: 5,
      continuing: [books[0], books[2]],
      upNext: [books[1], books[4], books[2]],
      finished: [books[3]],
      collections: 0,
      trash: 0,
      view: "grid"
    )
    let addAudiobook = app.tabBars.buttons["Add"]
    try tester.step(
      "populated-library",
      description: "Library opens with deterministic Continue Listening and Up Next shelves",
      verifications: [
        .valueEquals(organizer, initialOrganizer, "Every populated shelf exposes its exact production-model order"),
        .exists(app.buttons["resume-book-\(books[0])"], "The current book can resume from Continue Listening"),
        .exists(app.buttons["open-up-next"], "The ordered Up Next shelf is available"),
        .exists(anyElement(app, "recent-book-\(books[4])"), "Recently Added begins with the newest book"),
        .exists(app.buttons["browse-series"], "Series browsing is available"),
        .exists(app.buttons["browse-authors"], "Author browsing is available"),
        .exists(app.buttons["browse-narrators"], "Narrator browsing is available"),
        .exists(addAudiobook, "The tab pill includes the Add Audiobook action"),
        StepVerification(specification: "The pill-integrated Add Audiobook action is directly tappable") {
          addAudiobook.isHittable
        },
      ]
    )

    addAudiobook.tap()
    XCTAssertTrue(anyElement(app, "computer-receiver-screen").waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["choose-from-files-computer-receiver"].exists)
    app.buttons["Close"].tap()
    XCTAssertTrue(anyElement(app, "library-screen").waitForExistence(timeout: 2))

    app.buttons["resume-book-\(books[0])"].tap()
    try requireValue(anyElement(app, "now-playing-screen"), "player:paused:\(books[0]):0:45000")
    app.terminate()
    app = try makeApplication(reset: false)
    app.launch()

    app.buttons["open-up-next"].tap()
    let upNext = anyElement(app, "up-next-probe")
    try requireValue(upNext, upNextValue([books[1], books[4], books[2]]))
    app.buttons["up-next-move-up-\(books[2])"].tap()
    try requireValue(upNext, upNextValue([books[1], books[2], books[4]]))
    app.buttons["up-next-move-up-\(books[2])"].tap()
    try requireValue(upNext, upNextValue([books[2], books[1], books[4]]))
    app.buttons["up-next-book-\(books[2])"].tap()
    app.buttons["mark-finished-\(books[2])"].tap()
    app.buttons["confirm-mark-finished"].firstMatch.tap()
    try requireValue(
      anyElement(app, "book-state-probe"),
      "book:\(books[2]):finished=true:position=120000"
    )
    navigateBack(app)
    try requireValue(upNext, upNextValue([books[1], books[4]]))
    navigateBack(app)
    try requireValue(
      organizer,
      organizerValue(
        books: 5,
        continuing: [books[0]],
        upNext: [books[1], books[4]],
        finished: [books[2], books[3]],
        collections: 0,
        trash: 0,
        view: "grid"
      )
    )

    try verifyBrowseAxis(
      app,
      button: "browse-series",
      screen: "series-browser-screen",
      probe: "series-browser-probe",
      expected: "browse:series:groups=2:books=4:order=90000000-0000-0000-0000-000000000402,90000000-0000-0000-0000-000000000401",
      requiredRows: [
        "series-90000000-0000-0000-0000-000000000402",
        "series-90000000-0000-0000-0000-000000000401",
      ]
    )
    try verifyBrowseAxis(
      app,
      button: "browse-authors",
      screen: "authors-browser-screen",
      probe: "authors-browser-probe",
      expected: "browse:authors:groups=3:books=5:order=90000000-0000-0000-0000-000000000201,90000000-0000-0000-0000-000000000202,90000000-0000-0000-0000-000000000203",
      requiredRows: ["author-90000000-0000-0000-0000-000000000201"]
    )
    try verifyBrowseAxis(
      app,
      button: "browse-narrators",
      screen: "narrators-browser-screen",
      probe: "narrators-browser-probe",
      expected: "browse:narrators:groups=3:books=5:order=90000000-0000-0000-0000-000000000303,90000000-0000-0000-0000-000000000301,90000000-0000-0000-0000-000000000302",
      requiredRows: ["narrator-90000000-0000-0000-0000-000000000303"]
    )

    app.buttons["browse-collections"].tap()
    app.buttons["create-collection"].tap()
    let name = app.textFields["collection-name-input"]
    XCTAssertTrue(name.waitForExistence(timeout: 2))
    name.tap()
    name.typeText("Quiet Evenings")
    app.buttons["save-collection"].tap()
    app.buttons["add-collection-books"].tap()
    app.buttons["collection-select-book-\(books[0])"].tap()
    app.buttons["collection-select-book-\(books[1])"].tap()
    app.buttons["save-collection-books"].tap()
    app.buttons["collection-move-up-\(books[1])"].tap()
    let collection = anyElement(app, "collection-probe")
    try tester.step(
      "curated-collection",
      description: "A custom collection retains the listener's manual book order",
      verifications: [
        .valueEquals(
          collection,
          "collection:\(collectionID):name=Quiet Evenings:count=2:order=\(books[1]),\(books[0])",
          "The named collection contains exactly two books in curated order"
        ),
        .exists(anyElement(app, "collection-book-\(books[1])"), "The first ordered collection book is visible"),
        .exists(anyElement(app, "collection-book-\(books[0])"), "The second ordered collection book is visible"),
      ]
    )
    navigateBack(app)
    navigateBack(app)

    app.buttons["browse-all-books"].tap()
    let allBooks = anyElement(app, "all-books-probe")
    let allBookOrder = [books[3], books[0], books[4], books[2], books[1]]
    try requireValue(allBooks, allBooksValue(view: "grid", order: allBookOrder))
    try tester.step(
      "square-cover-bookshelves",
      description: "All Books presents square audiobook artwork on burnt-orange wooden shelves",
      verifications: [
        .exists(anyElement(app, "all-books-bookshelf"), "The shelf presentation is visible"),
        .exists(
          anyElement(app, "bookshelf-continue-book-\(books[0])"),
          "Continue Listening exposes the resumable square cover"
        ),
        .exists(
          anyElement(app, "bookshelf-recent-book-\(books[4])"),
          "Recently Added exposes the newest square cover"
        ),
        .exists(
          anyElement(app, "all-books-book-\(books[3])"),
          "The complete A–Z shelf exposes its first sorted audiobook"
        ),
      ]
    )
    app.buttons["library-view-list"].tap()
    try requireValue(allBooks, allBooksValue(view: "list", order: allBookOrder))
    app.terminate()

    let restoredApp = try makeApplication(reset: false)
    restoredApp.launch()
    verifyNonLibraryRunways(restoredApp)
    restoredApp.tabBars.buttons["Library"].tap()
    restoredApp.buttons["browse-all-books"].tap()
    let restoredAllBooks = anyElement(restoredApp, "all-books-probe")
    try requireValue(restoredAllBooks, allBooksValue(view: "list", order: allBookOrder))
    restoredApp.buttons["all-books-book-\(books[4])"].tap()
    restoredApp.buttons["move-book-to-trash-toolbar"].tap()
    restoredApp.buttons["remove-book-to-trash"].firstMatch.tap()
    navigateBack(restoredApp)
    let openTrash = restoredApp.buttons["open-trash"].firstMatch
    let miniPlayer = restoredApp.otherElements["mini-player"]
    XCTAssertTrue(openTrash.waitForExistence(timeout: 2))
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    for _ in 0..<5
    where !openTrash.isHittable || openTrash.frame.maxY > miniPlayer.frame.minY - 4 {
      restoredApp.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.72))
        .press(
          forDuration: 0.05,
          thenDragTo: restoredApp.coordinate(
            withNormalizedOffset: CGVector(dx: 0.92, dy: 0.28)
          ),
          withVelocity: .slow,
          thenHoldForDuration: 0
        )
    }
    XCTAssertTrue(openTrash.isHittable, "Trash must remain tappable above the mini-player")
    XCTAssertLessThanOrEqual(
      openTrash.frame.maxY,
      miniPlayer.frame.minY - 4,
      "Library content must have enough bottom runway to scroll Trash fully above the mini-player"
    )
    try tester.step(
      "trash-clear-of-player",
      description: "The final Library control scrolls completely above the persistent player",
      verifications: [
        .exists(openTrash, "Trash remains visible and tappable above the mini-player"),
        .exists(miniPlayer, "The persistent player remains available below Library content"),
      ]
    )
    openTrash.tap()
    let trash = anyElement(restoredApp, "trash-probe")
    try tester.step(
      "recoverable-trash",
      description: "Removing a book creates an exact recoverable Trash transaction",
      verifications: [
        .valueEquals(
          trash,
          "trash:transactions=1:books=\(books[4]):assets=1:bytes=8461:restorable=true:managed-checksum-preserved=true",
          "Trash reports one intact restorable managed asset"
        ),
        .exists(anyElement(restoredApp, "trash-book-\(books[4])"), "The removed book is identifiable in Trash"),
        .exists(restoredApp.buttons["restore-trash-\(trashID)"], "The exact removal transaction can be restored"),
        .exists(restoredApp.buttons["delete-trash-\(trashID)"], "The managed copy can be permanently deleted after confirmation"),
      ]
    )
    restoredApp.buttons["restore-trash-\(trashID)"].tap()
    try requireValue(
      trash,
      "trash:transactions=0:books=none:assets=0:bytes=0:restorable=false:managed-checksum-preserved=true"
    )
    navigateBack(restoredApp)
    restoredApp.buttons["browse-all-books"].tap()
    let restoredOrganizer = anyElement(restoredApp, "library-organizer-probe")
    try tester.step(
      "restored-library-list",
      description: "Restore returns the book and its organization while list preference persists",
      verifications: [
        .valueEquals(
          restoredOrganizer,
          organizerValue(
            books: 5,
            continuing: [books[0]],
            upNext: [books[1], books[4]],
            finished: [books[2], books[3]],
            collections: 1,
            trash: 0,
            view: "list"
          ),
          "Restore atomically returns the book to its prior Up Next position"
        ),
        .valueEquals(restoredAllBooks, allBooksValue(view: "list", order: allBookOrder), "The list choice survives restart and Trash restore"),
        .exists(anyElement(restoredApp, "all-books-book-\(books[4])"), "The restored book is visible again"),
      ]
    )

    navigateBack(restoredApp)
    restoredApp.buttons["open-library-search"].tap()
    try requireValue(anyElement(restoredApp, "library-search-screen"), "ready")
    let searchInput = restoredApp.textFields["library-search-input"]
    XCTAssertTrue(searchInput.waitForExistence(timeout: 2))
    searchInput.tap()
    searchInput.typeText("Mina Sol\n")
    let searchProbe = anyElement(restoredApp, "library-search-probe")
    try tester.step(
      "metadata-search",
      description: "Local search finds contributor metadata without a network",
      verifications: [
        .valueEquals(
          searchProbe,
          searchValue(query: "mina sol", count: 2, order: [books[4], books[2]]),
          "Normalized contributor search returns exactly the two matching books in title order"
        ),
        .exists(searchInput, "The local query remains available for immediate refinement"),
        .exists(anyElement(restoredApp, "library-search-summary"), "The result count and active order are visible"),
      ]
    )

    restoredApp.buttons["clear-search-query"].tap()
    searchInput.tap()
    searchInput.typeText("Quiet Evenings\n")
    try requireValue(
      searchProbe,
      searchValue(query: "quiet evenings", count: 2, order: [books[0], books[1]])
    )
    restoredApp.buttons["clear-search-query"].tap()
    searchInput.tap()
    searchInput.typeText("Full Book\n")
    try requireValue(
      searchProbe,
      searchValue(query: "full book", count: 5, order: allBookOrder)
    )
    restoredApp.buttons["clear-search-query"].tap()

    restoredApp.buttons["search-sort"].tap()
    restoredApp.buttons["search-sort-recently-added"].tap()
    restoredApp.buttons["search-sort"].tap()
    restoredApp.buttons["search-sort-direction"].tap()
    restoredApp.buttons["search-filter"].tap()
    restoredApp.buttons["search-filter-finished"].tap()
    let persistedSearchValue = searchValue(
      query: "", count: 2, sort: "recentlyAdded", direction: "descending",
      status: "finished", order: [books[3], books[2]]
    )
    try tester.step(
      "filtered-search",
      description: "Search combines a listening-state filter with a meaningful sort",
      verifications: [
        .valueEquals(searchProbe, persistedSearchValue, "Finished books are sorted newest-first"),
        .exists(restoredApp.staticTexts["2 books · Finished · Recently added"], "The active result summary is explicit"),
        .exists(restoredApp.buttons["clear-library-search"], "All active choices can be cleared in one tap"),
      ]
    )

    restoredApp.terminate()
    let searchRelaunch = try makeApplication(reset: false)
    searchRelaunch.launch()
    searchRelaunch.buttons["open-library-search"].tap()
    let relaunchedProbe = anyElement(searchRelaunch, "library-search-probe")
    try requireValue(relaunchedProbe, persistedSearchValue)
    let relaunchedInput = searchRelaunch.textFields["library-search-input"]
    relaunchedInput.tap()
    relaunchedInput.typeText("No Such Audiobook\n")
    try tester.step(
      "no-search-matches",
      description: "No search matches is distinct from an empty library",
      verifications: [
        .valueEquals(
          relaunchedProbe,
          searchValue(
            query: "no such audiobook", count: 0, sort: "recentlyAdded",
            direction: "descending", status: "finished", empty: "query", order: []
          ),
          "The durable sort and filter remain active while the query has no matches"
        ),
        .exists(anyElement(searchRelaunch, "library-search-empty"), "A dedicated no-match state is shown"),
        .exists(searchRelaunch.buttons["Clear Search and Filters"], "The no-match state offers one-tap recovery"),
      ]
    )
    searchRelaunch.buttons["Clear Search and Filters"].tap()
    try requireValue(relaunchedProbe, searchValue(query: "", count: 5, order: allBookOrder))
    tester.generateDocs()
  }

  private func makeApplication(reset: Bool) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "synthetic-populated-library",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
      "-e2e-computer-receiver-ready",
    ]
    if reset { app.launchArguments.insert("-e2e-reset", at: 1) }
    app.launchEnvironment["TZ"] = "America/Toronto"
    app.launchEnvironment["PLAYER_E2E_LIBRARY_DESCRIPTOR_BASE64"] = try fixtureData(
      resource: "synthetic-populated-library-fixture", extension: "json"
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
      Bundle(for: Self.self).url(forResource: resource, withExtension: fileExtension),
      "The checked-in synthetic populated-library fixture must be in the UI-test bundle"
    )
    return try Data(contentsOf: url)
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func navigateBack(_ app: XCUIApplication) {
    let back = app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(back.waitForExistence(timeout: 2))
    back.tap()
  }

  private func verifyNonLibraryRunways(_ app: XCUIApplication) {
    let miniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))

    app.tabBars.buttons["Settings"].tap()
    assertScrollsAboveMiniPlayer(
      app.buttons["settings-diagnostics"], miniPlayer: miniPlayer, in: app,
      message: "The final Settings row must scroll above the mini-player"
    )

    app.buttons["settings-backup"].tap()
    assertScrollsAboveMiniPlayer(
      anyElement(app, "backup-automatic-explanation"), miniPlayer: miniPlayer, in: app,
      message: "The final Backup content must scroll above the mini-player"
    )
    navigateBack(app)

    app.buttons["playback-defaults"].tap()
    assertScrollsAboveMiniPlayer(
      anyElement(app, "transport-seek-context"), miniPlayer: miniPlayer, in: app,
      message: "The final Playback Defaults control must scroll above the mini-player"
    )
    navigateBack(app)
  }

  private func assertScrollsAboveMiniPlayer(
    _ element: XCUIElement,
    miniPlayer: XCUIElement,
    in app: XCUIApplication,
    message: String
  ) {
    XCTAssertTrue(element.waitForExistence(timeout: 2), message)
    for _ in 0..<8
    where !element.isHittable || element.frame.maxY > miniPlayer.frame.minY - 4 {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.72))
        .press(
          forDuration: 0.05,
          thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.28)),
          withVelocity: .slow,
          thenHoldForDuration: 0
        )
    }
    XCTAssertTrue(element.isHittable, message)
    XCTAssertLessThanOrEqual(element.frame.maxY, miniPlayer.frame.minY - 4, message)
  }

  private func verifyBrowseAxis(
    _ app: XCUIApplication,
    button: String,
    screen: String,
    probe: String,
    expected: String,
    requiredRows: [String]
  ) throws {
    app.buttons[button].tap()
    XCTAssertTrue(anyElement(app, screen).waitForExistence(timeout: 2))
    try requireValue(anyElement(app, probe), expected)
    for row in requiredRows { XCTAssertTrue(anyElement(app, row).exists) }
    navigateBack(app)
  }

  private func organizerValue(
    books count: Int,
    continuing: [String],
    upNext: [String],
    finished: [String],
    collections: Int,
    trash: Int,
    view: String
  ) -> String {
    "library:books=\(count):continue=\(continuing.joined(separator: ",")):up-next=\(upNext.joined(separator: ",")):finished=\(finished.joined(separator: ",")):collections=\(collections):trash=\(trash):view=\(view):current=\(books[0]):position=45000"
  }

  private func upNextValue(_ order: [String]) -> String {
    "up-next:count=\(order.count):order=\(order.joined(separator: ","))"
  }

  private func allBooksValue(view: String, order: [String]) -> String {
    "all-books:count=5:view=\(view):order=\(order.joined(separator: ","))"
  }

  private func searchValue(
    query: String,
    count: Int,
    sort: String = "title",
    direction: String = "ascending",
    status: String = "any",
    formats: String = "any",
    missing: Bool = false,
    empty: String = "none",
    order: [String]
  ) -> String {
    "search:query=\(query):count=\(count):sort=\(sort):direction=\(direction):status=\(status):formats=\(formats):missing=\(missing):empty=\(empty):order=\(order.isEmpty ? "none" : order.joined(separator: ","))"
  }

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    guard element.waitForStringValue(expected, timeout: 2) else {
      XCTFail(
        "The library organization journey did not reach its required semantic state; actual=\(String(describing: element.value))"
      )
      throw LibraryOrganizationTestError.semanticStateUnavailable
    }
  }
}

private enum LibraryOrganizationTestError: Error { case semanticStateUnavailable }
