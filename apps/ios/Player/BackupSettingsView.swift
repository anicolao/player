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
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 24) {
            BackupSettingsSection("Export") {
              BackupSettingsRow {
                HStack {
                  Text("Backup contents")
                    .lineLimit(1)
                    .layoutPriority(1)
                  Spacer(minLength: 4)
                  Picker("Backup contents", selection: $exportKind) {
                    ForEach(PortableBackupKind.allCases, id: \.self) { kind in
                      Text(kind.displayName).tag(kind)
                    }
                  }
                  .labelsHidden()
                  .pickerStyle(.menu)
                  .lineLimit(1)
                  .minimumScaleFactor(0.85)
                }
              }
              BackupSettingsDivider()
              BackupSettingsRow {
                Text(exportExplanation)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
              BackupSettingsDivider()
              BackupSettingsRow {
                Button {
                  Task { await prepareExport() }
                } label: {
                  Label("Export Library Backup", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(isWorking)
                .accessibilityIdentifier("backup-export")
              }
            }
            .id("backup-scroll-top")

            BackupSettingsSection("Restore") {
              BackupSettingsRow {
                Button {
                  isChoosingRestore = true
                } label: {
                  Label("Choose Player Backup", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(isWorking)
                .accessibilityIdentifier("backup-restore")
              }
              BackupSettingsDivider()
              BackupSettingsRow {
                Text(
                  "Player verifies the manifest, artwork, and every audio file before replacing the library. A failed restore leaves the current library untouched."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
              }
            }

            BackupSettingsSection("Automatic database backups") {
              if let latest = automaticBackups.first {
                BackupSettingsRow {
                  LabeledContent(
                    "Latest",
                    value: latest.createdAt.formatted(date: .abbreviated, time: .shortened)
                  )
                }
                BackupSettingsDivider()
                BackupSettingsRow {
                  LabeledContent("Copies", value: "\(automaticBackups.count) of 3")
                }
                BackupSettingsDivider()
                BackupSettingsRow {
                  Button("Restore Latest Database Backup") {
                    confirmsAutomaticRestore = true
                  }
                  .buttonStyle(.plain)
                  .foregroundStyle(.tint)
                  .disabled(isWorking)
                  .accessibilityIdentifier("backup-restore-automatic")
                }
              } else {
                BackupSettingsRow {
                  Text("A backup will appear here after the library changes.")
                    .foregroundStyle(.secondary)
                }
              }
              BackupSettingsDivider()
              BackupSettingsRow {
                Text(
                  "Player rotates up to three local database copies. Audio stays in managed storage and is not duplicated."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("backup-automatic-explanation")
              }
            }

            if isWorking {
              BackupSettingsSection {
                BackupSettingsRow {
                  ProgressView("Checking library integrity…")
                    .accessibilityIdentifier("backup-progress")
                }
              }
            }
            if let message {
              BackupSettingsSection {
                BackupSettingsRow {
                  Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("backup-success")
                }
              }
            }
            #if E2E
              if E2EBackupBridge.shared.isConfigured {
                BackupSettingsSection("Deterministic walkthrough") {
                  BackupSettingsRow {
                    Button("Create Verified Backup") {
                      Task {
                        await runE2EAction { try await E2EBackupBridge.shared.export(using: model) }
                      }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("e2e-backup-export")
                  }
                  BackupSettingsDivider()
                  BackupSettingsRow {
                    Button("Clear Fixture Library") {
                      Task {
                        await runE2EAction { try await E2EBackupBridge.shared.clear(using: model) }
                      }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("e2e-backup-clear")
                  }
                  BackupSettingsDivider()
                  BackupSettingsRow {
                    Button("Restore Verified Backup") {
                      Task {
                        await runE2EAction {
                          try await E2EBackupBridge.shared.restore(using: model)
                        }
                      }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("e2e-backup-restore")
                  }
                }
              }
            #endif
          }
          .padding(.horizontal, 16)
          .padding(.top, 16)
          .padding(.bottom, 48)
        }
        .playerMiniPlayerScrollRunway()
        .accessibilityIdentifier("backup-scroll")
        .background(Color(uiColor: .systemGroupedBackground))
        #if E2E
          .onAppear { scrollBackupToTop(proxy) }
          .onChange(of: e2eRevision) { _, _ in scrollBackupToTop(proxy) }
          .overlay(alignment: .topLeading) {
            if E2EBackupBridge.shared.isConfigured {
              HStack(spacing: 0) {
                e2eTriggerButton("e2e-backup-export") {
                  try await E2EBackupBridge.shared.export(using: model)
                }
                e2eTriggerButton("e2e-backup-clear") {
                  try await E2EBackupBridge.shared.clear(using: model)
                }
                e2eTriggerButton("e2e-backup-restore") {
                  try await E2EBackupBridge.shared.restore(using: model)
                }
              }
            }
          }
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
    private func scrollBackupToTop(_ proxy: ScrollViewProxy) {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        proxy.scrollTo("backup-scroll-top", anchor: .top)
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

    private func e2eTriggerButton(
      _ identifier: String,
      action: @escaping @MainActor () async throws -> Void
    ) -> some View {
      Button {
        Task { await runE2EAction(action) }
      } label: {
        Color.white.opacity(0.001)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Run \(identifier)")
      .accessibilityIdentifier("e2e-trigger-\(identifier)")
      .disabled(isWorking)
    }
  #endif
}

private struct BackupSettingsSection<Content: View>: View {
  let title: String?
  let content: Content

  init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title {
        Text(title)
          .font(.headline)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 16)
      }
      VStack(spacing: 0) {
        content
      }
      .background(Color(uiColor: .secondarySystemGroupedBackground))
      .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct BackupSettingsRow<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
      .contentShape(Rectangle())
  }
}

private struct BackupSettingsDivider: View {
  var body: some View {
    Divider()
      .padding(.leading, 16)
  }
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
