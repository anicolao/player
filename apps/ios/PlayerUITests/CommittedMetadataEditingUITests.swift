import XCTest

@MainActor
final class CommittedMetadataEditingUITests: XCTestCase {
  private enum ID {
    static let targetBook = "a7000000-0000-0000-0000-000000000001"
    static let atlasBook = "a7000000-0000-0000-0000-000000000002"
    static let cedarBook = "a7000000-0000-0000-0000-000000000003"
    static let transaction = "a7100000-0000-0000-0000-000000000001"
    static let editor = "metadata-editor-screen"
    static let save = "metadata-save"
    static let cancel = "metadata-cancel"
    static let validation = "metadata-validation-state"
    static let committed = "metadata-committed-state"
    static let integrity = "committed-metadata-integrity-probe"

    static func field(_ field: String) -> String { "metadata-field-\(field)" }
    static func provenance(_ field: String) -> String { "metadata-provenance-\(field)" }
    static func lock(_ field: String) -> String { "metadata-lock-\(field)" }
  }

  private let originalEvidence = [
    "schema=1", "state=original", "books=3", "target=present", "transactions=0",
    "applied=0", "undone=0", "transaction-exact=true", "metadata-exact=true",
    "source=exact", "managed-files=3", "managed=exact", "audio-unchanged=true",
  ].joined(separator: ":")

  private let editedEvidence = [
    "schema=1", "state=edited", "books=3", "target=present", "transactions=1",
    "applied=1", "undone=0", "transaction-exact=true", "metadata-exact=true",
    "source=exact", "managed-files=3", "managed=exact", "audio-unchanged=true",
  ].joined(separator: ":")

  private let restoredEvidence = [
    "schema=1", "state=restored", "books=3", "target=present", "transactions=1",
    "applied=0", "undone=1", "transaction-exact=true", "metadata-exact=true",
    "source=exact", "managed-files=3", "managed=exact", "audio-unchanged=true",
  ].joined(separator: ":")

  private var focusedMetadataField: String?

  func testEditsPersistsIndexesAndUndoesACommittedBookAtomically() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    var app = makeApplication(reset: true)
    app.launch()

    app.buttons["browse-all-books"].tap()
    openTargetFromAllBooks(app)
    let integrity = anyElement(app, ID.integrity)
    try requireValue(integrity, originalEvidence)

    // A cancelled draft must not reach the model, index, persisted library, or audio.
    app.buttons["edit-book-metadata"].tap()
    let editor = anyElement(app, ID.editor)
    try requireValue(editor, "metadata:book:revision=0:dirty=false:saving=false:validation=valid")
    let seriesPosition = app.textFields[ID.field("seriesPosition")]
    XCTAssertTrue(waitForPredicate(
      NSPredicate(format: "exists == true AND enabled == false"),
      on: seriesPosition,
      timeout: EventDeadline().remaining
    ), "Series position must be disabled until a series exists")
    try replaceText(
      in: app.textFields[ID.field("title")],
      with: "Cancelled Draft",
      field: "title",
      app: app
    )
    try requireValue(editor, "metadata:book:revision=0:dirty=true:saving=false:validation=valid")
    app.buttons[ID.cancel].tap()
    XCTAssertTrue(waitForNoElements(
      app.descendants(matching: .any).matching(identifier: ID.editor),
      deadline: EventDeadline()
    ))
    try requireValue(integrity, originalEvidence)
    XCTAssertTrue(waitForExistence(app.staticTexts["Zulu Harbor"], deadline: EventDeadline()))

    navigateBack(app, label: "All Books", destination: anyElement(app, "all-books-screen"))
    navigateBack(app, label: "Library", destination: anyElement(app, "library-screen"))
    app.buttons["open-library-search"].tap()
    try setSearchQuery("Cancelled Draft", app: app)
    try requireSearch(app, query: "cancelled draft", count: 0, order: [])
    try setSearchQuery("Ari North", app: app)
    try requireSearch(app, query: "ari north", count: 1, order: [ID.targetBook])
    app.descendants(matching: .any)["search-result-\(ID.targetBook)"].tap()
    try requireValue(anyElement(app, ID.integrity), originalEvidence)

    app.buttons["edit-book-metadata"].tap()
    try requireValue(
      anyElement(app, ID.editor),
      "metadata:book:revision=0:dirty=false:saving=false:validation=valid"
    )
    XCTAssertTrue(waitForPredicate(
      NSPredicate(format: "exists == true AND enabled == false"),
      on: app.textFields[ID.field("seriesPosition")],
      timeout: EventDeadline().remaining
    ))

    try replaceText(in: app.textFields[ID.field("title")], with: "The Amber Archive", field: "title", app: app)
    app.buttons["metadata-apply-title"].tap()
    try replaceText(in: app.textFields[ID.field("sortTitle")], with: "Amber Archive, The", field: "sortTitle", app: app)
    try replaceText(in: app.textFields[ID.field("subtitle")], with: "", field: "subtitle", app: app)
    try replaceText(in: app.textFields[ID.field("authors")], with: "Leona Quill, Marek Stone", field: "authors", app: app)
    app.buttons["metadata-clear-narrators"].tap()
    try requireProvenance(
      app,
      field: "narrators",
      value: "value=empty|source=user-clear|confidence=user|locked=true|cleared=true"
    )
    try replaceText(in: app.textFields[ID.field("seriesName")], with: "Copper Meridian", field: "seriesName", app: app)
    XCTAssertTrue(waitForPredicate(
      NSPredicate(format: "exists == true AND enabled == true"),
      on: app.textFields[ID.field("seriesPosition")],
      timeout: EventDeadline().remaining
    ))
    try replaceText(in: app.textFields[ID.field("seriesPosition")], with: "3.5", field: "seriesPosition", app: app)
    dismissMetadataKeyboard(app, surface: metadataEditorSurface(app))
    app.buttons[ID.lock("seriesName")].tap()
    try requireProvenance(
      app,
      field: "seriesName",
      value: "value=Copper Meridian #3.5|source=user|confidence=user|locked=true|cleared=false"
    )
    try replaceText(in: app.textFields[ID.field("description")], with: "A revised archival journey.", field: "description", app: app)
    try replaceText(in: app.textFields[ID.field("genres")], with: "Adventure, History", field: "genres", app: app)
    dismissMetadataKeyboard(app, surface: metadataEditorSurface(app))
    app.buttons[ID.lock("genres")].tap()
    try requireProvenance(
      app,
      field: "genres",
      value: "value=Adventure, History|source=user|confidence=user|locked=true|cleared=false"
    )
    try replaceText(in: app.textFields[ID.field("tags")], with: "restored, night", field: "tags", app: app)
    try replaceText(in: app.textFields[ID.field("language")], with: "fr-CA", field: "language", app: app)

    let year = app.textFields[ID.field("publicationYear")]
    try replaceText(in: year, with: "20x4", field: "publicationYear", app: app)
    try requireInvalidYear(app, containing: "20x4")
    try replaceText(in: year, with: "10000", field: "publicationYear", app: app)
    try requireInvalidYear(app, containing: "10000")
    try replaceText(in: year, with: "2024", field: "publicationYear", app: app)
    try requireValue(anyElement(app, ID.validation), "valid")

    try replaceText(in: app.textFields[ID.field("publisher")], with: "Burnt Oak Audio", field: "publisher", app: app)
    try replaceText(in: app.textFields[ID.field("edition")], with: "Second edition", field: "edition", app: app)
    let abridgement = anyElement(app, ID.field("abridgement"))
    XCTAssertTrue(waitForExistence(abridgement, deadline: EventDeadline()))
    abridgement.tap()
    let unabridgedQuery = app.buttons.matching(
      NSPredicate(format: "label == %@", "Unabridged")
    )
    let unabridged = unabridgedQuery.element
    XCTAssertTrue(waitForExistence(unabridged, deadline: EventDeadline()))
    XCTAssertEqual(unabridgedQuery.count, 1)
    unabridged.tap()
    try requireProvenance(
      app,
      field: "abridgement",
      value: "value=unabridged|source=user|confidence=user|locked=false|cleared=false"
    )
    XCTAssertTrue(
      waitForNoElements(unabridgedQuery, deadline: EventDeadline()),
      "The abridgement choice must dismiss before Save"
    )
    try requireValue(anyElement(app, ID.validation), "valid")

    let save = app.buttons[ID.save]
    XCTAssertTrue(waitForPredicate(
      NSPredicate(format: "exists == true AND enabled == true"),
      on: save,
      timeout: EventDeadline().remaining
    ))
    save.tap()
    XCTAssertTrue(waitForNoElements(
      app.descendants(matching: .any).matching(identifier: ID.editor),
      deadline: EventDeadline()
    ))
    try requireValue(anyElement(app, ID.integrity), editedEvidence)
    XCTAssertTrue(waitForExistence(app.staticTexts["The Amber Archive"], deadline: EventDeadline()))
    XCTAssertTrue(waitForExistence(app.staticTexts["Leona Quill"], deadline: EventDeadline()))
    XCTAssertTrue(waitForExistence(
      app.staticTexts["Copper Meridian · Book 3.5"],
      deadline: EventDeadline()
    ))
    XCTAssertTrue(waitForNoElements(
      app.staticTexts.matching(NSPredicate(format: "label == %@", "Milo Grey")),
      deadline: EventDeadline()
    ))

    // Search was already mounted beneath Book Detail. It must rebuild from the
    // saved book rather than serving its old Ari North entry.
    navigateBack(app, label: "Search", destination: anyElement(app, "library-search-screen"))
    try requireSearch(app, query: "ari north", count: 0, order: [])
    navigateBack(app, label: "Library", destination: anyElement(app, "library-screen"))

    try verifyAllBooksOrder(
      app,
      expected: [ID.targetBook, ID.atlasBook, ID.cedarBook],
      view: "shelf"
    )
    app.buttons["library-view-list"].tap()
    try requireValue(
      anyElement(app, "all-books-probe"),
      allBooksValue(order: [ID.targetBook, ID.atlasBook, ID.cedarBook], view: "list")
    )
    navigateBack(app, label: "Library", destination: anyElement(app, "library-screen"))
    try verifyBrowseFacets(app, edited: true)

    XCTAssertTrue(terminateAndWait(app))
    app = makeApplication(reset: false)
    app.launch()
    app.buttons["browse-all-books"].tap()
    openTargetFromAllBooks(app)
    try requireValue(anyElement(app, ID.integrity), editedEvidence)
    XCTAssertTrue(waitForExistence(
      app.staticTexts["The Amber Archive"],
      deadline: EventDeadline()
    ))
    app.buttons["edit-book-metadata"].tap()
    try verifyPersistedFieldProvenance(app)
    app.buttons[ID.cancel].tap()
    XCTAssertTrue(waitForNoElements(
      app.descendants(matching: .any).matching(identifier: ID.editor),
      deadline: EventDeadline()
    ))
    try requireValue(anyElement(app, ID.integrity), editedEvidence)

    navigateBack(app, label: "All Books", destination: anyElement(app, "all-books-screen"))
    navigateBack(app, label: "Library", destination: anyElement(app, "library-screen"))
    app.buttons["open-library-search"].tap()
    try setSearchQuery("Burnt Oak Audio", app: app)
    try requireSearch(app, query: "burnt oak audio", count: 1, order: [ID.targetBook])
    app.descendants(matching: .any)["search-result-\(ID.targetBook)"].tap()
    let undo = app.buttons["undo-metadata-repair"]
    XCTAssertTrue(waitForExistence(undo, deadline: EventDeadline()))
    undo.tap()
    try requireValue(anyElement(app, ID.integrity), restoredEvidence)
    XCTAssertTrue(waitForExistence(app.staticTexts["Zulu Harbor"], deadline: EventDeadline()))
    XCTAssertTrue(waitForNoElements(
      app.buttons.matching(identifier: "undo-metadata-repair"),
      deadline: EventDeadline()
    ))

    // This exact Search instance remains mounted under Book Detail. Undo keeps
    // the transaction count at one, so only a semantic revision can refresh it.
    navigateBack(app, label: "Search", destination: anyElement(app, "library-search-screen"))
    try requireSearch(app, query: "burnt oak audio", count: 0, order: [])
    try setSearchQuery("Ari North", app: app)
    try requireSearch(app, query: "ari north", count: 1, order: [ID.targetBook])
    navigateBack(app, label: "Library", destination: anyElement(app, "library-screen"))
    try verifyAllBooksOrder(
      app,
      expected: [ID.atlasBook, ID.cedarBook, ID.targetBook],
      view: "list"
    )
    navigateBack(app, label: "Library", destination: anyElement(app, "library-screen"))
    try verifyBrowseFacets(app, edited: false)
  }

  private func makeApplication(reset: Bool) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-e2e", "-e2e-fixture", "synthetic-committed-metadata",
      "-e2e-committed-metadata-namespace", "primary",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset { app.launchArguments.insert("-e2e-reset", at: 1) }
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func openTargetFromAllBooks(_ app: XCUIApplication) {
    let target = app.descendants(matching: .any)["all-books-book-\(ID.targetBook)"]
    XCTAssertTrue(waitForExistence(target, deadline: EventDeadline()))
    target.tap()
    XCTAssertTrue(waitForExistence(anyElement(app, "book-detail-screen"), deadline: EventDeadline()))
  }

  private func verifyAllBooksOrder(
    _ app: XCUIApplication,
    expected: [String],
    view: String
  ) throws {
    app.buttons["browse-all-books"].tap()
    try requireValue(anyElement(app, "all-books-probe"), allBooksValue(order: expected, view: view))
  }

  private func allBooksValue(order: [String], view: String) -> String {
    "all-books:count=3:view=\(view):order=\(order.joined(separator: ","))"
  }

  private func verifyBrowseFacets(_ app: XCUIApplication, edited: Bool) throws {
    if edited {
      try verifyFacet(
        app,
        button: "browse-series",
        probe: "series-browser-probe",
        expected: "browse:series:groups=3:books=3:order=atlas cycle,cedar arc,copper meridian"
      )
      try verifyFacet(
        app,
        button: "browse-authors",
        probe: "authors-browser-probe",
        expected: "browse:authors:groups=4:books=4:order=bea moss,leona quill,marek stone,nico vale"
      )
      try verifyFacet(
        app,
        button: "browse-narrators",
        probe: "narrators-browser-probe",
        expected: "browse:narrators:groups=2:books=2:order=ada coil,soren bell"
      )
    } else {
      try verifyFacet(
        app,
        button: "browse-series",
        probe: "series-browser-probe",
        expected: "browse:series:groups=2:books=2:order=atlas cycle,cedar arc"
      )
      try verifyFacet(
        app,
        button: "browse-authors",
        probe: "authors-browser-probe",
        expected: "browse:authors:groups=3:books=3:order=ari north,bea moss,nico vale"
      )
      try verifyFacet(
        app,
        button: "browse-narrators",
        probe: "narrators-browser-probe",
        expected: "browse:narrators:groups=3:books=3:order=ada coil,milo grey,soren bell"
      )
    }
  }

  private func verifyFacet(
    _ app: XCUIApplication,
    button: String,
    probe: String,
    expected: String
  ) throws {
    app.buttons[button].tap()
    try requireValue(anyElement(app, probe), expected)
    navigateBack(app, label: "Library", destination: anyElement(app, "library-screen"))
  }

  private func verifyPersistedFieldProvenance(_ app: XCUIApplication) throws {
    let transaction = ID.transaction
    let expectations: [(String, String)] = [
      ("cover", "value=cover|source=embedded-artwork|confidence=high|locked=false|cleared=false"),
      ("title", "value=The Amber Archive|source=user|confidence=user|locked=true|cleared=false"),
      ("sortTitle", "value=Amber Archive, The|source=user|confidence=user|locked=false|cleared=false"),
      ("subtitle", "value=empty|source=user-clear|confidence=user|locked=false|cleared=true"),
      ("authors", "value=Leona Quill, Marek Stone|source=user|confidence=user|locked=false|cleared=false"),
      ("narrators", "value=empty|source=user-clear|confidence=user|locked=true|cleared=true"),
      ("seriesName", "value=Copper Meridian #3.5|source=user|confidence=user|locked=true|cleared=false"),
      ("seriesPosition", "value=3.5|source=user|confidence=user|locked=false|cleared=false"),
      ("description", "value=A revised archival journey.|source=user|confidence=user|locked=false|cleared=false"),
      ("genres", "value=Adventure, History|source=user|confidence=user|locked=true|cleared=false"),
      ("tags", "value=restored, night|source=user|confidence=user|locked=false|cleared=false"),
      ("language", "value=fr-CA|source=user|confidence=user|locked=false|cleared=false"),
      ("publicationYear", "value=2024|source=user|confidence=user|locked=false|cleared=false"),
      ("publisher", "value=Burnt Oak Audio|source=user|confidence=user|locked=false|cleared=false"),
      ("edition", "value=Second edition|source=user|confidence=user|locked=false|cleared=false"),
      ("abridgement", "value=unabridged|source=user|confidence=user|locked=false|cleared=false"),
    ]
    for (field, expected) in expectations {
      try requireProvenance(app, field: field, value: expected)
    }
    let committed = anyElement(app, ID.committed)
    XCTAssertTrue(waitForExistence(committed, deadline: EventDeadline()))
    let value = try stringValue(of: committed)
    XCTAssertTrue(value.contains("target=book:\(ID.targetBook)"))
    XCTAssertTrue(value.contains("transactions=\(transaction):applied"))
    for field in expectations.map(\.0) {
      XCTAssertTrue(value.contains("\(field){"), "Comprehensive state omitted \(field)")
    }
  }

  private func requireInvalidYear(_ app: XCUIApplication, containing value: String) throws {
    let validation = anyElement(app, ID.validation)
    XCTAssertTrue(waitForExistence(validation, deadline: EventDeadline()))
    let actual = try stringValue(of: validation)
    XCTAssertTrue(actual.hasPrefix("invalid="), "Expected invalid year state; actual=\(actual)")
    XCTAssertTrue(actual.contains(value), "Invalid year state omitted \(value); actual=\(actual)")
    XCTAssertTrue(waitForPredicate(
      NSPredicate(format: "exists == true AND enabled == false"),
      on: app.buttons[ID.save],
      timeout: EventDeadline().remaining
    ), "An invalid year must block Save")
  }

  private func replaceText(
    in field: XCUIElement,
    with replacement: String,
    field fieldName: String,
    app: XCUIApplication
  ) throws {
    XCTAssertTrue(waitForExistence(field, deadline: EventDeadline()))
    let surface = metadataEditorSurface(app)
    let scroll = surface.container
    if app.keyboards.firstMatch.exists, focusedMetadataField != fieldName {
      dismissMetadataKeyboard(app, surface: surface)
    }
    let revealed: Bool
    if field.isHittable {
      revealed = true
    } else {
      let targetIsAboveViewport = field.frame.maxY <= scroll.frame.minY
      if field.isHittable {
        revealed = true
      } else if targetIsAboveViewport {
        revealed = scrollUntil(
          { field.isHittable },
          on: surface,
          deadline: EventDeadline(),
          direction: .towardStart,
          terminalEndpoint: \.atTop,
          failureContext: {
            "field=\(fieldName), direction=toward-start, frame=\(field.frame), "
              + "scroll=\(scroll.frame), hittable=\(field.isHittable)"
          }
        ) {
          boundedEditorDrag(in: scroll, direction: .towardStart)
        }
      } else {
        revealed = scrollUntil(
          { field.isHittable },
          on: surface,
          deadline: EventDeadline(),
          direction: .towardEnd,
          terminalEndpoint: \.atBottom,
          failureContext: {
            "field=\(fieldName), direction=toward-end, frame=\(field.frame), "
              + "scroll=\(scroll.frame), hittable=\(field.isHittable)"
          }
        ) {
          boundedEditorDrag(in: scroll, direction: .towardEnd)
        }
      }
    }
    XCTAssertTrue(
      revealed,
      "The metadata field must become hittable through progress-making editor scrolling"
    )
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    XCTAssertTrue(
      waitForPredicate(
        NSPredicate(format: "exists == true AND hittable == true AND hasKeyboardFocus == true"),
        on: field,
        timeout: EventDeadline().remaining
      ),
      "The metadata field must be hittable and acquire focus before replacement text is entered"
    )
    focusedMetadataField = fieldName
    XCTAssertTrue(waitForExistence(app.keyboards.firstMatch, deadline: EventDeadline()))
    let provenance = anyElement(app, ID.provenance(fieldName))
    XCTAssertTrue(waitForExistence(provenance, deadline: EventDeadline()))
    let currentProvenance = try stringValue(of: provenance)
    let currentValue = try metadataValue(from: currentProvenance)
    if !currentValue.isEmpty {
      field.typeText(
        String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
      )
      try requireValuePrefix(provenance, "value=empty|")
    }
    if !replacement.isEmpty {
      field.typeText(replacement)
    }
    let expectedPrefix = replacement.isEmpty ? "value=empty|" : "value=\(replacement)|"
    try requireValuePrefix(provenance, expectedPrefix)
  }

  private func metadataEditorSurface(_ app: XCUIApplication) -> ScrollSurface {
    ScrollSurface(
      container: anyElement(app, "metadata-editor-scroll"),
      readiness: anyElement(app, "metadata-editor-scroll-readiness"),
      containerID: "metadata-editor-scroll",
      axis: .vertical,
      permitsGeometrySettledFallback: true
    )
  }

  private func dismissMetadataKeyboard(
    _ app: XCUIApplication,
    surface: ScrollSurface
  ) {
    guard app.keyboards.firstMatch.exists else { return }
    let dismissalDeadline = EventDeadline()
    let done = app.buttons["metadata-keyboard-done"]
    XCTAssertTrue(waitForExistence(done, deadline: dismissalDeadline))
    done.tap()
    XCTAssertTrue(
      waitForNoElements(app.keyboards, deadline: dismissalDeadline)
        && waitForScrollReadiness(
          surface,
          deadline: dismissalDeadline,
          matching: { $0.isIdle && $0.geometryReady }
        ),
      "Done must dismiss the focused metadata field and settle layout before the next action"
    )
    focusedMetadataField = nil
  }

  private func requireProvenance(
    _ app: XCUIApplication,
    field: String,
    value: String
  ) throws {
    try requireValue(anyElement(app, ID.provenance(field)), value)
  }

  private func setSearchQuery(_ query: String, app: XCUIApplication) throws {
    let clear = app.buttons["clear-search-query"]
    if clear.exists {
      clear.tap()
      try requireSearch(app, query: "", count: 3, order: nil)
    }
    let input = app.textFields["library-search-input"]
    XCTAssertTrue(waitForExistence(input, deadline: EventDeadline()))
    input.tap()
    XCTAssertTrue(waitForExistence(app.keyboards.firstMatch, deadline: EventDeadline()))
    input.typeText(query + "\n")
  }

  private func requireSearch(
    _ app: XCUIApplication,
    query: String,
    count: Int,
    order: [String]?
  ) throws {
    let probe = anyElement(app, "library-search-probe")
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        guard probe.exists,
          let value = probe.value.map(String.init(describing:)),
          let state = SearchProbe(value)
        else { return false }
        return state.indexed
          && state.query == query
          && state.count == count
          && (order == nil || state.order == order)
      },
      object: nil
    )
    guard XCTWaiter.wait(for: [expectation], timeout: EventDeadline().remaining) == .completed
    else {
      XCTFail("Search did not reach query=\(query), count=\(count), order=\(String(describing: order)); actual=\(String(describing: probe.value))")
      throw CommittedMetadataTestError.semanticStateUnavailable
    }
  }

  private func boundedEditorDrag(
    in scroll: XCUIElement,
    direction: ScrollProbeDirection
  ) {
    let startY = direction == .towardEnd ? 0.50 : 0.30
    let endY = direction == .towardEnd ? 0.30 : 0.50
    scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: startY))
      .press(
        forDuration: 0,
        thenDragTo: scroll.coordinate(
          withNormalizedOffset: CGVector(dx: 0.82, dy: endY)
        ),
        withVelocity: 300,
        thenHoldForDuration: 0
      )
  }

  private func navigateBack(
    _ app: XCUIApplication,
    label: String,
    destination: XCUIElement
  ) {
    let back = app.navigationBars.buttons[label]
    XCTAssertTrue(waitForExistence(back, deadline: EventDeadline()))
    back.tap()
    XCTAssertTrue(waitForExistence(destination, deadline: EventDeadline()))
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    guard element.waitForStringValue(expected, timeout: 2) else {
      XCTFail("Required value was unavailable; expected=\(expected), actual=\(String(describing: element.value))")
      throw CommittedMetadataTestError.semanticStateUnavailable
    }
  }

  private func requireValuePrefix(_ element: XCUIElement, _ expectedPrefix: String) throws {
    if element.exists,
      element.value.map(String.init(describing:))?.hasPrefix(expectedPrefix) == true
    {
      return
    }
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(
        format: "exists == true AND value BEGINSWITH %@",
        expectedPrefix
      ),
      object: element
    )
    let completed = XCTWaiter.wait(
      for: [expectation],
      timeout: EventDeadline().remaining
    ) == .completed
    let finalValue = element.exists ? element.value.map(String.init(describing:)) : nil
    guard completed || finalValue?.hasPrefix(expectedPrefix) == true else {
      XCTFail("Required value prefix was unavailable; expected=\(expectedPrefix), actual=\(String(describing: element.value))")
      throw CommittedMetadataTestError.semanticStateUnavailable
    }
  }

  private func stringValue(of element: XCUIElement) throws -> String {
    guard element.exists, let value = element.value else {
      throw CommittedMetadataTestError.semanticStateUnavailable
    }
    return String(describing: value)
  }

  private func metadataValue(from provenance: String) throws -> String {
    guard provenance.hasPrefix("value="),
      let sourceRange = provenance.range(of: "|source=")
    else { throw CommittedMetadataTestError.semanticStateUnavailable }
    let start = provenance.index(provenance.startIndex, offsetBy: "value=".count)
    let value = String(provenance[start..<sourceRange.lowerBound])
    return value == "empty" ? "" : value
  }
}

private struct SearchProbe {
  let indexed: Bool
  let query: String
  let count: Int
  let order: [String]

  init?(_ encoded: String) {
    let tokens = encoded.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard tokens.first == "search" else { return nil }
    var values: [String: String] = [:]
    for token in tokens.dropFirst() {
      let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2, !pair[0].isEmpty, values[String(pair[0])] == nil else { return nil }
      values[String(pair[0])] = String(pair[1])
    }
    let keys: Set<String> = [
      "revision", "indexed", "query", "count", "sort", "direction", "status",
      "formats", "missing", "empty", "order",
    ]
    guard Set(values.keys) == keys,
      let revision = values["revision"], revision.count == 64,
      revision.allSatisfy({ $0.isHexDigit }),
      let indexedText = values["indexed"], ["true", "false"].contains(indexedText),
      let countText = values["count"], let count = Int(countText), count >= 0,
      let sort = values["sort"],
      ["title", "author", "series", "recentlyAdded", "duration", "progress"].contains(sort),
      let direction = values["direction"], ["ascending", "descending"].contains(direction),
      let status = values["status"],
      ["any", "unplayed", "inProgress", "finished"].contains(status),
      let formats = values["formats"],
      formats == "any" || formats.split(separator: ",").allSatisfy({ $0 == "M4B" }),
      let missing = values["missing"], ["true", "false"].contains(missing),
      let empty = values["empty"], ["none", "filters", "query"].contains(empty),
      let orderText = values["order"]
    else { return nil }
    let order = orderText == "none" ? [] : orderText.split(separator: ",").map(String.init)
    guard order.count == count,
      Set(order).count == order.count,
      order.allSatisfy({ UUID(uuidString: $0) != nil }),
      (count == 0) == (empty != "none")
    else { return nil }
    self.indexed = indexedText == "true"
    query = values["query"] ?? ""
    self.count = count
    self.order = order
  }
}

private enum CommittedMetadataTestError: Error {
  case semanticStateUnavailable
}
