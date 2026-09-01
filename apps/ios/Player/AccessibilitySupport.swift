import SwiftUI

private struct PlayerHighContrastKey: EnvironmentKey {
  static let defaultValue = false
}

private struct PlayerReduceDecorativeArtworkKey: EnvironmentKey {
  static let defaultValue = false
}

private struct PlayerDifferentiateWithoutColorKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var playerHighContrast: Bool {
    get { self[PlayerHighContrastKey.self] }
    set { self[PlayerHighContrastKey.self] = newValue }
  }

  var playerReducesDecorativeArtwork: Bool {
    get { self[PlayerReduceDecorativeArtworkKey.self] }
    set { self[PlayerReduceDecorativeArtworkKey.self] = newValue }
  }

  var playerDifferentiatesWithoutColor: Bool {
    get { self[PlayerDifferentiateWithoutColorKey.self] }
    set { self[PlayerDifferentiateWithoutColorKey.self] = newValue }
  }
}

struct PlayerAccessibilityRootModifier: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
  @Environment(\.accessibilityDifferentiateWithoutColor) private
    var systemDifferentiatesWithoutColor
  @Environment(\.colorSchemeContrast) private var systemContrast

  let preferences: AccessibilityPreferences

  func body(content: Content) -> some View {
    content
      .environment(
        \.playerHighContrast,
        preferences.prefersHighContrast || systemContrast == .increased
      )
      .environment(\.playerReducesDecorativeArtwork, preferences.reducesDecorativeArtwork)
      .environment(\.playerDifferentiatesWithoutColor, systemDifferentiatesWithoutColor)
      .transaction { transaction in
        guard systemReducesMotion else { return }
        transaction.animation = nil
        transaction.disablesAnimations = true
      }
  }
}

private struct AccessibleCardModifier: ViewModifier {
  @Environment(\.playerHighContrast) private var highContrast
  @Environment(\.playerDifferentiatesWithoutColor) private var differentiateWithoutColor

  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    content.overlay {
      if highContrast || differentiateWithoutColor {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(
            PlayerColor.ink.opacity(highContrast ? 0.58 : 0.28), lineWidth: highContrast ? 2 : 1
          )
          .accessibilityHidden(true)
      }
    }
  }
}

extension View {
  func playerAccessibleCard(cornerRadius: CGFloat) -> some View {
    modifier(AccessibleCardModifier(cornerRadius: cornerRadius))
  }

  func accessibilityScrollsIfNeeded(
    _ enabled: Bool,
    identifier: String,
    readinessID: String,
    axis: E2EScrollAxis
  ) -> some View {
    modifier(
      AccessibilityScrollModifier(
        enabled: enabled,
        identifier: identifier,
        readinessID: readinessID,
        axis: axis
      )
    )
  }
}

private struct AccessibilityScrollModifier: ViewModifier {
  let enabled: Bool
  let identifier: String
  let readinessID: String
  let axis: E2EScrollAxis

  @ViewBuilder
  func body(content: Content) -> some View {
    if enabled {
      ScrollView { content }
        .playerMiniPlayerScrollRunway()
        .accessibilityIdentifier(identifier)
        .e2eScrollReadiness(
          id: readinessID,
          containerID: identifier,
          axis: axis
        )
    } else {
      content
    }
  }
}

struct AccessibilitySettingsView: View {
  @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
  @Environment(\.accessibilityDifferentiateWithoutColor) private
    var systemDifferentiatesWithoutColor
  @Environment(\.colorSchemeContrast) private var systemContrast
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.legibilityWeight) private var legibilityWeight

  @Bindable var model: PlayerModel

  var body: some View {
    ScrollViewReader { _ in
      Form {
        Section {
          Toggle(
            "Use higher contrast",
            isOn: prefersHighContrast
          )
          .accessibilityIdentifier("accessibility-high-contrast")
          Toggle(
            "Reduce decorative artwork",
            isOn: reducesDecorativeArtwork
          )
          .accessibilityIdentifier("accessibility-reduce-artwork")
        } header: {
          Text("Display")
        } footer: {
          Text(
            "These options can strengthen the interface beyond your iPhone settings. System accessibility settings always remain authoritative."
          )
        }

        Section("Active iPhone settings") {
          systemRow("Reduce Motion", enabled: systemReducesMotion, symbol: "figure.walk.motion")
          systemRow(
            "Increase Contrast",
            enabled: systemContrast == .increased,
            symbol: "circle.lefthalf.filled"
          )
          systemRow(
            "Differentiate Without Color",
            enabled: systemDifferentiatesWithoutColor,
            symbol: "eye"
          )
          systemRow("Bold Text", enabled: legibilityWeight == .bold, symbol: "bold")
          LabeledContent("Text size") {
            Text(dynamicTypeSize.isAccessibilitySize ? "Accessibility" : "Standard")
          }
        }
        .id("active-iphone-settings")
      }
      .playerMiniPlayerScrollRunway()
      .accessibilityIdentifier("accessibility-settings-scroll")
      .e2eScrollReadiness(
        id: "accessibility-settings-scroll-readiness",
        containerID: "accessibility-settings-scroll",
        axis: .vertical
      )
    }
    .scrollContentBackground(.hidden)
    .background(PlayerColor.background)
    .navigationTitle("Accessibility")
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("accessibility-settings-screen")
    .accessibilityValue(settingsValue)
    #if E2E
      .overlay {
        StateProbe(
          id: "accessibility-preferences-state",
          value: modelPreferencesValue
        )
        .id(modelPreferencesValue)
      }
    #endif
  }

  private var prefersHighContrast: Binding<Bool> {
    Binding(
      get: { model.library.accessibilityPreferences.prefersHighContrast },
      set: { enabled in Task { _ = await model.setPrefersHighContrast(enabled) } }
    )
  }

  private var reducesDecorativeArtwork: Binding<Bool> {
    Binding(
      get: { model.library.accessibilityPreferences.reducesDecorativeArtwork },
      set: { enabled in Task { _ = await model.setReducesDecorativeArtwork(enabled) } }
    )
  }

  private func systemRow(_ title: String, enabled: Bool, symbol: String) -> some View {
    LabeledContent {
      Label(enabled ? "On" : "Off", systemImage: enabled ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(enabled ? PlayerColor.accent : PlayerColor.secondary)
    } label: {
      Label(title, systemImage: symbol)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(enabled ? "On" : "Off")
  }

  private var settingsValue: String {
    return [
      "accessibility",
      "high-contrast=\(model.library.accessibilityPreferences.prefersHighContrast)",
      "reduce-artwork=\(model.library.accessibilityPreferences.reducesDecorativeArtwork)",
      "system-reduce-motion=\(systemReducesMotion)",
      "system-increase-contrast=\(systemContrast == .increased)",
      "system-differentiate=\(systemDifferentiatesWithoutColor)",
      "system-bold=\(legibilityWeight == .bold)",
      "large-text=\(dynamicTypeSize.isAccessibilitySize)",
    ].joined(separator: ":")
  }

  private var modelPreferencesValue: String {
    let preferences = model.library.accessibilityPreferences
    return
      "high-contrast=\(preferences.prefersHighContrast):reduce-artwork=\(preferences.reducesDecorativeArtwork)"
  }
}
