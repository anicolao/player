import Foundation
import Observation

@MainActor
@Observable
final class PlayerModel {
  private(set) var library: LibrarySnapshot = .empty
  private(set) var playbackState: PlaybackState = .unloaded
  private(set) var isRestored = false
  private(set) var lastErrorMessage: String?

  @ObservationIgnored private let environment: PlayerEnvironment
  @ObservationIgnored private var playbackIntegrationsConfigured = false
  @ObservationIgnored private var wasPlayingBeforeInterruption = false
  @ObservationIgnored private var importTasks: [UUID: Task<Void, Never>] = [:]

  init(environment: PlayerEnvironment) {
    self.environment = environment
    self.playbackState = environment.playback.state
  }

  func restore() async {
    do {
      library = try await environment.persistence.load()
      let recoveredInterruptedImports = recoverInterruptedImports()
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
      }
      if library.currentBookID != nil {
        try await loadCurrentBookIntoPlayback()
      }
      if storedPosition != recoveredPosition || recoveredInterruptedImports {
        try await persist()
      }
      isRestored = true
      lastErrorMessage = nil
      publishNowPlaying()
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
      lastErrorMessage = error.localizedDescription
      environment.nowPlaying.clear()
    }
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
    guard !playbackIntegrationsConfigured else { return }
    do {
      try environment.audioSession.configure()
      environment.audioSession.installEventHandler { [weak self] event in
        await self?.handleAudioSessionEvent(event)
      }
      environment.remoteCommands.installCommandHandler { [weak self] command in
        await self?.handleRemoteCommand(command)
      }
      playbackIntegrationsConfigured = true
      lastErrorMessage = nil
      publishNowPlaying()
    } catch {
      lastErrorMessage = error.localizedDescription
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
        lastErrorMessage = "A share request reused an identifier with different content."
        return nil
      }
      try? await queue.acknowledge(claimed.handoff.id)
      lastErrorMessage = nil
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
        lastErrorMessage = error.localizedDescription
        return nil
      }
      do {
        try await queue.acknowledge(claimed.handoff.id)
      } catch {
        // The durable receipt is the exactly-once boundary. Retain it if queue
        // cleanup fails so an immediate replay deduplicates instead of importing
        // the same payload a second time.
        try? await queue.returnForRetry(claimed.handoff.id)
        lastErrorMessage = error.localizedDescription
        return nil
      }
    } else {
      try? await queue.returnForRetry(claimed.handoff.id)
    }
    return jobID
  }

  @discardableResult
  func enqueueImport(_ request: ImportRequest) async -> UUID? {
    guard !request.selectedURLs.isEmpty else {
      lastErrorMessage = PlayerCoreError.invalidAssetSelection.localizedDescription
      return nil
    }
    do {
      let sources = try makeDurableSources(for: request)
      if request.selectedURLs.count == 1,
        request.selectedURLs[0].pathExtension.lowercased() == "zip"
      {
        return await importZipArchive(
          from: request.selectedURLs[0],
          checkpoint: ImportQueueCheckpoint(
            entryPoint: request.entryPoint,
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
          entryPoint: request.entryPoint,
          sources: sources,
          shareHandoffID: request.shareHandoffID
        )
      )
      library.importJobs.append(job)
      try await persist()
      await executeQueuedImport(jobID: jobID, initialURLs: request.selectedURLs)
      return jobID
    } catch {
      lastErrorMessage = error.localizedDescription
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
      lastErrorMessage = nil
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
      lastErrorMessage = error.localizedDescription
      return jobID
    }
  }

  /// Acquires files and folders as one reviewable import. Selection membership is
  /// the primary grouping signal; folder and embedded-title agreement are recorded
  /// as explainable supporting evidence rather than silently creating extra books.
  @discardableResult
  private func legacyImportAudioSelection(from selectedURLs: [URL]) async -> UUID? {
    guard !selectedURLs.isEmpty else {
      lastErrorMessage = PlayerCoreError.invalidAssetSelection.localizedDescription
      return nil
    }

    let archiveURLs = selectedURLs.filter { $0.pathExtension.lowercased() == "zip" }
    if !archiveURLs.isEmpty {
      guard selectedURLs.count == 1, archiveURLs.count == 1 else {
        lastErrorMessage = "Import one ZIP archive at a time."
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
        let commonTitle = commonNonBlank(group.compactMap(\.inspected.title))
        let filenameTitle = filenameStem(for: group[0].asset.originalFilename).display
        let warnings = (preparedGroups.count > 1
          ? ["Confirm that this selection is one audiobook."]
          : []) + ordered.warnings
        proposals.append(
          BookProposal(
            id: proposalID,
            proposedBookID: bookID,
            title: commonFolder ?? commonTitle ?? filenameTitle,
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
      lastErrorMessage = nil
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
      lastErrorMessage = error.localizedDescription
      return jobID
    }
  }

  @discardableResult
  func retryImport(jobID: UUID) async -> Bool {
    guard let job = library.importJobs.first(where: { $0.id == jobID }), job.phase == .failed else {
      lastErrorMessage = PlayerCoreError.missingImport(jobID).localizedDescription
      return false
    }
    if job.zipStatus?.retryAllowed == true {
      await executeZipImport(jobID: jobID, sourceURL: nil)
    } else if job.queueCheckpoint != nil, job.failure?.recoveryAction == .retry {
      await executeQueuedImport(jobID: jobID, initialURLs: nil)
    } else {
      lastErrorMessage = PlayerCoreError.importNotReady(jobID).localizedDescription
      return false
    }
    return library.importJobs.first(where: { $0.id == jobID }).map {
      $0.phase == .ready || $0.phase == .needsReview
    } ?? false
  }

  func cancelImport(jobID: UUID) async {
    guard var job = library.importJobs.first(where: { $0.id == jobID }) else { return }
    importTasks[jobID]?.cancel()
    if job.zipStatus != nil, let workspace = try? await environment.media.zipWorkspace(for: jobID) {
      try? await environment.zipExtractor.cancelAndClean(
        destinationRoot: workspace.destinationRoot,
        checkpointURL: workspace.checkpointURL
      )
    }
    await environment.media.discardStaging(for: jobID)
    job.phase = .cancelled
    job.progress = .none
    job.proposals = []
    job.stagedAssets = []
    job.failure = nil
    if var status = job.zipStatus {
      status.extractedEntryCount = 0
      status.failureReasonCode = nil
      status.retryAllowed = false
      job.zipStatus = status
    }
    try? await replaceAndPersist(job)
    lastErrorMessage = nil
  }

  @discardableResult
  func addImportToLibrary(jobID: UUID) async -> UUID? {
    guard var job = library.importJobs.first(where: { $0.id == jobID }) else {
      lastErrorMessage = PlayerCoreError.missingImport(jobID).localizedDescription
      return nil
    }
    let proposals = job.proposals
    guard
      job.phase == .ready || job.phase == .needsReview,
      !proposals.isEmpty
    else {
      lastErrorMessage = PlayerCoreError.importNotReady(jobID).localizedDescription
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
            chapters: proposal.chapters
          )
        )
      }
      // Publish only after every immutable asset move has succeeded.
      library.books.append(contentsOf: books)
      job.phase = .committed
      job.committedBookID = books.first?.id
      job.updatedAt = environment.clock.now()
      replace(job)
      try await persist()
      await environment.media.discardStaging(for: jobID)
      lastErrorMessage = nil
      return books.first?.id
    } catch {
      for item in managed.reversed() { try? await environment.media.rollback(item) }
      library = previousLibrary
      try? await environment.persistence.save(library)
      lastErrorMessage = error.localizedDescription
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

  func loadCurrentBook() async {
    do {
      try await loadCurrentBookIntoPlayback()
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func play(bookID: UUID, at seconds: Double? = nil) async {
    guard
      let book = library.books.first(where: { $0.id == bookID }),
      let asset = book.assets.first
    else {
      lastErrorMessage = PlayerCoreError.missingBook(bookID).localizedDescription
      return
    }

    do {
      try environment.audioSession.activate()
      let url = try await environment.media.managedURL(for: asset.managedRelativePath)
      let startSeconds = seconds
        ?? (library.playbackPosition?.bookID == bookID ? library.playbackPosition?.seconds : nil)
        ?? 0
      try await environment.playback.load(url: url, bookID: bookID, at: startSeconds)
      environment.playback.play()
      playbackState = environment.playback.state
      library.currentBookID = bookID
      await acknowledgePlaybackPosition(
        environment.playback.currentPositionSeconds,
        reason: .play
      )
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func seek(to seconds: Double) async {
    guard playbackState.loadedBookID != nil else { return }
    await environment.playback.seek(to: seconds)
    playbackState = environment.playback.state
    await acknowledgePlaybackPosition(
      environment.playback.currentPositionSeconds,
      reason: .seek
    )
  }

  func pause() async {
    await pause(reason: .pause)
  }

  func checkpointForBackground() async {
    guard playbackState.loadedBookID != nil, playbackState.status == .playing else { return }
    await acknowledgePlaybackPosition(
      environment.playback.currentPositionSeconds,
      reason: .background
    )
  }

  private func pausePlayback() -> Double {
    environment.playback.pause()
    playbackState = environment.playback.state
    return environment.playback.currentPositionSeconds
  }

  private func pause(reason: PositionEventReason) async {
    let seconds = pausePlayback()
    await acknowledgePlaybackPosition(seconds, reason: reason)
  }

  private func resumeCurrentBook() async {
    guard let bookID = library.currentBookID else { return }
    if environment.playback.state.loadedBookID == bookID {
      do {
        try environment.audioSession.activate()
        environment.playback.play()
        playbackState = environment.playback.state
        await acknowledgePlaybackPosition(
          environment.playback.currentPositionSeconds,
          reason: .play
        )
      } catch {
        lastErrorMessage = error.localizedDescription
      }
    } else {
      await play(bookID: bookID)
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
    case .skipForward(let seconds):
      await seek(to: environment.playback.currentPositionSeconds + max(0, seconds))
    case .skipBackward(let seconds):
      await seek(to: max(0, environment.playback.currentPositionSeconds - max(0, seconds)))
    case .changePosition(let seconds):
      await seek(to: seconds)
    }
  }

  private func handleAudioSessionEvent(_ event: AudioSessionEvent) async {
    switch event {
    case .interruptionBegan:
      wasPlayingBeforeInterruption = playbackState.status == .playing
      if wasPlayingBeforeInterruption { await pause(reason: .interruption) }
    case .interruptionEnded(let shouldResume):
      let resume = shouldResume && wasPlayingBeforeInterruption
      wasPlayingBeforeInterruption = false
      if resume { await resumeCurrentBook() }
    case .oldDeviceUnavailable:
      if playbackState.status == .playing { await pause(reason: .routeChange) }
    }
  }

  private func loadCurrentBookIntoPlayback() async throws {
    guard let bookID = library.currentBookID else { return }
    guard
      let book = library.books.first(where: { $0.id == bookID }),
      let asset = book.assets.first
    else {
      throw PlayerCoreError.missingBook(bookID)
    }
    let url = try await environment.media.managedURL(for: asset.managedRelativePath)
    let seconds = library.playbackPosition?.bookID == bookID
      ? library.playbackPosition?.seconds ?? 0
      : 0
    try await environment.playback.load(url: url, bookID: bookID, at: seconds)
    playbackState = environment.playback.state
  }

  /// Records a position only after the playback boundary acknowledges that the
  /// listener reached it. Periodic observers, background handlers, and audio
  /// interruption handlers all use this entry point.
  func acknowledgePlaybackPosition(
    _ seconds: Double,
    reason: PositionEventReason = .periodic
  ) async {
    guard
      seconds.isFinite,
      let bookID = playbackState.loadedBookID ?? library.currentBookID,
      let book = library.books.first(where: { $0.id == bookID })
    else { return }

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
    playbackState.loadedBookID = bookID
    playbackState.elapsedSeconds = position.seconds
    do {
      try await persist()
      lastErrorMessage = nil
      publishNowPlaying()
    } catch {
      library = previousLibrary
      lastErrorMessage = error.localizedDescription
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
    environment.nowPlaying.publish(
      NowPlayingSnapshot(
        bookID: book.id,
        title: book.title,
        authors: book.authors,
        narrators: book.narrators,
        seriesName: book.seriesName,
        chapterTitle: chapter?.title,
        durationSeconds: book.durationSeconds,
        elapsedSeconds: elapsed,
        playbackRate: playbackState.status == .playing ? 1 : 0,
        artworkData: book.artworkData
      )
    )
  }

  private func makeDurableSources(for request: ImportRequest) throws -> [DurableImportSource] {
    try request.selectedURLs.enumerated().map { index, url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      let bookmark = try? url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      let requestedNames = request.sourceDisplayNames ?? []
      return DurableImportSource(
        displayName: index < requestedNames.count ? requestedNames[index] : url.lastPathComponent,
        bookmarkData: bookmark,
        fallbackURLString: url.absoluteString,
        isDirectory: values.isDirectory == true
      )
    }
  }

  private func resolveSources(_ sources: [DurableImportSource]) throws -> [URL] {
    try sources.map { source in
      if let bookmark = source.bookmarkData {
        var stale = false
        if let resolved = try? URL(
          resolvingBookmarkData: bookmark,
          options: [],
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        ), !stale {
          return resolved
        }
      }
      guard let fallback = URL(string: source.fallbackURLString) else {
        throw PlayerCoreError.fileOperation("The import source is no longer available.")
      }
      return fallback
    }
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
        let urls = try initialURLs ?? resolveSources(checkpoint.sources)
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
      while currentCheckpoint.inspected.count < currentCheckpoint.acquired.count {
        try Task.checkCancellation()
        let selectionIndex = currentCheckpoint.inspected.count
        let item = currentCheckpoint.acquired[selectionIndex]
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
        currentCheckpoint.inspected.append(
          InspectedImportAsset(asset: asset, inspected: inspected, acquired: item)
        )
        guard var progressed = library.importJobs.first(where: { $0.id == jobID }) else { return }
        progressed.queueCheckpoint = currentCheckpoint
        try await replaceAndPersist(progressed)
      }

      let review = try await buildImportReview(from: currentCheckpoint.inspected)
      guard var completed = library.importJobs.first(where: { $0.id == jobID }) else { return }
      completed.queueCheckpoint = currentCheckpoint
      completed.stagedAssets = review.stagedAssets
      completed.proposals = review.proposals
      completed.phase = review.proposals.contains(where: { !$0.warnings.isEmpty })
        ? .needsReview : .ready
      completed.failure = nil
      try await replaceAndPersist(completed)
      lastErrorMessage = nil
    } catch is CancellationError {
      await cancelImport(jobID: jobID)
    } catch {
      guard var failed = library.importJobs.first(where: { $0.id == jobID }) else { return }
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
      lastErrorMessage = error.localizedDescription
    }
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
    catch { lastErrorMessage = error.localizedDescription }
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
      completed.progress = ImportProgress(
        completed: Int64(clamping: result.checkpoint.extractedBytes),
        total: Int64(clamping: result.checkpoint.totalBytes)
      )
      completed.phase = review.proposals.contains(where: { !$0.warnings.isEmpty })
        ? .needsReview : .ready
      completed.failure = nil
      try await replaceAndPersist(completed)
      lastErrorMessage = nil
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
      lastErrorMessage = error.localizedDescription
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
    var prepared: [PreparedImportAsset] = []
    for (selectionIndex, item) in acquired.enumerated() {
      let url = try await environment.media.stagedURL(for: item.staged.relativePath)
      let inspected = try await environment.inspector.inspect(url: url)
      let assetID = await environment.ids.next()
      prepared.append(PreparedImportAsset(
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
    return try await buildImportReview(from: prepared.map {
      InspectedImportAsset(asset: $0.asset, inspected: $0.inspected, acquired: $0.acquired)
    })
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
      let commonTitle = commonNonBlank(group.compactMap(\.inspected.title))
      proposals.append(BookProposal(
        id: proposalID,
        proposedBookID: bookID,
        title: commonFolder ?? commonTitle ?? filenameStem(for: first.originalFilename).display,
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
    replace(updated)
    try await persist()
  }

  private func reviseImport(
    jobID: UUID,
    mutation: (inout ImportJob) throws -> Void
  ) async -> Bool {
    guard var job = library.importJobs.first(where: { $0.id == jobID }) else {
      lastErrorMessage = PlayerCoreError.missingImport(jobID).localizedDescription
      return false
    }
    guard job.phase == .ready || job.phase == .needsReview else {
      lastErrorMessage = PlayerCoreError.importNotReady(jobID).localizedDescription
      return false
    }
    let previousLibrary = library
    do {
      try mutation(&job)
      job.reviewRevision += 1
      job.phase = job.proposals.contains(where: { !$0.warnings.isEmpty }) ? .needsReview : .ready
      try await replaceAndPersist(job)
      lastErrorMessage = nil
      return true
    } catch {
      library = previousLibrary
      lastErrorMessage = error.localizedDescription
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
