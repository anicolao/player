import UniformTypeIdentifiers
import XCTest
@testable import Player

final class ShareProviderImportCoordinatorTests: XCTestCase {
  func testRejectsMixedUnsupportedSelectionBeforeRequestingAnyProvider() throws {
    let requests = LockedCounter()
    let supported = provider(
      types: [try XCTUnwrap(UTType(filenameExtension: "mp3")?.identifier)],
      name: "Chapter.mp3",
      requests: requests
    )
    let unsupported = provider(
      types: [UTType.plainText.identifier],
      name: "Notes.txt",
      requests: requests
    )

    XCTAssertThrowsError(
      try ShareProviderImportCoordinator().selections(from: [supported, unsupported])
    ) { error in
      XCTAssertEqual(error as? ShareProviderImportError, .mixedUnsupportedSelection)
    }
    XCTAssertEqual(requests.value, 0)
  }

  func testFallsBackToTemporaryRepresentationAndCopiesBeforeCallbackReturns() async throws {
    let root = temporaryRoot("share-provider-temporary")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "Ephemeral.mp3")
    let payload = Data("ephemeral share provider bytes".utf8)
    try payload.write(to: source)
    let inPlaceError = NSError(domain: "ShareFixture", code: 11)
    let item = ShareImportItemProvider(
      registeredTypeIdentifiers: [try XCTUnwrap(UTType(filenameExtension: "mp3")?.identifier)],
      suggestedName: "Ephemeral.mp3",
      loadInPlace: { _, completion in
        completion(nil, false, inPlaceError)
        return Progress(totalUnitCount: 1)
      },
      loadFile: { _, completion in
        completion(source, nil)
        try? FileManager.default.removeItem(at: source)
        return Progress(totalUnitCount: 1)
      }
    )
    let coordinator = ShareProviderImportCoordinator()
    let selections = try coordinator.selections(from: [item])
    let writer = try AppGroupImportHandoffWriter(containerURL: root)

    try await coordinator.copy(selections, to: writer) { _, _ in }
    let id = try writer.publish()

    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    let request = root
      .appending(path: PlayerAppGroup.importQueueDirectoryName)
      .appending(path: "Pending")
      .appending(path: id.uuidString.lowercased())
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let handoff = try decoder.decode(
      ShareImportHandoff.self,
      from: Data(contentsOf: request.appending(path: "handoff.json"))
    )
    XCTAssertEqual(handoff.items.map(\.originalFilename), ["Ephemeral.mp3"])
    XCTAssertEqual(
      try Data(contentsOf: request.appending(path: try XCTUnwrap(handoff.items.first?.relativePath))),
      payload
    )
  }

  func testPreservesTemporaryProviderFailureAfterInPlaceFallback() async throws {
    let root = temporaryRoot("share-provider-error")
    defer { try? FileManager.default.removeItem(at: root) }
    let inPlaceError = NSError(domain: "ShareFixture", code: 21)
    let temporaryError = NSError(
      domain: NSItemProvider.errorDomain,
      code: -1,
      userInfo: [NSLocalizedDescriptionKey: "The iCloud item is offline."]
    )
    let item = ShareImportItemProvider(
      registeredTypeIdentifiers: [try XCTUnwrap(UTType(filenameExtension: "m4b")?.identifier)],
      suggestedName: "Offline.m4b",
      loadInPlace: { _, completion in
        completion(nil, false, inPlaceError)
        return Progress(totalUnitCount: 1)
      },
      loadFile: { _, completion in
        completion(nil, temporaryError)
        return Progress(totalUnitCount: 1)
      }
    )
    let coordinator = ShareProviderImportCoordinator()
    let selections = try coordinator.selections(from: [item])
    let writer = try AppGroupImportHandoffWriter(containerURL: root)
    defer { writer.cancel() }

    do {
      try await coordinator.copy(selections, to: writer) { _, _ in }
      XCTFail("An offline temporary provider must fail")
    } catch let error as NSError {
      XCTAssertEqual(error.domain, temporaryError.domain)
      XCTAssertEqual(error.code, temporaryError.code)
      XCTAssertEqual(error.localizedDescription, temporaryError.localizedDescription)
    }
  }

  func testTaskCancellationCancelsProviderProgressAndPublishesNothing() async throws {
    let root = temporaryRoot("share-provider-cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    let requested = expectation(description: "provider request started")
    let providerProgress = Progress(totalUnitCount: 1)
    let item = ShareImportItemProvider(
      registeredTypeIdentifiers: [try XCTUnwrap(UTType(filenameExtension: "m4a")?.identifier)],
      suggestedName: "Pending.m4a",
      loadInPlace: { _, _ in
        requested.fulfill()
        return providerProgress
      },
      loadFile: { _, _ in
        XCTFail("Cancellation must not start a fallback request")
        return Progress(totalUnitCount: 1)
      }
    )
    let coordinator = ShareProviderImportCoordinator()
    let selections = try coordinator.selections(from: [item])
    let writer = try AppGroupImportHandoffWriter(containerURL: root)
    let operation = Task {
      try await coordinator.copy(selections, to: writer) { _, _ in }
    }
    await fulfillment(of: [requested], timeout: 2)

    operation.cancel()
    do {
      try await operation.value
      XCTFail("The cancelled provider operation must throw")
    } catch is CancellationError {}
    writer.cancel()

    XCTAssertTrue(providerProgress.isCancelled)
    let queue = root.appending(path: PlayerAppGroup.importQueueDirectoryName)
    let incoming = queue.appending(path: "Incoming")
    let pending = queue.appending(path: "Pending")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: incoming.path), [])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pending.path), [])
  }

  func testSanitizesProviderFilenameWithoutLosingSupportedExtension() throws {
    let metadata = try ShareProviderImportCoordinator.metadata(
      sourceURL: URL(filePath: "/tmp/source.mp3"),
      typeIdentifier: try XCTUnwrap(UTType(filenameExtension: "mp3")?.identifier),
      suggestedName: "../bad:\u{0001}name.mp3",
      index: 0
    )

    XCTAssertEqual(metadata.fileExtension, "mp3")
    XCTAssertEqual(metadata.originalFilename, "bad--name.mp3")
    XCTAssertFalse(metadata.originalFilename.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0)
    })
  }

  private func provider(
    types: [String],
    name: String,
    requests: LockedCounter
  ) -> ShareImportItemProvider {
    ShareImportItemProvider(
      registeredTypeIdentifiers: types,
      suggestedName: name,
      loadInPlace: { _, _ in
        requests.increment()
        return Progress(totalUnitCount: 1)
      },
      loadFile: { _, _ in
        requests.increment()
        return Progress(totalUnitCount: 1)
      }
    )
  }

  private func temporaryRoot(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "player-\(suffix)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}
