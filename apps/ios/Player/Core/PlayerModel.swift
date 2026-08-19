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

  init(environment: PlayerEnvironment) {
    self.environment = environment
    self.playbackState = environment.playback.state
  }

  func restore() async {
    do {
      library = try await environment.persistence.load()
      isRestored = true
      lastErrorMessage = nil
    } catch {
      isRestored = false
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
        container: inspected.container
      )
      job.proposal = BookProposal(
        id: proposalID,
        proposedBookID: bookID,
        title: inspected.title?.nilIfBlank ?? fallbackTitle,
        authors: inspected.authors,
        durationSeconds: inspected.durationSeconds,
        artworkData: inspected.artworkData,
        asset: asset,
        warnings: []
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
        dateAdded: environment.clock.now()
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

  func play(bookID: UUID, at seconds: Double = 0) async {
    guard
      let book = library.books.first(where: { $0.id == bookID }),
      let asset = book.assets.first
    else {
      lastErrorMessage = PlayerCoreError.missingBook(bookID).localizedDescription
      return
    }

    do {
      let url = try await environment.media.managedURL(for: asset.managedRelativePath)
      try await environment.playback.load(url: url, bookID: bookID, at: seconds)
      environment.playback.play()
      playbackState = environment.playback.state
      library.currentBookID = bookID
      try await persist()
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func pause() {
    environment.playback.pause()
    playbackState = environment.playback.state
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
