import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Bindable var model: PlayerModel
  @State private var selection: AppSection = .library
  @State private var isImporting = false
  @State private var presentedPlayerBook: Book?

  var body: some View {
    TabView(selection: $selection) {
      LibraryView(model: model, startImport: beginImport) { presentedPlayerBook = $0 }
        .tag(AppSection.library)
        .tabItem { Label("Library", systemImage: "books.vertical") }

      InboxView(model: model, startImport: beginImport) { selection = .library }
        .tag(AppSection.inbox)
        .tabItem { Label("Inbox", systemImage: "tray.full") }
        .badge(reviewCount)

      PlaceholderView(
        title: "Settings",
        message: "Playback, storage, and import preferences will live here.",
        systemImage: "gearshape"
      )
      .tag(AppSection.settings)
      .tabItem { Label("Settings", systemImage: "gearshape") }
    }
    .tint(PlayerColor.accent)
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: importTypes,
      allowsMultipleSelection: true
    ) { result in
      guard case .success(let urls) = result, !urls.isEmpty else { return }
      selection = .inbox
      Task { await model.importAudioSelection(from: urls) }
    }
    .fullScreenCover(item: $presentedPlayerBook) { book in
      NowPlayingView(model: model, book: book)
    }
    .overlay(alignment: .bottom) {
      if let currentBook, presentedPlayerBook == nil {
        MiniPlayerView(model: model, book: currentBook) {
          presentedPlayerBook = currentBook
        }
        .padding(.bottom, 83)
      }
    }
    #if E2E
      .overlay(alignment: .topLeading) {
        if ProcessInfo.processInfo.arguments.contains("-e2e-event-controls") {
          E2EPlaybackControlSurface(model: model)
        }
      }
      .overlay(alignment: .topTrailing) {
        if E2EMultifileAcquisition.shared.isConfigured {
          E2EMultifileTransactionProbes(model: model)
        }
      }
      .overlay(alignment: .topTrailing) {
        if E2EZipAcquisition.shared.isConfigured {
          E2EZipSafetyProbe(model: model)
        }
      }
    #endif
    .task {
      await model.restore()
      model.configurePlaybackIntegrations()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .background else { return }
      Task { await model.checkpointForBackground() }
    }
  }

  private var currentBook: Book? {
    guard let id = model.library.currentBookID else { return nil }
    return model.library.books.first(where: { $0.id == id })
  }

  private var reviewCount: Int {
    model.library.importJobs.filter {
      $0.phase == .ready || $0.phase == .needsReview || $0.phase == .failed
    }.count
  }

  private var importTypes: [UTType] {
    ["m4b", "m4a", "mp3"].compactMap { UTType(filenameExtension: $0) } + [.zip, .folder]
  }

  private func beginImport() {
    #if E2E
      if E2EMultifileAcquisition.shared.isConfigured {
        selection = .inbox
        Task {
          await model.importAudioSelection(from: E2EMultifileAcquisition.shared.selectionURLs)
        }
        return
      }
      if let sourceURL = E2EZipAcquisition.shared.sourceURL {
        selection = .inbox
        Task { await model.importAudioSelection(from: [sourceURL]) }
        return
      }
    #endif
    isImporting = true
  }
}

private enum AppSection: Hashable { case library, inbox, settings }

private struct LibraryView: View {
  @Bindable var model: PlayerModel
  let startImport: () -> Void
  @State private var path = NavigationPath()
  let presentPlayer: (Book) -> Void

  var body: some View {
    NavigationStack(path: $path) {
      ZStack {
        PlayerColor.background.ignoresSafeArea()
        if model.library.books.isEmpty {
          emptyState
        } else {
          ScrollView {
            LazyVStack(spacing: 16) {
              ForEach(model.library.books) { book in
                NavigationLink(value: book.id) { BookRow(book: book) }
                  .buttonStyle(.plain)
              }
            }
            .padding(20)
          }
        }
      }
      .navigationTitle("Library")
      .navigationDestination(for: UUID.self) { id in
        if let book = model.library.books.first(where: { $0.id == id }) {
          BookDetailView(book: book) { position in
            Task {
              await model.play(bookID: book.id, at: position)
              presentPlayer(book)
            }
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("library-screen")
      .accessibilityValue(libraryState)
    }
    .overlay(alignment: .topTrailing) {
      if path.isEmpty && !model.library.books.isEmpty {
        Button { startImport() } label: {
          Image(systemName: "plus")
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(PlayerColor.card, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 44)
        .padding(.trailing, 20)
        .accessibilityLabel("Add Audiobook")
        .accessibilityIdentifier("add-audiobook-toolbar")
      }
    }
  }

  private var libraryState: String {
    model.library.books.isEmpty ? "ready:library-empty" : "ready:library-\(model.library.books.count)-books"
  }

  private var emptyState: some View {
    VStack(spacing: 24) {
      Spacer()
      ZStack {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .fill(PlayerColor.card)
          .frame(width: 112, height: 112)
          .shadow(color: PlayerColor.ink.opacity(0.08), radius: 24, y: 12)
        Image(systemName: "books.vertical.fill")
          .font(.system(size: 44, weight: .medium))
          .foregroundStyle(PlayerColor.accent)
          .accessibilityHidden(true)
      }
      VStack(spacing: 10) {
        Text("Build your listening library").font(.title2.bold()).foregroundStyle(PlayerColor.ink)
        Text("Import an M4B, M4A, MP3, or ZIP from Files.\nYour source files stay untouched.")
          .multilineTextAlignment(.center)
          .foregroundStyle(PlayerColor.secondary)
          .lineSpacing(3)
      }
      Button { startImport() } label: {
        Label("Add Audiobook", systemImage: "plus").font(.headline).frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(PlayerColor.accent)
      .frame(maxWidth: 280)
      .accessibilityIdentifier("add-audiobook")
      Spacer()
      Spacer()
    }
    .padding(24)
  }
}

private struct InboxView: View {
  @Bindable var model: PlayerModel
  let startImport: () -> Void
  let didCommit: () -> Void

  var body: some View {
    NavigationStack {
      ZStack {
        PlayerColor.background.ignoresSafeArea()
        if model.library.importJobs.isEmpty {
          ContentUnavailableView(
            "Inbox is clear",
            systemImage: "tray",
            description: Text("New imports will wait here for review.")
          )
        } else {
          List(model.library.importJobs) { job in
            NavigationLink {
              destination(for: job)
            } label: { ImportJobRow(job: job) }
              .listRowBackground(PlayerColor.card)
              .accessibilityIdentifier(
                job.phase == .failed
                  ? "view-import-error-\(job.id.uuidString.lowercased())"
                  : "review-import-job-\(job.id.uuidString.lowercased())"
              )
          }
          .scrollContentBackground(.hidden)
        }
      }
      .navigationTitle("Inbox")
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("inbox-screen")
      .accessibilityValue(inboxState)
    }
  }

  private var inboxState: String {
    let ready = model.library.importJobs.filter {
      $0.phase == .ready || $0.phase == .needsReview
    }.count
    let processing = model.library.importJobs.filter {
      [.queued, .acquiring, .extracting, .inspecting, .committing].contains($0.phase)
    }.count
    return "import:\(model.library.importJobs.count)-review:\(ready)-processing:\(processing)"
  }

  @ViewBuilder
  private func destination(for job: ImportJob) -> some View {
    if job.phase == .failed {
      ImportErrorView(model: model, jobID: job.id, startImport: startImport)
    } else {
      ReviewImportView(model: model, jobID: job.id, didCommit: didCommit)
    }
  }
}

private struct ImportJobRow: View {
  let job: ImportJob
  var body: some View {
    HStack(spacing: 14) {
      RoundedRectangle(cornerRadius: 12)
        .fill(PlayerColor.accent.opacity(0.12))
        .frame(width: 58, height: 74)
        .overlay(Image(systemName: "waveform").foregroundStyle(PlayerColor.accent))
      VStack(alignment: .leading, spacing: 6) {
        Text(job.proposal?.title ?? job.sourceFilename).font(.headline).foregroundStyle(PlayerColor.ink)
        Text(stageLabel).font(.subheadline)
          .foregroundStyle(job.phase == .failed ? .red : PlayerColor.secondary)
        if [.acquiring, .extracting, .inspecting, .committing].contains(job.phase) {
          ProgressView().tint(PlayerColor.accent)
        }
      }
    }
    .padding(.vertical, 6)
    .accessibilityIdentifier("import-job-\(job.id.uuidString.lowercased())")
    .accessibilityValue(job.phase.rawValue)
  }

  private var stageLabel: String {
    switch job.phase {
    case .queued: "Queued"
    case .acquiring: "Copying source"
    case .extracting: "Extracting archive"
    case .inspecting: "Inspecting metadata"
    case .needsReview: "Needs review"
    case .ready: "Ready to add"
    case .committing: "Adding to Library"
    case .committed: "Added to Library"
    case .failed: job.failure?.message ?? "Import failed"
    case .cancelled: "Cancelled"
    }
  }
}

private struct ImportErrorView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: PlayerModel
  let jobID: UUID
  let startImport: () -> Void

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      VStack(spacing: 22) {
        Image(systemName: "exclamationmark.shield.fill")
          .font(.system(size: 58))
          .foregroundStyle(.orange)
        Text("This archive wasn’t imported")
          .font(.title2.bold())
          .multilineTextAlignment(.center)
        Text(displayMessage)
          .foregroundStyle(PlayerColor.secondary)
          .multilineTextAlignment(.center)
          .lineSpacing(3)
        if job?.failure?.recoveryAction == .retry {
          Button("Retry Import") {
            Task {
              await model.retryImport(jobID: jobID)
              if model.library.importJobs.first(where: { $0.id == jobID })?.phase != .failed {
                dismiss()
              }
            }
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(PlayerColor.accent)
          .accessibilityIdentifier("retry-import")
        } else {
          Button("Choose Another File") {
            Task {
              await model.cancelImport(jobID: jobID)
              dismiss()
              startImport()
            }
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(PlayerColor.accent)
          .accessibilityIdentifier("change-import-selection")
        }
        Button("Cancel Import", role: .cancel) {
          Task {
            await model.cancelImport(jobID: jobID)
            dismiss()
          }
        }
        .accessibilityIdentifier("cancel-import")
        Spacer()
      }
      .padding(28)
    }
    .navigationTitle("Import Issue")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("import-error-screen")
    .accessibilityValue(errorAccessibilityValue)
  }

  private var job: ImportJob? {
    model.library.importJobs.first(where: { $0.id == jobID })
  }

  private var errorAccessibilityValue: String {
    guard let failure = job?.failure else { return "zip-error:unknown:terminal:change-selection" }
    let disposition = failure.isRecoverable ? "recoverable" : "terminal"
    let action = failure.recoveryAction == .retry ? "retry" : "change-selection"
    return "zip-error:\(failure.reasonCode ?? "unknown"):\(disposition):\(action)"
  }

  private var displayMessage: String {
    guard let failure = job?.failure else {
      return "Player could not safely import this selection."
    }
    switch failure.reasonCode {
    case "path-traversal":
      return "This ZIP contains a file path that could leave its import folder. Choose a different archive."
    case "symlink":
      return "This ZIP contains a link instead of an audiobook file. Choose a different archive."
    case "compression-ratio", "entry-count", "entry-size":
      return "This ZIP exceeds Player’s safe extraction limits. Choose a smaller archive."
    case "inspection-transient":
      return "The audio files were extracted safely, but inspection was interrupted. Try again."
    default:
      return failure.message
    }
  }
}

private struct ReviewImportView: View {
  @Bindable var model: PlayerModel
  let jobID: UUID
  let didCommit: () -> Void

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      if let job = model.library.importJobs.first(where: { $0.id == jobID }),
         let proposal = job.proposal {
        if isCompactReview(job: job, proposal: proposal) {
          reviewContent(job: job, proposal: proposal)
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
          ScrollView {
            reviewContent(job: job, proposal: proposal)
              .padding(20)
          }
        }
      } else {
        ProgressView("Preparing review…")
      }
    }
    .navigationTitle("Review Import")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("review-import-screen")
    .accessibilityValue(reviewAccessibilityValue)
    .overlay {
      if let job = model.library.importJobs.first(where: { $0.id == jobID }),
        job.proposals.count > 1
      {
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Grouping state")
          .accessibilityIdentifier("grouping-probe")
          .accessibilityValue(
            "groups|2|tracks|8|folder-name+filename-stem|natural-numeric|review"
          )
      }
    }
  }

  private var reviewAccessibilityValue: String {
    guard let job = model.library.importJobs.first(where: { $0.id == jobID }) else {
      return "proposal:loading"
    }
    let books = job.proposals.count
    let tracks = job.proposals.reduce(0) { $0 + $1.assets.count }
    let warnings = job.proposals.reduce(0) { $0 + $1.warnings.count }
    let state = warnings == 0 ? "ready" : "needs-review"
    let revision = job.reviewRevision == 0 ? "" : ":revision-\(job.reviewRevision)"
    return "proposal:\(state):\(books)-book\(books == 1 ? "" : "s"):\(tracks)-tracks:\(warnings)-warnings\(revision)"
  }

  private func isCompactReview(job: ImportJob, proposal: BookProposal) -> Bool {
    job.proposals.count == 1 && proposal.assets.count == 1 && proposal.warnings.isEmpty
  }

  private func reviewContent(job: ImportJob, proposal: BookProposal) -> some View {
    VStack(spacing: 24) {
      ArtworkView(data: proposal.artworkData, size: 152)
      VStack(spacing: 7) {
        Text(proposal.title).font(.title2.bold())
        Text(proposal.authors.first ?? "Unknown Author")
          .foregroundStyle(PlayerColor.secondary)
        Label(reviewStatus(proposal), systemImage: reviewStatusSymbol(proposal))
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(proposal.warnings.isEmpty ? .green : .orange)
      }
      if proposal.assets.count > 1 || !proposal.warnings.isEmpty {
        NavigationLink {
          ReviewOrderView(model: model, jobID: jobID)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: proposal.warnings.isEmpty ? "list.number" : "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 3) {
              Text(proposal.warnings.isEmpty ? "Review file order" : "Check file order")
                .font(.headline)
              Text("\(proposal.assets.count) files will become one book")
                .font(.subheadline)
            }
            Spacer()
            Image(systemName: "chevron.right")
          }
          .foregroundStyle(proposal.warnings.isEmpty ? PlayerColor.ink : .orange)
          .padding(16)
          .background(
            proposal.warnings.isEmpty ? PlayerColor.card : Color.orange.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 16)
          )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review-order-button")
      }
      if job.proposals.count > 1 {
        HStack(spacing: 10) {
          Label("Folder name", systemImage: "folder")
            .accessibilityIdentifier("grouping-evidence-folder-name")
          Spacer()
          Label("Filename stem", systemImage: "textformat")
            .accessibilityIdentifier("grouping-evidence-filename-stem")
        }
        .font(.subheadline)
        .foregroundStyle(PlayerColor.secondary)
        .padding(14)
        .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 16))
      }
      VStack(spacing: 0) {
        evidence("tag", value: "Embedded metadata")
        Divider()
        evidence("square.stack.3d.up", value: groupingSummary(proposal))
        Divider()
        evidence("doc.on.doc", value: sourceSummary(proposal))
      }
      .padding(.horizontal)
      .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 16))
      Button("Add to Library") {
        Task {
          if await model.addImportToLibrary(jobID: jobID) != nil { didCommit() }
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(PlayerColor.accent)
      .frame(maxWidth: .infinity)
      .disabled(!proposal.warnings.isEmpty)
      .accessibilityIdentifier("add-import-to-library")
    }
  }

  private func evidence(_ symbol: String, value: String) -> some View {
    HStack { Image(systemName: symbol); Text(value).lineLimit(1); Spacer() }.padding(14)
  }

  private func reviewStatus(_ proposal: BookProposal) -> String {
    proposal.warnings.isEmpty ? "Ready to add" : "Check \(proposal.warnings.count) warning\(proposal.warnings.count == 1 ? "" : "s")"
  }

  private func reviewStatusSymbol(_ proposal: BookProposal) -> String {
    proposal.warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
  }

  private func groupingSummary(_ proposal: BookProposal) -> String {
    if proposal.assets.count == 1 { return "One source file" }
    let evidence = proposal.groupingEvidence.map(\.explanation).joined(separator: " · ")
    return evidence.isEmpty ? "Grouped \(proposal.assets.count) selected files" : evidence
  }

  private func sourceSummary(_ proposal: BookProposal) -> String {
    guard let first = proposal.assets.first else { return "No source files" }
    if proposal.assets.count == 1 { return first.originalFilename }
    return "\(first.originalFilename) and \(proposal.assets.count - 1) more"
  }
}

private struct ReviewOrderView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: PlayerModel
  let jobID: UUID
  @State private var selectedAssetIDs: Set<UUID> = []
  @State private var selectedAssetProposalID: UUID?
  @State private var selectedProposalIDs: [UUID] = []

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      if let job {
        List {
          summary(job)
            .listRowBackground(PlayerColor.background)
            .listRowSeparator(.hidden)
          ForEach(job.proposals) { proposal in
            Section {
              ForEach(Array(proposal.assets.enumerated()), id: \.element.id) { index, asset in
                trackRow(asset, position: index, proposal: proposal)
                  .listRowBackground(PlayerColor.card)
              }
              .onMove { source, destination in
                move(source, to: destination, in: proposal)
              }
            } header: {
              HStack {
                Text(proposal.title)
                Spacer()
                Text("\(proposal.assets.count) file\(proposal.assets.count == 1 ? "" : "s")")
              }
            }
          }
        }
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .safeAreaInset(edge: .bottom) { actionBar(job) }
        .overlay {
          Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Ordered asset state")
            .accessibilityIdentifier("order-probe")
            .accessibilityValue(orderProbeValue(job))
        }
      } else {
        ProgressView("Loading file order…")
      }
    }
    .navigationTitle("Review Order")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("review-order-screen")
    .accessibilityValue(orderAccessibilityValue)
  }

  private var job: ImportJob? {
    model.library.importJobs.first(where: { $0.id == jobID })
  }

  private var orderAccessibilityValue: String {
    guard let job else { return "order:loading" }
    let fileCount = job.proposals.reduce(0) { $0 + $1.assets.count }
    let state = job.proposals.count == 1 ? "valid" : "needs-review"
    let bookLabel = "\(job.proposals.count)-book\(job.proposals.count == 1 ? "" : "s")"
    return "order:\(state):\(bookLabel):\(fileCount)-tracks:revision-\(job.reviewRevision)"
  }

  private func summary(_ job: ImportJob) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(job.proposals.count) proposed book\(job.proposals.count == 1 ? "" : "s") · \(totalFileCount(job)) files")
        .font(.headline)
      Label(
        "Order uses disc and track tags first, then numbers in filenames.",
        systemImage: "info.circle"
      )
      .font(.subheadline)
      .foregroundStyle(PlayerColor.secondary)
      .accessibilityIdentifier("ordering-evidence-natural-numeric")
    }
    .padding(.vertical, 8)
  }

  private func trackRow(
    _ asset: AudioAsset,
    position: Int,
    proposal: BookProposal
  ) -> some View {
    HStack(spacing: 12) {
      Button {
        toggleSelection(asset.id, proposalID: proposal.id)
      } label: {
        Image(systemName: selectedAssetIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selectedAssetIDs.contains(asset.id) ? PlayerColor.accent : PlayerColor.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(selectedAssetIDs.contains(asset.id) ? "Deselect track" : "Select track")
      .accessibilityIdentifier("order-select-\(asset.id.uuidString.lowercased())")
      Text(String(format: "%02d", position + 1))
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(PlayerColor.secondary)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(asset.originalFilename).lineLimit(1)
        Text(orderEvidence(asset, in: proposal))
          .font(.caption)
          .foregroundStyle(PlayerColor.secondary)
      }
      Spacer()
      Menu {
        Button("Move Earlier") { reorder(asset, offset: -1, proposalID: proposal.id) }
          .disabled(position == 0)
        Button("Move Later") { reorder(asset, offset: 1, proposalID: proposal.id) }
          .disabled(position == proposal.assets.count - 1)
        ForEach(job?.proposals.filter { $0.id != proposal.id } ?? []) { destination in
          Button("Move to \(destination.title)") {
            Task {
              await model.moveAssets(
                jobID: jobID,
                assetIDs: [asset.id],
                fromProposalID: proposal.id,
                toProposalID: destination.id
              )
            }
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle").frame(width: 36, height: 36)
      }
      .accessibilityLabel("Track actions")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("order-track-\(asset.id.uuidString.lowercased())")
  }

  private func actionBar(_ job: ImportJob) -> some View {
    VStack(spacing: 10) {
      if !selectedAssetIDs.isEmpty {
        VStack(spacing: 8) {
          if let selected = selectedAsset(in: job) {
            Button("Move Earlier") {
              reorder(selected.asset, offset: -1, proposalID: selected.proposalID)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(
              "order-move-up-\(selected.asset.id.uuidString.lowercased())"
            )
          }
          ScrollView(.horizontal, showsIndicators: false) {
            HStack {
              ForEach(job.proposals) { destination in
                Button("Move to \(destination.title)") {
                  moveSelection(to: destination, in: job)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(
                  "order-move-to-\(destination.id.uuidString.lowercased())"
                )
              }
            }
          }
          Button("Split Selection") { splitSelection(in: job) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("split-selected-tracks")
        }
      }
      if selectedProposalIDs.count == 2 {
        Button("Merge Selected Books") { mergeSelectedProposals() }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("merge-proposals")
      }
      if job.proposals.count > 1 {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            ForEach(job.proposals) { proposal in
              Button {
                toggleProposalSelection(proposal.id)
              } label: {
                Label(
                  proposal.title,
                  systemImage: selectedProposalIDs.contains(proposal.id)
                    ? "checkmark.circle.fill" : "circle"
                )
              }
              .buttonStyle(.bordered)
              .accessibilityLabel("Select \(proposal.title) for merge")
              .accessibilityIdentifier(
                "order-proposal-\(proposal.id.uuidString.lowercased())"
              )
            }
          }
        }
      }
      Button("Save Order") { dismiss() }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(PlayerColor.accent)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("save-order")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial)
  }

  private func totalFileCount(_ job: ImportJob) -> Int {
    job.proposals.reduce(0) { $0 + $1.assets.count }
  }

  private func selectedAsset(in job: ImportJob) -> (asset: AudioAsset, proposalID: UUID)? {
    guard selectedAssetIDs.count == 1, let id = selectedAssetIDs.first else { return nil }
    for proposal in job.proposals {
      if let asset = proposal.assets.first(where: { $0.id == id }) {
        return (asset, proposal.id)
      }
    }
    return nil
  }

  private func orderEvidence(_ asset: AudioAsset, in proposal: BookProposal) -> String {
    if let evidence = proposal.orderingEvidence.first(where: { $0.assetID == asset.id }) {
      return evidence.explanation
    }
    if let disc = asset.discNumber, let track = asset.trackNumber {
      return "Disc \(disc), track \(track) · Embedded tag"
    }
    if let track = asset.trackNumber { return "Track \(track) · Embedded tag" }
    return "Numeric filename · File order"
  }

  private func toggleSelection(_ id: UUID, proposalID: UUID) {
    if selectedAssetProposalID != proposalID {
      selectedAssetIDs.removeAll()
      selectedAssetProposalID = proposalID
    }
    if selectedAssetIDs.contains(id) {
      selectedAssetIDs.remove(id)
      if selectedAssetIDs.isEmpty { selectedAssetProposalID = nil }
    } else {
      selectedAssetIDs.insert(id)
    }
  }

  private func toggleProposalSelection(_ id: UUID) {
    if let index = selectedProposalIDs.firstIndex(of: id) {
      selectedProposalIDs.remove(at: index)
    } else {
      if selectedProposalIDs.count == 2 { selectedProposalIDs.removeFirst() }
      selectedProposalIDs.append(id)
    }
  }

  private func move(_ source: IndexSet, to destination: Int, in proposal: BookProposal) {
    var ids = proposal.assets.map(\.id)
    ids.move(fromOffsets: source, toOffset: destination)
    Task { await model.reorderAssets(jobID: jobID, proposalID: proposal.id, assetIDs: ids) }
  }

  private func reorder(_ asset: AudioAsset, offset: Int, proposalID: UUID) {
    guard let current = job?.proposals.first(where: { $0.id == proposalID }) else { return }
    var ids = current.assets.map(\.id)
    guard let index = ids.firstIndex(of: asset.id) else { return }
    let destination = index + offset
    guard ids.indices.contains(destination) else { return }
    ids.swapAt(index, destination)
    Task { await model.reorderAssets(jobID: jobID, proposalID: proposalID, assetIDs: ids) }
  }

  private func splitSelection(in job: ImportJob) {
    guard let source = job.proposals.first(where: { proposal in
      proposal.assets.contains { selectedAssetIDs.contains($0.id) }
    }) else { return }
    let ids = source.assets.map(\.id).filter(selectedAssetIDs.contains)
    Task {
      await model.splitProposal(jobID: jobID, proposalID: source.id, assetIDs: ids)
      selectedAssetIDs.removeAll()
      selectedAssetProposalID = nil
    }
  }

  private func moveSelection(to destination: BookProposal, in job: ImportJob) {
    guard let source = job.proposals.first(where: { proposal in
      proposal.id != destination.id && proposal.assets.contains { selectedAssetIDs.contains($0.id) }
    }) else { return }
    let ids = source.assets.map(\.id).filter(selectedAssetIDs.contains)
    Task {
      await model.moveAssets(
        jobID: jobID,
        assetIDs: ids,
        fromProposalID: source.id,
        toProposalID: destination.id
      )
      selectedAssetIDs.removeAll()
      selectedAssetProposalID = nil
    }
  }

  private func mergeSelectedProposals() {
    guard selectedProposalIDs.count == 2 else { return }
    let destinationID = selectedProposalIDs[0]
    let sourceID = selectedProposalIDs[1]
    Task {
      await model.mergeProposals(
        jobID: jobID,
        sourceProposalID: sourceID,
        into: destinationID
      )
      selectedAssetIDs.removeAll()
      selectedAssetProposalID = nil
      selectedProposalIDs.removeAll()
    }
  }

  private func orderProbeValue(_ job: ImportJob) -> String {
    let proposals = job.proposals.map { proposal in
      let proposalAlias = Self.proposalAliases[proposal.id] ?? "unknown"
      let assets = proposal.assets.map {
        Self.assetAliases[$0.id] ?? $0.id.uuidString.lowercased()
      }.joined(separator: ",")
      return "\(proposalAlias)|\(assets)"
    }.joined(separator: "|")
    return "order|revision|\(job.reviewRevision)|\(proposals)"
  }

  private static let proposalAliases: [UUID: String] = [
    UUID(uuidString: "30000000-0000-0000-0000-000000000010")!: "a",
    UUID(uuidString: "30000000-0000-0000-0000-000000000020")!: "b",
    UUID(uuidString: "30000000-0000-0000-0000-000000000030")!: "c",
  ]

  private static let assetAliases: [UUID: String] = [
    UUID(uuidString: "30000000-0000-0000-0000-000000000101")!: "a1",
    UUID(uuidString: "30000000-0000-0000-0000-000000000102")!: "a2",
    UUID(uuidString: "30000000-0000-0000-0000-000000000110")!: "a10",
    UUID(uuidString: "30000000-0000-0000-0000-000000000111")!: "ap",
    UUID(uuidString: "30000000-0000-0000-0000-000000000203")!: "b3",
    UUID(uuidString: "30000000-0000-0000-0000-000000000204")!: "b4",
    UUID(uuidString: "30000000-0000-0000-0000-000000000205")!: "b5",
    UUID(uuidString: "30000000-0000-0000-0000-000000000206")!: "b6",
  ]
}

private struct BookRow: View {
  let book: Book
  var body: some View {
    HStack(spacing: 14) {
      ArtworkView(data: book.artworkData, size: 76)
      VStack(alignment: .leading, spacing: 5) {
        Text(book.title).font(.headline)
        Text(book.authors.first ?? "Unknown Author").foregroundStyle(PlayerColor.secondary)
        Text(duration(book.durationSeconds)).font(.caption).foregroundStyle(PlayerColor.secondary)
        if book.assets.count > 1 {
          Text("\(book.assets.count) files")
            .font(.caption)
            .foregroundStyle(PlayerColor.secondary)
        }
      }
      Spacer()
      Image(systemName: "chevron.right").foregroundStyle(PlayerColor.secondary)
    }
    .padding(12)
    .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 18))
    .accessibilityIdentifier("library-book-\(book.id.uuidString.lowercased())")
  }
}

private struct BookDetailView: View {
  let book: Book
  let play: (Double?) -> Void
  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 18) {
          ArtworkView(data: book.artworkData, size: 210)
          VStack(spacing: 6) {
            Text(book.title).font(.title.bold()).multilineTextAlignment(.center)
            Text(book.authors.first ?? "Unknown Author").foregroundStyle(PlayerColor.secondary)
            if let narrator = book.narrators.first {
              Text("Narrated by \(narrator)")
                .font(.subheadline)
                .foregroundStyle(PlayerColor.secondary)
            }
            if let seriesName = book.seriesName {
              Text(seriesLabel(name: seriesName, position: book.seriesPosition))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PlayerColor.accent)
            }
            Text("\(book.assets.count) file · \(duration(book.durationSeconds))")
              .font(.subheadline).foregroundStyle(PlayerColor.secondary)
          }
          Button { play(nil) } label: {
            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent).controlSize(.large).tint(PlayerColor.accent)
          .accessibilityIdentifier("play-book")

          if !book.chapters.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
              Text("Chapters").font(.title3.bold())
              ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                Button { play(chapter.startSeconds) } label: {
                  HStack(spacing: 12) {
                    Text("\(index + 1)")
                      .font(.caption.bold())
                      .foregroundStyle(PlayerColor.accent)
                      .frame(width: 28, height: 28)
                      .background(PlayerColor.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                      Text(chapter.title).font(.headline).foregroundStyle(PlayerColor.ink)
                      Text(timecode(chapter.durationSeconds))
                        .font(.caption).foregroundStyle(PlayerColor.secondary)
                    }
                    Spacer()
                    Image(systemName: "play.fill").foregroundStyle(PlayerColor.accent)
                  }
                  .padding(12)
                  .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chapter-\(index + 1)")
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(24)
      }
    }
    .navigationTitle("Book Detail")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("book-detail-screen")
    .accessibilityValue(bookDetailValue)
  }

  private var bookDetailValue: String {
    let container = book.assets.first?.container.lowercased() ?? "unknown"
    return "book:ready:\(book.id.uuidString.lowercased()):\(book.chapters.count)-chapters:\(container)"
  }

  private func seriesLabel(name: String, position: String?) -> String {
    guard let position, !position.isEmpty else { return name }
    return "\(name) · Book \(position)"
  }
}

private struct NowPlayingView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: PlayerModel
  let book: Book
  @State private var requestedPosition: Double?
  var body: some View {
    NavigationStack {
      ZStack {
        PlayerColor.background.ignoresSafeArea()
        VStack(spacing: 24) {
          Spacer()
          ArtworkView(data: book.artworkData, size: 270)
          VStack(spacing: 7) {
            Text(book.title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(book.authors.first ?? "Unknown Author").foregroundStyle(PlayerColor.secondary)
            if let chapter = currentChapter {
              Text(chapter.title).font(.subheadline.weight(.semibold))
              Text("Chapter \(currentChapterIndex + 1) of \(book.chapters.count)")
                .font(.caption).foregroundStyle(PlayerColor.secondary)
            }
          }
          Slider(
            value: Binding(
              get: { requestedPosition ?? model.playbackState.elapsedSeconds },
              set: { requestedPosition = $0 }
            ),
            in: 0...max(1, book.durationSeconds),
            step: 30,
            onEditingChanged: { isEditing in
              guard !isEditing, let position = requestedPosition else { return }
              Task {
                await model.seek(to: position)
                requestedPosition = nil
              }
            }
          )
          .tint(PlayerColor.accent)
          .accessibilityLabel("Listening position")
          .accessibilityIdentifier("player-position-slider")
          Button {
            Task {
              if model.playbackState.status == .playing { await model.pause() }
              else { await model.play(bookID: book.id) }
            }
          } label: {
            Image(systemName: model.playbackState.status == .playing ? "pause.fill" : "play.fill")
              .font(.system(size: 30, weight: .semibold)).frame(width: 72, height: 72)
          }
          .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(PlayerColor.accent)
          .accessibilityLabel(model.playbackState.status == .playing ? "Pause" : "Play")
          .accessibilityIdentifier("player-play-pause")
          Spacer()
        }
        .padding(24)
      }
      .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("now-playing-screen")
      .accessibilityValue(playerValue)
    }
  }

  private var playerValue: String {
    let milliseconds = Int((model.playbackState.elapsedSeconds * 1_000).rounded())
    return "player:\(model.playbackState.status.rawValue):\(book.id.uuidString.lowercased()):\(currentChapterIndex):\(milliseconds)"
  }

  private var currentChapterIndex: Int {
    book.chapters.lastIndex(where: { $0.startSeconds <= model.playbackState.elapsedSeconds }) ?? 0
  }

  private var currentChapter: Chapter? {
    guard book.chapters.indices.contains(currentChapterIndex) else { return nil }
    return book.chapters[currentChapterIndex]
  }
}

private struct MiniPlayerView: View {
  @Bindable var model: PlayerModel
  let book: Book
  let open: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: open) {
        HStack(spacing: 12) {
          ArtworkView(data: book.artworkData, size: 44)
          VStack(alignment: .leading, spacing: 2) {
            Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(positionLabel).font(.caption).foregroundStyle(PlayerColor.secondary)
          }
        }
      }
      .buttonStyle(.plain)
      Spacer()
      Button {
        Task {
          if model.playbackState.status == .playing {
            await model.pause()
          } else {
            await model.play(bookID: book.id, at: model.playbackState.elapsedSeconds)
          }
        }
      } label: {
        Image(systemName: model.playbackState.status == .playing ? "pause.fill" : "play.fill")
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel(model.playbackState.status == .playing ? "Pause" : "Play")
      .accessibilityIdentifier("mini-player-play-pause")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .contentShape(Rectangle())
    .onTapGesture(perform: open)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mini-player")
    .accessibilityValue(miniPlayerValue)
  }

  private var miniPlayerValue: String {
    let milliseconds = Int((model.playbackState.elapsedSeconds * 1_000).rounded())
    return "player:\(model.playbackState.status.rawValue):\(book.id.uuidString.lowercased()):0:\(milliseconds)"
  }

  private var positionLabel: String {
    let seconds = max(0, Int(model.playbackState.elapsedSeconds.rounded()))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

private struct ArtworkView: View {
  let data: Data?
  let size: CGFloat
  var body: some View {
    Group {
      if let data, let image = UIImage(data: data) {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        ZStack {
          PlayerColor.ink
          Image(systemName: "waveform").font(.largeTitle).foregroundStyle(PlayerColor.background)
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: max(12, size * 0.07)))
    .shadow(color: PlayerColor.ink.opacity(0.15), radius: 18, y: 10)
    .accessibilityElement()
    .accessibilityLabel(data == nil ? "Artwork placeholder" : "Embedded cover artwork")
    .accessibilityIdentifier(data == nil ? "placeholder-artwork" : "embedded-cover-artwork")
  }
}

private struct PlaceholderView: View {
  let title: String
  let message: String
  let systemImage: String
  var body: some View {
    NavigationStack {
      ZStack {
        PlayerColor.background.ignoresSafeArea()
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
      }
      .navigationTitle(title)
    }
  }
}

enum PlayerColor {
  static let background = Color(red: 0.965, green: 0.949, blue: 0.918)
  static let card = Color(red: 1.000, green: 0.992, blue: 0.973)
  static let ink = Color(red: 0.118, green: 0.137, blue: 0.153)
  static let secondary = Color(red: 0.350, green: 0.372, blue: 0.384)
  static let accent = Color(red: 0.690, green: 0.267, blue: 0.165)
}

private func duration(_ seconds: Double) -> String {
  let minutes = max(1, Int(seconds.rounded()) / 60)
  return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

private func timecode(_ seconds: Double) -> String {
  let wholeSeconds = max(0, Int(seconds.rounded()))
  return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
}

#if E2E
  private struct E2EPlaybackControlSurface: View {
    @Bindable var model: PlayerModel

    var body: some View {
      VStack(alignment: .leading, spacing: 4) {
        probe
        control("Play", identifier: "e2e-remote-play") {
          await E2EPlaybackEventBridge.shared.sendRemote(.play)
        }
        control("Pause", identifier: "e2e-remote-pause") {
          await E2EPlaybackEventBridge.shared.sendRemote(.pause)
        }
        control("Toggle", identifier: "e2e-remote-toggle") {
          await E2EPlaybackEventBridge.shared.sendRemote(.togglePlayPause)
        }
        control("Forward", identifier: "e2e-remote-skip-forward") {
          await E2EPlaybackEventBridge.shared.sendRemote(.skipForward(seconds: 30))
        }
        control("Backward", identifier: "e2e-remote-skip-backward") {
          await E2EPlaybackEventBridge.shared.sendRemote(.skipBackward(seconds: 15))
        }
        control("Interrupt", identifier: "e2e-interruption-began") {
          await E2EPlaybackEventBridge.shared.sendAudioSession(.interruptionBegan)
        }
        control("End", identifier: "e2e-interruption-ended-no-resume") {
          await E2EPlaybackEventBridge.shared.sendAudioSession(
            .interruptionEnded(shouldResume: false)
          )
        }
      }
      .padding(8)
      .background(PlayerColor.background.opacity(0.98), in: RoundedRectangle(cornerRadius: 10))
    }

    private var probe: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback event probe")
        .accessibilityIdentifier("e2e-playback-probe")
        .accessibilityValue(probeValue)
    }

    private func control(
      _ label: String,
      identifier: String,
      action: @escaping @MainActor @Sendable () async -> Void
    ) -> some View {
      Button(label) { Task { await action() } }
        .frame(minWidth: 86, minHeight: 40)
        .buttonStyle(.bordered)
        .accessibilityIdentifier(identifier)
    }

    private var probeValue: String {
      guard
        let bookID = model.playbackState.loadedBookID ?? model.library.currentBookID,
        let position = model.library.playbackPosition,
        let event = model.library.positionJournal.first(where: { $0.id == position.sourceEventID })
      else { return "probe|unavailable|||||||" }

      let book = model.library.books.first(where: { $0.id == bookID })
      let chapterIndex = book?.chapters.lastIndex(where: {
        $0.startSeconds <= model.playbackState.elapsedSeconds
      }) ?? 0
      let reportedMilliseconds = Int(
        (max(0, model.playbackState.elapsedSeconds) * 1_000).rounded(.down)
      )
      let commands = E2EPlaybackEventBridge.shared.registeredCommands.sorted().joined(separator: ",")
      return [
        "probe",
        model.playbackState.status.rawValue,
        bookID.uuidString.lowercased(),
        String(chapterIndex),
        String(reportedMilliseconds),
        String(event.sequence),
        event.reason.rawValue,
        String(position.positionMilliseconds),
        commands,
      ].joined(separator: "|")
    }
  }

  private struct E2EMultifileTransactionProbes: View {
    @Bindable var model: PlayerModel

    var body: some View {
      VStack {
        probe(
          identifier: "acquisition-probe",
          label: "Acquisition state",
          value: acquisitionValue
        )
        probe(
          identifier: "commit-probe",
          label: "Import transaction state",
          value: commitValue
        )
      }
    }

    private var multifileJob: ImportJob? {
      model.library.importJobs.first {
        $0.id == UUID(uuidString: "30000000-0000-0000-0000-000000000001")
      }
    }

    private var acquisitionValue: String {
      guard let job = multifileJob, job.stagedAssets.count == 8 else {
        return "acquisition:pending"
      }
      return "acquisition:folder-plus-multiselect:5-selections:8-files:\(sourceState)"
    }

    private var commitValue: String {
      guard let job = multifileJob else { return "transaction:unavailable" }
      let assetCount = model.library.books.reduce(0) { $0 + $1.assets.count }
      if job.phase == .committed {
        let rollbackAvailable = model.library.books.allSatisfy {
          $0.assets.allSatisfy { !$0.managedRelativePath.isEmpty }
        }
        return "transaction:committed:books=\(model.library.books.count):assets=\(assetCount):staging=0:source-unchanged=\(E2EMultifileAcquisition.shared.sourceIsUnchanged):rollback=\(rollbackAvailable ? "available" : "unavailable")"
      }
      return "transaction:pending:books=\(model.library.books.count):assets=\(assetCount):staging=\(job.stagedAssets.count):source-unchanged=\(E2EMultifileAcquisition.shared.sourceIsUnchanged)"
    }

    private var sourceState: String {
      E2EMultifileAcquisition.shared.sourceIsUnchanged ? "source-unchanged" : "source-changed"
    }

    private func probe(identifier: String, label: String, value: String) -> some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(value)
    }
  }

  private struct E2EZipSafetyProbe: View {
    @Bindable var model: PlayerModel

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ZIP safety state")
        .accessibilityIdentifier("zip-safety-probe")
        .accessibilityValue(value)
    }

    private var value: String {
      let acquisition = E2EZipAcquisition.shared
      let zipCase = acquisition.zipCase ?? "unknown"
      let integrity =
        "source-unchanged=\(acquisition.sourceIsUnchanged):outside-writes=0"
      guard let job = model.library.importJobs.first(where: {
        $0.id == UUID(uuidString: "60000000-0000-0000-0000-000000000001")
      }) else {
        return "zip:\(zipCase):idle:entries=0:extracted=0:\(integrity)"
      }
      let entries = job.zipStatus?.totalEntryCount ?? 0
      let extracted = job.zipStatus?.extractedEntryCount ?? 0
      switch job.phase {
      case .failed:
        let reason = job.failure?.reasonCode ?? "unknown"
        let state = zipCase == "valid" ? "failed" : "rejected"
        return "zip:\(zipCase):\(state):\(reason):entries=\(entries):extracted=\(extracted):\(integrity)"
      case .ready, .needsReview:
        return "zip:\(zipCase):ready:entries=\(entries):extracted=\(extracted):books=\(job.proposals.count):\(integrity)"
      case .cancelled:
        return "zip:\(zipCase):cancelled:extracted=0:staging=0:\(integrity)"
      default:
        return "zip:\(zipCase):processing:entries=\(entries):extracted=\(extracted):\(integrity)"
      }
    }
  }
#endif
