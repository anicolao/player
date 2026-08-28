import SwiftUI

enum E2EScrollAxis: String, Equatable {
  case horizontal
  case vertical
}

extension View {
  @ViewBuilder
  func e2eScrollReadiness(
    id: String,
    containerID: String,
    axis: E2EScrollAxis
  ) -> some View {
    #if E2E
      if #available(iOS 18.0, *) {
        modifier(
          E2EScrollReadinessModifier(
            id: id,
            containerID: containerID,
            axis: axis
          )
        )
      } else {
        self
      }
    #else
      self
    #endif
  }

  @ViewBuilder
  func e2eLayoutReadiness(id: String, containerID: String) -> some View {
    #if E2E
      if #available(iOS 18.0, *) {
        modifier(E2ELayoutReadinessModifier(id: id, containerID: containerID))
      } else {
        self
      }
    #else
      self
    #endif
  }
}

#if E2E
  struct E2EScrollEndpointRange: Equatable {
    let offset: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let contentLength: CGFloat
    let containerLength: CGFloat
    let atStart: Bool
    let atEnd: Bool

    init(
      visibleRect: CGRect,
      contentSize: CGSize,
      axis: E2EScrollAxis,
      tolerance: CGFloat = 1
    ) {
      switch axis {
      case .horizontal:
        offset = visibleRect.minX
        contentLength = contentSize.width
        containerLength = visibleRect.width
        atStart = visibleRect.minX <= tolerance
        atEnd = visibleRect.maxX >= contentSize.width - tolerance
      case .vertical:
        offset = visibleRect.minY
        contentLength = contentSize.height
        containerLength = visibleRect.height
        atStart = visibleRect.minY <= tolerance
        atEnd = visibleRect.maxY >= contentSize.height - tolerance
      }
      // SwiftUI computes visibleRect from content offset, insets, and container size.
      // Normalize to content coordinates so List and ScrollView margin behavior agree.
      minimum = 0
      maximum = max(0, contentLength - containerLength)
    }
  }

  @available(iOS 18.0, *)
  private struct E2EScrollReadinessModifier: ViewModifier {
    let id: String
    let containerID: String
    let axis: E2EScrollAxis

    @State private var interactionID = 0
    @State private var completionID = 0
    @State private var geometryID = 0
    @State private var completionGeometryID = 0
    @State private var isIdle = true
    @State private var endpoints = E2EScrollEndpoints()

    func body(content: Content) -> some View {
      content
        .onScrollGeometryChange(for: E2EScrollEndpoints.self) { geometry in
          E2EScrollEndpoints(geometry: geometry, axis: axis)
        } action: { _, newValue in
          let nextGeometryID = geometryID + 1
          geometryID = nextGeometryID
          endpoints = newValue
          if isIdle, completionID > 0, completionID == interactionID {
            completionGeometryID = nextGeometryID
          }
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
          let finalEndpoints = E2EScrollEndpoints(geometry: context.geometry, axis: axis)
          let finalGeometryID: Int
          if finalEndpoints != endpoints {
            finalGeometryID = geometryID + 1
            geometryID = finalGeometryID
            endpoints = finalEndpoints
          } else {
            finalGeometryID = geometryID
          }
          if oldPhase == .idle, newPhase != .idle { interactionID += 1 }
          if oldPhase != .idle, newPhase == .idle {
            completionID += 1
            completionGeometryID = finalGeometryID
          }
          isIdle = newPhase == .idle
        }
        .overlay(alignment: .topLeading) {
          StateProbe(
            id: id,
            value: [
              "scroll",
              "schema=1",
              "container=\(containerID)",
              "axis=\(axis.rawValue)",
              "interaction=\(interactionID)",
              "completion=\(completionID)",
              "geometry=\(geometryID)",
              "completion-geometry=\(completionGeometryID)",
              "geometry-ready=\(geometryID > 0 && endpoints.isFinite && endpoints.containerLength > 0)",
              "phase=\(isIdle ? "idle" : "scrolling")",
              "at-left=\(endpoints.atLeft)",
              "at-right=\(endpoints.atRight)",
              "at-top=\(endpoints.atTop)",
              "at-bottom=\(endpoints.atBottom)",
              "offset=\(endpoints.offset)",
              "minimum=\(endpoints.minimum)",
              "maximum=\(endpoints.maximum)",
              "content=\(endpoints.contentLength)",
              "container-length=\(endpoints.containerLength)",
            ].joined(separator: "|")
          )
        }
    }
  }

  @available(iOS 18.0, *)
  private struct E2EScrollEndpoints: Equatable {
    var atLeft = false
    var atRight = false
    var atTop = false
    var atBottom = false
    var offset: CGFloat = 0
    var minimum: CGFloat = 0
    var maximum: CGFloat = 0
    var contentLength: CGFloat = 0
    var containerLength: CGFloat = 0

    var isFinite: Bool {
      offset.isFinite && minimum.isFinite && maximum.isFinite
        && contentLength.isFinite && containerLength.isFinite
    }

    init() {}

    init(geometry: ScrollGeometry, axis: E2EScrollAxis) {
      let tolerance: CGFloat = 1
      let range = E2EScrollEndpointRange(
        visibleRect: geometry.visibleRect,
        contentSize: geometry.contentSize,
        axis: axis,
        tolerance: tolerance
      )

      switch axis {
      case .horizontal:
        offset = range.offset
        minimum = range.minimum
        maximum = range.maximum
        contentLength = range.contentLength
        containerLength = range.containerLength
        atLeft = range.atStart
        atRight = range.atEnd
      case .vertical:
        offset = range.offset
        minimum = range.minimum
        maximum = range.maximum
        contentLength = range.contentLength
        containerLength = range.containerLength
        atTop = range.atStart
        atBottom = range.atEnd
      }
    }
  }

  @available(iOS 18.0, *)
  private struct E2ELayoutReadinessModifier: ViewModifier {
    let id: String
    let containerID: String

    @State private var generation = 0
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
      content
        .onGeometryChange(for: CGSize.self) { proxy in
          proxy.size
        } action: { newSize in
          generation += 1
          size = newSize
        }
        .overlay(alignment: .topLeading) {
          StateProbe(
            id: id,
            value: [
              "layout",
              "schema=1",
              "container=\(containerID)",
              "generation=\(generation)",
              "width=\(size.width)",
              "height=\(size.height)",
              "ready=\(generation > 0 && size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0)",
            ].joined(separator: "|")
          )
      }
    }
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
#endif
