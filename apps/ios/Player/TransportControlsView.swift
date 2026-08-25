import SwiftUI

struct TransportPreferencesEditor: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: PlayerModel
  let book: Book?

  @State private var usesBookOverride: Bool
  @State private var playbackRate: Double
  @State private var backwardSkipSeconds: Double
  @State private var forwardSkipSeconds: Double
  @State private var seekContext: PlaybackSeekContext

  init(model: PlayerModel, book: Book? = nil) {
    self.model = model
    self.book = book
    let preferences = book.map { model.transportPreferences(for: $0.id) }
      ?? model.library.globalTransportPreferences
    _usesBookOverride = State(initialValue: book != nil)
    _playbackRate = State(initialValue: preferences.playbackRate)
    _backwardSkipSeconds = State(initialValue: preferences.backwardSkipSeconds)
    _forwardSkipSeconds = State(initialValue: preferences.forwardSkipSeconds)
    _seekContext = State(initialValue: preferences.seekContext)
  }

  var body: some View {
    Form {
      if book != nil {
        Section {
          Button("Use Library Defaults") { clearBookOverride() }
            .accessibilityIdentifier("transport-use-library-defaults")
        } footer: {
          Text("This book keeps its own settings until you switch it back to the library defaults.")
        }
      }

      Section("Listening") {
        Picker("Playback speed", selection: $playbackRate) {
          ForEach(Self.playbackRates, id: \.self) { rate in
            Text(Self.rateLabel(rate)).tag(rate)
          }
        }
        .accessibilityIdentifier("transport-rate-picker")

        Picker("Skip backward", selection: $backwardSkipSeconds) {
          ForEach(Self.skipIntervals, id: \.self) { seconds in
            Text(Self.secondsLabel(seconds)).tag(seconds)
          }
        }
        .accessibilityIdentifier("transport-backward-picker")

        Picker("Skip forward", selection: $forwardSkipSeconds) {
          ForEach(Self.skipIntervals, id: \.self) { seconds in
            Text(Self.secondsLabel(seconds)).tag(seconds)
          }
        }
        .accessibilityIdentifier("transport-forward-picker")

        Picker("Scrubber", selection: $seekContext) {
          Text("Current chapter").tag(PlaybackSeekContext.chapter)
          Text("Whole book").tag(PlaybackSeekContext.wholeBook)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("transport-seek-context")
      }

      Section {
        Text("Speed supports 0.5×–3.0× in 0.05× steps. Skip buttons and remote controls use these same intervals.")
          .font(.footnote)
          .foregroundStyle(PlayerColor.secondary)
      }
    }
    .playerMiniPlayerScrollRunway()
    .navigationTitle(book == nil ? "Playback Defaults" : "Book Playback")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .accessibilityIdentifier("save-transport-preferences")
      }
    }
    .accessibilityIdentifier("transport-preferences-screen")
    .accessibilityValue(preferencesValue)
  }

  private var preferencesValue: String {
    let scope = book == nil ? "global" : (usesBookOverride ? "book" : "global")
    return "transport:scope=\(scope):rate=\(Self.rateToken(playbackRate)):back=\(Int(backwardSkipSeconds)):forward=\(Int(forwardSkipSeconds)):seek=\(seekContext == .chapter ? "chapter" : "whole-book")"
  }

  private func save() {
    let preferences = TransportPreferences(
      playbackRate: playbackRate,
      backwardSkipSeconds: backwardSkipSeconds,
      forwardSkipSeconds: forwardSkipSeconds,
      seekContext: seekContext
    )
    Task {
      if let book {
        if usesBookOverride {
          _ = await model.setTransportPreferenceOverride(
            TransportPreferenceOverride(
              playbackRate: preferences.playbackRate,
              backwardSkipSeconds: preferences.backwardSkipSeconds,
              forwardSkipSeconds: preferences.forwardSkipSeconds,
              seekContext: preferences.seekContext
            ),
            for: book.id
          )
        } else {
          _ = await model.clearTransportPreferenceOverride(for: book.id)
        }
      } else {
        _ = await model.setGlobalTransportPreferences(preferences)
      }
      dismiss()
    }
  }

  private func clearBookOverride() {
    guard let book else { return }
    Task {
      _ = await model.clearTransportPreferenceOverride(for: book.id)
      dismiss()
    }
  }

  static let playbackRates = stride(from: 0.5, through: 3.000_1, by: 0.05).map {
    (Double(Int(($0 * 20).rounded())) / 20)
  }
  static let skipIntervals: [Double] = [10, 15, 20, 30, 45, 60]

  static func rateLabel(_ rate: Double) -> String {
    String(format: "%.2f×", rate)
  }

  static func rateToken(_ rate: Double) -> String {
    String(format: "%.2f", rate)
  }

  static func secondsLabel(_ seconds: Double) -> String {
    "\(Int(seconds)) seconds"
  }
}
