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

  init(environment: PlayerEnvironment) {
    self.environment = environment
    self.playbackState = environment.playback.state
  }

  func restore() async {
    do {
      library = try await environment.persistence.load()
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
      if storedPosition != recoveredPosition {
        try await persist()
      }
      isRestored = true
      lastErrorMessage = nil
      publishNowPlaying()
    } catch {
      isRestored = false
      lastErrorMessage = error.localizedDescription
      environment.nowPlaying.clear()
    }
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
  func importAudioSelection(from selectedURLs: [URL]) async -> UUID? {
    guard !selectedURLs.isEmpty else {
      lastErrorMessage = PlayerCoreError.invalidAssetSelection.localizedDescription
      return nil
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
