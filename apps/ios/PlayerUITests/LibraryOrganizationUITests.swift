import XCTest

@MainActor
final class LibraryOrganizationUITests: XCTestCase {
  private let books = (1...5).map {
    String(format: "90000000-0000-0000-0000-%012d", $0)
  }
  private let bookTitles = [
    "Ember at Daybreak",
    "Tides Between Stars",
    "The Clockwork Orchard",
    "A Lantern for Winter",
    "Quiet Maps",
  ]
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
      view: "shelf"
    )
    let addAudiobook = app.tabBars.buttons["Add"]
    let libraryRootScroll = anyElement(app, "library-root-scroll")
    let libraryRootReadiness = anyElement(app, "library-root-scroll-readiness")
    let homeRecentShelf = anyElement(app, "library-home-recent-shelf-scroll")
    let homeRecentReadiness = anyElement(app, "library-home-recent-shelf-scroll-readiness")
    let initialArtwork = anyElement(app, "library-artwork-probe")
    let initialMiniPlayer = app.otherElements["mini-player"]
    try tester.step(
      "populated-library",
      description: "Library opens with deterministic Continue Listening and Up Next shelves",
      verifications: [
        .valueEquals(organizer, initialOrganizer, "Every populated shelf exposes its exact production-model order"),
        .exists(app.buttons["resume-book-\(books[0])"], "The current book can resume from Continue Listening"),
        .exists(app.buttons["open-up-next"], "The ordered Up Next shelf is available"),
        .exists(
          anyElement(app, "library-home-recently-added-shelf"),
          "Recently Added uses the reusable square-cover shelf"
        ),
        .exists(anyElement(app, "recent-book-\(books[4])"), "Recently Added begins with the newest book"),
        .exists(app.buttons["browse-series"], "Series browsing is available"),
        .exists(app.buttons["browse-authors"], "Author browsing is available"),
        .exists(app.buttons["browse-narrators"], "Narrator browsing is available"),
        .exists(addAudiobook, "The tab pill includes the Add Audiobook action"),
        StepVerification(specification: "The pill-integrated Add Audiobook action is directly tappable") {
          addAudiobook.isHittable
        },
      ],
      captureReadiness: organizationCaptureReadiness(
        app: app,
        specification: "At capture, the exact five-book organization and paused player are settled at the Library and Recently Added starts with visible cover-bearing cards",
        anchor: homeRecentReadiness
      ) {
        self.hasExactValue(organizer, initialOrganizer)
          && self.hasExactValue(initialArtwork, self.artworkValue(self.books))
          && self.hasExactValue(
            initialMiniPlayer,
            "player:paused:\(self.books[0]):0:45000"
          )
          && self.isSettled(
            libraryRootReadiness,
            containerID: "library-root-scroll",
            axis: .vertical,
            endpoint: \.atTop
          )
          && self.isSettled(
            homeRecentReadiness,
            containerID: "library-home-recent-shelf-scroll",
            axis: .horizontal,
            endpoint: \.atLeft
          )
          && self.visibleElements(
            in: app,
            identifierPrefix: "recent-book-",
            within: homeRecentShelf
          ).count >= 3
          && elementIsFullyVisible(addAudiobook, within: app.tabBars.firstMatch)
      }
    )

    addAudiobook.tap()
    XCTAssertTrue(anyElement(app, "computer-receiver-screen").waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["choose-from-files-computer-receiver"].exists)
    app.buttons["Close"].tap()
    XCTAssertTrue(anyElement(app, "library-screen").waitForExistence(timeout: 2))

    app.buttons["resume-book-\(books[0])"].tap()
    try requireValue(anyElement(app, "now-playing-screen"), "player:paused:\(books[0]):0:45000")
    XCTAssertTrue(terminateAndWait(app))
    app = try makeApplication(reset: false)
    app.launch()
    let workingOrganizer = anyElement(app, "library-organizer-probe")
    let workingArtwork = anyElement(app, "library-artwork-probe")

    app.buttons["open-up-next"].tap()
    let upNext = anyElement(app, "up-next-probe")
    try requireValue(upNext, upNextValue([books[1], books[4], books[2]]))
    app.buttons["up-next-move-up-\(books[2])"].tap()
    try requireValue(upNext, upNextValue([books[1], books[2], books[4]]))
    app.buttons["up-next-move-up-\(books[2])"].tap()
    try requireValue(upNext, upNextValue([books[2], books[1], books[4]]))
    app.buttons["up-next-book-\(books[2])"].tap()
    app.buttons["mark-finished-\(books[2])"].tap()
    let finishedAlert = app.alerts["Mark as finished?"]
    XCTAssertTrue(finishedAlert.waitForExistence(timeout: 2))
    let confirmFinished = finishedAlert.buttons["confirm-mark-finished"].firstMatch
    XCTAssertTrue(confirmFinished.waitForExistence(timeout: 2))
    confirmFinished.tap()
    try requireValue(
      anyElement(app, "book-state-probe"),
      "book:\(books[2]):finished=true:position=120000"
    )
    navigateBack(app, label: "Up Next", destination: upNext)
    try requireValue(upNext, upNextValue([books[1], books[4]]))
    navigateBack(app, label: "Library", destination: anyElement(app, "library-screen"))
    let postFinishedOrganizer = organizerValue(
      books: 5,
      continuing: [books[0]],
      upNext: [books[1], books[4]],
      finished: [books[2], books[3]],
      collections: 0,
      trash: 0,
      view: "shelf"
    )
    try requireValue(
      workingOrganizer,
      postFinishedOrganizer
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
    let expectedCollection =
      "collection:\(collectionID):name=Quiet Evenings:count=2:order=\(books[1]),\(books[0])"
    let collectionScroll = anyElement(app, "collection-detail-scroll")
    let collectionReadiness = anyElement(app, "collection-detail-scroll-readiness")
    let collectionArtwork = anyElement(app, "collection-artwork-probe")
    let firstCollectionBook = anyElement(app, "collection-book-\(books[1])")
    let secondCollectionBook = anyElement(app, "collection-book-\(books[0])")
    try tester.step(
      "curated-collection",
      description: "A custom collection retains the listener's manual book order",
      verifications: [
        .valueEquals(
          collection,
          expectedCollection,
          "The named collection contains exactly two books in curated order"
        ),
        .exists(firstCollectionBook, "The first ordered collection book is visible"),
        .exists(secondCollectionBook, "The second ordered collection book is visible"),
      ],
      captureReadiness: organizationCaptureReadiness(
        app: app,
        specification: "At capture, the exact two-book collection order and its cover-bearing rows are fully visible on idle production List geometry",
        anchor: collectionReadiness
      ) {
        self.hasExactValue(collection, expectedCollection)
          && self.hasExactValue(collectionArtwork, self.artworkValue(self.books))
          && self.isSettled(
            collectionReadiness,
            containerID: "collection-detail-scroll",
            axis: .vertical
          )
          && elementIsFullyVisible(firstCollectionBook, within: collectionScroll)
          && elementIsFullyVisible(secondCollectionBook, within: collectionScroll)
      }
    )
    navigateBack(app, label: "Collections", destination: anyElement(app, "collections-screen"))
    navigateBack(app, label: "Library", destination: anyElement(app, "library-screen"))

    app.buttons["browse-all-books"].tap()
    let allBooks = anyElement(app, "all-books-probe")
    let allBookOrder = [books[3], books[0], books[4], books[2], books[1]]
    try requireValue(allBooks, allBooksValue(view: "shelf", order: allBookOrder))
    let expectedShelfBooks = allBooksValue(view: "shelf", order: allBookOrder)
    let shelfOrganizer = organizerValue(
      books: 5,
      continuing: [books[0]],
      upNext: [books[1], books[4]],
      finished: [books[2], books[3]],
      collections: 1,
      trash: 0,
      view: "shelf"
    )
    let allBooksScroll = anyElement(app, "all-books-scroll")
    let allBooksReadiness = anyElement(app, "all-books-scroll-readiness")
    let continueShelf = anyElement(app, "all-books-continue-shelf-scroll")
    let continueShelfReadiness = anyElement(app, "all-books-continue-shelf-scroll-readiness")
    let recentShelf = anyElement(app, "all-books-recent-shelf-scroll")
    let recentShelfReadiness = anyElement(app, "all-books-recent-shelf-scroll-readiness")
    let recentShelfLeftEnd = anyElement(app, "all-books-recent-shelf-scroll-left-end")
    let alphabeticalShelf = anyElement(app, "all-books-a-z-shelf-scroll")
    let alphabeticalShelfReadiness = anyElement(app, "all-books-a-z-shelf-scroll-readiness")
    let recentShelfSurface = ScrollSurface(
      container: recentShelf,
      readiness: recentShelfReadiness,
      containerID: "all-books-recent-shelf-scroll",
      axis: .horizontal
    )
    let leftDeadline = EventDeadline()
    XCTAssertTrue(
      waitForExistence(recentShelf, deadline: leftDeadline)
        && waitForScrollReadiness(
          recentShelfSurface,
          deadline: leftDeadline,
          matching: { $0.isIdle && $0.atLeft }
        )
        && elementIsFullyVisible(
          recentShelfLeftEnd,
          within: recentShelf,
          requiresHittable: false
        ),
      "Recently Added must publish its idle left endpoint before capture"
    )
    try tester.step(
      "square-cover-bookshelves",
      description: "All Books presents square audiobook artwork at the left ends of burnt-orange wooden shelves",
      verifications: [
        .exists(anyElement(app, "all-books-bookshelf"), "The shelf presentation is visible"),
        .exists(
          anyElement(app, "all-books-recent-shelf-scroll"),
          "The books and their wooden shelf share one horizontal scroll surface"
        ),
        StepVerification(specification: "Recently Added exposes the wooden shelf's left endpoint") {
          elementIsFullyVisible(
            recentShelfLeftEnd,
            within: recentShelf,
            requiresHittable: false
          )
        },
        StepVerification(specification: "Recently Added is idle at its measured left endpoint") {
          guard let state = recentShelfSurface.state() else { return false }
          return state.isIdle && state.atLeft
        },
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
      ],
      captureReadiness: organizationCaptureReadiness(
        app: app,
        specification: "At capture, the exact shelf order and all visible cover-bearing shelves are idle at their production starts",
        anchor: recentShelfReadiness
      ) {
        self.hasExactValue(allBooks, expectedShelfBooks)
          && self.hasExactValue(workingOrganizer, shelfOrganizer)
          && self.hasExactValue(workingArtwork, self.artworkValue(self.books))
          && self.isSettled(
            allBooksReadiness,
            containerID: "all-books-scroll",
            axis: .vertical,
            endpoint: \.atTop
          )
          && self.isSettled(
            continueShelfReadiness,
            containerID: "all-books-continue-shelf-scroll",
            axis: .horizontal,
            endpoint: \.atLeft
          )
          && self.isSettled(
            recentShelfReadiness,
            containerID: "all-books-recent-shelf-scroll",
            axis: .horizontal,
            endpoint: \.atLeft
          )
          && self.isSettled(
            alphabeticalShelfReadiness,
            containerID: "all-books-a-z-shelf-scroll",
            axis: .horizontal,
            endpoint: \.atLeft
          )
          && elementIsFullyVisible(
            self.anyElement(app, "bookshelf-continue-book-\(self.books[0])"),
            within: continueShelf,
            requiresHittable: false
          )
          && elementIsFullyVisible(
            self.anyElement(app, "bookshelf-recent-book-\(self.books[4])"),
            within: recentShelf,
            requiresHittable: false
          )
          && elementIsFullyVisible(
            self.anyElement(app, "all-books-book-\(self.books[3])"),
            within: alphabeticalShelf,
            requiresHittable: false
          )
      }
    )
    let oldestRecentBook = anyElement(app, "bookshelf-recent-book-\(books[0])")
    let recentShelfRightEnd = anyElement(app, "all-books-recent-shelf-scroll-right-end")
    let finalBookIsFullyVisible = {
      oldestRecentBook.exists
        && oldestRecentBook.frame.minX >= recentShelf.frame.minX
        && oldestRecentBook.frame.maxX <= recentShelf.frame.maxX
    }
    XCTAssertTrue(
      scrollUntil(
        {
          recentShelfSurface.state()?.atRight == true
            && finalBookIsFullyVisible()
            && elementIsFullyVisible(
              recentShelfRightEnd,
              within: recentShelf,
              requiresHittable: false
            )
        },
        on: recentShelfSurface,
        deadline: EventDeadline(),
        requiresInteraction: true,
        requiresScrollableRange: true,
        terminalEndpoint: \.atRight
      ) {
        recentShelf.swipeLeft(velocity: .fast)
      },
      "The Recently Added shelf must reveal its final book and right end through progress-making scrolling"
    )
    XCTAssertTrue(
      challengeSettledEnd(
        on: recentShelfSurface,
        tracking: oldestRecentBook,
        deadline: EventDeadline()
      ) {
        recentShelf.swipeLeft(velocity: .fast)
      },
      "The Recently Added shelf must remain settled after one deliberate right-end challenge"
    )
    try tester.step(
      "square-cover-bookshelf-right-end",
      description: "The books carry their wooden shelf to its visible right end",
      verifications: [
        .exists(oldestRecentBook, "The oldest audiobook remains on the shared shelf"),
        StepVerification(specification: "The final audiobook is fully reachable at the shelf end") {
          recentShelfSurface.state()?.isIdle == true
            && recentShelfSurface.state()?.atRight == true
            && finalBookIsFullyVisible()
        },
        StepVerification(specification: "The wooden shelf's right endpoint is fully visible") {
          elementIsFullyVisible(
            recentShelfRightEnd,
            within: recentShelf,
            requiresHittable: false
          )
        },
      ],
      captureReadiness: organizationCaptureReadiness(
        app: app,
        specification: "At capture, the exact shelf state is idle with Recently Added at its right endpoint, its final cover and wooden end fully visible, and every other visible scroll surface settled",
        anchor: recentShelfReadiness
      ) {
        self.hasExactValue(allBooks, expectedShelfBooks)
          && self.hasExactValue(workingOrganizer, shelfOrganizer)
          && self.hasExactValue(workingArtwork, self.artworkValue(self.books))
          && self.isSettled(
            allBooksReadiness,
            containerID: "all-books-scroll",
            axis: .vertical
          )
          && self.isSettled(
            continueShelfReadiness,
            containerID: "all-books-continue-shelf-scroll",
            axis: .horizontal
          )
          && self.isSettled(
            recentShelfReadiness,
            containerID: "all-books-recent-shelf-scroll",
            axis: .horizontal,
            endpoint: \.atRight
          )
          && self.isSettled(
            alphabeticalShelfReadiness,
            containerID: "all-books-a-z-shelf-scroll",
            axis: .horizontal
          )
          && finalBookIsFullyVisible()
          && elementIsFullyVisible(
            recentShelfRightEnd,
            within: recentShelf,
            requiresHittable: false
          )
      }
    )
    app.buttons["library-view-list"].tap()
    try requireValue(allBooks, allBooksValue(view: "list", order: allBookOrder))
    XCTAssertTrue(terminateAndWait(app))

    let restoredApp = try makeApplication(reset: false)
    restoredApp.launch()
    verifyNonLibraryRunways(restoredApp)
    restoredApp.tabBars.buttons["Library"].tap()
    restoredApp.buttons["browse-all-books"].tap()
    let restoredAllBooks = anyElement(restoredApp, "all-books-probe")
    try requireValue(restoredAllBooks, allBooksValue(view: "list", order: allBookOrder))
    restoredApp.buttons["all-books-book-\(books[4])"].tap()
    restoredApp.buttons["move-book-to-trash-toolbar"].tap()
    let removalSheet = restoredApp.sheets["Move this audiobook to Trash?"]
    XCTAssertTrue(removalSheet.waitForExistence(timeout: 2))
    let confirmRemoval = removalSheet.buttons["remove-book-to-trash"].firstMatch
    XCTAssertTrue(confirmRemoval.waitForExistence(timeout: 2))
    confirmRemoval.tap()
    navigateBack(
      restoredApp,
      label: "Library",
      destination: anyElement(restoredApp, "library-screen")
    )
    let openTrash = restoredApp.buttons["open-trash"]
    let miniPlayer = restoredApp.otherElements["mini-player"]
    let libraryScroll = anyElement(restoredApp, "library-root-scroll")
    let libraryScrollReadiness = anyElement(restoredApp, "library-root-scroll-readiness")
    let librarySurface = ScrollSurface(
      container: libraryScroll,
      readiness: libraryScrollReadiness,
      containerID: "library-root-scroll",
      axis: .vertical
    )
    let trashedOrganizer = anyElement(restoredApp, "library-organizer-probe")
    let activeArtwork = anyElement(restoredApp, "library-artwork-probe")
    let expectedTrashedOrganizer = organizerValue(
      books: 4,
      continuing: [books[0]],
      upNext: [books[1]],
      finished: [books[2], books[3]],
      collections: 1,
      trash: 1,
      view: "list"
    )
    XCTAssertTrue(
      scrollUntil(
        { librarySurface.state()?.atTop == true },
        on: librarySurface,
        deadline: EventDeadline(),
        direction: .towardStart,
        requiresInteraction: true,
        requiresScrollableRange: true,
        terminalEndpoint: \.atTop,
        failureContext: {
          "target=\(openTrash.frame), target-hittable=\(openTrash.isHittable), "
            + "mini-player=\(miniPlayer.frame), scroll=\(libraryScroll.frame)"
        }
      ) {
        libraryScroll.swipeDown(velocity: .fast)
      },
      "Library must establish a progress-making top endpoint before testing its bottom runway"
    )
    let runwayDeadline = EventDeadline()
    XCTAssertTrue(waitForExistence(openTrash, deadline: runwayDeadline))
    XCTAssertTrue(waitForExistence(miniPlayer, deadline: runwayDeadline))
    XCTAssertTrue(
      scrollUntil(
        {
          librarySurface.state()?.atBottom == true
            && openTrash.isHittable
            && elementIsFullyVisible(
              openTrash,
              within: libraryScroll,
              obscuredBelow: miniPlayer
            )
        },
        on: librarySurface,
        deadline: runwayDeadline,
        requiresInteraction: true,
        requiresScrollableRange: true,
        terminalEndpoint: \.atBottom,
        failureContext: {
          "target=\(openTrash.frame), target-hittable=\(openTrash.isHittable), "
            + "mini-player=\(miniPlayer.frame), scroll=\(libraryScroll.frame)"
        }
      ) {
        fullHeightUpwardDrag(in: libraryScroll)
      },
      "Trash must become tappable above the mini-player through progress-making Library scrolling"
    )
    XCTAssertTrue(
      challengeSettledEnd(
        on: librarySurface,
        tracking: openTrash,
        deadline: EventDeadline()
      ) {
        fullHeightUpwardDrag(in: libraryScroll)
      },
      "Library must remain settled after one deliberate bottom-end challenge"
    )
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
        StepVerification(specification: "Trash is fully clear of the persistent player") {
          openTrash.isHittable && openTrash.frame.maxY <= miniPlayer.frame.minY - 4
        },
        StepVerification(specification: "Library publishes an idle, geometry-confirmed bottom endpoint") {
          guard let state = ScrollReadinessState(libraryScrollReadiness.value) else {
            return false
          }
          return state.isIdle && state.atBottom
        },
      ],
      captureReadiness: organizationCaptureReadiness(
        app: restoredApp,
        specification: "At capture, the exact four-book/one-Trash organization is idle at the Library bottom with Trash fully clear of the paused player",
        anchor: libraryScrollReadiness
      ) {
        self.hasExactValue(trashedOrganizer, expectedTrashedOrganizer)
          && self.hasExactValue(
            activeArtwork,
            self.artworkValue(Array(self.books.prefix(4)))
          )
          && self.hasExactValue(
            miniPlayer,
            "player:paused:\(self.books[0]):0:45000"
          )
          && self.isSettled(
            libraryScrollReadiness,
            containerID: "library-root-scroll",
            axis: .vertical,
            endpoint: \.atBottom
          )
          && openTrash.isHittable
          && elementIsFullyVisible(
            openTrash,
            within: libraryScroll,
            obscuredBelow: miniPlayer
          )
      }
    )
    openTrash.tap()
    let trash = anyElement(restoredApp, "trash-probe")
    let expectedTrash =
      "trash:transactions=1:books=\(books[4]):assets=1:bytes=8461:restorable=true:managed-checksum-preserved=true"
    let trashScroll = anyElement(restoredApp, "trash-scroll")
    let trashReadiness = anyElement(restoredApp, "trash-scroll-readiness")
    let trashArtwork = anyElement(restoredApp, "trash-artwork-probe")
    let trashedBook = anyElement(restoredApp, "trash-book-\(books[4])")
    try tester.step(
      "recoverable-trash",
      description: "Removing a book creates an exact recoverable Trash transaction",
      verifications: [
        .valueEquals(
          trash,
          expectedTrash,
          "Trash reports one intact restorable managed asset"
        ),
        .exists(trashedBook, "The removed book is identifiable in Trash"),
        .exists(restoredApp.buttons["restore-trash-\(trashID)"], "The exact removal transaction can be restored"),
        .exists(restoredApp.buttons["delete-trash-\(trashID)"], "The managed copy can be permanently deleted after confirmation"),
      ],
      captureReadiness: organizationCaptureReadiness(
        app: restoredApp,
        specification: "At capture, the exact recoverable Trash transaction, cover-bearing book row, and both actions are fully visible on idle production List geometry",
        anchor: trashReadiness
      ) {
        self.hasExactValue(trash, expectedTrash)
          && self.hasExactValue(trashArtwork, self.artworkValue([self.books[4]]))
          && self.isSettled(
            trashReadiness,
            containerID: "trash-scroll",
            axis: .vertical
          )
          && elementIsFullyVisible(trashedBook, within: trashScroll)
          && elementIsFullyVisible(
            restoredApp.buttons["restore-trash-\(self.trashID)"],
            within: trashScroll
          )
          && elementIsFullyVisible(
            restoredApp.buttons["delete-trash-\(self.trashID)"],
            within: trashScroll
          )
      }
    )
    restoredApp.buttons["restore-trash-\(trashID)"].tap()
    try requireValue(
      trash,
      "trash:transactions=0:books=none:assets=0:bytes=0:restorable=false:managed-checksum-preserved=true"
    )
    navigateBack(
      restoredApp,
      label: "Library",
      destination: anyElement(restoredApp, "library-screen")
    )
    restoredApp.buttons["browse-all-books"].tap()
    let restoredOrganizer = anyElement(restoredApp, "library-organizer-probe")
    let expectedRestoredOrganizer = organizerValue(
      books: 5,
      continuing: [books[0]],
      upNext: [books[1], books[4]],
      finished: [books[2], books[3]],
      collections: 1,
      trash: 0,
      view: "list"
    )
    let expectedRestoredBooks = allBooksValue(view: "list", order: allBookOrder)
    let restoredAllBooksScroll = anyElement(restoredApp, "all-books-scroll")
    let restoredAllBooksReadiness = anyElement(restoredApp, "all-books-scroll-readiness")
    let restoredArtwork = anyElement(restoredApp, "library-artwork-probe")
    let restoredBook = anyElement(restoredApp, "all-books-book-\(books[4])")
    try tester.step(
      "restored-library-list",
      description: "Restore returns the book and its organization while list preference persists",
      verifications: [
        .valueEquals(
          restoredOrganizer,
          expectedRestoredOrganizer,
          "Restore atomically returns the book to its prior Up Next position"
        ),
        .valueEquals(restoredAllBooks, expectedRestoredBooks, "The list choice survives restart and Trash restore"),
        .exists(restoredBook, "The restored book is visible again"),
      ],
      captureReadiness: organizationCaptureReadiness(
        app: restoredApp,
        specification: "At capture, the exact restored organization and persisted list order are settled with the restored cover-bearing row fully visible",
        anchor: restoredAllBooksReadiness
      ) {
        self.hasExactValue(restoredOrganizer, expectedRestoredOrganizer)
          && self.hasExactValue(restoredAllBooks, expectedRestoredBooks)
          && self.hasExactValue(restoredArtwork, self.artworkValue(self.books))
          && self.isSettled(
            restoredAllBooksReadiness,
            containerID: "all-books-scroll",
            axis: .vertical
          )
          && elementIsFullyVisible(restoredBook, within: restoredAllBooksScroll)
      }
    )

    navigateBack(
      restoredApp,
      label: "Library",
      destination: anyElement(restoredApp, "library-screen")
    )
    restoredApp.buttons["open-library-search"].tap()
    try requireValue(anyElement(restoredApp, "library-search-screen"), "ready")
    let searchInput = restoredApp.textFields["library-search-input"]
    XCTAssertTrue(searchInput.waitForExistence(timeout: 2))
    searchInput.tap()
    searchInput.typeText("Mina Sol\n")
    let searchProbe = anyElement(restoredApp, "library-search-probe")
    let searchFocus = anyElement(restoredApp, "library-search-focus-state")
    let searchLayoutReadiness = anyElement(restoredApp, "library-search-layout-readiness")
    let searchResultsScroll = anyElement(restoredApp, "library-search-results-scroll")
    let searchResultsReadiness = anyElement(restoredApp, "library-search-results-scroll-readiness")
    let searchArtwork = anyElement(restoredApp, "library-search-artwork-probe")
    let expectedMetadataSearch = searchValue(
      query: "mina sol",
      count: 2,
      order: [books[4], books[2]]
    )
    let searchSubmitDeadline = EventDeadline()
    XCTAssertTrue(
      searchFocus.waitForStringValue("unfocused", timeout: searchSubmitDeadline.remaining),
      "Submitting local search must dismiss focus before the result layout is captured"
    )
    try tester.step(
      "metadata-search",
      description: "Local search finds contributor metadata without a network",
      verifications: [
        .valueEquals(
          searchProbe,
          expectedMetadataSearch,
          "Normalized contributor search returns exactly the two matching books in title order"
        ),
        .exists(searchInput, "The local query remains available for immediate refinement"),
        .exists(anyElement(restoredApp, "library-search-summary"), "The result count and active order are visible"),
      ],
      captureReadiness: organizationCaptureReadiness(
        app: restoredApp,
        specification: "At capture, the exact two-book contributor result order and cover-bearing rows are settled on idle search geometry with submitted focus dismissed",
        anchor: searchResultsReadiness
      ) {
        self.hasExactValue(searchProbe, expectedMetadataSearch)
          && self.hasExactValue(searchArtwork, self.artworkValue(self.books))
          && self.hasExactValue(searchFocus, "unfocused")
          && self.hasSettledLayout(
            searchLayoutReadiness,
            containerID: "library-search-layout"
          )
          && self.isSettled(
            searchResultsReadiness,
            containerID: "library-search-results-scroll",
            axis: .vertical
          )
          && self.searchResultsAreFullyVisible(
            [self.bookTitles[4], self.bookTitles[2]],
            app: restoredApp,
            within: searchResultsScroll
          )
      }
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
      ],
      captureReadiness: organizationCaptureReadiness(
        app: restoredApp,
        specification: "At capture, the exact finished/recent order and two cover-bearing results are settled on idle search geometry with sort/filter menus closed",
        anchor: searchResultsReadiness
      ) {
        self.hasExactValue(searchProbe, persistedSearchValue)
          && self.hasExactValue(searchArtwork, self.artworkValue(self.books))
          && self.hasSettledLayout(
            searchLayoutReadiness,
            containerID: "library-search-layout"
          )
          && self.isSettled(
            searchResultsReadiness,
            containerID: "library-search-results-scroll",
            axis: .vertical
          )
          && self.searchResultsAreFullyVisible(
            [self.bookTitles[3], self.bookTitles[2]],
            app: restoredApp,
            within: searchResultsScroll
          )
          && !restoredApp.buttons["search-sort-recently-added"].exists
          && !restoredApp.buttons["search-filter-finished"].exists
      }
    )

    XCTAssertTrue(terminateAndWait(restoredApp))
    let searchRelaunch = try makeApplication(reset: false)
    searchRelaunch.launch()
    searchRelaunch.buttons["open-library-search"].tap()
    let relaunchedProbe = anyElement(searchRelaunch, "library-search-probe")
    try requireValue(relaunchedProbe, persistedSearchValue)
    let relaunchedInput = searchRelaunch.textFields["library-search-input"]
    relaunchedInput.tap()
    relaunchedInput.typeText("No Such Audiobook\n")
    let noMatchValue = searchValue(
      query: "no such audiobook", count: 0, sort: "recentlyAdded",
      direction: "descending", status: "finished", empty: "query", order: []
    )
    let relaunchedFocus = anyElement(searchRelaunch, "library-search-focus-state")
    let relaunchedLayout = anyElement(searchRelaunch, "library-search-layout-readiness")
    let relaunchedArtwork = anyElement(searchRelaunch, "library-search-artwork-probe")
    let emptySearch = anyElement(searchRelaunch, "library-search-empty")
    let clearEmptySearch = searchRelaunch.buttons["Clear Search and Filters"]
    try tester.step(
      "no-search-matches",
      description: "No search matches is distinct from an empty library",
      verifications: [
        .valueEquals(
          relaunchedProbe,
          noMatchValue,
          "The durable sort and filter remain active while the query has no matches"
        ),
        .exists(emptySearch, "A dedicated no-match state is shown"),
        .exists(clearEmptySearch, "The no-match state offers one-tap recovery"),
      ],
      captureReadiness: organizationCaptureReadiness(
        app: searchRelaunch,
        specification: "At capture, the exact durable no-match search state is laid out with submitted focus dismissed and its one-tap recovery fully visible",
        anchor: relaunchedLayout
      ) {
        self.hasExactValue(relaunchedProbe, noMatchValue)
          && self.hasExactValue(relaunchedArtwork, self.artworkValue(self.books))
          && self.hasExactValue(relaunchedFocus, "unfocused")
          && self.hasSettledLayout(
            relaunchedLayout,
            containerID: "library-search-layout"
          )
          && emptySearch.exists
          && clearEmptySearch.isHittable
      }
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
    app.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "identifier == %@ OR label == %@",
          identifier,
          identifier
        )
      )
      .firstMatch
  }

  private func navigateBack(
    _ app: XCUIApplication,
    label: String,
    destination: XCUIElement
  ) {
    let back = app.navigationBars.buttons[label]
    XCTAssertTrue(back.waitForExistence(timeout: 2))
    back.tap()
    XCTAssertTrue(
      destination.waitForExistence(timeout: 2),
      "Expected Back to \(label) to reveal \(destination.identifier)"
    )
  }

  private func verifyNonLibraryRunways(_ app: XCUIApplication) {
    let miniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))

    app.tabBars.buttons["Settings"].tap()
    assertScrollsAboveMiniPlayer(
      app.buttons["settings-diagnostics"], miniPlayer: miniPlayer,
      scrollContainer: anyElement(app, "settings-scroll"),
      readiness: anyElement(app, "settings-scroll-readiness"),
      permitsGeometrySettledFallback: true,
      message: "The final Settings row must scroll above the mini-player"
    )

    revealSettingsRow(
      app.buttons["settings-backup"],
      app: app,
      direction: .towardStart
    )
    app.buttons["settings-backup"].tap()
    assertScrollsAboveMiniPlayer(
      anyElement(app, "backup-automatic-explanation"), miniPlayer: miniPlayer,
      scrollContainer: anyElement(app, "backup-scroll"),
      readiness: anyElement(app, "backup-scroll-readiness"),
      permitsGeometrySettledFallback: false,
      message: "The final Backup content must scroll above the mini-player"
    )
    navigateBack(
      app,
      label: "Settings",
      destination: app.navigationBars["Settings"]
    )

    revealSettingsRow(
      app.buttons["playback-defaults"],
      app: app,
      direction: .towardEnd
    )
    app.buttons["playback-defaults"].tap()
    assertScrollsAboveMiniPlayer(
      anyElement(app, "transport-seek-context"), miniPlayer: miniPlayer,
      scrollContainer: anyElement(app, "transport-preferences-screen"),
      readiness: anyElement(app, "transport-preferences-scroll-readiness"),
      permitsGeometrySettledFallback: true,
      message: "The final Playback Defaults control must scroll above the mini-player"
    )
    navigateBack(
      app,
      label: "Settings",
      destination: app.navigationBars["Settings"]
    )
  }

  private func assertScrollsAboveMiniPlayer(
    _ element: XCUIElement,
    miniPlayer: XCUIElement,
    scrollContainer: XCUIElement,
    readiness: XCUIElement,
    permitsGeometrySettledFallback: Bool,
    message: String
  ) {
    let deadline = EventDeadline()
    XCTAssertTrue(waitForExistence(element, deadline: deadline), message)
    XCTAssertTrue(waitForExistence(scrollContainer, deadline: deadline), message)
    let surface = ScrollSurface(
      container: scrollContainer,
      readiness: readiness,
      containerID: scrollContainer.identifier,
      axis: .vertical,
      permitsGeometrySettledFallback: permitsGeometrySettledFallback
    )
    let reachedClearance = scrollUntil(
      {
        element.isHittable
          && elementIsFullyVisible(
            element,
            within: scrollContainer,
            obscuredBelow: miniPlayer
          )
      },
      on: surface,
      deadline: deadline,
      terminalEndpoint: \.atBottom,
      failureContext: {
        "target=\(element.frame), target-hittable=\(element.isHittable), "
          + "mini-player=\(miniPlayer.frame), scroll=\(scrollContainer.frame)"
      }
    ) {
      upwardDrag(in: scrollContainer, velocity: .fast)
    }
    XCTAssertTrue(reachedClearance, message)
    XCTAssertTrue(element.isHittable, message)
    XCTAssertLessThanOrEqual(element.frame.maxY, miniPlayer.frame.minY - 4, message)
  }

  private func revealSettingsRow(
    _ element: XCUIElement,
    app: XCUIApplication,
    direction: ScrollProbeDirection
  ) {
    let deadline = EventDeadline()
    let container = anyElement(app, "settings-scroll")
    let surface = ScrollSurface(
      container: container,
      readiness: anyElement(app, "settings-scroll-readiness"),
      containerID: "settings-scroll",
      axis: .vertical,
      permitsGeometrySettledFallback: true
    )
    let terminalEndpoint: KeyPath<ScrollReadinessState, Bool> =
      direction == .towardEnd ? \.atBottom : \.atTop
    XCTAssertTrue(waitForExistence(element, deadline: deadline))
    XCTAssertTrue(
      scrollUntil(
        { element.isHittable },
        on: surface,
        deadline: deadline,
        direction: direction,
        terminalEndpoint: terminalEndpoint
      ) {
        if direction == .towardEnd {
          upwardDrag(in: container, velocity: .fast)
        } else {
          downwardDrag(in: container, velocity: .fast)
        }
      },
      "The Settings row \(element.identifier) must be revealed before tapping"
    )
  }

  private func upwardDrag(in element: XCUIElement, velocity: XCUIGestureVelocity) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.72))
      .press(
        forDuration: 0.05,
        thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.28)),
        withVelocity: velocity,
        thenHoldForDuration: 0
      )
  }

  private func downwardDrag(in element: XCUIElement, velocity: XCUIGestureVelocity) {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.28))
      .press(
        forDuration: 0.05,
        thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.72)),
        withVelocity: velocity,
        thenHoldForDuration: 0
      )
  }

  private func fullHeightUpwardDrag(in element: XCUIElement) {
    element.swipeUp(velocity: .fast)
  }

  private func organizationCaptureReadiness(
    app: XCUIApplication,
    specification: String,
    anchor: XCUIElement,
    checkNow: @escaping @MainActor () -> Bool
  ) -> CaptureReadiness {
    CaptureReadiness(specification: specification, anchor: anchor) {
      checkNow()
        && !app.keyboards.firstMatch.exists
        && !app.alerts.firstMatch.exists
        && !app.sheets.firstMatch.exists
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

  private func visibleElements(
    in app: XCUIApplication,
    identifierPrefix: String,
    within container: XCUIElement
  ) -> [XCUIElement] {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix))
      .allElementsBoundByIndex
      .filter { elementIsFullyVisible($0, within: container, requiresHittable: false) }
  }

  private func searchResultsAreFullyVisible(
    _ titles: [String],
    app: XCUIApplication,
    within container: XCUIElement
  ) -> Bool {
    titles.allSatisfy { title in
      elementIsFullyVisible(
        app.staticTexts[title],
        within: container,
        requiresHittable: false
      )
    }
  }

  private func artworkValue(_ identifiers: [String]) -> String {
    "artwork:ready=\(identifiers.joined(separator: ",")):count=\(identifiers.count)"
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
    navigateBack(
      app,
      label: "Library",
      destination: anyElement(app, "library-screen")
    )
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
