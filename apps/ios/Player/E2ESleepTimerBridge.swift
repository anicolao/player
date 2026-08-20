#if E2E
  import Foundation
  import Observation
  import SwiftUI

  final class E2EMutablePlayerClock: PlayerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(value: Date) {
      self.value = value
    }

    func now() -> Date {
      lock.withLock { value }
    }

    func advance(by seconds: TimeInterval) {
      lock.withLock { value = value.addingTimeInterval(seconds) }
    }
  }

  @MainActor
  @Observable
  final class E2ESleepTimerBridge {
    static let shared = E2ESleepTimerBridge()

    private(set) var isConfigured = false
    private(set) var showsControls = false
    @ObservationIgnored private var clock: E2EMutablePlayerClock?

    func configure(clock: E2EMutablePlayerClock) {
      self.clock = clock
      isConfigured = true
      showsControls = true
    }

    func hideControls() {
      showsControls = false
    }

    func advanceClock(by seconds: TimeInterval) {
      clock?.advance(by: seconds)
    }
  }

  @MainActor
  struct E2ESleepTimerControlSurface: View {
    @Bindable var model: PlayerModel

    var body: some View {
      ZStack(alignment: .topTrailing) {
        probe
        if E2ESleepTimerBridge.shared.showsControls && boundaryControlsAvailable {
          VStack(spacing: 4) {
            Button("Fade boundary") {
              Task {
                await model.seek(to: 85, context: .wholeBook)
                await model.evaluateSleepTimer()
              }
            }
            .accessibilityIdentifier("e2e-sleep-enter-fade")

            Button("Complete boundary") {
              Task {
                await model.seek(to: 90, context: .wholeBook)
                await model.evaluateSleepTimer()
                E2ESleepTimerBridge.shared.hideControls()
              }
            }
            .accessibilityIdentifier("e2e-sleep-complete-boundary")
          }
          .font(.caption)
          .buttonStyle(.bordered)
          .padding(6)
          .background(PlayerColor.background.opacity(0.98), in: RoundedRectangle(cornerRadius: 10))
        }
      }
    }

    private var boundaryControlsAvailable: Bool {
      guard let timer = model.activeSleepTimer else { return false }
      if case .endOfTrack = timer.selection { return true }
      return false
    }

    private var probe: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .id(probeValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep timer state")
        .accessibilityIdentifier("sleep-timer-state-probe")
        .accessibilityValue(probeValue)
    }

    private var probeValue: String {
      let timer = model.activeSleepTimer
      let projection = model.activeSleepTimerProjection
      let history = model.recentSleepHistory
      let latest = history.first
      let context = model.sleepResumeContext
      let position = Int64((max(0, model.playbackState.elapsedSeconds) * 1_000).rounded(.down))
      let journal = model.library.positionJournal.map {
        "\($0.sequence):\($0.reason.rawValue)@\($0.positionMilliseconds)"
      }.joined(separator: ",")
      var tokens = [
        "sleep-timer",
        "active=\(timer?.id.uuidString.lowercased() ?? "none")",
        "selection=\(timer.map { selectionToken($0.selection) } ?? "none")",
        "fade=\(timer.map { String($0.fadeEnabled) } ?? "none")",
        "phase=\(timer?.phase.rawValue ?? "none")",
        "remaining=\(projection?.remainingSeconds.map { String(Int(max(0, $0).rounded(.down))) } ?? "none")",
        "target=\(projection?.targetPositionMilliseconds.map(String.init) ?? "none")",
        "history=\(history.count)",
        "latest=\(latest?.status.rawValue ?? "none")",
        "rewinds=\(model.library.resumeRewindTransactions.count)",
      ]
      if let latest {
        tokens.append(contentsOf: [
          "history-id=\(latest.id.uuidString.lowercased())",
          "history-timer=\(latest.timerID.uuidString.lowercased())",
          "history-selection=\(selectionToken(latest.selection))",
          "stop=\(latest.actualStopPositionMilliseconds)",
          "event=\(latest.positionEventID?.uuidString.lowercased() ?? "none")",
          "context-used=\(latest.resumeContextUsedAt == nil ? "false" : "true")",
        ])
      }
      if let context {
        tokens.append(contentsOf: [
          "context=\(context.historyID.uuidString.lowercased())",
          "context-book=\(context.bookID.uuidString.lowercased())",
          "context-stop=\(context.stoppedPositionMilliseconds)",
          "context-until=\(Int(context.availableUntil.timeIntervalSince1970))",
        ])
      } else {
        tokens.append("context=none")
      }
      tokens.append("position=\(position)")
      tokens.append("playback=\(model.playbackState.status.rawValue)")
      tokens.append("journal=\(journal)")
      return tokens.joined(separator: "|")
    }

    private func selectionToken(_ selection: SleepTimerSelection) -> String {
      switch selection {
      case .preset(let preset): "preset-\(preset.rawValue)"
      case .custom(let seconds): "custom-\(Int(seconds.rounded(.down)))"
      case .endOfChapter: "end-chapter"
      case .endOfTrack: "end-track"
      }
    }
  }
#endif
