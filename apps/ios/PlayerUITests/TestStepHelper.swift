import XCTest

@MainActor
func dismissAppleIntelligenceNotificationIfPresent(
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
  let notificationTitle = springboard.staticTexts["Ready for Apple Intelligence"]
  guard notificationTitle.waitForExistence(timeout: 0.5) else { return }
  notificationTitle.swipeUp()
  XCTAssertTrue(
    waitForPredicate(
      NSPredicate(format: "exists == false"),
      on: notificationTitle,
      timeout: 1
    ),
    "The simulator's Apple Intelligence notification should not obscure the walkthrough",
    file: file,
    line: line
  )
}

@MainActor
func waitForPredicate(
  _ predicate: NSPredicate,
  on element: XCUIElement,
  timeout: TimeInterval = TestStepHelper.conditionTimeout
) -> Bool {
  if predicate.evaluate(with: element) { return true }
  let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
  _ = XCTWaiter.wait(for: [expectation], timeout: timeout)
  return predicate.evaluate(with: element)
}

@MainActor
extension XCUIElement {
  func waitForStringValue(_ expectedValue: String, timeout: TimeInterval) -> Bool {
    if currentStringValue == expectedValue { return true }
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true AND value == %@", expectedValue),
      object: self
    )
    if XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed { return true }
    return currentStringValue == expectedValue
  }

  fileprivate var currentStringValue: String? {
    guard exists else { return nil }
    return value.map(String.init(describing:))
  }
}

@MainActor
func scrollUntil(
  _ condition: @escaping () -> Bool,
  tracking element: XCUIElement,
  timeout: TimeInterval = TestStepHelper.conditionTimeout,
  gesture: () -> Void
) -> Bool {
  if condition() { return true }

  let deadline = Date().addingTimeInterval(timeout)
  var previousGeometry = scrollGeometry(of: element)
  while Date() < deadline {
    gesture()
    if condition() { return true }

    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { break }
    let geometryBeforeWait = previousGeometry
    let progressed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        condition() || scrollGeometry(of: element) != geometryBeforeWait
      },
      object: element
    )
    _ = XCTWaiter.wait(for: [progressed], timeout: remaining)
    if condition() { return true }

    let currentGeometry = scrollGeometry(of: element)
    guard currentGeometry != previousGeometry else {
      print(
        "Scroll made no progress: identifier=\(element.identifier), "
          + "geometry=\(currentGeometry)"
      )
      return false
    }
    previousGeometry = currentGeometry
  }
  return condition()
}

@MainActor
func scrollToSettledEnd(
  tracking element: XCUIElement,
  timeout: TimeInterval = TestStepHelper.conditionTimeout,
  gesture: () -> Void
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  var previousGeometry = scrollGeometry(of: element)
  while Date() < deadline {
    gesture()
    let currentGeometry = scrollGeometry(of: element)
    if currentGeometry == previousGeometry { return true }
    previousGeometry = currentGeometry
  }
  print(
    "Scroll did not reach a settled end: identifier=\(element.identifier), "
      + "latestGeometry=\(previousGeometry)"
  )
  return false
}

@MainActor
private func scrollGeometry(of element: XCUIElement) -> String {
  guard element.exists else { return "missing" }
  let frame = element.frame
  return [
    "x=\(frame.minX)",
    "y=\(frame.minY)",
    "maxX=\(frame.maxX)",
    "maxY=\(frame.maxY)",
  ].joined(separator: ":")
}

@MainActor
struct StepVerification {
  let specification: String
  let check: () -> Bool

  static func exists(
    _ element: XCUIElement,
    _ specification: String
  ) -> StepVerification {
    StepVerification(specification: specification) {
      element.waitForExistence(timeout: TestStepHelper.conditionTimeout)
    }
  }

  static func notExists(
    _ element: XCUIElement,
    _ specification: String
  ) -> StepVerification {
    StepVerification(specification: specification) {
      if !element.exists { return true }
      let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false"),
        object: element
      )
      if XCTWaiter.wait(
        for: [expectation],
        timeout: TestStepHelper.conditionTimeout
      ) == .completed { return true }
      return !element.exists
    }
  }

  static func valueEquals(
    _ element: XCUIElement,
    _ expectedValue: String,
    _ specification: String
  ) -> StepVerification {
    StepVerification(specification: specification) {
      if element.waitForStringValue(
        expectedValue,
        timeout: TestStepHelper.conditionTimeout
      ) {
        return true
      }
      let latest = element.value.map(String.init(describing:)) ?? "missing"
      print(
        "Value verification failed: identifier=\(element.identifier), "
          + "expected=\(expectedValue), latest=\(latest)"
      )
      return false
    }
  }

  static func valueContains(
    _ element: XCUIElement,
    _ expectedFragment: String,
    _ specification: String
  ) -> StepVerification {
    StepVerification(specification: specification) {
      if element.currentStringValue?.contains(expectedFragment) == true { return true }
      let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == true AND value CONTAINS %@", expectedFragment),
        object: element
      )
      if XCTWaiter.wait(
        for: [expectation], timeout: TestStepHelper.conditionTimeout
      ) == .completed { return true }
      if element.currentStringValue?.contains(expectedFragment) == true { return true }
      let latest = element.value.map(String.init(describing:)) ?? ""
      print(
        "Value verification failed: identifier=\(element.identifier), "
          + "expected fragment=\(expectedFragment), latest=\(latest)"
      )
      return false
    }
  }
}

@MainActor
final class TestStepHelper {
  static let conditionTimeout: TimeInterval = 2

  private unowned let testCase: XCTestCase
  private var metadata = StoryMetadata(
    title: "",
    narrative: "",
    fixture: "unspecified",
    additionalPreconditions: [],
    deviceConfiguration: "iPhone 17 on iOS 26.5, portrait, light appearance, standard Dynamic Type"
  )
  private var steps: [Step] = []
  private var nextScreenshotIndex = 0

  init(testCase: XCTestCase, startIndex: Int = 0) {
    self.testCase = testCase
    self.nextScreenshotIndex = startIndex
  }

  func setMetadata(
    title: String,
    narrative: String,
    fixture: String,
    additionalPreconditions: [String] = [],
    deviceConfiguration: String = "iPhone 17 on iOS 26.5, portrait, light appearance, standard Dynamic Type"
  ) {
    metadata = StoryMetadata(
      title: title,
      narrative: narrative,
      fixture: fixture,
      additionalPreconditions: additionalPreconditions,
      deviceConfiguration: deviceConfiguration
    )
  }

  func step(
    _ identifier: String,
    description: String,
    verifications: [StepVerification]
  ) throws {
    dismissAppleIntelligenceNotificationIfPresent()

    for verification in verifications {
      XCTAssertTrue(
        verification.check(),
        verification.specification,
        file: #filePath,
        line: #line
      )
    }

    let filename = String(format: "%03d-%@.png", nextScreenshotIndex, identifier)
    nextScreenshotIndex += 1

    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = filename
    attachment.lifetime = .keepAlways
    testCase.add(attachment)

    steps.append(
      Step(
        description: description,
        filename: filename,
        verifications: verifications.map(\.specification)
      )
    )
  }

  func generateDocs() {
    let readme = """
      # Test: \(metadata.title)

      > \(metadata.narrative)

      ## Deterministic preconditions

      - Fixture: `\(metadata.fixture)`
      - Xcode: 26.6
      - Device: \(metadata.deviceConfiguration)
      - Locale and time zone: `en_CA`, `America/Toronto`
      - Status bar: fixed at 9:41 AM, full battery, and full network indicators
      - Animations: disabled by the E2E build configuration
      - Network and clock data: unused by this story
      \(metadata.additionalPreconditions.map { "- \($0)" }.joined(separator: "\n"))

      \(steps.map(markdown).joined(separator: "\n\n"))
      """ + "\n"

    let attachment = XCTAttachment(
      data: Data(readme.utf8),
      uniformTypeIdentifier: "public.plain-text"
    )
    attachment.name = "README.md"
    attachment.lifetime = .keepAlways
    testCase.add(attachment)
  }

  private func markdown(_ step: Step) -> String {
    let checks = step.verifications.map { "- [x] \($0)" }.joined(separator: "\n")
    return """
      ## \(step.description)

      ![\(step.description)](./screenshots/ios/\(step.filename))

      **Verifications:**

      \(checks)
      """
  }
}

private struct StoryMetadata {
  let title: String
  let narrative: String
  let fixture: String
  let additionalPreconditions: [String]
  let deviceConfiguration: String
}

private struct Step {
  let description: String
  let filename: String
  let verifications: [String]
}
