#if E2E
  import AVFAudio
  import Foundation
  import Observation

  private final class E2ERemoteCommandTarget {}
  private final class E2EAudioSessionObservation: AudioSessionNotificationObservation {}

  @MainActor
  @Observable
  final class E2EPlaybackEventBridge:
    AudioSessionPlatform,
    AudioSessionNotificationSource,
    RemoteCommandCenterSource
  {
    static let shared = E2EPlaybackEventBridge()

    @ObservationIgnored
    private var remoteTargets: [
      RemoteCommandRegistration: (
        target: E2ERemoteCommandTarget,
        handler: (RemoteCommandInvocation) -> RemoteCommandDispatchResult
      )
    ] = [:]
    @ObservationIgnored
    private var audioNotificationHandlers: [
      AudioSessionNotificationKind: @Sendable (AudioSessionNotificationPayload) -> Void
    ] = [:]

    private(set) var registeredCommands: Set<String> = []
    private(set) var registeredAudioNotifications: Set<String> = []
    private(set) var audioConfigureCount = 0
    private(set) var audioActivationCount = 0
    private(set) var latestPostedAudioEvent = "none"
    private(set) var beganReceivingRemoteControlEvents = false

    var notificationObject: AnyObject { self }

    func reset() {
      remoteTargets = [:]
      audioNotificationHandlers = [:]
      registeredCommands = []
      registeredAudioNotifications = []
      audioConfigureCount = 0
      audioActivationCount = 0
      latestPostedAudioEvent = "none"
      beganReceivingRemoteControlEvents = false
    }

    func configureForSpokenAudio(options: AVAudioSession.CategoryOptions) throws {
      guard options == AVAudioSessionController.playbackCategoryOptions else {
        throw E2EPlaybackBridgeError.unexpectedAudioCategoryOptions
      }
      audioConfigureCount += 1
    }

    func activate() throws {
      audioActivationCount += 1
    }

    func observe(
      _ kind: AudioSessionNotificationKind,
      object: AnyObject,
      using handler: @escaping @Sendable (AudioSessionNotificationPayload) -> Void
    ) -> any AudioSessionNotificationObservation {
      guard object === self else {
        return E2EAudioSessionObservation()
      }
      audioNotificationHandlers[kind] = handler
      registeredAudioNotifications.insert(kind.rawValue)
      return E2EAudioSessionObservation()
    }

    func beginReceivingRemoteControlEvents() {
      beganReceivingRemoteControlEvents = true
    }

    func setEnabled(_ enabled: Bool, for command: RemoteCommandRegistration) {
      if !enabled {
        registeredCommands.remove(command.rawValue)
      }
    }

    func addTarget(
      for command: RemoteCommandRegistration,
      handler: @escaping (RemoteCommandInvocation) -> RemoteCommandDispatchResult
    ) -> Any {
      let target = E2ERemoteCommandTarget()
      remoteTargets[command] = (target, handler)
      registeredCommands.insert(command.rawValue)
      return target
    }

    func removeTarget(_ target: Any, for command: RemoteCommandRegistration) {
      guard
        let target = target as? E2ERemoteCommandTarget,
        remoteTargets[command]?.target === target
      else { return }
      remoteTargets.removeValue(forKey: command)
      registeredCommands.remove(command.rawValue)
    }

    func setPreferredIntervals(_ intervals: [Double], for command: RemoteCommandRegistration) {}
    func setSupportedPlaybackRates(_ rates: [Double]) {}

    @discardableResult
    func sendRemote(
      _ command: RemoteCommandRegistration,
      invocation: RemoteCommandInvocation = RemoteCommandInvocation()
    ) -> RemoteCommandDispatchResult {
      guard let target = remoteTargets[command] else { return .commandFailed }
      return target.handler(invocation)
    }

    func sendAudioSession(_ event: AudioSessionEvent) {
      let kind: AudioSessionNotificationKind
      let payload: AudioSessionNotificationPayload
      switch event {
      case .interruptionBegan:
        kind = .interruption
        latestPostedAudioEvent = "interruption-began"
        payload = AudioSessionNotificationPayload(
          interruptionType: AVAudioSession.InterruptionType.began.rawValue
        )
      case .interruptionEnded(let shouldResume):
        kind = .interruption
        latestPostedAudioEvent = shouldResume
          ? "interruption-ended-resume"
          : "interruption-ended-no-resume"
        payload = AudioSessionNotificationPayload(
          interruptionType: AVAudioSession.InterruptionType.ended.rawValue,
          interruptionOptions: shouldResume
            ? AVAudioSession.InterruptionOptions.shouldResume.rawValue
            : 0
        )
      case .oldDeviceUnavailable:
        kind = .routeChange
        latestPostedAudioEvent = "old-device-unavailable"
        payload = AudioSessionNotificationPayload(
          routeChangeReason: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        )
      }
      audioNotificationHandlers[kind]?(payload)
    }

    var audioSessionEvidence: String {
      let observers = registeredAudioNotifications.sorted().joined(separator: ",")
      return [
        "configured=\(audioConfigureCount)",
        "activated=\(audioActivationCount)",
        "observers=\(observers)",
        "posted=\(latestPostedAudioEvent)",
      ].joined(separator: ":")
    }
  }

  private enum E2EPlaybackBridgeError: Error {
    case unexpectedAudioCategoryOptions
  }
#endif
