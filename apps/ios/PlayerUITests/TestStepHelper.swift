import XCTest

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
      let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false"),
        object: element
      )
      return XCTWaiter.wait(
        for: [expectation],
        timeout: TestStepHelper.conditionTimeout
      ) == .completed
    }
  }

  static func valueEquals(
    _ element: XCUIElement,
    _ expectedValue: String,
    _ specification: String
  ) -> StepVerification {
    StepVerification(specification: specification) {
      let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", expectedValue),
        object: element
      )
      return XCTWaiter.wait(
        for: [expectation],
        timeout: TestStepHelper.conditionTimeout
      ) == .completed
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
    additionalPreconditions: []
  )
  private var steps: [Step] = []
  private var nextScreenshotIndex = 0

  init(testCase: XCTestCase) {
    self.testCase = testCase
  }

  func setMetadata(
    title: String,
    narrative: String,
    fixture: String,
    additionalPreconditions: [String] = []
  ) {
    metadata = StoryMetadata(
      title: title,
      narrative: narrative,
      fixture: fixture,
      additionalPreconditions: additionalPreconditions
    )
  }

  func step(
    _ identifier: String,
    description: String,
    verifications: [StepVerification]
  ) throws {
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

    let screenshot = stableScreenshot()
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

  private func stableScreenshot() -> XCUIScreenshot {
    var previous = XCUIScreen.main.screenshot()
    var previousPixels = previous.image.pngData()

    for _ in 0..<20 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      let current = XCUIScreen.main.screenshot()
      let currentPixels = current.image.pngData()
      if currentPixels == previousPixels {
        return current
      }
      previous = current
      previousPixels = currentPixels
    }

    XCTFail("The screen did not reach two consecutive pixel-identical frames")
    return previous
  }

  func generateDocs() {
    let readme = """
      # Test: \(metadata.title)

      > \(metadata.narrative)

      ## Deterministic preconditions

      - Fixture: `\(metadata.fixture)`
      - Xcode: 26.6
      - Device: iPhone 17 on iOS 26.5, portrait, light appearance, standard Dynamic Type
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
}

private struct Step {
  let description: String
  let filename: String
  let verifications: [String]
}
