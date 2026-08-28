import XCTest
@testable import Player

final class ImportRecoveryTests: XCTestCase {
  func testE2EImportRecoveryScenarioAcceptsEveryCanonicalValue() throws {
    for scenario in E2EImportRecoveryScenario.allCases {
      let parsed = try E2EImportRecoveryScenario.parseRequired(arguments: [
        "Player",
        "-e2e",
        "-e2e-recovery-scenario", scenario.rawValue,
        "-AppleLanguages", "(en)",
      ])
      XCTAssertEqual(parsed, scenario)
    }
  }

  func testE2EImportRecoveryScenarioRequiresExactlyOneValue() {
    let invalidArguments = [
      ["Player", "-e2e"],
      ["Player", "-e2e-recovery-scenario"],
      ["Player", "-e2e-recovery-scenario", "-e2e-reset"],
      [
        "Player",
        "-e2e-recovery-scenario", "mixed",
        "-e2e-recovery-scenario", "low-space",
      ],
    ]

    for arguments in invalidArguments {
      XCTAssertThrowsError(
        try E2EImportRecoveryScenario.parseRequired(arguments: arguments),
        "Expected strict scenario parsing to reject \(arguments)"
      )
    }
  }

  func testE2EImportRecoveryScenarioRejectsUnknownAndMalformedValues() {
    let invalidValues = [
      "partial",
      "Mixed",
      "../mixed",
      "mixed/other",
      "",
      String(repeating: "a", count: 65),
    ]

    for value in invalidValues {
      XCTAssertThrowsError(
        try E2EImportRecoveryScenario.parseRequired(arguments: [
          "Player", "-e2e-recovery-scenario", value,
        ]),
        "Expected strict scenario parsing to reject \(value.debugDescription)"
      )
    }
  }

  func testDetectsExistingAndWithinSelectionDuplicatesExplainably() {
    let files = [
      file(1, "first.m4b", checksum: "aaa"),
      file(2, "copy.m4b", checksum: "AAA"),
      file(3, "owned.m4b", checksum: "bbb"),
    ]
    let existing = [ExistingMediaFingerprint(
      checksumSHA256: "BBB",
      bookID: uuid(80),
      assetID: uuid(81),
      filename: "library-copy.m4b"
    )]
    let plan = ImportRecoveryPlanner.assess(files: files, existing: existing)

    XCTAssertEqual(plan.phase, .needsReview)
    XCTAssertEqual(plan.acceptedFileCount, 1)
    XCTAssertEqual(plan.duplicateFileCount, 2)
    XCTAssertEqual(plan.failedFileCount, 0)
    XCTAssertTrue(plan.canContinueWithAcceptedFiles)
    XCTAssertEqual(plan.files.map(\.disposition), [.accepted, .duplicate, .duplicate])
    XCTAssertEqual(plan.files[1].issue?.code, .duplicateInSelection)
    XCTAssertEqual(plan.files[2].issue?.code, .duplicateInLibrary)
    XCTAssertEqual(
      plan.files[2].issue?.remediations.first,
      ImportRemediation(kind: .openExistingBook, fileID: uuid(3), bookID: uuid(80))
    )
  }

  func testPartialSelectionKeepsValidFilesAndProvidesFileSpecificRecovery() {
    let plan = ImportRecoveryPlanner.assess(
      files: [
        file(1, "good.m4b", checksum: "good"),
        file(2, "broken.mp3", validity: .corrupt(details: "invalid frame")),
        file(3, "notes.txt", validity: .unsupported(format: "TXT")),
      ],
      existing: []
    )

    XCTAssertEqual(plan.phase, .needsReview)
    XCTAssertEqual(plan.acceptedFileCount, 1)
    XCTAssertEqual(plan.failedFileCount, 2)
    XCTAssertTrue(plan.canContinueWithAcceptedFiles)
    XCTAssertEqual(plan.files[1].issue?.affectedFilename, "broken.mp3")
    XCTAssertEqual(
      plan.files[1].issue?.remediations.map(\.kind),
      [.retryFile, .removeFile, .changeSelection]
    )
    XCTAssertEqual(
      plan.files[2].issue?.remediations.map(\.kind),
      [.removeFile, .changeSelection]
    )
    XCTAssertTrue(plan.files.allSatisfy { $0.issue?.sourceIsUnchanged ?? true })
  }

  func testAllCorruptIsRecoverableWhileAllUnsupportedIsTerminal() {
    let corrupt = ImportRecoveryPlanner.assess(
      files: [file(1, "broken.m4b", validity: .corrupt(details: nil))],
      existing: []
    )
    XCTAssertEqual(corrupt.phase, .failedRecoverable)
    XCTAssertFalse(corrupt.canContinueWithAcceptedFiles)

    let unsupported = ImportRecoveryPlanner.assess(
      files: [file(2, "notes.txt", validity: .unsupported(format: "TXT"))],
      existing: []
    )
    XCTAssertEqual(unsupported.phase, .failedTerminal)
    XCTAssertFalse(unsupported.files[0].issue?.isRecoverable ?? true)
  }

  func testLowStorageBlocksOtherwiseValidSelectionWithoutTouchingSources() throws {
    let storage = ImportStoragePreflight(
      requiredCopyBytes: 100,
      availableBytes: 115,
      safetyMarginBytes: 16
    )
    let plan = ImportRecoveryPlanner.assess(
      files: [file(1, "book.m4b", checksum: "aaa")],
      existing: [],
      storage: storage
    )

    XCTAssertEqual(plan.phase, .failedRecoverable)
    XCTAssertFalse(plan.canContinueWithAcceptedFiles)
    let issue = try XCTUnwrap(plan.globalIssues.first)
    XCTAssertEqual(issue.code, .insufficientStorage)
    XCTAssertEqual(issue.requiredBytes, 116)
    XCTAssertEqual(issue.availableBytes, 115)
    XCTAssertTrue(issue.sourceIsUnchanged)
    XCTAssertEqual(issue.remediations.map(\.kind), [.freeStorage, .changeSelection, .cancelImport])
  }

  func testMissingAndChecksumMismatchOfferScopedRetryRemoveAndReselect() {
    let plan = ImportRecoveryPlanner.assess(
      files: [
        file(1, "cloud.m4b", validity: .missing),
        file(
          2,
          "changed.mp3",
          validity: .checksumMismatch(expected: "old", actual: "new")
        ),
      ],
      existing: []
    )

    XCTAssertEqual(plan.phase, .failedRecoverable)
    XCTAssertEqual(plan.files.map { $0.issue?.code }, [.missingSource, .checksumMismatch])
    for status in plan.files {
      XCTAssertEqual(
        status.issue?.remediations.map(\.kind),
        [.retryFile, .removeFile, .changeSelection]
      )
      XCTAssertTrue(status.issue?.remediations.prefix(2).allSatisfy {
        $0.fileID == status.file.id
      } ?? false)
    }
  }

  func testStorageSummaryAccountsForEveryScopeAndBook() throws {
    let manifests = [
      try manifest(1, scope: .managedBook(uuid(70)), entries: [("Media/a", 100), ("Media/b", 20)]),
      try manifest(2, scope: .managedBook(uuid(71)), entries: [("Media/c", 50)]),
      try manifest(3, scope: .stagingJob(uuid(80)), entries: [("Staging/source", 30)]),
      try manifest(4, scope: .trashTransaction(uuid(90)), entries: [("Trash/audio", 40)]),
      try manifest(5, scope: .database, entries: [("Library.json", 10)]),
    ]
    let summary = StorageSummaryPlanner.summarize(manifests: manifests, availableBytes: 1_000)

    XCTAssertEqual(summary.managedMediaBytes, 170)
    XCTAssertEqual(summary.stagingBytes, 30)
    XCTAssertEqual(summary.trashBytes, 40)
    XCTAssertEqual(summary.databaseBytes, 10)
    XCTAssertEqual(summary.usedBytes, 250)
    XCTAssertEqual(summary.reclaimableBytes, 70)
    XCTAssertEqual(summary.availableBytes, 1_000)
    XCTAssertEqual(summary.perBook, [
      BookStorageSummary(bookID: uuid(70), byteCount: 120, fileCount: 2),
      BookStorageSummary(bookID: uuid(71), byteCount: 50, fileCount: 1),
    ])
  }

  func testStorageManifestsRejectUnsafeDuplicateAndNegativeEntries() throws {
    XCTAssertThrowsError(try manifest(1, scope: .database, entries: [("../escape", 1)]))
    XCTAssertThrowsError(try manifest(1, scope: .database, entries: [("/absolute", 1)]))
    XCTAssertThrowsError(try manifest(1, scope: .database, entries: [("Library.json", -1)]))
    XCTAssertThrowsError(try manifest(
      1,
      scope: .database,
      entries: [("Library.json", 1), ("Library.json", 2)]
    ))
  }

  func testStorageManifestDecoderCannotBypassEntryValidation() throws {
    let valid = try manifest(1, scope: .database, entries: [("Library.json", 1)])
    let encoded = try JSONEncoder().encode(valid)
    let original = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let invalidEntries: [[[String: Any]]] = [
      [["relativePath": "/absolute", "byteCount": 1]],
      [["relativePath": "../escape", "byteCount": 1]],
      [["relativePath": "Library.json", "byteCount": -1]],
      [
        ["relativePath": "Library.json", "byteCount": 1],
        ["relativePath": "Library.json", "byteCount": 2],
      ],
    ]

    for entries in invalidEntries {
      var object = original
      object["entries"] = entries
      let data = try JSONSerialization.data(withJSONObject: object)
      XCTAssertThrowsError(try JSONDecoder().decode(StorageManifest.self, from: data))
    }
  }

  func testStorageSummarySaturatesAllTotalsInsteadOfOverflowing() throws {
    let manifests = [
      try manifest(1, scope: .managedBook(uuid(70)), entries: [("Media/a", .max)]),
      try manifest(2, scope: .managedBook(uuid(70)), entries: [("Media/b", .max)]),
      try manifest(3, scope: .stagingJob(uuid(80)), entries: [("Staging/a", .max)]),
      try manifest(4, scope: .trashTransaction(uuid(90)), entries: [("Trash/a", .max)]),
      try manifest(5, scope: .database, entries: [("Library.json", .max)]),
    ]
    let summary = StorageSummaryPlanner.summarize(manifests: manifests, availableBytes: .max)

    XCTAssertEqual(summary.managedMediaBytes, .max)
    XCTAssertEqual(summary.perBook[0].byteCount, .max)
    XCTAssertEqual(summary.usedBytes, .max)
    XCTAssertEqual(summary.reclaimableBytes, .max)
  }

  func testFilesystemInventoryReportsManagedStagingTrashAndRealDatabaseBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "player-storage-inventory-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let bookID = uuid(70)
    let jobID = uuid(80)
    let trashID = uuid(90)
    let files: [(String, Int)] = [
      ("Media/\(bookID.uuidString.lowercased())/audio.m4b", 100),
      ("Staging/\(jobID.uuidString.lowercased())/source.m4b", 30),
      ("Trash/\(trashID.uuidString.lowercased())/audio.m4b", 40),
      ("Library.json", 17),
    ]
    for (relativePath, byteCount) in files {
      let url = root.appending(path: relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(repeating: 0x41, count: byteCount).write(to: url)
    }

    let inventory = try await FileSystemMediaManager(rootURL: root).storageInventory()
    let summary = StorageSummaryPlanner.summarize(
      manifests: inventory.manifests,
      availableBytes: inventory.availableBytes
    )
    XCTAssertEqual(summary.managedMediaBytes, 100)
    XCTAssertEqual(summary.stagingBytes, 30)
    XCTAssertEqual(summary.trashBytes, 40)
    XCTAssertEqual(summary.databaseBytes, 17)
    XCTAssertNotNil(summary.availableBytes)
    XCTAssertEqual(summary.perBook, [
      BookStorageSummary(bookID: bookID, byteCount: 100, fileCount: 1)
    ])
  }

  func testDiscardStagedFileIsConfinedAndNeverMutatesSource() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "player-storage-discard-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.deletingLastPathComponent().appending(path: "source-\(UUID()).m4b")
    defer { try? FileManager.default.removeItem(at: source) }
    let original = Data("source-remains-immutable".utf8)
    try original.write(to: source)
    let manager = FileSystemMediaManager(rootURL: root)
    let staged = try await manager.stage(sourceURL: source, jobID: uuid(80))

    try await manager.discardStagedFile(relativePath: staged.relativePath)

    XCTAssertEqual(try Data(contentsOf: source), original)
    await XCTAssertThrowsErrorAsync {
      try await manager.discardStorage(scope: .managedBook(self.uuid(70)))
    }
    await XCTAssertThrowsErrorAsync {
      try await manager.discardStagedFile(relativePath: "../source.m4b")
    }
  }

  @MainActor
  func testQueuedImportKeepsValidSiblingAndRetriesAndRemovesIndividualFailures() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "player-recovery-import-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sources = [
      ("Book 01.m4a", Data("valid".utf8)),
      ("Book 02.m4a", Data("transient-corrupt".utf8)),
      ("Book notes.txt", Data("unsupported".utf8)),
    ]
    let sourceURLs = try sources.map { filename, data -> URL in
      let url = root.appending(path: "Sources/\(filename)")
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: url)
      return url
    }
    let ids = (1...30).map { uuid(1_000 + $0) }
    let store = InMemoryLibraryStore()
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: FileSystemMediaManager(rootURL: root.appending(path: "PlayerData")),
      inspector: RecoveryAudioInspector(),
      playback: DeterministicPlaybackController(),
      clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
      ids: DeterministicPlayerIDGenerator(values: ids)
    ))
    await model.restore()

    let enqueuedJobID = await model.enqueueImport(ImportRequest(
      entryPoint: .files,
      selectedURLs: sourceURLs
    ))
    let jobID = try XCTUnwrap(enqueuedJobID)
    var job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.phase, .needsReview)
    XCTAssertEqual(job.recoveryPlan?.acceptedFileCount, 1)
    XCTAssertEqual(job.recoveryPlan?.failedFileCount, 2)
    XCTAssertEqual(job.proposals.flatMap(\.assets).count, 1)
    let corruptID = try XCTUnwrap(job.recoveryPlan?.files.first(where: {
      $0.issue?.code == .corruptAudio
    })?.file.id)
    let unsupportedID = try XCTUnwrap(job.recoveryPlan?.files.first(where: {
      $0.issue?.code == .unsupportedFormat
    })?.file.id)

    let retried = await model.retryImportFile(jobID: jobID, fileID: corruptID)
    XCTAssertTrue(retried)
    job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.recoveryPlan?.acceptedFileCount, 2)
    XCTAssertEqual(job.recoveryPlan?.failedFileCount, 1)
    XCTAssertEqual(job.recoveryPlan?.files.first(where: { $0.file.id == corruptID })?.disposition, .accepted)

    let removed = await model.removeImportFile(jobID: jobID, fileID: unsupportedID)
    XCTAssertTrue(removed)
    job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.recoveryPlan?.acceptedFileCount, 2)
    XCTAssertEqual(job.recoveryPlan?.failedFileCount, 0)
    XCTAssertEqual(job.phase, .ready)
    let continued = await model.continueImportWithAcceptedFiles(jobID: jobID)
    XCTAssertTrue(continued)
    XCTAssertEqual(model.library.importJobs.first(where: { $0.id == jobID })?.phase, .ready)
    XCTAssertEqual(try Data(contentsOf: sourceURLs[1]), Data("transient-corrupt".utf8))
    XCTAssertEqual(try Data(contentsOf: sourceURLs[2]), Data("unsupported".utf8))
  }

  @MainActor
  func testClearRecoverableStagingCancelsOnlyItsJobAndRetainsSourceReceipt() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "player-recovery-clear-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let jobID = uuid(80)
    let staging = root.appending(
      path: "Staging/\(jobID.uuidString.lowercased())/orphan.m4b"
    )
    try FileManager.default.createDirectory(
      at: staging.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(repeating: 0x41, count: 32).write(to: staging)
    let source = DurableImportSource(
      displayName: "Original.m4b",
      bookmarkData: nil,
      fallbackURLString: "file:///Original.m4b",
      isDirectory: false
    )
    let job = ImportJob(
      id: jobID,
      sourceFilename: source.displayName,
      phase: .failed,
      progress: ImportProgress(completed: 32, total: 32),
      stagedRelativePath: "Staging/\(jobID.uuidString.lowercased())/orphan.m4b",
      failure: ImportFailure(
        message: "Low storage",
        affectedFilename: source.displayName,
        sourceIsUnchanged: true,
        isRecoverable: true,
        reasonCode: ImportRecoveryIssueCode.insufficientStorage.rawValue,
        recoveryAction: .retry
      ),
      createdAt: .distantPast,
      updatedAt: .distantPast,
      queueCheckpoint: ImportQueueCheckpoint(entryPoint: .files, sources: [source]),
      recoveryPlan: ImportRecoveryPlanner.assess(
        files: [],
        existing: [],
        storage: ImportStoragePreflight(
          requiredCopyBytes: 64,
          availableBytes: 32,
          safetyMarginBytes: 0
        )
      )
    )
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [],
      importJobs: [job],
      currentBookID: nil
    ))
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: FileSystemMediaManager(rootURL: root),
      inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
      playback: DeterministicPlaybackController()
    ))
    await model.restore()
    let initialSummary = await model.refreshStorageSummary()
    XCTAssertEqual(initialSummary?.stagingBytes, 32)

    let didClear = await model.clearRecoverableStorage(scope: .stagingJob(jobID))
    XCTAssertTrue(didClear)

    let cleared = try XCTUnwrap(model.library.importJobs.first)
    XCTAssertEqual(cleared.phase, .cancelled)
    XCTAssertNil(cleared.recoveryPlan)
    XCTAssertEqual(cleared.queueCheckpoint?.sources, [source])
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    XCTAssertEqual(model.storageSummary?.stagingBytes, 0)
  }

  @MainActor
  func testCancelThroughConcreteMediaForwarderRemovesJobStagingAndRetainsSources() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "player-recovery-cancel-forwarder-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let jobID = uuid(81)
    let sourceURL = root.appending(path: "Source/original.m4b")
    try FileManager.default.createDirectory(
      at: sourceURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let sourceData = Data("source-receipt-remains".utf8)
    try sourceData.write(to: sourceURL)
    let base = FileSystemMediaManager(rootURL: root.appending(path: "PlayerData"))
    let staged = try await base.stage(sourceURL: sourceURL, jobID: jobID)
    let durableSource = DurableImportSource(
      displayName: sourceURL.lastPathComponent,
      bookmarkData: nil,
      fallbackURLString: sourceURL.absoluteString,
      isDirectory: false
    )
    let acquired = AcquiredAudioFile(
      staged: staged,
      sourceRelativePath: sourceURL.lastPathComponent,
      commonFolderName: nil
    )
    let job = ImportJob(
      id: jobID,
      sourceFilename: sourceURL.lastPathComponent,
      phase: .failed,
      progress: ImportProgress(completed: staged.byteCount, total: staged.byteCount),
      stagedRelativePath: staged.relativePath,
      failure: ImportFailure(
        message: "Synthetic inspection failure",
        affectedFilename: sourceURL.lastPathComponent,
        sourceIsUnchanged: true,
        isRecoverable: true,
        reasonCode: ImportRecoveryIssueCode.corruptAudio.rawValue,
        recoveryAction: .retry
      ),
      createdAt: .distantPast,
      updatedAt: .distantPast,
      queueCheckpoint: ImportQueueCheckpoint(
        entryPoint: .files,
        sources: [durableSource],
        acquired: [acquired],
        acquisitionComplete: true
      )
    )
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [],
      importJobs: [job],
      currentBookID: nil
    ))
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: ConcreteDiscardForwarder(base: base),
      inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
      playback: DeterministicPlaybackController()
    ))
    await model.restore()

    await model.cancelImport(jobID: jobID)

    let cancelled = try XCTUnwrap(model.library.importJobs.first)
    XCTAssertEqual(cancelled.phase, .cancelled)
    XCTAssertEqual(cancelled.queueCheckpoint?.sources, [durableSource])
    XCTAssertTrue(cancelled.queueCheckpoint?.acquired.isEmpty == true)
    let stagingDirectory = root.appending(
      path: "PlayerData/Staging/\(jobID.uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
  }

  @MainActor
  func testAbandonImportRemovesInboxRecordAndStagingButRetainsSource() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "player-recovery-abandon-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let jobID = uuid(82)
    let sourceURL = root.appending(path: "Source/original.m4b")
    try FileManager.default.createDirectory(
      at: sourceURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let sourceData = Data("source-survives-abandonment".utf8)
    try sourceData.write(to: sourceURL)
    let base = FileSystemMediaManager(rootURL: root.appending(path: "PlayerData"))
    let staged = try await base.stage(sourceURL: sourceURL, jobID: jobID)
    let job = ImportJob(
      id: jobID,
      sourceFilename: sourceURL.lastPathComponent,
      phase: .ready,
      progress: ImportProgress(completed: staged.byteCount, total: staged.byteCount),
      stagedRelativePath: staged.relativePath,
      createdAt: .distantPast,
      updatedAt: .distantPast,
      stagedAssets: [StagedImportAsset(
        assetID: uuid(83),
        stagedRelativePath: staged.relativePath,
        sourceRelativePath: sourceURL.lastPathComponent
      )]
    )
    let store = InMemoryLibraryStore(snapshot: LibrarySnapshot(
      books: [],
      importJobs: [job],
      currentBookID: nil
    ))
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: ConcreteDiscardForwarder(base: base),
      inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
      playback: DeterministicPlaybackController()
    ))
    await model.restore()

    let abandoned = await model.abandonImport(jobID: jobID)
    let persisted = await store.load()

    XCTAssertTrue(abandoned)
    XCTAssertTrue(model.library.importJobs.isEmpty)
    XCTAssertTrue(persisted.importJobs.isEmpty)
    let stagingDirectory = root.appending(
      path: "PlayerData/Staging/\(jobID.uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
    XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
  }

  func testSchema13MigrationClearsUnversionedRecoveryAndStorageDefaults() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "player-recovery-migration-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appending(path: "Library.json")
    let job = ImportJob(
      id: uuid(80),
      sourceFilename: "book.m4b",
      phase: .failed,
      progress: .none,
      createdAt: .distantPast,
      updatedAt: .distantPast,
      recoveryPlan: ImportRecoveryPlanner.assess(
        files: [file(1, "book.m4b", checksum: "abc")],
        existing: []
      )
    )
    let store = CodableLibraryStore(fileURL: fileURL)
    try await store.save(LibrarySnapshot(
      books: [],
      importJobs: [job],
      currentBookID: nil,
      storageManifests: [try manifest(
        3,
        scope: .stagingJob(job.id),
        entries: [("Staging/book.m4b", 12)]
      )]
    ))
    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    envelope["schemaVersion"] = 13
    try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL, options: .atomic)

    let migrated = try await store.load()
    XCTAssertNil(migrated.importJobs.first?.recoveryPlan)
    XCTAssertTrue(migrated.storageManifests.isEmpty)
    try await store.save(migrated)
    let saved = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    XCTAssertEqual(saved["schemaVersion"] as? Int, 15)
  }

  private func file(
    _ suffix: Int,
    _ filename: String,
    checksum: String? = nil,
    validity: ImportFileValidity = .valid
  ) -> ImportFileAssessment {
    ImportFileAssessment(
      id: uuid(suffix),
      relativePath: filename,
      filename: filename,
      byteCount: 100,
      checksumSHA256: checksum,
      format: URL(filePath: filename).pathExtension.uppercased(),
      validity: validity
    )
  }

  private func manifest(
    _ suffix: Int,
    scope: StorageScope,
    entries: [(String, Int64)]
  ) throws -> StorageManifest {
    try StorageManifest(
      id: uuid(suffix),
      scope: scope,
      entries: entries.map {
        StorageManifestEntry(relativePath: $0.0, byteCount: $0.1)
      },
      createdAt: .distantPast
    )
  }

  private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "f0000000-0000-0000-0000-%012d", suffix))!
  }

}

private actor RecoveryAudioInspector: AudioInspecting {
  private var transientCorruptFailed = false

  func inspect(url: URL) async throws -> InspectedAudio {
    let data = try Data(contentsOf: url)
    if data == Data("transient-corrupt".utf8), !transientCorruptFailed {
      transientCorruptFailed = true
      throw PlayerCoreError.unreadableAudio(url.lastPathComponent)
    }
    if data == Data("unsupported".utf8) {
      throw PlayerCoreError.unsupportedFile(url.lastPathComponent)
    }
    return InspectedAudio(
      title: "Book",
      authors: ["Test Author"],
      durationSeconds: 60,
      artworkData: nil,
      container: "M4A"
    )
  }
}

private actor ConcreteDiscardForwarder: MediaManaging {
  let base: FileSystemMediaManager

  init(base: FileSystemMediaManager) {
    self.base = base
  }

  func stage(sourceURL: URL, jobID: UUID) async throws -> StagedAudio {
    try await base.stage(sourceURL: sourceURL, jobID: jobID)
  }

  func stagedURL(for relativePath: String) async throws -> URL {
    try await base.stagedURL(for: relativePath)
  }

  func commit(
    _ staged: StagedAudio,
    bookID: UUID,
    assetID: UUID
  ) async throws -> ManagedAudio {
    try await base.commit(staged, bookID: bookID, assetID: assetID)
  }

  func rollback(_ managed: ManagedAudio) async throws {
    try await base.rollback(managed)
  }

  func managedURL(for relativePath: String) async throws -> URL {
    try await base.managedURL(for: relativePath)
  }

  func discardStaging(for jobID: UUID) async {
    await base.discardStaging(for: jobID)
  }
}

private func XCTAssertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected expression to throw.", file: file, line: line)
  } catch {}
}
