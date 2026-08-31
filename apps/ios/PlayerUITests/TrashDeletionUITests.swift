import XCTest

@MainActor
final class TrashDeletionUITests: PlayerUITestCase {
  private let bookID = "90000000-0000-0000-0000-000000000001"
  private let siblingBookID = "90000000-0000-0000-0000-000000000005"
  private let siblingTransactionID = "90000000-0000-0000-0000-000000000601"
  private let transactionID = "90000000-0000-0000-0000-000000000602"

  func testPermanentlyDeletesOnlyTheConfirmedCurrentBook() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let audioByteCount = try fixtureData(resource: "library-book-audio", extension: "m4b").count
    let app = try makeApplication(reset: true)

    app.launch()
    let miniPlayer = app.otherElements["mini-player"]
    XCTAssertTrue(waitForExistence(miniPlayer, deadline: EventDeadline()))
    app.buttons["browse-all-books"].tap()
    app.descendants(matching: .any)["all-books-book-\(bookID)"].tap()
    XCTAssertTrue(waitForExistence(
      app.descendants(matching: .any)["book-detail-screen"], deadline: EventDeadline()
    ))
    app.buttons["move-book-to-trash-toolbar"].tap()
    tapPhysicalConfirmation(
      app.sheets["Move this audiobook to Trash?"],
      identifier: "remove-book-to-trash"
    )
    try requireValue(
      app.descendants(matching: .any)["trash-removal-probe"],
      "trash-removal:target-book-present=false:transaction=recoverable:current=none:playback=unloaded:loaded=none"
    )
    XCTAssertFalse(miniPlayer.exists)

    let libraryBack = app.navigationBars.buttons["Library"]
    XCTAssertTrue(waitForExistence(libraryBack, deadline: EventDeadline()))
    libraryBack.tap()
    app.tabBars.buttons["Settings"].tap()
    let settingsTrash = app.buttons["settings-trash"]
    XCTAssertTrue(waitForExistence(settingsTrash, deadline: EventDeadline()))
    settingsTrash.tap()

    let trash = app.descendants(matching: .any)["trash-probe"]
    let purge = app.descendants(matching: .any)["trash-purge-probe"]
    let restore = app.buttons["restore-trash-\(transactionID)"]
    let siblingRestore = app.buttons["restore-trash-\(siblingTransactionID)"]
    let delete = app.buttons["delete-trash-\(transactionID)"]
    let row = app.descendants(matching: .any)["trash-book-\(bookID)"]
    let playback = app.descendants(matching: .any)["trash-playback-probe"]
    try requirePurgeEvidence(
      purge,
      status: "recoverable",
      targetFileCount: 1,
      trashTransactionCount: 2,
      audioByteCount: audioByteCount
    )
    try requireValue(
      trash,
      "trash:transactions=2:books=\(siblingBookID),\(bookID):assets=2:bytes=\(audioByteCount * 2):restorable=true:managed-checksum-preserved=true"
    )
    try requireValue(
      playback,
      "trash-playback:current=none:status=unloaded:loaded=none:position=none"
    )
    XCTAssertTrue(waitForExistence(row, deadline: EventDeadline()))
    XCTAssertTrue(waitForExistence(restore, deadline: EventDeadline()))
    XCTAssertTrue(waitForExistence(delete, deadline: EventDeadline()))
    XCTAssertTrue(waitForExistence(siblingRestore, deadline: EventDeadline()))
    XCTAssertFalse(miniPlayer.exists)
    XCTAssertTrue(app.sheets.count == 0 && app.alerts.count == 0)
    let evidenceBeforeCancellation = try stringValue(of: purge)

    delete.tap()
    let cancellationSheet = app.sheets["Delete this audiobook forever?"]
    XCTAssertTrue(waitForExistence(cancellationSheet, deadline: EventDeadline()))
    let cancel = app.otherElements["PopoverDismissRegion"]
    XCTAssertTrue(waitForExistence(cancel, deadline: EventDeadline()))
    cancel.tap()
    XCTAssertTrue(waitForNoElements(app.sheets, deadline: EventDeadline()))
    try requireValue(purge, evidenceBeforeCancellation)
    XCTAssertTrue(restore.exists, "Cancelling permanent deletion must preserve Restore")

    delete.tap()
    tapPhysicalConfirmation(
      app.sheets["Delete this audiobook forever?"],
      identifier: "confirm-delete-trash"
    )
    try requirePurgeEvidence(
      purge,
      status: "purged",
      targetFileCount: 0,
      trashTransactionCount: 1,
      audioByteCount: audioByteCount
    )
    try requireValue(
      trash,
      "trash:transactions=1:books=\(siblingBookID):assets=1:bytes=\(audioByteCount):restorable=true:managed-checksum-preserved=true"
    )
    XCTAssertTrue(waitForNoElements(
      app.buttons.matching(identifier: "restore-trash-\(transactionID)"),
      deadline: EventDeadline()
    ))
    XCTAssertFalse(row.exists)

    XCTAssertTrue(waitForExistence(
      app.descendants(matching: .any)["trash-book-\(siblingBookID)"],
      deadline: EventDeadline()
    ))
    XCTAssertTrue(waitForExistence(siblingRestore, deadline: EventDeadline()))
    try requireValue(
      playback,
      "trash-playback:current=none:status=unloaded:loaded=none:position=none"
    )
    XCTAssertFalse(miniPlayer.exists)
    XCTAssertTrue(app.sheets.count == 0 && app.alerts.count == 0)

    XCTAssertTrue(terminateAndWait(app))
    let relaunched = try makeApplication(reset: false)
    relaunched.launchArguments.append(contentsOf: [
      "-e2e-start-section", "settings",
      "-e2e-start-settings-route", "trash",
    ])
    relaunched.launch()
    let relaunchedPurge = relaunched.descendants(matching: .any)["trash-purge-probe"]
    try requirePurgeEvidence(
      relaunchedPurge,
      status: "purged",
      targetFileCount: 0,
      trashTransactionCount: 1,
      audioByteCount: audioByteCount
    )
    XCTAssertTrue(waitForExistence(
      relaunched.descendants(matching: .any)["trash-book-\(siblingBookID)"],
      deadline: EventDeadline()
    ))
    XCTAssertTrue(waitForExistence(
      relaunched.buttons["restore-trash-\(siblingTransactionID)"],
      deadline: EventDeadline()
    ))
    XCTAssertFalse(relaunched.buttons["restore-trash-\(transactionID)"].exists)
    XCTAssertFalse(relaunched.otherElements["mini-player"].exists)
    relaunched.tabBars.buttons["Library"].tap()
    try requireValue(
      relaunched.descendants(matching: .any)["library-organizer-probe"],
      "library:books=3:continue=90000000-0000-0000-0000-000000000003:up-next=90000000-0000-0000-0000-000000000002,90000000-0000-0000-0000-000000000003:finished=90000000-0000-0000-0000-000000000004:collections=0:trash=1:view=shelf:current=none:position=0"
    )
    XCTAssertFalse(relaunched.otherElements["mini-player"].exists)

    relaunched.tabBars.buttons["Add"].tap()
    let receiver = relaunched.descendants(matching: .any)["computer-receiver-screen"]
    XCTAssertTrue(waitForExistence(receiver, deadline: EventDeadline()))
    let chooseFiles = relaunched.buttons["choose-from-files-computer-receiver"]
    XCTAssertTrue(waitForExistence(chooseFiles, deadline: EventDeadline()))
    chooseFiles.tap()
    let reviewJobs = relaunched.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "review-import-job-")
    )
    XCTAssertTrue(waitForSingleElement(reviewJobs))
    reviewJobs.element(boundBy: 0).tap()
    let reviewScreen = relaunched.descendants(matching: .any)["review-import-screen"]
    try requireValue(reviewScreen, "proposal:ready:1-book:1-tracks:0-warnings")
    let addToLibrary = relaunched.buttons["add-import-to-library"]
    XCTAssertTrue(waitForExistence(addToLibrary, deadline: EventDeadline()))
    addToLibrary.tap()
    try requireValue(
      relaunched.descendants(matching: .any)["library-screen"],
      "ready:library-4-books"
    )
    try requireValue(
      relaunched.descendants(matching: .any)["commit-probe"],
      "transaction:committed:books=4:assets=4:staging-files=0:managed-files=4:managed-file-set=exact:managed-paths=exact:managed-presence=exact:managed-bytes=exact:managed-checksums=exact:source-unchanged=true"
    )
  }

  private func requirePurgeEvidence(
    _ element: XCUIElement,
    status: String,
    targetFileCount: Int,
    trashTransactionCount: Int,
    audioByteCount: Int
  ) throws {
    let deadline = EventDeadline()
    func matches() -> Bool {
      guard let value = element.value.map(String.init(describing:)),
        let evidence = PurgeEvidence(value)
      else { return false }
      return evidence.matches(
        status: status,
        targetFileCount: targetFileCount,
        trashTransactionCount: trashTransactionCount,
        audioByteCount: audioByteCount
      )
    }
    if matches() { return }
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in matches() },
      object: element
    )
    _ = XCTWaiter.wait(for: [expectation], timeout: deadline.remaining)
    guard matches() else {
      XCTFail("Permanent-deletion evidence did not settle: \(String(describing: element.value))")
      throw TrashDeletionTestError.semanticStateUnavailable
    }
  }

  private func waitForSingleElement(_ query: XCUIElementQuery) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in query.count == 1 },
      object: nil
    )
    _ = XCTWaiter.wait(for: [expectation], timeout: EventDeadline().remaining)
    return query.count == 1
  }

  private func tapPhysicalConfirmation(_ sheet: XCUIElement, identifier: String) {
    XCTAssertTrue(waitForExistence(sheet, deadline: EventDeadline()))
    let matches = sheet.buttons.matching(identifier: identifier).allElementsBoundByIndex
    XCTAssertFalse(matches.isEmpty)
    guard let action = matches.first(where: { $0.isEnabled && $0.isHittable }) else {
      return XCTFail("The confirmation must expose one interactable physical action")
    }
    XCTAssertTrue(matches.allSatisfy {
      $0.identifier == action.identifier && $0.label == action.label && $0.frame == action.frame
    })
    action.tap()
  }

  private func hasValue(_ element: XCUIElement, _ expected: String) -> Bool {
    element.exists && element.value.map(String.init(describing:)) == expected
  }

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    guard element.waitForStringValue(expected, timeout: EventDeadline().remaining) else {
      XCTFail("Expected \(expected); actual=\(String(describing: element.value))")
      throw TrashDeletionTestError.semanticStateUnavailable
    }
  }

  private func stringValue(of element: XCUIElement) throws -> String {
    guard element.exists, let value = element.value.map(String.init(describing:)) else {
      XCTFail("The semantic probe had no string value")
      throw TrashDeletionTestError.semanticStateUnavailable
    }
    return value
  }

  private func makeApplication(reset: Bool) throws -> XCUIApplication {
    let app = bookshelfApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "synthetic-permanent-trash",
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
}

private enum TrashDeletionTestError: Error {
  case semanticStateUnavailable
}

private struct PurgeEvidence {
  private static let requiredKeys: Set<String> = [
    "transaction", "target-files", "target-bytes", "target-checksum-preserved",
    "target-manifest-agrees",
    "sibling-transaction", "sibling-trash-files", "sibling-trash-bytes",
    "sibling-manifest-agrees", "sibling-checksum-preserved", "other-managed-files",
    "other-managed-bytes", "other-checksums-preserved", "managed-summary-files",
    "managed-summary-bytes", "managed-disk-files", "managed-disk-bytes",
    "trash-summary-files", "trash-summary-bytes", "trash-disk-files",
    "trash-disk-bytes", "storage-summary-matches-disk", "pending-deletion-files",
    "expected-file-bytes", "source-checksum-preserved",
  ]

  private let fields: [String: String]

  init?(_ value: String) {
    let tokens = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard tokens.first == "purge" else { return nil }
    var parsed: [String: String] = [:]
    for token in tokens.dropFirst() {
      let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
      let key = String(pair[0])
      guard parsed.updateValue(String(pair[1]), forKey: key) == nil else { return nil }
    }
    guard Set(parsed.keys) == Self.requiredKeys else { return nil }
    fields = parsed
  }

  func matches(
    status: String,
    targetFileCount: Int,
    trashTransactionCount: Int,
    audioByteCount: Int
  ) -> Bool {
    let otherManagedCount = 3
    let otherManagedBytes = otherManagedCount * audioByteCount
    guard fields["transaction"] == status,
      integer("target-files") == targetFileCount,
      integer("target-bytes") == targetFileCount * audioByteCount,
      fields["target-checksum-preserved"] == "true",
      fields["target-manifest-agrees"] == "true",
      fields["sibling-transaction"] == "recoverable",
      integer("sibling-trash-files") == 1,
      integer("sibling-trash-bytes") == audioByteCount,
      fields["sibling-manifest-agrees"] == "true",
      fields["sibling-checksum-preserved"] == "true",
      integer("other-managed-files") == otherManagedCount,
      integer("other-managed-bytes") == otherManagedBytes,
      fields["other-checksums-preserved"] == "true",
      integer("managed-summary-files") == otherManagedCount,
      integer("managed-summary-bytes") == otherManagedBytes,
      integer("managed-disk-files") == otherManagedCount,
      integer("managed-disk-bytes") == otherManagedBytes,
      integer("trash-summary-files") == trashTransactionCount * 2,
      integer("trash-disk-files") == trashTransactionCount * 2,
      let trashSummaryBytes = integer("trash-summary-bytes"),
      trashSummaryBytes == integer("trash-disk-bytes"),
      trashSummaryBytes > trashTransactionCount * audioByteCount,
      fields["storage-summary-matches-disk"] == "true",
      integer("pending-deletion-files") == 0,
      integer("expected-file-bytes") == audioByteCount,
      fields["source-checksum-preserved"] == "true"
    else { return false }
    return true
  }

  private func integer(_ key: String) -> Int? {
    fields[key].flatMap(Int.init)
  }
}
