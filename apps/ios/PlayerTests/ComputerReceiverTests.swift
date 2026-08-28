import XCTest
import Network
@testable import Player

@MainActor
final class ComputerReceiverTests: XCTestCase {
  func testCanonicalReceiverScenariosAndMirroringTipOverridesParseExactly() throws {
    let production = try E2EComputerReceiverLaunchConfiguration.parse(arguments: [
      "Player", "-e2e-computer-receiver-ready", "-e2e-show-mirroring-tip",
    ])
    XCTAssertNil(production.scenario)
    XCTAssertEqual(production.mirroringTip, .automatic)

    let ready = try receiverConfiguration(arguments: [])
    XCTAssertEqual(ready.scenario, .ready)
    XCTAssertEqual(ready.mirroringTip, .automatic)

    let phases: [(String, E2EComputerReceiverLaunchConfiguration.Scenario)] = [
      ("-e2e-mirroring-drop-progress", .dropProgress),
      ("-e2e-computer-receiver-completed", .completed),
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
      ["-e2e-computer-receiver-paused", "-e2e-computer-receiver-paused"],
      ["-e2e-mirroring-drop-progress", "-e2e-computer-receiver-completed"],
      ["-e2e-mirroring-drop-progress", "-e2e-computer-receiver-paused"],
      ["-e2e-computer-receiver-completed", "-e2e-computer-receiver-paused"],
    ]

    for additionalArguments in invalidArguments {
      let arguments = ["Player", "-e2e", "-e2e-computer-receiver-ready"]
        + additionalArguments
      XCTAssertThrowsError(
        try E2EComputerReceiverLaunchConfiguration.parse(arguments: arguments),
        "Expected invalid receiver scenario to be rejected: \(arguments)"
      )
    }

    for phase in [
      "-e2e-mirroring-drop-progress",
      "-e2e-computer-receiver-completed",
      "-e2e-computer-receiver-paused",
    ] {
      XCTAssertThrowsError(
        try E2EComputerReceiverLaunchConfiguration.parse(arguments: ["Player", "-e2e", phase])
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
    XCTAssertTrue(rawResponse.contains("Send audiobooks to Player"))
  }

  private func receiverConfiguration(
    arguments: [String]
  ) throws -> E2EComputerReceiverLaunchConfiguration {
    try E2EComputerReceiverLaunchConfiguration.parse(arguments: [
      "Player", "-e2e", "-e2e-computer-receiver-ready",
    ] + arguments)
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
    XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Send audiobooks to Player"))

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
    await secondServer.stop()

    XCTAssertEqual(secondPort, firstPort)
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
