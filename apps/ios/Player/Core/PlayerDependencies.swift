import Foundation

protocol LibraryPersisting: Sendable {
  func load() async throws -> LibrarySnapshot
  func save(_ snapshot: LibrarySnapshot) async throws
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
}

protocol AudioInspecting: Sendable {
  func inspect(url: URL) async throws -> InspectedAudio
}

@MainActor
protocol AudioPlaybackControlling: AnyObject {
  var state: PlaybackState { get }
  func load(url: URL, bookID: UUID, at seconds: Double) async throws
  func play()
  func pause()
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
  let clock: any PlayerClock
  let ids: any PlayerIDGenerating

  init(
    persistence: any LibraryPersisting,
    media: any MediaManaging,
    inspector: any AudioInspecting,
    playback: any AudioPlaybackControlling,
    clock: any PlayerClock = SystemPlayerClock(),
    ids: any PlayerIDGenerating = SystemPlayerIDGenerator()
  ) {
    self.persistence = persistence
    self.media = media
    self.inspector = inspector
    self.playback = playback
    self.clock = clock
    self.ids = ids
  }

  static func production(rootURL: URL? = nil) throws -> PlayerEnvironment {
    let root = try rootURL ?? Self.defaultRootURL()
    return PlayerEnvironment(
      persistence: CodableLibraryStore(fileURL: root.appending(path: "Library.json")),
      media: FileSystemMediaManager(rootURL: root),
      inspector: AVFoundationAudioInspector(),
      playback: AVPlayerPlaybackController()
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
