import XCTest

@MainActor
final class BookmarkUITests: PlayerUITestCase {
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
    try addBookmark(
      with: add,
      expectedValue: "bookmark=\(boundaryBookmarkID):book=\(bookID):position=60000",
      in: app
    )
    var probe = try requireProbe(app, count: 1, position: 60_000, clock: 1_700_030_000)
    XCTAssertEqual(probe["clock"], "1700030000")
    XCTAssertEqual(probe["order"], boundaryBookmarkID)
    XCTAssertEqual(
      probe["items"],
      "\(boundaryBookmarkID)~60000~\(secondAssetID)~0~crossing~The Crossing · 1:00~none~1700030000~1700030000"
    )
    XCTAssertEqual(probe.journal, "1:pause@60000")

    let prepareSecond = app.buttons["e2e-bookmark-second-position"]
    XCTAssertTrue(prepareSecond.waitForExistence(timeout: 2))
    prepareSecond.tap()
    probe = try requireProbe(app, count: 1, position: 15_000, clock: 1_700_030_060)
    XCTAssertEqual(probe["clock"], "1700030060")
    XCTAssertEqual(probe.journal, "1:pause@60000,2:seek@15000")
    try addBookmark(
      with: add,
      expectedValue: "bookmark=\(secondBookmarkID):book=\(bookID):position=15000",
      in: app
    )
    probe = try requireProbe(app, count: 2, position: 15_000, clock: 1_700_030_060)
    XCTAssertEqual(probe["order"], "\(boundaryBookmarkID),\(secondBookmarkID)")

    let doneButtons = app.navigationBars.buttons.matching(identifier: "close-now-playing")
    let done = doneButtons.element
    XCTAssertTrue(done.waitForExistence(timeout: 2))
    XCTAssertEqual(
      doneButtons.count,
      1,
      "Now Playing must expose one navigation-scoped Done button"
    )
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
    probe = try requireProbe(app, count: 2, position: 15_000, clock: 1_700_030_060)
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
    let keyboards = app.keyboards
    XCTAssertLessThanOrEqual(keyboards.count, 1, "Bookmark search must expose at most one keyboard")
    if keyboards.count == 1 {
      search.typeKey(.return, modifierFlags: [])
    }
    XCTAssertTrue(
      waitForNoElements(keyboards),
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
      ],
      captureReadiness: bookmarkCaptureReadiness(
        app: app,
        specification: "At capture, the exact two-bookmark label ordering and durable bookmark model are settled with both complete cards unobscured and no transient editor, menu, keyboard, or alert",
        anchor: app.descendants(matching: .any)["book-detail-scroll-readiness"]
      ) {
        guard
          let value = app.descendants(matching: .any)["bookmarks-state-probe"].value as? String,
          let state = BookmarkProbe(value)
        else { return false }
        return state["count"] == "2"
          && state["order"] == "\(self.boundaryBookmarkID),\(self.secondBookmarkID)"
          && state["transactions"] == "0"
          && state["position"] == "15000"
          && self.hasExactValue(
            app.descendants(matching: .any)["bookmarks-screen"],
            "bookmarks:query=:sort=label:count=2:order=\(self.secondBookmarkID),\(self.boundaryBookmarkID)"
          )
          && self.hasSettledScroll(
            app.descendants(matching: .any)["book-detail-scroll-readiness"],
            containerID: "book-detail-scroll"
          )
          && self.hasExactValue(app.buttons["bookmarks-segment"], "selected")
          && app.buttons["bookmarks-segment"].isHittable
          && self.bookmarkSegmentIsFramed(
            app.buttons["bookmarks-segment"],
            within: app.scrollViews["book-detail-scroll"]
          )
          && self.bookmarkFrameIsUnobscured(
            [secondRow, boundaryRow],
            actions: [
              app.buttons["bookmarks-segment"],
              app.buttons["jump-to-bookmark-\(self.secondBookmarkID)"],
              app.buttons["jump-to-bookmark-\(self.boundaryBookmarkID)"],
            ],
            above: app.otherElements["mini-player"],
            within: app.scrollViews["book-detail-scroll"]
          )
          && app.otherElements["mini-player"].exists
      }
    )

    let jump = app.buttons["jump-to-bookmark-\(boundaryBookmarkID)"]
    try tapWhenHittable(jump, in: app)
    try requireValue(
      app.descendants(matching: .any)["bookmark-jump-confirmation"],
      "bookmark=\(boundaryBookmarkID):position=60000"
    )
    probe = try requireProbe(app, count: 2, position: 60_000, clock: 1_700_030_060)
    XCTAssertEqual(probe.journal, "1:pause@60000,2:seek@15000,3:seek@60000")

    let delete = app.buttons["delete-bookmark-\(boundaryBookmarkID)"]
    XCTAssertTrue(delete.waitForExistence(timeout: 2))
    delete.tap()
    probe = try requireProbe(
      app, count: 1, transactions: 1, position: 60_000, clock: 1_700_030_060
    )
    XCTAssertEqual(probe["order"], secondBookmarkID)
    XCTAssertEqual(
      probe["deletions"],
      "\(deletionID)~\(boundaryBookmarkID)~0~deleted~1700030060~none"
    )
    XCTAssertEqual(probe["clock"], "1700030060")
    try requireValue(
      app.buttons["undo-delete-bookmark"],
      "transaction=\(deletionID):bookmark=\(boundaryBookmarkID)"
    )
    XCTAssertTrue(terminateAndWait(app))

    let restored = makeApplication(reset: false)
    restored.launch()
    try openBookmarkDetail(restored)
    probe = try requireProbe(
      restored, count: 1, transactions: 1, position: 60_000, clock: 1_700_030_060
    )
    XCTAssertEqual(probe["clock"], "1700030060")
    try requireValue(
      restored.buttons["undo-delete-bookmark"],
      "transaction=\(deletionID):bookmark=\(boundaryBookmarkID)"
    )
    restored.buttons["undo-delete-bookmark"].tap()
    probe = try requireProbe(
      restored, count: 2, transactions: 1, position: 60_000, clock: 1_700_030_060
    )
    XCTAssertEqual(probe["order"], "\(boundaryBookmarkID),\(secondBookmarkID)")
    XCTAssertEqual(
      probe["deletions"],
      "\(deletionID)~\(boundaryBookmarkID)~0~undone~1700030060~1700030060"
    )
    XCTAssertFalse(restored.buttons["undo-delete-bookmark"].exists)

    try returnToLibraryRoot(restored)
    let openSearch = restored.buttons["open-library-search"]
    XCTAssertTrue(openSearch.waitForExistence(timeout: 2))
    openSearch.tap()
    let librarySearch = restored.textFields["library-search-input"]
    XCTAssertTrue(librarySearch.waitForExistence(timeout: 2))
    try focusAndType("cafe clue", into: librarySearch, in: restored)
    try requireSearchValue(
      restored.descendants(matching: .any)["library-search-probe"],
      "query=cafe clue:count=1:sort=title:direction=ascending:status=any:formats=any:missing=false:empty=none:order=\(bookID)"
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
      app.descendants(matching: .any)["bookmark-label-editor-value"].waitForStringValue(
        "empty",
        timeout: 2
      ),
      "Expected the production clear action to publish the empty label state"
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
    XCTAssertTrue(
      waitForPredicate(
        NSPredicate(format: "exists == false"),
        on: app.descendants(matching: .any)["bookmark-editor"]
      ),
      "The bookmark editor must finish dismissing after Save"
    )
  }

  private func assertEverySort(_ app: XCUIApplication) throws {
    try selectSort(
      app, optionID: "bookmark-sort-position-descending",
      expected: "bookmarks:query=:sort=positionDescending:count=2:order=\(boundaryBookmarkID),\(secondBookmarkID)"
    )
    try selectSort(
      app, optionID: "bookmark-sort-date-newest",
      expected: "bookmarks:query=:sort=dateNewest:count=2:order=\(secondBookmarkID),\(boundaryBookmarkID)"
    )
    try selectSort(
      app, optionID: "bookmark-sort-date-oldest",
      expected: "bookmarks:query=:sort=dateOldest:count=2:order=\(boundaryBookmarkID),\(secondBookmarkID)"
    )
    try selectSort(
      app, optionID: "bookmark-sort-label",
      expected: "bookmarks:query=:sort=label:count=2:order=\(secondBookmarkID),\(boundaryBookmarkID)"
    )
  }

  private func selectSort(
    _ app: XCUIApplication,
    optionID: String,
    expected: String
  ) throws {
    let menu = app.buttons["bookmark-sort"]
    try tapWhenHittable(menu, in: app)
    let options = app.buttons.matching(identifier: optionID)
    let selectedOption = options.element
    XCTAssertTrue(
      waitForPredicate(
        NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
        on: selectedOption
      ),
      "The bookmark sort menu must publish a hittable \(optionID) action"
    )
    XCTAssertEqual(options.count, 1, "The bookmark sort option identifier must be unique.")
    try deliverBookmarkSortSelection(options, expected: expected, in: app)
    XCTAssertTrue(
      waitForNoElements(options, deadline: EventDeadline()),
      "The bookmark sort menu must dismiss after selecting \(optionID)"
    )
    try requireBookmarksScreen(app, expected)
  }

  private func deliverBookmarkSortSelection(
    _ options: XCUIElementQuery,
    expected: String,
    in app: XCUIApplication
  ) throws {
    let receipt = app.descendants(matching: .any)["bookmarks-screen"]
    let receiptPredicate = NSPredicate(format: "exists == true AND value == %@", expected)
    if receiptPredicate.evaluate(with: receipt) { return }

    let targets = options.allElementsBoundByIndex
    guard targets.count == 1 else {
      XCTFail("The bookmark sort menu did not expose exactly one current action")
      throw BookmarkUITestError.sortActionUnavailable
    }
    let target = targets[0]
    let targetFrame = target.frame
    let appFrame = app.frame
    guard target.exists, target.isEnabled, target.isHittable,
      !targetFrame.isEmpty, !appFrame.isEmpty, appFrame.contains(targetFrame)
    else {
      XCTFail("The bookmark sort menu did not expose a contained physical action")
      throw BookmarkUITestError.sortActionUnavailable
    }
    let coordinate = app.coordinate(
      withNormalizedOffset: CGVector(
        dx: (targetFrame.midX - appFrame.minX) / appFrame.width,
        dy: (targetFrame.midY - appFrame.minY) / appFrame.height
      )
    )

    var deliveryDeadline: EventDeadline?
    repeat {
      if receiptPredicate.evaluate(with: receipt) { return }
      if let deliveryDeadline {
        let currentTargets = options.allElementsBoundByIndex
        guard currentTargets.count == 1,
          currentTargets[0].exists,
          currentTargets[0].isEnabled,
          currentTargets[0].isHittable,
          currentTargets[0].frame == targetFrame
        else {
          if waitForPredicate(
            receiptPredicate,
            on: receipt,
            timeout: deliveryDeadline.remaining
          ) { return }
          XCTFail("The bookmark sort menu transitioned without publishing its semantic receipt")
          throw BookmarkUITestError.sortActionUnavailable
        }
        if deliveryDeadline.remaining <= 0 { break }
      }

      guard performPhysicalInteractionWithoutPostEventQuiescence(
        in: app,
        { coordinate.tap() }
      ) else {
        XCTFail("The pinned XCTest runtime did not expose bounded physical synthesis")
        throw BookmarkUITestError.sortActionUnavailable
      }
      if deliveryDeadline == nil { deliveryDeadline = EventDeadline() }
      guard let deliveryDeadline else {
        XCTFail("The bookmark sort menu could not establish its delivery deadline")
        throw BookmarkUITestError.sortActionUnavailable
      }
      if waitForPredicate(
        receiptPredicate,
        on: receipt,
        timeout: min(0.25, deliveryDeadline.remaining)
      ) { return }
    } while (deliveryDeadline?.remaining ?? 0) > 0

    XCTFail("The bookmark sort menu action did not publish its semantic receipt")
    throw BookmarkUITestError.sortActionUnavailable
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
    let allBooksBack = app.navigationBars["Book Detail"].buttons["All Books"]
    XCTAssertTrue(allBooksBack.waitForExistence(timeout: 2))
    allBooksBack.tap()
    XCTAssertTrue(app.descendants(matching: .any)["all-books-screen"].waitForExistence(timeout: 2))

    let libraryBack = app.navigationBars["All Books"].buttons["Library"]
    XCTAssertTrue(libraryBack.waitForExistence(timeout: 2))
    libraryBack.tap()
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
    let miniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(waitForExistence(miniPlayer, deadline: EventDeadline()))
    let scroll = app.scrollViews["book-detail-scroll"]
    let surface = ScrollSurface(
      application: app,
      container: scroll,
      readiness: app.descendants(matching: .any)["book-detail-scroll-readiness"],
      containerID: "book-detail-scroll",
      axis: .vertical
    )
    XCTAssertTrue(waitForExistence(scroll, deadline: EventDeadline()))

    XCTAssertTrue(
      scrollUntil(
        { surface.state()?.atBottom == true },
        on: surface,
        deadline: EventDeadline(),
        requiresScrollableRange: true,
        failureContext: {
          "segment=\(segment.frame), rows=\(rows.map(\.frame)), "
            + "actions=\(jumpActions.map(\.frame)), mini-player=\(miniPlayer.frame)"
        }
      ) {
        scroll.swipeUp(velocity: .fast)
      },
      "Book Detail must reach its correlated bottom endpoint before bookmark framing"
    )
    for element in [segment] + rows + jumpActions {
      XCTAssertTrue(
        waitForPredicate(
          NSPredicate(format: "exists == true AND hittable == true"),
          on: element
        ),
        "\(element.identifier) must be independently actionable after bottom-endpoint framing"
      )
    }
    XCTAssertTrue(bookmarkSegmentIsFramed(segment, within: scroll))
    XCTAssertTrue(
      bookmarkFrameIsUnobscured(
        rows,
        actions: [segment] + jumpActions,
        above: miniPlayer,
        within: scroll
      ),
      "Both complete bookmark cards must settle above the mini-player at the proven bottom endpoint"
    )
  }

  private func bookmarkSegmentIsFramed(
    _ segment: XCUIElement,
    within scroll: XCUIElement
  ) -> Bool {
    guard segment.exists, scroll.exists, scroll.frame.height > 0 else { return false }
    let normalizedMinY = (segment.frame.minY - scroll.frame.minY) / scroll.frame.height
    return (0.230...0.238).contains(normalizedMinY)
  }

  private func revealBookmarkRow(_ row: XCUIElement, in app: XCUIApplication) throws {
    let scroll = app.scrollViews["book-detail-scroll"]
    XCTAssertTrue(waitForExistence(scroll, deadline: EventDeadline()))
    let surface = ScrollSurface(
      application: app,
      container: scroll,
      readiness: app.descendants(matching: .any)["book-detail-scroll-readiness"],
      containerID: "book-detail-scroll",
      axis: .vertical,
      permitsGeometrySettledFallback: true
    )
    XCTAssertTrue(
      scrollUntil(
        { surface.state()?.atBottom == true },
        on: surface,
        deadline: EventDeadline(),
        terminalEndpoint: \.atBottom
      ) {
        scroll.swipeUp(velocity: .fast)
      },
      "Expected Book Detail to reach its correlated bottom endpoint while revealing a bookmark row"
    )
    XCTAssertTrue(
      elementIsFullyVisible(
        row,
        within: scroll,
        requiresHittable: false
      ),
      "Expected the complete bookmark row to be visible at the proven bottom endpoint"
    )
  }

  private func bookmarkFrameIsUnobscured(
    _ rows: [XCUIElement],
    actions: [XCUIElement],
    above miniPlayer: XCUIElement,
    within scroll: XCUIElement
  ) -> Bool {
    let unobscuredTop = scroll.frame.minY + 4
    let unobscuredBottom = miniPlayer.frame.minY - 4
    return (rows + actions).allSatisfy {
      $0.frame.minY >= unobscuredTop && $0.frame.maxY <= unobscuredBottom
    }
  }

  private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication) throws {
    if element.isHittable {
      element.tap()
      return
    }
    let bookDetail = app.scrollViews["book-detail-scroll"]
    let libraryScroll = app.descendants(matching: .any)["library-root-scroll"]
    let scrollContainer = bookDetail.exists ? bookDetail : libraryScroll
    let containerID = bookDetail.exists ? "book-detail-scroll" : "library-root-scroll"
    let readinessID = bookDetail.exists
      ? "book-detail-scroll-readiness" : "library-root-scroll-readiness"
    let deadline = EventDeadline()
    XCTAssertTrue(waitForExistence(scrollContainer, deadline: deadline))
    let surface = ScrollSurface(
      application: app,
      container: scrollContainer,
      readiness: app.descendants(matching: .any)[readinessID],
      containerID: containerID,
      axis: .vertical
    )
    XCTAssertTrue(
      scrollUntil(
        { element.isHittable },
        on: surface,
        deadline: deadline,
        terminalEndpoint: \.atBottom
      ) {
        scrollContainer.swipeUp(velocity: .fast)
      },
      "Expected \(element.identifier) to become hittable through progress-making screen scrolling"
    )
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
    let originIdentifier: String
    switch identifier {
    case "bookmark-label-editor", "bookmark-note-editor":
      originIdentifier = "bookmark-editor"
    case "bookmark-search":
      originIdentifier = "bookmarks-screen"
    case "library-search-input":
      originIdentifier = "library-search-screen"
    default:
      XCTFail("Focus delivery has no exact origin for \(identifier)")
      return
    }
    let exactOrigin = app.descendants(matching: .any)[originIdentifier]
    XCTAssertTrue(resolveAppleIntelligenceNotification(testCase: self))
    let appFrame = app.frame
    let fieldFrame = currentField.frame
    guard
      currentField.isEnabled && currentField.isHittable
        && exactOrigin.exists && !appFrame.isEmpty && !fieldFrame.isEmpty
        && appFrame.contains(fieldFrame)
    else {
      XCTFail(
      "Expected \(identifier) to expose one contained physical focus target"
      )
      return
    }
    let coordinate = app.coordinate(
      withNormalizedOffset: CGVector(
        dx: (fieldFrame.midX - appFrame.minX) / appFrame.width,
        dy: (fieldFrame.midY - appFrame.minY) / appFrame.height
      )
    )
    guard let focusReceipt = DarwinEventReceipt(
      name: "com.spnss.player.e2e.text-input-focused"
    ) else {
      XCTFail("Expected the Darwin focus receipt to register")
      return
    }
    var deliveryDeadline: EventDeadline?
    var delivered = false
    repeat {
      if let deliveryDeadline {
        guard exactOrigin.exists, currentField.exists, currentField.isEnabled,
          currentField.isHittable, currentField.frame == fieldFrame
        else {
          delivered = focusReceipt.wait(timeout: deliveryDeadline.remaining)
          break
        }
        if deliveryDeadline.remaining <= 0 { break }
      }
      XCTAssertTrue(
        performPhysicalInteractionWithoutPostEventQuiescence(in: app) {
          coordinate.tap()
        },
        "Expected the pinned XCTest runtime to synthesize focus for \(identifier)"
      )
      if deliveryDeadline == nil { deliveryDeadline = EventDeadline() }
      guard let deliveryDeadline else { break }
      delivered = focusReceipt.wait(timeout: min(0.25, deliveryDeadline.remaining))
    } while !delivered && (deliveryDeadline?.remaining ?? 0) > 0
    XCTAssertTrue(
      delivered,
      "Expected \(identifier) to publish its production focus event within two seconds while the exact editor target remained unchanged"
    )
    guard delivered else { return }
    currentField.typeText(text)

    let valueProbeIdentifier: String?
    switch identifier {
    case "bookmark-label-editor": valueProbeIdentifier = "bookmark-label-editor-value"
    case "bookmark-note-editor": valueProbeIdentifier = "bookmark-note-editor-value"
    default: valueProbeIdentifier = nil
    }
    let valueProbeMatches = valueProbeIdentifier.map {
      app.descendants(matching: .any)[$0].waitForStringValue(text, timeout: 2)
    } ?? false
    XCTAssertTrue(
      valueProbeMatches || currentField.waitForStringValue(text, timeout: 2),
      "Expected \(identifier) to receive the complete text"
    )
  }

  private func requireProbe(
    _ app: XCUIApplication,
    count: Int,
    transactions: Int? = nil,
    position: Int64,
    clock: Int64
  ) throws -> BookmarkProbe {
    let element = app.descendants(matching: .any)["bookmarks-state-probe"]
    func matches(_ probe: BookmarkProbe) -> Bool {
      probe["count"] == String(count)
        && (transactions == nil || probe["transactions"] == String(transactions!))
        && probe["position"] == String(position)
        && probe["clock"] == String(clock)
    }
    let predicate = NSPredicate { object, _ in
      guard let element = object as? XCUIElement,
        let value = element.value as? String,
        let probe = BookmarkProbe(value)
      else { return false }
      return matches(probe)
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    _ = XCTWaiter.wait(for: [expectation], timeout: 2)
    if let value = element.value as? String,
      let probe = BookmarkProbe(value),
      matches(probe)
    {
      return probe
    }
    XCTFail("Bookmark probe did not reach count=\(count), transactions=\(transactions.map(String.init) ?? "any"), position=\(position), clock=\(clock); actual=\(String(describing: element.value))")
    throw BookmarkUITestError.probeUnavailable
  }

  private func addBookmark(
    with action: XCUIElement,
    expectedValue: String,
    in app: XCUIApplication
  ) throws {
    let receipt = app.descendants(matching: .any)["bookmark-saved"]
    let completed = NSPredicate(
      format: "exists == true AND value == %@",
      expectedValue
    )
    guard deliverPhysicalActionAcknowledgedByDisabling(
      action,
      until: receipt,
      satisfies: completed,
      in: app
    ) else {
      XCTFail("Add Bookmark did not acknowledge delivery within two seconds")
      throw BookmarkUITestError.probeUnavailable
    }
    try requireValue(receipt, expectedValue)
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

  private func requireSearchValue(
    _ element: XCUIElement,
    _ expectedResult: String
  ) throws {
    func matches(_ value: String?) -> Bool {
      guard let value else { return false }
      let fields = value.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
      return fields.count == 4
        && fields[0] == "search"
        && fields[1].hasPrefix("revision=")
        && fields[1].dropFirst("revision=".count).count == 64
        && fields[2] == "indexed=true"
        && fields[3] == expectedResult
    }

    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { object, _ in
        guard let element = object as? XCUIElement else { return false }
        return matches(element.value.map(String.init(describing:)))
      },
      object: element
    )
    _ = XCTWaiter.wait(for: [expectation], timeout: 2)
    guard matches(element.value.map(String.init(describing:))) else {
      XCTFail(
        "Expected indexed library search result \(expectedResult); "
          + "actual=\(String(describing: element.value))"
      )
      throw BookmarkUITestError.probeUnavailable
    }
  }

  private func makeApplication(reset: Bool) -> XCUIApplication {
    let app = bookshelfApplication()
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

  private func bookmarkCaptureReadiness(
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
        && app.menus.count == 0
        && !app.descendants(matching: .any)["bookmark-editor"].exists
    }
  }

  private func hasExactValue(_ element: XCUIElement, _ expected: String) -> Bool {
    element.exists && element.value.map(String.init(describing:)) == expected
  }

  private func hasSettledScroll(_ probe: XCUIElement, containerID: String) -> Bool {
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
  }
}

private struct BookmarkProbe {
  private static let keys: Set<String> = [
    "schema", "count", "order", "items", "transactions", "deletions", "clock", "position",
    "journal",
  ]
  private static let deletionStatuses: Set<String> = ["deleted", "undone"]
  private static let journalReasons: Set<String> = [
    "play", "periodic", "pause", "seek", "background", "interruption", "routeChange",
    "preResumeRewind", "resumeRewind", "undoResumeRewind", "sleepTimer",
  ]

  private var fields: [String: String]
  let journal: String

  init?(_ value: String) {
    let tokens = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard tokens.first == "bookmarks" else { return nil }
    var parsed: [String: String] = [:]
    for token in tokens.dropFirst() {
      guard let separator = token.firstIndex(of: "=") else { return nil }
      let key = String(token[..<separator])
      let fieldValue = String(token[token.index(after: separator)...])
      guard !key.isEmpty, (!fieldValue.isEmpty || key == "journal"), parsed[key] == nil else {
        return nil
      }
      parsed[key] = fieldValue
    }
    guard Set(parsed.keys) == Self.keys, parsed["schema"] == "1",
      let count = Self.nonnegativeInt(parsed["count"]),
      let order = parsed["order"], let items = parsed["items"],
      let transactionCount = Self.nonnegativeInt(parsed["transactions"]),
      let deletions = parsed["deletions"],
      Self.nonnegativeInt64(parsed["clock"]) != nil,
      Self.nonnegativeInt64(parsed["position"]) != nil,
      let journal = parsed["journal"], Self.validJournal(journal)
    else { return nil }

    let orderedIDs: [String]
    if count == 0 {
      guard order == "none", items == "none" else { return nil }
      orderedIDs = []
    } else {
      orderedIDs = order.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
      guard orderedIDs.count == count, Set(orderedIDs).count == count,
        orderedIDs.allSatisfy(Self.uuid),
        Self.validItems(items, count: count, orderedIDs: orderedIDs)
      else { return nil }
    }

    if transactionCount == 0 {
      guard deletions == "none" else { return nil }
    } else {
      guard Self.validDeletions(deletions, count: transactionCount) else { return nil }
    }
    fields = parsed
    self.journal = journal
  }

  subscript(_ key: String) -> String? { fields[key] }

  private static func validItems(_ value: String, count: Int, orderedIDs: [String]) -> Bool {
    guard value != "none" else { return false }
    let records = value.split(separator: ";", omittingEmptySubsequences: false)
    guard records.count == count else { return false }
    var itemIDs: [String] = []
    for record in records {
      let values = record.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
      guard values.count == 9, uuid(values[0]), nonnegativeInt64(values[1]) != nil,
        uuid(values[2]), nonnegativeInt64(values[3]) != nil,
        !values[4].isEmpty, !values[5].isEmpty,
        values[6] == "none" || !values[6].isEmpty,
        canonicalInt(values[7]) != nil, canonicalInt(values[8]) != nil
      else { return false }
      itemIDs.append(values[0])
    }
    return itemIDs == orderedIDs
  }

  private static func validDeletions(_ value: String, count: Int) -> Bool {
    guard value != "none" else { return false }
    let records = value.split(separator: ";", omittingEmptySubsequences: false)
    guard records.count == count else { return false }
    var transactionIDs: Set<String> = []
    for record in records {
      let values = record.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
      guard values.count == 6, uuid(values[0]), transactionIDs.insert(values[0]).inserted,
        uuid(values[1]), nonnegativeInt(values[2]) != nil,
        deletionStatuses.contains(values[3]),
        nonnegativeInt64(values[4]) != nil,
        (values[3] == "deleted" && values[5] == "none")
          || (values[3] == "undone" && nonnegativeInt64(values[5]) != nil)
      else { return false }
    }
    return true
  }

  private static func nonnegativeInt(_ value: String?) -> Int? {
    guard let value, let parsed = Int(value), parsed >= 0, String(parsed) == value else { return nil }
    return parsed
  }

  private static func nonnegativeInt64(_ value: String?) -> Int64? {
    guard let value, let parsed = Int64(value), parsed >= 0, String(parsed) == value else {
      return nil
    }
    return parsed
  }

  private static func canonicalInt(_ value: String?) -> Int? {
    guard let value, let parsed = Int(value), String(parsed) == value else { return nil }
    return parsed
  }

  private static func uuid(_ value: String?) -> Bool {
    guard let value, let parsed = UUID(uuidString: value) else { return false }
    return parsed.uuidString.lowercased() == value
  }

  private static func validJournal(_ value: String) -> Bool {
    if value.isEmpty { return true }
    var previousSequence = 0
    for event in value.split(separator: ",", omittingEmptySubsequences: false) {
      let sequenceAndEvent = event.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard sequenceAndEvent.count == 2,
        let sequence = nonnegativeInt(String(sequenceAndEvent[0])), sequence > previousSequence
      else { return false }
      let reasonAndPosition = sequenceAndEvent[1].split(
        separator: "@", maxSplits: 1, omittingEmptySubsequences: false
      )
      guard reasonAndPosition.count == 2,
        journalReasons.contains(String(reasonAndPosition[0])),
        nonnegativeInt64(String(reasonAndPosition[1])) != nil
      else { return false }
      previousSequence = sequence
    }
    return true
  }
}

private enum BookmarkUITestError: Error {
  case probeUnavailable
  case sortActionUnavailable
}
