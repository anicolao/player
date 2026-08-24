import Foundation

protocol LibraryPersisting: Sendable {
  func load() async throws -> LibrarySnapshot
  func save(_ snapshot: LibrarySnapshot) async throws
  func automaticBackups() async -> [AutomaticLibraryBackup]
  func restoreLatestAutomaticBackup() async throws -> LibrarySnapshot
  func startupRecoveryStatus() async -> StartupRecoveryStatus
  func recoverLatestAutomaticBackupPreservingPrimary() async throws -> LibrarySnapshot
  func beginFreshLibraryPreservingPrimary() async throws -> LibrarySnapshot
}

extension LibraryPersisting {
  func automaticBackups() async -> [AutomaticLibraryBackup] { [] }

  func restoreLatestAutomaticBackup() async throws -> LibrarySnapshot {
    throw PlayerCoreError.fileOperation("No valid automatic library backup is available.")
  }

  func startupRecoveryStatus() async -> StartupRecoveryStatus {
    StartupRecoveryStatus(
      issue: .storageUnavailable,
      validAutomaticBackupCount: 0,
      invalidAutomaticBackupCount: 0
    )
  }

  func recoverLatestAutomaticBackupPreservingPrimary() async throws -> LibrarySnapshot {
    try await restoreLatestAutomaticBackup()
  }

  func beginFreshLibraryPreservingPrimary() async throws -> LibrarySnapshot {
    try await save(.empty)
    return .empty
  }
}

protocol MediaManaging: Sendable {
  func stage(sourceURL: URL, jobID: UUID) async throws -> StagedAudio
  func stagedURL(for relativePath: String) async throws -> URL
  func commit(
    _ staged: StagedAudio,
    bookID: UUID,
    assetID: UUID
  ) async throws -> ManagedAudio
  func rollback(_ managed: ManagedAudio) async throws
  func managedURL(for relativePath: String) async throws -> URL
  func discardStaging(for jobID: UUID) async
  func acquireSelection(_ selectedURLs: [URL], jobID: UUID) async throws -> [AcquiredAudioFile]
  func stageArchive(sourceURL: URL, jobID: UUID) async throws -> StagedAudio
  func zipWorkspace(for jobID: UUID) async throws -> ZipImportWorkspace
  func acquireExtractedAudio(
    _ files: [ZipExtractedFile],
    in workspace: ZipImportWorkspace,
    jobID: UUID
  ) async throws -> [AcquiredAudioFile]
  func moveManagedMediaToTrash(
    bookID: UUID,
    transactionID: UUID
  ) async throws -> TrashedMediaManifest
  func restoreManagedMediaFromTrash(_ manifest: TrashedMediaManifest) async throws
  func storageInventory() async throws -> StorageInventorySnapshot
  func discardStagedFile(relativePath: String) async throws
  func discardStorage(scope: StorageScope) async throws
  func reconcileStartupStorage(with library: LibrarySnapshot) async throws
    -> StartupStorageReconciliation
}

extension MediaManaging {
  func acquireSelection(_ selectedURLs: [URL], jobID: UUID) async throws -> [AcquiredAudioFile] {
    throw PlayerCoreError.fileOperation("This media source does not support multi-item acquisition.")
  }

  func stageArchive(sourceURL: URL, jobID: UUID) async throws -> StagedAudio {
    throw PlayerCoreError.fileOperation("This media source does not support ZIP acquisition.")
  }

  func zipWorkspace(for jobID: UUID) async throws -> ZipImportWorkspace {
    throw PlayerCoreError.fileOperation("This media source does not support ZIP extraction.")
  }

  func acquireExtractedAudio(
    _ files: [ZipExtractedFile],
    in workspace: ZipImportWorkspace,
    jobID: UUID
  ) async throws -> [AcquiredAudioFile] {
    throw PlayerCoreError.fileOperation("This media source does not support extracted audio.")
  }

  func moveManagedMediaToTrash(
    bookID: UUID,
    transactionID: UUID
  ) async throws -> TrashedMediaManifest {
    throw PlayerCoreError.fileOperation("This media source does not support recoverable removal.")
  }

  func restoreManagedMediaFromTrash(_ manifest: TrashedMediaManifest) async throws {
    throw PlayerCoreError.fileOperation("This media source does not support trash restoration.")
  }

  func storageInventory() async throws -> StorageInventorySnapshot {
    StorageInventorySnapshot(manifests: [], availableBytes: nil)
  }

  func discardStagedFile(relativePath: String) async throws {
    throw PlayerCoreError.fileOperation("This media source cannot remove an individual staged file.")
  }

  func discardStorage(scope: StorageScope) async throws {
    throw PlayerCoreError.fileOperation("This media source cannot clear recoverable storage.")
  }

  func reconcileStartupStorage(with library: LibrarySnapshot) async throws
    -> StartupStorageReconciliation
  {
    .unchanged(library)
  }
}

protocol AudioInspecting: Sendable {
  func inspect(url: URL) async throws -> InspectedAudio
}

@MainActor
protocol AudioPlaybackControlling: AnyObject {
  var state: PlaybackState { get }
  var currentPositionSeconds: Double { get }
  var playbackRate: Double { get }
  func load(url: URL, bookID: UUID, at seconds: Double) async throws
  func seek(to seconds: Double) async
  func setPlaybackRate(_ rate: Double)
  func play()
  func pause()
  func beginSleepFade(durationSeconds: TimeInterval)
  func completeSleepFadeAndPause()
  func cancelSleepFade()
}

@MainActor
extension AudioPlaybackControlling {
  var playbackRate: Double { 1 }
  func setPlaybackRate(_ rate: Double) {}
  func beginSleepFade(durationSeconds: TimeInterval) {}
  func completeSleepFadeAndPause() { pause() }
  func cancelSleepFade() {}
}

@MainActor
protocol AudioSessionControlling: AnyObject {
  func configure() throws
  func activate() throws
  func installEventHandler(
    _ handler: @escaping @MainActor @Sendable (AudioSessionEvent) async -> Void
  )
}

@MainActor
protocol RemoteCommandControlling: AnyObject {
  func installCommandHandler(
    _ handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  )
  func updateTransportConfiguration(_ preferences: TransportPreferences)
}

@MainActor
extension RemoteCommandControlling {
  func updateTransportConfiguration(_ preferences: TransportPreferences) {}
}

@MainActor
protocol NowPlayingPublishing: AnyObject {
  func publish(_ snapshot: NowPlayingSnapshot)
  func clear()
}

protocol PlayerClock: Sendable {
  func now() -> Date
}

protocol PlayerIDGenerating: Sendable {
  func next() async -> UUID
}

struct SystemPlayerClock: PlayerClock {
  func now() -> Date { Date() }
}

struct FixedPlayerClock: PlayerClock {
  let value: Date
  func now() -> Date { value }
}

actor SystemPlayerIDGenerator: PlayerIDGenerating {
  func next() -> UUID { UUID() }
}

actor DeterministicPlayerIDGenerator: PlayerIDGenerating {
  private var values: [UUID]

  init(values: [UUID]) {
    self.values = values
  }

  func next() -> UUID {
    precondition(!values.isEmpty, "The deterministic ID sequence is exhausted.")
    return values.removeFirst()
  }
}

@MainActor
struct PlayerEnvironment {
  let persistence: any LibraryPersisting
  let media: any MediaManaging
  let inspector: any AudioInspecting
  let playback: any AudioPlaybackControlling
  let audioSession: any AudioSessionControlling
  let remoteCommands: any RemoteCommandControlling
  let nowPlaying: any NowPlayingPublishing
  let clock: any PlayerClock
  let ids: any PlayerIDGenerating
  let zipExtractor: any ZipExtracting
  let backups: any LibraryBackupManaging
  let diagnostics: any SupportDiagnosticsManaging

  init(
    persistence: any LibraryPersisting,
    media: any MediaManaging,
    inspector: any AudioInspecting,
    playback: any AudioPlaybackControlling,
    audioSession: any AudioSessionControlling = DisabledAudioSessionController(),
    remoteCommands: any RemoteCommandControlling = DisabledRemoteCommandController(),
    nowPlaying: any NowPlayingPublishing = DisabledNowPlayingPublisher(),
    clock: any PlayerClock = SystemPlayerClock(),
    ids: any PlayerIDGenerating = SystemPlayerIDGenerator(),
    zipExtractor: any ZipExtracting = SafeZipExtractor(),
    backups: any LibraryBackupManaging = DisabledLibraryBackupManager(),
    diagnostics: any SupportDiagnosticsManaging = DisabledSupportDiagnosticsManager()
  ) {
    self.persistence = persistence
    self.media = media
    self.inspector = inspector
    self.playback = playback
    self.audioSession = audioSession
    self.remoteCommands = remoteCommands
    self.nowPlaying = nowPlaying
    self.clock = clock
    self.ids = ids
    self.zipExtractor = zipExtractor
    self.backups = backups
    self.diagnostics = diagnostics
  }

  static func production(rootURL: URL? = nil) throws -> PlayerEnvironment {
    let root = try rootURL ?? Self.defaultRootURL()
    return PlayerEnvironment(
      persistence: CodableLibraryStore(fileURL: root.appending(path: "Library.json")),
      media: FileSystemMediaManager(rootURL: root),
      inspector: AVFoundationAudioInspector(),
      playback: AVPlayerPlaybackController(),
      audioSession: AVAudioSessionController(),
      remoteCommands: MPRemoteCommandController(),
      nowPlaying: MPNowPlayingPublisher(),
      backups: FileSystemLibraryBackupManager(rootURL: root),
      diagnostics: FileSystemSupportDiagnosticsManager(rootURL: root)
    )
  }

  private static func defaultRootURL() throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return support.appending(path: "Player", directoryHint: .isDirectory)
  }
}

@MainActor
final class DisabledAudioSessionController: AudioSessionControlling {
  func configure() throws {}
  func activate() throws {}
  func installEventHandler(
    _ handler: @escaping @MainActor @Sendable (AudioSessionEvent) async -> Void
  ) {}
}

@MainActor
final class DisabledRemoteCommandController: RemoteCommandControlling {
  func installCommandHandler(
    _ handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  ) {}
}

@MainActor
final class DisabledNowPlayingPublisher: NowPlayingPublishing {
  func publish(_ snapshot: NowPlayingSnapshot) {}
  func clear() {}
}
