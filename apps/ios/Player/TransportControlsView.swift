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
  @State private var isPersisting = false

  init(model: PlayerModel, book: Book? = nil) {
    self.model = model
    self.book = book
    let preferences = book.map { model.transportPreferences(for: $0.id) }
      ?? model.library.globalTransportPreferences
    _usesBookOverride = State(initialValue: book?.transportPreferenceOverride != nil)
    _playbackRate = State(initialValue: preferences.playbackRate)
    _backwardSkipSeconds = State(initialValue: preferences.backwardSkipSeconds)
    _forwardSkipSeconds = State(initialValue: preferences.forwardSkipSeconds)
    _seekContext = State(initialValue: preferences.seekContext)
  }

  var body: some View {
    Form {
      if book != nil, usesBookOverride {
        Section {
          Button("Use Library Defaults") { clearBookOverride() }
            .accessibilityIdentifier("transport-use-library-defaults")
            .disabled(isPersisting)
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
        .onChange(of: playbackRate) { _, _ in usesBookOverride = book != nil }

        Picker("Skip backward", selection: $backwardSkipSeconds) {
          ForEach(Self.skipIntervals, id: \.self) { seconds in
            Text(Self.secondsLabel(seconds)).tag(seconds)
          }
        }
        .accessibilityIdentifier("transport-backward-picker")
        .onChange(of: backwardSkipSeconds) { _, _ in usesBookOverride = book != nil }

        Picker("Skip forward", selection: $forwardSkipSeconds) {
          ForEach(Self.skipIntervals, id: \.self) { seconds in
            Text(Self.secondsLabel(seconds)).tag(seconds)
          }
        }
        .accessibilityIdentifier("transport-forward-picker")
        .onChange(of: forwardSkipSeconds) { _, _ in usesBookOverride = book != nil }

        Picker("Scrubber", selection: $seekContext) {
          Text("Current chapter").tag(PlaybackSeekContext.chapter)
          Text("Whole book").tag(PlaybackSeekContext.wholeBook)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("transport-seek-context")
        .onChange(of: seekContext) { _, _ in usesBookOverride = book != nil }
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
          .disabled(isPersisting)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .accessibilityIdentifier("save-transport-preferences")
          .disabled(isPersisting)
      }
    }
    .accessibilityIdentifier("transport-preferences-screen")
    .accessibilityValue(preferencesValue)
    .e2eScrollReadiness(
      id: "transport-preferences-scroll-readiness",
      containerID: "transport-preferences-screen",
      axis: .vertical
    )
    .alert(
      editorError?.title ?? "Couldn’t Save Playback Settings",
      isPresented: Binding(
        get: { editorError != nil },
        set: { isPresented in
          if !isPresented, let id = editorError?.id {
            model.clearPresentedError(id: id)
          }
        }
      )
    ) {
      Button("OK") {
        if let id = editorError?.id { model.clearPresentedError(id: id) }
      }
    } message: {
      Text(editorError?.message ?? "Bookshelf couldn’t save these playback settings.")
    }
  }

  private var editorError: PlayerPresentationError? {
    model.presentationError(in: .transportPreferences, owner: .transportPreferences)
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
    guard !isPersisting else { return }
    isPersisting = true
    Task {
      let persisted: Bool
      if let book {
        if usesBookOverride {
          persisted = await model.setTransportPreferenceOverride(
            TransportPreferenceOverride(
              playbackRate: preferences.playbackRate,
              backwardSkipSeconds: preferences.backwardSkipSeconds,
              forwardSkipSeconds: preferences.forwardSkipSeconds,
              seekContext: preferences.seekContext
            ),
            for: book.id,
            errorOwner: .transportPreferences
          )
        } else {
          persisted = await model.clearTransportPreferenceOverride(
            for: book.id,
            errorOwner: .transportPreferences
          )
        }
      } else {
        persisted = await model.setGlobalTransportPreferences(
          preferences,
          errorOwner: .transportPreferences
        )
      }
      isPersisting = false
      if persisted { dismiss() }
    }
  }

  private func clearBookOverride() {
    guard let book else { return }
    guard !isPersisting else { return }
    isPersisting = true
    Task {
      let persisted = await model.clearTransportPreferenceOverride(
        for: book.id,
        errorOwner: .transportPreferences
      )
      isPersisting = false
      if persisted { dismiss() }
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
