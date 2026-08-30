import XCTest

@MainActor
final class LibrarySearchCoverageUITests: PlayerUITestCase {
  private let books = (1...5).map {
    String(format: "90000000-0000-0000-0000-%012d", $0)
  }

  func testEveryProductionSortAndFilterPersistsClearsAndResets() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    var app = try makeApplication(reset: true)
    app.launch()
    try openSearch(in: app)
    var probe = uniquelyIdentifiedElement(app, "library-search-results-probe")

    let sortOrders: [(id: String, value: String, ascending: [String])] = [
      ("search-sort-title", "title", [books[3], books[0], books[4], books[2], books[1]]),
      ("search-sort-author", "author", [books[3], books[0], books[1], books[2], books[4]]),
      ("search-sort-series", "series", [books[3], books[2], books[4], books[0], books[1]]),
      ("search-sort-recently-added", "recentlyAdded", books),
      ("search-sort-duration", "duration", [books[4], books[2], books[0], books[3], books[1]]),
      ("search-sort-progress", "progress", [books[1], books[4], books[2], books[0], books[3]]),
    ]

    var direction = "ascending"
    for (index, sort) in sortOrders.enumerated() {
      if index > 0 { try choose(sort.id, from: "search-sort", in: app) }
      let order = direction == "ascending" ? sort.ascending : Array(sort.ascending.reversed())
      try requireSearch(probe, sort: sort.value, direction: direction, order: order)

      try choose("search-sort-direction", from: "search-sort", in: app)
      direction = direction == "ascending" ? "descending" : "ascending"
      let reversed = direction == "ascending" ? sort.ascending : Array(sort.ascending.reversed())
      try requireSearch(probe, sort: sort.value, direction: direction, order: reversed)
    }

    XCTAssertEqual(direction, "ascending")
    try choose("search-sort-title", from: "search-sort", in: app)
    try requireSearch(probe, order: sortOrders[0].ascending)
    XCTAssertTrue(app.staticTexts["5 books · Title"].waitForExistence(timeout: 2))

    try choose("search-filter-unplayed", from: "search-filter", in: app)
    try requireSearch(probe, status: "unplayed", order: [books[4], books[1]])
    XCTAssertTrue(app.staticTexts["2 books · Unplayed · Title"].waitForExistence(timeout: 2))
    try choose("search-filter-any-status", from: "search-filter", in: app)
    try requireSearch(probe, order: sortOrders[0].ascending)

    try choose("search-filter-in-progress", from: "search-filter", in: app)
    try requireSearch(probe, status: "inProgress", order: [books[0], books[2]])
    try choose("search-filter-finished", from: "search-filter", in: app)
    try requireSearch(probe, status: "finished", order: [books[3]])
    try choose("search-filter-any-status", from: "search-filter", in: app)
    try requireSearch(probe, order: sortOrders[0].ascending)

    try choose("search-filter-m4b", from: "search-filter", in: app)
    try requireSearch(
      probe,
      formats: "M4B",
      order: [books[3], books[0], books[4], books[2]]
    )
    try choose("search-filter-m4b", from: "search-filter", in: app)
    try requireSearch(probe, order: sortOrders[0].ascending)

    try choose("search-filter-missing-metadata", from: "search-filter", in: app)
    try requireSearch(probe, missing: true, order: [books[3]])
    XCTAssertTrue(
      app.staticTexts["1 book · Missing metadata · Title"].waitForExistence(timeout: 2)
    )
    try choose("search-filter-missing-metadata", from: "search-filter", in: app)
    try requireSearch(probe, order: sortOrders[0].ascending)

    try choose("search-filter-unplayed", from: "search-filter", in: app)
    try choose("search-filter-m4b", from: "search-filter", in: app)
    try requireSearch(probe, status: "unplayed", formats: "M4B", order: [books[4]])
    try choose("search-filter-missing-metadata", from: "search-filter", in: app)
    try requireSearch(
      probe,
      status: "unplayed",
      formats: "M4B",
      missing: true,
      empty: "filters",
      order: []
    )
    XCTAssertTrue(
      uniquelyIdentifiedElement(app, "library-search-empty").waitForExistence(timeout: 2)
    )
    XCTAssertTrue(app.staticTexts["No books match these filters"].exists)
    try tapButton(label: "Clear Search and Filters", in: app)
    try requireSearch(probe, order: sortOrders[0].ascending)

    try tap("search-result-\(books[3])", in: app)
    XCTAssertTrue(
      uniquelyIdentifiedElement(app, "book-detail-screen").waitForExistence(timeout: 2)
    )
    app.navigationBars.buttons["Search"].tap()
    XCTAssertTrue(probe.waitForExistence(timeout: 2))

    let input = app.textFields["library-search-input"]
    input.tap()
    input.typeText("No Such Audiobook\n")
    try requireSearch(probe, query: "no such audiobook", empty: "query", order: [])
    XCTAssertTrue(app.staticTexts["No search matches"].exists)
    try tapButton(label: "Clear Search and Filters", in: app)
    try requireSearch(probe, order: sortOrders[0].ascending)

    try choose("search-sort-progress", from: "search-sort", in: app)
    try choose("search-sort-direction", from: "search-sort", in: app)
    try choose("search-filter-unplayed", from: "search-filter", in: app)
    try choose("search-filter-m4b", from: "search-filter", in: app)
    let persistedOrder = [books[4]]
    try requireSearch(
      probe,
      sort: "progress",
      direction: "descending",
      status: "unplayed",
      formats: "M4B",
      order: persistedOrder
    )

    XCTAssertTrue(terminateAndWait(app))
    app = try makeApplication(reset: false)
    app.launch()
    try openSearch(in: app)
    probe = uniquelyIdentifiedElement(app, "library-search-results-probe")
    try requireSearch(
      probe,
      sort: "progress",
      direction: "descending",
      status: "unplayed",
      formats: "M4B",
      order: persistedOrder
    )
    XCTAssertTrue(
      app.staticTexts["1 book · Unplayed · M4B · Progress"].waitForExistence(timeout: 2)
    )
    try tap("clear-library-search", in: app)
    try requireSearch(probe, order: sortOrders[0].ascending)

    try choose("search-sort-author", from: "search-sort", in: app)
    try choose("search-sort-direction", from: "search-sort", in: app)
    try choose("search-filter-finished", from: "search-filter", in: app)
    try requireSearch(
      probe,
      sort: "author",
      direction: "descending",
      status: "finished",
      order: [books[3]]
    )
    XCTAssertTrue(terminateAndWait(app))

    app = try makeApplication(reset: true)
    app.launch()
    try openSearch(in: app)
    probe = uniquelyIdentifiedElement(app, "library-search-results-probe")
    try requireSearch(probe, order: sortOrders[0].ascending)
  }

  private func makeApplication(reset: Bool) throws -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "synthetic-search-matrix",
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
      Bundle(for: Self.self).url(forResource: resource, withExtension: fileExtension)
    )
    return try Data(contentsOf: url)
  }

  private func openSearch(in app: XCUIApplication) throws {
    let open = app.buttons["open-library-search"]
    XCTAssertTrue(open.waitForExistence(timeout: 2))
    open.tap()
    let screen = uniquelyIdentifiedElement(app, "library-search-screen")
    guard screen.waitForStringValue("ready", timeout: 2) else {
      XCTFail("Search index did not become ready; actual=\(String(describing: screen.value))")
      throw LibrarySearchCoverageError.stateUnavailable
    }
  }

  private func choose(_ item: String, from menu: String, in app: XCUIApplication) throws {
    try tap(menu, in: app)
    try tap(item, in: app)
  }

  private func tap(_ identifier: String, in app: XCUIApplication) throws {
    let query = app.descendants(matching: .any).matching(identifier: identifier)
    if let element = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
      element.tap()
      return
    }
    let candidate = query.element
    guard candidate.waitForExistence(timeout: 2), candidate.isHittable else {
      XCTFail("No hittable production control reported \(identifier)")
      throw LibrarySearchCoverageError.stateUnavailable
    }
    candidate.tap()
  }

  private func tapButton(label: String, in app: XCUIApplication) throws {
    let button = app.buttons[label]
    guard button.waitForExistence(timeout: 2), button.isHittable else {
      XCTFail("No hittable production button reported label \(label)")
      throw LibrarySearchCoverageError.stateUnavailable
    }
    button.tap()
  }

  private func requireSearch(
    _ probe: XCUIElement,
    query: String = "",
    sort: String = "title",
    direction: String = "ascending",
    status: String = "any",
    formats: String = "any",
    missing: Bool = false,
    empty: String = "none",
    order: [String]
  ) throws {
    let expected = "query=\(query):count=\(order.count):sort=\(sort):direction=\(direction):status=\(status):formats=\(formats):missing=\(missing):empty=\(empty):order=\(order.isEmpty ? "none" : order.joined(separator: ","))"
    guard probe.waitForStringValue(expected, timeout: 2) else {
      XCTFail("Search did not reach \(expected); actual=\(String(describing: probe.value))")
      throw LibrarySearchCoverageError.stateUnavailable
    }
  }
}

private enum LibrarySearchCoverageError: Error {
  case stateUnavailable
}
