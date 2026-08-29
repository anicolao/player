import Foundation

#if E2E
  @MainActor
  final class E2EOfflineRecoveryBridge {
    static let shared = E2EOfflineRecoveryBridge()
    static let corruptPrimaryBytes = Data("corrupt primary with private catalog bytes".utf8)

    private(set) var isConfigured = false
    private(set) var diagnosticsValue = "diagnostics:pending"
    private(set) var actionRevision = 0
    private var forbiddenValues: [String] = []
    private var scenario: E2EOfflineRecoveryScenario = .automaticRestore
    private var root: URL?
    private var launchStorageFailurePending = false

    private init() {}

    func configure(
      scenario: E2EOfflineRecoveryScenario,
      root: URL,
      reset: Bool
    ) {
      if reset || !isConfigured || self.scenario != scenario || self.root != root {
        launchStorageFailurePending = scenario == .launchStorageRetry
        actionRevision = 0
      }
      isConfigured = true
      diagnosticsValue = "diagnostics:pending"
      self.scenario = scenario
      self.root = root
    }

    func setForbiddenValues(_ forbiddenValues: [String]) {
      self.forbiddenValues = forbiddenValues
    }

    func consumeLaunchStorageFailure() -> Bool {
      guard launchStorageFailurePending else { return false }
      launchStorageFailurePending = false
      actionRevision += 1
      return true
    }

    func recordPersistenceLoad() {
      actionRevision += 1
    }

    func recordBoundaryOutcome() {
      actionRevision += 1
    }

    func saveSupportBundleToFiles(_ bundle: PreparedSupportBundle) throws {
      _ = try sanitizedReport(in: bundle)
      guard let root else {
        throw PlayerCoreError.fileOperation("The recovery fixture root is unavailable.")
      }
      let files = root.appending(path: "E2EFiles", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
      let destination = files.appending(path: bundle.url.lastPathComponent)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: bundle.url, to: destination)
      actionRevision += 1
    }

    var preservationValue: String {
      guard let root else { return "recovery-evidence:unconfigured" }
      let primary = root.appending(path: "Library.json")
      let primaryBytes = try? Data(contentsOf: primary)
      let primaryState: String
      if primaryBytes == Self.corruptPrimaryBytes {
        primaryState = "corrupt"
      } else if primaryBytes == nil {
        primaryState = "absent"
      } else {
        primaryState = "readable"
      }
      let catalogEvidence = regularEntryCount(
        at: root.appending(path: "Recovery/Quarantine", directoryHint: .isDirectory)
      )
      let orphanEvidence = regularEntryCount(
        at: root.appending(path: "Recovery/Orphans", directoryHint: .isDirectory)
      )
      let filesExports = regularEntryCount(
        at: root.appending(path: "E2EFiles", directoryHint: .isDirectory)
      )
      let preparedExports = regularEntryCount(
        at: root.appending(path: "SupportExports", directoryHint: .isDirectory)
      )
      let recoveredAudioName = "d1000000-0000-0000-0000-000000000002.m4b"
      let managedAudioPreserved = recursiveEntryExists(named: recoveredAudioName, under: root)
      return "recovery-evidence:primary=\(primaryState):catalog=\(catalogEvidence):"
        + "orphans=\(orphanEvidence):audio=\(managedAudioPreserved):"
        + "files=\(filesExports):prepared=\(preparedExports):revision=\(actionRevision)"
    }

    func verify(_ bundle: PreparedSupportBundle) throws {
      let report = try sanitizedReport(in: bundle)
      guard report.bookCount == 1, report.audioAssetCount == 1,
        report.quarantinedManagedBookCount == 1,
        report.quarantinedStagingJobCount == 1,
        report.quarantinedTrashTransactionCount == 1,
        report.localFeaturesRequireInternet == false
      else {
        throw PlayerCoreError.fileOperation(
          "The support report did not contain expected safe facts.")
      }
      diagnosticsValue = "diagnostics:sanitized=true:forbidden=absent:offline=true:quarantined=3"
      actionRevision += 1
    }

    private func sanitizedReport(in bundle: PreparedSupportBundle) throws -> SanitizedSupportReport
    {
      let data = try Data(contentsOf: bundle.url)
      guard let text = String(data: data, encoding: .utf8) else {
        throw PlayerCoreError.fileOperation("The support report was not UTF-8 JSON.")
      }
      guard forbiddenValues.allSatisfy({ !text.localizedCaseInsensitiveContains($0) }) else {
        throw PlayerCoreError.fileOperation("The support report exposed forbidden fixture data.")
      }
      guard !text.contains("positionMilliseconds"), !text.contains("playbackPosition"),
        !text.contains("sleepTimer")
      else {
        throw PlayerCoreError.fileOperation("The support report exposed listening history.")
      }
      return try JSONDecoder.playerDecoder.decode(SanitizedSupportReport.self, from: data)
    }

    private func regularEntryCount(at directory: URL) -> Int {
      ((try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []).count
    }

    private func recursiveEntryExists(named name: String, under directory: URL) -> Bool {
      guard
        let enumerator = FileManager.default.enumerator(
          at: directory,
          includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles]
        )
      else { return false }
      for case let url as URL in enumerator where url.lastPathComponent == name {
        return true
      }
      return false
    }
  }

  actor E2ETransientRecoveryStore: LibraryPersisting {
    private let base: CodableLibraryStore
    private let issue: StartupRecoveryIssue
    private var remainingFailures: Int

    init(
      base: CodableLibraryStore,
      issue: StartupRecoveryIssue,
      failuresBeforeSuccess: Int
    ) {
      self.base = base
      self.issue = issue
      remainingFailures = failuresBeforeSuccess
    }

    func load() async throws -> LibrarySnapshot {
      await MainActor.run { E2EOfflineRecoveryBridge.shared.recordPersistenceLoad() }
      if remainingFailures > 0 {
        remainingFailures -= 1
        throw PlayerCoreError.fileOperation("The deterministic store is temporarily unavailable.")
      }
      return try await base.load()
    }

    func save(_ snapshot: LibrarySnapshot) async throws { try await base.save(snapshot) }
    func automaticBackups() async -> [AutomaticLibraryBackup] { await base.automaticBackups() }
    func restoreLatestAutomaticBackup() async throws -> LibrarySnapshot {
      try await base.restoreLatestAutomaticBackup()
    }
    func startupRecoveryStatus() async -> StartupRecoveryStatus {
      StartupRecoveryStatus(
        issue: issue,
        validAutomaticBackupCount: 0,
        invalidAutomaticBackupCount: 0
      )
    }
    func recoverLatestAutomaticBackupPreservingPrimary() async throws -> LibrarySnapshot {
      try await base.recoverLatestAutomaticBackupPreservingPrimary()
    }
    func beginFreshLibraryPreservingPrimary() async throws -> LibrarySnapshot {
      try await base.beginFreshLibraryPreservingPrimary()
    }
  }

  actor E2EFailingSupportDiagnosticsManager: SupportDiagnosticsManaging {
    func prepareBundle(
      library: LibrarySnapshot,
      recovery: StartupRecoveryStatus?,
      reconciliation: StartupStorageReconciliation?,
      automaticBackupCount: Int
    ) throws -> PreparedSupportBundle {
      throw PlayerCoreError.fileOperation(
        "The deterministic support report could not be written to local storage."
      )
    }

    func discardPreparedBundle(_ bundle: PreparedSupportBundle) {}
  }
#endif
