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
        timelineStartSeconds: 0
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
        chapters: chapters
      )
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

  @discardableResult
  func addImportToLibrary(jobID: UUID) async -> UUID? {
    guard var job = library.importJobs.first(where: { $0.id == jobID }) else {
      lastErrorMessage = PlayerCoreError.missingImport(jobID).localizedDescription
      return nil
    }
    guard
      job.phase == .ready || job.phase == .needsReview,
      let proposal = job.proposal,
      let stagedPath = job.stagedRelativePath
    else {
      lastErrorMessage = PlayerCoreError.importNotReady(jobID).localizedDescription
      return nil
    }

    let previousLibrary = library
    var managed: ManagedAudio?
    do {
      job.phase = .committing
      try await replaceAndPersist(job)
      let staged = StagedAudio(
        relativePath: stagedPath,
        originalFilename: proposal.asset.originalFilename,
        checksumSHA256: proposal.asset.checksumSHA256,
        byteCount: proposal.asset.byteCount
      )
      let committed = try await environment.media.commit(
        staged,
        bookID: proposal.proposedBookID,
        assetID: proposal.asset.id
      )
      managed = committed

      var asset = proposal.asset
      asset.managedRelativePath = committed.relativePath
      let book = Book(
        id: proposal.proposedBookID,
        title: proposal.title,
        authors: proposal.authors,
        durationSeconds: proposal.durationSeconds,
        artworkData: proposal.artworkData,
        assets: [asset],
        dateAdded: environment.clock.now(),
        narrators: proposal.narrators,
        seriesName: proposal.seriesName,
        seriesPosition: proposal.seriesPosition,
        artworkMediaType: proposal.artworkMediaType,
        chapters: proposal.chapters
      )
      library.books.append(book)
      job.phase = .committed
      job.committedBookID = book.id
      job.updatedAt = environment.clock.now()
      replace(job)
      try await persist()
      await environment.media.discardStaging(for: jobID)
      lastErrorMessage = nil
      return book.id
    } catch {
      if let managed { try? await environment.media.rollback(managed) }
      library = previousLibrary
      lastErrorMessage = error.localizedDescription
      return nil
    }
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

private extension String {
  var nilIfBlank: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}
