import AVFoundation
import Foundation
import MediaPlayer
import UIKit

struct AVFoundationAudioInspector: AudioInspecting {
  private static let maximumArtworkBytes = 20 * 1_024 * 1_024

  func inspect(url: URL) async throws -> InspectedAudio {
    let fileExtension = url.pathExtension.lowercased()
    guard ["m4a", "m4b", "mp3"].contains(fileExtension) else {
      throw PlayerCoreError.unsupportedFile(url.lastPathComponent)
    }

    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let seconds = CMTimeGetSeconds(duration)
    guard seconds.isFinite, seconds > 0 else {
      throw PlayerCoreError.unreadableAudio(url.lastPathComponent)
    }

    let commonMetadata = try await asset.load(.commonMetadata)
    let formatMetadata = try await asset.load(.metadata)
    let metadata = commonMetadata + formatMetadata
    let title = await stringValue(for: .commonIdentifierTitle, in: metadata)
    let artist = await stringValue(for: .commonIdentifierArtist, in: metadata)
    let artwork = await dataValue(for: .commonIdentifierArtwork, in: metadata)
    let narrator = await textValue(
      matchingIdentifierFragments: ["narrator", "readby", "reader"],
      in: metadata
    )
    let seriesPosition = await textValue(
      matchingIdentifierFragments: [
        "series-part", "series_part", "seriesposition", "series-position", "seriesnumber",
      ],
      in: metadata
    )
    let series = await textValue(
      matchingIdentifierFragments: ["series"],
      excludingIdentifierFragments: ["part", "position", "number"],
      in: metadata
    )
    let chapters = try await chapters(in: asset, durationSeconds: seconds, filename: url.lastPathComponent)

    return InspectedAudio(
      title: title,
      authors: ContributorParser.names(from: artist),
      durationSeconds: seconds,
      artworkData: artwork,
      container: fileExtension.uppercased(),
      narrators: ContributorParser.names(from: narrator),
      seriesName: series?.trimmedNilIfEmpty,
      seriesPosition: seriesPosition?.trimmedNilIfEmpty,
      artworkMediaType: artwork.flatMap(ArtworkType.mediaType),
      chapters: chapters
    )
  }

  private func stringValue(
    for identifier: AVMetadataIdentifier,
    in metadata: [AVMetadataItem]
  ) async -> String? {
    guard let item = AVMetadataItem.metadataItems(
      from: metadata,
      filteredByIdentifier: identifier
    ).first else { return nil }
    return try? await item.load(.stringValue)
  }

  private func dataValue(
    for identifier: AVMetadataIdentifier,
    in metadata: [AVMetadataItem]
  ) async -> Data? {
    guard let item = AVMetadataItem.metadataItems(
      from: metadata,
      filteredByIdentifier: identifier
    ).first else { return nil }
    guard let data = try? await item.load(.dataValue), data.count <= Self.maximumArtworkBytes else {
      return nil
    }
    return data
  }

  private func textValue(
    matchingIdentifierFragments included: [String],
    excludingIdentifierFragments excluded: [String] = [],
    in metadata: [AVMetadataItem]
  ) async -> String? {
    for item in metadata {
      let identifier = item.identifier?.rawValue.lowercased() ?? ""
      guard
        included.contains(where: identifier.contains),
        !excluded.contains(where: identifier.contains),
        let value = try? await item.load(.stringValue),
        value.trimmedNilIfEmpty != nil
      else { continue }
      return value
    }
    return nil
  }

  private func chapters(
    in asset: AVAsset,
    durationSeconds: Double,
    filename: String
  ) async throws -> [Chapter] {
    let locales = try await asset.load(.availableChapterLocales)
    for locale in locales {
      let groups = try await asset.loadChapterMetadataGroups(
        withTitleLocale: locale,
        containingItemsWithCommonKeys: [.commonKeyTitle]
      )
      guard !groups.isEmpty else { continue }
      var candidates: [EmbeddedChapterCandidate] = []
      for group in groups {
        let title = await stringValue(for: .commonIdentifierTitle, in: group.items)
        candidates.append(
          EmbeddedChapterCandidate(
            title: title,
            startSeconds: CMTimeGetSeconds(group.timeRange.start),
            durationSeconds: CMTimeGetSeconds(group.timeRange.duration)
          )
        )
      }
      let normalized = ChapterTimeline.embeddedChapters(
        candidates,
        assetDurationSeconds: durationSeconds
      )
      if !normalized.isEmpty { return normalized }
    }

    return [
      Chapter(
        id: "file-0",
        title: URL(filePath: filename).deletingPathExtension().lastPathComponent,
        startSeconds: 0,
        durationSeconds: durationSeconds,
        source: .file,
        assetID: nil
      )
    ]
  }
}

struct EmbeddedChapterCandidate: Equatable, Sendable {
  var title: String?
  var startSeconds: Double
  var durationSeconds: Double
}

enum ChapterTimeline {
  static func embeddedChapters(
    _ candidates: [EmbeddedChapterCandidate],
    assetDurationSeconds: Double
  ) -> [Chapter] {
    guard assetDurationSeconds.isFinite, assetDurationSeconds > 0 else { return [] }
    let ordered = candidates
      .filter {
        $0.startSeconds.isFinite && $0.durationSeconds.isFinite
          && $0.startSeconds >= 0 && $0.startSeconds < assetDurationSeconds
      }
      .sorted { $0.startSeconds < $1.startSeconds }

    return ordered.enumerated().compactMap { index, candidate in
      let nextStart = ordered.indices.contains(index + 1)
        ? ordered[index + 1].startSeconds
        : assetDurationSeconds
      let maximumDuration = max(0, min(nextStart, assetDurationSeconds) - candidate.startSeconds)
      let proposedDuration = candidate.durationSeconds > 0
        ? candidate.durationSeconds
        : maximumDuration
      let duration = min(proposedDuration, maximumDuration)
      guard duration > 0 else { return nil }
      let startMilliseconds = Int64((candidate.startSeconds * 1_000).rounded(.down))
      return Chapter(
        id: "embedded-\(index)-\(startMilliseconds)",
        title: candidate.title?.trimmedNilIfEmpty ?? "Chapter \(index + 1)",
        startSeconds: candidate.startSeconds,
        durationSeconds: duration,
        source: .embedded,
        assetID: nil
      )
    }
  }
}

enum ContributorParser {
  static func names(from value: String?) -> [String] {
    guard let value else { return [] }
    return value
      .components(separatedBy: CharacterSet(charactersIn: ";\n"))
      .compactMap(\.trimmedNilIfEmpty)
  }
}

private enum ArtworkType {
  static func mediaType(for data: Data) -> String? {
    let bytes = Array(data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if bytes.count >= 12,
      String(decoding: bytes[4..<12], as: UTF8.self) == "ftypheic"
    {
      return "image/heic"
    }
    return nil
  }
}

private extension String {
  var trimmedNilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

actor DeterministicAudioInspector: AudioInspecting {
  private let result: Result<InspectedAudio, PlayerCoreError>

  init(result: Result<InspectedAudio, PlayerCoreError>) {
    self.result = result
  }

  func inspect(url: URL) throws -> InspectedAudio {
    try result.get()
  }
}

@MainActor
final class AVPlayerPlaybackController: AudioPlaybackControlling {
  private var player: AVPlayer?
  private(set) var state: PlaybackState = .unloaded

  var currentPositionSeconds: Double {
    guard let seconds = player?.currentTime().seconds, seconds.isFinite else {
      return state.elapsedSeconds
    }
    return max(0, seconds)
  }

  func load(url: URL, bookID: UUID, at seconds: Double = 0) async throws {
    let asset = AVURLAsset(url: url)
    guard try await asset.load(.isPlayable) else {
      throw PlayerCoreError.unreadableAudio(url.lastPathComponent)
    }

    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    if seconds > 0 {
      await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1_000))
    }
    self.player = player
    state = PlaybackState(status: .paused, loadedBookID: bookID, elapsedSeconds: seconds)
  }

  func play() {
    player?.play()
    guard state.loadedBookID != nil else { return }
    state.status = .playing
  }

  func seek(to seconds: Double) async {
    guard let player else { return }
    let destination = max(0, seconds)
    await player.seek(to: CMTime(seconds: destination, preferredTimescale: 1_000))
    state.elapsedSeconds = currentPositionSeconds
  }

  func pause() {
    player?.pause()
    guard state.loadedBookID != nil else { return }
    if let seconds = player?.currentTime().seconds, seconds.isFinite {
      state.elapsedSeconds = seconds
    }
    state.status = .paused
  }
}

@MainActor
final class DeterministicPlaybackController: AudioPlaybackControlling {
  private(set) var state: PlaybackState
  private(set) var loadedURL: URL?

  init(state: PlaybackState = .unloaded) {
    self.state = state
  }

  var currentPositionSeconds: Double { state.elapsedSeconds }

  func load(url: URL, bookID: UUID, at seconds: Double) async throws {
    loadedURL = url
    state = PlaybackState(status: .paused, loadedBookID: bookID, elapsedSeconds: seconds)
  }

  func play() {
    guard state.loadedBookID != nil else { return }
    state.status = .playing
  }

  func seek(to seconds: Double) async {
    guard state.loadedBookID != nil else { return }
    state.elapsedSeconds = max(0, seconds)
  }

  func pause() {
    guard state.loadedBookID != nil else { return }
    state.status = .paused
  }
}

@MainActor
final class AVAudioSessionController: NSObject, AudioSessionControlling {
  private let session: AVAudioSession
  private var eventHandler: (@MainActor @Sendable (AudioSessionEvent) async -> Void)?

  init(session: AVAudioSession = .sharedInstance()) {
    self.session = session
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruptionNotification(_:)),
      name: AVAudioSession.interruptionNotification,
      object: session
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChangeNotification(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: session
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func configure() throws {
    try session.setCategory(
      .playback,
      mode: .spokenAudio,
      options: [.allowAirPlay, .allowBluetoothA2DP]
    )
  }

  func activate() throws {
    try session.setActive(true)
  }

  func installEventHandler(
    _ handler: @escaping @MainActor @Sendable (AudioSessionEvent) async -> Void
  ) {
    eventHandler = handler
  }

  @objc private nonisolated func handleInterruptionNotification(_ notification: Notification) {
    guard
      let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawType)
    else { return }

    let event: AudioSessionEvent
    switch type {
    case .began:
      event = .interruptionBegan
    case .ended:
      let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      event = .interruptionEnded(
        shouldResume: AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
      )
    @unknown default:
      return
    }
    Task { @MainActor [weak self] in
      guard let handler = self?.eventHandler else { return }
      await handler(event)
    }
  }

  @objc private nonisolated func handleRouteChangeNotification(_ notification: Notification) {
    guard
      let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
    else { return }
    Task { @MainActor [weak self] in
      guard let handler = self?.eventHandler else { return }
      await handler(.oldDeviceUnavailable)
    }
  }
}

@MainActor
final class MPRemoteCommandController: RemoteCommandControlling {
  private let center: MPRemoteCommandCenter
  private var installedTargets: [(MPRemoteCommand, Any)] = []

  init(center: MPRemoteCommandCenter = .shared()) {
    self.center = center
  }

  func installCommandHandler(
    _ handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  ) {
    removeInstalledTargets()
    install(center.playCommand, event: .play, handler: handler)
    install(center.pauseCommand, event: .pause, handler: handler)
    install(center.togglePlayPauseCommand, event: .togglePlayPause, handler: handler)

    center.skipForwardCommand.preferredIntervals = [30]
    center.skipBackwardCommand.preferredIntervals = [15]
    let forwardTarget = center.skipForwardCommand.addTarget { event in
      let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? 30
      Task { @MainActor in await handler(.skipForward(seconds: seconds)) }
      return .success
    }
    installedTargets.append((center.skipForwardCommand, forwardTarget))
    let backwardTarget = center.skipBackwardCommand.addTarget { event in
      let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
      Task { @MainActor in await handler(.skipBackward(seconds: seconds)) }
      return .success
    }
    installedTargets.append((center.skipBackwardCommand, backwardTarget))
    let positionTarget = center.changePlaybackPositionCommand.addTarget { event in
      guard let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
        return .commandFailed
      }
      Task { @MainActor in await handler(.changePosition(seconds: seconds)) }
      return .success
    }
    installedTargets.append((center.changePlaybackPositionCommand, positionTarget))
  }

  private func install(
    _ command: MPRemoteCommand,
    event: RemotePlaybackCommand,
    handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  ) {
    let target = command.addTarget { _ in
      Task { @MainActor in await handler(event) }
      return .success
    }
    installedTargets.append((command, target))
  }

  private func removeInstalledTargets() {
    for (command, target) in installedTargets {
      command.removeTarget(target)
    }
    installedTargets.removeAll()
  }
}

@MainActor
final class MPNowPlayingPublisher: NowPlayingPublishing {
  private let center: MPNowPlayingInfoCenter

  init(center: MPNowPlayingInfoCenter = .default()) {
    self.center = center
  }

  func publish(_ snapshot: NowPlayingSnapshot) {
    var information: [String: Any] = [
      MPMediaItemPropertyTitle: snapshot.title,
      MPMediaItemPropertyArtist: snapshot.authors.joined(separator: ", "),
      MPMediaItemPropertyPlaybackDuration: snapshot.durationSeconds,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsedSeconds,
      MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
    ]
    if !snapshot.narrators.isEmpty {
      information[MPMediaItemPropertyComposer] = snapshot.narrators.joined(separator: ", ")
    }
    if let seriesName = snapshot.seriesName {
      information[MPMediaItemPropertyAlbumTitle] = seriesName
    }
    if let data = snapshot.artworkData, let image = UIImage(data: data) {
      information[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
        boundsSize: image.size,
        requestHandler: { _ in image }
      )
    }
    center.nowPlayingInfo = information
  }

  func clear() {
    center.nowPlayingInfo = nil
  }
}

@MainActor
final class DeterministicAudioSessionController: AudioSessionControlling {
  private var eventHandler: (@MainActor @Sendable (AudioSessionEvent) async -> Void)?
  private(set) var configureCount = 0
  private(set) var activateCount = 0
  var configureError: Error?
  var activationError: Error?

  func configure() throws {
    configureCount += 1
    if let configureError { throw configureError }
  }

  func activate() throws {
    activateCount += 1
    if let activationError { throw activationError }
  }

  func installEventHandler(
    _ handler: @escaping @MainActor @Sendable (AudioSessionEvent) async -> Void
  ) {
    eventHandler = handler
  }

  func send(_ event: AudioSessionEvent) async {
    await eventHandler?(event)
  }
}

@MainActor
final class DeterministicRemoteCommandController: RemoteCommandControlling {
  private var commandHandler: (@MainActor @Sendable (RemotePlaybackCommand) async -> Void)?
  private(set) var installationCount = 0

  func installCommandHandler(
    _ handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  ) {
    installationCount += 1
    commandHandler = handler
  }

  func send(_ command: RemotePlaybackCommand) async {
    await commandHandler?(command)
  }
}

@MainActor
final class DeterministicNowPlayingPublisher: NowPlayingPublishing {
  private(set) var snapshots: [NowPlayingSnapshot] = []
  private(set) var clearCount = 0

  var latest: NowPlayingSnapshot? { snapshots.last }

  func publish(_ snapshot: NowPlayingSnapshot) {
    snapshots.append(snapshot)
  }

  func clear() {
    clearCount += 1
  }
}
