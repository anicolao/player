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
  @State private var errorMessage: String?
  @State private var preparedSupportBundle: PreparedSupportBundle?
  @State private var preparedSupportBundleToDiscard: PreparedSupportBundle?

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
              "Player preserves the unreadable database in quarantine before restoring or starting over. Managed audiobook files are not deleted."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }
          .padding(18)
          .background(Color(uiColor: .secondarySystemGroupedBackground))
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          Button("Try Opening Again") {
            Task {
              isWorking = true
              await model.retryStartupRestore()
              isWorking = false
            }
          }
          .disabled(isWorking)
          .accessibilityIdentifier("startup-recovery-retry")
          Button("Export Sanitized Support Bundle") {
            Task { await prepareSupportBundle() }
          }
          .disabled(isWorking)
          .accessibilityIdentifier("startup-recovery-diagnostics")
          Button("Start with an Empty Library", role: .destructive) {
            confirmsFreshLibrary = true
          }
          .disabled(isWorking)
          .accessibilityIdentifier("startup-recovery-fresh")
          if isWorking {
            ProgressView("Protecting local data…")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          StateProbe(id: "startup-recovery-probe", value: recoveryProbeValue)
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
    .sheet(item: $preparedSupportBundle, onDismiss: discardPreparedSupportBundle) { bundle in
      SystemSupportBundleExporter(url: bundle.url)
        .ignoresSafeArea()
    }
    .alert(
      "Recovery Couldn’t Be Completed",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "The local recovery operation failed.")
    }
  }

  private var recoveryExplanation: String {
    switch status.issue {
    case .unreadableLibrary:
      "Player could not validate the local catalog. Your audio and every recovery copy remain untouched."
    case .newerLibraryVersion:
      "This catalog was written by a newer Player version. Reinstall that version or restore a compatible local copy."
    case .storageUnavailable:
      "Player could not safely read its local catalog. Try again before choosing a recovery action."
    }
  }

  private var recoveryProbeValue: String {
    "recovery:\(status.issue.rawValue):valid=\(status.validAutomaticBackupCount):"
      + "invalid=\(status.invalidAutomaticBackupCount):preserved=true"
  }

  private func restoreAutomaticBackup() async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await model.recoverFromLatestAutomaticBackup()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func beginFreshLibrary() async {
    isWorking = true
    defer { isWorking = false }
    do {
      try await model.beginFreshLibraryAfterRecovery()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func prepareSupportBundle() async {
    isWorking = true
    defer { isWorking = false }
    do {
      let bundle = try await model.prepareSupportBundle()
      preparedSupportBundleToDiscard = bundle
      preparedSupportBundle = bundle
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func discardPreparedSupportBundle() {
    guard let bundle = preparedSupportBundleToDiscard else { return }
    preparedSupportBundleToDiscard = nil
    Task { await model.discardPreparedSupportBundle(bundle) }
  }
}

struct SupportDiagnosticsView: View {
  @Bindable var model: PlayerModel
  @State private var isWorking = false
  @State private var errorMessage: String?
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
            "Player identifies staging, trash, and managed-media ownership from database IDs and app manifests. It never guesses ownership from audiobook filenames."
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
        }
      #endif
    }
    .navigationTitle("Offline & Support")
    .navigationBarTitleDisplayMode(.inline)
    #if E2E
      .overlay(alignment: .topLeading) {
        if E2EOfflineRecoveryBridge.shared.isConfigured {
          Button {
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
    .sheet(item: $preparedSupportBundle, onDismiss: discardPreparedSupportBundle) { bundle in
      SystemSupportBundleExporter(url: bundle.url)
        .ignoresSafeArea()
    }
    .alert(
      "Support Bundle Couldn’t Be Created",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "The support report could not be prepared.")
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
      errorMessage = error.localizedDescription
    }
  }

  private func discardPreparedSupportBundle() {
    guard let bundle = preparedSupportBundleToDiscard else { return }
    preparedSupportBundleToDiscard = nil
    Task { await model.discardPreparedSupportBundle(bundle) }
  }

  #if E2E
    private func verifySanitizedBundleForE2E() async {
      isWorking = true
      defer {
        isWorking = false
        e2eRevision += 1
      }
      do {
        let bundle = try await model.prepareSupportBundle()
        try E2EOfflineRecoveryBridge.shared.verify(bundle)
        await model.discardPreparedSupportBundle(bundle)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  #endif
}

private struct SystemSupportBundleExporter: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    UIDocumentPickerViewController(forExporting: [url], asCopy: true)
  }

  func updateUIViewController(
    _ uiViewController: UIDocumentPickerViewController,
    context: Context
  ) {}
}
