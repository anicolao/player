import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class PlayerModel {
  private(set) var library: LibrarySnapshot = .empty
  private(set) var playbackState: PlaybackState = .unloaded
  private(set) var isRestored = false
  private(set) var presentationErrors: [PlayerPresentationError] = []
  private(set) var storageSummary: StorageSummary?
  private(set) var startupRecoveryStatus: StartupRecoveryStatus?
  private(set) var startupReconciliation: StartupStorageReconciliation?
  private(set) var monetization: MonetizationSnapshot
  var isFullUnlockPresented = false
  private(set) var monetizationNotice: String?

  @ObservationIgnored private let environment: PlayerEnvironment
  @ObservationIgnored private var playbackIntegrationsConfigured = false
  @ObservationIgnored private var audioSessionConfigured = false
  private(set) var playbackSetupError: PlayerPresentationError?
  @ObservationIgnored private var wasPlayingBeforeInterruption = false
  @ObservationIgnored private var importTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var cancellingImportIDs: Set<UUID> = []
  @ObservationIgnored private var mutatingTrashTransactionIDs: Set<UUID> = []
  @ObservationIgnored private var mutatingMetadataTargets: Set<MetadataTarget> = []
  @ObservationIgnored private var sleepTimerMonitorTask: Task<Void, Never>?
  @ObservationIgnored private var monetizationSnapshotTask: Task<Void, Never>?
  @ObservationIgnored private var sleepTimerEvaluationInProgress = false
  @ObservationIgnored private var loadedAssetID: UUID?
  @ObservationIgnored private var loadedAssetTimelineStartSeconds = 0.0
  @ObservationIgnored private var playbackMeterLastUptime: TimeInterval?
  @ObservationIgnored private var pendingPlaybackMeterSeconds: TimeInterval = 0
  @ObservationIgnored private let logger = Logger(
    subsystem: "com.spnss.player",
    category: "ImportPipeline"
  )

  init(environment: PlayerEnvironment) {
    self.environment = environment
    self.playbackState = environment.playback.state
    self.monetization = environment.monetization.snapshot

    let monetizationUpdates = environment.monetization.snapshotUpdates
    monetizationSnapshotTask = Task { @MainActor [weak self] in
      for await snapshot in monetizationUpdates {
        guard !Task.isCancelled, let self else { return }
        applyMonetizationSnapshot(snapshot)
      }
    }
  }

  deinit {
    monetizationSnapshotTask?.cancel()
  }

  var presentedError: PlayerPresentationError? {
    presentationErrors.first { $0.owner == .root }
  }

  func presentationError(in domain: PlayerErrorDomain) -> PlayerPresentationError? {
    presentationErrors.last { $0.domain == domain }
  }

  func presentationError(
    in domain: PlayerErrorDomain,
    owner: PlayerErrorPresentationOwner
  ) -> PlayerPresentationError? {
    presentationErrors.last { $0.domain == domain && $0.owner == owner }
  }

  private func present(
    _ error: any Error,
    in domain: PlayerErrorDomain,
    owner: PlayerErrorPresentationOwner? = nil,
    recoveryAction: PlayerErrorRecoveryAction? = nil
  ) {
    present(PlayerPresentationError.presenting(
      error,
      in: domain,
      owner: owner,
      recoveryAction: recoveryAction
    ))
  }

  private func present(
    _ message: String,
    in domain: PlayerErrorDomain,
    owner: PlayerErrorPresentationOwner? = nil,
    recoveryAction: PlayerErrorRecoveryAction? = nil
  ) {
    present(PlayerPresentationError.presenting(
      message,
      in: domain,
      owner: owner,
      recoveryAction: recoveryAction
    ))
  }

  private func present(_ error: PlayerPresentationError) {
    presentationErrors.append(error)
  }

  func clearPresentedError(id: UUID) {
    presentationErrors.removeAll { $0.id == id }
  }

  private func consumePresentationError(
    in domain: PlayerErrorDomain,
    owner: PlayerErrorPresentationOwner
  ) -> PlayerPresentationError? {
    guard let index = presentationErrors.lastIndex(where: {
      $0.domain == domain && $0.owner == owner
    }) else { return nil }
    return presentationErrors.remove(at: index)
  }

  func restore() async {
    do {
      try await environment.backups.recoverInterruptedRestores()
      let loadedLibrary = try await environment.persistence.load()
      let reconciliation = try await environment.media.reconcileStartupStorage(
        with: loadedLibrary
      )
      library = reconciliation.library
      startupReconciliation = reconciliation
      storageSummary = library.storageManifests.isEmpty ? nil : StorageSummaryPlanner.summarize(
        manifests: library.storageManifests,
        availableBytes: nil
      )
      let recoveredInterruptedImports = recoverInterruptedImports()
      let recoveredSleepTimer = recoverInterruptedSleepTimer()
      let storedPosition = library.playbackPosition
      let recoveredPosition = PositionJournalRecovery.recover(from: library)
      library.playbackPosition = recoveredPosition
      if let recoveredPosition {
        library.currentBookID = recoveredPosition.bookID
        playbackState = PlaybackState(
          status: .paused,
          loadedBookID: recoveredPosition.bookID,
          elapsedSeconds: recoveredPosition.seconds
        )
      } else if let currentBookID = library.currentBookID,
        library.books.contains(where: { $0.id == currentBookID })
      {
        playbackState = PlaybackState(
          status: .paused,
          loadedBookID: currentBookID,
          elapsedSeconds: 0
        )
      } else {
        library.currentBookID = nil
        playbackState = .unloaded
        loadedAssetID = nil
        loadedAssetTimelineStartSeconds = 0
      }
      if library.currentBookID != nil {
        try await loadCurrentBookIntoPlayback()
      }
      if loadedLibrary != library || storedPosition != recoveredPosition
        || recoveredInterruptedImports || recoveredSleepTimer
      {
        try await persist()
      }
      isRestored = true
      startupRecoveryStatus = nil
      applyCurrentTransportConfiguration()
      publishNowPlaying()
      scheduleSleepTimerMonitor()
      let resumableQueueJobIDs = library.importJobs.filter {
        $0.phase == .failed
          && $0.failure?.reasonCode == "import-interrupted"
          && $0.queueCheckpoint != nil
          && $0.zipStatus == nil
      }.map(\.id)
      for jobID in resumableQueueJobIDs {
        await executeQueuedImport(jobID: jobID, initialURLs: nil)
      }
    } catch {
      isRestored = false
      startupRecoveryStatus = await environment.persistence.startupRecoveryStatus()
      environment.nowPlaying.clear()
    }
  }

  func retryStartupRestore() async {
    await restore()
  }

  func recoverFromLatestAutomaticBackup() async throws {
    _ = try await environment.persistence.recoverLatestAutomaticBackupPreservingPrimary()
    await restore()
    guard isRestored else {
      throw PlayerCoreError.fileOperation(
        "The recovered automatic backup could not be opened safely."
      )
    }
  }

  func beginFreshLibraryAfterRecovery() async throws {
    _ = try await environment.persistence.beginFreshLibraryPreservingPrimary()
    await restore()
    guard isRestored else {
      throw PlayerCoreError.fileOperation("A fresh local library could not be created.")
    }
  }

  func prepareSupportBundle() async throws -> PreparedSupportBundle {
    let automaticBackupCount: Int
    if let startupRecoveryStatus {
      // Startup recovery already validated every candidate backup while
      // classifying the failure. Repeating that filesystem walk here can make
      // support export wait on the same protected files a second time.
      automaticBackupCount = startupRecoveryStatus.validAutomaticBackupCount
    } else {
      automaticBackupCount = await environment.persistence.automaticBackups().count
    }
    return try await environment.diagnostics.prepareBundle(
      library: library,
      recovery: startupRecoveryStatus,
      reconciliation: startupReconciliation,
      automaticBackupCount: automaticBackupCount
    )
  }

  func discardPreparedSupportBundle(_ bundle: PreparedSupportBundle) async {
    await environment.diagnostics.discardPreparedBundle(bundle)
  }

  func prepareLibraryBackup(kind: PortableBackupKind) async throws -> PreparedLibraryBackup {
    try await environment.backups.prepareExport(library: library, kind: kind)
  }

  func discardPreparedLibraryBackup(_ backup: PreparedLibraryBackup) async {
    await environment.backups.discardPreparedExport(backup)
  }

  func restoreLibraryBackup(from url: URL) async throws {
    await checkpointPlaybackMeter(force: true)
    environment.playback.pause()
    playbackMeterLastUptime = nil
    _ = try await environment.backups.restore(from: url)
    await restore()
    guard isRestored else {
      throw PlayerCoreError.fileOperation(
        presentationError(in: .recovery)?.message
          ?? "The restored library could not be opened."
      )
    }
  }

  func automaticLibraryBackups() async -> [AutomaticLibraryBackup] {
    await environment.persistence.automaticBackups()
  }

  func restoreLatestAutomaticLibraryBackup() async throws {
    await checkpointPlaybackMeter(force: true)
    environment.playback.pause()
    playbackMeterLastUptime = nil
    _ = try await environment.persistence.restoreLatestAutomaticBackup()
    await restore()
    guard isRestored else {
      throw PlayerCoreError.fileOperation(
        presentationError(in: .recovery)?.message
          ?? "The automatic backup could not be opened."
      )
    }
  }

  #if E2E
    func replaceLibraryForBackupE2E(with snapshot: LibrarySnapshot) async throws {
      try await environment.persistence.save(snapshot)
      await restore()
    }

    func adoptPrimaryLibraryForBackupE2E(_ snapshot: LibrarySnapshot) {
      library = snapshot
    }
  #endif

  private func recoverInterruptedSleepTimer() -> Bool {
    guard var timer = library.activeSleepTimer else { return false }
    guard library.books.contains(where: { $0.id == timer.bookID }) else {
      library.activeSleepTimer = nil
      return true
    }
    guard timer.phase == .fading else { return false }
    timer.phase = .active
    library.activeSleepTimer = timer
    return true
  }

  private func recoverInterruptedImports() -> Bool {
    var changed = false
    for index in library.importJobs.indices {
      guard
        [.acquiring, .extracting, .inspecting].contains(library.importJobs[index].phase),
        library.importJobs[index].zipStatus != nil
          || library.importJobs[index].queueCheckpoint != nil
      else { continue }
      if var status = library.importJobs[index].zipStatus {
        status.failureReasonCode = "import-interrupted"
        status.retryAllowed = true
        library.importJobs[index].zipStatus = status
      }
      library.importJobs[index].phase = .failed
      library.importJobs[index].failure = ImportFailure(
        message: "The import was interrupted and can continue from its checkpoint.",
        affectedFilename: library.importJobs[index].sourceFilename,
        sourceIsUnchanged: true,
        isRecoverable: true,
        reasonCode: "import-interrupted",
        recoveryAction: .retry
      )
      changed = true
    }
    return changed
  }

  func configurePlaybackIntegrations() {
    if !playbackIntegrationsConfigured {
      environment.playback.installEventHandler { [weak self] event in
        await self?.handlePlaybackEngineEvent(event)
      }
      environment.audioSession.installEventHandler { [weak self] event in
        await self?.handleAudioSessionEvent(event)
      }
      environment.remoteCommands.installCommandHandler { [weak self] command in
        await self?.handleRemoteCommand(command)
      }
      playbackIntegrationsConfigured = true
    }
    guard !audioSessionConfigured else { return }
    do {
      try environment.audioSession.configure()
      audioSessionConfigured = true
      playbackSetupError = nil
      applyCurrentTransportConfiguration()
      publishNowPlaying()
    } catch {
      playbackSetupError = PlayerPresentationError.presenting(
        error,
        in: .playback,
        recoveryAction: .contactSupport
      )
    }
  }

  private func prepareAudioSessionForPlayback() throws {
    if !audioSessionConfigured {
      try environment.audioSession.configure()
      audioSessionConfigured = true
      playbackSetupError = nil
    }
    try environment.audioSession.activate()
  }

  func prepareMonetization() async {
    await environment.monetization.prepare()
    synchronizeMonetizationSnapshot()
  }

  func refreshMonetization() async {
    await environment.monetization.refreshEntitlement()
    synchronizeMonetizationSnapshot()
  }

  func purchaseFullUnlock() async {
    await environment.monetization.purchaseFullUnlock()
    synchronizeMonetizationSnapshot()
    if monetization.isUnlocked { isFullUnlockPresented = false }
  }

  func restorePurchases() async {
    await environment.monetization.restorePurchases()
    synchronizeMonetizationSnapshot()
    if monetization.isUnlocked { isFullUnlockPresented = false }
  }

  func handleOfferCodeRedemption(completed: Bool) async {
    await environment.monetization.handleOfferCodeRedemption(completed: completed)
    synchronizeMonetizationSnapshot()
    if case .completed(entitlementConfirmed: true) = monetization.offerCodeRedemptionOutcome,
      monetization.isUnlocked
    {
      isFullUnlockPresented = false
    }
  }

  func showFullUnlock() {
    isFullUnlockPresented = true
  }

  func dismissMonetizationNotice() {
    monetizationNotice = nil
  }

  private func synchronizeMonetizationSnapshot() {
    applyMonetizationSnapshot(environment.monetization.snapshot)
  }

  private func applyMonetizationSnapshot(_ next: MonetizationSnapshot) {
    let previous = monetization
    monetization = next
    guard !next.isUnlocked else {
      isFullUnlockPresented = false
      return
    }
    let thresholds: [(seconds: TimeInterval, message: String)] = [
      (25 * 60 * 60, "25 hours of included listening remain."),
      (10 * 60 * 60, "10 hours of included listening remain."),
      (2 * 60 * 60, "2 hours of included listening remain. You can unlock Bookshelf forever at any time."),
    ]
    if let crossed = thresholds.last(where: {
      previous.remainingPlaybackSeconds > $0.seconds
        && next.remainingPlaybackSeconds <= $0.seconds
    }) {
      monetizationNotice = crossed.message
    }
  }

  private func allowNewPlaybackSession() -> Bool {
    synchronizeMonetizationSnapshot()
    guard monetization.canStartPlayback else {
      isFullUnlockPresented = true
      return false
    }
    return true
  }

  private func beginPlaybackMetering() {
    playbackMeterLastUptime = environment.playbackUptime.now()
  }

  private func checkpointPlaybackMeter(force: Bool) async {
    guard playbackState.status == .playing else {
      playbackMeterLastUptime = nil
      return
    }
    guard environment.playback.isPlaybackAdvancing else {
      playbackMeterLastUptime = nil
      return
    }
    let now = environment.playbackUptime.now()
    defer { playbackMeterLastUptime = now }
    guard let previous = playbackMeterLastUptime else { return }
    let elapsed = now - previous
    guard elapsed.isFinite, elapsed > 0 else { return }
    pendingPlaybackMeterSeconds += elapsed
    guard force || pendingPlaybackMeterSeconds >= 5 else { return }
    let seconds = pendingPlaybackMeterSeconds
    pendingPlaybackMeterSeconds = 0
    await environment.monetization.recordPlayback(seconds: seconds)
    synchronizeMonetizationSnapshot()
  }

  func metadata(for target: MetadataTarget) -> AudiobookMetadata? {
    switch target {
    case .book(let bookID):
      library.books.first(where: { $0.id == bookID })?.metadata
    case .proposal(let jobID, let proposalID):
      library.importJobs.first(where: { $0.id == jobID })?
        .proposals.first(where: { $0.id == proposalID })?.metadata
    }
  }

  @discardableResult
  func repairBookMetadata(
    bookID: UUID,
    mutations: [MetadataMutation]
  ) async -> UUID? {
    await repairMetadata(target: .book(bookID), mutations: mutations)
  }

  @discardableResult
  func repairProposalMetadata(
    jobID: UUID,
    proposalID: UUID,
    mutations: [MetadataMutation]
  ) async -> UUID? {
    await repairMetadata(
      target: .proposal(jobID: jobID, proposalID: proposalID),
      mutations: mutations
    )
  }

  @discardableResult
  func repairMetadata(
    target: MetadataTarget,
    mutations: [MetadataMutation]
  ) async -> UUID? {
    guard !mutations.isEmpty else { return nil }
    guard mutatingMetadataTargets.insert(target).inserted else {
      present(MetadataRepairError.transactionInProgress, in: .metadata)
      return nil
    }
    defer { mutatingMetadataTargets.remove(target) }
    let transactionID = await environment.ids.next()
    let previousLibrary = library
    do {
      guard var repaired = metadata(for: target) else {
        throw missingTargetError(target)
      }
      let before = repaired
      for mutation in mutations {
        try repaired.apply(mutation, transactionID: transactionID)
      }
      try repaired.validateForCommit()
      try replaceMetadata(
        repaired,
        for: target,
        proposalRevisionIncrement: mutations.count
      )
      library.metadataTransactions.append(MetadataTransaction(
        id: transactionID,
        target: target,
        before: before,
        after: repaired,
        mutations: mutations,
        createdAt: environment.clock.now(),
        status: .applied,
        undoneAt: nil
      ))
      // Persist the complete candidate before publishing it through the
      // observable model; no half-repaired field set is visible across an await.
      let committedLibrary = library
      library = previousLibrary
      try await environment.persistence.save(committedLibrary)
      library = committedLibrary
      publishNowPlaying()
      return transactionID
    } catch {
      library = previousLibrary
      present(error, in: .metadata)
      return nil
    }
  }

  @discardableResult
  func undoLastMetadataTransaction(for target: MetadataTarget) async -> Bool {
    guard let transaction = library.metadataTransactions.last(where: {
      $0.target == target && $0.status == .applied
    }) else {
      present(
        "There is no metadata edit to undo.",
        in: .metadata,
        owner: .root,
        recoveryAction: .acknowledge
      )
      return false
    }
    return await undoMetadataTransaction(id: transaction.id)
  }

  @discardableResult
  func undoMetadataTransaction(id: UUID) async -> Bool {
    guard let transactionIndex = library.metadataTransactions.firstIndex(where: { $0.id == id })
    else {
      present(MetadataRepairError.transactionNotApplied(id), in: .metadata, owner: .root)
      return false
    }
    let transaction = library.metadataTransactions[transactionIndex]
    guard mutatingMetadataTargets.insert(transaction.target).inserted else {
      present(MetadataRepairError.transactionInProgress, in: .metadata, owner: .root)
      return false
    }
    defer { mutatingMetadataTargets.remove(transaction.target) }
    guard transaction.status == .applied,
      !library.metadataTransactions[(transactionIndex + 1)...].contains(where: {
        $0.target == transaction.target && $0.status == .applied
      })
    else {
      present(MetadataRepairError.transactionNotApplied(id), in: .metadata, owner: .root)
      return false
    }

    let previousLibrary = library
    do {
      try replaceMetadata(transaction.before, for: transaction.target)
      library.metadataTransactions[transactionIndex].status = .undone
      library.metadataTransactions[transactionIndex].undoneAt = environment.clock.now()
      let committedLibrary = library
      library = previousLibrary
      try await environment.persistence.save(committedLibrary)
      library = committedLibrary
      publishNowPlaying()
      return true
    } catch {
      library = previousLibrary
      present(error, in: .metadata, owner: .root)
      return false
    }
  }

  @discardableResult
  func importAudio(from sourceURL: URL) async -> UUID? {
    await enqueueImport(ImportRequest(entryPoint: .files, selectedURLs: [sourceURL]))
  }

  @discardableResult
  func importAudioSelection(from selectedURLs: [URL]) async -> UUID? {
    await enqueueImport(ImportRequest(entryPoint: .files, selectedURLs: selectedURLs))
  }

  @discardableResult
  func handleSystemFileSelection(
    _ outcome: SystemSelectionOutcome<[URL]>
  ) async -> UUID? {
    switch outcome {
    case .selected(let urls):
      return await importAudioSelection(from: urls)
    case .cancelled:
      return nil
    case .failed(let failure):
      let detail = failure.message.trimmingCharacters(in: .whitespacesAndNewlines)
      let suffix = detail.isEmpty ? "" : " \(detail)"
      present(
        "Files couldn’t provide the selected audiobook.\(suffix) Download it in Files or choose another copy, then try again.",
        in: .importFlow,
        recoveryAction: .acknowledge
      )
      return nil
    }
  }

  func importFromComputer(_ selectedURLs: [URL]) async -> DirectImportOutcome {
    let previousBookIDs = Set(library.books.map(\.id))
    guard let jobID = await enqueueImport(
      ImportRequest(entryPoint: .computerReceiver, selectedURLs: selectedURLs),
      errorOwner: .computerReceiver
    ), let job = library.importJobs.first(where: { $0.id == jobID }) else {
      return DirectImportOutcome(
        state: .failed,
        message: consumePresentationError(in: .importFlow, owner: .computerReceiver)?.message
          ?? "Bookshelf could not import these files.",
        addedBookCount: 0,
        cleanupIncomingFiles: false
      )
    }
    switch job.phase {
    case .ready where job.proposals.allSatisfy({ $0.warnings.isEmpty }):
      guard await addImportToLibrary(jobID: jobID, errorOwner: .computerReceiver) != nil else {
        return DirectImportOutcome(
          state: .failed,
          message: consumePresentationError(in: .importFlow, owner: .computerReceiver)?.message
            ?? "Bookshelf could not add this audiobook.",
          addedBookCount: 0,
          cleanupIncomingFiles: true
        )
      }
      let added = library.books.filter { !previousBookIDs.contains($0.id) }
      let message: String
      if added.count == 1, let book = added.first {
        message = "\(book.title) added"
      } else {
        message = "\(added.count) books added"
      }
      return DirectImportOutcome(
        state: .completed,
        message: message,
        addedBookCount: added.count,
        cleanupIncomingFiles: true
      )
    case .ready, .needsReview:
      return DirectImportOutcome(
        state: .needsReview,
        message: "The files were received. Open Inbox to review this import.",
        addedBookCount: 0,
        cleanupIncomingFiles: true
      )
    case .failed:
      return DirectImportOutcome(
        state: .failed,
        message: job.failure?.message ?? "Bookshelf could not import these files.",
        addedBookCount: 0,
        cleanupIncomingFiles: true
      )
    default:
      return DirectImportOutcome(
        state: .failed,
        message: "Bookshelf did not finish checking these files.",
        addedBookCount: 0,
        cleanupIncomingFiles: false
      )
    }
  }

  @discardableResult
  func handleDocumentOpen(_ url: URL, receivedViaAirDrop: Bool = false) async -> UUID? {
    await enqueueImport(ImportRequest(
      entryPoint: receivedViaAirDrop ? .airDrop : .documentOpen,
      selectedURLs: [url]
    ))
  }

  @discardableResult
  func importSharedHandoff(
    _ claimed: ClaimedShareImport,
    from queue: AppGroupImportHandoffQueue
  ) async -> UUID? {
    let fingerprint = claimed.handoff.payloadFingerprint
    if let receipt = library.shareImportReceipts.first(where: {
      $0.handoffID == claimed.handoff.id
    }) {
      guard receipt.payloadFingerprint == fingerprint else {
        try? await queue.acknowledge(claimed.handoff.id)
        present(
          "A share request reused an identifier with different content.",
          in: .importFlow,
          recoveryAction: .reviewInbox
        )
        return nil
      }
      try? await queue.acknowledge(claimed.handoff.id)
      return receipt.jobID
    }
    let jobID = await enqueueImport(ImportRequest(
      entryPoint: .shareExtension,
      selectedURLs: claimed.fileURLs,
      shareHandoffID: claimed.handoff.id,
      sourceDisplayNames: claimed.handoff.items.map(\.originalFilename)
    ))
    guard let jobID,
      let job = library.importJobs.first(where: { $0.id == jobID })
    else {
      try? await queue.returnForRetry(claimed.handoff.id)
      return nil
    }
    let acquisitionIsDurable = job.queueCheckpoint?.acquisitionComplete == true
      || job.zipStatus != nil
    if acquisitionIsDurable {
      let receipt = ShareImportReceipt(
        handoffID: claimed.handoff.id,
        payloadFingerprint: fingerprint,
        jobID: jobID,
        receivedAt: environment.clock.now()
      )
      library.shareImportReceipts.append(receipt)
      do {
        try await persist()
      } catch {
        library.shareImportReceipts.removeAll { $0.handoffID == claimed.handoff.id }
        try? await queue.returnForRetry(claimed.handoff.id)
        present(error, in: .importFlow)
        return nil
      }
      do {
        try await queue.acknowledge(claimed.handoff.id)
      } catch {
        // The durable receipt is the exactly-once boundary. Retain it if queue
        // cleanup fails so an immediate replay deduplicates instead of importing
        // the same payload a second time.
        try? await queue.returnForRetry(claimed.handoff.id)
        present(error, in: .importFlow)
        return nil
      }
    } else {
      try? await queue.returnForRetry(claimed.handoff.id)
    }
    return jobID
  }

  @discardableResult
  func enqueueImport(
    _ request: ImportRequest,
    errorOwner: PlayerErrorPresentationOwner = .root
  ) async -> UUID? {
    guard !request.selectedURLs.isEmpty else {
      present(PlayerCoreError.invalidAssetSelection, in: .importFlow, owner: errorOwner)
      return nil
    }
    do {
      let sources = try await environment.media.referenceImportSources(
        request.selectedURLs,
        displayNames: request.sourceDisplayNames
      )
      let entryPoint: ImportEntryPoint = request.entryPoint == .files
        && sources.contains(where: \.isDirectory)
        ? .folder : request.entryPoint
      if request.selectedURLs.count == 1,
        request.selectedURLs[0].pathExtension.lowercased() == "zip"
      {
        return await importZipArchive(
          from: request.selectedURLs[0],
          checkpoint: ImportQueueCheckpoint(
            entryPoint: entryPoint,
            sources: sources,
            shareHandoffID: request.shareHandoffID
          )
        )
      }
      guard !request.selectedURLs.contains(where: { $0.pathExtension.lowercased() == "zip" }) else {
        throw PlayerCoreError.fileOperation("Import one ZIP archive at a time.")
      }
      let jobID = await environment.ids.next()
      let now = environment.clock.now()
      let displayNames = sources.map(\.displayName)
      let job = ImportJob(
        id: jobID,
        sourceFilename: displayNames.count == 1
          ? displayNames[0] : "\(displayNames.count) selected items",
        phase: .queued,
        progress: .none,
        createdAt: now,
        updatedAt: now,
        queueCheckpoint: ImportQueueCheckpoint(
          entryPoint: entryPoint,
          sources: sources,
          shareHandoffID: request.shareHandoffID
        )
      )
      library.importJobs.append(job)
      try await persist()
      await executeQueuedImport(jobID: jobID, initialURLs: request.selectedURLs)
      return jobID
    } catch {
      present(error, in: .importFlow, owner: errorOwner)
      return nil
    }
  }

  @discardableResult
  func changeImportSelection(
    jobID: UUID,
    to request: ImportRequest
  ) async -> UUID? {
    await cancelImport(jobID: jobID)
    return await enqueueImport(request)
  }

  @discardableResult
  private func legacyImportAudio(from sourceURL: URL) async -> UUID? {
    let jobID = await environment.ids.next()
    let now = environment.clock.now()
    var job = ImportJob(
      id: jobID,
      sourceFilename: sourceURL.lastPathComponent,
      phase: .queued,
      progress: .none,
      createdAt: now,
      updatedAt: now
    )
    library.importJobs.append(job)

    do {
      try await persist()
      job.phase = .acquiring
      try await replaceAndPersist(job)

      let staged = try await environment.media.stage(sourceURL: sourceURL, jobID: jobID)
      job.stagedRelativePath = staged.relativePath
      job.progress = ImportProgress(completed: staged.byteCount, total: staged.byteCount)
      job.phase = .inspecting
      try await replaceAndPersist(job)

      let stagedURL = try await environment.media.stagedURL(for: staged.relativePath)
      let inspected = try await environment.inspector.inspect(url: stagedURL)
      let assetID = await environment.ids.next()
      let proposalID = await environment.ids.next()
      let bookID = await environment.ids.next()
      let fallbackTitle = sourceURL.deletingPathExtension().lastPathComponent
      let asset = AudioAsset(
        id: assetID,
        originalFilename: staged.originalFilename,
        managedRelativePath: "",
        checksumSHA256: staged.checksumSHA256,
        byteCount: staged.byteCount,
        durationSeconds: inspected.durationSeconds,
        container: inspected.container,
        timelineStartSeconds: 0,
        discNumber: inspected.discNumber,
        trackNumber: inspected.trackNumber
      )
      let chapters = inspected.chapters.map { chapter in
        var mapped = chapter
        mapped.assetID = assetID
        return mapped
      }
      job.proposal = BookProposal(
        id: proposalID,
        proposedBookID: bookID,
        title: inspected.title?.nilIfBlank ?? fallbackTitle,
        authors: inspected.authors,
        durationSeconds: inspected.durationSeconds,
        artworkData: inspected.artworkData,
        asset: asset,
        warnings: [],
        narrators: inspected.narrators,
        seriesName: inspected.seriesName,
        seriesPosition: inspected.seriesPosition,
        artworkMediaType: inspected.artworkMediaType,
        chapters: chapters,
        groupingEvidence: [
          GroupingEvidence(
            kind: .selectedTogether,
            explanation: "Selected as one audiobook file."
          )
        ]
      )
      job.stagedAssets = [
        StagedImportAsset(
          assetID: assetID,
          stagedRelativePath: staged.relativePath,
          sourceRelativePath: staged.originalFilename
        )
      ]
      job.phase = .ready
      job.failure = nil
      try await replaceAndPersist(job)
      return jobID
    } catch {
      job.phase = .failed
      job.failure = ImportFailure(
        message: error.localizedDescription,
        affectedFilename: sourceURL.lastPathComponent,
        sourceIsUnchanged: true,
        isRecoverable: true
      )
      try? await replaceAndPersist(job)
      present(error, in: .importFlow)
      return jobID
    }
  }

  /// Acquires files and folders as one reviewable import. Selection membership is
  /// the primary grouping signal; folder and embedded-title agreement are recorded
  /// as explainable supporting evidence rather than silently creating extra books.
  @discardableResult
  private func legacyImportAudioSelection(from selectedURLs: [URL]) async -> UUID? {
    guard !selectedURLs.isEmpty else {
      present(PlayerCoreError.invalidAssetSelection, in: .importFlow)
      return nil
    }

    let archiveURLs = selectedURLs.filter { $0.pathExtension.lowercased() == "zip" }
    if !archiveURLs.isEmpty {
      guard selectedURLs.count == 1, archiveURLs.count == 1 else {
        present("Import one ZIP archive at a time.", in: .importFlow)
        return nil
      }
      return await importZipArchive(from: archiveURLs[0])
    }

    let jobID = await environment.ids.next()
    let now = environment.clock.now()
    var job = ImportJob(
      id: jobID,
      sourceFilename: selectedURLs.count == 1
        ? selectedURLs[0].lastPathComponent
        : "\(selectedURLs.count) selected items",
      phase: .queued,
      progress: .none,
      createdAt: now,
      updatedAt: now
    )
    library.importJobs.append(job)

    do {
      try await persist()
      job.phase = .acquiring
      try await replaceAndPersist(job)

      let acquired = try await environment.media.acquireSelection(selectedURLs, jobID: jobID)
      job.progress = ImportProgress(
        completed: acquired.reduce(0) { $0 + $1.staged.byteCount },
        total: acquired.reduce(0) { $0 + $1.staged.byteCount }
      )
      job.phase = .inspecting
      try await replaceAndPersist(job)

      var prepared: [PreparedImportAsset] = []
      for (selectionIndex, item) in acquired.enumerated() {
        let stagedURL = try await environment.media.stagedURL(for: item.staged.relativePath)
        let inspected = try await environment.inspector.inspect(url: stagedURL)
        let assetID = await environment.ids.next()
        let asset = AudioAsset(
          id: assetID,
          originalFilename: item.staged.originalFilename,
          managedRelativePath: "",
          checksumSHA256: item.staged.checksumSHA256,
          byteCount: item.staged.byteCount,
          durationSeconds: inspected.durationSeconds,
          container: inspected.container,
          discNumber: inspected.discNumber,
          trackNumber: inspected.trackNumber,
          importOrder: selectionIndex
        )
        prepared.append(
          PreparedImportAsset(
            asset: asset,
            inspected: inspected,
            acquired: item
          )
        )
      }

      let preparedGroups = groupedImportAssets(prepared)
      var proposals: [BookProposal] = []
      for group in preparedGroups {
        let ordered = NaturalTrackOrdering.order(group.map(\.asset))
        let preparedByID = Dictionary(uniqueKeysWithValues: group.map { ($0.asset.id, $0) })
        var chapters: [Chapter] = []
        var positionedAssets: [AudioAsset] = []
        var timelineStart = 0.0
        for var asset in ordered.assets {
          guard let item = preparedByID[asset.id] else { continue }
          asset.timelineStartSeconds = timelineStart
          positionedAssets.append(asset)
          chapters.append(contentsOf: item.inspected.chapters.map { chapter in
            Chapter(
              id: "\(asset.id.uuidString.lowercased())-\(chapter.id)",
              title: chapter.title,
              startSeconds: chapter.startSeconds + timelineStart,
              durationSeconds: chapter.durationSeconds,
              source: chapter.source,
              assetID: asset.id
            )
          })
          timelineStart += asset.durationSeconds
        }
        guard let primaryAsset = positionedAssets.first else {
          throw PlayerCoreError.invalidAssetSelection
        }
        let proposalID = await environment.ids.next()
        let bookID = await environment.ids.next()
        let commonFolder = commonNonBlank(group.compactMap(\.acquired.commonFolderName))
        let commonAlbumTitle = commonNonBlank(group.compactMap(\.inspected.albumTitle))
        let commonTitle = commonNonBlank(group.compactMap(\.inspected.title))
        let filenameTitle = filenameStem(for: group[0].asset.originalFilename).display
        let warnings = (preparedGroups.count > 1
          ? ["Confirm that this selection is one audiobook."]
          : []) + ordered.warnings
        proposals.append(
          BookProposal(
            id: proposalID,
            proposedBookID: bookID,
            title: commonAlbumTitle ?? commonTitle ?? commonFolder ?? filenameTitle,
            authors: uniqueContributors(group.flatMap(\.inspected.authors)),
            durationSeconds: timelineStart,
            artworkData: group.compactMap(\.inspected.artworkData).first,
            asset: primaryAsset,
            warnings: warnings,
            narrators: uniqueContributors(group.flatMap(\.inspected.narrators)),
            seriesName: group.compactMap(\.inspected.seriesName).first,
            seriesPosition: group.compactMap(\.inspected.seriesPosition).first,
            artworkMediaType: group.compactMap(\.inspected.artworkMediaType).first,
            chapters: chapters.sorted { $0.startSeconds < $1.startSeconds },
            additionalAssets: Array(positionedAssets.dropFirst()),
            groupingEvidence: groupingEvidence(for: group),
            orderingEvidence: ordered.evidence
          )
        )
      }
      job.stagedRelativePath = acquired.first?.staged.relativePath
      job.stagedAssets = prepared.map {
        StagedImportAsset(
          assetID: $0.asset.id,
          stagedRelativePath: $0.acquired.staged.relativePath,
          sourceRelativePath: $0.acquired.sourceRelativePath
        )
      }
      job.proposals = proposals
      job.phase = proposals.contains(where: { !$0.warnings.isEmpty }) ? .needsReview : .ready
      job.failure = nil
      try await replaceAndPersist(job)
      return jobID
    } catch {
      job.phase = .failed
      job.failure = ImportFailure(
        message: error.localizedDescription,
        affectedFilename: nil,
        sourceIsUnchanged: true,
        isRecoverable: true
      )
      try? await replaceAndPersist(job)
      present(error, in: .importFlow)
      return jobID
    }
  }

  @discardableResult
  func retryImport(jobID: UUID) async -> Bool {
    guard let job = library.importJobs.first(where: { $0.id == jobID }), job.phase == .failed else {
      present(PlayerCoreError.missingImport(jobID), in: .importFlow)
      return false
    }
    if job.zipStatus?.retryAllowed == true {
      await executeZipImport(jobID: jobID, sourceURL: nil)
    } else if job.queueCheckpoint != nil,
      (job.failure?.recoveryAction == .retry
        || job.recoveryPlan?.phase == .failedRecoverable)
    {
      await executeQueuedImport(jobID: jobID, initialURLs: nil)
    } else {
      present(PlayerCoreError.importNotReady(jobID), in: .importFlow)
      return false
    }
    return library.importJobs.first(where: { $0.id == jobID }).map {
      $0.phase == .ready || $0.phase == .needsReview
    } ?? false
  }

  func recoveryPlan(for jobID: UUID) -> ImportRecoveryPlan? {
    library.importJobs.first(where: { $0.id == jobID })?.recoveryPlan
  }

  /// Re-inspects one failed staged copy through the normal durable queue. The
  /// source selection is never edited and successful siblings keep their
  /// inspection checkpoints.
  @discardableResult
  func retryImportFile(jobID: UUID, fileID: UUID) async -> Bool {
    guard var job = library.importJobs.first(where: { $0.id == jobID }),
      var plan = job.recoveryPlan,
      let statusIndex = plan.files.firstIndex(where: { $0.file.id == fileID }),
      plan.files[statusIndex].disposition == .failed,
      plan.files[statusIndex].issue?.isRecoverable == true,
      job.queueCheckpoint != nil
    else {
      present(PlayerCoreError.importNotReady(jobID), in: .importFlow)
      return false
    }
    let previousLibrary = library
    // A valid marker on the existing durable status means "retry pending" to
    // the queue, while preserving the stable recovery-file identifier across
    // the failed → accepted transition and an intervening app termination.
    plan.files[statusIndex].file.validity = .valid
    job.recoveryPlan = plan
    job.phase = .inspecting
    job.failure = nil
    do {
      try await replaceAndPersist(job)
      await executeQueuedImport(jobID: jobID, initialURLs: nil)
      return library.importJobs.first(where: { $0.id == jobID }).map {
        $0.recoveryPlan?.files.contains(where: {
          $0.file.id == fileID && $0.disposition == .accepted
        }) == true
      } ?? false
    } catch {
      library = previousLibrary
      present(error, in: .importFlow)
      return false
    }
  }

  /// Excludes one staged copy from this import. Only the app-owned staging
  /// path is removed; the security-scoped source remains unchanged.
  @discardableResult
  func removeImportFile(jobID: UUID, fileID: UUID) async -> Bool {
    guard let previousJob = library.importJobs.first(where: { $0.id == jobID }),
      let status = previousJob.recoveryPlan?.files.first(where: { $0.file.id == fileID }),
      var checkpoint = previousJob.queueCheckpoint
    else {
      present(PlayerCoreError.importNotReady(jobID), in: .importFlow)
      return false
    }
    let path = status.file.relativePath
    let previousLibrary = library
    var updated = previousJob
    checkpoint.acquired.removeAll { $0.staged.relativePath == path }
    checkpoint.inspected.removeAll { $0.acquired.staged.relativePath == path }
    updated.queueCheckpoint = checkpoint
    updated.recoveryPlan?.files.removeAll { $0.file.id == fileID }
    updated.stagedAssets.removeAll { $0.stagedRelativePath == path }
    do {
      try await replaceAndPersist(updated)
      do {
        try await environment.media.discardStagedFile(relativePath: path)
      } catch {
        library = previousLibrary
        try await environment.persistence.save(previousLibrary)
        throw error
      }
      await executeQueuedImport(jobID: jobID, initialURLs: nil)
      return library.importJobs.first(where: { $0.id == jobID })?
        .recoveryPlan?.files.contains(where: { $0.file.id == fileID }) == false
    } catch {
      library = previousLibrary
      present(error, in: .importFlow)
      return false
    }
  }

  /// Confirms that unresolved failed/duplicate siblings should remain excluded
  /// and moves the accepted proposal to the normal import-review boundary.
  @discardableResult
  func continueImportWithAcceptedFiles(jobID: UUID) async -> Bool {
    guard var job = library.importJobs.first(where: { $0.id == jobID }),
      job.recoveryPlan?.canContinueWithAcceptedFiles == true,
      !job.proposals.isEmpty
    else {
      present(PlayerCoreError.importNotReady(jobID), in: .importFlow)
      return false
    }
    let previousLibrary = library
    job.phase = job.proposals.contains(where: { !$0.warnings.isEmpty }) ? .needsReview : .ready
    job.failure = nil
    do {
      try await replaceAndPersist(job)
      return true
    } catch {
      library = previousLibrary
      present(error, in: .importFlow)
      return false
    }
  }

  @discardableResult
  func refreshStorageSummary() async -> StorageSummary? {
    let previousLibrary = library
    do {
      let inventory = try await environment.media.storageInventory()
      var updated = library
      updated.storageManifests = inventory.manifests
      try await environment.persistence.save(updated)
      library = updated
      storageSummary = StorageSummaryPlanner.summarize(
        manifests: inventory.manifests,
        availableBytes: inventory.availableBytes
      )
      return storageSummary
    } catch {
      library = previousLibrary
      present(error, in: .storage)
      return nil
    }
  }

  /// Clears only recoverable app-owned staging or trash.
  @discardableResult
  func clearRecoverableStorage(scope: StorageScope) async -> Bool {
    if case .trashTransaction(let transactionID) = scope {
      return await permanentlyDeleteTrashTransaction(transactionID)
    }
    let previousLibrary = library
    var updated = library
    switch scope {
    case .stagingJob(let jobID):
      guard let index = updated.importJobs.firstIndex(where: { $0.id == jobID }) else {
        present(PlayerCoreError.missingImport(jobID), in: .storage)
        return false
      }
      updated.importJobs[index].phase = .cancelled
      updated.importJobs[index].progress = .none
      updated.importJobs[index].stagedRelativePath = nil
      updated.importJobs[index].stagedAssets = []
      updated.importJobs[index].proposals = []
      updated.importJobs[index].recoveryPlan = nil
      updated.importJobs[index].failure = nil
      if var checkpoint = updated.importJobs[index].queueCheckpoint {
        checkpoint.acquired = []
        checkpoint.inspected = []
        checkpoint.acquisitionComplete = false
        updated.importJobs[index].queueCheckpoint = checkpoint
      }
    case .trashTransaction:
      return false
    case .managedBook, .database:
      present(
        "Only staging and Trash can be cleared from recoverable storage.",
        in: .storage,
        recoveryAction: .acknowledge
      )
      return false
    }

    do {
      try await environment.persistence.save(updated)
      library = updated
      do {
        try await environment.media.discardStorage(scope: scope)
      } catch {
        library = previousLibrary
        try await environment.persistence.save(previousLibrary)
        throw error
      }
      _ = await refreshStorageSummary()
      return true
    } catch {
      library = previousLibrary
      present(error, in: .storage)
      return false
    }
  }

  private func permanentlyDeleteTrashTransaction(_ transactionID: UUID) async -> Bool {
    guard mutatingTrashTransactionIDs.insert(transactionID).inserted else {
      present(LibraryOrganizationError.trashTransactionNotRecoverable(transactionID), in: .storage)
      return false
    }
    defer { mutatingTrashTransactionIDs.remove(transactionID) }

    guard let index = library.trashTransactions.firstIndex(where: { $0.id == transactionID }) else {
      present(LibraryOrganizationError.missingTrashTransaction(transactionID), in: .storage)
      return false
    }
    let transaction = library.trashTransactions[index]
    guard transaction.status == .recoverable, let book = transaction.book else {
      present(LibraryOrganizationError.trashTransactionNotRecoverable(transactionID), in: .storage)
      return false
    }

    let previousLibrary = library
    var purgingLibrary = library
    purgingLibrary.trashTransactions[index].beginPurging(at: environment.clock.now())
    do {
      try await environment.persistence.save(purgingLibrary)
      library = purgingLibrary
    } catch {
      present(error, in: .storage)
      return false
    }

    let deletion: PreparedTrashDeletion
    do {
      deletion = try await environment.media.preparePermanentTrashDeletion(
        transactionID: transactionID,
        bookID: book.id,
        mediaPolicy: transaction.mediaPolicy,
        manifest: transaction.mediaManifest
      )
    } catch {
      do {
        try await environment.persistence.save(previousLibrary)
        library = previousLibrary
      } catch {
        // Keep the durable purging intent. Startup reconciliation can safely
        // return it to recoverable because filesystem preparation never completed.
      }
      present(error, in: .storage)
      return false
    }

    var purgedLibrary = purgingLibrary
    purgedLibrary.bookmarks.removeAll { $0.bookID == book.id }
    purgedLibrary.bookmarkDeletionTransactions.removeAll { $0.bookmark.bookID == book.id }
    purgedLibrary.resumeRewindTransactions.removeAll { $0.bookID == book.id }
    if purgedLibrary.activeSleepTimer?.bookID == book.id {
      purgedLibrary.activeSleepTimer = nil
    }
    purgedLibrary.trashTransactions[index].finishPurging(at: environment.clock.now())

    do {
      try await environment.persistence.save(purgedLibrary)
    } catch {
      do {
        try await environment.media.rollbackPermanentTrashDeletion(deletion)
        try await environment.persistence.save(previousLibrary)
        library = previousLibrary
      } catch {
        // The durable purging record and journal deliberately remain. Startup
        // reconciliation will retry rollback without guessing which bytes moved.
        library = purgingLibrary
      }
      present(error, in: .storage)
      return false
    }

    library = purgedLibrary
    if environment.playback.state.loadedBookID == book.id {
      environment.playback.unload()
      playbackState = .unloaded
      loadedAssetID = nil
      loadedAssetTimelineStartSeconds = 0
      playbackMeterLastUptime = nil
      pendingPlaybackMeterSeconds = 0
    }
    if transaction.wasCurrentBook {
      sleepTimerMonitorTask?.cancel()
      sleepTimerMonitorTask = nil
    }
    publishNowPlaying()

    do {
      try await environment.media.commitPermanentTrashDeletion(deletion)
    } catch {
      // The purged tombstone is the commit point. The journal remains durable
      // and startup reconciliation will finish removing the prepared payload.
      present(error, in: .storage)
      return false
    }
    return await refreshStorageSummary() != nil
  }

  func cancelImport(jobID: UUID) async {
    guard var job = library.importJobs.first(where: { $0.id == jobID }) else { return }
    guard cancellingImportIDs.insert(jobID).inserted else { return }
    defer { cancellingImportIDs.remove(jobID) }
    let previousLibrary = library
    importTasks[jobID]?.cancel()
    job.phase = .cancelled
    job.progress = .none
    job.proposals = []
    job.stagedAssets = []
    job.stagedRelativePath = nil
    job.recoveryPlan = nil
    job.failure = nil
    if var checkpoint = job.queueCheckpoint {
      checkpoint.acquired = []
      checkpoint.inspected = []
      checkpoint.acquisitionComplete = false
      job.queueCheckpoint = checkpoint
    }
    if var status = job.zipStatus {
      status.extractedEntryCount = 0
      status.failureReasonCode = nil
      status.retryAllowed = false
      job.zipStatus = status
    }
    job.updatedAt = environment.clock.now()
    var cancelledLibrary = previousLibrary
    guard let jobIndex = cancelledLibrary.importJobs.firstIndex(where: { $0.id == jobID }) else {
      return
    }
    cancelledLibrary.importJobs[jobIndex] = job
    do {
      try await environment.persistence.save(cancelledLibrary)
    } catch {
      present(error, in: .importFlow)
      return
    }
    if job.zipStatus != nil, let workspace = try? await environment.media.zipWorkspace(for: jobID) {
      try? await environment.zipExtractor.cancelAndClean(
        destinationRoot: workspace.destinationRoot,
        checkpointURL: workspace.checkpointURL
      )
    }
    await environment.media.discardStaging(for: jobID)
    library = cancelledLibrary
  }

  /// Permanently removes an Inbox record and all of its app-owned temporary
  /// files. A completed book is left untouched when its import receipt is
  /// dismissed.
  @discardableResult
  func abandonImport(jobID: UUID) async -> Bool {
    guard let job = library.importJobs.first(where: { $0.id == jobID }) else {
      present(PlayerCoreError.missingImport(jobID), in: .importFlow)
      return false
    }
    guard job.phase != .committing else {
      present(
        "Wait for this audiobook to finish adding before dismissing it.",
        in: .importFlow,
        recoveryAction: .acknowledge
      )
      return false
    }

    let previousLibrary = library
    importTasks[jobID]?.cancel()
    library.importJobs.removeAll { $0.id == jobID }
    library.metadataTransactions.removeAll { transaction in
      if case .proposal(let targetJobID, _) = transaction.target {
        return targetJobID == jobID
      }
      return false
    }
    library.storageManifests.removeAll { $0.scope == .stagingJob(jobID) }

    do {
      try await persist()
    } catch {
      library = previousLibrary
      present(error, in: .importFlow)
      return false
    }

    if job.zipStatus != nil, let workspace = try? await environment.media.zipWorkspace(for: jobID) {
      try? await environment.zipExtractor.cancelAndClean(
        destinationRoot: workspace.destinationRoot,
        checkpointURL: workspace.checkpointURL
      )
    }
    await environment.media.discardStaging(for: jobID)
    _ = await refreshStorageSummary()
    return true
  }

  @discardableResult
  func addImportToLibrary(
    jobID: UUID,
    errorOwner: PlayerErrorPresentationOwner = .root
  ) async -> UUID? {
    guard var job = library.importJobs.first(where: { $0.id == jobID }) else {
      present(PlayerCoreError.missingImport(jobID), in: .importFlow, owner: errorOwner)
      return nil
    }
    if job.phase == .committed, let committedBookID = job.committedBookID {
      return committedBookID
    }
    if job.phase == .committing {
      return nil
    }
    let proposals = job.proposals
    guard
      job.phase == .ready || job.phase == .needsReview,
      !proposals.isEmpty
    else {
      present(PlayerCoreError.importNotReady(jobID), in: .importFlow, owner: errorOwner)
      return nil
    }

    let previousLibrary = library
    var managed: [ManagedAudio] = []
    do {
      job.phase = .committing
      try await replaceAndPersist(job)
      let stagedByAsset = Dictionary(uniqueKeysWithValues: job.stagedAssets.map { ($0.assetID, $0) })
      var books: [Book] = []
      for proposal in proposals {
        var committedAssets: [AudioAsset] = []
        for asset in proposal.assets {
          let mapping = stagedByAsset[asset.id]
          let stagedPath = mapping?.stagedRelativePath
            ?? (asset.id == proposal.asset.id ? job.stagedRelativePath : nil)
          guard let stagedPath else { throw PlayerCoreError.invalidAssetSelection }
          let staged = StagedAudio(
            relativePath: stagedPath,
            originalFilename: asset.originalFilename,
            checksumSHA256: asset.checksumSHA256,
            byteCount: asset.byteCount
          )
          let committed = try await environment.media.commit(
            staged,
            bookID: proposal.proposedBookID,
            assetID: asset.id
          )
          managed.append(committed)
          var committedAsset = asset
          committedAsset.managedRelativePath = committed.relativePath
          committedAssets.append(committedAsset)
        }
        books.append(
          Book(
            id: proposal.proposedBookID,
            title: proposal.title,
            authors: proposal.authors,
            durationSeconds: proposal.durationSeconds,
            artworkData: proposal.artworkData,
            assets: committedAssets,
            dateAdded: environment.clock.now(),
            narrators: proposal.narrators,
            seriesName: proposal.seriesName,
            seriesPosition: proposal.seriesPosition,
            artworkMediaType: proposal.artworkMediaType,
            chapters: proposal.chapters,
            metadata: proposal.metadata
          )
        )
      }
      // Publish only after every immutable asset move has succeeded.
      library.books.append(contentsOf: books)
      for proposal in proposals {
        let proposalTarget = MetadataTarget.proposal(jobID: jobID, proposalID: proposal.id)
        let bookTarget = MetadataTarget.book(proposal.proposedBookID)
        for index in library.metadataTransactions.indices
        where library.metadataTransactions[index].target == proposalTarget {
          library.metadataTransactions[index].target = bookTarget
        }
      }
      job.phase = .committed
      job.committedBookID = books.first?.id
      job.updatedAt = environment.clock.now()
      replace(job)
      try await persist()
      await environment.media.discardStaging(for: jobID)
      return books.first?.id
    } catch {
      for item in managed.reversed() { try? await environment.media.rollback(item) }
      library = previousLibrary
      try? await environment.persistence.save(library)
      present(error, in: .importFlow, owner: errorOwner)
      return nil
    }
  }

  @discardableResult
  func reorderAssets(jobID: UUID, proposalID: UUID, assetIDs: [UUID]) async -> Bool {
    await reviseImport(jobID: jobID) { job in
      guard let index = job.proposals.firstIndex(where: { $0.id == proposalID }) else {
        throw PlayerCoreError.missingProposal(proposalID)
      }
      var proposals = job.proposals
      let current = proposals[index]
      guard Set(assetIDs).count == assetIDs.count,
        Set(assetIDs) == Set(current.assets.map(\.id))
      else { throw PlayerCoreError.invalidAssetSelection }
      let byID = Dictionary(uniqueKeysWithValues: current.assets.map { ($0.id, $0) })
      var revised = ProposalTimeline.rebuilding(current, orderedAssets: assetIDs.compactMap { byID[$0] })
      revised.orderingEvidence = revised.assets.map {
        TrackOrderingEvidence(assetID: $0.id, source: .manual, explanation: "Order confirmed in import review.")
      }
      revised.warnings = []
      proposals[index] = revised
      job.proposals = proposals
    }
  }

  @discardableResult
  func splitProposal(jobID: UUID, proposalID: UUID, assetIDs: [UUID]) async -> Bool {
    let newProposalID = await environment.ids.next()
    let newBookID = await environment.ids.next()
    return await reviseImport(jobID: jobID) { job in
      guard let index = job.proposals.firstIndex(where: { $0.id == proposalID }) else {
        throw PlayerCoreError.missingProposal(proposalID)
      }
      var proposals = job.proposals
      let original = proposals[index]
      let selected = Set(assetIDs)
      guard !selected.isEmpty, selected.count < original.assets.count else {
        throw PlayerCoreError.invalidAssetSelection
      }
      let keptAssets = original.assets.filter { !selected.contains($0.id) }
      let splitAssets = original.assets.filter { selected.contains($0.id) }
      guard splitAssets.count == selected.count else { throw PlayerCoreError.invalidAssetSelection }
      proposals[index] = ProposalTimeline.rebuilding(original, orderedAssets: keptAssets)
      var split = BookProposal(
        id: newProposalID,
        proposedBookID: newBookID,
        title: original.title,
        authors: original.authors,
        durationSeconds: splitAssets.reduce(0) { $0 + $1.durationSeconds },
        artworkData: original.artworkData,
        asset: splitAssets[0],
        warnings: [],
        narrators: original.narrators,
        seriesName: original.seriesName,
        seriesPosition: original.seriesPosition,
        artworkMediaType: original.artworkMediaType,
        chapters: original.chapters.filter { $0.assetID.map(selected.contains) ?? false },
        additionalAssets: Array(splitAssets.dropFirst()),
        groupingEvidence: [
          GroupingEvidence(kind: .selectedTogether, explanation: "Created by splitting the import review.")
        ],
        orderingEvidence: splitAssets.map {
          TrackOrderingEvidence(assetID: $0.id, source: .manual, explanation: "Membership confirmed in import review.")
        }
      )
      split = ProposalTimeline.rebuilding(split, orderedAssets: splitAssets)
      proposals.insert(split, at: index + 1)
      job.proposals = proposals
    }
  }

  @discardableResult
  func moveAssets(
    jobID: UUID,
    assetIDs: [UUID],
    from sourceProposalID: UUID,
    to destinationProposalID: UUID
  ) async -> Bool {
    await reviseImport(jobID: jobID) { job in
      var proposals = job.proposals
      guard
        let sourceIndex = proposals.firstIndex(where: { $0.id == sourceProposalID }),
        let destinationIndex = proposals.firstIndex(where: { $0.id == destinationProposalID }),
        sourceIndex != destinationIndex
      else { throw PlayerCoreError.missingProposal(sourceProposalID) }
      let selected = Set(assetIDs)
      let source = proposals[sourceIndex]
      let destination = proposals[destinationIndex]
      let moving = source.assets.filter { selected.contains($0.id) }
      guard !selected.isEmpty, moving.count == selected.count, moving.count < source.assets.count else {
        throw PlayerCoreError.invalidAssetSelection
      }
      proposals[sourceIndex] = ProposalTimeline.rebuilding(
        source,
        orderedAssets: source.assets.filter { !selected.contains($0.id) }
      )
      var destinationBase = destination
      destinationBase.chapters += source.chapters.filter { $0.assetID.map(selected.contains) ?? false }
      let combinedAssets = destination.assets + moving
      destinationBase.assets = combinedAssets
      proposals[destinationIndex] = ProposalTimeline.rebuilding(
        destinationBase,
        orderedAssets: combinedAssets
      )
      job.proposals = proposals
    }
  }

  @discardableResult
  func moveAssets(
    jobID: UUID,
    assetIDs: [UUID],
    fromProposalID: UUID,
    toProposalID: UUID
  ) async -> Bool {
    await moveAssets(
      jobID: jobID,
      assetIDs: assetIDs,
      from: fromProposalID,
      to: toProposalID
    )
  }

  @discardableResult
  func mergeProposals(jobID: UUID, sourceProposalID: UUID, into destinationProposalID: UUID) async -> Bool {
    await reviseImport(jobID: jobID) { job in
      var proposals = job.proposals
      guard
        let sourceIndex = proposals.firstIndex(where: { $0.id == sourceProposalID }),
        let destinationIndex = proposals.firstIndex(where: { $0.id == destinationProposalID }),
        sourceIndex != destinationIndex
      else { throw PlayerCoreError.missingProposal(sourceProposalID) }
      let source = proposals[sourceIndex]
      var destination = proposals[destinationIndex]
      destination.chapters += source.chapters
      let combinedAssets = destination.assets + source.assets
      destination.assets = combinedAssets
      destination = ProposalTimeline.rebuilding(
        destination,
        orderedAssets: combinedAssets
      )
      proposals[destinationIndex] = destination
      proposals.remove(at: sourceIndex)
      job.proposals = proposals
    }
  }

  @discardableResult
  func mergeProposals(
    jobID: UUID,
    sourceProposalID: UUID,
    destinationProposalID: UUID
  ) async -> Bool {
    await mergeProposals(
      jobID: jobID,
      sourceProposalID: sourceProposalID,
      into: destinationProposalID
    )
  }

  var continueListeningBooks: [Book] { library.continueListeningBooks }

  var upNextBooks: [Book] { library.upNextBooks }

  var recentlyAddedBooks: [Book] { library.recentlyAddedBooks }

  func browseGroups(for facet: LibraryBrowseFacet) -> [LibraryBrowseGroup] {
    library.browseGroups(for: facet)
  }

  @discardableResult
  func setBookFinished(bookID: UUID, isFinished: Bool) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      guard let index = candidate.books.firstIndex(where: { $0.id == bookID }) else {
        throw PlayerCoreError.missingBook(bookID)
      }
      let now = environment.clock.now()
      if isFinished {
        let durationMilliseconds = Int64(
          (max(0, candidate.books[index].durationSeconds) * 1_000).rounded(.down)
        )
        candidate.books[index].listeningState = BookListeningState(
          status: .finished,
          positionMilliseconds: durationMilliseconds,
          lastListenedAt: now,
          finishedAt: now
        )
        candidate.upNextBookIDs.removeAll { $0 == bookID }
      } else {
        candidate.books[index].listeningState.status =
          candidate.books[index].listeningState.positionMilliseconds > 0
          ? .inProgress : .unplayed
        candidate.books[index].listeningState.finishedAt = nil
      }
    }
  }

  @discardableResult
  func addToUpNext(bookID: UUID) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      guard candidate.books.contains(where: { $0.id == bookID }) else {
        throw PlayerCoreError.missingBook(bookID)
      }
      if !candidate.upNextBookIDs.contains(bookID) {
        candidate.upNextBookIDs.append(bookID)
      }
    }
  }

  @discardableResult
  func removeFromUpNext(bookID: UUID) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      candidate.upNextBookIDs.removeAll { $0 == bookID }
    }
  }

  @discardableResult
  func reorderUpNext(bookIDs: [UUID]) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      guard validReorder(bookIDs, replacing: candidate.upNextBookIDs) else {
        throw LibraryOrganizationError.invalidBookOrder
      }
      candidate.upNextBookIDs = bookIDs
    }
  }

  @discardableResult
  func createCollection(name: String) async -> UUID? {
    let collectionID = await environment.ids.next()
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let succeeded = await applyLibraryOrganizationMutation { candidate in
      try validateCollectionName(normalizedName, excluding: nil, in: candidate)
      let now = environment.clock.now()
      candidate.collections.append(BookCollection(
        id: collectionID,
        name: normalizedName,
        orderedBookIDs: [],
        createdAt: now,
        updatedAt: now
      ))
    }
    return succeeded ? collectionID : nil
  }

  @discardableResult
  func renameCollection(id: UUID, name: String) async -> Bool {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return await applyLibraryOrganizationMutation { candidate in
      guard let index = candidate.collections.firstIndex(where: { $0.id == id }) else {
        throw LibraryOrganizationError.missingCollection(id)
      }
      try validateCollectionName(normalizedName, excluding: id, in: candidate)
      candidate.collections[index].name = normalizedName
      candidate.collections[index].updatedAt = environment.clock.now()
    }
  }

  @discardableResult
  func deleteCollection(id: UUID) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      guard let index = candidate.collections.firstIndex(where: { $0.id == id }) else {
        throw LibraryOrganizationError.missingCollection(id)
      }
      candidate.collections.remove(at: index)
    }
  }

  @discardableResult
  func addBook(_ bookID: UUID, toCollection collectionID: UUID) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      guard candidate.books.contains(where: { $0.id == bookID }) else {
        throw PlayerCoreError.missingBook(bookID)
      }
      guard let index = candidate.collections.firstIndex(where: { $0.id == collectionID }) else {
        throw LibraryOrganizationError.missingCollection(collectionID)
      }
      if !candidate.collections[index].orderedBookIDs.contains(bookID) {
        candidate.collections[index].orderedBookIDs.append(bookID)
        candidate.collections[index].updatedAt = environment.clock.now()
      }
    }
  }

  @discardableResult
  func removeBook(_ bookID: UUID, fromCollection collectionID: UUID) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      guard let index = candidate.collections.firstIndex(where: { $0.id == collectionID }) else {
        throw LibraryOrganizationError.missingCollection(collectionID)
      }
      candidate.collections[index].orderedBookIDs.removeAll { $0 == bookID }
      candidate.collections[index].updatedAt = environment.clock.now()
    }
  }

  @discardableResult
  func reorderCollection(_ collectionID: UUID, bookIDs: [UUID]) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      guard let index = candidate.collections.firstIndex(where: { $0.id == collectionID }) else {
        throw LibraryOrganizationError.missingCollection(collectionID)
      }
      guard validReorder(bookIDs, replacing: candidate.collections[index].orderedBookIDs) else {
        throw LibraryOrganizationError.invalidBookOrder
      }
      candidate.collections[index].orderedBookIDs = bookIDs
      candidate.collections[index].updatedAt = environment.clock.now()
    }
  }

  @discardableResult
  func setAllBooksViewStyle(_ style: LibraryViewStyle) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      candidate.allBooksViewStyle = style
    }
  }

  @discardableResult
  func setLibrarySearchPreferences(_ preferences: LibrarySearchPreferences) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      candidate.searchPreferences = preferences
    }
  }

  @discardableResult
  func clearLibrarySearchPreferences() async -> Bool {
    await setLibrarySearchPreferences(.default)
  }

  func bookmarks(for bookID: UUID) -> [Bookmark] {
    library.bookmarks.filter { $0.bookID == bookID }
  }

  func searchBookmarks(
    bookID: UUID,
    query: String,
    sort: BookmarkSort = .positionAscending
  ) -> [Bookmark] {
    BookmarkIndex(bookmarks: bookmarks(for: bookID)).search(query: query, sort: sort)
  }

  @discardableResult
  func addBookmark(note: String? = nil) async -> UUID? {
    guard let book = currentBook else {
      present(BookmarkError.noCurrentBook, in: .bookmark)
      return nil
    }
    do {
      let bookmarkID = await environment.ids.next()
      let bookmark = try BookmarkPlanner.makeBookmark(
        id: bookmarkID,
        book: book,
        positionSeconds: sleepTimerPosition(for: book.id),
        note: note,
        createdAt: environment.clock.now()
      )
      var candidate = library
      candidate.bookmarks.append(bookmark)
      try await environment.persistence.save(candidate)
      library = candidate
      return bookmarkID
    } catch {
      present(error, in: .bookmark)
      return nil
    }
  }

  @discardableResult
  func editBookmark(
    id bookmarkID: UUID,
    label: String,
    note: String?
  ) async -> Bool {
    await applyLibraryOrganizationMutation(in: .bookmark) { candidate in
      guard let index = candidate.bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
        throw BookmarkError.missingBookmark(bookmarkID)
      }
      candidate.bookmarks[index] = try BookmarkPlanner.edited(
        candidate.bookmarks[index],
        label: label,
        note: note,
        updatedAt: environment.clock.now()
      )
    }
  }

  @discardableResult
  func deleteBookmark(id bookmarkID: UUID) async -> UUID? {
    guard let bookmarkIndex = library.bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
      present(BookmarkError.missingBookmark(bookmarkID), in: .bookmark)
      return nil
    }
    let transactionID = await environment.ids.next()
    var candidate = library
    let bookmark = candidate.bookmarks.remove(at: bookmarkIndex)
    candidate.bookmarkDeletionTransactions.append(BookmarkDeletionTransaction(
      id: transactionID,
      bookmark: bookmark,
      originalIndex: bookmarkIndex,
      deletedAt: environment.clock.now(),
      status: .deleted,
      undoneAt: nil
    ))
    do {
      try await environment.persistence.save(candidate)
      library = candidate
      return transactionID
    } catch {
      present(error, in: .bookmark)
      return nil
    }
  }

  @discardableResult
  func undoDeleteBookmark(transactionID: UUID) async -> Bool {
    await applyLibraryOrganizationMutation(in: .bookmark) { candidate in
      guard let transactionIndex = candidate.bookmarkDeletionTransactions.firstIndex(where: {
        $0.id == transactionID && $0.status == .deleted
      }) else {
        throw BookmarkError.noDeletionToUndo(transactionID)
      }
      let transaction = candidate.bookmarkDeletionTransactions[transactionIndex]
      guard !candidate.bookmarks.contains(where: { $0.id == transaction.bookmark.id }) else {
        throw BookmarkError.noDeletionToUndo(transactionID)
      }
      candidate.bookmarks.insert(
        transaction.bookmark,
        at: min(max(0, transaction.originalIndex), candidate.bookmarks.count)
      )
      candidate.bookmarkDeletionTransactions[transactionIndex].status = .undone
      candidate.bookmarkDeletionTransactions[transactionIndex].undoneAt = environment.clock.now()
    }
  }

  @discardableResult
  func jumpToBookmark(id bookmarkID: UUID) async -> Bool {
    guard let bookmark = library.bookmarks.first(where: { $0.id == bookmarkID }) else {
      present(BookmarkError.missingBookmark(bookmarkID), in: .bookmark)
      return false
    }
    guard let book = library.books.first(where: { $0.id == bookmark.bookID }) else {
      present(PlayerCoreError.missingBook(bookmark.bookID), in: .bookmark)
      return false
    }
    let wasPlaying = playbackState.status == .playing
    do {
      if currentBook?.id != book.id || environment.playback.state.loadedBookID != book.id {
        if let timer = library.activeSleepTimer, timer.bookID != book.id,
          !(await cancelSleepTimer())
        {
          return false
        }
        try await load(book: book, at: bookmark.bookPositionSeconds)
        applyCurrentTransportConfiguration(for: book.id)
      }
      guard await seekToBookPosition(bookmark.bookPositionSeconds) != nil else { return false }
      if wasPlaying {
        environment.playback.play()
        playbackState = environment.playback.state
        playbackState.elapsedSeconds = currentBookPositionSeconds
        publishNowPlaying()
      }
      return true
    } catch {
      present(error, in: .bookmark)
      return false
    }
  }

  @discardableResult
  func removeBook(
    bookID: UUID,
    mediaPolicy: LibraryRemovalMediaPolicy
  ) async -> UUID? {
    guard let originalBookIndex = library.books.firstIndex(where: { $0.id == bookID }) else {
      present(PlayerCoreError.missingBook(bookID), in: .storage)
      return nil
    }
    let transactionID = await environment.ids.next()
    var mediaManifest: TrashedMediaManifest?
    do {
      if mediaPolicy == .moveManagedMediaToTrash {
        mediaManifest = try await environment.media.moveManagedMediaToTrash(
          bookID: bookID,
          transactionID: transactionID
        )
      }

      var candidate = library
      let book = candidate.books.remove(at: originalBookIndex)
      let upNextIndex = candidate.upNextBookIDs.firstIndex(of: bookID)
      candidate.upNextBookIDs.removeAll { $0 == bookID }
      var placements: [CollectionBookPlacement] = []
      for index in candidate.collections.indices {
        if let placement = candidate.collections[index].orderedBookIDs.firstIndex(of: bookID) {
          placements.append(CollectionBookPlacement(
            collectionID: candidate.collections[index].id,
            index: placement
          ))
          candidate.collections[index].orderedBookIDs.removeAll { $0 == bookID }
          candidate.collections[index].updatedAt = environment.clock.now()
        }
      }
      let wasCurrentBook = candidate.currentBookID == bookID
      let playbackPosition = candidate.playbackPosition?.bookID == bookID
        ? candidate.playbackPosition : nil
      if playbackPosition != nil { candidate.playbackPosition = nil }
      if candidate.activeSleepTimer?.bookID == bookID {
        candidate.activeSleepTimer = nil
      }
      let positionEvents = candidate.positionJournal.filter { $0.bookID == bookID }
      candidate.positionJournal.removeAll { $0.bookID == bookID }
      let metadataTransactions = candidate.metadataTransactions.filter {
        $0.target == .book(bookID)
      }
      candidate.metadataTransactions.removeAll { $0.target == .book(bookID) }
      if wasCurrentBook { candidate.currentBookID = nil }
      candidate.trashTransactions.append(LibraryTrashTransaction(
        id: transactionID,
        book: book,
        originalBookIndex: originalBookIndex,
        mediaPolicy: mediaPolicy,
        mediaManifest: mediaManifest,
        upNextIndex: upNextIndex,
        collectionPlacements: placements,
        wasCurrentBook: wasCurrentBook,
        playbackPosition: playbackPosition,
        positionEvents: positionEvents,
        metadataTransactions: metadataTransactions,
        removedAt: environment.clock.now(),
        status: .recoverable,
        restoredAt: nil
      ))
      try await environment.persistence.save(candidate)
      library = candidate
      if wasCurrentBook {
        await checkpointPlaybackMeter(force: true)
        environment.playback.unload()
        playbackMeterLastUptime = nil
        pendingPlaybackMeterSeconds = 0
        playbackState = .unloaded
        loadedAssetID = nil
        loadedAssetTimelineStartSeconds = 0
        sleepTimerMonitorTask?.cancel()
        sleepTimerMonitorTask = nil
      }
      publishNowPlaying()
      return transactionID
    } catch {
      if let mediaManifest {
        try? await environment.media.restoreManagedMediaFromTrash(mediaManifest)
      }
      present(error, in: .storage)
      return nil
    }
  }

  @discardableResult
  func restoreTrashedBook(transactionID: UUID) async -> Bool {
    guard mutatingTrashTransactionIDs.insert(transactionID).inserted else {
      present(LibraryOrganizationError.trashTransactionNotRecoverable(transactionID), in: .storage)
      return false
    }
    defer { mutatingTrashTransactionIDs.remove(transactionID) }
    guard let transactionIndex = library.trashTransactions.firstIndex(where: {
      $0.id == transactionID
    }) else {
      present(LibraryOrganizationError.missingTrashTransaction(transactionID), in: .storage)
      return false
    }
    let transaction = library.trashTransactions[transactionIndex]
    guard transaction.status == .recoverable, let book = transaction.book else {
      present(
        LibraryOrganizationError.trashTransactionNotRecoverable(transactionID),
        in: .storage
      )
      return false
    }
    guard !library.books.contains(where: { $0.id == book.id }) else {
      present(LibraryOrganizationError.bookAlreadyExists(book.id), in: .storage)
      return false
    }

    var restoredMedia = false
    do {
      if let manifest = transaction.mediaManifest {
        try await environment.media.restoreManagedMediaFromTrash(manifest)
        restoredMedia = true
      }
      var candidate = library
      candidate.books.insert(
        book,
        at: min(max(0, transaction.originalBookIndex), candidate.books.count)
      )
      if let upNextIndex = transaction.upNextIndex,
        !candidate.upNextBookIDs.contains(book.id)
      {
        candidate.upNextBookIDs.insert(
          book.id,
          at: min(max(0, upNextIndex), candidate.upNextBookIDs.count)
        )
      }
      for placement in transaction.collectionPlacements {
        guard let collectionIndex = candidate.collections.firstIndex(where: {
          $0.id == placement.collectionID
        }) else { continue }
        if !candidate.collections[collectionIndex].orderedBookIDs.contains(book.id) {
          candidate.collections[collectionIndex].orderedBookIDs.insert(
            book.id,
            at: min(
              max(0, placement.index),
              candidate.collections[collectionIndex].orderedBookIDs.count
            )
          )
          candidate.collections[collectionIndex].updatedAt = environment.clock.now()
        }
      }
      let existingEventIDs = Set(candidate.positionJournal.map(\.id))
      candidate.positionJournal.append(contentsOf: transaction.positionEvents.filter {
        !existingEventIDs.contains($0.id)
      })
      candidate.positionJournal.sort { $0.sequence < $1.sequence }
      let existingMetadataTransactionIDs = Set(candidate.metadataTransactions.map(\.id))
      candidate.metadataTransactions.append(contentsOf: transaction.metadataTransactions.filter {
        !existingMetadataTransactionIDs.contains($0.id)
      })
      if transaction.wasCurrentBook && candidate.currentBookID == nil {
        candidate.currentBookID = book.id
        candidate.playbackPosition = transaction.playbackPosition
      }
      candidate.trashTransactions[transactionIndex].status = .restored
      candidate.trashTransactions[transactionIndex].restoredAt = environment.clock.now()
      try await environment.persistence.save(candidate)
      library = candidate
      if candidate.currentBookID == book.id {
        let seconds = candidate.playbackPosition?.seconds
          ?? book.listeningState.positionSeconds
        playbackState = PlaybackState(
          status: .paused,
          loadedBookID: book.id,
          elapsedSeconds: seconds
        )
        // The durable restore is complete even if an audio adapter cannot load
        // immediately (for example while protected files are unavailable).
        try? await loadCurrentBookIntoPlayback()
      }
      publishNowPlaying()
      return true
    } catch {
      if restoredMedia {
        _ = try? await environment.media.moveManagedMediaToTrash(
          bookID: book.id,
          transactionID: transactionID
        )
      }
      present(error, in: .storage)
      return false
    }
  }

  var currentTransportPreferences: TransportPreferences {
    guard let bookID = library.currentBookID else {
      return library.globalTransportPreferences
    }
    return transportPreferences(for: bookID)
  }

  func transportPreferences(for bookID: UUID) -> TransportPreferences {
    library.books.first(where: { $0.id == bookID })?
      .transportPreferenceOverride?.resolved(over: library.globalTransportPreferences)
      ?? library.globalTransportPreferences
  }

  @discardableResult
  func setGlobalTransportPreferences(
    _ preferences: TransportPreferences,
    errorOwner: PlayerErrorPresentationOwner? = nil
  ) async -> Bool {
    guard preferences.isValid else {
      present(
        TransportPreferencesError.invalidPreferences,
        in: .transportPreferences,
        owner: errorOwner,
        recoveryAction: .openSettings
      )
      return false
    }
    let changed = await applyLibraryOrganizationMutation(
      in: .transportPreferences,
      owner: errorOwner
    ) { candidate in
      candidate.globalTransportPreferences = preferences
    }
    if changed { applyCurrentTransportConfiguration() }
    return changed
  }

  @discardableResult
  func setAccessibilityPreferences(_ preferences: AccessibilityPreferences) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      candidate.accessibilityPreferences = preferences
    }
  }

  @discardableResult
  func setPrefersHighContrast(_ enabled: Bool) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      candidate.accessibilityPreferences.prefersHighContrast = enabled
    }
  }

  @discardableResult
  func setReducesDecorativeArtwork(_ enabled: Bool) async -> Bool {
    await applyLibraryOrganizationMutation { candidate in
      candidate.accessibilityPreferences.reducesDecorativeArtwork = enabled
    }
  }

  @discardableResult
  func setTransportPreferenceOverride(
    _ preferenceOverride: TransportPreferenceOverride,
    for bookID: UUID,
    errorOwner: PlayerErrorPresentationOwner? = nil
  ) async -> Bool {
    guard preferenceOverride.isValid else {
      present(
        TransportPreferencesError.invalidPreferences,
        in: .transportPreferences,
        owner: errorOwner,
        recoveryAction: .openSettings
      )
      return false
    }
    let changed = await applyLibraryOrganizationMutation(
      in: .transportPreferences,
      owner: errorOwner
    ) { candidate in
      guard let index = candidate.books.firstIndex(where: { $0.id == bookID }) else {
        throw PlayerCoreError.missingBook(bookID)
      }
      candidate.books[index].transportPreferenceOverride = preferenceOverride.isEmpty
        ? nil : preferenceOverride
    }
    if changed, library.currentBookID == bookID { applyCurrentTransportConfiguration() }
    return changed
  }

  @discardableResult
  func clearTransportPreferenceOverride(
    for bookID: UUID,
    errorOwner: PlayerErrorPresentationOwner? = nil
  ) async -> Bool {
    await setTransportPreferenceOverride(.empty, for: bookID, errorOwner: errorOwner)
  }

  @discardableResult
  func setPlaybackRate(_ rate: Double, for bookID: UUID) async -> Bool {
    guard TransportPreferences.isValidPlaybackRate(rate) else {
      present(
        TransportPreferencesError.invalidPreferences,
        in: .playback,
        recoveryAction: .openSettings
      )
      return false
    }
    var preferenceOverride = library.books.first(where: { $0.id == bookID })?
      .transportPreferenceOverride ?? .empty
    preferenceOverride.playbackRate = rate
    return await setTransportPreferenceOverride(preferenceOverride, for: bookID)
  }

  @discardableResult
  func setSkipIntervals(
    backward: Double,
    forward: Double,
    for bookID: UUID
  ) async -> Bool {
    guard backward.isFinite, backward > 0, forward.isFinite, forward > 0 else {
      present(
        TransportPreferencesError.invalidPreferences,
        in: .playback,
        recoveryAction: .openSettings
      )
      return false
    }
    var preferenceOverride = library.books.first(where: { $0.id == bookID })?
      .transportPreferenceOverride ?? .empty
    preferenceOverride.backwardSkipSeconds = backward
    preferenceOverride.forwardSkipSeconds = forward
    return await setTransportPreferenceOverride(preferenceOverride, for: bookID)
  }

  @discardableResult
  func setSeekContext(_ context: PlaybackSeekContext, for bookID: UUID) async -> Bool {
    var preferenceOverride = library.books.first(where: { $0.id == bookID })?
      .transportPreferenceOverride ?? .empty
    preferenceOverride.seekContext = context
    return await setTransportPreferenceOverride(preferenceOverride, for: bookID)
  }

  var pendingResumeRewind: ResumeRewindTransaction? {
    guard let bookID = playbackState.loadedBookID ?? library.currentBookID else { return nil }
    return library.resumeRewindTransactions.last(where: {
      $0.bookID == bookID && $0.status == .applied
    })
  }

  /// Copies the engine's live playhead into observable UI state. This remains
  /// available for lifecycle checkpoints; normal live progress arrives through
  /// the playback engine's event handler.
  func synchronizePlaybackProgress() async {
    guard playbackState.status == .playing else { return }
    await applyPlaybackProgress(currentBookPositionSeconds)
  }

  private func handlePlaybackEngineEvent(_ event: PlaybackEngineEvent) async {
    switch event {
    case .progress(let assetSeconds):
      guard playbackState.status == .playing, assetSeconds.isFinite else { return }
      await applyPlaybackProgress(loadedAssetTimelineStartSeconds + max(0, assetSeconds))
    case .reachedEnd:
      await handlePlaybackReachedEnd()
    }
  }

  private func applyPlaybackProgress(_ requestedPosition: Double) async {
    guard playbackState.status == .playing, let book = currentBook else { return }
    await checkpointPlaybackMeter(force: false)
    synchronizeMonetizationSnapshot()
    let position = min(max(0, requestedPosition), book.durationSeconds)
    guard position.isFinite else { return }
    playbackState.elapsedSeconds = position
    publishNowPlaying()
    await evaluateSleepTimer()
    await dismissResumeRewindNoticeIfNeeded(at: position)
  }

  private func handlePlaybackReachedEnd() async {
    guard let book = currentBook, let loadedAssetID else { return }
    let orderedAssets = book.assets.sorted {
      if $0.timelineStartSeconds != $1.timelineStartSeconds {
        return $0.timelineStartSeconds < $1.timelineStartSeconds
      }
      return $0.importOrder < $1.importOrder
    }
    guard let currentIndex = orderedAssets.firstIndex(where: { $0.id == loadedAssetID }) else {
      return
    }
    let completedAsset = orderedAssets[currentIndex]
    let boundary = min(
      book.durationSeconds,
      completedAsset.timelineStartSeconds + completedAsset.durationSeconds
    )
    playbackState = environment.playback.state
    playbackState.elapsedSeconds = boundary

    if orderedAssets.indices.contains(currentIndex + 1) {
      do {
        let next = orderedAssets[currentIndex + 1]
        try await load(book: book, at: next.timelineStartSeconds)
        applyCurrentTransportConfiguration(for: book.id)
        environment.playback.play()
        playbackState = environment.playback.state
        playbackState.elapsedSeconds = next.timelineStartSeconds
        publishNowPlaying()
      } catch {
        playbackMeterLastUptime = nil
        present(error, in: .playback)
      }
      return
    }

    await checkpointPlaybackMeter(force: true)
    playbackMeterLastUptime = nil
    _ = await recordAcknowledgedPlaybackPosition(
      book.durationSeconds,
      reason: .completion,
      marksFinished: true
    )
  }

  var activeSleepTimer: ActiveSleepTimer? { library.activeSleepTimer }

  var activeSleepTimerProjection: SleepTimerProjection? {
    guard let timer = library.activeSleepTimer else { return nil }
    return SleepTimerPlanner.projection(
      for: timer,
      now: environment.clock.now(),
      currentPositionSeconds: sleepTimerPosition(for: timer.bookID),
      playbackRate: environment.playback.playbackRate
    )
  }

  var recentSleepHistory: [SleepTimerHistoryEntry] {
    SleepTimerHistoryOrdering.newestFirst(library.sleepTimerHistory)
  }

  var sleepResumeContext: SleepResumeContext? {
    let now = environment.clock.now()
    guard let history = recentSleepHistory.first(where: { history in
      history.status == .completed
        && history.resumeContextUsedAt == nil
        && history.completedAt <= now
        && history.resumeContextExpiresAt >= now
        && library.books.contains(where: { book in book.id == history.bookID })
    }) else { return nil }
    return SleepResumeContext(
      historyID: history.id,
      bookID: history.bookID,
      stoppedPositionMilliseconds: history.actualStopPositionMilliseconds,
      availableUntil: history.resumeContextExpiresAt
    )
  }

  @discardableResult
  func startSleepTimer(
    selection: SleepTimerSelection,
    fadeEnabled: Bool = true
  ) async -> UUID? {
    guard let book = currentBook else {
      present(
        SleepTimerError.noCurrentBook,
        in: .sleepTimer,
        recoveryAction: .acknowledge
      )
      return nil
    }
    let previousLibrary = library
    do {
      let timerID = await environment.ids.next()
      let now = environment.clock.now()
      let position = sleepTimerPosition(for: book.id)
      let timer = try SleepTimerPlanner.makeTimer(
        id: timerID,
        book: book,
        selection: selection,
        fadeEnabled: fadeEnabled,
        currentPositionSeconds: position,
        now: now
      )
      if let replaced = library.activeSleepTimer {
        let historyID = await environment.ids.next()
        appendSleepHistory(SleepTimerHistoryEntry(
          id: historyID,
          timerID: replaced.id,
          bookID: replaced.bookID,
          selection: replaced.selection,
          fadeEnabled: replaced.fadeEnabled,
          startedAt: replaced.startedAt,
          expectedDeadline: replaced.deadline,
          expectedBoundaryPositionMilliseconds: replaced.boundaryPositionMilliseconds,
          actualStopPositionMilliseconds: sleepTimerPositionMilliseconds(for: replaced.bookID),
          completedAt: now,
          status: .replaced,
          positionEventID: nil,
          resumeContextUsedAt: nil
        ))
      }
      library.activeSleepTimer = timer
      try await persist()
      environment.playback.cancelSleepFade()
      scheduleSleepTimerMonitor()
      return timerID
    } catch {
      library = previousLibrary
      present(error, in: .sleepTimer)
      return nil
    }
  }

  @discardableResult
  func cancelSleepTimer() async -> Bool {
    guard let timer = library.activeSleepTimer else {
      present(
        SleepTimerError.noActiveTimer,
        in: .sleepTimer,
        recoveryAction: .acknowledge
      )
      return false
    }
    let previousLibrary = library
    do {
      let historyID = await environment.ids.next()
      appendSleepHistory(SleepTimerHistoryEntry(
        id: historyID,
        timerID: timer.id,
        bookID: timer.bookID,
        selection: timer.selection,
        fadeEnabled: timer.fadeEnabled,
        startedAt: timer.startedAt,
        expectedDeadline: timer.deadline,
        expectedBoundaryPositionMilliseconds: timer.boundaryPositionMilliseconds,
        actualStopPositionMilliseconds: sleepTimerPositionMilliseconds(for: timer.bookID),
        completedAt: environment.clock.now(),
        status: .cancelled,
        positionEventID: nil,
        resumeContextUsedAt: nil
      ))
      library.activeSleepTimer = nil
      try await persist()
      environment.playback.cancelSleepFade()
      sleepTimerMonitorTask?.cancel()
      sleepTimerMonitorTask = nil
      return true
    } catch {
      library = previousLibrary
      present(error, in: .sleepTimer)
      return false
    }
  }

  func evaluateSleepTimer() async {
    guard !sleepTimerEvaluationInProgress, var timer = library.activeSleepTimer else { return }
    let position = sleepTimerPosition(for: timer.bookID)
    guard timer.phase == .fading || SleepTimerPlanner.shouldBeginFade(
      timer,
      now: environment.clock.now(),
      currentPositionSeconds: position,
      playbackRate: environment.playback.playbackRate
    ) else { return }

    sleepTimerEvaluationInProgress = true
    defer { sleepTimerEvaluationInProgress = false }
    if timer.phase == .active {
      let previousLibrary = library
      timer.phase = .fading
      library.activeSleepTimer = timer
      do {
        try await persist()
      } catch {
        library = previousLibrary
        present(error, in: .sleepTimer, owner: .root)
        return
      }
      environment.playback.beginSleepFade(durationSeconds: timer.fadeDurationSeconds)
    }

    guard SleepTimerPlanner.hasReachedStopBoundary(
      timer,
      now: environment.clock.now(),
      currentPositionSeconds: sleepTimerPosition(for: timer.bookID)
    ) else { return }
    await checkpointPlaybackMeter(force: true)
    environment.playback.completeSleepFadeAndPause()
    playbackMeterLastUptime = nil
    playbackState = environment.playback.state
    playbackState.elapsedSeconds = currentBookPositionSeconds
    guard library.activeSleepTimer?.id == timer.id else { return }
    _ = await recordSleepTimerStop(
      currentBookPositionSeconds,
      timer: timer
    )
  }

  @discardableResult
  func resumeFromSleepWithContext() async -> Bool {
    guard let context = sleepResumeContext,
      let history = library.sleepTimerHistory.first(where: { $0.id == context.historyID }),
      let book = library.books.first(where: { $0.id == context.bookID })
    else {
      present(
        SleepTimerError.noResumeContext,
        in: .sleepTimer,
        owner: .root,
        recoveryAction: .acknowledge
      )
      return false
    }
    guard allowNewPlaybackSession() else { return false }
    do {
      try prepareAudioSessionForPlayback()
      let stoppedSeconds = history.actualStopSeconds
      try await load(book: book, at: stoppedSeconds)
      applyCurrentTransportConfiguration(for: book.id)
      let now = environment.clock.now()
      if let plan = SleepTimerPlanner.resumePlan(
        from: history,
        book: book,
        resumedAt: now,
        preferences: library.smartRewindPreferences
      ), !(await applySmartRewind(plan)) {
        return false
      }
      environment.playback.play()
      playbackState = environment.playback.state
      playbackState.elapsedSeconds = currentBookPositionSeconds
      beginPlaybackMetering()
      guard await recordAcknowledgedPlaybackPosition(
        currentBookPositionSeconds,
        reason: .play,
        consumedSleepHistoryID: history.id
      ) != nil else {
        environment.playback.pause()
        playbackMeterLastUptime = nil
        playbackState = environment.playback.state
        playbackState.elapsedSeconds = currentBookPositionSeconds
        return false
      }
      return true
    } catch {
      present(error, in: .sleepTimer, owner: .root)
      return false
    }
  }

  func smartRewindPlan(for bookID: UUID) -> SmartRewindPlan? {
    guard
      let book = library.books.first(where: { $0.id == bookID }),
      let position = library.playbackPosition,
      position.bookID == bookID,
      let pauseEvent = library.positionJournal.first(where: {
        $0.id == position.sourceEventID && $0.bookID == bookID && $0.hasValidIntegrity
      }),
      [.pause, .interruption, .routeChange].contains(pauseEvent.reason)
    else { return nil }
    return SmartRewindPlanner.plan(
      for: book,
      positionMilliseconds: position.positionMilliseconds,
      pausedAt: pauseEvent.acknowledgedAt,
      resumedAt: environment.clock.now(),
      preferences: library.smartRewindPreferences
    )
  }

  @discardableResult
  func setSmartRewindPreferences(_ preferences: SmartRewindPreferences) async -> Bool {
    guard preferences.isValid else {
      present(
        SmartRewindError.invalidPreferences,
        in: .smartRewind,
        recoveryAction: .openSettings
      )
      return false
    }
    return await applyLibraryOrganizationMutation(in: .smartRewind) { candidate in
      candidate.smartRewindPreferences = preferences
    }
  }

  @discardableResult
  func setSmartRewindEnabled(_ isEnabled: Bool) async -> Bool {
    var preferences = library.smartRewindPreferences
    preferences.isEnabled = isEnabled
    return await setSmartRewindPreferences(preferences)
  }

  @discardableResult
  func setSmartRewindMaximum(_ seconds: Double) async -> Bool {
    var preferences = library.smartRewindPreferences
    preferences.maximumRewindSeconds = seconds
    return await setSmartRewindPreferences(preferences)
  }

  @discardableResult
  func undoResumeRewind() async -> Bool {
    guard let transaction = pendingResumeRewind else {
      present(
        SmartRewindError.noRewindToUndo,
        in: .smartRewind,
        recoveryAction: .acknowledge
      )
      return false
    }
    guard let undoEvent = await seekToBookPosition(
      transaction.plan.originalSeconds,
      reason: .undoResumeRewind
    ) else { return false }
    let previousLibrary = library
    do {
      guard let index = library.resumeRewindTransactions.firstIndex(where: {
        $0.id == transaction.id && $0.status == .applied
      }) else { throw SmartRewindError.noRewindToUndo }
      library.resumeRewindTransactions[index].status = .undone
      library.resumeRewindTransactions[index].undoneAt = undoEvent.acknowledgedAt
      library.resumeRewindTransactions[index].undoEventID = undoEvent.id
      try await persist()
      return true
    } catch {
      library = previousLibrary
      present(error, in: .smartRewind)
      return false
    }
  }

  func loadCurrentBook() async {
    do {
      try await loadCurrentBookIntoPlayback()
    } catch {
      present(error, in: .playback)
    }
  }

  func play(bookID: UUID, at seconds: Double? = nil) async {
    guard let book = library.books.first(where: { $0.id == bookID }) else {
      present(
        PlayerCoreError.missingBook(bookID),
        in: .playback,
        recoveryAction: .acknowledge
      )
      return
    }
    guard allowNewPlaybackSession() else { return }
    let rewindPlan = seconds == nil ? smartRewindPlan(for: bookID) : nil

    do {
      try prepareAudioSessionForPlayback()
      let startSeconds = seconds
        ?? (library.playbackPosition?.bookID == bookID ? library.playbackPosition?.seconds : nil)
        ?? (book.listeningState.status == .finished ? 0 : book.listeningState.positionSeconds)
      try await load(book: book, at: startSeconds)
      applyCurrentTransportConfiguration(for: bookID)
      if let rewindPlan {
        _ = await applySmartRewind(rewindPlan)
      }
      environment.playback.play()
      playbackState = environment.playback.state
      playbackState.elapsedSeconds = currentBookPositionSeconds
      beginPlaybackMetering()
      library.currentBookID = bookID
      await acknowledgePlaybackPosition(
        currentBookPositionSeconds,
        reason: .play
      )
    } catch {
      present(error, in: .playback)
    }
  }

  func seek(to seconds: Double) async {
    await seekToBookPosition(seconds)
  }

  func seek(to seconds: Double, context: PlaybackSeekContext) async {
    guard let book = currentBook else { return }
    let position = PlaybackTimeline.seekPosition(
      seconds,
      context: context,
      in: book,
      from: currentBookPositionSeconds
    )
    await seekToBookPosition(position)
  }

  func previousChapter() async {
    guard let book = currentBook,
      let position = PlaybackTimeline.previousChapterPosition(
        in: book,
        at: currentBookPositionSeconds
      )
    else { return }
    await seekToBookPosition(position)
  }

  func nextChapter() async {
    guard let book = currentBook,
      let position = PlaybackTimeline.nextChapterPosition(
        in: book,
        at: currentBookPositionSeconds
      )
    else { return }
    await seekToBookPosition(position)
  }

  func skipBackward() async {
    await seekToBookPosition(
      currentBookPositionSeconds - currentTransportPreferences.backwardSkipSeconds
    )
  }

  func skipForward() async {
    await seekToBookPosition(
      currentBookPositionSeconds + currentTransportPreferences.forwardSkipSeconds
    )
  }

  func pause() async {
    await pause(reason: .pause)
  }

  func checkpointForBackground() async {
    guard playbackState.loadedBookID != nil, playbackState.status == .playing else { return }
    await checkpointPlaybackMeter(force: true)
    await acknowledgePlaybackPosition(
      currentBookPositionSeconds,
      reason: .background
    )
  }

  private func pausePlayback() -> Double {
    environment.playback.pause()
    playbackState = environment.playback.state
    playbackState.elapsedSeconds = currentBookPositionSeconds
    return playbackState.elapsedSeconds
  }

  private func pause(reason: PositionEventReason) async {
    await checkpointPlaybackMeter(force: true)
    let seconds = pausePlayback()
    playbackMeterLastUptime = nil
    await acknowledgePlaybackPosition(seconds, reason: reason)
  }

  private func resumeCurrentBook(applyingSmartRewind: Bool = true) async {
    guard let bookID = library.currentBookID else { return }
    guard allowNewPlaybackSession() else { return }
    if environment.playback.state.loadedBookID == bookID {
      do {
        try prepareAudioSessionForPlayback()
        applyCurrentTransportConfiguration(for: bookID)
        if applyingSmartRewind, let rewindPlan = smartRewindPlan(for: bookID) {
          _ = await applySmartRewind(rewindPlan)
        }
        environment.playback.play()
        playbackState = environment.playback.state
        playbackState.elapsedSeconds = currentBookPositionSeconds
        beginPlaybackMetering()
        await acknowledgePlaybackPosition(
          currentBookPositionSeconds,
          reason: .play
        )
      } catch {
        present(error, in: .playback)
      }
    } else {
      if applyingSmartRewind {
        await play(bookID: bookID)
      } else {
        let acknowledgedSeconds =
          library.playbackPosition?.bookID == bookID
          ? library.playbackPosition?.seconds : nil
        await play(bookID: bookID, at: acknowledgedSeconds ?? currentBookPositionSeconds)
      }
    }
  }

  private func handleRemoteCommand(_ command: RemotePlaybackCommand) async {
    switch command {
    case .play:
      await resumeCurrentBook()
    case .pause:
      if playbackState.status == .playing { await pause() }
    case .togglePlayPause:
      if playbackState.status == .playing {
        await pause()
      } else {
        await resumeCurrentBook()
      }
    case .previousChapter:
      await previousChapter()
    case .nextChapter:
      await nextChapter()
    case .skipForward(let seconds):
      await seekToBookPosition(currentBookPositionSeconds + max(0, seconds))
    case .skipBackward(let seconds):
      await seekToBookPosition(currentBookPositionSeconds - max(0, seconds))
    case .changePosition(let seconds):
      await seek(to: seconds)
    case .changePlaybackRate(let rate):
      if let bookID = library.currentBookID {
        _ = await setPlaybackRate(rate, for: bookID)
      }
    }
  }

  private func handleAudioSessionEvent(_ event: AudioSessionEvent) async {
    switch event {
    case .interruptionBegan:
      let beganWhilePlaying = playbackState.status == .playing
      wasPlayingBeforeInterruption = wasPlayingBeforeInterruption || beganWhilePlaying
      if beganWhilePlaying { await pause(reason: .interruption) }
    case .interruptionEnded(let shouldResume):
      let resume = shouldResume && wasPlayingBeforeInterruption
      wasPlayingBeforeInterruption = false
      // A system interruption is not a new listening session. Resume the exact
      // acknowledged position rather than applying the user's away-time rewind.
      if resume { await resumeCurrentBook(applyingSmartRewind: false) }
    case .oldDeviceUnavailable:
      // Never resume onto the speaker after a headset or car route disappears,
      // including when route loss arrives during an active interruption.
      wasPlayingBeforeInterruption = false
      if playbackState.status == .playing { await pause(reason: .routeChange) }
    }
  }

  private func loadCurrentBookIntoPlayback() async throws {
    guard let bookID = library.currentBookID else { return }
    guard let book = library.books.first(where: { $0.id == bookID }) else {
      throw PlayerCoreError.missingBook(bookID)
    }
    let seconds = library.playbackPosition?.bookID == bookID
      ? library.playbackPosition?.seconds ?? 0
      : (book.listeningState.status == .finished ? 0 : book.listeningState.positionSeconds)
    try await load(book: book, at: seconds)
    applyCurrentTransportConfiguration(for: bookID)
  }

  private var currentBook: Book? {
    guard let bookID = playbackState.loadedBookID ?? library.currentBookID else { return nil }
    return library.books.first(where: { $0.id == bookID })
  }

  private var currentBookPositionSeconds: Double {
    guard let book = currentBook else { return 0 }
    return min(
      max(0, loadedAssetTimelineStartSeconds + environment.playback.currentPositionSeconds),
      book.durationSeconds
    )
  }

  private func sleepTimerPosition(for bookID: UUID) -> Double {
    if (playbackState.loadedBookID ?? library.currentBookID) == bookID,
      environment.playback.state.loadedBookID == bookID
    {
      return currentBookPositionSeconds
    }
    if library.playbackPosition?.bookID == bookID {
      return library.playbackPosition?.seconds ?? 0
    }
    return library.books.first(where: { $0.id == bookID })?.listeningState.positionSeconds ?? 0
  }

  private func sleepTimerPositionMilliseconds(for bookID: UUID) -> Int64 {
    Int64((max(0, sleepTimerPosition(for: bookID)) * 1_000).rounded(.down))
  }

  private func appendSleepHistory(_ entry: SleepTimerHistoryEntry) {
    library.sleepTimerHistory.append(entry)
    if library.sleepTimerHistory.count > 100 {
      library.sleepTimerHistory.removeFirst(library.sleepTimerHistory.count - 100)
    }
  }

  private func scheduleSleepTimerMonitor() {
    sleepTimerMonitorTask?.cancel()
    sleepTimerMonitorTask = nil
    guard library.activeSleepTimer != nil else { return }
    sleepTimerMonitorTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let self, self.library.activeSleepTimer != nil else { break }
        await self.evaluateSleepTimer()
      }
    }
  }

  private func dismissResumeRewindNoticeIfNeeded(at position: Double) async {
    guard let transaction = pendingResumeRewind,
      position >= transaction.plan.targetSeconds + 5,
      let index = library.resumeRewindTransactions.firstIndex(where: {
        $0.id == transaction.id && $0.status == .applied
      })
    else { return }
    let previousLibrary = library
    library.resumeRewindTransactions[index].status = .dismissed
    library.resumeRewindTransactions[index].dismissedAt = environment.clock.now()
    do {
      try await persist()
    } catch {
      library = previousLibrary
      present(error, in: .smartRewind)
    }
  }

  private func load(book: Book, at bookSeconds: Double) async throws {
    guard let location = PlaybackTimeline.location(in: book, at: bookSeconds) else {
      throw TransportPreferencesError.missingPlaybackTimeline(book.id)
    }
    let url = try await environment.media.managedURL(for: location.asset.managedRelativePath)
    try await environment.playback.load(
      url: url,
      bookID: book.id,
      at: location.assetSeconds
    )
    loadedAssetID = location.asset.id
    loadedAssetTimelineStartSeconds = location.asset.timelineStartSeconds
    playbackState = environment.playback.state
    playbackState.elapsedSeconds = location.bookSeconds
  }

  @discardableResult
  private func applySmartRewind(_ plan: SmartRewindPlan) async -> Bool {
    guard playbackState.loadedBookID == plan.bookID else { return false }
    guard let preRewindEvent = await recordAcknowledgedPlaybackPosition(
      plan.originalSeconds,
      reason: .preResumeRewind
    ) else { return false }
    guard await seekToBookPosition(
      plan.targetSeconds,
      reason: .resumeRewind,
      resumeRewindPlan: plan,
      preRewindEventID: preRewindEvent.id
    ) != nil else {
      if let book = library.books.first(where: { $0.id == plan.bookID }) {
        try? await load(book: book, at: plan.originalSeconds)
        applyCurrentTransportConfiguration(for: plan.bookID)
      }
      return false
    }
    return true
  }

  @discardableResult
  private func seekToBookPosition(
    _ requestedSeconds: Double,
    reason: PositionEventReason = .seek,
    resumeRewindPlan: SmartRewindPlan? = nil,
    preRewindEventID: UUID? = nil
  ) async -> PositionEvent? {
    guard let book = currentBook,
      let location = PlaybackTimeline.location(in: book, at: requestedSeconds)
    else { return nil }
    let wasPlaying = playbackState.status == .playing
    do {
      if loadedAssetID == location.asset.id,
        environment.playback.state.loadedBookID == book.id
      {
        await environment.playback.seek(to: location.assetSeconds)
        playbackState = environment.playback.state
        playbackState.elapsedSeconds = location.bookSeconds
      } else {
        try await load(book: book, at: location.bookSeconds)
        applyCurrentTransportConfiguration(for: book.id)
        if wasPlaying { environment.playback.play() }
        playbackState = environment.playback.state
        playbackState.elapsedSeconds = location.bookSeconds
      }
      return await recordAcknowledgedPlaybackPosition(
        location.bookSeconds,
        reason: reason,
        resumeRewindPlan: resumeRewindPlan,
        preRewindEventID: preRewindEventID
      )
    } catch {
      present(error, in: .playback)
      return nil
    }
  }

  private func applyCurrentTransportConfiguration(for explicitBookID: UUID? = nil) {
    let preferences = explicitBookID.map(transportPreferences(for:))
      ?? currentTransportPreferences
    environment.playback.setPlaybackRate(preferences.playbackRate)
    environment.remoteCommands.updateTransportConfiguration(preferences)
    publishNowPlaying()
  }

  /// Records a position only after the playback boundary acknowledges that the
  /// listener reached it. Periodic observers, background handlers, and audio
  /// interruption handlers all use this entry point.
  func acknowledgePlaybackPosition(
    _ seconds: Double,
    reason: PositionEventReason = .periodic
  ) async {
    _ = await recordAcknowledgedPlaybackPosition(seconds, reason: reason)
  }

  private func recordAcknowledgedPlaybackPosition(
    _ seconds: Double,
    reason: PositionEventReason,
    marksFinished: Bool = false,
    resumeRewindPlan: SmartRewindPlan? = nil,
    preRewindEventID: UUID? = nil,
    consumedSleepHistoryID: UUID? = nil
  ) async -> PositionEvent? {
    guard
      seconds.isFinite,
      let bookID = playbackState.loadedBookID ?? library.currentBookID,
      let book = library.books.first(where: { $0.id == bookID })
    else { return nil }

    let previousLibrary = library
    let maximumMilliseconds = Int64((book.durationSeconds * 1_000).rounded(.down))
    let acknowledgedMilliseconds = Int64((max(0, seconds) * 1_000).rounded(.down))
    let safeMilliseconds = min(acknowledgedMilliseconds, maximumMilliseconds)
    let eventID = await environment.ids.next()
    let nextSequence = (library.positionJournal.map(\.sequence).max() ?? 0) + 1
    let event = PositionEvent.acknowledged(
      id: eventID,
      bookID: bookID,
      positionMilliseconds: safeMilliseconds,
      sequence: nextSequence,
      reason: reason,
      acknowledgedAt: environment.clock.now(),
      previousEventID: library.playbackPosition?.sourceEventID
    )
    let position = PlaybackPosition(
      bookID: bookID,
      positionMilliseconds: safeMilliseconds,
      sequence: nextSequence,
      sourceEventID: eventID,
      updatedAt: event.acknowledgedAt
    )

    library.positionJournal.append(event)
    library.playbackPosition = position
    library.currentBookID = bookID
    if let bookIndex = library.books.firstIndex(where: { $0.id == bookID }) {
      if marksFinished || library.books[bookIndex].listeningState.status == .finished {
        library.books[bookIndex].listeningState.status = .finished
        library.books[bookIndex].listeningState.positionMilliseconds = maximumMilliseconds
        library.books[bookIndex].listeningState.finishedAt = marksFinished
          ? event.acknowledgedAt : library.books[bookIndex].listeningState.finishedAt
        if marksFinished { library.upNextBookIDs.removeAll { $0 == bookID } }
      } else {
        library.books[bookIndex].listeningState.status = safeMilliseconds > 0
          ? .inProgress : .unplayed
        library.books[bookIndex].listeningState.positionMilliseconds = safeMilliseconds
        library.books[bookIndex].listeningState.finishedAt = nil
      }
      library.books[bookIndex].listeningState.lastListenedAt = event.acknowledgedAt
    }
    playbackState.loadedBookID = bookID
    playbackState.elapsedSeconds = position.seconds
    if let resumeRewindPlan, let preRewindEventID {
      let transactionID = await environment.ids.next()
      for index in library.resumeRewindTransactions.indices where
        library.resumeRewindTransactions[index].bookID == resumeRewindPlan.bookID
          && library.resumeRewindTransactions[index].status == .applied
      {
        library.resumeRewindTransactions[index].status = .superseded
      }
      library.resumeRewindTransactions.append(ResumeRewindTransaction(
        id: transactionID,
        plan: resumeRewindPlan,
        preRewindEventID: preRewindEventID,
        rewindEventID: event.id,
        status: .applied,
        undoneAt: nil,
        undoEventID: nil
      ))
    }
    if let consumedSleepHistoryID,
      let historyIndex = library.sleepTimerHistory.firstIndex(where: {
        $0.id == consumedSleepHistoryID
          && $0.status == .completed
          && $0.resumeContextUsedAt == nil
      })
    {
      library.sleepTimerHistory[historyIndex].resumeContextUsedAt = event.acknowledgedAt
    }
    do {
      try await persist()
      publishNowPlaying()
      return event
    } catch {
      library = previousLibrary
      present(error, in: .playback)
      return nil
    }
  }

  private func recordSleepTimerStop(
    _ seconds: Double,
    timer: ActiveSleepTimer
  ) async -> PositionEvent? {
    guard seconds.isFinite,
      let book = library.books.first(where: { $0.id == timer.bookID })
    else { return nil }

    let previousLibrary = library
    let maximumMilliseconds = Int64((book.durationSeconds * 1_000).rounded(.down))
    let acknowledgedMilliseconds = Int64((max(0, seconds) * 1_000).rounded(.down))
    let safeMilliseconds = min(acknowledgedMilliseconds, maximumMilliseconds)
    let eventID = await environment.ids.next()
    let historyID = await environment.ids.next()
    let nextSequence = (library.positionJournal.map(\.sequence).max() ?? 0) + 1
    let acknowledgedAt = environment.clock.now()
    let event = PositionEvent.acknowledged(
      id: eventID,
      bookID: book.id,
      positionMilliseconds: safeMilliseconds,
      sequence: nextSequence,
      reason: .sleepTimer,
      acknowledgedAt: acknowledgedAt,
      previousEventID: library.playbackPosition?.sourceEventID
    )
    let position = PlaybackPosition(
      bookID: book.id,
      positionMilliseconds: safeMilliseconds,
      sequence: nextSequence,
      sourceEventID: event.id,
      updatedAt: acknowledgedAt
    )

    library.positionJournal.append(event)
    library.playbackPosition = position
    library.currentBookID = book.id
    if let bookIndex = library.books.firstIndex(where: { $0.id == book.id }) {
      if library.books[bookIndex].listeningState.status == .finished {
        library.books[bookIndex].listeningState.positionMilliseconds = maximumMilliseconds
      } else {
        library.books[bookIndex].listeningState.status = safeMilliseconds > 0
          ? .inProgress : .unplayed
        library.books[bookIndex].listeningState.positionMilliseconds = safeMilliseconds
        library.books[bookIndex].listeningState.finishedAt = nil
      }
      library.books[bookIndex].listeningState.lastListenedAt = acknowledgedAt
    }
    appendSleepHistory(SleepTimerHistoryEntry(
      id: historyID,
      timerID: timer.id,
      bookID: timer.bookID,
      selection: timer.selection,
      fadeEnabled: timer.fadeEnabled,
      startedAt: timer.startedAt,
      expectedDeadline: timer.deadline,
      expectedBoundaryPositionMilliseconds: timer.boundaryPositionMilliseconds,
      actualStopPositionMilliseconds: safeMilliseconds,
      completedAt: acknowledgedAt,
      status: .completed,
      positionEventID: event.id,
      resumeContextUsedAt: nil
    ))
    library.activeSleepTimer = nil
    playbackState.loadedBookID = book.id
    playbackState.elapsedSeconds = position.seconds
    do {
      try await persist()
      publishNowPlaying()
      return event
    } catch {
      library = previousLibrary
      present(error, in: .sleepTimer, owner: .root)
      return nil
    }
  }

  private func publishNowPlaying() {
    guard
      let bookID = playbackState.loadedBookID ?? library.currentBookID,
      let book = library.books.first(where: { $0.id == bookID })
    else {
      environment.nowPlaying.clear()
      return
    }
    let elapsed = min(max(0, playbackState.elapsedSeconds), book.durationSeconds)
    let chapter = book.chapters
      .filter { $0.startSeconds <= elapsed }
      .max(by: { $0.startSeconds < $1.startSeconds })
    let chapterIndex = chapter.flatMap { current in
      book.chapters.firstIndex(where: { $0.id == current.id })
    }
    let configuredRate = transportPreferences(for: book.id).playbackRate
    environment.nowPlaying.publish(
      NowPlayingSnapshot(
        bookID: book.id,
        title: book.title,
        authors: book.authors,
        narrators: book.narrators,
        seriesName: book.seriesName,
        chapterTitle: chapter?.title,
        chapterIndex: chapterIndex,
        chapterCount: book.chapters.count,
        durationSeconds: book.durationSeconds,
        elapsedSeconds: elapsed,
        playbackRate: playbackState.status == .playing
          ? configuredRate : 0,
        defaultPlaybackRate: configuredRate,
        artworkData: book.renderedArtworkData
      )
    )
  }

  private func executeQueuedImport(jobID: UUID, initialURLs: [URL]?) async {
    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await self.runQueuedImport(jobID: jobID, initialURLs: initialURLs)
    }
    importTasks[jobID] = task
    await task.value
    importTasks.removeValue(forKey: jobID)
  }

  private func runQueuedImport(jobID: UUID, initialURLs: [URL]?) async {
    guard var job = library.importJobs.first(where: { $0.id == jobID }),
      var checkpoint = job.queueCheckpoint
    else { return }
    do {
      if !checkpoint.acquisitionComplete {
        // Acquisition is restartable. If a process stopped between filesystem
        // copies and the durable completion checkpoint, remove only that job's
        // staging and reacquire from its security-scoped source bookmarks.
        if initialURLs == nil || !checkpoint.acquired.isEmpty {
          await environment.media.discardStaging(for: jobID)
          checkpoint.acquired = []
          checkpoint.inspected = []
        }
        job.phase = .acquiring
        job.failure = nil
        job.queueCheckpoint = checkpoint
        try await replaceAndPersist(job)
        let urls: [URL]
        if let initialURLs {
          urls = initialURLs
        } else {
          urls = try await environment.media.resolveImportSources(checkpoint.sources)
        }
        let acquired = try await environment.media.acquireSelection(urls, jobID: jobID)
        checkpoint.acquired = acquired
        checkpoint.acquisitionComplete = true
        job.queueCheckpoint = checkpoint
        job.stagedRelativePath = acquired.first?.staged.relativePath
        let acquiredBytes = acquired.reduce(Int64(0)) { $0 + $1.staged.byteCount }
        job.progress = ImportProgress(completed: acquiredBytes, total: acquiredBytes)
        job.phase = .inspecting
        try await replaceAndPersist(job)
      }

      guard var current = library.importJobs.first(where: { $0.id == jobID }),
        var currentCheckpoint = current.queueCheckpoint
      else { return }
      current.phase = .inspecting
      current.failure = nil
      try await replaceAndPersist(current)

      let priorStatusesByPath = Dictionary(
        uniqueKeysWithValues: (current.recoveryPlan?.files ?? []).map {
          ($0.file.relativePath, $0)
        }
      )
      var failedAssessmentsByPath = Dictionary(
        uniqueKeysWithValues: priorStatusesByPath.compactMap { path, status in
          status.disposition == .failed && status.file.validity != .valid
            ? (path, status.file) : nil
        }
      )
      for (selectionIndex, item) in currentCheckpoint.acquired.enumerated() {
        try Task.checkCancellation()
        let path = item.staged.relativePath
        if currentCheckpoint.inspected.contains(where: {
          $0.acquired.staged.relativePath == path
        }) { continue }
        if failedAssessmentsByPath[path] != nil { continue }

        do {
          let stagedURL = try await environment.media.stagedURL(for: path)
          let inspected = try await environment.inspector.inspect(url: stagedURL)
          let assetID = await environment.ids.next()
          let asset = AudioAsset(
            id: assetID,
            originalFilename: item.staged.originalFilename,
            managedRelativePath: "",
            checksumSHA256: item.staged.checksumSHA256,
            byteCount: item.staged.byteCount,
            durationSeconds: inspected.durationSeconds,
            container: inspected.container,
            discNumber: inspected.discNumber,
            trackNumber: inspected.trackNumber,
            importOrder: selectionIndex
          )
          currentCheckpoint.inspected.append(
            InspectedImportAsset(asset: asset, inspected: inspected, acquired: item)
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          let assessment = failedImportAssessment(
            jobID: jobID,
            item: item,
            preferredID: priorStatusesByPath[path]?.file.id,
            error: error
          )
          failedAssessmentsByPath[path] = assessment
        }
        guard var progressed = library.importJobs.first(where: { $0.id == jobID }) else { return }
        progressed.queueCheckpoint = currentCheckpoint
        let assessedPaths = Set(
          currentCheckpoint.inspected.map { $0.acquired.staged.relativePath }
            + Array(failedAssessmentsByPath.keys)
        )
        progressed.recoveryPlan = makeImportRecoveryPlan(
          jobID: jobID,
          acquired: currentCheckpoint.acquired.filter {
            assessedPaths.contains($0.staged.relativePath)
          },
          inspected: currentCheckpoint.inspected,
          failedAssessments: failedAssessmentsByPath,
          priorStatusesByPath: priorStatusesByPath
        )
        try await replaceAndPersist(progressed)
      }

      let plan = makeImportRecoveryPlan(
        jobID: jobID,
        acquired: currentCheckpoint.acquired,
        inspected: currentCheckpoint.inspected,
        failedAssessments: failedAssessmentsByPath,
        priorStatusesByPath: priorStatusesByPath
      )
      let acceptedPaths = Set(plan.files.compactMap {
        $0.disposition == .accepted ? $0.file.relativePath : nil
      })
      let accepted = currentCheckpoint.inspected.filter {
        acceptedPaths.contains($0.acquired.staged.relativePath)
      }
      let review: (stagedAssets: [StagedImportAsset], proposals: [BookProposal])
      if accepted.isEmpty {
        review = ([], [])
      } else {
        review = try await buildImportReview(from: accepted)
      }
      guard var completed = library.importJobs.first(where: { $0.id == jobID }) else { return }
      completed.queueCheckpoint = currentCheckpoint
      completed.recoveryPlan = plan
      completed.stagedAssets = review.stagedAssets
      completed.proposals = review.proposals
      switch plan.phase {
      case .ready:
        completed.phase = review.proposals.contains(where: { !$0.warnings.isEmpty })
          ? .needsReview : .ready
        completed.failure = nil
      case .needsReview:
        completed.phase = .needsReview
        completed.failure = nil
      case .failedRecoverable, .failedTerminal:
        completed.phase = .failed
        completed.failure = importFailure(from: plan, fallbackFilename: completed.sourceFilename)
      }
      try await replaceAndPersist(completed)
    } catch is CancellationError {
      guard var interrupted = library.importJobs.first(where: { $0.id == jobID }) else { return }
      // A user-requested cancellation has already persisted its terminal state.
      // Any other cancellation is a failure worth retaining rather than being
      // silently rewritten as though the listener deliberately cancelled it.
      guard interrupted.phase != .cancelled else { return }
      interrupted.phase = .failed
      interrupted.failure = ImportFailure(
        message: "Bookshelf's import task stopped unexpectedly. Try sending the audiobook again.",
        affectedFilename: interrupted.sourceFilename,
        sourceIsUnchanged: true,
        isRecoverable: false,
        reasonCode: "unexpected-task-cancellation",
        recoveryAction: .changeSelection
      )
      try? await replaceAndPersist(interrupted)
      logger.error("Import task \(jobID.uuidString, privacy: .public) was cancelled unexpectedly")
    } catch {
      guard var failed = library.importJobs.first(where: { $0.id == jobID }) else { return }
      if let coreError = error as? PlayerCoreError,
        case let .insufficientStorage(required, available) = coreError
      {
        let plan = ImportRecoveryPlanner.assess(
          files: failed.recoveryPlan?.files.map(\.file) ?? [],
          existing: existingMediaFingerprints,
          storage: ImportStoragePreflight(
            requiredCopyBytes: required,
            availableBytes: available,
            safetyMarginBytes: 0
          )
        )
        failed.recoveryPlan = plan
        failed.phase = .failed
        failed.failure = importFailure(from: plan, fallbackFilename: failed.sourceFilename)
        try? await replaceAndPersist(failed)
        return
      }
      failed.phase = .failed
      failed.failure = ImportFailure(
        message: error.localizedDescription,
        affectedFilename: failed.sourceFilename,
        sourceIsUnchanged: true,
        isRecoverable: true,
        reasonCode: failed.queueCheckpoint?.acquisitionComplete == true
          ? "inspection-transient" : "acquisition-transient",
        recoveryAction: .retry
      )
      try? await replaceAndPersist(failed)
    }
  }

  private var existingMediaFingerprints: [ExistingMediaFingerprint] {
    library.books.flatMap { book in
      book.assets.map {
        ExistingMediaFingerprint(
          checksumSHA256: $0.checksumSHA256,
          bookID: book.id,
          assetID: $0.id,
          filename: $0.originalFilename
        )
      }
    }
  }

  private func makeImportRecoveryPlan(
    jobID: UUID,
    acquired: [AcquiredAudioFile],
    inspected: [InspectedImportAsset],
    failedAssessments: [String: ImportFileAssessment],
    priorStatusesByPath: [String: ImportFileRecoveryStatus]
  ) -> ImportRecoveryPlan {
    let inspectedByPath = Dictionary(
      uniqueKeysWithValues: inspected.map { ($0.acquired.staged.relativePath, $0) }
    )
    let files = acquired.map { item -> ImportFileAssessment in
      let path = item.staged.relativePath
      if let item = inspectedByPath[path] {
        return ImportFileAssessment(
          id: priorStatusesByPath[path]?.file.id ?? item.asset.id,
          relativePath: path,
          filename: item.asset.originalFilename,
          byteCount: item.asset.byteCount,
          checksumSHA256: item.asset.checksumSHA256,
          format: item.asset.container,
          validity: .valid
        )
      }
      if let failure = failedAssessments[path] { return failure }
      if let prior = priorStatusesByPath[path] { return prior.file }
      return ImportFileAssessment(
        id: ImportRecoveryPlanner.stableFileID(namespace: jobID, relativePath: path),
        relativePath: path,
        filename: item.staged.originalFilename,
        byteCount: item.staged.byteCount,
        checksumSHA256: item.staged.checksumSHA256,
        format: URL(filePath: item.staged.originalFilename).pathExtension.uppercased(),
        validity: .missing
      )
    }
    return ImportRecoveryPlanner.assess(
      files: files,
      existing: existingMediaFingerprints
    )
  }

  private func failedImportAssessment(
    jobID: UUID,
    item: AcquiredAudioFile,
    preferredID: UUID?,
    error: any Error
  ) -> ImportFileAssessment {
    let validity: ImportFileValidity
    if let coreError = error as? PlayerCoreError {
      switch coreError {
      case .unsupportedFile:
        validity = .unsupported(
          format: URL(filePath: item.staged.originalFilename).pathExtension.uppercased()
        )
      case .sourceIsNotAFile, .missingManagedFile:
        validity = .missing
      case .unreadableAudio:
        validity = .corrupt(details: nil)
      default:
        validity = .corrupt(details: coreError.localizedDescription)
      }
    } else if (error as NSError).code == NSFileNoSuchFileError {
      validity = .missing
    } else {
      validity = .corrupt(details: error.localizedDescription)
    }
    return ImportFileAssessment(
      id: preferredID
        ?? ImportRecoveryPlanner.stableFileID(
          namespace: jobID,
          relativePath: item.staged.relativePath
        ),
      relativePath: item.staged.relativePath,
      filename: item.staged.originalFilename,
      byteCount: item.staged.byteCount,
      checksumSHA256: item.staged.checksumSHA256,
      format: URL(filePath: item.staged.originalFilename).pathExtension.uppercased(),
      validity: validity
    )
  }

  private func importFailure(
    from plan: ImportRecoveryPlan,
    fallbackFilename: String
  ) -> ImportFailure {
    let issue = plan.globalIssues.first ?? plan.files.compactMap(\.issue).first
    let recoverable = plan.phase == .failedRecoverable
    return ImportFailure(
      message: issue?.message ?? "No usable audiobook files remain in this import.",
      affectedFilename: issue?.affectedFilename ?? fallbackFilename,
      sourceIsUnchanged: true,
      isRecoverable: recoverable,
      reasonCode: issue?.code.rawValue,
      recoveryAction: recoverable ? .retry : .changeSelection
    )
  }

  private func importZipArchive(
    from sourceURL: URL,
    checkpoint: ImportQueueCheckpoint? = nil
  ) async -> UUID {
    let jobID = await environment.ids.next()
    let now = environment.clock.now()
    let job = ImportJob(
      id: jobID,
      sourceFilename: sourceURL.lastPathComponent,
      phase: .queued,
      progress: .none,
      createdAt: now,
      updatedAt: now,
      queueCheckpoint: checkpoint
    )
    library.importJobs.append(job)
    do { try await persist() }
    catch { present(error, in: .importFlow) }
    await executeZipImport(jobID: jobID, sourceURL: sourceURL)
    return jobID
  }

  private func executeZipImport(jobID: UUID, sourceURL: URL?) async {
    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await self.runZipImport(jobID: jobID, sourceURL: sourceURL)
    }
    importTasks[jobID] = task
    await task.value
    importTasks.removeValue(forKey: jobID)
  }

  private func runZipImport(jobID: UUID, sourceURL: URL?) async {
    guard var job = library.importJobs.first(where: { $0.id == jobID }) else { return }
    do {
      let workspace = try await environment.media.zipWorkspace(for: jobID)
      let archive: StagedAudio
      if let status = job.zipStatus {
        archive = StagedAudio(
          relativePath: status.archiveStagedRelativePath,
          originalFilename: job.sourceFilename,
          checksumSHA256: "",
          byteCount: 0
        )
      } else {
        guard let sourceURL else { throw PlayerCoreError.invalidAssetSelection }
        job.phase = .acquiring
        job.failure = nil
        try await replaceAndPersist(job)
        archive = try await environment.media.stageArchive(sourceURL: sourceURL, jobID: jobID)
        job.zipStatus = ZipImportStatus(
          archiveStagedRelativePath: archive.relativePath,
          extractionRelativePath: workspace.extractionRelativePath,
          checkpointRelativePath: workspace.checkpointRelativePath,
          totalEntryCount: 0,
          extractedEntryCount: 0,
          failureReasonCode: nil,
          retryAllowed: false
        )
      }

      job.phase = .extracting
      job.failure = nil
      job.proposals = []
      job.stagedAssets = []
      try await replaceAndPersist(job)
      let archiveURL = try await environment.media.stagedURL(for: archive.relativePath)
      let result = try await environment.zipExtractor.extract(
        archiveURL: archiveURL,
        destinationRoot: workspace.destinationRoot,
        checkpointURL: workspace.checkpointURL
      ) { [weak self] progress in
        await self?.recordZipProgress(jobID: jobID, progress: progress)
      }

      guard var current = library.importJobs.first(where: { $0.id == jobID }) else { return }
      if var status = current.zipStatus {
        status.totalEntryCount = result.checkpoint.totalEntries
        status.extractedEntryCount = result.files.count
        status.failureReasonCode = nil
        status.retryAllowed = false
        current.zipStatus = status
      }
      current.phase = .inspecting
      try await replaceAndPersist(current)
      let acquired = try await environment.media.acquireExtractedAudio(
        result.files,
        in: workspace,
        jobID: jobID
      )
      let review = try await buildImportReview(from: acquired)
      guard var completed = library.importJobs.first(where: { $0.id == jobID }) else { return }
      completed.stagedRelativePath = acquired.first?.staged.relativePath
      completed.stagedAssets = review.stagedAssets
      completed.proposals = review.proposals
      completed.recoveryPlan = nil
      completed.progress = ImportProgress(
        completed: Int64(clamping: result.checkpoint.extractedBytes),
        total: Int64(clamping: result.checkpoint.totalBytes)
      )
      completed.phase = review.proposals.contains(where: { !$0.warnings.isEmpty })
        ? .needsReview : .ready
      completed.failure = nil
      try await replaceAndPersist(completed)
    } catch is CancellationError {
      await cancelImport(jobID: jobID)
    } catch {
      guard var failed = library.importJobs.first(where: { $0.id == jobID }) else { return }
      let workspace = try? await environment.media.zipWorkspace(for: jobID)
      let checkpoint = workspace.flatMap {
        try? JSONDecoder().decode(
          ZipExtractionCheckpoint.self,
          from: Data(contentsOf: $0.checkpointURL)
        )
      }
      let zipError = error as? ZipImportError
      let reason = zipError?.reasonCode ?? "inspection-transient"
      let canRetry = zipError == nil || zipError?.isRecoverable == true
      if var status = failed.zipStatus {
        status.totalEntryCount = checkpoint?.totalEntries ?? status.totalEntryCount
        status.extractedEntryCount = checkpoint?.completedEntries.count ?? status.extractedEntryCount
        status.failureReasonCode = reason
        status.retryAllowed = canRetry
        failed.zipStatus = status
      }
      failed.phase = .failed
      failed.failure = ImportFailure(
        message: error.localizedDescription,
        affectedFilename: zipError?.affectedPath,
        sourceIsUnchanged: true,
        isRecoverable: canRetry,
        reasonCode: reason,
        recoveryAction: canRetry ? .retry : .changeSelection
      )
      try? await replaceAndPersist(failed)
    }
  }

  private func recordZipProgress(jobID: UUID, progress: ZipExtractionProgress) async {
    guard var job = library.importJobs.first(where: { $0.id == jobID }) else { return }
    job.progress = ImportProgress(
      completed: Int64(clamping: progress.extractedBytes),
      total: Int64(clamping: progress.totalBytes)
    )
    if var status = job.zipStatus {
      status.extractedEntryCount = progress.completedEntries
      job.zipStatus = status
    }
    try? await replaceAndPersist(job)
  }

  private func buildImportReview(
    from acquired: [AcquiredAudioFile]
  ) async throws -> (stagedAssets: [StagedImportAsset], proposals: [BookProposal]) {
    var inspectedAssets: [InspectedImportAsset] = []
    for (selectionIndex, item) in acquired.enumerated() {
      let url = try await environment.media.stagedURL(for: item.staged.relativePath)
      let inspected = try await environment.inspector.inspect(url: url)
      let assetID = await environment.ids.next()
      inspectedAssets.append(InspectedImportAsset(
        asset: AudioAsset(
          id: assetID,
          originalFilename: item.staged.originalFilename,
          managedRelativePath: "",
          checksumSHA256: item.staged.checksumSHA256,
          byteCount: item.staged.byteCount,
          durationSeconds: inspected.durationSeconds,
          container: inspected.container,
          discNumber: inspected.discNumber,
          trackNumber: inspected.trackNumber,
          importOrder: selectionIndex
        ),
        inspected: inspected,
        acquired: item
      ))
    }
    return try await buildImportReview(from: inspectedAssets)
  }

  private func buildImportReview(
    from inspected: [InspectedImportAsset]
  ) async throws -> (stagedAssets: [StagedImportAsset], proposals: [BookProposal]) {
    let prepared = inspected.map {
      PreparedImportAsset(asset: $0.asset, inspected: $0.inspected, acquired: $0.acquired)
    }
    var proposals: [BookProposal] = []
    let groups = groupedImportAssets(prepared)
    for group in groups {
      let ordered = NaturalTrackOrdering.order(group.map(\.asset))
      let byID = Dictionary(uniqueKeysWithValues: group.map { ($0.asset.id, $0) })
      var assets: [AudioAsset] = []
      var chapters: [Chapter] = []
      var start = 0.0
      for var asset in ordered.assets {
        guard let item = byID[asset.id] else { continue }
        asset.timelineStartSeconds = start
        assets.append(asset)
        chapters += item.inspected.chapters.map {
          Chapter(
            id: "\(asset.id.uuidString.lowercased())-\($0.id)",
            title: $0.title,
            startSeconds: $0.startSeconds + start,
            durationSeconds: $0.durationSeconds,
            source: $0.source,
            assetID: asset.id
          )
        }
        start += asset.durationSeconds
      }
      guard let first = assets.first else { throw PlayerCoreError.invalidAssetSelection }
      let proposalID = await environment.ids.next()
      let bookID = await environment.ids.next()
      let commonFolder = commonNonBlank(group.compactMap(\.acquired.commonFolderName))
      let commonAlbumTitle = commonNonBlank(group.compactMap(\.inspected.albumTitle))
      let commonTitle = commonNonBlank(group.compactMap(\.inspected.title))
      proposals.append(BookProposal(
        id: proposalID,
        proposedBookID: bookID,
        title: commonAlbumTitle ?? commonTitle ?? commonFolder
          ?? filenameStem(for: first.originalFilename).display,
        authors: uniqueContributors(group.flatMap(\.inspected.authors)),
        durationSeconds: start,
        artworkData: group.compactMap(\.inspected.artworkData).first,
        asset: first,
        warnings: (groups.count > 1 ? ["Confirm that this selection is one audiobook."] : [])
          + ordered.warnings,
        narrators: uniqueContributors(group.flatMap(\.inspected.narrators)),
        seriesName: group.compactMap(\.inspected.seriesName).first,
        seriesPosition: group.compactMap(\.inspected.seriesPosition).first,
        artworkMediaType: group.compactMap(\.inspected.artworkMediaType).first,
        chapters: chapters.sorted { $0.startSeconds < $1.startSeconds },
        additionalAssets: Array(assets.dropFirst()),
        groupingEvidence: groupingEvidence(for: group),
        orderingEvidence: ordered.evidence
      ))
    }
    return (
      prepared.map {
        StagedImportAsset(
          assetID: $0.asset.id,
          stagedRelativePath: $0.acquired.staged.relativePath,
          sourceRelativePath: $0.acquired.sourceRelativePath
        )
      },
      proposals
    )
  }

  private func replaceAndPersist(_ job: ImportJob) async throws {
    var updated = job
    updated.updatedAt = environment.clock.now()
    var candidate = library
    if let index = candidate.importJobs.firstIndex(where: { $0.id == updated.id }) {
      candidate.importJobs[index] = updated
    } else {
      candidate.importJobs.append(updated)
    }
    try await environment.persistence.save(candidate)
    library = candidate
  }

  private func missingTargetError(_ target: MetadataTarget) -> PlayerCoreError {
    switch target {
    case .book(let bookID): .missingBook(bookID)
    case .proposal(let jobID, let proposalID):
      library.importJobs.contains(where: { $0.id == jobID })
        ? .missingProposal(proposalID) : .missingImport(jobID)
    }
  }

  private func replaceMetadata(
    _ metadata: AudiobookMetadata,
    for target: MetadataTarget,
    proposalRevisionIncrement: Int = 1
  ) throws {
    switch target {
    case .book(let bookID):
      guard let index = library.books.firstIndex(where: { $0.id == bookID }) else {
        throw PlayerCoreError.missingBook(bookID)
      }
      library.books[index].replaceMetadata(with: metadata)
    case .proposal(let jobID, let proposalID):
      guard let jobIndex = library.importJobs.firstIndex(where: { $0.id == jobID }) else {
        throw PlayerCoreError.missingImport(jobID)
      }
      guard library.importJobs[jobIndex].phase == .ready
        || library.importJobs[jobIndex].phase == .needsReview
      else { throw PlayerCoreError.importNotReady(jobID) }
      var proposals = library.importJobs[jobIndex].proposals
      guard let proposalIndex = proposals.firstIndex(where: { $0.id == proposalID }) else {
        throw PlayerCoreError.missingProposal(proposalID)
      }
      proposals[proposalIndex].replaceMetadata(with: metadata)
      library.importJobs[jobIndex].proposals = proposals
      library.importJobs[jobIndex].reviewRevision += max(0, proposalRevisionIncrement)
      library.importJobs[jobIndex].updatedAt = environment.clock.now()
    }
  }

  private func reviseImport(
    jobID: UUID,
    mutation: (inout ImportJob) throws -> Void
  ) async -> Bool {
    guard var job = library.importJobs.first(where: { $0.id == jobID }) else {
      present(
        PlayerCoreError.missingImport(jobID),
        in: .importFlow,
        recoveryAction: .acknowledge
      )
      return false
    }
    guard job.phase == .ready || job.phase == .needsReview else {
      present(
        PlayerCoreError.importNotReady(jobID),
        in: .importFlow,
        recoveryAction: .acknowledge
      )
      return false
    }
    let previousLibrary = library
    do {
      try mutation(&job)
      job.reviewRevision += 1
      job.phase = job.proposals.contains(where: { !$0.warnings.isEmpty }) ? .needsReview : .ready
      try await replaceAndPersist(job)
      return true
    } catch {
      library = previousLibrary
      present(error, in: .importFlow)
      return false
    }
  }

  private func replace(_ job: ImportJob) {
    if let index = library.importJobs.firstIndex(where: { $0.id == job.id }) {
      library.importJobs[index] = job
    } else {
      library.importJobs.append(job)
    }
  }

  private func persist() async throws {
    try await environment.persistence.save(library)
  }

  private func applyLibraryOrganizationMutation(
    in domain: PlayerErrorDomain = .library,
    owner: PlayerErrorPresentationOwner? = nil,
    _ mutation: (inout LibrarySnapshot) throws -> Void
  ) async -> Bool {
    var candidate = library
    do {
      try mutation(&candidate)
      try await environment.persistence.save(candidate)
      library = candidate
      return true
    } catch {
      present(error, in: domain, owner: owner)
      return false
    }
  }
}

private func validReorder(_ proposed: [UUID], replacing existing: [UUID]) -> Bool {
  proposed.count == Set(proposed).count
    && proposed.count == existing.count
    && Set(proposed) == Set(existing)
}

private func validateCollectionName(
  _ name: String,
  excluding collectionID: UUID?,
  in library: LibrarySnapshot
) throws {
  guard !name.isEmpty else { throw LibraryOrganizationError.invalidCollectionName }
  guard !library.collections.contains(where: {
    $0.id != collectionID && $0.name.caseInsensitiveCompare(name) == .orderedSame
  }) else {
    throw LibraryOrganizationError.duplicateCollectionName(name)
  }
}

private struct PreparedImportAsset {
  var asset: AudioAsset
  var inspected: InspectedAudio
  var acquired: AcquiredAudioFile
}

private enum ImportGroupingKey: Hashable {
  case folder(String)
  case filenameStem(String)
}

private func groupedImportAssets(_ prepared: [PreparedImportAsset]) -> [[PreparedImportAsset]] {
  var keys: [ImportGroupingKey] = []
  var groups: [ImportGroupingKey: [PreparedImportAsset]] = [:]
  for item in prepared {
    let key: ImportGroupingKey
    if let folder = item.acquired.commonFolderName?.nilIfBlank {
      key = .folder(folder.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    } else {
      key = .filenameStem(filenameStem(for: item.asset.originalFilename).key)
    }
    if groups[key] == nil { keys.append(key) }
    groups[key, default: []].append(item)
  }
  return keys.compactMap { groups[$0] }
}

private func filenameStem(for filename: String) -> (key: String, display: String) {
  let base = URL(filePath: filename).deletingPathExtension().lastPathComponent
  let prefix = base.prefix { !$0.isNumber }
  let trimmed = String(prefix).trimmingCharacters(
    in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
  )
  let display = trimmed.nilIfBlank ?? base
  let key = display.folding(
    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
    locale: Locale(identifier: "en_US_POSIX")
  )
  return (key, display)
}

private func uniqueContributors(_ values: [String]) -> [String] {
  var seen: Set<String> = []
  return values.filter { seen.insert($0.folding(options: [.caseInsensitive], locale: nil)).inserted }
}

private func commonNonBlank(_ values: [String]) -> String? {
  guard let first = values.first?.nilIfBlank, values.count > 0 else { return nil }
  return values.allSatisfy { $0.caseInsensitiveCompare(first) == .orderedSame } ? first : nil
}

private func groupingEvidence(for prepared: [PreparedImportAsset]) -> [GroupingEvidence] {
  var evidence = [
    GroupingEvidence(
      kind: .selectedTogether,
      explanation: "The user selected these \(prepared.count) audio files together."
    )
  ]
  let folders = prepared.compactMap(\.acquired.commonFolderName)
  if let folder = commonNonBlank(folders), folders.count == prepared.count {
    evidence.append(
      GroupingEvidence(kind: .commonFolder, explanation: "Every track came from the folder \(folder).")
    )
  }
  if folders.isEmpty, let first = prepared.first {
    let stem = filenameStem(for: first.asset.originalFilename).display
    evidence.append(
      GroupingEvidence(kind: .filenameStem, explanation: "Every loose file shares the filename stem \(stem).")
    )
  }
  let titles = prepared.compactMap(\.inspected.title)
  if let title = commonNonBlank(titles), titles.count == prepared.count {
    evidence.append(
      GroupingEvidence(kind: .commonEmbeddedTitle, explanation: "Every track declares the title \(title).")
    )
  }
  return evidence
}

private extension String {
  var nilIfBlank: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}
