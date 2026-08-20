import SwiftUI

struct SmartRewindSettingsView: View {
  @Bindable var model: PlayerModel
  @State private var requestedEnabled: Bool

  init(model: PlayerModel) {
    self.model = model
    _requestedEnabled = State(initialValue: model.library.smartRewindPreferences.isEnabled)
  }

  var body: some View {
    Form {
      Section {
        Toggle(
          "Smart Rewind",
          isOn: $requestedEnabled
        )
        .onChange(of: requestedEnabled) { _, enabled in
          Task {
            if !(await model.setSmartRewindEnabled(enabled)) {
              requestedEnabled = preferences.isEnabled
            }
          }
        }
        .accessibilityIdentifier("smart-rewind-enabled")
      } footer: {
        Text("After time away, Player briefly rewinds so you can pick up the thread. An Undo button always returns to your exact saved position.")
      }

      Section("Maximum rewind") {
        Picker(
          "Maximum rewind",
          selection: Binding(
            get: { preferences.maximumRewindSeconds },
            set: { seconds in Task { _ = await model.setSmartRewindMaximum(seconds) } }
          )
        ) {
          ForEach(Self.maximumOptions, id: \.self) { seconds in
            Text("\(Int(seconds)) seconds")
              .tag(seconds)
              .accessibilityIdentifier("smart-rewind-maximum-\(Int(seconds))")
          }
        }
        .accessibilityIdentifier("smart-rewind-maximum")
        .accessibilityValue("\(Int(preferences.maximumRewindSeconds)) seconds")
      }

      Section("How it adapts") {
        tier("A short break", detail: "5 seconds after 30 seconds away")
        tier("A longer break", detail: "15 seconds after 10 minutes away")
        tier("More than an hour", detail: "30 seconds, within your maximum")
        Label("Rewinds stop at the current chapter boundary.", systemImage: "text.book.closed")
          .font(.footnote)
          .foregroundStyle(PlayerColor.secondary)
      }
    }
    .scrollContentBackground(.hidden)
    .background(PlayerColor.background)
    .navigationTitle("Smart Rewind")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("smart-rewind-settings-screen")
    .accessibilityValue(settingsValue)
  }

  private var preferences: SmartRewindPreferences {
    model.library.smartRewindPreferences
  }

  private var settingsValue: String {
    "smart-rewind:enabled=\(preferences.isEnabled):maximum=\(Int(preferences.maximumRewindSeconds)):thresholds=30,600,3600:rewinds=5,15,30"
  }

  private func tier(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.subheadline.weight(.semibold))
      Text(detail).font(.caption).foregroundStyle(PlayerColor.secondary)
    }
  }

  private static let maximumOptions: [Double] = [10, 15, 20, 30, 45, 60]
}
