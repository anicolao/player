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
    }
  }
}
