import XCTest

@MainActor
final class ImportIngressResilienceUITests: XCTestCase {
  private let documentJobID = "70000000-0000-0000-0000-000000000001"
  private let handoffID = "70000000-0000-0000-0000-000000000101"
  private let shareJobID = "70000000-0000-0000-0000-000000000102"

  func testDocumentOpenResumesOneImportAcrossAcquireAndInspectRestarts() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let documentURL = try fixtureURL(
      resource: "document-open-interrupted-acquire",
      extension: "m4a"
    )

    let acquiringApp = makeApplication(
      reset: true,
      pauseAt: "acquire",
      channel: "document-open"
    )
    acquiringApp.launch()
    XCTAssertTrue(acquiringApp.wait(for: .runningForeground, timeout: 2))
    try requireValue(
      anyElement(acquiringApp, "import-ingress-probe"),
      "ingress:document:idle"
    )
    acquiringApp.open(documentURL)
    try requireValue(
      anyElement(acquiringApp, "import-ingress-probe"),
      "ingress:document:acquiring:job=\(documentJobID):jobs=1:staged=0:inspected=0:duplicates=0:source-unchanged=true"
    )
    XCTAssertTrue(terminateAndWait(acquiringApp))

    let inspectingApp = makeApplication(
      reset: false,
      pauseAt: "inspect",
      channel: "document-open"
    )
    inspectingApp.launch()
    try requireValue(
      anyElement(inspectingApp, "import-ingress-probe"),
      "ingress:document:inspecting:job=\(documentJobID):jobs=1:staged=1:inspected=0:duplicates=0:source-unchanged=true"
    )
    XCTAssertTrue(terminateAndWait(inspectingApp))

    let resumedApp = makeApplication(reset: false, channel: "document-open")
    resumedApp.launch()
    try requireValue(
      anyElement(resumedApp, "import-ingress-probe"),
      "ingress:document:ready:job=\(documentJobID):jobs=1:staged=1:inspected=1:proposals=1:duplicates=0:source-unchanged=true"
    )
    resumedApp.tabBars.buttons["Inbox"].tap()
    resumedApp.buttons["review-import-job-\(documentJobID)"].tap()
    try requireValue(
      anyElement(resumedApp, "review-import-screen"),
      "proposal:ready:1-book:1-tracks:0-warnings"
    )
  }

  func testConsumesAndDeduplicatesShareExtensionAppGroupHandoff() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let payload = try Data(contentsOf: fixtureURL(
      resource: "share-extension-handoff",
      extension: "m4a"
    ))
    let envelope = try Data(contentsOf: fixtureURL(
      resource: "share-extension-envelope",
      extension: "json"
    ))

    let consumingApp = makeShareApplication(
      reset: true,
      payload: payload,
      envelope: envelope
    )
    consumingApp.launch()
    try requireValue(
      anyElement(consumingApp, "share-handoff-probe"),
      "handoff:share-extension:consumed:id=\(handoffID):job=\(shareJobID):jobs=1:staged=1:proposals=1:receipt=recorded:pending=0:processing=0:source-unchanged=true"
    )
    XCTAssertTrue(terminateAndWait(consumingApp))

    let replayApp = makeShareApplication(
      reset: false,
      payload: payload,
      envelope: envelope
    )
    replayApp.launch()
    try requireValue(
      anyElement(replayApp, "share-handoff-probe"),
      "handoff:share-extension:deduplicated:id=\(handoffID):job=\(shareJobID):jobs=1:staged=1:proposals=1:receipt=retained:pending=0:processing=0:source-unchanged=true"
    )
    replayApp.tabBars.buttons["Inbox"].tap()
    XCTAssertTrue(replayApp.buttons["review-import-job-\(shareJobID)"].waitForExistence(timeout: 2))
  }

  private func makeApplication(
    reset: Bool,
    pauseAt: String? = nil,
    channel: String
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = baseArguments(reset: reset) + [
      "-e2e-import-channel", channel,
    ]
    if let pauseAt {
      app.launchArguments += ["-e2e-import-pause", pauseAt]
    }
    app.launchEnvironment["TZ"] = "America/Toronto"
    return app
  }

  private func makeShareApplication(
    reset: Bool,
    payload: Data,
    envelope: Data
  ) -> XCUIApplication {
    let app = makeApplication(reset: reset, channel: "share-extension")
    app.launchArguments += ["-e2e-stage-share-handoff", handoffID]
    app.launchEnvironment["PLAYER_E2E_SHARE_PAYLOAD_BASE64"] = payload.base64EncodedString()
    app.launchEnvironment["PLAYER_E2E_SHARE_ENVELOPE_BASE64"] = envelope.base64EncodedString()
    return app
  }

  private func baseArguments(reset: Bool) -> [String] {
    var arguments = [
      "-e2e", "-e2e-fixture", "synthetic-import-channels",
      "-AppleLanguages", "(en)",
      "-AppleLocale", "en_CA",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryM",
      "-NSTreatUnknownArgumentsAsOpen", "NO",
    ]
    if reset { arguments.insert("-e2e-reset", at: 1) }
    return arguments
  }

  private func fixtureURL(resource: String, extension fileExtension: String) throws -> URL {
    try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: resource, withExtension: fileExtension),
      "The checked-in synthetic import-channel fixture must be in the UI-test bundle"
    )
  }

  private func anyElement(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func requireValue(_ element: XCUIElement, _ expected: String) throws {
    guard element.waitForStringValue(expected, timeout: 2) else {
      XCTFail(
        "The import ingress journey did not reach its required semantic state; actual=\(String(describing: element.value))"
      )
      throw ImportIngressTestError.semanticStateUnavailable
    }
  }
}

private enum ImportIngressTestError: Error {
  case semanticStateUnavailable
}
