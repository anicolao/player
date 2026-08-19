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
      ]
    )

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
    app.buttons["library-view-list"].tap()
    try requireValue(allBooks, allBooksValue(view: "list", order: allBookOrder))
    app.terminate()

    let restoredApp = try makeApplication(reset: false)
    restoredApp.launch()
    restoredApp.buttons["browse-all-books"].tap()
    let restoredAllBooks = anyElement(restoredApp, "all-books-probe")
    try requireValue(restoredAllBooks, allBooksValue(view: "list", order: allBookOrder))
    restoredApp.buttons["all-books-book-\(books[4])"].tap()
    restoredApp.buttons["remove-book"].tap()
    restoredApp.buttons["remove-book-to-trash"].firstMatch.tap()
    restoredApp.buttons["open-trash"].tap()
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
      ]
    )
    restoredApp.buttons["restore-trash-\(trashID)"].tap()
    try requireValue(
      trash,
      "trash:transactions=0:books=none:assets=0:bytes=0:restorable=false:managed-checksum-preserved=true"
    )
    navigateBack(restoredApp)
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
    tester.generateDocs()
  }

  private func makeApplication(reset: Bool) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "synthetic-populated-library",
      "-AppleLanguages", "(en)", "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
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

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", expected), object: element
    )
    guard XCTWaiter.wait(for: [expectation], timeout: 2) == .completed else {
      XCTFail("The library organization journey did not reach its required semantic state")
      throw LibraryOrganizationTestError.semanticStateUnavailable
    }
  }
}

private enum LibraryOrganizationTestError: Error { case semanticStateUnavailable }
