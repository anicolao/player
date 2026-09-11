import XCTest

@MainActor
final class OfflineRecoverySupportUITests: PlayerUITestCase {
  func testSupportBundleSaveCancelAndPreparationFailure() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try proveSupportBundleExportOutcomes()
  }
}
