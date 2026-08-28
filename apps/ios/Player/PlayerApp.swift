import SwiftUI
import UIKit

@main
struct PlayerApp: App {
  @State private var model: PlayerModel?
  @State private var launchErrorMessage: String?
  private let e2eLaunchConfiguration: E2ELaunchConfiguration?
  private let launchNavigation: E2ELaunchNavigationConfiguration
  private let playbackControls: E2EPlaybackControlConfiguration
  #if E2E
    @State private var e2eDynamicTypeSize: DynamicTypeSize
  #endif

  init() {
    #if E2E
      UIView.setAnimationsEnabled(false)
      do {
        e2eLaunchConfiguration = try E2ELaunchConfiguration.parse(
          arguments: ProcessInfo.processInfo.arguments
        )
      } catch {
        e2eLaunchConfiguration = nil
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
      launchNavigation = .library
      playbackControls = .disabled
    #endif
    do {
      let environment = try PlayerEnvironment.launchEnvironment(
        e2eLaunchConfiguration: e2eLaunchConfiguration,
        playbackControls: playbackControls
      )
      _model = State(
        initialValue: PlayerModel(environment: environment)
      )
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
      model = PlayerModel(environment: try PlayerEnvironment.launchEnvironment(
        e2eLaunchConfiguration: e2eLaunchConfiguration,
        playbackControls: playbackControls
      ))
      launchErrorMessage = nil
    } catch {
      launchErrorMessage = error.localizedDescription
    }
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
        "Player could not reach its private local folder. No library files were changed."
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
