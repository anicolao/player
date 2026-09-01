import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
  static let playerSupportBundle = UTType(exportedAs: "com.spnss.player.support-bundle")
}

struct StartupRecoveryView: View {
  @Bindable var model: PlayerModel
  let status: StartupRecoveryStatus
  @State private var isWorking = false
  @State private var confirmsFreshLibrary = false
  @State private var localError: PlayerPresentationError?
  @State private var preparedSupportBundle: PreparedSupportBundle?
  @State private var preparedSupportBundleToDiscard: PreparedSupportBundle?
  @State private var recoveryActionState = "idle"
  @State private var supportExportMessage: String?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Image(systemName: "externaldrive.badge.exclamationmark")
            .font(.system(size: 52, weight: .semibold))
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 10) {
            Text("Your library needs recovery")
              .font(.largeTitle.bold())
            Text(recoveryExplanation)
              .foregroundStyle(.secondary)
          }
          if status.canRestoreAutomaticBackup {
            Button {
              Task { await restoreAutomaticBackup() }
            } label: {
              Label("Restore Latest Safe Copy", systemImage: "clock.arrow.circlepath")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)
            .accessibilityIdentifier("startup-recovery-restore")
          }
          VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Valid local copies", value: "\(status.validAutomaticBackupCount)")
            if status.invalidAutomaticBackupCount > 0 {
              LabeledContent(
                "Unreadable local copies",
                value: "\(status.invalidAutomaticBackupCount)"
              )
            }
            Text(
              "Bookshelf preserves the unreadable database in quarantine before restoring or starting over. Managed audiobook files are not deleted."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          .padding(18)
          .background(Color(uiColor: .secondarySystemGroupedBackground))
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          Button("Try Opening Again") {
            Task { await retryOpeningLibrary() }
          }
          .disabled(isWorking)
          .accessibilityIdentifier("startup-recovery-retry")
          Button("Export Sanitized Support Bundle") {
            Task { await prepareSupportBundle() }
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
          .disabled(isWorking)
          .accessibilityIdentifier("startup-recovery-diagnostics")
          Button("Start with an Empty Library", role: .destructive) {
            confirmsFreshLibrary = true
          }
          .disabled(isWorking)
          .accessibilityIdentifier("startup-recovery-fresh")
          if let supportExportMessage {
            Label(supportExportMessage, systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
              .accessibilityIdentifier("startup-recovery-support-export-result")
          }
          if isWorking {
            ProgressView("Protecting local data…")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          StateProbe(id: "startup-recovery-probe", value: recoveryProbeValue)
          StateProbe(id: "startup-recovery-action-state", value: recoveryActionState)
          #if E2E
            if E2EOfflineRecoveryBridge.shared.isConfigured {
              StateProbe(
                id: "offline-recovery-action-probe",
                value: E2EOfflineRecoveryBridge.shared.preservationValue
              )
            }
          #endif
        }
        .padding(24)
      }
      .playerMiniPlayerScrollRunway()
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle("Library Recovery")
      .navigationBarTitleDisplayMode(.inline)
    }
    .confirmationDialog(
      "Start with an empty library?",
      isPresented: $confirmsFreshLibrary,
      titleVisibility: .visible
    ) {
      Button("Preserve Old Database and Start Fresh", role: .destructive) {
        Task { await beginFreshLibrary() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "The unreadable database and unrecognized app-owned files stay quarantined for support recovery."
      )
    }
    .sheet(item: $preparedSupportBundle, onDismiss: cancelUndeliveredSupportBundle) { bundle in
      #if E2E
        if E2EOfflineRecoveryBridge.shared.isConfigured {
          E2ESupportBundleExporter(
            bundle: bundle,
            onOutcome: { finishSupportBundleExport(bundle, outcome: $0) }
          )
        } else {
          SystemSupportBundleExporter(url: bundle.url) {
            finishSupportBundleExport(bundle, outcome: $0)
          }
          .ignoresSafeArea()
        }
      #else
        SystemSupportBundleExporter(url: bundle.url) {
          finishSupportBundleExport(bundle, outcome: $0)
        }
        .ignoresSafeArea()
      #endif
    }
    .alert(
      localError?.title ?? "Couldn’t Restore Library",
      isPresented: Binding(
        get: { localError != nil },
        set: { if !$0 { localError = nil } }
      )
    ) {
      Button("OK") { localError = nil }
    } message: {
      Text(localError?.message ?? "The local recovery operation failed.")
    }
  }

  private var recoveryExplanation: String {
    switch status.issue {
    case .unreadableLibrary:
      "Bookshelf could not validate the local catalog. Your audio and every recovery copy remain untouched."
    case .newerLibraryVersion:
      "This catalog was written by a newer Bookshelf version. Reinstall that version or restore a compatible local copy."
    case .storageUnavailable:
      "Bookshelf cannot currently reach its protected local storage. This does not mean the catalog is damaged; unlock storage and try again."
    }
  }

  private var recoveryProbeValue: String {
    "recovery:\(status.issue.rawValue):valid=\(status.validAutomaticBackupCount):"
      + "invalid=\(status.invalidAutomaticBackupCount):preserved=true"
  }

  private func retryOpeningLibrary() async {
    isWorking = true
    recoveryActionState = "retrying"
    await model.retryStartupRestore()
    isWorking = false
    guard model.startupRecoveryStatus != nil else { return }
    recoveryActionState = "retry-failed"
    localError = PlayerPresentationError.presenting(
      "Bookshelf still cannot open this library. No library files were changed; you can try again, export a support bundle, or choose another recovery option.",
      in: .recovery,
      owner: .startupRecovery,
      recoveryAction: .retry
    )
  }

  private func restoreAutomaticBackup() async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await model.recoverFromLatestAutomaticBackup()
    } catch {
      localError = PlayerPresentationError.presenting(error, in: .recovery)
    }
  }

  private func beginFreshLibrary() async {
    isWorking = true
    recoveryActionState = "starting-fresh"
    defer { isWorking = false }
    do {
      try await model.beginFreshLibraryAfterRecovery()
    } catch {
      localError = PlayerPresentationError.presenting(error, in: .recovery)
    }
  }

  private func prepareSupportBundle() async {
    isWorking = true
    recoveryActionState = "preparing-support"
    supportExportMessage = nil
    defer { isWorking = false }
    do {
      let bundle = try await model.prepareSupportBundle()
      preparedSupportBundleToDiscard = bundle
      preparedSupportBundle = bundle
      recoveryActionState = "awaiting-files"
    } catch {
      recoveryActionState = "support-preparation-failed"
      localError = PlayerPresentationError.presenting(
        error,
        in: .diagnostics,
        owner: .startupRecovery
      )
    }
  }

  private func cancelUndeliveredSupportBundle() {
    guard let bundle = preparedSupportBundleToDiscard else { return }
    finishSupportBundleExport(bundle, outcome: .cancelled)
  }

  private func finishSupportBundleExport(
    _ bundle: PreparedSupportBundle,
    outcome: SupportBundleExportPickerOutcome
  ) {
    guard preparedSupportBundleToDiscard?.url == bundle.url else { return }
    preparedSupportBundleToDiscard = nil
    preparedSupportBundle = nil
    recoveryActionState = "finalizing-support"
    Task {
      await model.discardPreparedSupportBundle(bundle)
      #if E2E
        E2EOfflineRecoveryBridge.shared.recordBoundaryOutcome()
      #endif
      recoveryActionState = outcome == .saved ? "support-saved" : "support-cancelled"
      supportExportMessage = outcome == .saved ? "Support bundle saved to Files." : nil
    }
  }
}

struct SupportDiagnosticsView: View {
  @Bindable var model: PlayerModel
  @State private var isWorking = false
  @State private var localError: PlayerPresentationError?
  @State private var preparedSupportBundle: PreparedSupportBundle?
  @State private var preparedSupportBundleToDiscard: PreparedSupportBundle?
  #if E2E
    @State private var e2eRevision = 0
  #endif

  var body: some View {
    ZStack {
      List {
        Section("Offline library") {
          Label("Core library works without Internet", systemImage: "wifi.slash")
          Text(
            "Files import, browsing, search, metadata editing, playback, bookmarks, backup, and recovery use only local storage. Receiving from a computer uses the local network only while its screen is open."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        Section("Startup integrity") {
          if let reconciliation = model.startupReconciliation,
            reconciliation.quarantinedItemCount > 0
          {
            LabeledContent(
              "Quarantined app-owned items",
              value: "\(reconciliation.quarantinedItemCount)"
            )
          } else {
            Label("Storage records reconciled", systemImage: "checkmark.shield")
              .foregroundStyle(.green)
          }
          Text(
            "Bookshelf identifies staging, trash, and managed-media ownership from database IDs and app manifests. It never guesses ownership from audiobook filenames."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        Section("Support") {
          Button {
            Task { await prepareSupportBundle() }
          } label: {
            Label("Export Sanitized Support Bundle", systemImage: "square.and.arrow.up")
          }
          .disabled(isWorking)
          .accessibilityIdentifier("diagnostics-export")
          Text(
            "The report contains app/schema versions and aggregate counts only. It excludes titles, contributors, notes, source filenames, paths, checksums, pairing data, and listening history."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        if isWorking {
          Section { ProgressView("Preparing sanitized report…") }
        }
      }
      .playerMiniPlayerScrollRunway()
      StateProbe(id: "diagnostics-probe", value: diagnosticsProbeValue)
      #if E2E
        if E2EOfflineRecoveryBridge.shared.isConfigured {
          StateProbe(
            id: "offline-recovery-diagnostics-probe",
            value: E2EOfflineRecoveryBridge.shared.diagnosticsValue
          )
          .id(e2eRevision)
          StateProbe(
            id: "offline-recovery-action-probe",
            value: E2EOfflineRecoveryBridge.shared.preservationValue
          )
          .id(e2eRevision)
        }
      #endif
    }
    .navigationTitle("Offline & Support")
    .navigationBarTitleDisplayMode(.inline)
    #if E2E
      .overlay(alignment: .topLeading) {
        if E2EOfflineRecoveryBridge.shared.isConfigured {
          Button {
            guard !isWorking else { return }
            isWorking = true
            Task { await verifySanitizedBundleForE2E() }
          } label: {
            Color.white.opacity(0.001)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Verify sanitized support bundle")
          .accessibilityIdentifier("e2e-verify-diagnostics")
          .disabled(isWorking)
        }
      }
    #endif
    .sheet(item: $preparedSupportBundle, onDismiss: cancelUndeliveredSupportBundle) { bundle in
      SystemSupportBundleExporter(url: bundle.url) {
        finishSupportBundleExport(bundle, outcome: $0)
      }
      .ignoresSafeArea()
    }
    .alert(
      localError?.title ?? "Couldn’t Create Support Bundle",
      isPresented: Binding(
        get: { localError != nil },
        set: { if !$0 { localError = nil } }
      )
    ) {
      Button("OK") { localError = nil }
    } message: {
      Text(localError?.message ?? "The support report could not be prepared.")
    }
  }

  private var diagnosticsProbeValue: String {
    let quarantined = model.startupReconciliation?.quarantinedItemCount ?? 0
    return "diagnostics:sanitized=true:offline=true:quarantined=\(quarantined)"
  }

  private func prepareSupportBundle() async {
    isWorking = true
    defer { isWorking = false }
    do {
      let bundle = try await model.prepareSupportBundle()
      preparedSupportBundleToDiscard = bundle
      preparedSupportBundle = bundle
    } catch {
      localError = PlayerPresentationError.presenting(error, in: .diagnostics)
    }
  }

  private func cancelUndeliveredSupportBundle() {
    guard let bundle = preparedSupportBundleToDiscard else { return }
    finishSupportBundleExport(bundle, outcome: .cancelled)
  }

  private func finishSupportBundleExport(
    _ bundle: PreparedSupportBundle,
    outcome: SupportBundleExportPickerOutcome
  ) {
    guard preparedSupportBundleToDiscard?.url == bundle.url else { return }
    preparedSupportBundleToDiscard = nil
    preparedSupportBundle = nil
    Task { await model.discardPreparedSupportBundle(bundle) }
  }

  #if E2E
    private func verifySanitizedBundleForE2E() async {
      defer {
        isWorking = false
        e2eRevision += 1
        E2EOperationEvent.postSupportVerificationFinished()
      }
      do {
        let bundle = try await model.prepareSupportBundle()
        try E2EOfflineRecoveryBridge.shared.verify(bundle)
        await model.discardPreparedSupportBundle(bundle)
      } catch {
        localError = PlayerPresentationError.presenting(error, in: .diagnostics)
      }
    }
  #endif
}

private enum SupportBundleExportPickerOutcome: Equatable {
  case saved
  case cancelled
}

private struct SystemSupportBundleExporter: UIViewControllerRepresentable {
  let url: URL
  let onOutcome: @MainActor (SupportBundleExportPickerOutcome) -> Void

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(
    _ uiViewController: UIDocumentPickerViewController,
    context: Context
  ) {}

  func makeCoordinator() -> Coordinator { Coordinator(onOutcome: onOutcome) }

  final class Coordinator: NSObject, UIDocumentPickerDelegate {
    let onOutcome: @MainActor (SupportBundleExportPickerOutcome) -> Void

    init(onOutcome: @escaping @MainActor (SupportBundleExportPickerOutcome) -> Void) {
      self.onOutcome = onOutcome
    }

    func documentPicker(
      _ controller: UIDocumentPickerViewController,
      didPickDocumentsAt urls: [URL]
    ) {
      Task { @MainActor in onOutcome(.saved) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      Task { @MainActor in onOutcome(.cancelled) }
    }
  }
}

#if E2E
  private struct E2ESupportBundleExporter: View {
    let bundle: PreparedSupportBundle
    let onOutcome: @MainActor (SupportBundleExportPickerOutcome) -> Void

    var body: some View {
      NavigationStack {
        VStack(spacing: 20) {
          Image(systemName: "folder.badge.plus")
            .font(.system(size: 44))
            .foregroundStyle(.tint)
          Text("Choose a destination in Files")
            .font(.headline)
          Text(
            "This deterministic boundary stands in only for the system Files destination picker."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          Button("Save") {
            do {
              try E2EOfflineRecoveryBridge.shared.saveSupportBundleToFiles(bundle)
              onOutcome(.saved)
            } catch {
              onOutcome(.cancelled)
            }
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("e2e-files-save-support-bundle")
          Button("Cancel") { onOutcome(.cancelled) }
            .accessibilityIdentifier("e2e-files-cancel-support-bundle")
        }
        .padding(28)
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
      }
    }
  }
#endif
