import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
  static let playerLibraryBackup = UTType(exportedAs: "com.spnss.player.library-backup")
}

struct BackupSettingsView: View {
  @Bindable var model: PlayerModel
  @State private var exportKind = PortableBackupKind.includingMedia
  @State private var isWorking = false
  @State private var preparedBackup: PreparedLibraryBackup?
  @State private var preparedBackupToDiscard: PreparedLibraryBackup?
  @State private var isChoosingRestore = false
  @State private var pendingRestoreURL: URL?
  @State private var confirmsPortableRestore = false
  @State private var confirmsAutomaticRestore = false
  @State private var automaticBackups: [AutomaticLibraryBackup] = []
  @State private var message: String?
  @State private var errorMessage: String?
  #if E2E
    @State private var e2eRevision = 0
  #endif

  var body: some View {
    ZStack {
      ScrollViewReader { proxy in
        List {
          Section("Export") {
            Picker("Backup contents", selection: $exportKind) {
              ForEach(PortableBackupKind.allCases, id: \.self) { kind in
                Text(kind.displayName).tag(kind)
              }
            }
            Text(exportExplanation)
              .font(.footnote)
              .foregroundStyle(.secondary)
            Button {
              Task { await prepareExport() }
            } label: {
              Label("Export Library Backup", systemImage: "square.and.arrow.up")
            }
            .disabled(isWorking)
            .accessibilityIdentifier("backup-export")
          }
          .id("backup-scroll-top")

          Section("Restore") {
            Button {
              isChoosingRestore = true
            } label: {
              Label("Choose Player Backup", systemImage: "square.and.arrow.down")
            }
            .disabled(isWorking)
            .accessibilityIdentifier("backup-restore")
            Text(
              "Player verifies the manifest, artwork, and every audio file before replacing the library. A failed restore leaves the current library untouched."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }

          Section("Automatic database backups") {
            if let latest = automaticBackups.first {
              LabeledContent(
                "Latest", value: latest.createdAt.formatted(date: .abbreviated, time: .shortened))
              LabeledContent("Copies", value: "\(automaticBackups.count) of 3")
              Button("Restore Latest Database Backup") {
                confirmsAutomaticRestore = true
              }
              .disabled(isWorking)
              .accessibilityIdentifier("backup-restore-automatic")
            } else {
              Text("A backup will appear here after the library changes.")
                .foregroundStyle(.secondary)
            }
            Text(
              "Player rotates up to three local database copies. Audio stays in managed storage and is not duplicated."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
          }

          if isWorking {
            Section {
              ProgressView("Checking library integrity…")
                .accessibilityIdentifier("backup-progress")
            }
          }
          if let message {
            Section {
              Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("backup-success")
            }
          }
          #if E2E
            if E2EBackupBridge.shared.isConfigured {
              Section("Deterministic walkthrough") {
                Button("Create Verified Backup") {
                  Task {
                    await runE2EAction { try await E2EBackupBridge.shared.export(using: model) }
                  }
                }
                .accessibilityIdentifier("e2e-backup-export")
                Button("Clear Fixture Library") {
                  Task {
                    await runE2EAction { try await E2EBackupBridge.shared.clear(using: model) }
                  }
                }
                .accessibilityIdentifier("e2e-backup-clear")
                Button("Restore Verified Backup") {
                  Task {
                    await runE2EAction { try await E2EBackupBridge.shared.restore(using: model) }
                  }
                }
                .accessibilityIdentifier("e2e-backup-restore")
              }
            }
          #endif
        }
        #if E2E
          .onAppear { scrollWalkthroughToTop(proxy) }
          .onChange(of: e2eRevision) { _, _ in scrollWalkthroughToTop(proxy) }
        #endif
      }
      #if E2E
        if E2EBackupBridge.shared.isConfigured {
          StateProbe(
            id: "backup-e2e-probe",
            value: E2EBackupBridge.shared.value(for: model)
          )
          .id(e2eRevision)
        }
      #endif
    }
    .navigationTitle("Backup")
    .navigationBarTitleDisplayMode(.inline)
    .task { await reloadAutomaticBackups() }
    .fileImporter(
      isPresented: $isChoosingRestore,
      allowedContentTypes: [.playerLibraryBackup],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else {
        if case .failure(let error) = result { errorMessage = error.localizedDescription }
        return
      }
      pendingRestoreURL = url
      confirmsPortableRestore = true
    }
    .confirmationDialog(
      "Replace this library?",
      isPresented: $confirmsPortableRestore,
      titleVisibility: .visible
    ) {
      Button("Restore Backup", role: .destructive) {
        guard let pendingRestoreURL else { return }
        Task { await restorePortable(from: pendingRestoreURL) }
      }
      Button("Cancel", role: .cancel) { pendingRestoreURL = nil }
    } message: {
      Text(
        "The selected backup replaces books, progress, bookmarks, preferences, and managed audio only after every included file passes its integrity check."
      )
    }
    .confirmationDialog(
      "Restore the latest database backup?",
      isPresented: $confirmsAutomaticRestore,
      titleVisibility: .visible
    ) {
      Button("Restore Database", role: .destructive) {
        Task { await restoreAutomatic() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Managed audio is left in place. Current library organization and listening data will be replaced."
      )
    }
    .sheet(item: $preparedBackup, onDismiss: discardPreparedBackup) { backup in
      SystemBackupExporter(url: backup.url)
        .ignoresSafeArea()
    }
    .alert(
      "Backup Couldn’t Be Completed",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "The backup operation failed.")
    }
  }

  private var exportExplanation: String {
    switch exportKind {
    case .metadataOnly:
      "A small catalog backup. Restoring it requires the same verified audio to remain on this device."
    case .includingMedia:
      "A portable package containing the catalog, artwork, listening data, and one verified copy of every audiobook."
    }
  }

  private func prepareExport() async {
    isWorking = true
    message = nil
    defer { isWorking = false }
    do {
      let backup = try await model.prepareLibraryBackup(kind: exportKind)
      preparedBackupToDiscard = backup
      preparedBackup = backup
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func discardPreparedBackup() {
    guard let backup = preparedBackupToDiscard else { return }
    preparedBackupToDiscard = nil
    Task { await model.discardPreparedLibraryBackup(backup) }
  }

  private func restorePortable(from url: URL) async {
    isWorking = true
    message = nil
    pendingRestoreURL = nil
    defer { isWorking = false }
    do {
      try await model.restoreLibraryBackup(from: url)
      message = "Library restored from the verified Player backup."
      await reloadAutomaticBackups()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func restoreAutomatic() async {
    isWorking = true
    message = nil
    defer { isWorking = false }
    do {
      try await model.restoreLatestAutomaticLibraryBackup()
      message = "Library restored from the latest valid database backup."
      await reloadAutomaticBackups()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func reloadAutomaticBackups() async {
    automaticBackups = await model.automaticLibraryBackups()
  }

  #if E2E
    private func scrollWalkthroughToTop(_ proxy: ScrollViewProxy) {
      Task { @MainActor in
        // A hosted simulator can deliver onAppear before List has resolved its
        // variable-height rows. Wait for that layout pass so scrollTo never
        // uses provisional row estimates.
        try? await Task.sleep(for: .milliseconds(500))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          proxy.scrollTo("backup-scroll-top", anchor: .top)
        }
      }
    }

    private func runE2EAction(_ action: @escaping @MainActor () async throws -> Void) async {
      isWorking = true
      message = nil
      defer {
        isWorking = false
        e2eRevision += 1
      }
      do {
        try await action()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  #endif
}

extension PreparedLibraryBackup: Identifiable {
  var id: URL { url }
}

private struct SystemBackupExporter: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    UIDocumentPickerViewController(forExporting: [url], asCopy: true)
  }

  func updateUIViewController(
    _ uiViewController: UIDocumentPickerViewController,
    context: Context
  ) {}
}
