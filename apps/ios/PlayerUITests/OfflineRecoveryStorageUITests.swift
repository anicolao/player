import XCTest

@MainActor
final class OfflineRecoveryStorageUITests: PlayerUITestCase {
  func testProtectedStorageCanBeRetriedAtLaunch() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try proveLaunchStorageRetry()
  }
}
