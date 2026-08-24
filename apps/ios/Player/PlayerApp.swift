import SwiftUI
import UIKit

@main
struct PlayerApp: App {
  @State private var model: PlayerModel?
  @State private var launchErrorMessage: String?

  init() {
    #if E2E
      UIView.setAnimationsEnabled(false)
    #endif
    do {
      _model = State(
        initialValue: PlayerModel(environment: try PlayerEnvironment.launchEnvironment())
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
          ContentView(model: model)
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
      model = PlayerModel(environment: try PlayerEnvironment.launchEnvironment())
      launchErrorMessage = nil
    } catch {
      launchErrorMessage = error.localizedDescription
    }
  }

  #if E2E
    private var e2eDynamicTypeSize: DynamicTypeSize {
      switch ProcessInfo.processInfo.environment["PLAYER_E2E_DYNAMIC_TYPE"] {
      case "accessibility5": .accessibility5
      case "large": .large
      default: .medium
      }
    }
  #endif
}

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
