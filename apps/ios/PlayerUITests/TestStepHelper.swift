import XCTest

@MainActor
extension XCUIElement {
  func waitForStringValue(_ expectedValue: String, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if exists, value.map(String.init(describing:)) == expectedValue {
        return true
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return false
  }
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
      let deadline = Date().addingTimeInterval(TestStepHelper.conditionTimeout)
      var latest = ""
      repeat {
        if element.exists {
          latest = element.value.map(String.init(describing:)) ?? ""
          if latest.contains(expectedFragment) { return true }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      } while Date() < deadline
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
    let requiredStableFrameCount = 5
    var previous = XCUIScreen.main.screenshot()
    var previousPixels = previous.image.pngData()
    var stableFrameCount = 1

    for _ in 0..<20 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      let current = XCUIScreen.main.screenshot()
      let currentPixels = current.image.pngData()
      if currentPixels == previousPixels {
        stableFrameCount += 1
        if stableFrameCount == requiredStableFrameCount {
          return current
        }
      } else {
        stableFrameCount = 1
      }
      previous = current
      previousPixels = currentPixels
    }

    XCTFail(
      "The screen did not reach \(requiredStableFrameCount) consecutive pixel-identical frames"
    )
    return previous
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
