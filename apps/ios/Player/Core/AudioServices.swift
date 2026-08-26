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
    let albumTitle = await stringValue(for: .commonIdentifierAlbumName, in: metadata)
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
    let discNumber = await integerValue(
      matchingIdentifierFragments: ["discnumber", "disc-number", "disc_number", "/disk", "/disc"],
      in: metadata
    )
    let trackNumber = await integerValue(
      matchingIdentifierFragments: ["tracknumber", "track-number", "track_number", "/track"],
      in: metadata
    )
    let chapters = try await chapters(in: asset, durationSeconds: seconds, filename: url.lastPathComponent)

    return InspectedAudio(
      title: title,
      albumTitle: albumTitle,
      authors: ContributorParser.names(from: artist),
      durationSeconds: seconds,
      artworkData: artwork,
      container: fileExtension.uppercased(),
      narrators: ContributorParser.names(from: narrator),
      seriesName: series?.trimmedNilIfEmpty,
      seriesPosition: seriesPosition?.trimmedNilIfEmpty,
      artworkMediaType: artwork.flatMap(ArtworkType.mediaType),
      chapters: chapters,
      discNumber: discNumber,
      trackNumber: trackNumber
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

  private func integerValue(
    matchingIdentifierFragments included: [String],
    in metadata: [AVMetadataItem]
  ) async -> Int? {
    guard let value = await textValue(matchingIdentifierFragments: included, in: metadata) else {
      return nil
    }
    let leadingComponent = value.split(separator: "/", maxSplits: 1).first
    return leadingComponent.flatMap { component in
      Int(component.trimmingCharacters(in: .whitespacesAndNewlines))
    }
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
  private(set) var playbackRate = 1.0
  private var sleepFadeTask: Task<Void, Never>?
  private var sleepFadeOriginalVolume: Float?

  var currentPositionSeconds: Double {
    guard let seconds = player?.currentTime().seconds, seconds.isFinite else {
      return state.elapsedSeconds
    }
    return max(0, seconds)
  }

  var isPlaybackAdvancing: Bool {
    state.status == .playing && player?.timeControlStatus == .playing
  }

  func load(url: URL, bookID: UUID, at seconds: Double = 0) async throws {
    cancelSleepFade()
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
    player?.playImmediately(atRate: Float(playbackRate))
    guard state.loadedBookID != nil else { return }
    state.status = .playing
  }

  func setPlaybackRate(_ rate: Double) {
    guard TransportPreferences.isValidPlaybackRate(rate) else { return }
    playbackRate = rate
    if state.status == .playing {
      player?.rate = Float(rate)
    }
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

  func beginSleepFade(durationSeconds: TimeInterval) {
    guard let player else { return }
    cancelSleepFade()
    let duration = max(0, durationSeconds.isFinite ? durationSeconds : 0)
    let originalVolume = player.volume
    sleepFadeOriginalVolume = originalVolume
    guard duration > 0 else {
      player.volume = 0
      return
    }
    sleepFadeTask = Task { @MainActor [weak self, weak player] in
      let steps = 20
      let stepDuration = duration / Double(steps)
      for step in 1...steps {
        guard !Task.isCancelled, let self, let player, self.player === player else { return }
        player.volume = originalVolume * Float(steps - step) / Float(steps)
        try? await Task.sleep(for: .seconds(stepDuration))
      }
    }
  }

  func completeSleepFadeAndPause() {
    sleepFadeTask?.cancel()
    sleepFadeTask = nil
    pause()
    if let sleepFadeOriginalVolume {
      player?.volume = sleepFadeOriginalVolume
    }
    sleepFadeOriginalVolume = nil
  }

  func cancelSleepFade() {
    sleepFadeTask?.cancel()
    sleepFadeTask = nil
    if let sleepFadeOriginalVolume {
      player?.volume = sleepFadeOriginalVolume
    }
    sleepFadeOriginalVolume = nil
  }
}

@MainActor
final class DeterministicPlaybackController: AudioPlaybackControlling {
  private(set) var state: PlaybackState
  private(set) var loadedURL: URL?
  private(set) var playbackRate = 1.0

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

  func setPlaybackRate(_ rate: Double) {
    guard TransportPreferences.isValidPlaybackRate(rate) else { return }
    playbackRate = rate
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
  // Playback sessions already route to AirPlay and Bluetooth A2DP. Apple only
  // permits explicitly setting those options with `.playAndRecord`; combining
  // them with `.playback` causes `setCategory` to fail with OSStatus -50.
  static let playbackCategoryOptions: AVAudioSession.CategoryOptions = []

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
      options: Self.playbackCategoryOptions
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
  private var transportPreferences: TransportPreferences = .default

  init(center: MPRemoteCommandCenter = .shared()) {
    self.center = center
  }

  func installCommandHandler(
    _ handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  ) {
    UIApplication.shared.beginReceivingRemoteControlEvents()
    removeInstalledTargets()
    install(center.playCommand, event: .play, handler: handler)
    install(center.pauseCommand, event: .pause, handler: handler)
    install(center.togglePlayPauseCommand, event: .togglePlayPause, handler: handler)
    install(center.previousTrackCommand, trackButton: .previous, handler: handler)
    install(center.nextTrackCommand, trackButton: .next, handler: handler)

    updateTransportConfiguration(transportPreferences)
    center.skipForwardCommand.isEnabled = true
    let forwardTarget = center.skipForwardCommand.addTarget { event in
      let seconds = (event as? MPSkipIntervalCommandEvent)?.interval
        ?? self.transportPreferences.forwardSkipSeconds
      Task { @MainActor in await handler(.skipForward(seconds: seconds)) }
      return .success
    }
    installedTargets.append((center.skipForwardCommand, forwardTarget))
    center.skipBackwardCommand.isEnabled = true
    let backwardTarget = center.skipBackwardCommand.addTarget { event in
      let seconds = (event as? MPSkipIntervalCommandEvent)?.interval
        ?? self.transportPreferences.backwardSkipSeconds
      Task { @MainActor in await handler(.skipBackward(seconds: seconds)) }
      return .success
    }
    installedTargets.append((center.skipBackwardCommand, backwardTarget))
    center.changePlaybackPositionCommand.isEnabled = true
    let positionTarget = center.changePlaybackPositionCommand.addTarget { event in
      guard let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
        return .commandFailed
      }
      Task { @MainActor in await handler(.changePosition(seconds: seconds)) }
      return .success
    }
    installedTargets.append((center.changePlaybackPositionCommand, positionTarget))
    center.changePlaybackRateCommand.isEnabled = true
    let rateTarget = center.changePlaybackRateCommand.addTarget { event in
      guard let rate = (event as? MPChangePlaybackRateCommandEvent)?.playbackRate else {
        return .commandFailed
      }
      Task { @MainActor in await handler(.changePlaybackRate(Double(rate))) }
      return .success
    }
    installedTargets.append((center.changePlaybackRateCommand, rateTarget))
  }

  func updateTransportConfiguration(_ preferences: TransportPreferences) {
    guard preferences.isValid else { return }
    transportPreferences = preferences
    center.skipForwardCommand.preferredIntervals = [NSNumber(value: preferences.forwardSkipSeconds)]
    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: preferences.backwardSkipSeconds)]
    center.changePlaybackRateCommand.supportedPlaybackRates = stride(
      from: 0.5,
      through: 3.0,
      by: 0.05
    ).map { NSNumber(value: $0) }
  }

  private func install(
    _ command: MPRemoteCommand,
    event: RemotePlaybackCommand,
    handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  ) {
    command.isEnabled = true
    let target = command.addTarget { _ in
      Task { @MainActor in await handler(event) }
      return .success
    }
    installedTargets.append((command, target))
  }

  private func install(
    _ command: MPRemoteCommand,
    trackButton: RemoteTrackButton,
    handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  ) {
    command.isEnabled = true
    let target = command.addTarget { _ in
      let event = trackButton.playbackCommand(using: self.transportPreferences)
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
      MPMediaItemPropertyAlbumTitle: snapshot.seriesName ?? snapshot.title,
      MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue,
      MPMediaItemPropertyPlaybackDuration: snapshot.durationSeconds,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsedSeconds,
      MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.defaultPlaybackRate,
      MPNowPlayingInfoPropertyPlaybackProgress: snapshot.durationSeconds > 0
        ? min(max(snapshot.elapsedSeconds / snapshot.durationSeconds, 0), 1) : 0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPNowPlayingInfoPropertyIsLiveStream: false,
      MPNowPlayingInfoPropertyExternalContentIdentifier: snapshot.bookID.uuidString.lowercased(),
    ]
    if !snapshot.narrators.isEmpty {
      information[MPMediaItemPropertyComposer] = snapshot.narrators.joined(separator: ", ")
    }
    if let chapterIndex = snapshot.chapterIndex {
      information[MPNowPlayingInfoPropertyChapterNumber] = chapterIndex
      information[MPNowPlayingInfoPropertyChapterCount] = snapshot.chapterCount
    }
    if let data = snapshot.artworkData, let artwork = MPNowPlayingArtworkFactory.make(from: data) {
      information[MPMediaItemPropertyArtwork] = artwork
    }
    center.nowPlayingInfo = information
    center.playbackState = snapshot.playbackRate > 0 ? .playing : .paused
  }

  func clear() {
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
  }
}

/// `MPNowPlayingInfoCenter` invokes artwork request handlers on its private
/// access queue. Building the closure inside `MPNowPlayingPublisher`, which is
/// main-actor isolated, gives the closure a main-actor executor check and
/// crashes when MediaPlayer calls it off-main. Keep the factory and handler
/// explicitly outside that isolation and only capture an immutable image.
enum MPNowPlayingArtworkFactory {
  nonisolated static func make(from data: Data) -> MPMediaItemArtwork? {
    guard let image = UIImage(data: data) else { return nil }
    let provider = MPNowPlayingArtworkProvider(image: image)
    return MPMediaItemArtwork(
      boundsSize: provider.boundsSize,
      requestHandler: provider.image(for:)
    )
  }
}

final class MPNowPlayingArtworkProvider: @unchecked Sendable {
  private static let maximumDimension: CGFloat = 1_024
  private let storedImage: UIImage
  let boundsSize: CGSize

  nonisolated init(image: UIImage) {
    storedImage = image
    let sourceSize = image.size
    let scale = min(
      1,
      Self.maximumDimension / max(sourceSize.width, sourceSize.height)
    )
    boundsSize = CGSize(
      width: max(1, (sourceSize.width * scale).rounded(.down)),
      height: max(1, (sourceSize.height * scale).rounded(.down))
    )
  }

  /// MediaPlayer asks for receiver-appropriate artwork dimensions. Return an
  /// exact-size bitmap so Bluetooth and in-car displays do not have to decode
  /// or resize an arbitrarily large embedded cover themselves.
  nonisolated func image(for requestedSize: CGSize) -> UIImage {
    guard requestedSize.width.isFinite, requestedSize.height.isFinite,
      requestedSize.width > 0, requestedSize.height > 0
    else { return storedImage }

    let targetSize = CGSize(
      width: min(Self.maximumDimension, max(1, requestedSize.width.rounded(.up))),
      height: min(Self.maximumDimension, max(1, requestedSize.height.rounded(.up)))
    )
    let sourceSize = storedImage.size
    guard sourceSize.width > 0, sourceSize.height > 0 else { return storedImage }

    let scale = max(
      targetSize.width / sourceSize.width,
      targetSize.height / sourceSize.height
    )
    let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    let drawOrigin = CGPoint(
      x: (targetSize.width - drawSize.width) / 2,
      y: (targetSize.height - drawSize.height) / 2
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
      storedImage.draw(in: CGRect(origin: drawOrigin, size: drawSize))
    }
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
  private(set) var transportPreferences: TransportPreferences = .default

  func installCommandHandler(
    _ handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  ) {
    installationCount += 1
    commandHandler = handler
  }

  func send(_ command: RemotePlaybackCommand) async {
    await commandHandler?(command)
  }

  func updateTransportConfiguration(_ preferences: TransportPreferences) {
    transportPreferences = preferences
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
