import SwiftUI

struct ImportRecoveryView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: PlayerModel
  let jobID: UUID
  let startImport: () -> Void
  let didCommit: () -> Void

  var body: some View {
    Group {
      if let job, job.phase == .ready, !job.proposals.isEmpty {
        ReviewImportView(model: model, jobID: job.id, didCommit: didCommit)
      } else if let job, let plan = job.recoveryPlan {
        recoveryContent(job: job, plan: plan)
      } else if let job, !job.proposals.isEmpty {
        ReviewImportView(model: model, jobID: job.id, didCommit: didCommit)
      } else {
        ContentUnavailableView("Import unavailable", systemImage: "exclamationmark.triangle")
      }
    }
  }

  private func recoveryContent(job: ImportJob, plan: ImportRecoveryPlan) -> some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Label(recoveryTitle(plan), systemImage: recoverySymbol(plan))
            .font(.headline)
            .foregroundStyle(plan.phase == .ready ? .green : .orange)
          Text(recoveryMessage(plan))
            .font(.subheadline)
            .foregroundStyle(PlayerColor.secondary)
        }
        .padding(.vertical, 4)
      }

      ForEach(plan.globalIssues, id: \.code) { issue in
        Section("Storage") {
          issueSummary(issue)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("import-storage-issue")
            .accessibilityValue(storageIssueValue(issue))
          if issue.remediations.contains(where: { $0.kind == .freeStorage }) {
            NavigationLink {
              StorageSettingsView(model: model)
            } label: {
              Label("Review Storage", systemImage: "internaldrive")
            }
            .accessibilityIdentifier("free-import-storage")
          }
        }
      }

      if !plan.files.isEmpty {
        Section("Selected files") {
          ForEach(plan.files, id: \.file.id) { status in
            recoveryFileRow(status)
          }
        }
      }

      Section {
        recoveryActions(job: job, plan: plan)
      }
    }
    .scrollContentBackground(.hidden)
    .background(PlayerColor.background)
    .navigationTitle("Review Import")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("import-recovery-screen")
    .accessibilityValue(recoveryValue(job: job, plan: plan))
  }

  private func issueSummary(_ issue: ImportRecoveryIssue) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(issueTitle(issue.code)).font(.subheadline.weight(.semibold))
      Text(issue.message).font(.subheadline).foregroundStyle(PlayerColor.secondary)
    }
  }

  private func storageIssueValue(_ issue: ImportRecoveryIssue) -> String {
    let required = issue.requiredBytes ?? 0
    let available = issue.availableBytes ?? 0
    return "required=\(required):available=\(available):source-unchanged=\(issue.sourceIsUnchanged)"
  }

  private func recoveryFileRow(_ status: ImportFileRecoveryStatus) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: fileSymbol(status))
          .foregroundStyle(fileColor(status))
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 4) {
          Text(status.file.filename).font(.subheadline.weight(.semibold))
          Text(fileDetail(status)).font(.caption).foregroundStyle(PlayerColor.secondary)
        }
      }
      if let issue = status.issue {
        HStack(spacing: 10) {
          if issue.remediations.contains(where: { $0.kind == .retryFile }) {
            Button("Retry File") {
              Task { _ = await model.retryImportFile(jobID: jobID, fileID: status.file.id) }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("retry-import-file-\(status.file.id.uuidString.lowercased())")
          }
          if issue.remediations.contains(where: { $0.kind == .removeFile }) {
            Button("Remove") {
              Task { _ = await model.removeImportFile(jobID: jobID, fileID: status.file.id) }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("remove-import-file-\(status.file.id.uuidString.lowercased())")
          }
          if let remediation = issue.remediations.first(where: {
            $0.kind == .openExistingBook && $0.bookID != nil
          }), let bookID = remediation.bookID {
            NavigationLink {
              BookDetailView(model: model, bookID: bookID) { book, position in
                Task { await model.play(bookID: book.id, at: position) }
              }
            } label: {
              Text("Open Existing")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(
              "open-existing-book-\(status.file.id.uuidString.lowercased())"
            )
          }
        }
        .font(.caption.weight(.semibold))
      }
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("recovery-file-\(status.file.id.uuidString.lowercased())")
    .accessibilityValue(fileValue(status))
  }

  @ViewBuilder
  private func recoveryActions(job: ImportJob, plan: ImportRecoveryPlan) -> some View {
    if !plan.globalIssues.isEmpty {
      Button("Try Import Again") {
        Task {
          await model.retryImport(jobID: job.id)
          if model.recoveryPlan(for: job.id) == nil, jobAfterAction?.phase != .failed {
            // The same destination changes to the ordinary proposal review.
          }
        }
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("retry-import")
    }
    if plan.canContinueWithAcceptedFiles {
      Button("Continue with \(plan.acceptedFileCount) Files") {
        Task { _ = await model.continueImportWithAcceptedFiles(jobID: job.id) }
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("continue-partial-import")
    }
    Button("Choose Another Selection") {
      Task {
        await model.cancelImport(jobID: job.id)
        dismiss()
        startImport()
      }
    }
    .accessibilityIdentifier("change-import-selection")
    Button("Cancel Import", role: .cancel) {
      Task {
        await model.cancelImport(jobID: job.id)
        dismiss()
      }
    }
    .accessibilityIdentifier("cancel-import")
  }

  private var job: ImportJob? {
    model.library.importJobs.first(where: { $0.id == jobID })
  }

  private var jobAfterAction: ImportJob? { job }

  private func recoveryValue(job: ImportJob, plan: ImportRecoveryPlan) -> String {
    let globals = plan.globalIssues.map(\.code.rawValue).sorted().joined(separator: ",")
    return [
      "recovery",
      "job=\(job.id.uuidString.lowercased())",
      "phase=\(plan.phase.rawValue)",
      "accepted=\(plan.acceptedFileCount)",
      "duplicates=\(plan.duplicateFileCount)",
      "failed=\(plan.failedFileCount)",
      "global=\(globals.isEmpty ? "none" : globals)",
      "continue=\(plan.canContinueWithAcceptedFiles)",
      "source-unchanged=\(sourceUnchanged(plan))",
    ].joined(separator: ":")
  }

  private func fileValue(_ status: ImportFileRecoveryStatus) -> String {
    let issue = status.issue
    let actions = issue?.remediations.map(\.kind.rawValue).joined(separator: ",") ?? "none"
    return [
      "file=\(status.file.id.uuidString.lowercased())",
      "disposition=\(status.disposition.rawValue)",
      "issue=\(issue?.code.rawValue ?? "none")",
      "recoverable=\(issue?.isRecoverable ?? false)",
      "actions=\(actions.isEmpty ? "none" : actions)",
      "source-unchanged=\(issue?.sourceIsUnchanged ?? true)",
    ].joined(separator: ":")
  }

  private func sourceUnchanged(_ plan: ImportRecoveryPlan) -> Bool {
    let issues = plan.globalIssues + plan.files.compactMap(\.issue)
    return issues.allSatisfy(\.sourceIsUnchanged)
  }

  private func recoveryTitle(_ plan: ImportRecoveryPlan) -> String {
    if !plan.globalIssues.isEmpty { return "More space is needed" }
    if plan.canContinueWithAcceptedFiles { return "Some files need attention" }
    return "This selection needs attention"
  }

  private func recoveryMessage(_ plan: ImportRecoveryPlan) -> String {
    if !plan.globalIssues.isEmpty {
      return "Review storage, choose a smaller selection, or cancel without changing your files."
    }
    if plan.canContinueWithAcceptedFiles {
      return "Fix or remove individual files, then continue with everything Player can safely read."
    }
    return "Retry recoverable files, remove them, or choose another selection."
  }

  private func recoverySymbol(_ plan: ImportRecoveryPlan) -> String {
    plan.globalIssues.isEmpty ? "waveform.badge.exclamationmark" : "externaldrive.badge.exclamationmark"
  }

  private func issueTitle(_ code: ImportRecoveryIssueCode) -> String {
    switch code {
    case .insufficientStorage: "Not enough free space"
    case .duplicateInSelection: "Duplicate in selection"
    case .duplicateInLibrary: "Already in Library"
    case .corruptAudio: "Audio could not be read"
    case .unsupportedFormat: "Unsupported format"
    case .missingSource: "Source is unavailable"
    case .checksumMismatch: "Source changed while copying"
    }
  }

  private func fileDetail(_ status: ImportFileRecoveryStatus) -> String {
    guard let issue = status.issue else { return "Ready to import" }
    return issue.message
  }

  private func fileSymbol(_ status: ImportFileRecoveryStatus) -> String {
    switch status.disposition {
    case .accepted: "checkmark.circle.fill"
    case .duplicate: "doc.on.doc.fill"
    case .failed: "exclamationmark.circle.fill"
    }
  }

  private func fileColor(_ status: ImportFileRecoveryStatus) -> Color {
    switch status.disposition {
    case .accepted: .green
    case .duplicate: .orange
    case .failed: .red
    }
  }
}

struct StorageSettingsView: View {
  @Bindable var model: PlayerModel

  var body: some View {
    List {
      if let summary = model.storageSummary {
        Section("Player storage") {
          storageRow("Audiobooks", bytes: summary.managedMediaBytes, id: "storage-managed")
          storageRow("Imports in progress", bytes: summary.stagingBytes, id: "storage-staging")
          storageRow("Trash", bytes: summary.trashBytes, id: "storage-trash")
          storageRow("Library data", bytes: summary.databaseBytes, id: "storage-database")
          storageRow("Reclaimable", bytes: summary.reclaimableBytes, id: "storage-reclaimable")
          HStack {
            Text("Available on device")
            Spacer()
            Text(summary.availableBytes.map(storageBytes) ?? "Unavailable")
              .foregroundStyle(PlayerColor.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("storage-available")
          .accessibilityValue(summary.availableBytes.map(String.init) ?? "unknown")
        }

        if !summary.perBook.isEmpty {
          Section("Audiobooks") {
            ForEach(summary.perBook, id: \.bookID) { book in
              bookStorageRow(book)
            }
          }
        }

        Section {
          ForEach(stagingManifests, id: \.id) { manifest in
            cleanupRow(
              title: "Incomplete import",
              detail: storageBytes(manifest.byteCount),
              id: "clear-staging-\(scopeID(manifest.scope))"
            ) {
              await clear(manifest.scope)
            }
          }
          ForEach(trashManifests, id: \.id) { manifest in
            cleanupRow(
              title: "Purged audiobook",
              detail: storageBytes(manifest.byteCount),
              id: "clear-trash-\(scopeID(manifest.scope))"
            ) {
              await clear(manifest.scope)
            }
          }
          if stagingManifests.isEmpty && trashManifests.isEmpty {
            Text("No recoverable storage to clear")
              .foregroundStyle(PlayerColor.secondary)
          }
        } header: {
          Text("Safe cleanup")
        } footer: {
          Text("Cleanup never removes audiobook files in your Library or the library database.")
        }
      } else {
        ProgressView("Calculating storage…")
      }
    }
    .scrollContentBackground(.hidden)
    .background(PlayerColor.background)
    .navigationTitle("Storage")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("storage-screen")
    .accessibilityValue(storageValue)
    .task { _ = await model.refreshStorageSummary() }
  }

  private func storageRow(_ title: String, bytes: Int64, id: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(storageBytes(bytes)).foregroundStyle(PlayerColor.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(id)
    .accessibilityValue(String(bytes))
  }

  private func bookStorageRow(_ book: BookStorageSummary) -> some View {
    let identifier = "storage-book-\(book.bookID.uuidString.lowercased())"
    return HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(bookTitle(book.bookID)).font(.subheadline.weight(.semibold))
        Text("\(book.fileCount) files")
          .font(.caption)
          .foregroundStyle(PlayerColor.secondary)
      }
      Spacer()
      Text(storageBytes(book.byteCount)).foregroundStyle(PlayerColor.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier)
    .accessibilityValue(bookStorageValue(book))
  }

  private func cleanupRow(
    title: String,
    detail: String,
    id: String,
    action: @escaping @MainActor () async -> Void
  ) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(detail).font(.caption).foregroundStyle(PlayerColor.secondary)
      }
      Spacer()
      Button("Clear", role: .destructive) { Task { await action() } }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(id)
    }
  }

  private func clear(_ scope: StorageScope) async {
    guard await model.clearRecoverableStorage(scope: scope) else { return }
    _ = await model.refreshStorageSummary()
  }

  private var stagingManifests: [StorageManifest] {
    model.library.storageManifests.filter {
      if case .stagingJob = $0.scope { return true }
      return false
    }
  }

  private var trashManifests: [StorageManifest] {
    model.library.storageManifests.filter {
      if case .trashTransaction = $0.scope { return true }
      return false
    }
  }

  private func scopeID(_ scope: StorageScope) -> String {
    switch scope {
    case .managedBook(let id), .stagingJob(let id), .trashTransaction(let id):
      id.uuidString.lowercased()
    case .database: "database"
    }
  }

  private func bookTitle(_ id: UUID) -> String {
    model.library.books.first(where: { $0.id == id })?.title ?? "Audiobook"
  }

  private func bookStorageValue(_ book: BookStorageSummary) -> String {
    let id = book.bookID.uuidString.lowercased()
    return "book=\(id):bytes=\(book.byteCount):files=\(book.fileCount)"
  }

  private var storageValue: String {
    guard let summary = model.storageSummary else { return "storage:loading" }
    return [
      "storage",
      "used=\(summary.usedBytes)",
      "managed=\(summary.managedMediaBytes)",
      "staging=\(summary.stagingBytes)",
      "trash=\(summary.trashBytes)",
      "database=\(summary.databaseBytes)",
      "available=\(summary.availableBytes.map(String.init) ?? "unknown")",
      "reclaimable=\(summary.reclaimableBytes)",
      "books=\(summary.perBook.count)",
    ].joined(separator: ":")
  }

  private func storageBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
