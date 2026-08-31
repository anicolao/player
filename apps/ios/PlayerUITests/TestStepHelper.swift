import Darwin
import XCTest
import UniformTypeIdentifiers

@MainActor
class PlayerUITestCase: XCTestCase {
  private var retainedFailureScreen = false

  override func record(_ issue: XCTIssue) {
    if !retainedFailureScreen {
      retainedFailureScreen = true
      let screenshot = XCUIScreen.main.screenshot()
      let attachment = XCTAttachment(
        data: screenshot.pngRepresentation,
        uniformTypeIdentifier: UTType.png.identifier
      )
      attachment.name = "xctest-failure-screen.png"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    super.record(issue)
  }
}

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
  // XCUIApplication.frame can be reported in screenshot pixels for SpringBoard
  // while its descendant frames and normalized coordinates use points. Select
  // a point-space window that contains the notification before converting its
  // frame to the application-relative normalized coordinate system.
  let coordinateFrame = springboard.windows.allElementsBoundByIndex
    .map(\.frame)
    .first {
      !$0.isEmpty
        && $0.contains(CGPoint(x: notificationFrame.midX, y: notificationFrame.midY))
    }
  guard !notificationFrame.isEmpty, let coordinateFrame else {
    let dismissed = waitForNoElements(notificationTitles, deadline: EventDeadline())
    guard dismissed else {
      attachSystemInterruptionEvidence(
        springboard,
        reason: "Apple Intelligence notification had no dismissible frame",
        testCase: testCase
      )
      XCTFail(
        "The simulator's Apple Intelligence notification had no dismissible frame; "
          + "notificationFrame=\(notificationFrame), "
          + "springboardFrame=\(springboard.frame), "
          + "windowFrames=\(springboard.windows.allElementsBoundByIndex.map(\.frame))",
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
  let normalizedX = (notificationFrame.midX - coordinateFrame.minX) / coordinateFrame.width
  let normalizedStartY =
    (notificationFrame.midY - coordinateFrame.minY) / coordinateFrame.height
  let normalizedEndY = max(
    0.001,
    (notificationFrame.minY - coordinateFrame.minY - 44) / coordinateFrame.height
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
func performPhysicalInteractionWithoutPostEventQuiescence(
  in application: XCUIApplication,
  _ interaction: () -> Void
) -> Bool {
  // The pinned XCTest runtime exposes bit 1 as
  // XCUIApplicationInteractionOptionSkipPostEventQuiescence. These callers
  // already wait for an exact product-state event, so XCTest's independent
  // global-idle wait is neither the completion signal nor part of its two-second
  // contract. Fail closed if that pinned interaction option is unavailable.
  let interactionOptionsKey = "currentInteractionOptions"
  guard
    let currentOptions = application.value(forKey: interactionOptionsKey) as? NSNumber
  else { return false }
  application.setValue(
    NSNumber(value: currentOptions.uintValue | (1 << 1)),
    forKey: interactionOptionsKey
  )
  defer {
    application.setValue(currentOptions, forKey: interactionOptionsKey)
  }
  interaction()
  return true
}

@_silgen_name("notify_register_file_descriptor")
private func e2eNotifyRegisterFileDescriptor(
  _ name: UnsafePointer<CChar>,
  _ descriptor: UnsafeMutablePointer<Int32>,
  _ flags: Int32,
  _ token: UnsafeMutablePointer<Int32>
) -> UInt32

@_silgen_name("notify_cancel")
private func e2eNotifyCancel(_ token: Int32) -> UInt32

private final class DarwinEventReceipt: @unchecked Sendable {
  private var descriptor: Int32 = -1
  private var token: Int32 = 0

  init?(name: String) {
    let status = name.withCString { notificationName in
      e2eNotifyRegisterFileDescriptor(notificationName, &descriptor, 0, &token)
    }
    guard status == 0, descriptor >= 0 else { return nil }
  }

  deinit {
    _ = e2eNotifyCancel(token)
  }

  func wait(timeout: TimeInterval) -> Bool {
    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    return Darwin.poll(&event, 1, Int32(timeout * 1_000)) == 1
      && event.revents & Int16(POLLIN) != 0
  }
}

@MainActor
func backgroundAndReactivateApplication(
  _ application: XCUIApplication,
  requiring interactiveElement: XCUIElement
) -> Bool {
  guard let backgroundReceipt = DarwinEventReceipt(
    name: "com.spnss.player.e2e.background-checkpoint-completed"
  ) else { return false }
  let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

  XCUIDevice.shared.press(.home)
  springboard.activate()
  guard springboard.wait(for: .runningForeground, timeout: 2) else { return false }
  guard backgroundReceipt.wait(timeout: 2) else { return false }

  application.activate()
  let interactive = NSPredicate { _, _ in
    guard application.state == .runningForeground,
      interactiveElement.exists,
      interactiveElement.isEnabled,
      interactiveElement.isHittable
    else { return false }
    let applicationFrame = application.frame
    let elementFrame = interactiveElement.frame
    return !applicationFrame.isEmpty
      && !elementFrame.isEmpty
      && applicationFrame.contains(elementFrame)
  }
  return waitForPredicate(interactive, on: interactiveElement, timeout: 2)
}

@MainActor
func performBoundedForegroundInteraction(
  _ interactiveElement: XCUIElement,
  in application: XCUIApplication
) -> Bool {
  let interactive = NSPredicate { _, _ in
    guard application.state == .runningForeground,
      interactiveElement.exists,
      interactiveElement.isEnabled,
      interactiveElement.isHittable
    else { return false }
    let applicationFrame = application.frame
    let elementFrame = interactiveElement.frame
    return !applicationFrame.isEmpty
      && !elementFrame.isEmpty
      && applicationFrame.contains(elementFrame)
  }
  guard waitForPredicate(interactive, on: interactiveElement, timeout: 2) else { return false }

  let applicationFrame = application.frame
  let elementFrame = interactiveElement.frame
  let coordinate = application.coordinate(
    withNormalizedOffset: CGVector(
      dx: (elementFrame.midX - applicationFrame.minX) / applicationFrame.width,
      dy: (elementFrame.midY - applicationFrame.minY) / applicationFrame.height
    )
  )
  return performPhysicalInteractionWithoutPostEventQuiescence(
    in: application,
    { coordinate.tap() }
  )
}

/// Delivers an asynchronous production button action without guessing whether
/// XCTest's synthesized event reached SwiftUI. The button's synchronous
/// disabled state acknowledges acceptance; an already-published final receipt
/// also counts as delivery. Re-synthesis is safe only while both are absent.
@MainActor
func deliverPhysicalActionAcknowledgedByDisabling(
  _ action: XCUIElement,
  until completionReceipt: XCUIElement,
  satisfies completionPredicate: NSPredicate,
  in application: XCUIApplication
) -> Bool {
  if completionPredicate.evaluate(with: completionReceipt) { return true }

  let interactive = NSPredicate { _, _ in
    guard application.state == .runningForeground,
      action.exists,
      action.isEnabled,
      action.isHittable
    else { return false }
    let applicationFrame = application.frame
    let actionFrame = action.frame
    return !applicationFrame.isEmpty
      && !actionFrame.isEmpty
      && applicationFrame.contains(actionFrame)
  }
  guard waitForPredicate(interactive, on: action, timeout: 2) else { return false }

  let applicationFrame = application.frame
  let actionFrame = action.frame
  let coordinate = application.coordinate(
    withNormalizedOffset: CGVector(
      dx: (actionFrame.midX - applicationFrame.minX) / applicationFrame.width,
      dy: (actionFrame.midY - applicationFrame.minY) / applicationFrame.height
    )
  )
  let disabled = NSPredicate(format: "exists == true AND enabled == false")
  var deliveryDeadline: EventDeadline?

  repeat {
    if completionPredicate.evaluate(with: completionReceipt) { return true }
    if action.exists, !action.isEnabled { return true }
    guard action.exists, action.isEnabled, action.isHittable, action.frame == actionFrame else {
      guard let deliveryDeadline else { return false }
      return waitForPredicate(
        completionPredicate,
        on: completionReceipt,
        timeout: deliveryDeadline.remaining
      )
    }
    if let deliveryDeadline, deliveryDeadline.remaining <= 0 { break }

    guard performPhysicalInteractionWithoutPostEventQuiescence(
      in: application,
      { coordinate.tap() }
    ) else { return false }
    if deliveryDeadline == nil { deliveryDeadline = EventDeadline() }
    guard let deliveryDeadline else { return false }

    if waitForPredicate(
      disabled,
      on: action,
      timeout: min(0.25, deliveryDeadline.remaining)
    ) { return true }
    if completionPredicate.evaluate(with: completionReceipt) { return true }
  } while (deliveryDeadline?.remaining ?? 0) > 0

  return false
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
  let application: XCUIApplication
  let container: XCUIElement
  let readiness: XCUIElement
  let containerID: String
  let axis: E2EScrollAxis
  var containerElementID: String? = nil
  var permitsGeometrySettledFallback = false

  func state() -> ScrollReadinessState? {
    guard let state = ScrollReadinessState(readiness.value),
      state.containerID == containerID,
      state.axis == axis,
      container.identifier == (containerElementID ?? containerID)
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

  // Each physical gesture and its correlated completion are one observable
  // event. A long but finite surface may require multiple such events, so give
  // each synthesis its own deadline while bounding the total gesture count
  // from the reported scroll geometry.
  var remainingGestureCount = max(
    2,
    Int(ceil((initial.maximum - initial.minimum) / max(initial.containerLength * 0.2, 1))) + 2
  )
  var observedInteraction = false
  var lastCorrelatedState: ScrollReadinessState?
  var before = initial
  while remainingGestureCount > 0 {
    if let terminalEndpoint, before[keyPath: terminalEndpoint] {
      let context = failureContext()
      print(
        "Scroll condition is false at the terminal endpoint: "
          + scrollReadinessDiagnostic(surface)
          + (context.isEmpty ? "" : "; \(context)")
      )
      return false
    }
    guard performPhysicalInteractionWithoutPostEventQuiescence(in: surface.application, gesture)
    else {
      print("The pinned XCTest runtime cannot bound scroll gesture synthesis")
      return false
    }
    remainingGestureCount -= 1
    let actionDeadline = EventDeadline()

    let receiptDeadline = EventDeadline(timeout: min(0.25, actionDeadline.remaining))
    let receiptMatches: (ScrollReadinessState) -> Bool = { after in
      let madeOffsetProgress: Bool
      switch direction {
      case .towardStart: madeOffsetProgress = after.offset < before.offset - 0.5
      case .towardEnd: madeOffsetProgress = after.offset > before.offset + 0.5
      }
      return after.interactionID > before.interactionID || madeOffsetProgress
    }
    var received = waitForScrollReadiness(
      surface,
      deadline: receiptDeadline,
      matching: receiptMatches
    )
    if !received, let latest = surface.state() { received = receiptMatches(latest) }
    guard received else {
      guard let latest = surface.state(),
        latest.isIdle,
        latest.interactionID == before.interactionID,
        latest.completionID == before.completionID,
        latest.geometryID == before.geometryID,
        latest.completionGeometryID == before.completionGeometryID,
        abs(latest.offset - before.offset) <= 0.5,
        actionDeadline.remaining > 0
      else {
        print(
          "Scroll gesture changed state without a correlatable receipt: "
            + scrollReadinessDiagnostic(surface)
        )
        return false
      }
      before = latest
      continue
    }

    var settledState: ScrollReadinessState?
    let recordCorrelatedState: (ScrollReadinessState) -> Bool = { after in
      settledState = nil
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
    let observedCorrelatedState = waitForScrollReadiness(
      surface,
      deadline: actionDeadline,
      matching: recordCorrelatedState
    )
    if !observedCorrelatedState, let latest = surface.state() {
      _ = recordCorrelatedState(latest)
    }
    guard let settledState else {
      let context = failureContext()
      print(
        "Scroll gesture lacked settled, progress-making evidence: "
            + scrollReadinessDiagnostic(surface)
            + "; origin=interaction=\(before.interactionID),completion=\(before.completionID),"
            + "geometry=\(before.geometryID),completion-geometry="
            + "\(before.completionGeometryID),offset=\(before.offset)"
            + (context.isEmpty ? "" : "; \(context)")
      )
      return false
    }
    observedInteraction = true
    lastCorrelatedState = settledState
    if condition() { return true }
    if let terminalEndpoint, settledState[keyPath: terminalEndpoint],
      waitForScrollReadiness(
        surface,
        deadline: actionDeadline,
        matching: { after in
          let phaseCompletion = after.interactionID >= settledState.interactionID
            && after.completionID >= settledState.completionID
            && after.completionGeometryID == after.geometryID
          let listGeometryFallback = surface.permitsGeometrySettledFallback
            && after.geometryID >= settledState.geometryID
          return after.isIdle
            && after[keyPath: terminalEndpoint]
            && after.geometryID >= settledState.geometryID
            && (phaseCompletion || listGeometryFallback)
            && condition()
        }
      )
    {
      return true
    }
    before = settledState
  }

  if observedInteraction,
    let correlated = lastCorrelatedState,
    let latest = surface.state(),
    latest.isIdle,
    latest.geometryID >= correlated.geometryID,
    (
      (
        latest.interactionID == correlated.interactionID
          && latest.completionID == correlated.completionID
          && latest.completionGeometryID == latest.geometryID
      )
        || surface.permitsGeometrySettledFallback
    ),
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
  gesture: () -> Void
) -> Bool {
  guard let before = surface.state(), before.isIdle, before.atEnd else { return false }
  let beforeFrame = element.frame
  var received = false
  var transitionDeadline: EventDeadline?
  while transitionDeadline?.remaining ?? 2 > 0 && !received {
    guard performPhysicalInteractionWithoutPostEventQuiescence(
      in: surface.application,
      gesture
    ) else { return false }
    if transitionDeadline == nil { transitionDeadline = EventDeadline() }
    guard let transitionDeadline else { return false }
    let receiptMatches: (ScrollReadinessState) -> Bool = {
      $0.interactionID > before.interactionID
    }
    received = waitForScrollReadiness(
      surface,
      deadline: EventDeadline(timeout: min(0.25, transitionDeadline.remaining)),
      matching: receiptMatches
    )
    if !received, let latest = surface.state() { received = receiptMatches(latest) }
    if !received,
      let latest = surface.state(),
      latest.isIdle,
      latest.atEnd == before.atEnd,
      latest.interactionID == before.interactionID,
      latest.completionID == before.completionID,
      latest.geometryID == before.geometryID,
      latest.completionGeometryID == before.completionGeometryID,
      abs(latest.offset - before.offset) <= 1
    {
      continue
    }
    if !received { return false }
  }
  guard received, let transitionDeadline else { return false }
  guard waitForScrollReadiness(
    surface,
    deadline: transitionDeadline,
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
