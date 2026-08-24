import SwiftUI
import UIKit

@main
struct PlayerApp: App {
  @State private var model: PlayerModel

  init() {
    #if E2E
      UIView.setAnimationsEnabled(false)
    #endif
    do {
      _model = State(initialValue: PlayerModel(environment: try PlayerEnvironment.launchEnvironment()))
    } catch {
      fatalError("Player could not open local storage: \(error.localizedDescription)")
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .preferredColorScheme(.light)
        #if E2E
          // Simulator preference propagation can lag on hosted runners. Pin the
          // app environment so canonical screenshots exercise the documented
          // size instead of whichever category the fresh host reports first.
          .dynamicTypeSize(e2eDynamicTypeSize)
        #endif
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
