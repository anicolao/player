import XCTest

@MainActor
final class MultifileGroupingUITests: PlayerUITestCase {
  private let jobID = "30000000-0000-0000-0000-000000000001"
  private let proposalA = "30000000-0000-0000-0000-000000000010"
  private let proposalB = "30000000-0000-0000-0000-000000000020"
  private let proposalC = "30000000-0000-0000-0000-000000000030"
  private let finalBookID = "30000000-0000-0000-0000-000000000100"
  private let prelude = "30000000-0000-0000-0000-000000000111"
  private let b3 = "30000000-0000-0000-0000-000000000203"
  private let b4 = "30000000-0000-0000-0000-000000000204"

  func testRepairsMessyMultifileGroupingAndCommitsExactlyOneBook() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = makeApplication()
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "Messy Unicode files become one intentionally ordered audiobook",
      narrative:
        "As a listener importing a folder and several files, I want to understand Bookshelf's grouping guess, repair it, and commit one complete book.",
      fixture: "messy-multifile-unicode",
      additionalPreconditions: [
        "All eight audio files are generated tones with deterministic identifiers and checksums",
        "Acquisition supplies one folder plus four selected loose files through the production selection boundary",
        "Folder names, Unicode filename stems, and numeric components are the only grouping evidence",
        "The source fixture checksum is checked before acquisition and after atomic commit",
      ]
    )

    app.launch()
    app.buttons["choose-from-files-empty-library"].tap()

    let acquisitionProbe = anyElement(app, "acquisition-probe")
    try requireValue(
      acquisitionProbe,
      "acquisition:folder-plus-multiselect:5-selections:8-files:source-unchanged"
    )
    let inbox = anyElement(app, "inbox-screen")
    try requireValue(inbox, "import:1-review:1-processing:0")
    app.tabBars.buttons["Inbox"].tap()
    app.buttons["review-import-job-\(jobID)"].tap()

    let reviewImport = anyElement(app, "review-import-screen")
    let reviewScroll = anyElement(app, "review-import-scroll")
    let reviewReadiness = anyElement(app, "review-import-scroll-readiness")
    let groupingProbe = anyElement(app, "grouping-probe")
    let addToLibrary = app.buttons["add-import-to-library"]
    let folderEvidence = anyElement(app, "grouping-evidence-folder-name")
    let filenameEvidence = anyElement(app, "grouping-evidence-filename-stem")
    let reviewOrder = app.buttons["review-order-button"]
    let reviewArtwork = reviewImport.descendants(matching: .any)["placeholder-artwork"]
    try tester.step(
      "explainable-grouping",
      description: "Review Import explains why the selection became two candidate books",
      verifications: [
        .valueEquals(
          reviewImport,
          "proposal:needs-review:2-books:8-tracks:2-warnings",
          "The complete eight-file selection is present in two warning-bearing candidates"
        ),
        .valueEquals(
          groupingProbe,
          "groups|2|tracks|8|folder-name+filename-stem|natural-numeric|review",
          "The proposal reports its folder, filename, and numeric-order evidence"
        ),
        .exists(
          folderEvidence,
          "Folder-name grouping evidence is visible"
        ),
        .exists(
          filenameEvidence,
          "Unicode filename-stem grouping evidence is visible"
        ),
        .exists(
          reviewOrder,
          "The ordering problem links directly to Review Order"
        ),
        .valueEquals(
          addToLibrary,
          "blocked:2-warnings:disabled",
          "The pinned Add to Library action explains why it is blocked"
        ),
        StepVerification(specification: "The blocked primary action remains visibly pinned") {
          addToLibrary.exists
            && !addToLibrary.isEnabled
            && app.frame.intersects(addToLibrary.frame)
        },
      ],
      captureReadiness: CaptureReadiness(
        specification:
          "At capture, the exact two-book grouping proposal is settled at the top with its evidence, placeholder artwork, and blocked pinned action fully rendered",
        anchor: reviewReadiness
      ) {
        guard let state = ScrollReadinessState(reviewReadiness.value) else { return false }
        return state.containerID == "review-import-scroll"
          && state.axis == .vertical
          && state.isIdle
          && state.atTop
          && self.hasExactValue(
            reviewImport,
            "proposal:needs-review:2-books:8-tracks:2-warnings"
          )
          && self.hasExactValue(
            groupingProbe,
            "groups|2|tracks|8|folder-name+filename-stem|natural-numeric|review"
          )
          && self.hasExactValue(addToLibrary, "blocked:2-warnings:disabled")
          && !addToLibrary.isEnabled
          && elementIsFullyVisible(
            reviewArtwork,
            within: reviewScroll,
            requiresHittable: false
          )
          && elementIsFullyVisible(folderEvidence, within: reviewScroll, requiresHittable: false)
          && elementIsFullyVisible(filenameEvidence, within: reviewScroll, requiresHittable: false)
          && elementIsFullyVisible(reviewOrder, within: reviewScroll)
          && elementIsFullyVisible(addToLibrary, within: app, requiresHittable: false)
          && self.hasNoTransientUI(app)
      }
    )

    let orderScreen = anyElement(app, "review-order-screen")
    let orderProbe = anyElement(app, "order-probe")
    try tapPhysicalAction(reviewOrder, until: orderProbe, in: app)
    let orderingEvidence = anyElement(app, "ordering-evidence-natural-numeric")
    try requireValue(
      orderProbe,
      "order|revision|0|a|a1,a2,a10,ap|b|b3,b4,b5,b6"
    )
    XCTAssertEqual(
      app.descendants(matching: .any)
        .matching(identifier: "ordering-evidence-natural-numeric").count,
      1,
      "Natural-order evidence must be one unambiguous accessibility element"
    )
    let preludeTrack = anyElement(app, "order-track-\(prelude)")
    let lastTrack = anyElement(app, "order-track-\(b3)")
    let saveOrder = app.buttons["save-order"]
    let orderScroll = app.collectionViews.firstMatch
    let orderActionBarTop = app.buttons["order-proposal-\(proposalA)"]
    try tester.step(
      "natural-order-review",
      description: "Review Order preserves natural numeric order and every original file",
      verifications: [
        .valueEquals(
          orderScreen,
          "order:needs-review:2-books:8-tracks:revision-0",
          "Two candidates and all eight tracks require review"
        ),
        .valueEquals(
          orderProbe,
          "order|revision|0|a|a1,a2,a10,ap|b|b3,b4,b5,b6",
          "Numeric filename components place part 2 before part 10"
        ),
        .exists(
          orderingEvidence,
          "Natural numeric ordering evidence is visible"
        ),
        .exists(preludeTrack, "The Unicode prelude is retained"),
        .exists(anyElement(app, "order-track-\(b4)"), "The accented loose file is retained"),
      ],
      captureReadiness: CaptureReadiness(
        specification:
          "At capture, the exact initial natural ordering and visible first proposal rows are rendered together with the pinned action and no transient UI",
        anchor: orderProbe
      ) {
        self.hasExactValue(
          orderScreen,
          "order:needs-review:2-books:8-tracks:revision-0"
        )
          && self.hasExactValue(
            orderProbe,
            "order|revision|0|a|a1,a2,a10,ap|b|b3,b4,b5,b6"
          )
          && elementIsFullyVisible(orderingEvidence, within: orderScreen, requiresHittable: false)
          && elementIsFullyVisible(preludeTrack, within: orderScreen, requiresHittable: false)
          && elementIsFullyVisible(saveOrder, within: orderScreen)
          && self.hasNoTransientUI(app)
      }
    )

    let selectB4 = app.buttons["order-select-\(b4)"]
    try selectTrack(
      selectB4,
      in: app,
      within: orderScroll,
      obscuredBelow: orderActionBarTop,
      direction: .towardEnd
    )
    app.buttons["order-move-to-\(proposalA)"].tap()
    try requireValue(
      orderProbe,
      "order|revision|1|a|a1,a2,a10,ap,b4|b|b3,b5,b6"
    )

    let selectPrelude = app.buttons["order-select-\(prelude)"]
    try selectTrack(
      selectPrelude,
      in: app,
      within: orderScroll,
      obscuredBelow: orderActionBarTop,
      direction: .towardStart
    )
    app.buttons["order-move-up-\(prelude)"].tap()
    try requireValue(
      orderProbe,
      "order|revision|2|a|a1,a2,ap,a10,b4|b|b3,b5,b6"
    )
    app.buttons["order-move-up-\(prelude)"].tap()
    try requireValue(
      orderProbe,
      "order|revision|3|a|a1,ap,a2,a10,b4|b|b3,b5,b6"
    )
    app.buttons["order-move-up-\(prelude)"].tap()
    try requireValue(
      orderProbe,
      "order|revision|4|a|ap,a1,a2,a10,b4|b|b3,b5,b6"
    )

    let selectB3 = app.buttons["order-select-\(b3)"]
    try selectTrack(
      selectB3,
      in: app,
      within: orderScroll,
      obscuredBelow: orderActionBarTop,
      direction: .towardEnd
    )
    app.buttons["split-selected-tracks"].tap()
    try requireValue(
      orderProbe,
      "order|revision|5|a|ap,a1,a2,a10,b4|b|b5,b6|c|b3"
    )

    anyElement(app, "order-proposal-\(proposalB)").tap()
    anyElement(app, "order-proposal-\(proposalC)").tap()
    let mergeProposals = app.buttons["merge-proposals"]
    try requireExistence(mergeProposals)
    mergeProposals.tap()
    try requireValue(
      orderProbe,
      "order|revision|6|a|ap,a1,a2,a10,b4|b|b5,b6,b3"
    )

    anyElement(app, "order-proposal-\(proposalA)").tap()
    anyElement(app, "order-proposal-\(proposalB)").tap()
    try requireExistence(mergeProposals)
    mergeProposals.tap()

    try tester.step(
      "corrected-one-book",
      description: "Move, reorder, split, and merge corrections produce one valid book",
      verifications: [
        .valueEquals(
          orderScreen,
          "order:valid:1-book:8-tracks:revision-7",
          "The corrected proposal is one valid eight-track book"
        ),
        .valueEquals(
          orderProbe,
          "order|revision|7|a|ap,a1,a2,a10,b4,b5,b6,b3",
          "The editor preserves the listener's complete curated order"
        ),
        .exists(saveOrder, "The valid corrected order can be saved"),
      ],
      captureReadiness: CaptureReadiness(
        specification:
          "At capture, the exact corrected one-book order, its first and last tracks, and enabled pinned save action are rendered atomically with no transient UI",
        anchor: orderProbe
      ) {
        self.hasExactValue(orderScreen, "order:valid:1-book:8-tracks:revision-7")
          && self.hasExactValue(
            orderProbe,
            "order|revision|7|a|ap,a1,a2,a10,b4,b5,b6,b3"
          )
          && saveOrder.isEnabled
          && elementIsFullyVisible(preludeTrack, within: orderScreen, requiresHittable: false)
          && elementIsFullyVisible(lastTrack, within: orderScreen, requiresHittable: false)
          && elementIsFullyVisible(saveOrder, within: orderScreen)
          && self.hasNoTransientUI(app)
      }
    )

    app.buttons["save-order"].tap()
    try requireValue(
      anyElement(app, "review-import-screen"),
      "proposal:ready:1-book:8-tracks:0-warnings:revision-7"
    )
    let readyAddToLibrary = app.buttons["add-import-to-library"]
    try requireValue(readyAddToLibrary, "ready:enabled")
    XCTAssertTrue(readyAddToLibrary.isEnabled)
    let commitProbe = anyElement(app, "commit-probe")
    try requireValue(
      commitProbe,
      "transaction:pending:books=0:assets=0:staging-records=8:staging-files=8:source-unchanged=true"
    )
    readyAddToLibrary.tap()

    let library = anyElement(app, "library-screen")
    let committedBook = anyElement(app, "recent-book-\(finalBookID)")
    let libraryScrollReadiness = anyElement(app, "library-root-scroll-readiness")
    let recentShelf = anyElement(app, "library-home-recent-shelf-scroll")
    let recentShelfReadiness = anyElement(app, "library-home-recent-shelf-scroll-readiness")
    let artworkProbe = anyElement(app, "library-artwork-probe")
    let committedProbe = anyElement(app, "commit-probe")
    let committedEvidence =
      "transaction:committed:books=1:assets=8:staging-files=0:managed-files=8:managed-file-set=exact:managed-paths=exact:managed-presence=exact:managed-bytes=exact:managed-checksums=exact:source-unchanged=true"
    try tester.step(
      "atomic-commit",
      description: "The corrected selection appears atomically as one complete library book",
      verifications: [
        .valueEquals(
          library,
          "ready:library-1-books",
          "Exactly one book appears after the transaction commits"
        ),
        .exists(committedBook, "The populated Library exposes the stable corrected book"),
        .valueEquals(
          committedProbe,
          committedEvidence,
          "All eight exact managed files exist with matching paths, sizes, and checksums after staging is cleared"
        ),
      ],
      captureReadiness: CaptureReadiness(
        specification:
          "At capture, the exact atomic commit is visible as one settled recent shelf card with deterministic placeholder artwork and no transient UI",
        anchor: recentShelfReadiness
      ) {
        guard
          let libraryState = ScrollReadinessState(libraryScrollReadiness.value),
          let shelfState = ScrollReadinessState(recentShelfReadiness.value)
        else { return false }
        return libraryState.containerID == "library-root-scroll"
          && libraryState.axis == .vertical
          && libraryState.isIdle
          && libraryState.atTop
          && shelfState.containerID == "library-home-recent-shelf-scroll"
          && shelfState.axis == .horizontal
          && shelfState.isIdle
          && shelfState.atLeft
          && self.hasExactValue(library, "ready:library-1-books")
          && self.hasExactValue(
            committedProbe,
            committedEvidence
          )
          && self.hasExactValue(artworkProbe, "artwork:ready=:count=0")
          && elementIsFullyVisible(committedBook, within: recentShelf)
          && self.hasNoTransientUI(app)
      }
    )

    tester.generateDocs()
  }

  private func makeApplication() -> XCUIApplication {
    let app = bookshelfApplication()
    app.launchArguments = [
      "-e2e", "-e2e-reset",
      "-e2e-fixture", "messy-multifile-unicode",
      "-e2e-acquisition", "SyntheticMessyMultifile",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func hasExactValue(_ element: XCUIElement, _ expected: String) -> Bool {
    element.exists && element.value.map(String.init(describing:)) == expected
  }

  private func hasNoTransientUI(_ app: XCUIApplication) -> Bool {
    !app.keyboards.firstMatch.exists
      && !app.alerts.firstMatch.exists
      && !app.sheets.firstMatch.exists
  }

  private func tapPhysicalAction(
    _ action: XCUIElement,
    until destination: XCUIElement,
    in app: XCUIApplication
  ) throws {
    if destination.exists { return }
    guard action.exists, action.isEnabled else {
      XCTFail("The multifile journey expected its enabled action or semantic destination")
      throw MultifileGroupingTestError.semanticStateUnavailable
    }
    let actionFrame = action.frame
    let appFrame = app.frame
    guard actionFrame.width >= 44,
      actionFrame.height >= 44,
      !appFrame.isEmpty,
      appFrame.contains(actionFrame)
    else {
      XCTFail("The multifile journey expected a visible 44-point action target")
      throw MultifileGroupingTestError.semanticStateUnavailable
    }
    let coordinate = app.coordinate(
      withNormalizedOffset: CGVector(
        dx: (actionFrame.midX - appFrame.minX) / appFrame.width,
        dy: (actionFrame.midY - appFrame.minY) / appFrame.height
      )
    )

    // Frame discovery and physical synthesis are not product-state waits. Give
    // the semantic receipt its own two-second event deadline only after the
    // first touch has completed, and redeliver only while the exact source
    // action remains unchanged.
    var deliveryDeadline: EventDeadline?
    repeat {
      if let deliveryDeadline {
        if destination.exists { return }
        guard action.exists, action.isEnabled, action.frame == actionFrame else {
          if destination.waitForExistence(timeout: deliveryDeadline.remaining) { return }
          XCTFail("The multifile journey lost its action before the semantic destination appeared")
          throw MultifileGroupingTestError.semanticStateUnavailable
        }
        if deliveryDeadline.remaining <= 0 { break }
      }
      guard performPhysicalInteractionWithoutPostEventQuiescence(
        in: app,
        { coordinate.tap() }
      ) else {
        XCTFail("The pinned XCTest runtime did not expose bounded physical synthesis")
        throw MultifileGroupingTestError.semanticStateUnavailable
      }
      if deliveryDeadline == nil { deliveryDeadline = EventDeadline() }
      guard let deliveryDeadline else {
        XCTFail("The multifile journey could not establish its delivery deadline")
        throw MultifileGroupingTestError.semanticStateUnavailable
      }
      if destination.waitForExistence(timeout: min(0.25, deliveryDeadline.remaining)) {
        return
      }
      if !action.exists || !action.isEnabled || action.frame != actionFrame {
        if destination.waitForExistence(timeout: deliveryDeadline.remaining) { return }
        XCTFail("The multifile journey expected its enabled action or semantic destination")
        throw MultifileGroupingTestError.semanticStateUnavailable
      }
    } while (deliveryDeadline?.remaining ?? 0) > 0

    XCTFail("The multifile action did not reveal its semantic destination")
    throw MultifileGroupingTestError.semanticStateUnavailable
  }

  private func selectTrack(
    _ action: XCUIElement,
    in app: XCUIApplication,
    within container: XCUIElement,
    obscuredBelow obstruction: XCUIElement,
    direction: ScrollProbeDirection
  ) throws {
    guard container.waitForExistence(timeout: 2), obstruction.waitForExistence(timeout: 2) else {
      XCTFail("The multifile journey expected the order list and pinned action boundary")
      throw MultifileGroupingTestError.semanticStateUnavailable
    }
    var revealed = trackActionIsUnobscured(action, within: container, below: obstruction)
    var revealDeadline: EventDeadline?
    let revealPredicate = NSPredicate { _, _ in
      self.trackActionIsUnobscured(action, within: container, below: obstruction)
    }
    while !revealed, revealDeadline?.remaining ?? 2 > 0 {
      guard performPhysicalInteractionWithoutPostEventQuiescence(
        in: app,
        { self.scrollOrder(container, direction: direction) }
      ) else {
        XCTFail("The pinned XCTest runtime did not expose bounded physical synthesis")
        throw MultifileGroupingTestError.semanticStateUnavailable
      }
      if revealDeadline == nil { revealDeadline = EventDeadline() }
      guard let revealDeadline else { break }
      revealed = waitForPredicate(
        revealPredicate,
        on: action,
        timeout: min(0.35, revealDeadline.remaining)
      )
    }
    guard revealed else {
      XCTFail(
        "The multifile journey could not reveal its exact track action; "
          + "track=\(action.identifier), frame=\(action.frame), obstruction=\(obstruction.frame)"
      )
      throw MultifileGroupingTestError.semanticStateUnavailable
    }
    guard action.exists, action.isEnabled, action.label == "Select track" else {
      XCTFail("The multifile journey expected one unselected enabled track action")
      throw MultifileGroupingTestError.semanticStateUnavailable
    }
    let actionFrame = action.frame
    let appFrame = app.frame
    guard !actionFrame.isEmpty,
      !appFrame.isEmpty,
      appFrame.contains(actionFrame)
    else {
      XCTFail("The multifile journey expected a fully visible track action")
      throw MultifileGroupingTestError.semanticStateUnavailable
    }
    let coordinate = app.coordinate(
      withNormalizedOffset: CGVector(
        dx: (actionFrame.midX - appFrame.minX) / appFrame.width,
        dy: (actionFrame.midY - appFrame.minY) / appFrame.height
      )
    )
    guard performPhysicalInteractionWithoutPostEventQuiescence(
      in: app,
      { coordinate.tap() }
    ) else {
      XCTFail("The pinned XCTest runtime did not expose bounded physical synthesis")
      throw MultifileGroupingTestError.semanticStateUnavailable
    }
    let selectionDeadline = EventDeadline()
    let selected = NSPredicate(format: "exists == true AND label == %@", "Deselect track")
    guard waitForPredicate(selected, on: action, timeout: selectionDeadline.remaining) else {
      XCTFail(
        "The multifile journey expected label Deselect track, latest=\(action.label)"
      )
      throw MultifileGroupingTestError.semanticStateUnavailable
    }
  }

  private func trackActionIsUnobscured(
    _ action: XCUIElement,
    within container: XCUIElement,
    below obstruction: XCUIElement
  ) -> Bool {
    guard action.exists, action.isEnabled, action.label == "Select track",
      container.exists, obstruction.exists
    else { return false }
    let frame = action.frame
    let viewport = container.frame
    let unobscuredBottom = min(viewport.maxY, obstruction.frame.minY)
    return !frame.isEmpty
      && frame.minY >= viewport.minY
      && frame.maxY <= unobscuredBottom
  }

  private func scrollOrder(_ container: XCUIElement, direction: ScrollProbeDirection) {
    let startY: CGFloat = direction == .towardEnd ? 0.72 : 0.28
    let endY: CGFloat = direction == .towardEnd ? 0.28 : 0.72
    container.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: startY))
      .press(
        forDuration: 0.05,
        thenDragTo: container.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: endY)),
        withVelocity: .default,
        thenHoldForDuration: 0
      )
  }

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    guard element.waitForStringValue(expected, timeout: 2) else {
      XCTFail(
        "The multifile journey expected \(expected), latest=\(String(describing: element.value))"
      )
      throw MultifileGroupingTestError.semanticStateUnavailable
    }
  }

  private func requireExistence(_ element: XCUIElement) throws {
    guard element.waitForExistence(timeout: 2) else {
      XCTFail("The multifile journey expected \(element.identifier) to exist")
      throw MultifileGroupingTestError.semanticStateUnavailable
    }
  }
}

private enum MultifileGroupingTestError: Error {
  case semanticStateUnavailable
}
