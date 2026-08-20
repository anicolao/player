import XCTest

@MainActor
final class MultifileGroupingUITests: XCTestCase {
  private let jobID = "30000000-0000-0000-0000-000000000001"
  private let proposalA = "30000000-0000-0000-0000-000000000010"
  private let proposalB = "30000000-0000-0000-0000-000000000020"
  private let proposalC = "30000000-0000-0000-0000-000000000030"
  private let finalBookID = "30000000-0000-0000-0000-000000000100"
  private let prelude = "30000000-0000-0000-0000-000000000111"
  private let b3 = "30000000-0000-0000-0000-000000000203"
  private let b4 = "30000000-0000-0000-0000-000000000204"

  func testRepairsMessyMultifileGroupingAndCommitsOneBookAtomically() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait

    let app = makeApplication()
    let tester = TestStepHelper(testCase: self)
    tester.setMetadata(
      title: "Messy Unicode files become one intentionally ordered audiobook",
      narrative:
        "As a listener importing a folder and several files, I want to understand Player's grouping guess, repair it, and commit one complete book.",
      fixture: "messy-multifile-unicode",
      additionalPreconditions: [
        "All eight audio files are generated tones with deterministic identifiers and checksums",
        "Acquisition supplies one folder plus four selected loose files through the production selection boundary",
        "Folder names, Unicode filename stems, and numeric components are the only grouping evidence",
        "The source fixture checksum is checked before acquisition and after atomic commit",
      ]
    )

    app.launch()
    app.buttons["add-audiobook"].tap()

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
    let groupingProbe = anyElement(app, "grouping-probe")
    let addToLibrary = app.buttons["add-import-to-library"]
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
          anyElement(app, "grouping-evidence-folder-name"),
          "Folder-name grouping evidence is visible"
        ),
        .exists(
          anyElement(app, "grouping-evidence-filename-stem"),
          "Unicode filename-stem grouping evidence is visible"
        ),
        .exists(
          app.buttons["review-order-button"],
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
      ]
    )

    app.buttons["review-order-button"].tap()
    let orderScreen = anyElement(app, "review-order-screen")
    let orderProbe = anyElement(app, "order-probe")
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
          anyElement(app, "ordering-evidence-natural-numeric"),
          "Natural numeric ordering evidence is visible"
        ),
        .exists(anyElement(app, "order-track-\(prelude)"), "The Unicode prelude is retained"),
        .exists(anyElement(app, "order-track-\(b4)"), "The accented loose file is retained"),
      ]
    )

    app.buttons["order-select-\(b4)"].tap()
    app.buttons["order-move-to-\(proposalA)"].tap()
    try requireValue(
      orderProbe,
      "order|revision|1|a|a1,a2,a10,ap,b4|b|b3,b5,b6"
    )

    app.buttons["order-select-\(prelude)"].tap()
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

    app.buttons["order-select-\(b3)"].tap()
    app.buttons["split-selected-tracks"].tap()
    try requireValue(
      orderProbe,
      "order|revision|5|a|ap,a1,a2,a10,b4|b|b5,b6|c|b3"
    )

    anyElement(app, "order-proposal-\(proposalB)").tap()
    anyElement(app, "order-proposal-\(proposalC)").tap()
    app.buttons["merge-proposals"].tap()
    try requireValue(
      orderProbe,
      "order|revision|6|a|ap,a1,a2,a10,b4|b|b5,b6,b3"
    )

    anyElement(app, "order-proposal-\(proposalA)").tap()
    anyElement(app, "order-proposal-\(proposalB)").tap()
    app.buttons["merge-proposals"].tap()

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
        .exists(app.buttons["save-order"], "The valid corrected order can be saved"),
      ]
    )

    app.buttons["save-order"].tap()
    try requireValue(
      reviewImport,
      "proposal:ready:1-book:8-tracks:0-warnings:revision-7"
    )
    try requireValue(addToLibrary, "ready:enabled")
    XCTAssertTrue(addToLibrary.isEnabled)
    let commitProbe = anyElement(app, "commit-probe")
    try requireValue(
      commitProbe,
      "transaction:pending:books=0:assets=0:staging=8:source-unchanged=true"
    )
    addToLibrary.tap()

    let library = anyElement(app, "library-screen")
    let committedBook = anyElement(app, "recent-book-\(finalBookID)")
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
          commitProbe,
          "transaction:committed:books=1:assets=8:staging=0:source-unchanged=true:rollback=available",
          "All eight assets committed together, staging cleared, and rollback remains available"
        ),
      ]
    )

    tester.generateDocs()
  }

  private func makeApplication() -> XCUIApplication {
    let app = XCUIApplication()
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

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    let deadline = Date().addingTimeInterval(2)
    var latest: String?
    repeat {
      if element.exists {
        latest = element.value as? String
        if latest == expected { return }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline

    XCTFail("The multifile journey expected \(expected), latest=\(latest ?? "nil")")
    throw MultifileGroupingTestError.semanticStateUnavailable
  }
}

private enum MultifileGroupingTestError: Error {
  case semanticStateUnavailable
}
