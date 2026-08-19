import SwiftUI
import UIKit

@main
struct PlayerApp: App {
  init() {
    #if E2E
      UIView.setAnimationsEnabled(false)
    #endif
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .preferredColorScheme(.light)
    }
  }
}

