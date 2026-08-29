import XCTest

enum E2EScrollAxis: String, Equatable {
  case horizontal
  case vertical
}

struct ScrollReadinessState {
  let containerID: String
  let axis: E2EScrollAxis
  let interactionID: Int
  let completionID: Int
  let geometryID: Int
  let completionGeometryID: Int
  let geometryReady: Bool
  let isIdle: Bool
  let atLeft: Bool
  let atRight: Bool
  let atTop: Bool
  let atBottom: Bool
  let offset: Double
  let minimum: Double
  let maximum: Double
  let contentLength: Double
  let containerLength: Double

  var hasScrollableRange: Bool { maximum - minimum > 1 }
  var atEnd: Bool { axis == .horizontal ? atRight : atBottom }

  init?(_ rawValue: Any?) {
    guard let value = rawValue as? String else { return nil }
    let tokens = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard tokens.first == "scroll" else { return nil }
    var fields: [String: String] = [:]
    for token in tokens.dropFirst() {
      guard let separator = token.firstIndex(of: "=") else { return nil }
      let key = String(token[..<separator])
      let value = String(token[token.index(after: separator)...])
      guard !key.isEmpty, !value.isEmpty, fields[key] == nil else { return nil }
      fields[key] = value
    }
    guard Set(fields.keys) == Self.expectedKeys,
      fields["schema"] == "1",
      let containerID = fields["container"], !containerID.isEmpty,
      let axisValue = fields["axis"], let axis = E2EScrollAxis(rawValue: axisValue),
      let interactionID = fields["interaction"].flatMap(Int.init), interactionID >= 0,
      let completionID = fields["completion"].flatMap(Int.init), completionID >= 0,
      let geometryID = fields["geometry"].flatMap(Int.init), geometryID > 0,
      let completionGeometryID = fields["completion-geometry"].flatMap(Int.init),
      completionGeometryID >= 0, completionGeometryID <= geometryID,
      let geometryReady = Self.bool(fields["geometry-ready"]), geometryReady,
      let isIdle = Self.phase(fields["phase"]),
      let atLeft = Self.bool(fields["at-left"]),
      let atRight = Self.bool(fields["at-right"]),
      let atTop = Self.bool(fields["at-top"]),
      let atBottom = Self.bool(fields["at-bottom"]),
      let offset = fields["offset"].flatMap(Double.init), offset.isFinite,
      let minimum = fields["minimum"].flatMap(Double.init), minimum.isFinite,
      let maximum = fields["maximum"].flatMap(Double.init), maximum.isFinite,
      let contentLength = fields["content"].flatMap(Double.init), contentLength.isFinite,
      let containerLength = fields["container-length"].flatMap(Double.init),
      containerLength.isFinite, containerLength > 0,
      contentLength >= 0, maximum >= minimum
    else { return nil }
    self.containerID = containerID
    self.axis = axis
    self.interactionID = interactionID
    self.completionID = completionID
    self.geometryID = geometryID
    self.completionGeometryID = completionGeometryID
    self.geometryReady = geometryReady
    self.isIdle = isIdle
    self.atLeft = atLeft
    self.atRight = atRight
    self.atTop = atTop
    self.atBottom = atBottom
    self.offset = offset
    self.minimum = minimum
    self.maximum = maximum
    self.contentLength = contentLength
    self.containerLength = containerLength
  }

  private static let expectedKeys: Set<String> = [
    "schema", "container", "axis", "interaction", "completion", "geometry",
    "completion-geometry", "geometry-ready", "phase", "at-left", "at-right",
    "at-top", "at-bottom", "offset", "minimum", "maximum", "content",
    "container-length",
  ]

  private static func bool(_ value: String?) -> Bool? {
    switch value {
    case "true": true
    case "false": false
    default: nil
    }
  }

  private static func phase(_ value: String?) -> Bool? {
    switch value {
    case "idle": true
    case "scrolling": false
    default: nil
    }
  }
}

struct LayoutReadinessState {
  let containerID: String
  let generation: Int

  init?(_ rawValue: Any?) {
    guard let value = rawValue as? String else { return nil }
    let tokens = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard tokens.first == "layout" else { return nil }
    var fields: [String: String] = [:]
    for token in tokens.dropFirst() {
      guard let separator = token.firstIndex(of: "=") else { return nil }
      let key = String(token[..<separator])
      let value = String(token[token.index(after: separator)...])
      guard !key.isEmpty, !value.isEmpty, fields[key] == nil else { return nil }
      fields[key] = value
    }
    guard Set(fields.keys) == Self.expectedKeys,
      fields["schema"] == "1", fields["ready"] == "true",
      let containerID = fields["container"], !containerID.isEmpty,
      let generation = fields["generation"].flatMap(Int.init), generation > 0,
      let width = fields["width"].flatMap(Double.init), width.isFinite, width > 0,
      let height = fields["height"].flatMap(Double.init), height.isFinite, height > 0
    else { return nil }
    self.containerID = containerID
    self.generation = generation
  }

  private static let expectedKeys: Set<String> = [
    "schema", "container", "generation", "width", "height", "ready",
  ]
}

@MainActor
func resolveAppleIntelligenceNotification(
  testCase: XCTestCase,
  file: StaticString = #filePath,
  line: UInt = #line
) -> Bool {
  resolveAppleIntelligenceNotificationState(
    testCase: testCase,
    file: file,
    line: line
  ).succeeded
}

private enum AppleIntelligenceNotificationResolution: Equatable {
  case absent
  case dismissed
  case failed

  var succeeded: Bool { self != .failed }
}

@MainActor
private func resolveAppleIntelligenceNotificationState(
  testCase: XCTestCase,
  file: StaticString,
  line: UInt
) -> AppleIntelligenceNotificationResolution {
  let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
  let notificationTitles = springboard.staticTexts.matching(
    NSPredicate(format: "label == %@", "Ready for Apple Intelligence")
  )

  if notificationTitles.count == 0,
    SystemInterruptionReadiness.appleIntelligenceState == .unobserved
  {
    let appearanceDeadline = EventDeadline(timeout: 1)
    _ = waitForExistence(notificationTitles.element, deadline: appearanceDeadline)
  }
  guard notificationTitles.count > 0 else {
    SystemInterruptionReadiness.appleIntelligenceState = .observedAbsent
    return .absent
  }
  guard notificationTitles.count == 1 else {
    attachSystemInterruptionEvidence(
      springboard,
      reason: "multiple Apple Intelligence notifications were present",
      testCase: testCase
    )
    XCTFail(
      "Expected one Apple Intelligence notification, found \(notificationTitles.count)",
      file: file,
      line: line
    )
    return .failed
  }

  let notificationTitle = notificationTitles.element
  let notificationFrame = notificationTitle.frame
  let springboardFrame = springboard.frame
  guard !notificationFrame.isEmpty, !springboardFrame.isEmpty else {
    let dismissed = waitForNoElements(notificationTitles, deadline: EventDeadline())
    guard dismissed else {
      attachSystemInterruptionEvidence(
        springboard,
        reason: "Apple Intelligence notification had no dismissible frame",
        testCase: testCase
      )
      XCTFail(
        "The simulator's Apple Intelligence notification had no dismissible frame; "
          + "notificationFrame=\(notificationFrame), springboardFrame=\(springboardFrame)",
        file: file,
        line: line
      )
      return .failed
    }
    SystemInterruptionReadiness.appleIntelligenceState = .dismissed
    return .dismissed
  }

  // Anchor the drag to SpringBoard, whose frame survives the banner's automatic
  // dismissal. An element-bound swipe retries against the disappearing title and
  // can fail after the overlay has already left the screen.
  let normalizedX = (notificationFrame.midX - springboardFrame.minX) / springboardFrame.width
  let normalizedStartY =
    (notificationFrame.midY - springboardFrame.minY) / springboardFrame.height
  let normalizedEndY = max(
    0.001,
    (notificationFrame.minY - springboardFrame.minY - 44) / springboardFrame.height
  )
  springboard.coordinate(
    withNormalizedOffset: CGVector(dx: normalizedX, dy: normalizedStartY)
  ).press(
    forDuration: 0.01,
    thenDragTo: springboard.coordinate(
      withNormalizedOffset: CGVector(dx: normalizedX, dy: normalizedEndY)
    ),
    withVelocity: .fast,
    thenHoldForDuration: 0
  )
  let dismissed = waitForNoElements(notificationTitles, deadline: EventDeadline())
  guard dismissed else {
    attachSystemInterruptionEvidence(
      springboard,
      reason: "Apple Intelligence notification did not dismiss",
      testCase: testCase
    )
    XCTFail(
      "The simulator's Apple Intelligence notification remained after dismissal; "
        + "count=\(notificationTitles.count), hierarchy=\(springboard.debugDescription)",
      file: file,
      line: line
    )
    return .failed
  }
  SystemInterruptionReadiness.appleIntelligenceState = .dismissed
  return .dismissed
}

@MainActor
private enum SystemInterruptionReadiness {
  enum ObservationState {
    case unobserved
    case observedAbsent
    case dismissed
  }

  static var appleIntelligenceState = ObservationState.unobserved
}

@MainActor
private func attachSystemInterruptionEvidence(
  _ springboard: XCUIApplication,
  reason: String,
  testCase: XCTestCase
) {
  let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
  screenshot.name = "system-overlay-\(reason.replacingOccurrences(of: " ", with: "-"))"
  screenshot.lifetime = .keepAlways
  testCase.add(screenshot)

  let hierarchy = XCTAttachment(string: springboard.debugDescription)
  hierarchy.name = "system-overlay-springboard-hierarchy"
  hierarchy.lifetime = .keepAlways
  testCase.add(hierarchy)
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
func waitForNoElements(
  _ query: XCUIElementQuery,
  deadline: EventDeadline = EventDeadline()
) -> Bool {
  if query.count == 0 { return true }
  guard query.count == 1 else { return false }
  let previouslyVisibleElement = query.element
  guard deadline.remaining > 0 else { return false }
  let expectation = XCTNSPredicateExpectation(
    predicate: NSPredicate(format: "exists == false"),
    object: previouslyVisibleElement
  )
  _ = XCTWaiter.wait(for: [expectation], timeout: deadline.remaining)
  return query.count == 0
}

@MainActor
func uniquelyIdentifiedElement(
  _ application: XCUIApplication,
  _ identifier: String
) -> XCUIElement {
  application.descendants(matching: .any).matching(identifier: identifier).element
}

@MainActor
extension XCUIElement {
  func waitForStringValue(_ expectedValue: String, timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "exists == true AND value == %@", expectedValue)
    if predicate.evaluate(with: self) { return true }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    if XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed { return true }
    // Re-evaluate the same semantic condition after a deadline-edge wakeup.
    // Splitting this into separate `exists` and `value` queries can report false
    // even when the value snapshot available at the deadline is already exact.
    return predicate.evaluate(with: self)
  }

  fileprivate var currentStringValue: String? {
    guard exists else { return nil }
    return value.map(String.init(describing:))
  }
}

struct EventDeadline {
  private let expiresAt: TimeInterval

  init(timeout: TimeInterval = 2) {
    expiresAt = ProcessInfo.processInfo.systemUptime + min(timeout, 2)
  }

  var remaining: TimeInterval {
    max(0, expiresAt - ProcessInfo.processInfo.systemUptime)
  }
}

enum ScrollProbeDirection: Equatable {
  case towardStart
  case towardEnd
}

@MainActor
struct ScrollSurface {
  let container: XCUIElement
  let readiness: XCUIElement
  let containerID: String
  let axis: E2EScrollAxis
  var permitsGeometrySettledFallback = false

  func state() -> ScrollReadinessState? {
    guard let state = ScrollReadinessState(readiness.value),
      state.containerID == containerID,
      state.axis == axis,
      container.identifier == containerID
    else { return nil }
    return state
  }
}

@MainActor
func scrollUntil(
  _ condition: @escaping () -> Bool,
  on surface: ScrollSurface,
  deadline readinessDeadline: EventDeadline = EventDeadline(),
  direction: ScrollProbeDirection = .towardEnd,
  requiresInteraction: Bool = false,
  requiresScrollableRange: Bool = false,
  terminalEndpoint: KeyPath<ScrollReadinessState, Bool>? = nil,
  failureContext: () -> String = { "" },
  gesture: () -> Void
) -> Bool {
  guard waitForScrollReadiness(
    surface,
    deadline: readinessDeadline,
    matching: { $0.isIdle && $0.geometryReady }
  ), let initial = surface.state()
  else {
    print("Scroll surface did not become ready: \(scrollReadinessDiagnostic(surface))")
    return false
  }
  if requiresScrollableRange && !initial.hasScrollableRange {
    print("Scroll surface is not scrollable: \(scrollReadinessDiagnostic(surface))")
    return false
  }
  if !requiresInteraction && condition() { return true }

  // Readiness and the first virtualized-target query are one observable phase.
  // Give gesture synthesis and its correlated completion a separate bounded
  // event budget so a slow accessibility snapshot cannot prevent all input.
  let actionDeadline = EventDeadline()
  var observedInteraction = false
  var lastCorrelatedState: ScrollReadinessState?
  var before = initial
  while actionDeadline.remaining > 0 {
    if let terminalEndpoint, before[keyPath: terminalEndpoint] {
      let context = failureContext()
      print(
        "Scroll condition is false at the terminal endpoint: "
          + scrollReadinessDiagnostic(surface)
          + (context.isEmpty ? "" : "; \(context)")
      )
      return false
    }
    guard actionDeadline.remaining >= 0.2 else { break }
    gesture()

    var settledState: ScrollReadinessState?
    let correlated = waitForScrollReadiness(
      surface,
      deadline: actionDeadline,
      matching: { after in
        let madeOffsetProgress: Bool
        switch direction {
        case .towardStart: madeOffsetProgress = after.offset < before.offset - 0.5
        case .towardEnd: madeOffsetProgress = after.offset > before.offset + 0.5
        }
        guard after.isIdle, after.geometryID > before.geometryID, madeOffsetProgress
        else { return false }
        let phaseCompletion = after.interactionID > before.interactionID
          && after.completionID > before.completionID
          && after.completionGeometryID == after.geometryID
        let listGeometryFallback = surface.permitsGeometrySettledFallback
          && after.geometryID > before.geometryID
          && after.isIdle
          && condition()
        let isCorrelated = phaseCompletion || listGeometryFallback
        if isCorrelated { settledState = after }
        return isCorrelated
      }
    )
    guard correlated, let settledState else {
      let context = failureContext()
      print(
        "Scroll gesture lacked settled, progress-making evidence: "
          + scrollReadinessDiagnostic(surface)
          + (context.isEmpty ? "" : "; \(context)")
      )
      return false
    }
    observedInteraction = true
    lastCorrelatedState = settledState
    if condition() { return true }
    before = settledState
  }

  if observedInteraction,
    let correlated = lastCorrelatedState,
    let latest = surface.state(),
    latest.isIdle,
    latest.interactionID == correlated.interactionID,
    latest.completionID == correlated.completionID,
    latest.geometryID >= correlated.geometryID,
    latest.completionGeometryID == latest.geometryID,
    condition()
  {
    return true
  }
  let context = failureContext()
  print(
    "Scroll deadline expired after settled progress: "
      + scrollReadinessDiagnostic(surface)
      + (context.isEmpty ? "" : "; \(context)")
  )
  return false
}

@MainActor
func challengeSettledEnd(
  on surface: ScrollSurface,
  tracking element: XCUIElement,
  deadline: EventDeadline = EventDeadline(),
  gesture: () -> Void
) -> Bool {
  guard let before = surface.state(), before.isIdle, before.atEnd else { return false }
  let beforeFrame = element.frame
  gesture()
  guard waitForScrollReadiness(
    surface,
    deadline: deadline,
    matching: { after in
      after.isIdle && after.atEnd
        && after.interactionID > before.interactionID
        && after.completionID > before.completionID
        && after.completionGeometryID == after.geometryID
    }
  ), let after = surface.state()
  else { return false }
  return abs(after.offset - before.offset) <= 1
    && abs(element.frame.minX - beforeFrame.minX) <= 1
    && abs(element.frame.minY - beforeFrame.minY) <= 1
}

@MainActor
func waitForScrollReadiness(
  _ surface: ScrollSurface,
  deadline: EventDeadline = EventDeadline(),
  matching condition: @escaping (ScrollReadinessState) -> Bool
) -> Bool {
  func matches() -> Bool {
    guard let state = surface.state() else { return false }
    return condition(state)
  }
  if matches() { return true }
  guard deadline.remaining > 0 else { return false }
  let expectation = XCTNSPredicateExpectation(
    predicate: NSPredicate { _, _ in matches() },
    object: surface.readiness
  )
  _ = XCTWaiter.wait(for: [expectation], timeout: deadline.remaining)
  return matches()
}

@MainActor
func waitForLayoutCondition(
  probe: XCUIElement,
  containerID: String,
  deadline: EventDeadline = EventDeadline(),
  condition: @escaping () -> Bool
) -> Bool {
  func matches() -> Bool {
    guard let state = LayoutReadinessState(probe.value), state.containerID == containerID else {
      return false
    }
    return condition()
  }
  if matches() { return true }
  guard deadline.remaining > 0 else { return false }
  let expectation = XCTNSPredicateExpectation(
    predicate: NSPredicate { _, _ in matches() },
    object: probe
  )
  _ = XCTWaiter.wait(for: [expectation], timeout: deadline.remaining)
  return matches()
}

@MainActor
func waitForExistence(_ element: XCUIElement, deadline: EventDeadline) -> Bool {
  element.exists || element.waitForExistence(timeout: deadline.remaining)
}

@MainActor
@discardableResult
func terminateAndWait(
  _ application: XCUIApplication,
  deadline: EventDeadline = EventDeadline()
) -> Bool {
  if application.state == .notRunning { return true }
  application.terminate()
  if application.state == .notRunning { return true }
  guard deadline.remaining > 0 else { return false }
  let expectation = XCTNSPredicateExpectation(
    predicate: NSPredicate { object, _ in
      (object as? XCUIApplication)?.state == .notRunning
    },
    object: application
  )
  _ = XCTWaiter.wait(for: [expectation], timeout: deadline.remaining)
  return application.state == .notRunning
}

@MainActor
private func scrollReadinessDiagnostic(_ surface: ScrollSurface) -> String {
  "container=\(surface.containerID), axis=\(surface.axis.rawValue), "
    + "probe=\(surface.readiness.identifier), value=\(String(describing: surface.readiness.value))"
}

@MainActor
func elementIsFullyVisible(
  _ element: XCUIElement,
  within container: XCUIElement,
  obscuredBelow obstruction: XCUIElement? = nil,
  tolerance: CGFloat = 1,
  requiresHittable: Bool = true
) -> Bool {
  guard element.exists, container.exists, !element.frame.isEmpty else { return false }
  let elementFrame = element.frame
  var containerFrame = container.frame
  if let obstruction, obstruction.exists {
    containerFrame.size.height = max(
      0,
      min(containerFrame.maxY, obstruction.frame.minY - 4) - containerFrame.minY
    )
  }
  return (!requiresHittable || element.isHittable)
    && elementFrame.minX >= containerFrame.minX - tolerance
    && elementFrame.maxX <= containerFrame.maxX + tolerance
    && elementFrame.minY >= containerFrame.minY - tolerance
    && elementFrame.maxY <= containerFrame.maxY + tolerance
}

@MainActor
struct StepVerification {
  let specification: String
  let check: @MainActor () -> Bool

  static func exists(
    _ element: XCUIElement,
    _ specification: String
  ) -> StepVerification {
    StepVerification(specification: specification) {
      element.waitForExistence(timeout: TestStepHelper.conditionTimeout)
    }
  }

  static func hittable(
    _ element: XCUIElement,
    _ specification: String
  ) -> StepVerification {
    StepVerification(specification: specification) {
      let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == true AND hittable == true"),
        object: element
      )
      return XCTWaiter.wait(
        for: [expectation],
        timeout: TestStepHelper.conditionTimeout
      ) == .completed
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
struct CaptureReadiness {
  let specification: String
  let anchor: XCUIElement
  let prime: (@MainActor () -> Bool)?
  let preparedScreenshot: (@MainActor () -> XCUIScreenshot?)?
  let checkNow: @MainActor () -> Bool

  init(
    specification: String,
    anchor: XCUIElement,
    prime: (@MainActor () -> Bool)? = nil,
    preparedScreenshot: (@MainActor () -> XCUIScreenshot?)? = nil,
    checkNow: @escaping @MainActor () -> Bool
  ) {
    self.specification = specification
    self.anchor = anchor
    self.prime = prime
    self.preparedScreenshot = preparedScreenshot
    self.checkNow = checkNow
  }
}

private enum TestStepError: Error {
  case captureNotReady(String)
  case systemOverlayNotDismissed
}

@MainActor
private func waitForCaptureReadiness(
  _ readiness: CaptureReadiness,
  deadline: EventDeadline
) -> Bool {
  if readiness.checkNow() { return true }
  guard deadline.remaining > 0 else { return false }
  let expectation = XCTNSPredicateExpectation(
    predicate: NSPredicate { _, _ in readiness.checkNow() },
    object: readiness.anchor
  )
  return XCTWaiter.wait(for: [expectation], timeout: deadline.remaining) == .completed
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
  private var systemOverlayResolved = true

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
    verifications: [StepVerification],
    captureReadiness: CaptureReadiness? = nil
  ) throws {
    dismissAppleIntelligenceNotificationIfPresent()
    guard systemOverlayResolved else {
      throw TestStepError.systemOverlayNotDismissed
    }

    for verification in verifications {
      XCTAssertTrue(
        verification.check(),
        verification.specification,
        file: #filePath,
        line: #line
      )
    }

    let filename = String(format: "%03d-%@.png", nextScreenshotIndex, identifier)
    var preparedScreenshot: XCUIScreenshot?
    if let captureReadiness {
      if let prime = captureReadiness.prime {
        let isPrimed = prime()
        XCTAssertTrue(
          isPrimed,
          "Capture readiness could not prepare its first verified observation",
          file: #filePath,
          line: #line
        )
        guard isPrimed else {
          throw TestStepError.captureNotReady(captureReadiness.specification)
        }
      }
      let deadline = EventDeadline()
      let isReady = waitForCaptureReadiness(captureReadiness, deadline: deadline)
      XCTAssertTrue(
        isReady,
        captureReadiness.specification,
        file: #filePath,
        line: #line
      )
      guard isReady else {
        throw TestStepError.captureNotReady(captureReadiness.specification)
      }
    }

    // A simulator system banner can arrive while the app-owned capture predicates
    // are being evaluated. Resolve it again at the capture boundary; if dismissal
    // changed the composited frame, establish capture readiness again before using
    // any prepared screenshot.
    let captureBoundaryResolution = dismissAppleIntelligenceNotificationIfPresent()
    guard systemOverlayResolved else {
      throw TestStepError.systemOverlayNotDismissed
    }
    if captureBoundaryResolution == .dismissed, let captureReadiness {
      if let prime = captureReadiness.prime {
        let isPrimed = prime()
        XCTAssertTrue(
          isPrimed,
          "Capture readiness could not prepare a post-notification observation",
          file: #filePath,
          line: #line
        )
        guard isPrimed else {
          throw TestStepError.captureNotReady(captureReadiness.specification)
        }
      }
      let retryDeadline = EventDeadline()
      let isReady = waitForCaptureReadiness(captureReadiness, deadline: retryDeadline)
      XCTAssertTrue(
        isReady,
        captureReadiness.specification,
        file: #filePath,
        line: #line
      )
      guard isReady else {
        throw TestStepError.captureNotReady(captureReadiness.specification)
      }
    }

    if let takePreparedScreenshot = captureReadiness?.preparedScreenshot {
      preparedScreenshot = takePreparedScreenshot()
      XCTAssertNotNil(
        preparedScreenshot,
        "Capture readiness succeeded without retaining its verified screenshot",
        file: #filePath,
        line: #line
      )
      guard preparedScreenshot != nil else {
        throw TestStepError.captureNotReady(captureReadiness?.specification ?? "prepared capture")
      }
    }

    let screenshot = preparedScreenshot ?? XCUIScreen.main.screenshot()
    nextScreenshotIndex += 1
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

  @discardableResult
  private func dismissAppleIntelligenceNotificationIfPresent()
    -> AppleIntelligenceNotificationResolution
  {
    let resolution = resolveAppleIntelligenceNotificationState(
      testCase: testCase,
      file: #filePath,
      line: #line
    )
    systemOverlayResolved = resolution.succeeded
    return resolution
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
