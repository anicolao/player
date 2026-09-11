import XCTest

@MainActor
final class OfflineRecoveryRetryUITests: PlayerUITestCase {
  func testAutomaticRetryAndPersistentFailureRemainSafe() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    try proveAutomaticRetrySuccess(scenario: "retry-succeeds")
    try proveAutomaticRetrySuccess(scenario: "transient-storage-unavailable")
    try proveRetryRemainsFailedWithoutMutation()
  }
}
