import SwiftUI
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import Player

@MainActor
final class MirroringDropAdapterTests: XCTestCase {
  func testMaterializesFileProviderWithoutSecondPhysicalCopyAndCleansSession() async throws {
    let fixtureRoot = temporaryRoot("file-fixture")
    let receiverRoot = temporaryRoot("file-receiver")
    defer {
      try? FileManager.default.removeItem(at: fixtureRoot)
      try? FileManager.default.removeItem(at: receiverRoot)
    }
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let source = fixtureRoot.appending(path: "Chapter 01.mp3")
    let payload = Data("mirroring file provider".utf8)
    try payload.write(to: source)
    let provider = fileProvider(
      source,
      typeIdentifier: try XCTUnwrap(UTType(filenameExtension: "mp3")?.identifier),
      suggestedName: "Chapter 01.mp3"
    )
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)
    var updates: [MirroringDropProgress] = []

    let materialized = try await adapter.materialize([provider]) { updates.append($0) }

    let received = try XCTUnwrap(materialized.selectionURLs.first)
    XCTAssertEqual(received.lastPathComponent, "Chapter 01.mp3")
    XCTAssertEqual(try Data(contentsOf: received), payload)
    XCTAssertEqual(updates.map(\.completedItems), [0, 1])
    let attributes = try FileManager.default.attributesOfItem(atPath: received.path)
    XCTAssertGreaterThanOrEqual(
      (attributes[.referenceCount] as? NSNumber)?.intValue ?? 0,
      2,
      "A same-volume provider file should be retained with a hard link"
    )

    adapter.cleanup(materialized)
    XCTAssertFalse(FileManager.default.fileExists(atPath: materialized.sessionRoot.path))
    XCTAssertEqual(try Data(contentsOf: source), payload)
  }

  func testEagerMaterializationRequestsTemporaryFileBeforeDropCallbackReturns() async throws {
    let fixtureRoot = temporaryRoot("eager-file-fixture")
    let receiverRoot = temporaryRoot("eager-file-receiver")
    defer {
      try? FileManager.default.removeItem(at: fixtureRoot)
      try? FileManager.default.removeItem(at: receiverRoot)
    }
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let source = fixtureRoot.appending(path: "Mirrored Book.m4b")
    let payload = Data("cross-device temporary representation".utf8)
    try payload.write(to: source)
    let m4bType = try XCTUnwrap(UTType(filenameExtension: "m4b")?.identifier)
    let probe = DropRequestProbe()
    let unavailable = NSError(domain: NSItemProvider.errorDomain, code: -1)
    let provider = MirroringItemProvider(
      registeredTypeIdentifiers: [m4bType, UTType.data.identifier],
      suggestedName: source.lastPathComponent,
      canLoadURLObject: false,
      loadURLObject: { completion in
        completion(nil, unavailable)
        return Progress(totalUnitCount: 1)
      },
      loadInPlace: { _, completion in
        probe.recordInPlaceRequest()
        completion(nil, false, unavailable)
        return Progress(totalUnitCount: 1)
      },
      loadFile: { typeIdentifier, completion in
        probe.recordFileRequest(typeIdentifier)
        DispatchQueue.global().async {
          completion(source, nil)
        }
        return Progress(totalUnitCount: 1)
      }
    )
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)

    let operation = try adapter.beginMaterializing([provider])
    probe.endDropCallback()

    XCTAssertEqual(probe.fileRequests, [m4bType])
    XCTAssertEqual(probe.inPlaceRequestCount, 0)
    XCTAssertFalse(probe.requestStartedAfterDropCallback)
    let materialized = try await operation.value()
    let received = try XCTUnwrap(materialized.selectionURLs.first)
    XCTAssertEqual(try Data(contentsOf: received), payload)
    adapter.cleanup(materialized)
  }

  func testEagerMaterializationCopiesProviderFileBeforeTemporaryURLExpires() async throws {
    let fixtureRoot = temporaryRoot("temporary-file-fixture")
    let receiverRoot = temporaryRoot("temporary-file-receiver")
    defer {
      try? FileManager.default.removeItem(at: fixtureRoot)
      try? FileManager.default.removeItem(at: receiverRoot)
    }
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let source = fixtureRoot.appending(path: "Ephemeral.mp3")
    let payload = Data("temporary provider bytes".utf8)
    try payload.write(to: source)
    let mp3Type = try XCTUnwrap(UTType(filenameExtension: "mp3")?.identifier)
    let unavailable = NSError(domain: NSItemProvider.errorDomain, code: -1)
    let provider = MirroringItemProvider(
      registeredTypeIdentifiers: [mp3Type],
      suggestedName: source.lastPathComponent,
      canLoadURLObject: false,
      loadURLObject: { completion in
        completion(nil, unavailable)
        return Progress(totalUnitCount: 1)
      },
      loadInPlace: { _, completion in
        completion(nil, false, unavailable)
        return Progress(totalUnitCount: 1)
      },
      loadFile: { _, completion in
        completion(source, nil)
        try? FileManager.default.removeItem(at: source)
        return Progress(totalUnitCount: 1)
      }
    )
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)

    let operation = try adapter.beginMaterializing([provider])
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

    let materialized = try await operation.value()
    let received = try XCTUnwrap(materialized.selectionURLs.first)
    XCTAssertEqual(try Data(contentsOf: received), payload)
    adapter.cleanup(materialized)
  }

  func testMaterializesFinderURLObjectWhenFileRepresentationsAreUnavailable() async throws {
    let fixtureRoot = temporaryRoot("url-object-fixture")
    let receiverRoot = temporaryRoot("url-object-receiver")
    defer {
      try? FileManager.default.removeItem(at: fixtureRoot)
      try? FileManager.default.removeItem(at: receiverRoot)
    }
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let source = fixtureRoot.appending(path: "This Story Might Save Your Life.m4b")
    let payload = Data("finder URL object".utf8)
    try payload.write(to: source)
    let unavailable = NSError(domain: NSItemProvider.errorDomain, code: -1)
    let provider = MirroringItemProvider(
      registeredTypeIdentifiers: [UTType.fileURL.identifier],
      suggestedName: source.lastPathComponent,
      canLoadURLObject: true,
      loadURLObject: { completion in
        completion(source, nil)
        return Progress(totalUnitCount: 1)
      },
      loadInPlace: { _, completion in
        completion(nil, false, unavailable)
        return Progress(totalUnitCount: 1)
      },
      loadFile: { _, completion in
        completion(nil, unavailable)
        return Progress(totalUnitCount: 1)
      }
    )
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)

    let materialized = try await adapter.materialize([provider])

    let received = try XCTUnwrap(materialized.selectionURLs.first)
    XCTAssertEqual(received.lastPathComponent, source.lastPathComponent)
    XCTAssertEqual(try Data(contentsOf: received), payload)
    adapter.cleanup(materialized)
  }

  func testMaterializesSystemURLObjectProvider() async throws {
    let fixtureRoot = temporaryRoot("system-url-object-fixture")
    let receiverRoot = temporaryRoot("system-url-object-receiver")
    defer {
      try? FileManager.default.removeItem(at: fixtureRoot)
      try? FileManager.default.removeItem(at: receiverRoot)
    }
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let source = fixtureRoot.appending(path: "Finder Audiobook.m4b")
    let payload = Data("system NSItemProvider URL object".utf8)
    try payload.write(to: source)
    let provider = NSItemProvider(object: source as NSURL)
    provider.suggestedName = source.lastPathComponent
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)

    let materialized = try await adapter.materialize([provider])

    let received = try XCTUnwrap(materialized.selectionURLs.first)
    XCTAssertEqual(received.lastPathComponent, source.lastPathComponent)
    XCTAssertEqual(try Data(contentsOf: received), payload)
    adapter.cleanup(materialized)
  }

  func testMaterializesFinderFolderURLObjectWhenFileRepresentationsAreUnavailable() async throws {
    let fixtureRoot = temporaryRoot("folder-url-object-fixture")
    let receiverRoot = temporaryRoot("folder-url-object-receiver")
    defer {
      try? FileManager.default.removeItem(at: fixtureRoot)
      try? FileManager.default.removeItem(at: receiverRoot)
    }
    let source = fixtureRoot.appending(path: "Project Hail Mary", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let payload = Data("finder folder URL object".utf8)
    try payload.write(to: source.appending(path: "Chapter 01.m4b"))
    let unavailable = NSError(domain: NSItemProvider.errorDomain, code: -1)
    let provider = MirroringItemProvider(
      registeredTypeIdentifiers: [UTType.folder.identifier, UTType.fileURL.identifier],
      suggestedName: source.lastPathComponent,
      canLoadURLObject: true,
      loadURLObject: { completion in
        completion(source, nil)
        return Progress(totalUnitCount: 1)
      },
      loadInPlace: { _, completion in
        completion(nil, false, unavailable)
        return Progress(totalUnitCount: 1)
      },
      loadFile: { _, completion in
        completion(nil, unavailable)
        return Progress(totalUnitCount: 1)
      }
    )
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)

    let materialized = try await adapter.materialize([provider])

    let received = try XCTUnwrap(materialized.selectionURLs.first)
    XCTAssertEqual(received.lastPathComponent, source.lastPathComponent)
    XCTAssertEqual(
      try Data(contentsOf: received.appending(path: "Chapter 01.m4b")),
      payload
    )
    adapter.cleanup(materialized)
  }

  func testTriesGenericFinderTypeAfterAdvertisedAudioTypeFails() async throws {
    let fixtureRoot = temporaryRoot("alternate-type-fixture")
    let receiverRoot = temporaryRoot("alternate-type-receiver")
    defer {
      try? FileManager.default.removeItem(at: fixtureRoot)
      try? FileManager.default.removeItem(at: receiverRoot)
    }
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let source = fixtureRoot.appending(path: "Chapter 01.m4b")
    let payload = Data("generic Finder representation".utf8)
    try payload.write(to: source)
    let m4bType = try XCTUnwrap(UTType(filenameExtension: "m4b")?.identifier)
    let unavailable = NSError(domain: NSItemProvider.errorDomain, code: -1)
    let provider = MirroringItemProvider(
      registeredTypeIdentifiers: [m4bType, UTType.fileURL.identifier],
      suggestedName: source.lastPathComponent,
      canLoadURLObject: false,
      loadURLObject: { completion in
        completion(nil, unavailable)
        return Progress(totalUnitCount: 1)
      },
      loadInPlace: { typeIdentifier, completion in
        if typeIdentifier == UTType.fileURL.identifier {
          completion(source, true, nil)
        } else {
          completion(nil, false, unavailable)
        }
        return Progress(totalUnitCount: 1)
      },
      loadFile: { _, completion in
        completion(nil, unavailable)
        return Progress(totalUnitCount: 1)
      }
    )
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)

    let materialized = try await adapter.materialize([provider])

    let received = try XCTUnwrap(materialized.selectionURLs.first)
    XCTAssertEqual(try Data(contentsOf: received), payload)
    adapter.cleanup(materialized)
  }

  func testMaterializesFolderProviderRecursivelyAndPreservesBookTree() async throws {
    let fixtureRoot = temporaryRoot("folder-fixture")
    let receiverRoot = temporaryRoot("folder-receiver")
    defer {
      try? FileManager.default.removeItem(at: fixtureRoot)
      try? FileManager.default.removeItem(at: receiverRoot)
    }
    let source = fixtureRoot.appending(path: "books", directoryHint: .isDirectory)
    let book = source.appending(path: "Project Hail Mary/Disc 1", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
    try Data("one".utf8).write(to: book.appending(path: "01.mp3"))
    try Data("two".utf8).write(to: book.appending(path: "02.m4b"))
    try Data("ignored".utf8).write(to: book.appending(path: "cover.jpg"))
    let provider = fileProvider(
      source,
      typeIdentifier: UTType.folder.identifier,
      suggestedName: "books"
    )
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)

    let materialized = try await adapter.materialize([provider])

    let selection = try XCTUnwrap(materialized.selectionURLs.first)
    XCTAssertEqual(selection.lastPathComponent, "books")
    XCTAssertEqual(
      try Data(contentsOf: selection.appending(path: "Project Hail Mary/Disc 1/01.mp3")),
      Data("one".utf8)
    )
    XCTAssertEqual(
      try Data(contentsOf: selection.appending(path: "Project Hail Mary/Disc 1/02.m4b")),
      Data("two".utf8)
    )
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: selection.appending(path: "Project Hail Mary/Disc 1/cover.jpg").path
    ))
    adapter.cleanup(materialized)
  }

  func testRejectsUnsafeFolderLinkAndRemovesPartialMaterialization() async throws {
    let fixtureRoot = temporaryRoot("link-fixture")
    let receiverRoot = temporaryRoot("link-receiver")
    defer {
      try? FileManager.default.removeItem(at: fixtureRoot)
      try? FileManager.default.removeItem(at: receiverRoot)
    }
    let source = fixtureRoot.appending(path: "Unsafe Book", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: source.appending(path: "01.mp3"))
    try FileManager.default.createSymbolicLink(
      at: source.appending(path: "escape.mp3"),
      withDestinationURL: URL(filePath: "/tmp/outside.mp3")
    )
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)

    do {
      _ = try await adapter.materialize([
        fileProvider(source, typeIdentifier: UTType.folder.identifier, suggestedName: "Unsafe Book"),
      ])
      XCTFail("A folder containing a symbolic link should be rejected")
    } catch let error as MirroringDropError {
      guard case .unsafeFolderEntry(let path) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(path, "escape.mp3")
    }
    XCTAssertTrue(try children(of: receiverRoot).isEmpty)
  }

  func testRejectsMixedZIPDropAndCleansEveryProviderCopy() async throws {
    let fixtureRoot = temporaryRoot("mixed-fixture")
    let receiverRoot = temporaryRoot("mixed-receiver")
    defer {
      try? FileManager.default.removeItem(at: fixtureRoot)
      try? FileManager.default.removeItem(at: receiverRoot)
    }
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let archive = fixtureRoot.appending(path: "Book.zip")
    let audio = fixtureRoot.appending(path: "Extra.mp3")
    try Data("zip".utf8).write(to: archive)
    try Data("audio".utf8).write(to: audio)
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)

    do {
      _ = try await adapter.materialize([
        fileProvider(archive, typeIdentifier: UTType.zip.identifier, suggestedName: "Book.zip"),
        fileProvider(
          audio,
          typeIdentifier: try XCTUnwrap(UTType(filenameExtension: "mp3")?.identifier),
          suggestedName: "Extra.mp3"
        ),
      ])
      XCTFail("A ZIP mixed with another provider should be rejected")
    } catch let error as MirroringDropError {
      XCTAssertEqual(error, .mixedArchiveSelection)
    }
    XCTAssertTrue(try children(of: receiverRoot).isEmpty)
  }

  func testCancellationCancelsProviderProgressAndRemovesSession() async throws {
    let fixtureRoot = temporaryRoot("cancel-fixture")
    let receiverRoot = temporaryRoot("cancel-receiver")
    defer {
      try? FileManager.default.removeItem(at: fixtureRoot)
      try? FileManager.default.removeItem(at: receiverRoot)
    }
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let source = fixtureRoot.appending(path: "Delayed.mp3")
    try Data("delayed".utf8).write(to: source)
    let providerProgress = Progress(totalUnitCount: 1)
    let provider = NSItemProvider()
    provider.suggestedName = "Delayed.mp3"
    let mp3Type = try XCTUnwrap(UTType(filenameExtension: "mp3")?.identifier)
    provider.registerFileRepresentation(
      forTypeIdentifier: mp3Type,
      fileOptions: [.openInPlace],
      visibility: .all
    ) { completion in
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        completion(source, true, nil)
      }
      return providerProgress
    }
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)
    let task = Task { try await adapter.materialize([provider]) }
    try await Task.sleep(for: .milliseconds(50))

    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Cancellation should end provider materialization")
    } catch is CancellationError {}
    XCTAssertTrue(providerProgress.isCancelled)
    XCTAssertTrue(try children(of: receiverRoot).isEmpty)
  }

  func testFolderProviderCompletesRealImporterWithInnerBookTitle() async throws {
    let temporaryRoot = temporaryRoot("pipeline")
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let bundled = try XCTUnwrap(
      Bundle(for: MirroringDropAdapterTests.self).url(
        forResource: "01-opening-tone",
        withExtension: "m4a"
      )
    )
    let source = temporaryRoot.appending(path: "Source/books/Project Hail Mary", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: bundled, to: source.appending(path: "01-opening-tone.m4a"))
    let receiverRoot = temporaryRoot.appending(path: "ComputerReceiver", directoryHint: .isDirectory)
    let adapter = MirroringDropAdapter(rootURL: receiverRoot)
    let provider = fileProvider(
      source.deletingLastPathComponent(),
      typeIdentifier: UTType.folder.identifier,
      suggestedName: "books"
    )
    let materialized = try await adapter.materialize([provider])
    let media = FileSystemMediaManager(rootURL: temporaryRoot)
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: InMemoryLibraryStore(),
      media: media,
      inspector: AVFoundationAudioInspector(),
      playback: DeterministicPlaybackController()
    ))
    await model.restore()

    let outcome = await model.importFromComputer(materialized.selectionURLs)

    XCTAssertEqual(outcome.state, .completed)
    XCTAssertEqual(model.library.books.first?.title, "Project Hail Mary")
    adapter.cleanup(materialized)
    XCTAssertFalse(FileManager.default.fileExists(atPath: materialized.sessionRoot.path))
    let asset = try XCTUnwrap(model.library.books.first?.assets.first)
    let managedURL = try await media.managedURL(for: asset.managedRelativePath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
  }

  func testNativeDropInteractionMovesBetweenWindowsAndUninstallsWithoutMutatingSwiftUIState() {
    var isTargeted = false
    let binding = Binding(
      get: { isTargeted },
      set: { isTargeted = $0 }
    )
    let coordinator = MirroringWindowDropInteraction.Coordinator(
      acceptedTypeIdentifiers: MirroringDropAdapter.acceptedTypeIdentifiers,
      isTargeted: binding,
      performDrop: { _ in true }
    )
    let firstWindow = UIWindow()
    let secondWindow = UIWindow()

    coordinator.install(on: firstWindow)

    XCTAssertEqual(firstWindow.interactions.compactMap { $0 as? UIDropInteraction }.count, 1)
    coordinator.install(on: secondWindow)
    XCTAssertTrue(firstWindow.interactions.compactMap { $0 as? UIDropInteraction }.isEmpty)
    XCTAssertEqual(secondWindow.interactions.compactMap { $0 as? UIDropInteraction }.count, 1)

    isTargeted = true
    coordinator.uninstall()

    XCTAssertTrue(secondWindow.interactions.compactMap { $0 as? UIDropInteraction }.isEmpty)
    XCTAssertTrue(isTargeted)
  }

  private func fileProvider(
    _ sourceURL: URL,
    typeIdentifier: String,
    suggestedName: String
  ) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = suggestedName
    provider.registerFileRepresentation(
      forTypeIdentifier: typeIdentifier,
      fileOptions: [.openInPlace],
      visibility: .all
    ) { completion in
      completion(sourceURL, true, nil)
      return Progress(totalUnitCount: 1)
    }
    return provider
  }

  private func temporaryRoot(_ purpose: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "MirroringDropAdapterTests-\(purpose)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }

  private func children(of directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
  }
}

private final class DropRequestProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var dropCallbackIsActive = true
  private(set) var fileRequests: [String] = []
  private(set) var inPlaceRequestCount = 0
  private(set) var requestStartedAfterDropCallback = false

  func recordFileRequest(_ typeIdentifier: String) {
    lock.lock()
    fileRequests.append(typeIdentifier)
    requestStartedAfterDropCallback = requestStartedAfterDropCallback || !dropCallbackIsActive
    lock.unlock()
  }

  func recordInPlaceRequest() {
    lock.lock()
    inPlaceRequestCount += 1
    lock.unlock()
  }

  func endDropCallback() {
    lock.lock()
    dropCallbackIsActive = false
    lock.unlock()
  }
}
