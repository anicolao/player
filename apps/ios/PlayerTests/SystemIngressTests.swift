import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Player

final class SystemIngressTests: XCTestCase {
  func testFileSelectionClassifierDistinguishesSelectionCancellationAndFailure() throws {
    let first = URL(filePath: "/tmp/first.m4b")
    let second = URL(filePath: "/tmp/second.mp3")
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.success([first, second])),
      .selected([first, second])
    )
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.success([])),
      .cancelled
    )
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.failure(CancellationError())),
      .cancelled
    )
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.failure(CocoaError(.userCancelled))),
      .cancelled
    )
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.failure(URLError(.cancelled))),
      .cancelled
    )
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.failure(POSIXError(.ECANCELED))),
      .cancelled
    )

    let providerFailure = NSError(domain: "FixtureProvider", code: 91, userInfo: [
      NSLocalizedDescriptionKey: "The cloud item is offline.",
    ])
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.failure(providerFailure)),
      .failed(SystemSelectionFailure(providerFailure))
    )
  }

  func testNestedCancellationIsRecognizedWithoutMisclassifyingProviderFailures() {
    let cancellation = NSError(
      domain: "FixtureProvider",
      code: 2,
      userInfo: [NSUnderlyingErrorKey: CocoaError(.userCancelled)]
    )
    XCTAssertTrue(SystemSelectionCancellation.isCancellation(cancellation))
    XCTAssertFalse(SystemSelectionCancellation.isCancellation(
      NSError(domain: NSItemProvider.errorDomain, code: -1)
    ))
  }

  func testSecurityScopedLeaseStartsUniqueURLsAndStopsEachSuccessfulStartExactlyOnce() {
    let probe = SecurityScopeProbe(accessibleNames: ["first.m4b", "second.mp3"])
    let access = probe.access
    let first = URL(filePath: "/tmp/first.m4b")
    let second = URL(filePath: "/tmp/second.mp3")
    let local = URL(filePath: "/tmp/local.zip")

    let lease = access.acquire([first, first, second, local])
    XCTAssertEqual(probe.startedNames, ["first.m4b", "second.mp3", "local.zip"])
    XCTAssertTrue(probe.stoppedNames.isEmpty)

    lease.release()
    lease.release()
    XCTAssertEqual(probe.stoppedNames, ["first.m4b", "second.mp3"])

    do {
      _ = access.acquire([first])
    }
    XCTAssertEqual(probe.startedNames, ["first.m4b", "second.mp3", "local.zip", "first.m4b"])
    XCTAssertEqual(probe.stoppedNames, ["first.m4b", "second.mp3", "first.m4b"])
  }

  func testCoverAcquirerUsesActualTypeAndRetainsValidPNG() throws {
    let png = try imageData(type: .png, width: 3, height: 2)
    let acquired = try CoverArtworkAcquirer().acquire(
      data: png,
      declaredMediaType: "image/jpeg"
    )
    XCTAssertEqual(acquired.data, png)
    XCTAssertEqual(acquired.mediaType, "image/png")
    XCTAssertEqual(acquired.pixelWidth, 3)
    XCTAssertEqual(acquired.pixelHeight, 2)
    XCTAssertFalse(acquired.wasNormalized)
  }

  func testCoverAcquirerRejectsEmptyOversizedCorruptAndExcessivePixelPayloads() throws {
    XCTAssertThrowsError(try CoverArtworkAcquirer().acquire(data: Data())) { error in
      XCTAssertEqual(error as? CoverArtworkAcquisitionError, .emptyData)
    }
    XCTAssertThrowsError(
      try CoverArtworkAcquirer(maximumEncodedByteCount: 3).acquire(data: Data(repeating: 1, count: 4))
    ) { error in
      XCTAssertEqual(
        error as? CoverArtworkAcquisitionError,
        .encodedDataTooLarge(maximumBytes: 3)
      )
    }
    XCTAssertThrowsError(try CoverArtworkAcquirer().acquire(data: Data("not image".utf8))) {
      error in
      XCTAssertEqual(error as? CoverArtworkAcquisitionError, .invalidImage)
    }
    let png = try imageData(type: .png, width: 11, height: 10)
    XCTAssertThrowsError(
      try CoverArtworkAcquirer(maximumPixelCount: 100).acquire(data: png)
    ) { error in
      XCTAssertEqual(
        error as? CoverArtworkAcquisitionError,
        .pixelLimitExceeded(width: 11, height: 10, maximumPixels: 100)
      )
    }
  }

  func testCoverAcquirerNormalizesReadableUnsupportedEncodingToPNG() throws {
    let tiff = try imageData(type: .tiff, width: 4, height: 3)
    let acquired = try CoverArtworkAcquirer().acquire(data: tiff)
    XCTAssertEqual(acquired.mediaType, "image/png")
    XCTAssertEqual(acquired.pixelWidth, 4)
    XCTAssertEqual(acquired.pixelHeight, 3)
    XCTAssertTrue(acquired.wasNormalized)
    XCTAssertNotEqual(acquired.data, tiff)
    XCTAssertNotNil(CGImageSourceCreateWithData(acquired.data as CFData, nil))
  }

  func testCoverAcquirerRetainsHEICAndReportsItsActualMediaType() throws {
    let heic = try imageData(type: .heic, width: 16, height: 16)
    let acquired = try CoverArtworkAcquirer().acquire(
      data: heic,
      declaredMediaType: "image/jpeg"
    )
    XCTAssertEqual(acquired.mediaType, "image/heic")
    XCTAssertEqual(acquired.pixelWidth, 16)
    XCTAssertEqual(acquired.pixelHeight, 16)
    XCTAssertFalse(acquired.wasNormalized)
    XCTAssertEqual(acquired.data, heic)
  }

  func testCoverFileAcquisitionBalancesScopeOnSuccessAndEveryFailure() throws {
    let root = temporaryRoot("cover-files")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let valid = root.appending(path: "valid.png")
    let corrupt = root.appending(path: "corrupt.png")
    let tooLarge = root.appending(path: "large.png")
    try imageData(type: .png, width: 2, height: 2).write(to: valid)
    try Data("not an image".utf8).write(to: corrupt)
    try Data(repeating: 7, count: 32).write(to: tooLarge)
    let probe = SecurityScopeProbe(accessibleNames: [
      valid.lastPathComponent, corrupt.lastPathComponent, tooLarge.lastPathComponent,
    ])

    XCTAssertEqual(
      try CoverArtworkAcquirer().acquire(fileURL: valid, resourceAccess: probe.access).mediaType,
      "image/png"
    )
    XCTAssertThrowsError(
      try CoverArtworkAcquirer().acquire(fileURL: corrupt, resourceAccess: probe.access)
    )
    XCTAssertThrowsError(
      try CoverArtworkAcquirer(maximumEncodedByteCount: 8).acquire(
        fileURL: tooLarge,
        resourceAccess: probe.access
      )
    )
    XCTAssertEqual(probe.startedNames, ["valid.png", "corrupt.png", "large.png"])
    XCTAssertEqual(probe.stoppedNames, ["valid.png", "corrupt.png", "large.png"])
  }

  func testPhotoSelectionAdapterValidatesSuccessBeforeIntegratingTheDraft() async throws {
    let png = try imageData(type: .png, width: 5, height: 4)
    let outcome = await CoverArtworkSelectionAdapter().acquirePhoto {
      png
    }
    var cover: CoverArtwork?
    let failure = CoverArtworkSelectionIntegration.apply(
      outcome,
      source: .photoLibrary
    ) { cover = $0 }

    XCTAssertNil(failure)
    XCTAssertEqual(cover?.originalData, png)
    XCTAssertEqual(cover?.mediaType, "image/png")
    XCTAssertEqual(cover?.source, .photoLibrary)
  }

  func testPhotoCancellationAndProviderFailureDoNotMutateExistingDraftState() async throws {
    let original = CoverArtwork(
      originalData: try imageData(type: .png, width: 2, height: 2),
      mediaType: "image/png",
      source: .embedded
    )
    let unrelatedTitle = "Uncommitted title"
    var cover = original
    var mutationCount = 0
    let cancellation = await CoverArtworkSelectionAdapter().acquirePhoto {
      throw CancellationError()
    }
    XCTAssertNil(CoverArtworkSelectionIntegration.apply(
      cancellation,
      source: .photoLibrary
    ) {
      mutationCount += 1
      cover = $0
    })

    let provider = NSError(domain: NSItemProvider.errorDomain, code: -1, userInfo: [
      NSLocalizedDescriptionKey: "The photo is not downloaded.",
    ])
    let providerFailure = await CoverArtworkSelectionAdapter().acquirePhoto {
      throw provider
    }
    let failure = CoverArtworkSelectionIntegration.apply(
      providerFailure,
      source: .photoLibrary
    ) {
      mutationCount += 1
      cover = $0
    }

    XCTAssertEqual(mutationCount, 0)
    XCTAssertEqual(cover, original)
    XCTAssertEqual(unrelatedTitle, "Uncommitted title")
    XCTAssertEqual(failure, SystemSelectionFailure(provider))
  }

  func testFileSelectionAdapterOwnsScopeAndUsesValidatedActualImageType() throws {
    let root = temporaryRoot("cover-selection-file")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "cover.jpg")
    let png = try imageData(type: .png, width: 6, height: 3)
    try png.write(to: file)
    let scope = SecurityScopeProbe(accessibleNames: [file.lastPathComponent])

    let outcome = CoverArtworkSelectionAdapter(resourceAccess: scope.access).acquireFile(
      .success([file])
    )
    guard case .selected(let acquired) = outcome else {
      return XCTFail("A readable selected file should be acquired")
    }
    XCTAssertEqual(acquired.data, png)
    XCTAssertEqual(acquired.mediaType, "image/png")
    XCTAssertEqual(scope.startedNames, ["cover.jpg"])
    XCTAssertEqual(scope.stoppedNames, ["cover.jpg"])
  }

  func testFileCancellationProviderFailureAndInvalidImageNeverIntegrateTheDraft() throws {
    let root = temporaryRoot("cover-selection-failures")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let invalid = root.appending(path: "invalid.png")
    try Data("not an image".utf8).write(to: invalid)
    let scope = SecurityScopeProbe(accessibleNames: [invalid.lastPathComponent])
    let adapter = CoverArtworkSelectionAdapter(resourceAccess: scope.access)
    let provider = NSError(domain: "FixtureFilesProvider", code: 42, userInfo: [
      NSLocalizedDescriptionKey: "The cloud item is offline.",
    ])
    let outcomes = [
      adapter.acquireFile(.success([])),
      adapter.acquireFile(.failure(CancellationError())),
      adapter.acquireFile(.failure(provider)),
      adapter.acquireFile(.success([invalid])),
    ]
    var mutationCount = 0
    let failures = outcomes.compactMap { outcome in
      CoverArtworkSelectionIntegration.apply(outcome, source: .file) { _ in
        mutationCount += 1
      }
    }

    XCTAssertEqual(mutationCount, 0)
    XCTAssertEqual(failures.count, 2)
    XCTAssertEqual(failures.first, SystemSelectionFailure(provider))
    XCTAssertTrue(failures.last?.message.contains("readable image") == true)
    XCTAssertEqual(scope.startedNames, ["invalid.png"])
    XCTAssertEqual(scope.stoppedNames, ["invalid.png"])
  }

  func testMediaReferencesAndAcquiresSingleMultipleFolderAndZIPWithoutChangingSources() async throws {
    let root = temporaryRoot("files-routes")
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
    let folder = sources.appending(path: "Folder Book", directoryHint: .isDirectory)
    let nested = folder.appending(path: "Disc 1", directoryHint: .isDirectory)
    let storage = root.appending(path: "Storage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let first = sources.appending(path: "First.mp3")
    let second = sources.appending(path: "Second.m4a")
    let folderFirst = folder.appending(path: "01.mp3")
    let folderSecond = nested.appending(path: "02.m4a")
    let archive = sources.appending(path: "Book.zip")
    let originals: [URL: Data] = [
      first: Data("first".utf8),
      second: Data("second".utf8),
      folderFirst: Data("folder-first".utf8),
      folderSecond: Data("folder-second".utf8),
      archive: Data("synthetic archive source".utf8),
    ]
    for (url, data) in originals { try data.write(to: url) }
    let selected = [first, second, folder, archive]
    let scope = SecurityScopeProbe(accessibleNames: Set(selected.map(\.lastPathComponent)))
    let bookmarks = ImportSourceBookmarkAccess(
      createBookmark: { Data($0.lastPathComponent.utf8) },
      resolveBookmark: { _ in
        throw PlayerCoreError.fileOperation("Resolution is not part of initial acquisition.")
      }
    )
    let media = FileSystemMediaManager(
      rootURL: storage,
      resourceAccess: scope.access,
      bookmarkAccess: bookmarks
    )
    let mediaInterface: any MediaManaging = media

    let references = try await mediaInterface.referenceImportSources(selected, displayNames: nil)
    XCTAssertEqual(references.map(\.displayName), selected.map(\.lastPathComponent))
    XCTAssertEqual(references.map(\.isDirectory), [false, false, true, false])
    XCTAssertEqual(references.map(\.bookmarkData), selected.map { Data($0.lastPathComponent.utf8) })

    let single = try await mediaInterface.acquireSelection([first], jobID: uuid(1))
    let multiple = try await mediaInterface.acquireSelection([first, second], jobID: uuid(2))
    let folderFiles = try await mediaInterface.acquireSelection([folder], jobID: uuid(3))
    let stagedArchive = try await mediaInterface.stageArchive(sourceURL: archive, jobID: uuid(4))
    XCTAssertEqual(single.map(\.sourceRelativePath), ["First.mp3"])
    XCTAssertEqual(multiple.map(\.sourceRelativePath), ["First.mp3", "Second.m4a"])
    XCTAssertEqual(folderFiles.map(\.sourceRelativePath), ["01.mp3", "Disc 1/02.m4a"])
    XCTAssertEqual(folderFiles.map(\.commonFolderName), ["Folder Book", "Disc 1"])
    XCTAssertEqual(stagedArchive.originalFilename, "Book.zip")
    for (url, data) in originals {
      XCTAssertEqual(try Data(contentsOf: url), data, "Acquisition changed \(url.lastPathComponent)")
    }
    XCTAssertEqual(scope.startedNames, scope.stoppedNames)
  }

  func testApplicationOwnedMediaReferencesAvoidSecurityScopeAndBookmarkServices() async throws {
    let root = temporaryRoot("application-owned-references")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "Computer Receiver", directoryHint: .isDirectory)
      .appending(path: "Project Hail Mary.m4a")
    let storage = root.appending(path: "Storage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("receiver-owned media".utf8).write(to: source)
    let scope = SecurityScopeProbe(accessibleNames: [])
    let bookmarks = ImportSourceBookmarkAccess(
      createBookmark: { _ in
        throw PlayerCoreError.fileOperation(
          "Application-owned receiver media must not ask File Provider for a bookmark."
        )
      },
      resolveBookmark: { _ in
        throw PlayerCoreError.fileOperation("Resolution is not part of source referencing.")
      }
    )
    let media: any MediaManaging = FileSystemMediaManager(
      rootURL: storage,
      resourceAccess: scope.access,
      bookmarkAccess: bookmarks
    )

    let references = try await media.referenceApplicationOwnedImportSources(
      [source],
      displayNames: ["Project Hail Mary.m4a"]
    )

    XCTAssertEqual(references.map(\.displayName), ["Project Hail Mary.m4a"])
    XCTAssertEqual(references.map(\.bookmarkData), [nil])
    XCTAssertEqual(references.map(\.fallbackURLString), [source.absoluteString])
    XCTAssertEqual(references.map(\.isDirectory), [false])
    XCTAssertEqual(scope.startedNames, [])
    XCTAssertEqual(scope.stoppedNames, [])
  }

  func testSecondItemFailureRemovesTheWholeJobStagingDirectoryAndPreservesSources() async throws {
    let root = temporaryRoot("files-transaction")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appending(path: "First.mp3")
    let second = root.appending(path: "Second.mp3")
    let firstData = Data("first source remains".utf8)
    let secondData = Data("second source remains".utf8)
    try firstData.write(to: first)
    try secondData.write(to: second)
    let jobID = uuid(10)
    let storage = root.appending(path: "Storage")
    let scope = SecurityScopeProbe(accessibleNames: ["First.mp3", "Second.mp3"])
    let media = FileSystemMediaManager(
      rootURL: storage,
      resourceAccess: scope.access,
      bookmarkAccess: noBookmarkAccess,
      beforeAcquisitionCopy: { url, index in
        if index == 1 {
          throw PlayerCoreError.fileOperation("Provider withdrew \(url.lastPathComponent).")
        }
      }
    )

    do {
      _ = try await media.acquireSelection([first, second], jobID: jobID)
      XCTFail("The second provider item should fail acquisition")
    } catch let error as PlayerCoreError {
      XCTAssertEqual(error, .fileOperation("Provider withdrew Second.mp3."))
    }

    XCTAssertFalse(FileManager.default.fileExists(
      atPath: storage.appending(path: "Staging/\(jobID.uuidString.lowercased())").path
    ))
    XCTAssertEqual(try Data(contentsOf: first), firstData)
    XCTAssertEqual(try Data(contentsOf: second), secondData)
    XCTAssertEqual(scope.startedNames, ["First.mp3", "Second.mp3"])
    XCTAssertEqual(scope.stoppedNames, ["First.mp3", "Second.mp3"])
  }

  func testCancellationAfterFirstItemRemovesTheWholeJobStagingDirectoryAndPreservesSources() async throws {
    let root = temporaryRoot("files-cancellation")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appending(path: "First.mp3")
    let second = root.appending(path: "Second.mp3")
    let firstData = Data("first cancellation source remains".utf8)
    let secondData = Data("second cancellation source remains".utf8)
    try firstData.write(to: first)
    try secondData.write(to: second)
    let jobID = uuid(11)
    let storage = root.appending(path: "Storage")
    let scope = SecurityScopeProbe(accessibleNames: ["First.mp3", "Second.mp3"])
    let media = FileSystemMediaManager(
      rootURL: storage,
      resourceAccess: scope.access,
      bookmarkAccess: noBookmarkAccess,
      beforeAcquisitionCopy: { _, index in
        if index == 1 { throw CancellationError() }
      }
    )

    do {
      _ = try await media.acquireSelection([first, second], jobID: jobID)
      XCTFail("Cancellation after the first staged item should stop acquisition")
    } catch is CancellationError {
      // Expected.
    }

    XCTAssertFalse(FileManager.default.fileExists(
      atPath: storage.appending(path: "Staging/\(jobID.uuidString.lowercased())").path
    ))
    XCTAssertEqual(try Data(contentsOf: first), firstData)
    XCTAssertEqual(try Data(contentsOf: second), secondData)
    XCTAssertEqual(scope.startedNames, ["First.mp3", "Second.mp3"])
    XCTAssertEqual(scope.stoppedNames, ["First.mp3", "Second.mp3"])
  }

  @MainActor
  func testSystemPickerCancellationAndProviderFailureCreateNoImportJob() async throws {
    let root = temporaryRoot("picker-outcomes")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(
      store: InMemoryLibraryStore(),
      media: FileSystemMediaManager(rootURL: root, bookmarkAccess: noBookmarkAccess)
    )
    await model.restore()

    let cancelledJobID = await model.handleSystemFileSelection(.cancelled)
    XCTAssertNil(cancelledJobID)
    XCTAssertTrue(model.library.importJobs.isEmpty)
    XCTAssertNil(model.presentationError(in: .importFlow))

    let failure = SystemSelectionFailure(NSError(
      domain: "CloudProvider",
      code: 19,
      userInfo: [NSLocalizedDescriptionKey: "The cloud item is offline."]
    ))
    let failedJobID = await model.handleSystemFileSelection(.failed(failure))
    XCTAssertNil(failedJobID)
    XCTAssertTrue(model.library.importJobs.isEmpty)
    let presented = try XCTUnwrap(model.presentationError(in: .importFlow))
    XCTAssertTrue(presented.message.contains("Files couldn’t provide"))
    XCTAssertTrue(presented.message.contains("Download it in Files"))
    XCTAssertTrue(presented.message.contains("cloud item is offline"))
  }

  @MainActor
  func testSelectedFolderUsesFolderEntryPointAndMixedZIPIsRejectedBeforeCreatingAJob() async throws {
    let root = temporaryRoot("selection-classification")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "Folder Book", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let chapter = folder.appending(path: "01.mp3")
    try Data("chapter".utf8).write(to: chapter)
    let folderStore = InMemoryLibraryStore()
    let folderModel = makeModel(
      store: folderStore,
      media: FileSystemMediaManager(
        rootURL: root.appending(path: "FolderStorage"),
        bookmarkAccess: noBookmarkAccess
      )
    )
    await folderModel.restore()

    let folderJobID = await folderModel.handleSystemFileSelection(.selected([folder]))
    let folderJob = try XCTUnwrap(folderModel.library.importJobs.first(where: {
      $0.id == folderJobID
    }))
    XCTAssertEqual(folderJob.queueCheckpoint?.entryPoint, .folder)
    XCTAssertEqual(folderJob.queueCheckpoint?.sources.first?.isDirectory, true)

    let archive = root.appending(path: "Book.zip")
    let audio = root.appending(path: "Extra.mp3")
    let archiveData = Data("archive source".utf8)
    let audioData = Data("audio source".utf8)
    try archiveData.write(to: archive)
    try audioData.write(to: audio)
    let mixedModel = makeModel(
      store: InMemoryLibraryStore(),
      media: FileSystemMediaManager(
        rootURL: root.appending(path: "MixedStorage"),
        bookmarkAccess: noBookmarkAccess
      )
    )
    await mixedModel.restore()
    let mixedJobID = await mixedModel.handleSystemFileSelection(.selected([archive, audio]))
    XCTAssertNil(mixedJobID)
    XCTAssertTrue(mixedModel.library.importJobs.isEmpty)
    XCTAssertTrue(
      try XCTUnwrap(mixedModel.presentationError(in: .importFlow)).message
        .contains("Import one ZIP archive at a time")
    )
    XCTAssertEqual(try Data(contentsOf: archive), archiveData)
    XCTAssertEqual(try Data(contentsOf: audio), audioData)
  }

  @MainActor
  func testRestartResolvesBookmarkThenHoldsScopeThroughDurableAcquisition() async throws {
    let root = temporaryRoot("bookmark-restart")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "Restarted.mp3")
    let sourceData = Data("restart source".utf8)
    try sourceData.write(to: source)
    let bookmarkData = Data("restart-bookmark".utf8)
    let bookmarkProbe = BookmarkResolutionProbe(result: .success(
      ResolvedImportSourceBookmark(url: source, isStale: false)
    ))
    let scope = SecurityScopeProbe(accessibleNames: [source.lastPathComponent])
    let jobID = uuid(20)
    let store = InMemoryLibraryStore(snapshot: interruptedImportSnapshot(
      jobID: jobID,
      source: source,
      bookmarkData: bookmarkData
    ))
    let model = makeModel(
      store: store,
      media: FileSystemMediaManager(
        rootURL: root.appending(path: "Storage"),
        resourceAccess: scope.access,
        bookmarkAccess: bookmarkProbe.access
      )
    )

    await model.restore()

    let resumed = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(resumed.phase, .ready)
    XCTAssertEqual(resumed.queueCheckpoint?.acquisitionComplete, true)
    XCTAssertEqual(bookmarkProbe.resolvedPayloads, [bookmarkData])
    XCTAssertEqual(scope.startedNames, [source.lastPathComponent])
    XCTAssertEqual(scope.stoppedNames, [source.lastPathComponent])
    XCTAssertEqual(try Data(contentsOf: source), sourceData)
  }

  @MainActor
  func testStaleRestartBookmarkFailsActionablyWithoutOpeningScopeOrLeavingStaging() async throws {
    let root = temporaryRoot("bookmark-stale")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "Unavailable.mp3")
    let sourceData = Data("unavailable source".utf8)
    try sourceData.write(to: source)
    let bookmarkData = Data("stale-bookmark".utf8)
    let bookmarkProbe = BookmarkResolutionProbe(result: .success(
      ResolvedImportSourceBookmark(url: source, isStale: true)
    ))
    let scope = SecurityScopeProbe(accessibleNames: [source.lastPathComponent])
    let jobID = uuid(30)
    let storage = root.appending(path: "Storage")
    let store = InMemoryLibraryStore(snapshot: interruptedImportSnapshot(
      jobID: jobID,
      source: source,
      bookmarkData: bookmarkData
    ))
    let model = makeModel(
      store: store,
      media: FileSystemMediaManager(
        rootURL: storage,
        resourceAccess: scope.access,
        bookmarkAccess: bookmarkProbe.access
      )
    )

    await model.restore()

    let failed = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(failed.phase, .failed)
    XCTAssertEqual(failed.failure?.reasonCode, "acquisition-transient")
    XCTAssertTrue(failed.failure?.message.contains("choose it again in Files") == true)
    XCTAssertEqual(bookmarkProbe.resolvedPayloads, [bookmarkData])
    XCTAssertTrue(scope.startedNames.isEmpty)
    XCTAssertTrue(scope.stoppedNames.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: storage.appending(path: "Staging/\(jobID.uuidString.lowercased())").path
    ))
    XCTAssertEqual(try Data(contentsOf: source), sourceData)
  }

  private func imageData(type: UTType, width: Int, height: Int) throws -> Data {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let output = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
      output,
      type.identifier as CFString,
      1,
      nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  private func temporaryRoot(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "player-system-ingress-\(name)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }

  private var noBookmarkAccess: ImportSourceBookmarkAccess {
    ImportSourceBookmarkAccess(
      createBookmark: { _ in nil },
      resolveBookmark: { _ in
        throw PlayerCoreError.fileOperation("No bookmark was created for this local fixture.")
      }
    )
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "81000000-0000-0000-0000-%012d", value))!
  }

  @MainActor
  private func makeModel(
    store: InMemoryLibraryStore,
    media: any MediaManaging
  ) -> PlayerModel {
    let ids = (100...140).map(uuid)
    return PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: media,
      inspector: DeterministicAudioInspector(result: .success(InspectedAudio(
        title: "System Files Book",
        authors: ["Fixture Author"],
        durationSeconds: 30,
        artworkData: nil,
        container: "MP3"
      ))),
      playback: DeterministicPlaybackController(),
      ids: DeterministicPlayerIDGenerator(values: ids)
    ))
  }

  private func interruptedImportSnapshot(
    jobID: UUID,
    source: URL,
    bookmarkData: Data
  ) -> LibrarySnapshot {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return LibrarySnapshot(
      books: [],
      importJobs: [ImportJob(
        id: jobID,
        sourceFilename: source.lastPathComponent,
        phase: .acquiring,
        progress: .none,
        createdAt: date,
        updatedAt: date,
        queueCheckpoint: ImportQueueCheckpoint(
          entryPoint: .files,
          sources: [DurableImportSource(
            displayName: source.lastPathComponent,
            bookmarkData: bookmarkData,
            fallbackURLString: source.absoluteString,
            isDirectory: false
          )]
        )
      )],
      currentBookID: nil
    )
  }
}

private final class SecurityScopeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let accessibleNames: Set<String>
  private var starts: [String] = []
  private var stops: [String] = []

  init(accessibleNames: Set<String>) {
    self.accessibleNames = accessibleNames
  }

  var access: SecurityScopedResourceAccess {
    SecurityScopedResourceAccess(
      startAccess: { [self] url in
        lock.withLock { starts.append(url.lastPathComponent) }
        return accessibleNames.contains(url.lastPathComponent)
      },
      stopAccess: { [self] url in
        lock.withLock { stops.append(url.lastPathComponent) }
      }
    )
  }

  var startedNames: [String] { lock.withLock { starts } }
  var stoppedNames: [String] { lock.withLock { stops } }
}

private final class BookmarkResolutionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let result: Result<ResolvedImportSourceBookmark, PlayerCoreError>
  private var payloads: [Data] = []

  init(result: Result<ResolvedImportSourceBookmark, PlayerCoreError>) {
    self.result = result
  }

  var access: ImportSourceBookmarkAccess {
    ImportSourceBookmarkAccess(
      createBookmark: { _ in nil },
      resolveBookmark: { [self] data in
        lock.withLock { payloads.append(data) }
        return try result.get()
      }
    )
  }

  var resolvedPayloads: [Data] { lock.withLock { payloads } }
}
