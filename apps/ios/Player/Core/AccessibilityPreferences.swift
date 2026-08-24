import Foundation

struct AccessibilityPreferences: Codable, Equatable, Sendable {
  var prefersHighContrast: Bool
  var reducesDecorativeArtwork: Bool

  static let `default` = AccessibilityPreferences(
    prefersHighContrast: false,
    reducesDecorativeArtwork: false
  )
}
