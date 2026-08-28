#if E2E
  import CryptoKit
  import Foundation
  import Observation
  import SwiftUI

  @MainActor
  @Observable
  final class E2EImportRecoveryBridge {
    struct FileEvidence: Equatable {
      let relativePath: String
      let byteCount: Int64
      let checksum: String
    }

    static let shared = E2EImportRecoveryBridge()

    private(set) var scenario: String?
    private(set) var rootURL: URL?
    private var sourceChecksums: [URL: String] = [:]
    private var initialManagedEvidence: [FileEvidence] = []
    private var initialStagingEvidence: [FileEvidence] = []
    private(set) var filesystemProjectionRevision = 0
    var sourceCount: Int { sourceChecksums.count }

    var isConfigured: Bool { scenario != nil }

    func configure(scenario: String, rootURL: URL, sourceURLs: [URL]) throws {
      self.scenario = scenario
      self.rootURL = rootURL
      sourceChecksums = try Dictionary(uniqueKeysWithValues: sourceURLs.map {
        ($0, try Self.checksum($0))
      })
      initialManagedEvidence = try filesystemInventory(in: "Media")
      initialStagingEvidence = try filesystemInventory(in: "Staging")
    }

    var sourcesAreUnchanged: Bool {
      !sourceChecksums.isEmpty && sourceChecksums.allSatisfy { url, expected in
        (try? Self.checksum(url)) == expected
      }
    }

    func stagingIsEmpty(jobID: UUID) -> Bool {
      guard let rootURL else { return false }
      let directory = rootURL
        .appending(path: "PlayerData/Staging", directoryHint: .isDirectory)
        .appending(path: jobID.uuidString.lowercased(), directoryHint: .isDirectory)
      guard FileManager.default.fileExists(atPath: directory.path) else { return true }
      return (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) ?? false
    }

    func invalidateFilesystemProjection() {
      filesystemProjectionRevision &+= 1
    }

    func lowSpaceIntegrity(stagingJobID: UUID) -> String {
      let expectedPath = "Staging/\(stagingJobID.uuidString.lowercased())/orphan.partial"
      guard let initial = initialStagingEvidence.first(where: { $0.relativePath == expectedPath })
      else {
        return "state=invalid:reason=missing-initial-staging-evidence"
      }
      do {
        let currentStaging = try filesystemInventory(in: "Staging")
        let currentManaged = try filesystemInventory(in: "Media")
        let cleared = currentStaging.contains(where: { $0.relativePath == expectedPath })
          ? 0 : initial.byteCount
        let baselineIntact = currentManaged == initialManagedEvidence
        let valid = sourcesAreUnchanged && cleared == initial.byteCount && baselineIntact
        return [
          "state=\(valid ? "valid" : "invalid")",
          "source-unchanged=\(sourcesAreUnchanged)",
          "staging-cleared=\(cleared)",
          "staging-path=\(initial.relativePath)",
          "staging-checksum=\(initial.checksum)",
          "managed-baseline-intact=\(baselineIntact)",
        ].joined(separator: ":")
      } catch {
        return "state=invalid:reason=filesystem-inventory-unavailable"
      }
    }

    func managedIntegrity(model: PlayerModel, jobID: UUID) -> String {
      do {
        let managed = try filesystemInventory(in: "Media")
        let duplicates = Self.duplicateCount(in: managed)
        let duplicateEvidence = Self.duplicateEvidence(in: managed)
        guard let job = model.library.importJobs.first(where: { $0.id == jobID }) else {
          return "state=invalid:reason=missing-job:managed-duplicates=\(duplicates)"
        }
        let accepted = job.recoveryPlan?.files.filter { $0.disposition == .accepted } ?? []
        let order = accepted.map { $0.file.id.uuidString.lowercased() }.joined(separator: ",")
        let excluded = sourceCount - accepted.count
        guard job.phase == .committed, let bookID = job.committedBookID,
          let book = model.library.books.first(where: { $0.id == bookID })
        else {
          let valid = sourcesAreUnchanged && duplicates == 0
          return [
            "state=\(valid ? "staged" : "invalid")",
            "accepted=\(accepted.count)",
            "excluded=\(excluded)",
            "managed-files=\(managed.count)",
            "managed-duplicates=\(duplicates)",
            "duplicate-evidence=\(duplicateEvidence)",
            "source-unchanged=\(sourcesAreUnchanged)",
            "order=\(order)",
          ].joined(separator: ":")
        }

        let initialByPath = Dictionary(
          uniqueKeysWithValues: initialManagedEvidence.map { ($0.relativePath, $0) }
        )
        let managedByPath = Dictionary(uniqueKeysWithValues: managed.map { ($0.relativePath, $0) })
        let committedPaths = Set(book.assets.map(\.managedRelativePath))
        let expectedPaths = Set(initialByPath.keys).union(committedPaths)
        let baselineIntact = initialByPath.allSatisfy { managedByPath[$0.key] == $0.value }
        let committedMatchSources = book.assets.allSatisfy { asset in
          guard let evidence = managedByPath[asset.managedRelativePath],
            let source = sourceChecksums.first(where: {
              $0.key.lastPathComponent == asset.originalFilename
            })?.value
          else { return false }
          return evidence.checksum == source
        }
        let inventoryExact = Set(managedByPath.keys) == expectedPaths
        let valid = sourcesAreUnchanged && duplicates == 0 && baselineIntact
          && committedMatchSources && inventoryExact
        let committedEvidence = managed.filter { committedPaths.contains($0.relativePath) }
          .map(Self.encoded).joined(separator: ",")
        return [
          "state=\(valid ? "valid" : "invalid")",
          "book=\(bookID.uuidString.lowercased())",
          "managed-files=\(managed.count)",
          "new-managed=\(committedEvidence.isEmpty ? 0 : committedPaths.count)",
          "managed-duplicates=\(duplicates)",
          "duplicate-evidence=\(duplicateEvidence)",
          "source-unchanged=\(sourcesAreUnchanged)",
          "baseline-intact=\(baselineIntact)",
          "inventory-exact=\(inventoryExact)",
          "source-checksums-match=\(committedMatchSources)",
          "managed=\(committedEvidence)",
        ].joined(separator: ":")
      } catch {
        return "state=invalid:reason=filesystem-inventory-unavailable"
      }
    }

    private func filesystemInventory(in directory: String) throws -> [FileEvidence] {
      guard let rootURL else { throw PlayerCoreError.fileOperation("Missing recovery root.") }
      let dataRoot = rootURL.appending(path: "PlayerData", directoryHint: .isDirectory)
      let directoryURL = dataRoot.appending(path: directory, directoryHint: .isDirectory)
      guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
      guard let enumerator = FileManager.default.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      ) else { throw PlayerCoreError.fileOperation("Could not enumerate recovery storage.") }
      var evidence: [FileEvidence] = []
      for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isSymbolicLink != true else {
          throw PlayerCoreError.fileOperation("Recovery storage contains a symbolic link.")
        }
        guard values.isRegularFile == true else { continue }
        let prefix = dataRoot.path + "/"
        guard url.path.hasPrefix(prefix) else {
          throw PlayerCoreError.fileOperation("Recovery storage escaped its fixture root.")
        }
        evidence.append(FileEvidence(
          relativePath: String(url.path.dropFirst(prefix.count)),
          byteCount: Int64(values.fileSize ?? 0),
          checksum: try Self.checksum(url)
        ))
      }
      return evidence.sorted { $0.relativePath < $1.relativePath }
    }

    private static func duplicateCount(in evidence: [FileEvidence]) -> Int {
      Dictionary(grouping: evidence, by: \.checksum).values.reduce(0) {
        $0 + max(0, $1.count - 1)
      }
    }

    private static func duplicateEvidence(in evidence: [FileEvidence]) -> String {
      let duplicates = Dictionary(grouping: evidence, by: \.checksum).values
        .filter { $0.count > 1 }
        .flatMap { $0 }
        .sorted { $0.relativePath < $1.relativePath }
      return duplicates.isEmpty ? "none" : duplicates.map(encoded).joined(separator: ",")
    }

    private static func encoded(_ evidence: FileEvidence) -> String {
      "\(evidence.relativePath)@\(evidence.byteCount)@\(evidence.checksum)"
    }

    private static func checksum(_ url: URL) throws -> String {
      let digest = SHA256.hash(data: try Data(contentsOf: url))
      return digest.map { String(format: "%02x", $0) }.joined()
    }
  }

  struct E2EImportRecoveryProbes: View {
    @Bindable var model: PlayerModel

    var body: some View {
      VStack(spacing: 0) {
        probe(id: "import-recovery-probe", value: stateValue)
        probe(id: "import-recovery-integrity-probe", value: integrityValue)
      }
      .frame(width: 1, height: 1)
      .clipped()
    }

    private func probe(id: String, value: String) -> some View {
      Color.clear
        .frame(width: 1, height: 1)
        .id(value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(id)
        .accessibilityIdentifier(id)
        .accessibilityValue(value)
    }

    private var stateValue: String {
      let bridge = E2EImportRecoveryBridge.shared
      _ = bridge.filesystemProjectionRevision
      let scenario = bridge.scenario ?? "none"
      let jobID = scenario == "low-space"
        ? UUID(uuidString: "61000000-0000-0000-0000-000000000001")!
        : UUID(uuidString: "61000000-0000-0000-0000-000000000002")!
      guard let job = model.library.importJobs.first(where: { $0.id == jobID }) else {
        return "scenario=\(scenario):job=missing:source-unchanged=\(bridge.sourcesAreUnchanged)"
      }
      if scenario == "all-corrupt", job.phase == .cancelled {
        let sourceCount = job.queueCheckpoint?.sources.count ?? 0
        return "scenario=all-corrupt:job=\(jobID.uuidString.lowercased()):phase=cancelled:staging=\(bridge.stagingIsEmpty(jobID: jobID) ? 0 : 1):sources=\(sourceCount):source-unchanged=\(bridge.sourcesAreUnchanged)"
      }
      let accepted = job.recoveryPlan?.acceptedFileCount ?? job.proposals.flatMap(\.assets).count
      return "scenario=\(scenario):job=\(jobID.uuidString.lowercased()):phase=\(job.phase.rawValue):accepted=\(accepted):source-unchanged=\(bridge.sourcesAreUnchanged)"
    }

    private var integrityValue: String {
      let bridge = E2EImportRecoveryBridge.shared
      switch bridge.scenario {
      case "low-space":
        let stagingJobID = UUID(uuidString: "61000000-0000-0000-0000-000000000003")!
        return "scenario=low-space:\(bridge.lowSpaceIntegrity(stagingJobID: stagingJobID))"
      case "mixed", "managed-duplicate":
        let jobID = UUID(uuidString: "61000000-0000-0000-0000-000000000002")!
        return "scenario=\(bridge.scenario!):\(bridge.managedIntegrity(model: model, jobID: jobID))"
      default:
        return "scenario=\(bridge.scenario ?? "none"):source-unchanged=\(bridge.sourcesAreUnchanged)"
      }
    }
  }

  enum E2EImportRecoveryEnvironment {
    private static let lowSpaceJobID = UUID(uuidString: "61000000-0000-0000-0000-000000000001")!
    private static let mixedJobID = UUID(uuidString: "61000000-0000-0000-0000-000000000002")!
    private static let stagingJobID = UUID(uuidString: "61000000-0000-0000-0000-000000000003")!
    private static let existingBookID = UUID(uuidString: "61000000-0000-0000-0000-000000000201")!
    private static let trashID = UUID(uuidString: "61000000-0000-0000-0000-000000000301")!
    private static let date = Date(timeIntervalSince1970: 1_700_040_000)

    @MainActor
    static func make(reset: Bool, scenario: String) throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EImportRecoveryStorage",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      let dataRoot = root.appending(path: "PlayerData", directoryHint: .isDirectory)
      let inputs = root.appending(path: "Synthetic Sources", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)

      let filenames: [String]
      switch scenario {
      case "low-space": filenames = ["01-space-signal.m4a"]
      case "all-corrupt": filenames = ["01-damaged-tone.m4a", "02-truncated-tone.m4a"]
      default:
        filenames = [
          "01-clear-signal.m4a", "02-retry-signal.m4a", "notes.txt",
          "01-clear-signal-copy.m4a", "existing-signal.m4b",
        ]
      }
      let sourceURLs = try filenames.enumerated().map { index, filename in
        let url = inputs.appending(path: filename)
        try deterministicData(label: filename, byteCount: 96 + index * 16).write(
          to: url,
          options: .atomic
        )
        return url
      }

      let existing = try existingBook(root: dataRoot)
      let seed: LibrarySnapshot
      switch scenario {
      case "low-space":
        seed = try lowSpaceSnapshot(sourceURLs: sourceURLs, existing: existing, root: dataRoot)
      case "all-corrupt":
        seed = try allCorruptSnapshot(sourceURLs: sourceURLs, existing: existing, root: dataRoot)
      default:
        seed = try mixedSnapshot(sourceURLs: sourceURLs, existing: existing, root: dataRoot)
      }
      try createRecoverableStorage(root: dataRoot, existing: existing)
      if scenario == "managed-duplicate" {
        try createDuplicateManagedCopy(root: dataRoot, existing: existing)
      }
      try E2EImportRecoveryBridge.shared.configure(
        scenario: scenario,
        rootURL: root,
        sourceURLs: sourceURLs
      )

      let media = E2ERecoveryMediaManager(
        base: FileSystemMediaManager(rootURL: dataRoot),
        stagingJobID: stagingJobID,
        trashID: trashID,
        existingBookID: existingBookID
      )
      let ids = (401...480).compactMap {
        UUID(uuidString: String(format: "61000000-0000-0000-0000-%012d", $0))
      }
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: dataRoot.appending(path: "Library.json")),
          seed: seed
        ),
        media: media,
        inspector: E2ERecoveryInspector(),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func lowSpaceSnapshot(
      sourceURLs: [URL], existing: Book, root: URL
    ) throws -> LibrarySnapshot {
      let file = try stagedAssessment(
        id: UUID(uuidString: "61000000-0000-0000-0000-000000000101")!,
        jobID: lowSpaceJobID,
        sourceURL: sourceURLs[0],
        checksum: "space-checksum",
        validity: .valid,
        root: root
      )
      let inspected = inspectedItem(file: file, assetID: uuid(411), checksum: "space-checksum")
      let plan = ImportRecoveryPlanner.assess(
        files: [file],
        existing: existingFingerprints(existing),
        storage: ImportStoragePreflight(
          requiredCopyBytes: 8_700,
          availableBytes: 8_192,
          safetyMarginBytes: 0
        )
      )
      let job = ImportJob(
        id: lowSpaceJobID,
        sourceFilename: "01-space-signal.m4a",
        phase: .failed,
        progress: .none,
        failure: ImportFailure(
          message: plan.globalIssues[0].message,
          affectedFilename: nil,
          sourceIsUnchanged: true,
          isRecoverable: true,
          reasonCode: ImportRecoveryIssueCode.insufficientStorage.rawValue,
          recoveryAction: .retry
        ),
        createdAt: date,
        updatedAt: date,
        queueCheckpoint: checkpoint(sourceURLs: sourceURLs, files: [file], inspected: [inspected]),
        recoveryPlan: plan
      )
      return try snapshot(books: [existing], jobs: [job, orphanStagingJob()], existing: existing)
    }

    private static func mixedSnapshot(
      sourceURLs: [URL], existing: Book, root: URL
    ) throws -> LibrarySnapshot {
      let ids = (101...105).map(uuid)
      let checksums = ["valid-checksum", "retry-checksum", "unsupported-checksum", "valid-checksum", "library-checksum"]
      let validity: [ImportFileValidity] = [
        .valid, .corrupt(details: "synthetic decode was interrupted"),
        .unsupported(format: "TXT"), .valid, .valid,
      ]
      let files = try ids.indices.map { index in
        return try stagedAssessment(
          id: ids[index],
          jobID: mixedJobID,
          sourceURL: sourceURLs[index],
          checksum: checksums[index],
          validity: validity[index],
          root: root
        )
      }
      let plan = ImportRecoveryPlanner.assess(
        files: files,
        existing: existingFingerprints(existing)
      )
      let inspected = [
        inspectedItem(file: files[0], assetID: uuid(421), checksum: checksums[0]),
        inspectedItem(file: files[3], assetID: uuid(423), checksum: checksums[3]),
        inspectedItem(file: files[4], assetID: uuid(424), checksum: checksums[4]),
      ]
      let proposal = proposal(from: [inspected[0]], id: uuid(425), bookID: uuid(426))
      let job = ImportJob(
        id: mixedJobID,
        sourceFilename: "5 selected items",
        phase: .needsReview,
        progress: ImportProgress(completed: files.reduce(0) { $0 + $1.byteCount }, total: nil),
        proposal: proposal,
        createdAt: date,
        updatedAt: date,
        stagedAssets: [stagedAsset(inspected[0])],
        queueCheckpoint: checkpoint(sourceURLs: sourceURLs, files: files, inspected: inspected),
        recoveryPlan: plan
      )
      return try snapshot(books: [existing], jobs: [job, orphanStagingJob()], existing: existing)
    }

    private static func allCorruptSnapshot(
      sourceURLs: [URL], existing: Book, root: URL
    ) throws -> LibrarySnapshot {
      let files = try sourceURLs.enumerated().map { index, source in
        try stagedAssessment(
          id: uuid(102 + index),
          jobID: mixedJobID,
          sourceURL: source,
          checksum: "corrupt-\(index)",
          validity: .corrupt(details: "synthetic audio is incomplete"),
          root: root
        )
      }
      let plan = ImportRecoveryPlanner.assess(
        files: files,
        existing: existingFingerprints(existing)
      )
      let job = ImportJob(
        id: mixedJobID,
        sourceFilename: "2 selected items",
        phase: .failed,
        progress: .none,
        failure: ImportFailure(
          message: "Two synthetic audio files could not be read.",
          affectedFilename: nil,
          sourceIsUnchanged: true,
          isRecoverable: true,
          reasonCode: ImportRecoveryIssueCode.corruptAudio.rawValue,
          recoveryAction: .retry
        ),
        createdAt: date,
        updatedAt: date,
        queueCheckpoint: checkpoint(sourceURLs: sourceURLs, files: files, inspected: []),
        recoveryPlan: plan
      )
      return try snapshot(books: [existing], jobs: [job], existing: existing)
    }

    private static func snapshot(
      books: [Book], jobs: [ImportJob], existing: Book
    ) throws -> LibrarySnapshot {
      let discarded = Book(
        id: uuid(202), title: "Discarded Synthetic Sample", authors: ["Open Fixture Lab"],
        durationSeconds: 30, artworkData: nil,
        assets: [AudioAsset(
          id: uuid(203), originalFilename: "discarded.m4a", managedRelativePath: "",
          checksumSHA256: "discarded", byteCount: 512, durationSeconds: 30, container: "M4A"
        )], dateAdded: date
      )
      let trash = LibraryTrashTransaction(
        id: trashID, book: discarded, originalBookIndex: 1,
        mediaPolicy: .moveManagedMediaToTrash,
        mediaManifest: TrashedMediaManifest(
          transactionID: trashID, bookID: discarded.id,
          originalDirectoryRelativePath: "Media/\(discarded.id.uuidString.lowercased())",
          trashDirectoryRelativePath: "Trash/\(trashID.uuidString.lowercased())",
          byteCount: 512
        ),
        upNextIndex: nil, collectionPlacements: [], wasCurrentBook: false,
        playbackPosition: nil, positionEvents: [], metadataTransactions: [],
        removedAt: date, status: .recoverable, restoredAt: nil
      )
      return LibrarySnapshot(
        books: books, importJobs: jobs, currentBookID: nil,
        trashTransactions: [trash], storageManifests: try storageManifests(existing: existing)
      )
    }

    private static func existingBook(root: URL) throws -> Book {
      let first = AudioAsset(
        id: uuid(211), originalFilename: "existing-signal.m4b",
        managedRelativePath: "Media/\(existingBookID.uuidString.lowercased())/part-1.m4b",
        checksumSHA256: "library-checksum", byteCount: 2_048, durationSeconds: 60,
        container: "M4B", importOrder: 0
      )
      let second = AudioAsset(
        id: uuid(212), originalFilename: "existing-signal-part-2.m4b",
        managedRelativePath: "Media/\(existingBookID.uuidString.lowercased())/part-2.m4b",
        checksumSHA256: "library-second-checksum", byteCount: 2_048, durationSeconds: 60,
        container: "M4B", timelineStartSeconds: 60, importOrder: 1
      )
      return Book(
        id: existingBookID, title: "Existing Signal", authors: ["Open Fixture Lab"],
        durationSeconds: 120, artworkData: nil, assets: [first, second], dateAdded: date,
        chapters: [Chapter(
          id: "existing-opening", title: "Opening", startSeconds: 0,
          durationSeconds: 120, source: .embedded, assetID: first.id
        )]
      )
    }

    private static func createRecoverableStorage(root: URL, existing: Book) throws {
      for asset in existing.assets {
        let url = root.appending(path: asset.managedRelativePath)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try deterministicData(label: asset.originalFilename, byteCount: 2_048).write(to: url)
      }
      let staging = root.appending(
        path: "Staging/\(stagingJobID.uuidString.lowercased())/orphan.partial"
      )
      try FileManager.default.createDirectory(
        at: staging.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try Data(repeating: 0x53, count: 768).write(to: staging)
      let trash = root.appending(path: "Trash/\(trashID.uuidString.lowercased())/discarded.m4a")
      try FileManager.default.createDirectory(
        at: trash.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try Data(repeating: 0x54, count: 512).write(to: trash)
    }

    private static func createDuplicateManagedCopy(root: URL, existing: Book) throws {
      guard let first = existing.assets.first else {
        throw PlayerCoreError.fileOperation("Missing duplicate source asset.")
      }
      let source = root.appending(path: first.managedRelativePath)
      let duplicate = root.appending(
        path: "Media/61000000-0000-0000-0000-000000000999/duplicate-part-1.m4b"
      )
      try FileManager.default.createDirectory(
        at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try Data(contentsOf: source).write(to: duplicate, options: .atomic)
    }

    private static func stagedAssessment(
      id: UUID, jobID: UUID, sourceURL: URL, checksum: String,
      validity: ImportFileValidity, root: URL
    ) throws -> ImportFileAssessment {
      let relativePath = "Staging/\(jobID.uuidString.lowercased())/\(sourceURL.lastPathComponent)"
      let staged = root.appending(path: relativePath)
      try FileManager.default.createDirectory(
        at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try Data(contentsOf: sourceURL).write(to: staged, options: .atomic)
      let bytes = Int64((try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      return ImportFileAssessment(
        id: id, relativePath: relativePath, filename: sourceURL.lastPathComponent,
        byteCount: bytes, checksumSHA256: checksum,
        format: sourceURL.pathExtension.uppercased(), validity: validity
      )
    }

    private static func checkpoint(
      sourceURLs: [URL], files: [ImportFileAssessment], inspected: [InspectedImportAsset]
    ) -> ImportQueueCheckpoint {
      ImportQueueCheckpoint(
        entryPoint: .files,
        sources: sourceURLs.map {
          DurableImportSource(
            displayName: $0.lastPathComponent, bookmarkData: nil,
            fallbackURLString: $0.absoluteString, isDirectory: false
          )
        },
        acquired: files.map {
          AcquiredAudioFile(
            staged: StagedAudio(
              relativePath: $0.relativePath, originalFilename: $0.filename,
              checksumSHA256: $0.checksumSHA256 ?? "", byteCount: $0.byteCount
            ), sourceRelativePath: $0.filename, commonFolderName: "Recovery Selection"
          )
        },
        inspected: inspected,
        acquisitionComplete: true
      )
    }

    private static func inspectedItem(
      file: ImportFileAssessment, assetID: UUID, checksum: String
    ) -> InspectedImportAsset {
      let acquired = AcquiredAudioFile(
        staged: StagedAudio(
          relativePath: file.relativePath, originalFilename: file.filename,
          checksumSHA256: checksum, byteCount: file.byteCount
        ), sourceRelativePath: file.filename, commonFolderName: "Recovery Selection"
      )
      return InspectedImportAsset(
        asset: AudioAsset(
          id: assetID, originalFilename: file.filename, managedRelativePath: "",
          checksumSHA256: checksum, byteCount: file.byteCount, durationSeconds: 30,
          container: "M4A", importOrder: Int(file.id.uuidString.suffix(3)) ?? 0
        ),
        inspected: InspectedAudio(
          title: "Recovery Selection", authors: ["Open Fixture Lab"],
          durationSeconds: 30, artworkData: nil, container: "M4A"
        ),
        acquired: acquired
      )
    }

    private static func proposal(
      from inspected: [InspectedImportAsset], id: UUID, bookID: UUID
    ) -> BookProposal {
      let assets = inspected.map(\.asset)
      return BookProposal(
        id: id, proposedBookID: bookID, title: "Recovery Selection",
        authors: ["Open Fixture Lab"], durationSeconds: Double(assets.count * 30),
        artworkData: nil, asset: assets[0], warnings: [],
        additionalAssets: Array(assets.dropFirst())
      )
    }

    private static func stagedAsset(_ inspected: InspectedImportAsset) -> StagedImportAsset {
      StagedImportAsset(
        assetID: inspected.asset.id,
        stagedRelativePath: inspected.acquired.staged.relativePath,
        sourceRelativePath: inspected.acquired.sourceRelativePath
      )
    }

    private static func orphanStagingJob() -> ImportJob {
      ImportJob(
        id: stagingJobID, sourceFilename: "Interrupted synthetic import", phase: .failed,
        progress: .none,
        failure: ImportFailure(
          message: "An interrupted synthetic import can be cleared.", affectedFilename: nil,
          sourceIsUnchanged: true, isRecoverable: true, reasonCode: "import-interrupted",
          recoveryAction: .retry
        ),
        createdAt: date, updatedAt: date
      )
    }

    private static func existingFingerprints(_ book: Book) -> [ExistingMediaFingerprint] {
      book.assets.map {
        ExistingMediaFingerprint(
          checksumSHA256: $0.checksumSHA256, bookID: book.id,
          assetID: $0.id, filename: $0.originalFilename
        )
      }
    }

    private static func storageManifests(existing: Book) throws -> [StorageManifest] {
      [
        try StorageManifest(
          id: uuid(501), scope: .managedBook(existing.id),
          entries: [
            StorageManifestEntry(relativePath: "part-1.m4b", byteCount: 2_048),
            StorageManifestEntry(relativePath: "part-2.m4b", byteCount: 2_048),
          ], createdAt: date
        ),
        try StorageManifest(
          id: uuid(502), scope: .stagingJob(stagingJobID),
          entries: [StorageManifestEntry(relativePath: "orphan.partial", byteCount: 768)],
          createdAt: date
        ),
        try StorageManifest(
          id: uuid(503), scope: .trashTransaction(trashID),
          entries: [StorageManifestEntry(relativePath: "discarded.m4a", byteCount: 512)],
          createdAt: date
        ),
        try StorageManifest(
          id: uuid(504), scope: .database,
          entries: [StorageManifestEntry(relativePath: "Library.json", byteCount: 256)],
          createdAt: date
        ),
      ]
    }

    private static func deterministicData(label: String, byteCount: Int) -> Data {
      let seed = Array(label.utf8)
      return Data((0..<byteCount).map { seed[$0 % seed.count] })
    }

    private static func uuid(_ suffix: Int) -> UUID {
      UUID(uuidString: String(format: "61000000-0000-0000-0000-%012d", suffix))!
    }
  }

  private actor E2ERecoveryInspector: AudioInspecting {
    func inspect(url: URL) async throws -> InspectedAudio {
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw PlayerCoreError.fileOperation("The staged synthetic audio is unavailable.")
      }
      return InspectedAudio(
        title: "Recovery Selection", authors: ["Open Fixture Lab"], durationSeconds: 30,
        artworkData: nil, container: "M4A"
      )
    }
  }

  private actor E2ERecoveryMediaManager: MediaManaging {
    let base: FileSystemMediaManager
    let stagingJobID: UUID
    let trashID: UUID
    let existingBookID: UUID
    var stagingPresent = true
    var trashPresent = true

    init(
      base: FileSystemMediaManager,
      stagingJobID: UUID,
      trashID: UUID,
      existingBookID: UUID
    ) {
      self.base = base
      self.stagingJobID = stagingJobID
      self.trashID = trashID
      self.existingBookID = existingBookID
    }

    func stage(sourceURL: URL, jobID: UUID) async throws -> StagedAudio {
      try await base.stage(sourceURL: sourceURL, jobID: jobID)
    }
    func stagedURL(for relativePath: String) async throws -> URL {
      try await base.stagedURL(for: relativePath)
    }
    func commit(_ staged: StagedAudio, bookID: UUID, assetID: UUID) async throws -> ManagedAudio {
      let managed = try await base.commit(staged, bookID: bookID, assetID: assetID)
      await E2EImportRecoveryBridge.shared.invalidateFilesystemProjection()
      return managed
    }
    func rollback(_ managed: ManagedAudio) async throws { try await base.rollback(managed) }
    func managedURL(for relativePath: String) async throws -> URL {
      try await base.managedURL(for: relativePath)
    }
    func discardStaging(for jobID: UUID) async {
      await base.discardStaging(for: jobID)
      await E2EImportRecoveryBridge.shared.invalidateFilesystemProjection()
    }
    func acquireSelection(_ selectedURLs: [URL], jobID: UUID) async throws -> [AcquiredAudioFile] {
      try await base.acquireSelection(selectedURLs, jobID: jobID)
    }
    func stageArchive(sourceURL: URL, jobID: UUID) async throws -> StagedAudio {
      try await base.stageArchive(sourceURL: sourceURL, jobID: jobID)
    }
    func zipWorkspace(for jobID: UUID) async throws -> ZipImportWorkspace {
      try await base.zipWorkspace(for: jobID)
    }
    func acquireExtractedAudio(
      _ files: [ZipExtractedFile], in workspace: ZipImportWorkspace, jobID: UUID
    ) async throws -> [AcquiredAudioFile] {
      try await base.acquireExtractedAudio(files, in: workspace, jobID: jobID)
    }
    func moveManagedMediaToTrash(
      bookID: UUID, transactionID: UUID
    ) async throws -> TrashedMediaManifest {
      try await base.moveManagedMediaToTrash(bookID: bookID, transactionID: transactionID)
    }
    func restoreManagedMediaFromTrash(_ manifest: TrashedMediaManifest) async throws {
      try await base.restoreManagedMediaFromTrash(manifest)
    }
    func discardStagedFile(relativePath: String) async throws {
      try await base.discardStagedFile(relativePath: relativePath)
    }
    func discardStorage(scope: StorageScope) async throws {
      try await base.discardStorage(scope: scope)
      if case .stagingJob(let id) = scope, id == stagingJobID { stagingPresent = false }
      if case .trashTransaction(let id) = scope, id == trashID { trashPresent = false }
      await E2EImportRecoveryBridge.shared.invalidateFilesystemProjection()
    }
    func storageInventory() async throws -> StorageInventorySnapshot {
      var manifests: [StorageManifest] = [
        try StorageManifest(
          id: UUID(uuidString: "61000000-0000-0000-0000-000000000501")!,
          scope: .managedBook(existingBookID),
          entries: [
            StorageManifestEntry(relativePath: "part-1.m4b", byteCount: 2_048),
            StorageManifestEntry(relativePath: "part-2.m4b", byteCount: 2_048),
          ], createdAt: Date(timeIntervalSince1970: 1_700_040_000)
        ),
        try StorageManifest(
          id: UUID(uuidString: "61000000-0000-0000-0000-000000000504")!, scope: .database,
          entries: [StorageManifestEntry(relativePath: "Library.json", byteCount: 256)],
          createdAt: Date(timeIntervalSince1970: 1_700_040_000)
        ),
      ]
      if stagingPresent {
        manifests.append(try StorageManifest(
          id: UUID(uuidString: "61000000-0000-0000-0000-000000000502")!,
          scope: .stagingJob(stagingJobID),
          entries: [StorageManifestEntry(relativePath: "orphan.partial", byteCount: 768)],
          createdAt: Date(timeIntervalSince1970: 1_700_040_000)
        ))
      }
      if trashPresent {
        manifests.append(try StorageManifest(
          id: UUID(uuidString: "61000000-0000-0000-0000-000000000503")!,
          scope: .trashTransaction(trashID),
          entries: [StorageManifestEntry(relativePath: "discarded.m4a", byteCount: 512)],
          createdAt: Date(timeIntervalSince1970: 1_700_040_000)
        ))
      }
      let reclaimed = (stagingPresent ? 0 : 768) + (trashPresent ? 0 : 512)
      return StorageInventorySnapshot(manifests: manifests, availableBytes: Int64(8_192 + reclaimed))
    }
  }
#endif
