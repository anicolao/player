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
  private static let progressInterval = CMTime(seconds: 0.25, preferredTimescale: 1_000)

  private var player: AVPlayer?
  private(set) var state: PlaybackState = .unloaded
  private(set) var playbackRate = 1.0
  private var eventHandler: (@MainActor @Sendable (PlaybackEngineEvent) async -> Void)?
  private var eventDeliveryTask: Task<Void, Never>?
  private var observerGeneration = 0
  private var periodicTimeObserver: Any?
  private var endObserver: NSObjectProtocol?
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

  func installEventHandler(
    _ handler: @escaping @MainActor @Sendable (PlaybackEngineEvent) async -> Void
  ) {
    eventHandler = handler
  }

  func load(url: URL, bookID: UUID, at seconds: Double = 0) async throws {
    cancelSleepFade()
    removePlaybackObservers()
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
    installPlaybackObservers(for: player, item: item)
  }

  func unload() {
    cancelSleepFade()
    removePlaybackObservers()
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil
    state = .unloaded
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

  private func installPlaybackObservers(for player: AVPlayer, item: AVPlayerItem) {
    let generation = observerGeneration
    periodicTimeObserver = player.addPeriodicTimeObserver(
      forInterval: Self.progressInterval,
      queue: .main
    ) { [weak self, weak player] time in
      let seconds = time.seconds
      MainActor.assumeIsolated {
        guard let self, self.player === player, self.state.status == .playing else { return }
        guard seconds.isFinite else { return }
        self.state.elapsedSeconds = max(0, seconds)
        self.enqueueEvent(
          .progress(seconds: self.state.elapsedSeconds),
          generation: generation
        )
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self, weak item] _ in
      MainActor.assumeIsolated {
        guard let self,
          self.player?.currentItem === item
        else { return }
        self.state.status = .paused
        self.enqueueEvent(.reachedEnd, generation: generation)
      }
    }
  }

  private func enqueueEvent(_ event: PlaybackEngineEvent, generation: Int) {
    let predecessor = eventDeliveryTask
    let handler = eventHandler
    eventDeliveryTask = Task { @MainActor [weak self] in
      await predecessor?.value
      guard let self, self.observerGeneration == generation else { return }
      await handler?(event)
    }
  }

  private func removePlaybackObservers() {
    observerGeneration += 1
    if let periodicTimeObserver, let player {
      player.removeTimeObserver(periodicTimeObserver)
    }
    periodicTimeObserver = nil
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    endObserver = nil
  }
}

@MainActor
final class DeterministicPlaybackController: AudioPlaybackControlling {
  private(set) var state: PlaybackState
  private(set) var loadedURL: URL?
  private(set) var playbackRate = 1.0
  private var eventHandler: (@MainActor @Sendable (PlaybackEngineEvent) async -> Void)?

  init(state: PlaybackState = .unloaded) {
    self.state = state
  }

  var currentPositionSeconds: Double { state.elapsedSeconds }

  func installEventHandler(
    _ handler: @escaping @MainActor @Sendable (PlaybackEngineEvent) async -> Void
  ) {
    eventHandler = handler
  }

  func load(url: URL, bookID: UUID, at seconds: Double) async throws {
    loadedURL = url
    state = PlaybackState(status: .paused, loadedBookID: bookID, elapsedSeconds: seconds)
  }

  func unload() {
    loadedURL = nil
    state = .unloaded
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

  func send(_ event: PlaybackEngineEvent) async {
    guard state.loadedBookID != nil else { return }
    switch event {
    case .progress(let seconds):
      guard state.status == .playing, seconds.isFinite else { return }
      state.elapsedSeconds = max(0, seconds)
    case .reachedEnd:
      state.status = .paused
    }
    await eventHandler?(event)
  }
}

@MainActor
protocol AudioSessionPlatform: AnyObject {
  var notificationObject: AnyObject { get }
  func configureForSpokenAudio(options: AVAudioSession.CategoryOptions) throws
  func activate() throws
}

@MainActor
final class SystemAudioSessionPlatform: AudioSessionPlatform {
  private let session: AVAudioSession

  init(session: AVAudioSession = .sharedInstance()) {
    self.session = session
  }

  var notificationObject: AnyObject { session }

  func configureForSpokenAudio(options: AVAudioSession.CategoryOptions) throws {
    try session.setCategory(.playback, mode: .spokenAudio, options: options)
  }

  func activate() throws {
    try session.setActive(true)
  }
}

enum AudioSessionNotificationKind: String, CaseIterable, Sendable {
  case interruption
  case routeChange = "route-change"

  var notificationName: Notification.Name {
    switch self {
    case .interruption: AVAudioSession.interruptionNotification
    case .routeChange: AVAudioSession.routeChangeNotification
    }
  }
}

struct AudioSessionNotificationPayload: Sendable {
  var interruptionType: UInt?
  var interruptionOptions: UInt?
  var routeChangeReason: UInt?

  init(
    interruptionType: UInt? = nil,
    interruptionOptions: UInt? = nil,
    routeChangeReason: UInt? = nil
  ) {
    self.interruptionType = interruptionType
    self.interruptionOptions = interruptionOptions
    self.routeChangeReason = routeChangeReason
  }

  init(notification: Notification) {
    interruptionType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
    interruptionOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
    routeChangeReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
  }
}

protocol AudioSessionNotificationObservation: AnyObject {}

@MainActor
protocol AudioSessionNotificationSource: AnyObject {
  func observe(
    _ kind: AudioSessionNotificationKind,
    object: AnyObject,
    using handler: @escaping @Sendable (AudioSessionNotificationPayload) -> Void
  ) -> any AudioSessionNotificationObservation
}

private final class NotificationCenterAudioSessionObservation:
  AudioSessionNotificationObservation,
  @unchecked Sendable
{
  private let center: NotificationCenter
  private let token: NSObjectProtocol

  init(center: NotificationCenter, token: NSObjectProtocol) {
    self.center = center
    self.token = token
  }

  deinit {
    center.removeObserver(token)
  }
}

@MainActor
final class NotificationCenterAudioSessionSource: AudioSessionNotificationSource {
  private let center: NotificationCenter

  init(center: NotificationCenter = .default) {
    self.center = center
  }

  func observe(
    _ kind: AudioSessionNotificationKind,
    object: AnyObject,
    using handler: @escaping @Sendable (AudioSessionNotificationPayload) -> Void
  ) -> any AudioSessionNotificationObservation {
    let token = center.addObserver(
      forName: kind.notificationName,
      object: object,
      queue: nil
    ) { notification in
      handler(AudioSessionNotificationPayload(notification: notification))
    }
    return NotificationCenterAudioSessionObservation(center: center, token: token)
  }
}

@MainActor
final class AVAudioSessionController: AudioSessionControlling {
  // Playback sessions already route to AirPlay and Bluetooth A2DP. Apple only
  // permits explicitly setting those options with `.playAndRecord`; combining
  // them with `.playback` causes `setCategory` to fail with OSStatus -50.
  static let playbackCategoryOptions: AVAudioSession.CategoryOptions = []

  private let platform: any AudioSessionPlatform
  private let notificationSource: any AudioSessionNotificationSource
  private var notificationObservations: [any AudioSessionNotificationObservation] = []
  private var eventHandler: (@MainActor @Sendable (AudioSessionEvent) async -> Void)?

  convenience init(session: AVAudioSession = .sharedInstance()) {
    self.init(
      platform: SystemAudioSessionPlatform(session: session),
      notificationSource: NotificationCenterAudioSessionSource()
    )
  }

  init(
    platform: any AudioSessionPlatform,
    notificationSource: any AudioSessionNotificationSource
  ) {
    self.platform = platform
    self.notificationSource = notificationSource
    notificationObservations = [
      notificationSource.observe(
        .interruption,
        object: platform.notificationObject
      ) { [weak self] payload in
        Task { @MainActor [weak self] in
          self?.handleInterruptionNotification(payload)
        }
      },
      notificationSource.observe(
        .routeChange,
        object: platform.notificationObject
      ) { [weak self] payload in
        Task { @MainActor [weak self] in
          self?.handleRouteChangeNotification(payload)
        }
      },
    ]
  }

  func configure() throws {
    try platform.configureForSpokenAudio(options: Self.playbackCategoryOptions)
  }

  func activate() throws {
    try platform.activate()
  }

  func installEventHandler(
    _ handler: @escaping @MainActor @Sendable (AudioSessionEvent) async -> Void
  ) {
    eventHandler = handler
  }

  private func handleInterruptionNotification(_ payload: AudioSessionNotificationPayload) {
    guard
      let rawType = payload.interruptionType,
      let type = AVAudioSession.InterruptionType(rawValue: rawType)
    else { return }

    let event: AudioSessionEvent
    switch type {
    case .began:
      event = .interruptionBegan
    case .ended:
      let rawOptions = payload.interruptionOptions ?? 0
      event = .interruptionEnded(
        shouldResume: AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
      )
    @unknown default:
      return
    }
    guard let eventHandler else { return }
    Task { await eventHandler(event) }
  }

  private func handleRouteChangeNotification(_ payload: AudioSessionNotificationPayload) {
    guard
      let rawReason = payload.routeChangeReason,
      AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
    else { return }
    guard let eventHandler else { return }
    Task { await eventHandler(.oldDeviceUnavailable) }
  }
}

enum RemoteCommandRegistration: String, CaseIterable, Sendable {
  case play
  case pause
  case toggle
  case previousTrack = "previous-track-skip-backward"
  case nextTrack = "next-track-skip-forward"
  case skipForward = "skip-forward"
  case skipBackward = "skip-backward"
  case changePosition = "change-position"
  case changeRate = "change-rate"
}

struct RemoteCommandInvocation: Sendable {
  var interval: Double?
  var positionTime: Double?
  var playbackRate: Double?

  init(
    interval: Double? = nil,
    positionTime: Double? = nil,
    playbackRate: Double? = nil
  ) {
    self.interval = interval
    self.positionTime = positionTime
    self.playbackRate = playbackRate
  }
}

enum RemoteCommandDispatchResult {
  case success
  case commandFailed
}

@MainActor
protocol RemoteCommandCenterSource: AnyObject {
  func beginReceivingRemoteControlEvents()
  func setEnabled(_ enabled: Bool, for command: RemoteCommandRegistration)
  func addTarget(
    for command: RemoteCommandRegistration,
    handler: @escaping (RemoteCommandInvocation) -> RemoteCommandDispatchResult
  ) -> Any
  func removeTarget(_ target: Any, for command: RemoteCommandRegistration)
  func setPreferredIntervals(_ intervals: [Double], for command: RemoteCommandRegistration)
  func setSupportedPlaybackRates(_ rates: [Double])
}

@MainActor
final class SystemRemoteCommandCenterSource: RemoteCommandCenterSource {
  private let center: MPRemoteCommandCenter

  init(center: MPRemoteCommandCenter = .shared()) {
    self.center = center
  }

  func beginReceivingRemoteControlEvents() {
    UIApplication.shared.beginReceivingRemoteControlEvents()
  }

  func setEnabled(_ enabled: Bool, for command: RemoteCommandRegistration) {
    mediaCommand(for: command).isEnabled = enabled
  }

  func addTarget(
    for command: RemoteCommandRegistration,
    handler: @escaping (RemoteCommandInvocation) -> RemoteCommandDispatchResult
  ) -> Any {
    mediaCommand(for: command).addTarget { event in
      let invocation = RemoteCommandInvocation(
        interval: (event as? MPSkipIntervalCommandEvent)?.interval,
        positionTime: (event as? MPChangePlaybackPositionCommandEvent)?.positionTime,
        playbackRate: (event as? MPChangePlaybackRateCommandEvent).map {
          Double($0.playbackRate)
        }
      )
      switch handler(invocation) {
      case .success: return .success
      case .commandFailed: return .commandFailed
      }
    }
  }

  func removeTarget(_ target: Any, for command: RemoteCommandRegistration) {
    mediaCommand(for: command).removeTarget(target)
  }

  func setPreferredIntervals(_ intervals: [Double], for command: RemoteCommandRegistration) {
    guard let command = mediaCommand(for: command) as? MPSkipIntervalCommand else { return }
    command.preferredIntervals = intervals.map(NSNumber.init(value:))
  }

  func setSupportedPlaybackRates(_ rates: [Double]) {
    center.changePlaybackRateCommand.supportedPlaybackRates = rates.map(NSNumber.init(value:))
  }

  private func mediaCommand(for registration: RemoteCommandRegistration) -> MPRemoteCommand {
    switch registration {
    case .play: center.playCommand
    case .pause: center.pauseCommand
    case .toggle: center.togglePlayPauseCommand
    case .previousTrack: center.previousTrackCommand
    case .nextTrack: center.nextTrackCommand
    case .skipForward: center.skipForwardCommand
    case .skipBackward: center.skipBackwardCommand
    case .changePosition: center.changePlaybackPositionCommand
    case .changeRate: center.changePlaybackRateCommand
    }
  }
}

@MainActor
final class MPRemoteCommandController: RemoteCommandControlling {
  private let source: any RemoteCommandCenterSource
  private var installedTargets: [(RemoteCommandRegistration, Any)] = []
  private var transportPreferences: TransportPreferences = .default

  convenience init(center: MPRemoteCommandCenter = .shared()) {
    self.init(source: SystemRemoteCommandCenterSource(center: center))
  }

  init(source: any RemoteCommandCenterSource) {
    self.source = source
  }

  func installCommandHandler(
    _ handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  ) {
    source.beginReceivingRemoteControlEvents()
    removeInstalledTargets()
    install(.play, event: .play, handler: handler)
    install(.pause, event: .pause, handler: handler)
    install(.toggle, event: .togglePlayPause, handler: handler)
    install(.previousTrack, trackButton: .previous, handler: handler)
    install(.nextTrack, trackButton: .next, handler: handler)

    updateTransportConfiguration(transportPreferences)
    source.setEnabled(true, for: .skipForward)
    let forwardTarget = source.addTarget(for: .skipForward) { invocation in
      let seconds = invocation.interval ?? self.transportPreferences.forwardSkipSeconds
      Task { @MainActor in await handler(.skipForward(seconds: seconds)) }
      return .success
    }
    installedTargets.append((.skipForward, forwardTarget))
    source.setEnabled(true, for: .skipBackward)
    let backwardTarget = source.addTarget(for: .skipBackward) { invocation in
      let seconds = invocation.interval ?? self.transportPreferences.backwardSkipSeconds
      Task { @MainActor in await handler(.skipBackward(seconds: seconds)) }
      return .success
    }
    installedTargets.append((.skipBackward, backwardTarget))
    source.setEnabled(true, for: .changePosition)
    let positionTarget = source.addTarget(for: .changePosition) { invocation in
      guard let seconds = invocation.positionTime else {
        return .commandFailed
      }
      Task { @MainActor in await handler(.changePosition(seconds: seconds)) }
      return .success
    }
    installedTargets.append((.changePosition, positionTarget))
    source.setEnabled(true, for: .changeRate)
    let rateTarget = source.addTarget(for: .changeRate) { invocation in
      guard let rate = invocation.playbackRate else {
        return .commandFailed
      }
      Task { @MainActor in await handler(.changePlaybackRate(rate)) }
      return .success
    }
    installedTargets.append((.changeRate, rateTarget))
  }

  func updateTransportConfiguration(_ preferences: TransportPreferences) {
    guard preferences.isValid else { return }
    transportPreferences = preferences
    source.setPreferredIntervals([preferences.forwardSkipSeconds], for: .skipForward)
    source.setPreferredIntervals([preferences.backwardSkipSeconds], for: .skipBackward)
    source.setSupportedPlaybackRates(stride(
      from: 0.5,
      through: 3.0,
      by: 0.05
    ).map { $0 })
  }

  private func install(
    _ command: RemoteCommandRegistration,
    event: RemotePlaybackCommand,
    handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  ) {
    source.setEnabled(true, for: command)
    let target = source.addTarget(for: command) { _ in
      Task { @MainActor in await handler(event) }
      return .success
    }
    installedTargets.append((command, target))
  }

  private func install(
    _ command: RemoteCommandRegistration,
    trackButton: RemoteTrackButton,
    handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
  ) {
    source.setEnabled(true, for: command)
    let target = source.addTarget(for: command) { _ in
      let event = trackButton.playbackCommand(using: self.transportPreferences)
      Task { @MainActor in await handler(event) }
      return .success
    }
    installedTargets.append((command, target))
  }

  private func removeInstalledTargets() {
    for (command, target) in installedTargets {
      source.removeTarget(target, for: command)
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
