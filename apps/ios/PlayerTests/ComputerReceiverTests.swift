import Network
import WebKit
import XCTest

@testable import Player

@MainActor
final class ComputerReceiverTests: XCTestCase {
  func testCanonicalReceiverScenariosAndMirroringTipOverridesParseExactly() throws {
    let production = try E2EComputerReceiverLaunchConfiguration.parse(
      arguments: ["Player"],
      e2eLaunchConfiguration: nil
    )
    XCTAssertNil(production.scenario)
    XCTAssertEqual(production.mirroringTip, .automatic)
    XCTAssertEqual(production.transportRoot, .production)

    let ready = try receiverConfiguration(arguments: [])
    XCTAssertEqual(ready.scenario, .ready)
    XCTAssertEqual(ready.mirroringTip, .automatic)

    let phases: [(String, E2EComputerReceiverLaunchConfiguration.Scenario)] = [
      ("-e2e-mirroring-drop-progress", .dropProgress),
      ("-e2e-computer-receiver-completed", .completed),
      ("-e2e-computer-receiver-failed", .failed),
      ("-e2e-computer-receiver-listener-failure", .listenerFailure),
      ("-e2e-computer-receiver-needs-review", .needsReview),
      ("-e2e-computer-receiver-paused", .paused),
    ]
    for (argument, scenario) in phases {
      let parsed = try receiverConfiguration(arguments: [argument])
      XCTAssertEqual(parsed.scenario, scenario)
      XCTAssertEqual(parsed.mirroringTip, .automatic)
    }

    let shown = try receiverConfiguration(arguments: ["-e2e-show-mirroring-tip"])
    XCTAssertEqual(shown.scenario, .ready)
    XCTAssertEqual(shown.mirroringTip, .show)
    let hidden = try receiverConfiguration(arguments: ["-e2e-hide-mirroring-tip"])
    XCTAssertEqual(hidden.scenario, .ready)
    XCTAssertEqual(hidden.mirroringTip, .hide)
  }

  func testReceiverScenarioRejectsDuplicateIncompatibleAndPhaseWithoutReadyFlags() {
    let invalidArguments = [
      ["-e2e-computer-receiver-ready"],
      ["-e2e-mirroring-drop-progress", "-e2e-mirroring-drop-progress"],
      ["-e2e-computer-receiver-completed", "-e2e-computer-receiver-completed"],
      ["-e2e-computer-receiver-failed", "-e2e-computer-receiver-failed"],
      [
        "-e2e-computer-receiver-listener-failure",
        "-e2e-computer-receiver-listener-failure",
      ],
      ["-e2e-computer-receiver-needs-review", "-e2e-computer-receiver-needs-review"],
      ["-e2e-computer-receiver-paused", "-e2e-computer-receiver-paused"],
      ["-e2e-mirroring-drop-progress", "-e2e-computer-receiver-completed"],
      ["-e2e-mirroring-drop-progress", "-e2e-computer-receiver-paused"],
      ["-e2e-computer-receiver-completed", "-e2e-computer-receiver-paused"],
    ]

    for additionalArguments in invalidArguments {
      let arguments = ["Player", "-e2e", "-e2e-computer-receiver-ready"]
        + additionalArguments
      XCTAssertThrowsError(
        try E2EComputerReceiverLaunchConfiguration.parse(
          arguments: arguments,
          e2eLaunchConfiguration: e2eLaunch(fixture: .emptyLibrary),
          launchIdentifier: "receiver-test"
        ),
        "Expected invalid receiver scenario to be rejected: \(arguments)"
      )
    }

    for phase in [
      "-e2e-mirroring-drop-progress",
      "-e2e-computer-receiver-completed",
      "-e2e-computer-receiver-failed",
      "-e2e-computer-receiver-listener-failure",
      "-e2e-computer-receiver-needs-review",
      "-e2e-computer-receiver-paused",
    ] {
      XCTAssertThrowsError(
        try E2EComputerReceiverLaunchConfiguration.parse(
          arguments: ["Player", "-e2e", phase],
          e2eLaunchConfiguration: e2eLaunch(fixture: .emptyLibrary),
          launchIdentifier: "receiver-test"
        )
      )
    }
  }

  func testMirroringTipRejectsDuplicatesAndConflictingOverrides() {
    let invalidArguments = [
      ["-e2e-show-mirroring-tip", "-e2e-show-mirroring-tip"],
      ["-e2e-hide-mirroring-tip", "-e2e-hide-mirroring-tip"],
      ["-e2e-show-mirroring-tip", "-e2e-hide-mirroring-tip"],
    ]
    for additionalArguments in invalidArguments {
      XCTAssertThrowsError(
        try receiverConfiguration(arguments: additionalArguments),
        "Expected invalid mirroring-tip override to be rejected: \(additionalArguments)"
      )
    }
  }

  func testRemovedTargetedModeAndUnknownReceiverFlagsFailClosed() {
    for argument in [
      "-e2e-mirroring-drop-targeted",
      "-e2e-mirroring-drop-unknown",
      "-e2e-computer-receiver-unknown",
    ] {
      XCTAssertThrowsError(
        try receiverConfiguration(arguments: [argument]),
        "Expected unknown receiver option to be rejected: \(argument)"
      )
    }
  }

  func testReceiverRootIsPrivateToFixtureScenarioAndLaunch() throws {
    let ready = try receiverConfiguration(arguments: [], launchIdentifier: "launch-101")
    let completed = try receiverConfiguration(
      arguments: ["-e2e-computer-receiver-completed"],
      launchIdentifier: "launch-101"
    )
    let nextLaunch = try receiverConfiguration(arguments: [], launchIdentifier: "launch-102")

    XCTAssertEqual(
      ready.transportRoot,
      .e2e(namespace: "PlayerE2EComputerReceiver-empty-library-ready-launch-101")
    )
    XCTAssertNotEqual(ready.transportRoot, completed.transportRoot)
    XCTAssertNotEqual(ready.transportRoot, nextLaunch.transportRoot)
  }

  func testIsolatedReceiverControllerLeavesProductionTransportRootUntouched() throws {
    let sandbox = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let support = sandbox.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
    let temporary = sandbox.appending(path: "Temporary", directoryHint: .isDirectory)
    let productionRoot = support
      .appending(path: "Player", directoryHint: .isDirectory)
      .appending(path: "ComputerReceiver", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: productionRoot, withIntermediateDirectories: true)
    let sentinel = productionRoot.appending(path: "production-sentinel.txt")
    let sentinelData = Data("must-not-be-deleted-by-e2e".utf8)
    try sentinelData.write(to: sentinel, options: .atomic)

    let configuration = try receiverConfiguration(
      arguments: [],
      launchIdentifier: "isolated-root"
    )
    let controller = ComputerReceiverController(
      launchConfiguration: configuration,
      applicationSupportURL: support,
      temporaryDirectory: temporary
    )

    XCTAssertEqual(
      controller.transportRootURL,
      temporary.appending(
        path: "PlayerE2EComputerReceiver-empty-library-ready-isolated-root",
        directoryHint: .isDirectory
      ).standardizedFileURL
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: controller.transportRootURL.path))
    XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
  }

  func testProductionReceiverCleansRelaunchDebrisOnceAndPreservesAcceptedScreenReopenFiles() throws
  {
    let sandbox = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: sandbox) }
    let support = sandbox.appending(path: "ApplicationSupport", directoryHint: .isDirectory)
    let temporary = sandbox.appending(path: "Temporary", directoryHint: .isDirectory)
    let receiverRoot = support
      .appending(path: "Player", directoryHint: .isDirectory)
      .appending(path: "ComputerReceiver", directoryHint: .isDirectory)
    let stalePartial = receiverRoot
      .appending(path: "stale-session", directoryHint: .isDirectory)
      .appending(path: "Chapter.partial")
    try FileManager.default.createDirectory(
      at: stalePartial.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("incomplete transfer".utf8).write(to: stalePartial)

    _ = ComputerReceiverController(
      launchConfiguration: .production,
      applicationSupportURL: support,
      temporaryDirectory: temporary
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: stalePartial.path))

    let accepted = receiverRoot.appending(path: "accepted-import.m4b")
    let acceptedBytes = Data("accepted import".utf8)
    try acceptedBytes.write(to: accepted)
    _ = ComputerReceiverController(
      launchConfiguration: .production,
      applicationSupportURL: support,
      temporaryDirectory: temporary
    )

    XCTAssertEqual(try Data(contentsOf: accepted), acceptedBytes)
  }

  func testInvalidReceiverConfigurationCannotMutateFixtureOrProductionReceiverRoots() throws {
    let fixtureRoot = FileManager.default.temporaryDirectory.appending(
      path: "PlayerE2EEmptyLibrary",
      directoryHint: .isDirectory
    )
    try? FileManager.default.removeItem(at: fixtureRoot)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let fixtureSentinel = fixtureRoot.appending(path: "fixture-sentinel.txt")
    let fixtureData = Data("fixture-must-survive".utf8)
    try fixtureData.write(to: fixtureSentinel, options: .atomic)

    let receiverSandbox = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: receiverSandbox) }
    let receiverSupport = receiverSandbox.appending(
      path: "ApplicationSupport",
      directoryHint: .isDirectory
    )
    let productionReceiverRoot = receiverSupport
      .appending(path: "Player", directoryHint: .isDirectory)
      .appending(path: "ComputerReceiver", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: productionReceiverRoot,
      withIntermediateDirectories: true
    )
    let receiverSentinel = productionReceiverRoot.appending(path: "receiver-sentinel.txt")
    let receiverData = Data("receiver-must-survive".utf8)
    try receiverData.write(to: receiverSentinel, options: .atomic)

    let arguments = [
      "Player", "-e2e", "-e2e-reset", "-e2e-fixture", "empty-library",
      "-e2e-computer-receiver-paused",
    ]
    XCTAssertThrowsError(
      try {
        let launch = try XCTUnwrap(E2ELaunchConfiguration.parse(arguments: arguments))
        let receiver = try E2EComputerReceiverLaunchConfiguration.parse(
          arguments: arguments,
          e2eLaunchConfiguration: launch,
          launchIdentifier: "invalid-launch"
        )
        _ = try PlayerEnvironment.launchEnvironment(
          e2eLaunchConfiguration: launch,
          playbackControls: .disabled
        )
        _ = ComputerReceiverController(
          launchConfiguration: receiver,
          applicationSupportURL: receiverSupport,
          temporaryDirectory: receiverSandbox.appending(path: "Temporary")
        )
      }()
    )
    XCTAssertEqual(try Data(contentsOf: fixtureSentinel), fixtureData)
    XCTAssertEqual(try Data(contentsOf: receiverSentinel), receiverData)
  }

  func testMirroringTipPolicyUsesInjectedConfiguration() throws {
    let automatic = try receiverConfiguration(arguments: [])
    let shown = try receiverConfiguration(arguments: ["-e2e-show-mirroring-tip"])
    let hidden = try receiverConfiguration(arguments: ["-e2e-hide-mirroring-tip"])

    XCTAssertTrue(MirroringTipPolicy.shouldShow(configuration: automatic, region: "CA"))
    XCTAssertFalse(MirroringTipPolicy.shouldShow(configuration: automatic, region: "FR"))
    XCTAssertTrue(MirroringTipPolicy.shouldShow(configuration: shown, region: "FR"))
    XCTAssertFalse(MirroringTipPolicy.shouldShow(configuration: hidden, region: "CA"))
  }

  func testInjectedBindingServesRawHTTPGetThroughProductionServerPath() async throws {
    let root = temporaryRoot()
    let binding = E2EDeterministicComputerReceiverBinding()
    let exchangeHandled = expectation(description: "Production receiver served the raw HTTP request")
    var observedEvents: [ComputerReceiverEvent] = []
    let server = ComputerReceiverServer(
      rootURL: root,
      bundle: .main,
      portPreference: try isolatedPortPreference(),
      binding: binding,
      credentials: ComputerReceiverCredentials(
        pairingCode: "482731",
        bearerToken: "focused-receiver-token"
      )
    )
    registerCleanup(for: server, root: root)

    let ready = try await server.start(
      importHandler: successfulReceiverImport,
      eventHandler: { event in
        observedEvents.append(event)
        if case .httpExchange = event { exchangeHandled.fulfill() }
      }
    )
    XCTAssertEqual(
      ready,
      ComputerReceiverReady(address: "http://192.168.1.42:49152", pairingCode: "482731")
    )

    await fulfillment(of: [exchangeHandled], timeout: 2)
    XCTAssertEqual(observedEvents.first, .ready(
      address: "http://192.168.1.42:49152",
      pairingCode: "482731"
    ))
    XCTAssertEqual(
      observedEvents.last,
      .httpExchange(ComputerReceiverHTTPExchange(method: "GET", path: "/", status: 200))
    )

    let capturedResponse = await binding.responseData()
    let response = try XCTUnwrap(capturedResponse)
    let rawResponse = String(decoding: response, as: UTF8.self)
    XCTAssertTrue(rawResponse.hasPrefix("HTTP/1.1 200 OK\r\n"))
    XCTAssertTrue(rawResponse.contains("Content-Type: text/html; charset=utf-8\r\n"))
    XCTAssertTrue(rawResponse.contains("Send audiobooks to Bookshelf"))
  }

  func testDeterministicPausedBindingDrivesProductionInterruptedUploadEvents() async throws {
    let root = temporaryRoot()
    let scenarioFinished = expectation(
      description: "The deterministic transport finished its production HTTP scenario"
    )
    let binding = E2EDeterministicComputerReceiverBinding(
      scenario: .paused,
      scenarioFinished: { scenarioFinished.fulfill() }
    )
    var observedEvents: [ComputerReceiverEvent] = []
    let server = ComputerReceiverServer(
      rootURL: root,
      bundle: .main,
      portPreference: try isolatedPortPreference(),
      binding: binding,
      credentials: ComputerReceiverCredentials(
        pairingCode: "482731",
        bearerToken: "e2e-deterministic-receiver-token"
      )
    )
    registerCleanup(for: server, root: root)

    _ = try await server.start(
      importHandler: successfulReceiverImport,
      eventHandler: { observedEvents.append($0) }
    )

    XCTAssertTrue(observedEvents.contains(.connected(clientName: "Bookshelf E2E Computer")))
    XCTAssertTrue(observedEvents.contains(.receiving(
      name: "Project Hail Mary",
      completedBytes: 734_003,
      totalBytes: 1_468_006
    )))
    XCTAssertEqual(observedEvents.last, .paused(
      name: "Project Hail Mary",
      completedBytes: 734_003,
      totalBytes: 1_468_006
    ))
    XCTAssertFalse(observedEvents.contains(where: {
      if case .completed = $0 { return true }
      return false
    }))
    await fulfillment(of: [scenarioFinished], timeout: 2)
  }

  func testCompletedScenarioIntentWithoutProductionCompletionEventRemainsReady() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let scenarioFinished = expectation(
      description: "The ready-only production exchange completed"
    )
    let readyOnlyBinding = E2EDeterministicComputerReceiverBinding(
      scenario: .ready,
      scenarioFinished: { scenarioFinished.fulfill() }
    )
    let model = makeReceiverModel(root: root.appending(path: "Model"))
    await model.restore()
    let completedIntent = try receiverConfiguration(
      arguments: ["-e2e-computer-receiver-completed"],
      launchIdentifier: "completed-intent-without-event"
    )
    let controller = ComputerReceiverController(
      launchConfiguration: completedIntent,
      applicationSupportURL: root.appending(path: "ApplicationSupport"),
      temporaryDirectory: root.appending(path: "Temporary"),
      bindingOverride: readyOnlyBinding,
      credentialsOverride: ComputerReceiverCredentials(
        pairingCode: "482731",
        bearerToken: "e2e-deterministic-receiver-token"
      )
    )

    controller.start(model: model)
    await fulfillment(of: [scenarioFinished], timeout: 2)

    XCTAssertEqual(controller.phase, .ready)
    XCTAssertEqual(controller.productionEvidence, "event=http:GET:/:status=200")
    XCTAssertTrue(model.library.books.isEmpty)
    XCTAssertTrue(model.library.importJobs.isEmpty)
    controller.stop()
  }

  private func receiverConfiguration(
    arguments: [String],
    launchIdentifier: String = "receiver-test"
  ) throws -> E2EComputerReceiverLaunchConfiguration {
    try E2EComputerReceiverLaunchConfiguration.parse(
      arguments: [
        "Player", "-e2e", "-e2e-fixture", "empty-library",
        "-e2e-computer-receiver-ready",
      ] + arguments,
      e2eLaunchConfiguration: e2eLaunch(fixture: .emptyLibrary),
      launchIdentifier: launchIdentifier
    )
  }

  private func e2eLaunch(fixture: E2EFixture) -> E2ELaunchConfiguration {
    E2ELaunchConfiguration(fixture: fixture, resetPolicy: .reset)
  }

  private func makeReceiverModel(root: URL) -> PlayerModel {
    PlayerModel(environment: PlayerEnvironment(
      persistence: InMemoryLibraryStore(snapshot: .empty),
      media: FileSystemMediaManager(rootURL: root),
      inspector: DeterministicAudioInspector(
        result: .failure(.unreadableAudio("No import should occur."))
      ),
      playback: DeterministicPlaybackController(),
      clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
      ids: DeterministicPlayerIDGenerator(values: (1...8).map {
        UUID(uuidString: String(format: "71000000-0000-0000-0000-%012d", $0))!
      })
    ))
  }

  func testFolderTransferPreservesBookNameAndRemovesIncomingCopyAfterImport() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ComputerImportStore(rootURL: root)
    let first = Data("synthetic chapter one".utf8)
    let second = Data("synthetic chapter two".utf8)

    let created = try await store.create(.init(
      entries: [
        .init(path: "Disc 1/01 Opening.mp3", byteCount: Int64(first.count)),
        .init(path: "Disc 1/02 Return.mp3", byteCount: Int64(second.count)),
      ],
      selectionKind: "folder",
      selectionName: "Project Hail Mary"
    ))
    for (index, data) in [first, second].enumerated() {
      let target = try await store.writeTarget(sessionID: created.id, index: index)
      try data.write(to: target.partialURL)
      await store.updateProgress(
        sessionID: created.id,
        fileBytes: Int64(data.count),
        completedBefore: target.completedBefore
      )
      try await store.finishWrite(
        sessionID: created.id,
        index: index,
        finalBytes: Int64(data.count)
      )
    }

    let receivedStatus = try await store.status(sessionID: created.id)
    XCTAssertEqual(receivedStatus.completedBytes, Int64(first.count + second.count))
    XCTAssertEqual(receivedStatus.totalBytes, Int64(first.count + second.count))

    let sealed = try await store.seal(sessionID: created.id)
    XCTAssertEqual(sealed.displayName, "Project Hail Mary")
    XCTAssertEqual(sealed.urls.map(\.lastPathComponent), ["Project Hail Mary"])
    XCTAssertEqual(
      try Data(contentsOf: sealed.urls[0].appending(path: "Disc 1/01 Opening.mp3")),
      first
    )

    await store.finish(sessionID: created.id, outcome: DirectImportOutcome(
      state: .completed,
      message: "Project Hail Mary added",
      addedBookCount: 1,
      cleanupIncomingFiles: true
    ))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sealed.urls[0].path))
    let status = try await store.status(sessionID: created.id)
    XCTAssertEqual(status.state, "completed")
    XCTAssertEqual(status.addedBookCount, 1)
  }

  func testRejectsEscapingDuplicateUnsupportedAndMixedArchiveSelections() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ComputerImportStore(rootURL: root)
    let requests: [ComputerImportStore.CreateRequest] = [
      .init(entries: [.init(path: "../escape.mp3", byteCount: 1)], selectionKind: "folder", selectionName: "Book"),
      .init(
        entries: [.init(path: "part.mp3", byteCount: 1), .init(path: "part.mp3", byteCount: 1)],
        selectionKind: "files",
        selectionName: nil
      ),
      .init(
        entries: [.init(path: "Part.mp3", byteCount: 1), .init(path: "párt.mp3", byteCount: 1)],
        selectionKind: "files",
        selectionName: nil
      ),
      .init(entries: [.init(path: "cover.jpg", byteCount: 1)], selectionKind: "files", selectionName: nil),
      .init(
        entries: [.init(path: "book.zip", byteCount: 1), .init(path: "part.mp3", byteCount: 1)],
        selectionKind: "files",
        selectionName: nil
      ),
    ]

    for request in requests {
      do {
        _ = try await store.create(request)
        XCTFail("Unsafe selection should be rejected")
      } catch let error as ComputerReceiverError {
        XCTAssertFalse(error.localizedDescription.isEmpty)
      }
    }
    let remaining = (try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    )) ?? []
    XCTAssertTrue(remaining.isEmpty)
  }

  func testCancelAndReceiverStopRemovePartialUploads() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ComputerImportStore(rootURL: root)
    let created = try await store.create(.init(
      entries: [.init(path: "Book.mp3", byteCount: 100)],
      selectionKind: "files",
      selectionName: "Book"
    ))
    let target = try await store.writeTarget(sessionID: created.id, index: 0)
    try Data(repeating: 7, count: 20).write(to: target.partialURL)
    try await store.cancel(sessionID: created.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.partialURL.path))

    let second = try await store.create(.init(
      entries: [.init(path: "Second.mp3", byteCount: 100)],
      selectionKind: "files",
      selectionName: "Second"
    ))
    let secondTarget = try await store.writeTarget(sessionID: second.id, index: 0)
    try Data(repeating: 8, count: 20).write(to: secondTarget.partialURL)
    await store.cleanupReceivingSessions()
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondTarget.partialURL.path))
  }

  func testCancelCannotRemoveASealedOrAcceptedImport() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ComputerImportStore(rootURL: root)
    let payload = Data("accepted audiobook".utf8)
    let created = try await store.create(.init(
      entries: [.init(path: "Book.m4b", byteCount: Int64(payload.count))],
      selectionKind: "files",
      selectionName: "Book"
    ))
    let target = try await store.writeTarget(sessionID: created.id, index: 0)
    try payload.write(to: target.partialURL)
    try await store.finishWrite(
      sessionID: created.id,
      index: 0,
      finalBytes: Int64(payload.count)
    )
    _ = try await store.seal(sessionID: created.id)

    do {
      try await store.cancel(sessionID: created.id)
      XCTFail("A sealed import must not be cancelled")
    } catch {
      // Expected.
    }
    XCTAssertEqual(try Data(contentsOf: target.finalURL), payload)

    await store.finish(sessionID: created.id, outcome: DirectImportOutcome(
      state: .completed,
      message: "Book added",
      addedBookCount: 1,
      cleanupIncomingFiles: false
    ))
    do {
      try await store.cancel(sessionID: created.id)
      XCTFail("An accepted import must not be cancelled")
    } catch {
      // Expected.
    }
    XCTAssertEqual(try Data(contentsOf: target.finalURL), payload)
    let status = try await store.status(sessionID: created.id)
    XCTAssertEqual(status.state, "completed")
  }

  func testReopeningReceiverDoesNotDeleteAnAcceptedImport() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstStore = ComputerImportStore(rootURL: root)
    let payload = Data("accepted transport file".utf8)
    let created = try await firstStore.create(.init(
      entries: [.init(path: "Book/Chapter 01.mp3", byteCount: Int64(payload.count))],
      selectionKind: "folder",
      selectionName: "Book"
    ))
    let target = try await firstStore.writeTarget(sessionID: created.id, index: 0)
    try payload.write(to: target.partialURL)
    try await firstStore.finishWrite(
      sessionID: created.id,
      index: 0,
      finalBytes: Int64(payload.count)
    )
    _ = try await firstStore.seal(sessionID: created.id)
    let acceptedFile = target.finalURL

    _ = ComputerImportStore(rootURL: root)

    XCTAssertEqual(try Data(contentsOf: acceptedFile), payload)
    await firstStore.finish(sessionID: created.id, outcome: DirectImportOutcome(
      state: .completed,
      message: "Book added",
      addedBookCount: 1,
      cleanupIncomingFiles: true
    ))
    XCTAssertFalse(FileManager.default.fileExists(atPath: acceptedFile.path))
  }

  func testInterruptedFileResumesAtServerConfirmedOffsetWithoutDuplicatingBytes() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ComputerImportStore(rootURL: root)
    let payload = Data("0123456789abcdef".utf8)
    let firstChunk = payload.prefix(6)
    let created = try await store.create(.init(
      entries: [.init(path: "Book.m4b", byteCount: Int64(payload.count))],
      selectionKind: "files",
      selectionName: "Book"
    ))

    let firstTarget = try await store.writeTarget(sessionID: created.id, index: 0)
    try Data(firstChunk).write(to: firstTarget.partialURL)
    await store.abandonWrite(sessionID: created.id, index: 0)

    let paused = try await store.status(sessionID: created.id)
    XCTAssertEqual(paused.fileOffsets, [Int64(firstChunk.count)])
    XCTAssertEqual(paused.completedBytes, Int64(firstChunk.count))

    let resumed = try await store.writeTarget(
      sessionID: created.id,
      index: 0,
      requestedOffset: Int64(firstChunk.count)
    )
    XCTAssertEqual(resumed.startingOffset, Int64(firstChunk.count))
    let handle = try FileHandle(forWritingTo: resumed.partialURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: payload.dropFirst(firstChunk.count))
    try handle.close()
    try await store.finishWrite(
      sessionID: created.id,
      index: 0,
      finalBytes: Int64(payload.count)
    )

    let sealed = try await store.seal(sessionID: created.id)
    XCTAssertEqual(try Data(contentsOf: sealed.urls[0]), payload)
  }

  func testResumeOffsetMustMatchDurableBytesAndFailedClaimsReleaseTheWriter() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ComputerImportStore(rootURL: root)
    let created = try await store.create(.init(
      entries: [.init(path: "Book.m4b", byteCount: 8)],
      selectionKind: "files",
      selectionName: "Book"
    ))

    do {
      _ = try await store.writeTarget(sessionID: created.id, index: 0, requestedOffset: 3)
      XCTFail("A browser-only offset must not be trusted")
    } catch let error as ComputerReceiverError {
      XCTAssertEqual(error.httpStatus, 409)
      XCTAssertTrue(error.localizedDescription.contains("byte 0"))
    }

    let target = try await store.writeTarget(sessionID: created.id, index: 0)
    do {
      _ = try await store.writeTarget(sessionID: created.id, index: 0)
      XCTFail("Two requests must not write the same partial file")
    } catch let error as ComputerReceiverError {
      XCTAssertEqual(error.httpStatus, 409)
    }
    await store.abandonWrite(sessionID: created.id, index: 0)
    XCTAssertEqual(target.startingOffset, 0)
    _ = try await store.writeTarget(sessionID: created.id, index: 0)
    await store.abandonWrite(sessionID: created.id, index: 0)
  }

  func testLocalHTTPFlowServesSveltePairsUploadsAndCompletes() async throws {
    let root = temporaryRoot()
    let importReceived = expectation(description: "Receiver handed the completed import to the app")
    let capture = ReceiverImportCapture(receivedSignal: importReceived)
    let server = ComputerReceiverServer(
      rootURL: root,
      bundle: .main,
      portPreference: try isolatedPortPreference()
    )
    registerCleanup(for: server, root: root)
    let ready = try await server.start(
      importHandler: { urls in await capture.importURLs(urls) },
      eventHandler: { _ in }
    )
    let port = try XCTUnwrap(URL(string: ready.address)?.port)
    let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))

    let (page, pageResponse) = try await URLSession.shared.data(from: baseURL)
    XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Send audiobooks to Bookshelf"))

    let pairBody = try JSONEncoder().encode(["code": ready.pairingCode])
    let (pairData, pairResponse) = try await request(
      baseURL.appending(path: "api/pair"),
      method: "POST",
      body: pairBody,
      headers: ["Content-Type": "application/json"]
    )
    XCTAssertEqual(pairResponse.statusCode, 200)
    let pair = try JSONDecoder().decode(PairResponse.self, from: pairData)

    let audio = Data("synthetic direct receiver audio".utf8)
    let manifest = try JSONEncoder().encode(ComputerImportStore.CreateRequest(
      entries: [.init(path: "Chapter 01.mp3", byteCount: Int64(audio.count))],
      selectionKind: "folder",
      selectionName: "HTTP Test Book"
    ))
    let auth = ["Authorization": "Bearer \(pair.token)"]
    let (createData, createResponse) = try await request(
      baseURL.appending(path: "api/imports"),
      method: "POST",
      body: manifest,
      headers: auth.merging(["Content-Type": "application/json"]) { current, _ in current }
    )
    XCTAssertEqual(createResponse.statusCode, 201)
    let created = try JSONDecoder().decode(CreateResponse.self, from: createData)

    let (_, uploadResponse) = try await request(
      baseURL.appending(path: "api/imports/\(created.id)/files/0"),
      method: "PUT",
      body: audio,
      headers: auth.merging(["Content-Type": "application/octet-stream"]) { current, _ in current }
    )
    XCTAssertEqual(uploadResponse.statusCode, 200)
    let (_, completeResponse) = try await request(
      baseURL.appending(path: "api/imports/\(created.id)/complete"),
      method: "POST",
      body: nil,
      headers: auth
    )
    XCTAssertEqual(completeResponse.statusCode, 202)

    await fulfillment(of: [importReceived], timeout: 2)
    let receivedData = await capture.receivedData
    let receivedFolderName = await capture.receivedFolderName
    XCTAssertEqual(receivedData, audio)
    XCTAssertEqual(receivedFolderName, "HTTP Test Book")

    let (statusData, statusResponse) = try await request(
      baseURL.appending(path: "api/imports/\(created.id)"),
      method: "GET",
      body: nil,
      headers: auth
    )
    XCTAssertEqual(statusResponse.statusCode, 200)
    let status = try JSONDecoder().decode(StatusResponse.self, from: statusData)
    XCTAssertEqual(status.state, "completed")
    XCTAssertEqual(status.completedBytes, Int64(audio.count))
    XCTAssertEqual(status.totalBytes, Int64(audio.count))
    XCTAssertEqual(status.fileOffsets, [Int64(audio.count)])
  }

  func testWebKitBrowserLoadsReceiverAndCompletesARealLocalHTTPImport() async throws {
    let root = temporaryRoot()
    let importReceived = expectation(
      description: "Browser upload reached the app import handler"
    )
    let capture = ReceiverImportCapture(receivedSignal: importReceived)
    let server = ComputerReceiverServer(
      rootURL: root,
      bundle: .main,
      portPreference: try isolatedPortPreference()
    )
    registerCleanup(for: server, root: root)
    let ready = try await server.start(
      importHandler: { urls in await capture.importURLs(urls) },
      eventHandler: { _ in }
    )
    var pageComponents = try XCTUnwrap(URLComponents(string: ready.address))
    // This browser is running inside the same process as the receiver. Using the
    // advertised LAN address makes a fresh simulator gate the navigation on the
    // local-network privacy prompt, while loopback exercises the identical live
    // HTTP server without depending on simulator permission state.
    pageComponents.host = "127.0.0.1"
    let pageURL = try XCTUnwrap(pageComponents.url)
    let webView = WKWebView(frame: .zero)
    let pageLoaded = expectation(description: "WebKit loaded the production receiver page")
    let navigation = ReceiverWebNavigationDelegate(pageLoaded: pageLoaded)
    defer { withExtendedLifetime(navigation) {} }
    webView.navigationDelegate = navigation
    webView.load(URLRequest(url: pageURL))
    await fulfillment(of: [pageLoaded], timeout: 2)

    let journeyCompleted = expectation(description: "Browser completed the HTTP transfer")
    var browserResult: [String: String]?
    let script = """
        const pairResponse = await fetch('/api/pair', {
          method: 'POST',
          headers: {'Content-Type': 'application/json', 'X-Player-Client-Name': 'WebKit Test'},
          body: JSON.stringify({code: '\(ready.pairingCode)'})
        });
        const pair = await pairResponse.json();
        if (!pairResponse.ok) throw new Error(pair.message);
        const bytes = new TextEncoder().encode('synthetic direct receiver audio');
        const auth = {'Authorization': `Bearer ${pair.token}`};
        const createResponse = await fetch('/api/imports', {
          method: 'POST',
          headers: {...auth, 'Content-Type': 'application/json'},
          body: JSON.stringify({
            entries: [{path: 'Chapter 01.mp3', byteCount: bytes.byteLength}],
            selectionKind: 'folder',
            selectionName: 'HTTP Test Book'
          })
        });
        const created = await createResponse.json();
        if (!createResponse.ok) throw new Error(created.message);
        const uploadResponse = await fetch(`/api/imports/${created.id}/files/0`, {
          method: 'PUT',
          headers: {
            ...auth,
            'Content-Type': 'application/octet-stream',
            'X-Player-Upload-Offset': '0'
          },
          body: bytes
        });
        if (!uploadResponse.ok) throw new Error((await uploadResponse.json()).message);
        const completeResponse = await fetch(`/api/imports/${created.id}/complete`, {
          method: 'POST', headers: auth
        });
        if (!completeResponse.ok) throw new Error((await completeResponse.json()).message);
        return {id: created.id, token: pair.token};
      """
    webView.callAsyncJavaScript(
      script,
      arguments: [:],
      in: nil,
      in: .page
    ) { result in
      switch result {
      case .success(let value): browserResult = value as? [String: String]
      case .failure(let error): XCTFail("Browser journey failed: \(error)")
      }
      journeyCompleted.fulfill()
    }
    await fulfillment(of: [journeyCompleted, importReceived], timeout: 2)
    let result = try XCTUnwrap(browserResult)

    let statusLoaded = expectation(description: "Browser observed the app completion state")
    var terminalState: String?
    webView.callAsyncJavaScript(
      """
        const cancellation = await fetch('/api/imports/\(result["id"] ?? "")', {
          method: 'DELETE',
          headers: {'Authorization': 'Bearer \(result["token"] ?? "")'}
        });
        const response = await fetch('/api/imports/\(result["id"] ?? "")', {
          headers: {'Authorization': 'Bearer \(result["token"] ?? "")'}
        });
        return `${cancellation.status}:${(await response.json()).state}`;
        """,
      arguments: [:],
      in: nil,
      in: .page
    ) { result in
      switch result {
      case .success(let value): terminalState = value as? String
      case .failure(let error): XCTFail("Browser status request failed: \(error)")
      }
      statusLoaded.fulfill()
    }
    await fulfillment(of: [statusLoaded], timeout: 2)
    XCTAssertEqual(terminalState, "409:completed")
    let receivedData = await capture.receivedData
    XCTAssertEqual(receivedData, Data("synthetic direct receiver audio".utf8))
  }

  func testReceiverReusesItsLastBoundPortWhenAvailable() async throws {
    let suiteName = "ComputerReceiverPortPreference-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    let preference = ComputerReceiverPortPreference(
      userDefaults: defaults,
      key: "preferredPort",
      defaultPort: nil
    )
    let firstRoot = temporaryRoot()
    let secondRoot = temporaryRoot()

    let firstServer = ComputerReceiverServer(
      rootURL: firstRoot,
      bundle: .main,
      portPreference: preference
    )
    registerCleanup(for: firstServer, root: firstRoot)
    let firstReady = try await firstServer.start(
      importHandler: { _ in
        DirectImportOutcome(
          state: .completed,
          message: "Imported",
          addedBookCount: 1,
          cleanupIncomingFiles: true
        )
      },
      eventHandler: { _ in }
    )
    let firstPort = try XCTUnwrap(URL(string: firstReady.address)?.port)
    let firstCode = firstReady.pairingCode
    let firstBaseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(firstPort)"))
    let (firstPairData, firstPairResponse) = try await request(
      firstBaseURL.appending(path: "api/pair"),
      method: "POST",
      body: try JSONEncoder().encode(["code": firstCode]),
      headers: ["Content-Type": "application/json"]
    )
    XCTAssertEqual(firstPairResponse.statusCode, 200)
    let firstPair = try JSONDecoder().decode(PairResponse.self, from: firstPairData)
    await firstServer.stop()

    let secondServer = ComputerReceiverServer(
      rootURL: secondRoot,
      bundle: .main,
      portPreference: preference
    )
    registerCleanup(for: secondServer, root: secondRoot)
    let secondReady = try await secondServer.start(
      importHandler: { _ in
        DirectImportOutcome(
          state: .completed,
          message: "Imported",
          addedBookCount: 1,
          cleanupIncomingFiles: true
        )
      },
      eventHandler: { _ in }
    )
    let secondPort = try XCTUnwrap(URL(string: secondReady.address)?.port)
    let secondCode = secondReady.pairingCode

    XCTAssertEqual(secondPort, firstPort)
    XCTAssertNotEqual(secondCode, firstCode)
    let secondBaseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(secondPort)"))
    let (_, expiredResponse) = try await request(
      secondBaseURL.appending(
        path: "api/imports/00000000-0000-0000-0000-000000000001"
      ),
      method: "GET",
      body: nil,
      headers: ["Authorization": "Bearer \(firstPair.token)"]
    )
    XCTAssertEqual(expiredResponse.statusCode, 401)
    let (_, secondPairResponse) = try await request(
      secondBaseURL.appending(path: "api/pair"),
      method: "POST",
      body: try JSONEncoder().encode(["code": secondCode]),
      headers: ["Content-Type": "application/json"]
    )
    XCTAssertEqual(secondPairResponse.statusCode, 200)
    await secondServer.stop()
  }

  func testReceiverFallsBackFromAnUnavailablePreferredPortAndPersistsTheReplacement() async throws {
    let suiteName = "ComputerReceiverPortFallback-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    let blockerPreference = ComputerReceiverPortPreference(
      userDefaults: defaults,
      key: "blockerPort",
      defaultPort: nil
    )
    let receiverPreference = ComputerReceiverPortPreference(
      userDefaults: defaults,
      key: "receiverPort",
      defaultPort: nil
    )
    let blockerRoot = temporaryRoot()
    let fallbackRoot = temporaryRoot()
    let reuseRoot = temporaryRoot()

    let blocker = ComputerReceiverServer(
      rootURL: blockerRoot,
      bundle: .main,
      portPreference: blockerPreference
    )
    addTeardownBlock {
      await blocker.stop()
      try FileManager.default.removeItem(at: blockerRoot)
    }
    let blockerReady = try await blocker.start(
      importHandler: successfulReceiverImport,
      eventHandler: { _ in }
    )
    let unavailablePort = try XCTUnwrap(URL(string: blockerReady.address)?.port)
    receiverPreference.recordBoundPort(UInt16(unavailablePort))

    let fallbackServer = ComputerReceiverServer(
      rootURL: fallbackRoot,
      bundle: .main,
      portPreference: receiverPreference
    )
    addTeardownBlock {
      await fallbackServer.stop()
      try FileManager.default.removeItem(at: fallbackRoot)
    }
    let fallbackReady = try await fallbackServer.start(
      importHandler: successfulReceiverImport,
      eventHandler: { _ in }
    )
    let fallbackPort = try XCTUnwrap(URL(string: fallbackReady.address)?.port)
    XCTAssertNotEqual(fallbackPort, unavailablePort)
    XCTAssertEqual(receiverPreference.preferredPort(), UInt16(fallbackPort))

    await fallbackServer.stop()
    await blocker.stop()

    let reuseServer = ComputerReceiverServer(
      rootURL: reuseRoot,
      bundle: .main,
      portPreference: receiverPreference
    )
    addTeardownBlock {
      await reuseServer.stop()
      try FileManager.default.removeItem(at: reuseRoot)
    }
    let reuseReady = try await reuseServer.start(
      importHandler: successfulReceiverImport,
      eventHandler: { _ in }
    )
    let reusedPort = try XCTUnwrap(URL(string: reuseReady.address)?.port)
    await reuseServer.stop()

    XCTAssertEqual(reusedPort, fallbackPort)
  }

  func testInterruptedHTTPRequestResumesFromDurableServerOffset() async throws {
    let root = temporaryRoot()
    let importReceived = expectation(description: "Receiver handed the resumed import to the app")
    let uploadPaused = expectation(description: "Receiver durably paused the interrupted upload")
    let capture = ReceiverImportCapture(receivedSignal: importReceived)
    let server = ComputerReceiverServer(
      rootURL: root,
      bundle: .main,
      portPreference: try isolatedPortPreference()
    )
    registerCleanup(for: server, root: root)
    let ready = try await server.start(
      importHandler: { urls in await capture.importURLs(urls) },
      eventHandler: { event in
        if case .paused = event { uploadPaused.fulfill() }
      }
    )
    let port = try XCTUnwrap(URL(string: ready.address)?.port)
    let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
    let pairBody = try JSONEncoder().encode(["code": ready.pairingCode])
    let (pairData, _) = try await request(
      baseURL.appending(path: "api/pair"),
      method: "POST",
      body: pairBody,
      headers: ["Content-Type": "application/json"]
    )
    let pair = try JSONDecoder().decode(PairResponse.self, from: pairData)
    let auth = ["Authorization": "Bearer \(pair.token)"]
    let audio = Data("synthetic direct receiver audio".utf8)
    let manifest = try JSONEncoder().encode(ComputerImportStore.CreateRequest(
      entries: [.init(path: "Chapter 01.mp3", byteCount: Int64(audio.count))],
      selectionKind: "folder",
      selectionName: "HTTP Test Book"
    ))
    let (createData, _) = try await request(
      baseURL.appending(path: "api/imports"),
      method: "POST",
      body: manifest,
      headers: auth.merging(["Content-Type": "application/json"]) { current, _ in current }
    )
    let created = try JSONDecoder().decode(CreateResponse.self, from: createData)
    let prefix = Data(audio.prefix(11))

    try await sendInterruptedUpload(
      port: UInt16(port),
      path: "/api/imports/\(created.id)/files/0",
      token: pair.token,
      advertisedLength: audio.count,
      bodyPrefix: prefix
    )

    await fulfillment(of: [uploadPaused], timeout: 2)
    let (pausedData, pausedResponse) = try await request(
      baseURL.appending(path: "api/imports/\(created.id)"),
      method: "GET",
      body: nil,
      headers: auth
    )
    XCTAssertEqual(pausedResponse.statusCode, 200)
    let pausedStatus = try JSONDecoder().decode(StatusResponse.self, from: pausedData)
    XCTAssertEqual(pausedStatus.fileOffsets, [Int64(prefix.count)])
    XCTAssertEqual(pausedStatus.completedBytes, Int64(prefix.count))

    let remainder = Data(audio.dropFirst(prefix.count))
    let (_, resumedResponse) = try await request(
      baseURL.appending(path: "api/imports/\(created.id)/files/0"),
      method: "PUT",
      body: remainder,
      headers: auth.merging([
        "Content-Type": "application/octet-stream",
        "X-Player-Upload-Offset": String(prefix.count),
      ]) { current, _ in current }
    )
    XCTAssertEqual(resumedResponse.statusCode, 200)
    _ = try await request(
      baseURL.appending(path: "api/imports/\(created.id)/complete"),
      method: "POST",
      body: nil,
      headers: auth
    )
    await fulfillment(of: [importReceived], timeout: 2)
    let receivedData = await capture.receivedData
    XCTAssertEqual(receivedData, audio)
  }

  func testAcceptedHTTPImportSurvivesReceiverStop() async throws {
    let root = temporaryRoot()
    let importStarted = expectation(description: "Accepted import started")
    let importFinished = expectation(description: "Accepted import finished after receiver stopped")
    let capture = ControlledReceiverImportCapture(
      startedSignal: importStarted,
      finishedSignal: importFinished
    )
    let server = ComputerReceiverServer(
      rootURL: root,
      bundle: .main,
      portPreference: try isolatedPortPreference()
    )
    addTeardownBlock {
      await capture.releaseImport()
      await server.stop()
      try? FileManager.default.removeItem(at: root)
    }
    let ready = try await server.start(
      importHandler: { urls in await capture.importURLs(urls) },
      eventHandler: { _ in }
    )
    let port = try XCTUnwrap(URL(string: ready.address)?.port)
    let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
    let pairBody = try JSONEncoder().encode(["code": ready.pairingCode])
    let (pairData, _) = try await request(
      baseURL.appending(path: "api/pair"),
      method: "POST",
      body: pairBody,
      headers: ["Content-Type": "application/json"]
    )
    let pair = try JSONDecoder().decode(PairResponse.self, from: pairData)
    let auth = ["Authorization": "Bearer \(pair.token)"]
    let audio = Data("slow durable import".utf8)
    let manifest = try JSONEncoder().encode(ComputerImportStore.CreateRequest(
      entries: [.init(path: "Chapter.mp3", byteCount: Int64(audio.count))],
      selectionKind: "folder",
      selectionName: "Slow Book"
    ))
    let (createData, _) = try await request(
      baseURL.appending(path: "api/imports"),
      method: "POST",
      body: manifest,
      headers: auth.merging(["Content-Type": "application/json"]) { current, _ in current }
    )
    let created = try JSONDecoder().decode(CreateResponse.self, from: createData)
    _ = try await request(
      baseURL.appending(path: "api/imports/\(created.id)/files/0"),
      method: "PUT",
      body: audio,
      headers: auth
    )
    let (_, completeResponse) = try await request(
      baseURL.appending(path: "api/imports/\(created.id)/complete"),
      method: "POST",
      body: nil,
      headers: auth
    )
    XCTAssertEqual(completeResponse.statusCode, 202)

    await fulfillment(of: [importStarted], timeout: 2)
    await server.stop()
    await capture.releaseImport()
    await fulfillment(of: [importFinished], timeout: 2)
    let finished = await capture.finished
    let wasCancelled = await capture.wasCancelled
    XCTAssertTrue(finished)
    XCTAssertFalse(wasCancelled)
  }

  func testReceiverOwnershipLeavesNoPortDefaultsOrRootsInForwardAndReverseOrder() async throws {
    var reusablePort: UInt16?

    for identifier in [1, 2, 3, 3, 2, 1] {
      let suiteName = "ComputerReceiverOwnership-\(identifier)-\(UUID().uuidString)"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
      let key = "preferredPort"
      let preference = ComputerReceiverPortPreference(
        userDefaults: defaults,
        key: key,
        defaultPort: reusablePort
      )
      let root = temporaryRoot()
      let server = ComputerReceiverServer(
        rootURL: root,
        bundle: .main,
        portPreference: preference
      )
      registerCleanup(for: server, root: root)
      addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

      let ready = try await server.start(
        importHandler: successfulReceiverImport,
        eventHandler: { _ in }
      )
      let boundPort = UInt16(try XCTUnwrap(URL(string: ready.address)?.port))
      if let reusablePort { XCTAssertEqual(boundPort, reusablePort) }
      else { reusablePort = boundPort }

      await server.stop()
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suiteName)

      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
      XCTAssertNil(defaults.object(forKey: key))
      XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
    }
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "ComputerReceiverTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }

  private func isolatedPortPreference() throws -> ComputerReceiverPortPreference {
    let suiteName = "ComputerReceiverPortPreference-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    return ComputerReceiverPortPreference(
      userDefaults: defaults,
      key: "preferredPort",
      defaultPort: nil
    )
  }

  private func registerCleanup(for server: ComputerReceiverServer, root: URL) {
    addTeardownBlock {
      await server.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func request(
    _ url: URL,
    method: String,
    body: Data?,
    headers: [String: String]
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, try XCTUnwrap(response as? HTTPURLResponse))
  }

  private var successfulReceiverImport: ComputerReceiverServer.ImportHandler {
    { _ in
      DirectImportOutcome(
        state: .completed,
        message: "Imported",
        addedBookCount: 1,
        cleanupIncomingFiles: true
      )
    }
  }

  private func sendInterruptedUpload(
    port: UInt16,
    path: String,
    token: String,
    advertisedLength: Int,
    bodyPrefix: Data
  ) async throws {
    let connection = NWConnection(
      host: NWEndpoint.Host("127.0.0.1"),
      port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)),
      using: .tcp
    )
    connection.start(queue: DispatchQueue(label: "ComputerReceiverTests.interrupted-upload"))
    let headers = """
      PUT \(path) HTTP/1.1\r
      Host: 127.0.0.1:\(port)\r
      Authorization: Bearer \(token)\r
      Content-Type: application/octet-stream\r
      X-Player-Upload-Offset: 0\r
      Content-Length: \(advertisedLength)\r
      Connection: close\r
      \r

      """
    var requestData = Data(headers.utf8)
    requestData.append(bodyPrefix)
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(content: requestData, isComplete: false, completion: .contentProcessed {
        error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      })
    }
    connection.cancel()
  }
}

private struct PairResponse: Decodable { var token: String }
private struct CreateResponse: Decodable { var id: String }
private struct StatusResponse: Decodable {
  var state: String
  var completedBytes: Int64
  var totalBytes: Int64
  var fileOffsets: [Int64]
}

private actor ReceiverImportCapture {
  private let receivedSignal: XCTestExpectation
  var receivedData: Data?
  var receivedFolderName: String?

  init(receivedSignal: XCTestExpectation) {
    self.receivedSignal = receivedSignal
  }

  func importURLs(_ urls: [URL]) -> DirectImportOutcome {
    receivedFolderName = urls.first?.lastPathComponent
    if let first = urls.first?.appending(path: "Chapter 01.mp3") {
      receivedData = try? Data(contentsOf: first)
    }
    receivedSignal.fulfill()
    return DirectImportOutcome(
      state: .completed,
      message: "HTTP Test Book added",
      addedBookCount: 1,
      cleanupIncomingFiles: true
    )
  }
}

private actor ControlledReceiverImportCapture {
  private let startedSignal: XCTestExpectation
  private let finishedSignal: XCTestExpectation
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var isReleased = false
  var finished = false
  var wasCancelled = false

  init(startedSignal: XCTestExpectation, finishedSignal: XCTestExpectation) {
    self.startedSignal = startedSignal
    self.finishedSignal = finishedSignal
  }

  func importURLs(_ urls: [URL]) async -> DirectImportOutcome {
    startedSignal.fulfill()
    await waitUntilReleased()
    wasCancelled = Task.isCancelled
    finished = true
    finishedSignal.fulfill()
    return DirectImportOutcome(
      state: .completed,
      message: "Slow Book added",
      addedBookCount: 1,
      cleanupIncomingFiles: true
    )
  }

  func releaseImport() {
    isReleased = true
    releaseContinuation?.resume()
    releaseContinuation = nil
  }

  private func waitUntilReleased() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }
}

@MainActor
private final class ReceiverWebNavigationDelegate: NSObject, WKNavigationDelegate {
  private let pageLoaded: XCTestExpectation

  init(pageLoaded: XCTestExpectation) {
    self.pageLoaded = pageLoaded
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    pageLoaded.fulfill()
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: any Error
  ) {
    XCTFail("WebKit failed to load the receiver: \(error)")
    pageLoaded.fulfill()
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    XCTFail("WebKit failed to begin loading the receiver: \(error)")
    pageLoaded.fulfill()
  }
}
