import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
  static let playerLibraryBackup = UTType(exportedAs: "com.spnss.player.library-backup")
}

enum BackupExportPickerOutcome: Equatable, Sendable {
  case saved
  case cancelled
}

enum BackupOperationState: Equatable, Sendable {
  case idle
  case preparing(String)
  case awaitingFiles(String)
  case finalizingExport(String)
  case awaitingRestoreSelection
  case confirmingPortableRestore
  case restoringPortable
  case confirmingAutomaticRestore
  case restoringAutomatic
  case succeeded(String)
  case cancelled
  case failed(String)

  var token: String {
    switch self {
    case .idle: "idle"
    case .preparing(let kind): "preparing-\(kind)"
    case .awaitingFiles(let kind): "awaiting-files-\(kind)"
    case .finalizingExport(let kind): "finalizing-export-\(kind)"
    case .awaitingRestoreSelection: "awaiting-restore-selection"
    case .confirmingPortableRestore: "confirming-portable-restore"
    case .restoringPortable: "restoring-portable"
    case .confirmingAutomaticRestore: "confirming-automatic-restore"
    case .restoringAutomatic: "restoring-automatic"
    case .succeeded(let operation): "succeeded-\(operation)"
    case .cancelled: "cancelled"
    case .failed(let operation): "failed-\(operation)"
    }
  }

  var progressLabel: String? {
    switch self {
    case .preparing: "Preparing and checking backup…"
    case .finalizingExport: "Cleaning up prepared backup…"
    case .restoringPortable: "Checking and restoring backup…"
    case .restoringAutomatic: "Restoring database backup…"
    default: nil
    }
  }
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
  @State private var localError: PlayerPresentationError?
  @State private var operationState = BackupOperationState.idle
  @State private var operationTask: Task<Void, Never>?
  #if E2E
    @State private var e2eRevision = 0
    @State private var isPresentingE2ERestoreSelection = false
  #endif

  var body: some View {
    ZStack {
      ScrollViewReader { _ in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 24) {
            BackupSettingsSection("Protect your library") {
              BackupSettingsRow {
                Text(
                  "Bookshelf keeps your library on this iPhone. Export a backup to Files to protect it or move it to another iPhone. Bookshelf never uploads your backup."
                )
                .font(.subheadline)
                .accessibilityIdentifier("backup-purpose")
              }
              BackupSettingsDivider()
              BackupSettingsRow {
                BackupChoiceExplanation(
                  title: "With audio",
                  detail:
                    "A self-contained copy of your books, artwork, edits, listening positions, preferences, and audio.",
                  systemImage: "waveform",
                  identifier: "backup-choice-with-audio"
                )
              }
              BackupSettingsDivider()
              BackupSettingsRow {
                BackupChoiceExplanation(
                  title: "Metadata only",
                  detail:
                    "A smaller copy of your organization, edits, listening positions, and preferences. You will still need the original audio files.",
                  systemImage: "list.bullet.rectangle",
                  identifier: "backup-choice-metadata-only"
                )
              }
              BackupSettingsDivider()
              BackupSettingsRow {
                BackupChoiceExplanation(
                  title: "Automatic copies",
                  detail:
                    "Up to three safety copies stay on this iPhone. They are not portable and do not duplicate your audio.",
                  systemImage: "externaldrive.badge.timemachine",
                  identifier: "backup-choice-automatic"
                )
              }
            }
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
                  .accessibilityIdentifier("backup-export-kind")
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
                  guard !isWorking else { return }
                  isWorking = true
                  operationState = .preparing(exportKind.rawValue)
                  startOperation { await prepareExport() }
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
            BackupSettingsSection("Restore") {
              BackupSettingsRow {
                Button {
                  beginRestoreSelection()
                } label: {
                  Label("Choose Bookshelf Backup", systemImage: "square.and.arrow.down")
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
                  "Before replacing your current library, Bookshelf checks the backup and every included file. If the check fails, nothing changes."
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
                    operationState = .confirmingAutomaticRestore
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
                  "These safety copies stay on this iPhone. They are not portable, and your audio is not duplicated."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("backup-automatic-explanation")
              }
            }

            if let progressLabel = operationState.progressLabel {
              BackupSettingsSection {
                BackupSettingsRow {
                  ProgressView(progressLabel)
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
          }
          .padding(.horizontal, 16)
          .padding(.top, 16)
          .padding(.bottom, 48)
        }
        .playerMiniPlayerScrollRunway()
        .accessibilityIdentifier("backup-scroll")
        .e2eScrollReadiness(
          id: "backup-scroll-readiness",
          containerID: "backup-scroll",
          axis: .vertical
        )
        .background(Color(uiColor: .systemGroupedBackground))
        #if E2E
          .overlay(alignment: .topLeading) {
            if E2EBackupBridge.shared.isConfigured {
              HStack(spacing: 0) {
                e2eTriggerButton("e2e-fixture-clear-library") {
                  try await E2EBackupBridge.shared.clear(using: model)
                }
                e2eTriggerButton("e2e-fixture-replace-catalog") {
                  try await E2EBackupBridge.shared.replaceCatalogPreservingMedia(using: model)
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
          StateProbe(id: "backup-operation-state", value: operationState.token)
        }
      #endif
    }
    .navigationTitle("Backup")
    .navigationBarTitleDisplayMode(.inline)
    .task { await reloadAutomaticBackups() }
    .onDisappear { operationTask?.cancel() }
    .fileImporter(
      isPresented: $isChoosingRestore,
      allowedContentTypes: [.playerLibraryBackup],
      allowsMultipleSelection: false
    ) { result in
      handleRestoreSelection(result)
    }
    #if E2E
      .sheet(isPresented: $isPresentingE2ERestoreSelection) {
        E2EBackupRestoreSelector { result in
          isPresentingE2ERestoreSelection = false
          handleRestoreSelection(result)
        }
      }
    #endif
    .confirmationDialog(
      "Replace this library?",
      isPresented: $confirmsPortableRestore,
      titleVisibility: .visible
    ) {
      Button("Restore Backup", role: .destructive) {
        guard let pendingRestoreURL else { return }
        operationState = .restoringPortable
        startOperation { await restorePortable(from: pendingRestoreURL) }
      }
      .accessibilityIdentifier("backup-confirm-portable-restore")
      Button("Cancel") {
        pendingRestoreURL = nil
        operationState = .cancelled
      }
      .accessibilityIdentifier("backup-cancel-portable-restore")
    } message: {
      Text(
        "The selected backup replaces books, progress, bookmarks, preferences, and managed audio only after every included file passes its integrity check."
      )
    }
    .onChange(of: confirmsPortableRestore) { _, isPresented in
      if !isPresented, operationState == .confirmingPortableRestore {
        pendingRestoreURL = nil
        operationState = .cancelled
      }
    }
    .confirmationDialog(
      "Restore the latest database backup?",
      isPresented: $confirmsAutomaticRestore,
      titleVisibility: .visible
    ) {
      Button("Restore Database", role: .destructive) {
        operationState = .restoringAutomatic
        startOperation { await restoreAutomatic() }
      }
      .accessibilityIdentifier("backup-confirm-automatic-restore")
      Button("Cancel") { operationState = .cancelled }
        .accessibilityIdentifier("backup-cancel-automatic-restore")
    } message: {
      Text(
        "Managed audio is left in place. Current library organization and listening data will be replaced."
      )
    }
    .onChange(of: confirmsAutomaticRestore) { _, isPresented in
      if !isPresented, operationState == .confirmingAutomaticRestore {
        operationState = .cancelled
      }
    }
    .sheet(item: $preparedBackup, onDismiss: cancelUndeliveredPreparedBackup) { backup in
      #if E2E
        if E2EBackupBridge.shared.isConfigured {
          E2EBackupExporter(
            backup: backup,
            onOutcome: { finishExport(backup, outcome: $0) },
            onFailure: { finishExport(backup, failure: $0) }
          )
        } else {
          SystemBackupExporter(url: backup.url) { outcome in
            finishExport(backup, outcome: outcome)
          }
          .ignoresSafeArea()
        }
      #else
        SystemBackupExporter(url: backup.url) { outcome in
          finishExport(backup, outcome: outcome)
        }
        .ignoresSafeArea()
      #endif
    }
    .alert(
      localError?.title ?? "Couldn’t Complete Backup",
      isPresented: Binding(
        get: { localError != nil },
        set: { if !$0 { localError = nil } }
      )
    ) {
      Button("OK") { localError = nil }
    } message: {
      Text(localError?.message ?? "The backup operation failed.")
    }
  }

  private var exportExplanation: String {
    switch exportKind {
    case .metadataOnly:
      "Choose a Files destination. This smaller backup needs your original audio files when you restore it."
    case .includingMedia:
      "Choose a Files destination. This self-contained backup can restore your library and its audio."
    }
  }

  private func beginRestoreSelection() {
    operationState = .awaitingRestoreSelection
    #if E2E
      if E2EBackupBridge.shared.isConfigured {
        isPresentingE2ERestoreSelection = true
        return
      }
    #endif
    isChoosingRestore = true
  }

  private func handleRestoreSelection(_ result: Result<[URL], Error>) {
    guard case .success(let urls) = result, let url = urls.first else {
      if case .failure(let error) = result,
        !SystemSelectionCancellation.isCancellation(error)
      {
        presentRecoveryError(error)
      } else {
        operationState = .cancelled
      }
      return
    }
    pendingRestoreURL = url
    operationState = .confirmingPortableRestore
    confirmsPortableRestore = true
  }

  private func prepareExport() async {
    message = nil
    defer { isWorking = false }
    do {
      let backup = try await model.prepareLibraryBackup(kind: exportKind)
      try Task.checkCancellation()
      preparedBackupToDiscard = backup
      preparedBackup = backup
      operationState = .awaitingFiles(backup.kind.rawValue)
    } catch is CancellationError {
      operationState = .cancelled
    } catch {
      operationState = .failed("export")
      localError = PlayerPresentationError.presenting(error, in: .backup)
    }
  }

  private func cancelUndeliveredPreparedBackup() {
    guard let backup = preparedBackupToDiscard else { return }
    finishExport(backup, outcome: .cancelled)
  }

  private func finishExport(
    _ backup: PreparedLibraryBackup,
    outcome: BackupExportPickerOutcome
  ) {
    guard preparedBackupToDiscard?.url == backup.url else { return }
    preparedBackupToDiscard = nil
    preparedBackup = nil
    operationState = .finalizingExport(backup.kind.rawValue)
    startOperation {
      await model.discardPreparedLibraryBackup(backup)
      switch outcome {
      case .saved:
        message = "\(backup.kind.displayName) backup saved to Files."
        operationState = .succeeded("export-\(backup.kind.rawValue)")
      case .cancelled:
        operationState = .cancelled
      }
      #if E2E
        e2eRevision += 1
      #endif
    }
  }

  private func finishExport(_ backup: PreparedLibraryBackup, failure: any Error) {
    guard preparedBackupToDiscard?.url == backup.url else { return }
    preparedBackupToDiscard = nil
    preparedBackup = nil
    operationState = .finalizingExport(backup.kind.rawValue)
    startOperation {
      await model.discardPreparedLibraryBackup(backup)
      operationState = .failed("export")
      localError = PlayerPresentationError.presenting(failure, in: .backup)
      #if E2E
        e2eRevision += 1
      #endif
    }
  }

  private func restorePortable(from url: URL) async {
    isWorking = true
    message = nil
    operationState = .restoringPortable
    pendingRestoreURL = nil
    defer { isWorking = false }
    do {
      try await model.restoreLibraryBackup(from: url)
      message = "Library restored from the verified Bookshelf backup."
      operationState = .succeeded("portable-restore")
      await reloadAutomaticBackups()
      #if E2E
        e2eRevision += 1
      #endif
    } catch is CancellationError {
      operationState = .cancelled
    } catch {
      presentRecoveryError(error)
    }
  }

  private func restoreAutomatic() async {
    isWorking = true
    message = nil
    operationState = .restoringAutomatic
    defer { isWorking = false }
    do {
      try await model.restoreLatestAutomaticLibraryBackup()
      message = "Library restored from the latest valid database backup."
      operationState = .succeeded("automatic-restore")
      await reloadAutomaticBackups()
      #if E2E
        e2eRevision += 1
      #endif
    } catch is CancellationError {
      operationState = .cancelled
    } catch {
      presentRecoveryError(error)
    }
  }

  private func reloadAutomaticBackups() async {
    automaticBackups = await model.automaticLibraryBackups()
  }

  private func startOperation(_ operation: @escaping @MainActor () async -> Void) {
    operationTask?.cancel()
    operationTask = Task { await operation() }
  }

  #if E2E
    private func runE2EAction(_ action: @escaping @MainActor () async throws -> Void) async {
      isWorking = true
      message = nil
      defer {
        isWorking = false
        e2eRevision += 1
      }
      do {
        try await action()
        await reloadAutomaticBackups()
      } catch {
        localError = PlayerPresentationError.presenting(error, in: .backup)
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

  private func presentRecoveryError(_ error: any Error) {
    operationState = .failed("restore")
    localError = PlayerPresentationError.presenting(
      error,
      in: .recovery,
      owner: .backupSettings
    )
  }
}

#if E2E
  private struct E2EBackupExporter: View {
    let backup: PreparedLibraryBackup
    let onOutcome: @MainActor (BackupExportPickerOutcome) -> Void
    let onFailure: @MainActor (any Error) -> Void

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
              try E2EBackupBridge.shared.saveToFiles(backup)
              onOutcome(.saved)
            } catch {
              onFailure(error)
            }
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("e2e-files-save-backup")
          Button("Cancel") { onOutcome(.cancelled) }
            .accessibilityIdentifier("e2e-files-cancel-export")
          Button("Simulate Provider Failure") {
            onFailure(
              PlayerCoreError.fileOperation(
                "The selected Files provider could not save the backup."
              )
            )
          }
          .accessibilityIdentifier("e2e-files-fail-export")
        }
        .padding(28)
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
      }
    }
  }

  private struct E2EBackupRestoreSelector: View {
    let onSelection: @MainActor (Result<[URL], Error>) -> Void

    var body: some View {
      NavigationStack {
        List {
          Button("Bookshelf Backup") {
            select { try E2EBackupBridge.shared.selectedBackupFromFiles() }
          }
          .accessibilityIdentifier("e2e-files-select-backup")
          Button("Tampered Backup") {
            select { try E2EBackupBridge.shared.tamperedBackupFromFiles() }
          }
          .accessibilityIdentifier("e2e-files-select-tampered-backup")
          Button("Incompatible Backup") {
            select { try E2EBackupBridge.shared.incompatibleBackupFromFiles() }
          }
          .accessibilityIdentifier("e2e-files-select-incompatible-backup")
          Button("Cancel", role: .cancel) {
            onSelection(.failure(CancellationError()))
          }
          .accessibilityIdentifier("e2e-files-cancel-restore")
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
      }
    }

    private func select(_ selection: () throws -> URL) {
      do {
        onSelection(.success([try selection()]))
      } catch {
        onSelection(.failure(error))
      }
    }
  }
#endif

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

private struct BackupChoiceExplanation: View {
  let title: String
  let detail: String
  let systemImage: String
  let identifier: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .foregroundStyle(.tint)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(detail)
    .accessibilityIdentifier(identifier)
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

struct SystemBackupExporter: UIViewControllerRepresentable {
  let url: URL
  let onOutcome: @MainActor (BackupExportPickerOutcome) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onOutcome: onOutcome)
  }

  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    picker.delegate = context.coordinator
    picker.presentationController?.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(
    _ uiViewController: UIDocumentPickerViewController,
    context: Context
  ) {}

  @MainActor
  final class Coordinator: NSObject, UIDocumentPickerDelegate,
    UIAdaptivePresentationControllerDelegate
  {
    private let onOutcome: @MainActor (BackupExportPickerOutcome) -> Void
    private var didFinish = false

    init(onOutcome: @escaping @MainActor (BackupExportPickerOutcome) -> Void) {
      self.onOutcome = onOutcome
    }

    func documentPicker(
      _ controller: UIDocumentPickerViewController,
      didPickDocumentsAt urls: [URL]
    ) {
      finish(.saved)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
      finish(.cancelled)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
      finish(.cancelled)
    }

    private func finish(_ outcome: BackupExportPickerOutcome) {
      guard !didFinish else { return }
      didFinish = true
      onOutcome(outcome)
    }
  }
}
