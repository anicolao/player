import XCTest

@MainActor
final class BookmarkUITests: XCTestCase {
  private let bookID = "53000000-0000-0000-0000-000000000001"
  private let firstAssetID = "53000000-0000-0000-0000-000000000002"
  private let secondAssetID = "53000000-0000-0000-0000-000000000003"
  private let boundaryBookmarkID = "53000000-0000-0000-0000-000000000101"
  private let secondBookmarkID = "53000000-0000-0000-0000-000000000103"
  private let deletionID = "53000000-0000-0000-0000-000000000105"

  func testBookmarksCaptureOrganizeSearchJumpDeleteAndUndoExactly() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let tester = TestStepHelper(testCase: self, startIndex: 2)
    tester.setMetadata(
      title: "Bookmarks preserve, organize, and restore exact listening places",
      narrative: "As a listener, I want bookmarks with useful labels and notes that remain searchable, jumpable, and safely undoable across relaunches.",
      fixture: "bookmarks",
      additionalPreconditions: [
        "The fixture contains one deterministic 120-second book split into two 60-second synthetic assets",
        "Playback begins paused exactly at the 60,000 ms asset and chapter boundary",
        "The injected clock begins at epoch 1,700,030,000 and advances exactly 60 seconds before the second bookmark",
        "Generated production UUIDs begin at suffix 101 and resume after the highest durable UUID on relaunch",
      ]
    )

    let app = makeApplication(reset: true)
    app.launch()
    try openNowPlaying(app)

    let add = app.buttons["add-bookmark"]
    XCTAssertTrue(add.waitForExistence(timeout: 2))
    add.tap()
    try requireValue(
      app.descendants(matching: .any)["bookmark-saved"],
      "bookmark=\(boundaryBookmarkID):book=\(bookID):position=60000"
    )
    var probe = try requireProbe(app, count: 1, position: 60_000)
    XCTAssertEqual(probe["order"], boundaryBookmarkID)
    XCTAssertEqual(
      probe["items"],
      "\(boundaryBookmarkID)~60000~\(secondAssetID)~0~crossing~The Crossing · 1:00~none~1700030000~1700030000"
    )
    XCTAssertEqual(probe.journal, "1:pause@60000")

    let prepareSecond = app.buttons["e2e-bookmark-second-position"]
    XCTAssertTrue(prepareSecond.waitForExistence(timeout: 2))
    prepareSecond.tap()
    probe = try requireProbe(app, count: 1, position: 15_000)
    XCTAssertEqual(probe.journal, "1:pause@60000,2:seek@15000")
    add.tap()
    try requireValue(
      app.descendants(matching: .any)["bookmark-saved"],
      "bookmark=\(secondBookmarkID):book=\(bookID):position=15000"
    )
    probe = try requireProbe(app, count: 2, position: 15_000)
    XCTAssertEqual(probe["order"], "\(boundaryBookmarkID),\(secondBookmarkID)")

    let done = app.buttons["Done"]
    XCTAssertTrue(done.waitForExistence(timeout: 2))
    done.tap()
    try openBookmarkDetail(app)

    let boundaryRow = app.descendants(matching: .any)["bookmark-row-\(boundaryBookmarkID)"]
    let secondRow = app.descendants(matching: .any)["bookmark-row-\(secondBookmarkID)"]
    try revealBookmarkRow(boundaryRow, in: app)
    try requireValue(
      boundaryRow,
      "book=\(bookID)|asset=\(secondAssetID)|chapter=crossing|bookMs=60000|assetMs=0|label=The Crossing · 1:00|note=none"
    )
    try revealBookmarkRow(secondRow, in: app)
    try requireValue(
      secondRow,
      "book=\(bookID)|asset=\(firstAssetID)|chapter=opening|bookMs=15000|assetMs=15000|label=Opening Signal · 0:15|note=none"
    )
    try requireBookmarksScreen(
      app,
      "bookmarks:query=:sort=positionAscending:count=2:order=\(secondBookmarkID),\(boundaryBookmarkID)"
    )

    try editSecondBookmark(app)
    probe = try requireProbe(app, count: 2, position: 15_000)
    XCTAssertEqual(
      probe["items"],
      "\(boundaryBookmarkID)~60000~\(secondAssetID)~0~crossing~The Crossing · 1:00~none~1700030000~1700030000;\(secondBookmarkID)~15000~\(firstAssetID)~15000~opening~Écho marker~Return to the café clue~1700030060~1700030060"
    )

    try assertEverySort(app)
    let search = app.textFields["bookmark-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 2))
    try focusAndType("echo cafe", into: search, in: app)
    try requireBookmarksScreen(
      app,
      "bookmarks:query=echo cafe:sort=label:count=1:order=\(secondBookmarkID)"
    )
    app.buttons["clear-bookmark-search"].tap()
    try requireBookmarksScreen(
      app,
      "bookmarks:query=:sort=label:count=2:order=\(secondBookmarkID),\(boundaryBookmarkID)"
    )
    if app.keyboards.firstMatch.exists {
      search.typeKey(.return, modifierFlags: [])
    }
    XCTAssertFalse(
      app.keyboards.firstMatch.waitForExistence(timeout: 1),
      "Bookmark walkthrough must not capture the search keyboard"
    )
    try prepareBookmarkWalkthroughFrame(
      app,
      segment: app.buttons["bookmarks-segment"],
      rows: [secondRow, boundaryRow],
      jumpActions: [
        app.buttons["jump-to-bookmark-\(secondBookmarkID)"],
        app.buttons["jump-to-bookmark-\(boundaryBookmarkID)"],
      ]
    )
    try tester.step(
      "bookmarks-list",
      description: "Book Detail organizes edited bookmarks with their listening context",
      verifications: [
        .valueEquals(
          app.buttons["bookmarks-segment"],
          "selected",
          "Bookmarks is the selected Book Detail section while Chapters remains adjacent"
        ),
        .valueEquals(
          app.descendants(matching: .any)["bookmarks-screen"],
          "bookmarks:query=:sort=label:count=2:order=\(secondBookmarkID),\(boundaryBookmarkID)",
          "The cleared bookmark search shows both bookmarks in deterministic label order"
        ),
        .valueEquals(
          secondRow,
          "book=\(bookID)|asset=\(firstAssetID)|chapter=opening|bookMs=15000|assetMs=15000|label=Écho marker|note=Return to the café clue",
          "The edited Unicode label and note remain attached to the exact first-asset position"
        ),
        .valueEquals(
          boundaryRow,
          "book=\(bookID)|asset=\(secondAssetID)|chapter=crossing|bookMs=60000|assetMs=0|label=The Crossing · 1:00|note=none",
          "The exact-boundary bookmark visibly retains its following asset and chapter context"
        ),
      ]
    )

    let jump = app.buttons["jump-to-bookmark-\(boundaryBookmarkID)"]
    try tapWhenHittable(jump, in: app)
    try requireValue(
      app.descendants(matching: .any)["bookmark-jump-confirmation"],
      "bookmark=\(boundaryBookmarkID):position=60000"
    )
    probe = try requireProbe(app, count: 2, position: 60_000)
    XCTAssertEqual(probe.journal, "1:pause@60000,2:seek@15000,3:seek@60000")

    let delete = app.buttons["delete-bookmark-\(boundaryBookmarkID)"]
    XCTAssertTrue(delete.waitForExistence(timeout: 2))
    delete.tap()
    probe = try requireProbe(app, count: 1, transactions: 1, position: 60_000)
    XCTAssertEqual(probe["order"], secondBookmarkID)
    XCTAssertEqual(
      probe["deletions"],
      "\(deletionID)~\(boundaryBookmarkID)~0~deleted~none"
    )
    try requireValue(
      app.buttons["undo-delete-bookmark"],
      "transaction=\(deletionID):bookmark=\(boundaryBookmarkID)"
    )
    app.terminate()

    let restored = makeApplication(reset: false)
    restored.launch()
    try openBookmarkDetail(restored)
    try requireValue(
      restored.buttons["undo-delete-bookmark"],
      "transaction=\(deletionID):bookmark=\(boundaryBookmarkID)"
    )
    restored.buttons["undo-delete-bookmark"].tap()
    probe = try requireProbe(restored, count: 2, transactions: 1, position: 60_000)
    XCTAssertEqual(probe["order"], "\(boundaryBookmarkID),\(secondBookmarkID)")
    XCTAssertEqual(
      probe["deletions"],
      "\(deletionID)~\(boundaryBookmarkID)~0~undone~set"
    )
    XCTAssertFalse(restored.buttons["undo-delete-bookmark"].exists)

    try returnToLibraryRoot(restored)
    let openSearch = restored.buttons["open-library-search"]
    XCTAssertTrue(openSearch.waitForExistence(timeout: 2))
    openSearch.tap()
    let librarySearch = restored.textFields["library-search-input"]
    XCTAssertTrue(librarySearch.waitForExistence(timeout: 2))
    try focusAndType("cafe clue", into: librarySearch, in: restored)
    try requireValue(
      restored.descendants(matching: .any)["library-search-probe"],
      "search:query=cafe clue:count=1:sort=title:direction=ascending:status=any:formats=any:missing=false:empty=none:order=\(bookID)"
    )
    tester.generateDocs()
  }

  private func editSecondBookmark(_ app: XCUIApplication) throws {
    let edit = app.buttons["edit-bookmark-\(secondBookmarkID)"]
    try tapWhenHittable(edit, in: app)
    let label = app.textFields["bookmark-label-editor"]
    XCTAssertTrue(label.waitForExistence(timeout: 2))
    let clearLabel = app.buttons["clear-bookmark-label"]
    XCTAssertTrue(clearLabel.waitForExistence(timeout: 2))
    clearLabel.tap()
    XCTAssertTrue(
      waitForEmptyFieldValue(label, placeholder: "Bookmark label", timeout: 2),
      "Expected the production clear action to empty the field; actual=\(String(describing: label.value))"
    )
    let save = app.buttons["save-bookmark"]
    let disabled = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == false"),
      object: save
    )
    XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 2), .completed)
    try focusAndType("Écho marker", into: label, in: app)

    let note = app.textViews["bookmark-note-editor"]
    XCTAssertTrue(note.waitForExistence(timeout: 2))
    try focusAndType("Return to the café clue", into: note, in: app)
    XCTAssertTrue(save.isEnabled)
    save.tap()
    XCTAssertFalse(app.descendants(matching: .any)["bookmark-editor"].waitForExistence(timeout: 1))
  }

  private func waitForEmptyFieldValue(
    _ field: XCUIElement,
    placeholder: String,
    timeout: TimeInterval
  ) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == '' OR value == %@", placeholder),
      object: field
    )
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func assertEverySort(_ app: XCUIApplication) throws {
    try selectSort(
      app, optionID: "bookmark-sort-position-descending", fallback: "Position, last to first",
      expected: "bookmarks:query=:sort=positionDescending:count=2:order=\(boundaryBookmarkID),\(secondBookmarkID)"
    )
    try selectSort(
      app, optionID: "bookmark-sort-date-newest", fallback: "Newest first",
      expected: "bookmarks:query=:sort=dateNewest:count=2:order=\(secondBookmarkID),\(boundaryBookmarkID)"
    )
    try selectSort(
      app, optionID: "bookmark-sort-date-oldest", fallback: "Oldest first",
      expected: "bookmarks:query=:sort=dateOldest:count=2:order=\(boundaryBookmarkID),\(secondBookmarkID)"
    )
    try selectSort(
      app, optionID: "bookmark-sort-label", fallback: "Label",
      expected: "bookmarks:query=:sort=label:count=2:order=\(secondBookmarkID),\(boundaryBookmarkID)"
    )
  }

  private func selectSort(
    _ app: XCUIApplication,
    optionID: String,
    fallback: String,
    expected: String
  ) throws {
    let menu = app.buttons["bookmark-sort"]
    try tapWhenHittable(menu, in: app)
    let option = app.buttons[optionID]
    if option.waitForExistence(timeout: 1) { option.tap() }
    else {
      let fallbackOption = app.buttons[fallback]
      XCTAssertTrue(fallbackOption.waitForExistence(timeout: 2))
      fallbackOption.tap()
    }
    try requireBookmarksScreen(app, expected)
  }

  private func openNowPlaying(_ app: XCUIApplication) throws {
    let miniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    miniPlayer.tap()
    XCTAssertTrue(app.otherElements["now-playing-screen"].waitForExistence(timeout: 2))
  }

  private func openBookmarkDetail(_ app: XCUIApplication) throws {
    let allBooks = app.buttons["browse-all-books"]
    try tapWhenHittable(allBooks, in: app)
    let book = app.buttons["all-books-book-\(bookID)"]
    XCTAssertTrue(book.waitForExistence(timeout: 2))
    book.tap()
    XCTAssertTrue(app.descendants(matching: .any)["book-detail-screen"].waitForExistence(timeout: 2))
    try tapWhenHittable(app.buttons["bookmarks-segment"], in: app)
    try requireValue(app.buttons["bookmarks-segment"], "selected")
  }

  private func returnToLibraryRoot(_ app: XCUIApplication) throws {
    for _ in 0..<2 {
      let back = app.navigationBars.buttons.element(boundBy: 0)
      XCTAssertTrue(back.waitForExistence(timeout: 2))
      back.tap()
    }
    XCTAssertTrue(app.descendants(matching: .any)["library-screen"].waitForExistence(timeout: 2))
  }

  private func requireBookmarksScreen(_ app: XCUIApplication, _ expected: String) throws {
    try requireValue(app.descendants(matching: .any)["bookmarks-screen"], expected)
  }

  private func prepareBookmarkWalkthroughFrame(
    _ app: XCUIApplication,
    segment: XCUIElement,
    rows: [XCUIElement],
    jumpActions: [XCUIElement]
  ) throws {
    let scrollView = app.scrollViews.firstMatch
    let miniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(scrollView.exists)
    XCTAssertTrue(miniPlayer.exists)

    let align = app.buttons["e2e-align-bookmarks-walkthrough"]
    XCTAssertTrue(align.waitForExistence(timeout: 2))
    align.tap()

    let visible = NSPredicate(format: "hittable == true")
    for element in rows + jumpActions {
      let expectation = XCTNSPredicateExpectation(predicate: visible, object: element)
      XCTAssertEqual(
        XCTWaiter.wait(for: [expectation], timeout: 2),
        .completed,
        "Expected both bookmark cards and their primary actions to be visible and unobscured before capture"
      )
    }
    XCTAssertTrue(
      bookmarkFrameIsUnobscured(rows, actions: jumpActions, above: miniPlayer),
      "Both complete bookmark cards must sit above the mini-player before capture"
    )
    XCTAssertTrue(segment.isHittable, "The selected Chapters/Bookmarks control must remain visible")
  }

  private func revealBookmarkRow(_ row: XCUIElement, in app: XCUIApplication) throws {
    let scrollView = app.scrollViews.firstMatch
    XCTAssertTrue(scrollView.exists)
    for _ in 0..<5 where !row.exists || !row.isHittable {
      scrollView.swipeUp(velocity: .slow)
    }
    XCTAssertTrue(row.waitForExistence(timeout: 2), "Expected the bookmark row to be reachable by scrolling")
  }

  private func bookmarkFrameIsUnobscured(
    _ rows: [XCUIElement],
    actions: [XCUIElement],
    above miniPlayer: XCUIElement
  ) -> Bool {
    let unobscuredBottom = miniPlayer.frame.minY - 4
    return (rows + actions).allSatisfy {
      $0.exists && $0.isHittable && $0.frame.maxY <= unobscuredBottom
    }
  }

  private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication) throws {
    let deadline = Date().addingTimeInterval(2)
    while !element.isHittable && Date() < deadline {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
    element.tap()
  }

  private func focusAndType(
    _ text: String,
    into field: XCUIElement,
    in app: XCUIApplication
  ) throws {
    let identifier = field.identifier
    let elementType = field.elementType
    let currentField = app.descendants(matching: elementType)[identifier]
    XCTAssertTrue(currentField.waitForExistence(timeout: 2))
    currentField.tap()

    let focusExpectation: (identifier: String, value: String)
    switch identifier {
    case "bookmark-search": focusExpectation = ("bookmark-search-focus-state", "focused")
    case "bookmark-label-editor": focusExpectation = ("bookmark-editor-focus-state", "label")
    case "bookmark-note-editor": focusExpectation = ("bookmark-editor-focus-state", "note")
    case "library-search-input": focusExpectation = ("library-search-focus-state", "focused")
    default:
      XCTFail("No observable focus state is defined for \(identifier)")
      return
    }
    let focusProbe = app.descendants(matching: .any)[focusExpectation.identifier]
    XCTAssertTrue(
      focusProbe.waitForStringValue(focusExpectation.value, timeout: 2),
      "Expected \(identifier) to acquire focus before typing"
    )
    currentField.typeText(text)
    XCTAssertTrue(
      currentField.waitForStringValue(text, timeout: 2),
      "Expected \(identifier) to receive the complete text"
    )
  }

  private func requireProbe(
    _ app: XCUIApplication,
    count: Int,
    transactions: Int? = nil,
    position: Int64
  ) throws -> BookmarkProbe {
    let element = app.descendants(matching: .any)["bookmarks-state-probe"]
    let predicate = NSPredicate { object, _ in
      guard let element = object as? XCUIElement,
        let value = element.value as? String,
        let probe = BookmarkProbe(value),
        probe["count"] == String(count),
        transactions == nil || probe["transactions"] == String(transactions!),
        probe["position"] == String(position)
      else { return false }
      return true
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    if XCTWaiter.wait(for: [expectation], timeout: 2) == .completed,
      let value = element.value as? String,
      let probe = BookmarkProbe(value)
    {
      return probe
    }
    XCTFail("Bookmark probe did not reach count=\(count), transactions=\(transactions.map(String.init) ?? "any"), position=\(position); actual=\(String(describing: element.value))")
    throw BookmarkUITestError.probeUnavailable
  }

  private func requireValue(
    _ element: XCUIElement,
    _ expected: String,
    timeout: TimeInterval = 2
  ) throws {
    guard element.waitForStringValue(expected, timeout: timeout) else {
      XCTFail("Expected \(element) to expose \(expected); actual=\(String(describing: element.value))")
      throw BookmarkUITestError.probeUnavailable
    }
  }

  private func makeApplication(reset: Bool) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e",
      "-e2e-fixture", "bookmarks",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset { app.launchArguments.insert("-e2e-reset", at: 1) }
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }
}

private struct BookmarkProbe {
  private var fields: [String: String]
  let journal: String

  init?(_ value: String) {
    let tokens = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard tokens.first == "bookmarks" else { return nil }
    var parsed: [String: String] = [:]
    for token in tokens.dropFirst() {
      guard let separator = token.firstIndex(of: "=") else { continue }
      parsed[String(token[..<separator])] = String(token[token.index(after: separator)...])
    }
    fields = parsed
    journal = parsed["journal"] ?? ""
  }

  subscript(_ key: String) -> String? { fields[key] }
}

private enum BookmarkUITestError: Error { case probeUnavailable }
