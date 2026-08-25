import SwiftUI

struct SleepTimerView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: PlayerModel
  @State private var fadeEnabled: Bool
  @State private var customMinutes = 25
  @State private var errorMessage: String?

  init(model: PlayerModel) {
    self.model = model
    _fadeEnabled = State(initialValue: model.activeSleepTimer?.fadeEnabled ?? true)
  }

  var body: some View {
    NavigationStack {
      Form {
        if let projection = model.activeSleepTimerProjection {
          Section("Active timer") {
            HStack(alignment: .firstTextBaseline) {
              VStack(alignment: .leading, spacing: 4) {
                Text(projection.selectionLabel).font(.headline)
                Text(activeDetail(projection))
                  .font(.caption)
                  .foregroundStyle(PlayerColor.secondary)
              }
              Spacer()
              Text(remainingLabel(projection.remainingSeconds))
                .font(.title3.monospacedDigit().weight(.semibold))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("active-sleep-timer")
            .accessibilityValue(activeValue(projection))

            Button("Cancel Sleep Timer", role: .destructive) {
              Task {
                if await model.cancelSleepTimer() { dismiss() }
              }
            }
            .accessibilityIdentifier("cancel-sleep-timer")
          }
        }

        Section {
          Toggle("Fade out gently", isOn: $fadeEnabled)
            .accessibilityIdentifier("sleep-timer-fade")
        } footer: {
          Text("When enabled, volume fades during the final five seconds and playback stops at the intended time or boundary.")
        }

        Section(model.activeSleepTimer == nil ? "Minutes" : "Replace with") {
          ForEach(SleepTimerPreset.allCases, id: \.rawValue) { preset in
            selectionButton(
              "\(preset.rawValue) minutes",
              systemImage: "timer",
              identifier: "sleep-timer-preset-\(preset.rawValue)",
              selection: .preset(preset)
            )
          }

          Picker("Custom duration", selection: $customMinutes) {
            ForEach(Self.customMinuteOptions, id: \.self) { minutes in
              Text("\(minutes) minutes")
                .tag(minutes)
                .accessibilityIdentifier("sleep-timer-custom-\(minutes)")
            }
          }
          .accessibilityIdentifier("sleep-timer-custom-picker")

          selectionButton(
            "Start custom · \(customMinutes) minutes",
            systemImage: "slider.horizontal.3",
            identifier: "start-custom-sleep-timer",
            selection: .custom(durationSeconds: TimeInterval(customMinutes * 60))
          )
        }

        Section("Stop after") {
          selectionButton(
            "End of Chapter",
            systemImage: "text.book.closed",
            identifier: "sleep-timer-end-chapter",
            selection: .endOfChapter
          )
          selectionButton(
            "End of Track",
            systemImage: "waveform",
            identifier: "sleep-timer-end-track",
            selection: .endOfTrack
          )
        }

        if !model.recentSleepHistory.isEmpty {
          Section("Recent") {
            ForEach(model.recentSleepHistory) { entry in
              VStack(alignment: .leading, spacing: 3) {
                Text(entry.selection.displayLabel).font(.subheadline.weight(.semibold))
                Text(historyDetail(entry))
                  .font(.caption)
                  .foregroundStyle(PlayerColor.secondary)
              }
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("sleep-history-\(entry.id.uuidString.lowercased())")
              .accessibilityValue(historyValue(entry))
            }
          }
        }
      }
      .playerMiniPlayerScrollRunway()
      .scrollContentBackground(.hidden)
      .background(PlayerColor.background)
      .navigationTitle("Sleep Timer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .accessibilityIdentifier("sleep-timer-screen")
      .accessibilityValue(screenValue)
      .alert("Sleep Timer", isPresented: errorIsPresented) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "The timer could not be started.")
      }
    }
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private var screenValue: String {
    guard let projection = model.activeSleepTimerProjection else {
      return "sleep-timer:active=none:fade=\(fadeEnabled):history=\(model.recentSleepHistory.count)"
    }
    let selection = model.activeSleepTimer.map { selectionToken($0.selection) } ?? "none"
    return "sleep-timer:active=\(projection.timerID.uuidString.lowercased()):selection=\(selection):remaining=\(remainingSeconds(projection.remainingSeconds)):target=\(projection.targetPositionMilliseconds.map(String.init) ?? "none"):fade=\(projection.fadeEnabled):phase=\(projection.phase.rawValue):history=\(model.recentSleepHistory.count)"
  }

  private func selectionButton(
    _ title: String,
    systemImage: String,
    identifier: String,
    selection: SleepTimerSelection
  ) -> some View {
    Button {
      Task {
        if await model.startSleepTimer(selection: selection, fadeEnabled: fadeEnabled) != nil {
          dismiss()
        } else {
          errorMessage = "Choose a timer that ends after the current listening position."
        }
      }
    } label: {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier(identifier)
  }

  private func activeDetail(_ projection: SleepTimerProjection) -> String {
    projection.phase == .fading ? "Fading now · stops at the intended boundary" : "Playback will pause automatically"
  }

  private func activeValue(_ projection: SleepTimerProjection) -> String {
    let selection = model.activeSleepTimer.map { selectionToken($0.selection) } ?? "none"
    return "timer=\(projection.timerID.uuidString.lowercased()):selection=\(selection):remaining=\(remainingSeconds(projection.remainingSeconds)):target=\(projection.targetPositionMilliseconds.map(String.init) ?? "none"):fade=\(projection.fadeEnabled):phase=\(projection.phase.rawValue)"
  }

  private func historyDetail(_ entry: SleepTimerHistoryEntry) -> String {
    switch entry.status {
    case .completed: "Stopped at \(timecode(entry.actualStopSeconds))"
    case .cancelled: "Cancelled"
    case .replaced: "Replaced"
    }
  }

  private func historyValue(_ entry: SleepTimerHistoryEntry) -> String {
    "history=\(entry.id.uuidString.lowercased()):timer=\(entry.timerID.uuidString.lowercased()):selection=\(selectionToken(entry.selection)):status=\(entry.status.rawValue):stop=\(entry.actualStopPositionMilliseconds):event=\(entry.positionEventID?.uuidString.lowercased() ?? "none"):context-used=\(entry.resumeContextUsedAt == nil ? "false" : "true")"
  }

  private func remainingLabel(_ seconds: TimeInterval?) -> String {
    guard let seconds else { return "At boundary" }
    return timecode(max(0, seconds))
  }

  private func remainingSeconds(_ seconds: TimeInterval?) -> String {
    seconds.map { String(Int(max(0, $0).rounded(.down))) } ?? "none"
  }

  private func selectionToken(_ selection: SleepTimerSelection) -> String {
    switch selection {
    case .preset(let preset): "preset-\(preset.rawValue)"
    case .custom(let seconds): "custom-\(Int(seconds.rounded(.down)))"
    case .endOfChapter: "end-chapter"
    case .endOfTrack: "end-track"
    }
  }

  private func timecode(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", value / 60, value % 60)
  }

  private static let customMinuteOptions = [1, 5, 20, 25, 90, 120]
}
