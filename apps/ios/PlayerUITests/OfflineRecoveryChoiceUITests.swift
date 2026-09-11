import XCTest

@MainActor
final class OfflineRecoveryChoiceUITests: PlayerUITestCase {
  func testFreshLibraryAndDistinctRecoveryExplanations() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try proveFreshLibraryPreservesRecoveryMaterial()
    try proveDistinctRecoveryExplanations()
  }
}
