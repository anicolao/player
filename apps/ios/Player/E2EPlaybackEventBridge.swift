#if E2E
  import Foundation
  import Observation

  @MainActor
  @Observable
  final class E2EPlaybackEventBridge {
    static let shared = E2EPlaybackEventBridge()

    @ObservationIgnored
    private var remoteHandler: (@MainActor @Sendable (RemotePlaybackCommand) async -> Void)?
    @ObservationIgnored
    private var audioSessionHandler: (@MainActor @Sendable (AudioSessionEvent) async -> Void)?

    private(set) var registeredCommands: Set<String> = []

    func reset() {
      remoteHandler = nil
      audioSessionHandler = nil
      registeredCommands = []
    }

    func installRemoteHandler(
      _ handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
    ) {
      remoteHandler = handler
      registeredCommands = [
        "change-position", "change-rate", "next-track-skip-forward", "pause", "play",
        "previous-track-skip-backward", "skip-backward", "skip-forward", "toggle",
      ]
    }

    func installAudioSessionHandler(
      _ handler: @escaping @MainActor @Sendable (AudioSessionEvent) async -> Void
    ) {
      audioSessionHandler = handler
    }

    func sendRemote(_ command: RemotePlaybackCommand) async {
      await remoteHandler?(command)
    }

    func sendAudioSession(_ event: AudioSessionEvent) async {
      await audioSessionHandler?(event)
    }
  }

  @MainActor
  final class E2EAudioSessionController: AudioSessionControlling {
    private let bridge: E2EPlaybackEventBridge

    init(bridge: E2EPlaybackEventBridge = .shared) {
      self.bridge = bridge
    }

    func configure() throws {}
    func activate() throws {}

    func installEventHandler(
      _ handler: @escaping @MainActor @Sendable (AudioSessionEvent) async -> Void
    ) {
      bridge.installAudioSessionHandler(handler)
    }
  }

  @MainActor
  final class E2ERemoteCommandController: RemoteCommandControlling {
    private let bridge: E2EPlaybackEventBridge

    init(bridge: E2EPlaybackEventBridge = .shared) {
      self.bridge = bridge
    }

    func installCommandHandler(
      _ handler: @escaping @MainActor @Sendable (RemotePlaybackCommand) async -> Void
    ) {
      bridge.installRemoteHandler(handler)
    }
  }
#endif
