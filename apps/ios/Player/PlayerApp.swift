import SwiftUI
import UIKit

@main
struct PlayerApp: App {
  @State private var model: PlayerModel?
  @State private var launchErrorMessage: String?
  private let applicationLifecycle: ApplicationLifecycleCoordinator
  private let e2eLaunchConfiguration: E2ELaunchConfiguration?
  private let receiverConfiguration: E2EComputerReceiverLaunchConfiguration
  private let launchNavigation: E2ELaunchNavigationConfiguration
  private let playbackControls: E2EPlaybackControlConfiguration
  #if E2E
    @State private var e2eDynamicTypeSize: DynamicTypeSize
  #endif

  init() {
    applicationLifecycle = ApplicationLifecycleCoordinator()
    #if E2E
      UIView.setAnimationsEnabled(false)
      do {
        e2eLaunchConfiguration = try E2ELaunchConfiguration.parse(
          arguments: ProcessInfo.processInfo.arguments
        )
      } catch {
        e2eLaunchConfiguration = nil
        receiverConfiguration = .production
        launchNavigation = .library
        playbackControls = .disabled
        _e2eDynamicTypeSize = State(initialValue: .medium)
        _model = State(initialValue: nil)
        _launchErrorMessage = State(initialValue: error.localizedDescription)
        return
      }
      do {
        receiverConfiguration = try E2EComputerReceiverLaunchConfiguration.parse(
          arguments: ProcessInfo.processInfo.arguments,
          e2eLaunchConfiguration: e2eLaunchConfiguration
        )
      } catch {
        receiverConfiguration = .production
        launchNavigation = .library
        playbackControls = .disabled
        _e2eDynamicTypeSize = State(initialValue: .medium)
        _model = State(initialValue: nil)
        _launchErrorMessage = State(initialValue: error.localizedDescription)
        return
      }
      do {
        launchNavigation = try E2ELaunchNavigationConfiguration.parse(
          arguments: ProcessInfo.processInfo.arguments
        )
      } catch {
        launchNavigation = .library
        playbackControls = .disabled
        _e2eDynamicTypeSize = State(initialValue: .medium)
        _model = State(initialValue: nil)
        _launchErrorMessage = State(initialValue: error.localizedDescription)
        return
      }
      do {
        playbackControls = try E2EPlaybackControlConfiguration.parse(
          arguments: ProcessInfo.processInfo.arguments
        )
      } catch {
        playbackControls = .disabled
        _e2eDynamicTypeSize = State(initialValue: .medium)
        _model = State(initialValue: nil)
        _launchErrorMessage = State(initialValue: error.localizedDescription)
        return
      }
      do {
        _e2eDynamicTypeSize = State(
          initialValue: try E2EDynamicTypeConfiguration.parse(
            environment: ProcessInfo.processInfo.environment
          ).dynamicTypeSize
        )
      } catch {
        _e2eDynamicTypeSize = State(initialValue: .medium)
        _model = State(initialValue: nil)
        _launchErrorMessage = State(initialValue: error.localizedDescription)
        return
      }
    #else
      e2eLaunchConfiguration = nil
      receiverConfiguration = .production
      launchNavigation = .library
      playbackControls = .disabled
    #endif
    do {
      let environment = try PlayerEnvironment.launchEnvironment(
        e2eLaunchConfiguration: e2eLaunchConfiguration,
        playbackControls: playbackControls
      )
      let launchedModel = PlayerModel(environment: environment)
      applicationLifecycle.bind(to: launchedModel)
      _model = State(initialValue: launchedModel)
      _launchErrorMessage = State(initialValue: nil)
    } catch {
      _model = State(initialValue: nil)
      _launchErrorMessage = State(initialValue: error.localizedDescription)
    }
  }

  var body: some Scene {
    WindowGroup {
      Group {
        if let model {
          ContentView(
            model: model,
            receiverConfiguration: receiverConfiguration,
            launchNavigation: launchNavigation,
            playbackControls: playbackControls
          )
        } else {
          LaunchStorageUnavailableView(
            detail: launchErrorMessage,
            retry: retryLaunchEnvironment
          )
        }
      }
        .preferredColorScheme(.light)
        .tint(PlayerColor.accent)
        #if E2E
          // Simulator preference propagation can lag on hosted runners. Pin the
          // app environment so canonical screenshots exercise the documented
          // size instead of whichever category the fresh host reports first.
          .dynamicTypeSize(e2eDynamicTypeSize)
        #endif
    }
  }

  private func retryLaunchEnvironment() {
    do {
      let replacementModel = PlayerModel(
        environment: try PlayerEnvironment.launchEnvironment(
          e2eLaunchConfiguration: e2eLaunchConfiguration,
          playbackControls: playbackControls
        )
      )
      applicationLifecycle.bind(to: replacementModel)
      model = replacementModel
      launchErrorMessage = nil
    } catch {
      launchErrorMessage = error.localizedDescription
    }
  }

}

@MainActor
private final class ApplicationLifecycleCoordinator: NSObject {
  private weak var model: PlayerModel?

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillResignActive(_:)),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidEnterBackground(_:)),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive(_:)),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func bind(to model: PlayerModel) {
    self.model = model
  }

  @objc private func applicationWillResignActive(_ notification: Notification) {
    #if E2E
      E2ELifecycleEvent.postSceneBecameInactive()
    #endif
    guard let model else { return }
    // UIApplication publishes this notification synchronously before UIKit's
    // background snapshot work. Begin durability here rather than depending on
    // SwiftUI to render an intermediate scenePhase value under load.
    model.prepareBackgroundCheckpoint()
    #if E2E
      Task { @MainActor in
        await model.waitForPreparedBackgroundCheckpoint()
        E2ELifecycleEvent.postBackgroundCheckpointCompleted()
      }
    #endif
  }

  @objc private func applicationDidEnterBackground(_ notification: Notification) {
    #if E2E
      E2ELifecycleEvent.postSceneBecameBackground()
    #endif
    guard let model else { return }
    Task { @MainActor in
      await model.checkpointForBackground()
      #if E2E
        E2ELifecycleEvent.postBackgroundCheckpointCompleted()
      #endif
    }
  }

  @objc private func applicationDidBecomeActive(_ notification: Notification) {
    model?.invalidatePreparedBackgroundCheckpoint()
  }
}

#if E2E
  enum E2EDynamicTypeConfiguration: String, CaseIterable {
    static let environmentKey = "PLAYER_E2E_DYNAMIC_TYPE"

    case medium
    case large
    case accessibility5

    static func parse(environment: [String: String]) throws -> Self {
      guard let value = environment[environmentKey] else { return .medium }
      guard let configuration = Self(rawValue: value) else {
        throw PlayerCoreError.fileOperation("Invalid E2E Dynamic Type value: \(value)")
      }
      return configuration
    }

    var dynamicTypeSize: DynamicTypeSize {
      switch self {
      case .medium: .medium
      case .large: .large
      case .accessibility5: .accessibility5
      }
    }
  }
#endif

private struct LaunchStorageUnavailableView: View {
  let detail: String?
  let retry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Local Storage Unavailable", systemImage: "externaldrive.badge.exclamationmark")
    } description: {
      Text(
        "Bookshelf could not reach its private local folder. No library files were changed."
      )
    } actions: {
      Button("Try Again", action: retry)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("launch-storage-retry")
    }
    .accessibilityIdentifier("launch-storage-unavailable")
    .accessibilityValue(detail == nil ? "unavailable" : "unavailable:detail")
  }
}
