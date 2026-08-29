import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct E2ELaunchNavigationConfiguration: Equatable {
  enum Section: String, CaseIterable {
    case library
    case inbox
    case settings
  }

  enum SettingsRoute: String, CaseIterable {
    case fullUnlock = "full-unlock"
    case trash
    case storage
    case backup
    case playbackDefaults = "playback-defaults"
    case smartRewind = "smart-rewind"
    case accessibility
    case diagnostics
  }

  static let sectionArgument = "-e2e-start-section"
  static let settingsRouteArgument = "-e2e-start-settings-route"
  static let library = E2ELaunchNavigationConfiguration(section: .library, settingsRoute: nil)

  let section: Section
  let settingsRoute: SettingsRoute?

  static func parse(arguments: [String]) throws -> E2ELaunchNavigationConfiguration {
    let sectionValue = try optionalValue(after: sectionArgument, in: arguments)
    let section: Section
    if let sectionValue {
      guard let parsed = Section(rawValue: sectionValue) else {
        throw PlayerCoreError.fileOperation("Invalid E2E start section: \(sectionValue)")
      }
      section = parsed
    } else {
      section = .library
    }

    let routeValue = try optionalValue(after: settingsRouteArgument, in: arguments)
    let settingsRoute: SettingsRoute?
    if let routeValue {
      guard let parsed = SettingsRoute(rawValue: routeValue) else {
        throw PlayerCoreError.fileOperation("Invalid E2E Settings route: \(routeValue)")
      }
      settingsRoute = parsed
    } else {
      settingsRoute = nil
    }
    guard settingsRoute == nil || section == .settings else {
      throw PlayerCoreError.fileOperation(
        "An E2E Settings route requires Settings as the start section."
      )
    }

    return E2ELaunchNavigationConfiguration(
      section: section,
      settingsRoute: settingsRoute
    )
  }

  private static func optionalValue(after marker: String, in arguments: [String]) throws -> String? {
    let markers = arguments.indices.filter { arguments[$0] == marker }
    guard markers.count <= 1 else {
      throw PlayerCoreError.fileOperation("Duplicate E2E navigation option: \(marker)")
    }
    guard let index = markers.first else { return nil }
    guard arguments.indices.contains(index + 1) else {
      throw PlayerCoreError.fileOperation("Missing E2E navigation value for: \(marker)")
    }
    let value = arguments[index + 1]
    guard !value.isEmpty, !value.hasPrefix("-") else {
      throw PlayerCoreError.fileOperation("Invalid E2E navigation value for: \(marker)")
    }
    return value
  }
}

struct ContentView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: PlayerModel
  @State private var selection: AppSection = .library
  @State private var isImporting = false
  @State private var isReceivingFromComputer = false
  @State private var chooseFilesAfterReceiverDismisses = false
  @State private var isDrainingSharedImports = false
  @State private var sharedImportQueueRevision = 0
  @State private var pendingDocumentURLs: [URL] = []
  @State private var presentedPlayerBook: Book?
  private let receiverConfiguration: E2EComputerReceiverLaunchConfiguration
  private let launchNavigation: E2ELaunchNavigationConfiguration
  private let playbackControls: E2EPlaybackControlConfiguration

  init(
    model: PlayerModel,
    receiverConfiguration: E2EComputerReceiverLaunchConfiguration,
    launchNavigation: E2ELaunchNavigationConfiguration,
    playbackControls: E2EPlaybackControlConfiguration
  ) {
    self.model = model
    self.receiverConfiguration = receiverConfiguration
    self.launchNavigation = launchNavigation
    self.playbackControls = playbackControls
    switch launchNavigation.section {
    case .library: _selection = State(initialValue: .library)
    case .inbox: _selection = State(initialValue: .inbox)
    case .settings: _selection = State(initialValue: .settings)
    }
  }

  var body: some View {
    if let recovery = model.startupRecoveryStatus {
      StartupRecoveryView(model: model, status: recovery)
    } else {
      operationalContent
    }
  }

  private var operationalContent: some View {
    TabView(selection: tabSelection) {
      playerTabContent {
        LibraryView(
          model: model,
          startComputerReceiver: { isReceivingFromComputer = true },
          startFileImport: beginFileImport
        ) { presentedPlayerBook = $0 }
      }
        .tag(AppSection.library)
        .tabItem { Label("Library", systemImage: "books.vertical") }

      playerTabContent {
        InboxView(model: model, startImport: beginImport) { selection = .library }
      }
        .tag(AppSection.inbox)
        .tabItem { Label("Inbox", systemImage: "tray.full") }
        .badge(reviewCount)

      playerTabContent {
        LibraryOrganizationSettingsView(
          model: model,
          initialRoute: launchNavigation.settingsRoute
        )
      }
        .tag(AppSection.settings)
        .tabItem { Label("Settings", systemImage: "gearshape") }

      Color.clear
        .tag(AppSection.add)
        .tabItem { Label("Add", systemImage: "plus") }
    }
    .tint(PlayerColor.accent)
    .modifier(
      PlayerAccessibilityRootModifier(
        preferences: model.library.accessibilityPreferences
      )
    )
    .fileImporter(
      isPresented: $isImporting,
      allowedContentTypes: importTypes,
      allowsMultipleSelection: true
    ) { result in
      guard case .success(let urls) = result, !urls.isEmpty else { return }
      selection = .inbox
      Task { await model.importAudioSelection(from: urls) }
    }
    .sheet(
      isPresented: $isReceivingFromComputer,
      onDismiss: {
        guard chooseFilesAfterReceiverDismisses else { return }
        chooseFilesAfterReceiverDismisses = false
        beginFileImport()
      }
    ) {
      ComputerReceiverView(
        model: model,
        launchConfiguration: receiverConfiguration,
        chooseFromFiles: {
          chooseFilesAfterReceiverDismisses = true
          isReceivingFromComputer = false
        }
      ) { needsInbox in
        selection = needsInbox ? .inbox : .library
      }
      .dynamicTypeSize(dynamicTypeSize)
    }
    .fullScreenCover(item: $presentedPlayerBook) { book in
      NowPlayingView(
        model: model,
        book: book,
        showsRewindExpiryControl: playbackControls.rewindExpiryControl
      )
      .dynamicTypeSize(dynamicTypeSize)
    }
    .sheet(isPresented: $model.isFullUnlockPresented) {
      NavigationStack {
        FullUnlockView(model: model)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Close") { model.isFullUnlockPresented = false }
            }
          }
      }
      .dynamicTypeSize(dynamicTypeSize)
    }
    #if E2E
      .overlay(alignment: .topLeading) {
        if playbackControls.eventControls {
          E2EPlaybackControlSurface(model: model)
        }
      }
      .overlay(alignment: .topLeading) {
        StateProbe(
          id: "playback-setup-probe",
          value: model.playbackSetupError.map {
            "setup=warning:domain=\($0.domain.rawValue):diagnostic=\($0.diagnosticDetail ?? "none")"
          } ?? "setup=ready"
        )
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
      .overlay(alignment: .topLeading) {
        if E2EImportIngressBridge.shared.isConfigured {
          E2EImportIngressProbes(model: model, queueRevision: sharedImportQueueRevision)
        }
      }
      .overlay(alignment: .topTrailing) {
        if E2EImportRecoveryBridge.shared.isConfigured {
          E2EImportRecoveryProbes(model: model)
        }
      }
      .overlay(alignment: .topLeading) {
        if E2EMetadataRepairBridge.shared.isConfigured {
          ZStack {
            Color.clear
              .frame(width: 1, height: 1)
              .id(model.library.books.count)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Metadata audio integrity")
              .accessibilityIdentifier("metadata-integrity-probe")
              .accessibilityValue(E2EMetadataRepairBridge.shared.integrityValue)
            Color.clear
              .frame(width: 1, height: 1)
              .id(E2EMetadataRepairBridge.shared.persistenceValue)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Metadata persistence")
              .accessibilityIdentifier("metadata-persistence-probe")
              .accessibilityValue(E2EMetadataRepairBridge.shared.persistenceValue)
          }
        }
      }
    #endif
    .task {
      if !model.isRestored {
        await model.restore()
      }
      await model.prepareMonetization()
      model.configurePlaybackIntegrations()
      await drainPendingDocumentURLs()
      await drainSharedImports()
    }
    .onOpenURL { url in
      acceptDocumentOpen(url)
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        Task {
          await model.refreshMonetization()
          await drainSharedImports()
        }
      case .background:
        Task { await model.checkpointForBackground() }
      default:
        break
      }
    }
    .alert(
      model.presentedError?.title ?? "Bookshelf",
      isPresented: Binding(
        get: { model.presentedError != nil },
        set: { isPresented in
          if !isPresented, let id = model.presentedError?.id {
            model.clearPresentedError(id: id)
          }
        }
      )
    ) {
      if let error = model.presentedError {
        presentedErrorActions(error)
      }
    } message: {
      Text(model.presentedError?.message ?? "Bookshelf couldn’t complete that action.")
    }
    .alert(
      "Included Listening",
      isPresented: Binding(
        get: { model.monetizationNotice != nil },
        set: { if !$0 { model.dismissMonetizationNotice() } }
      )
    ) {
      Button("OK") { model.dismissMonetizationNotice() }
      Button("View Full Unlock") {
        model.dismissMonetizationNotice()
        model.showFullUnlock()
      }
    } message: {
      Text(model.monetizationNotice ?? "")
    }
  }

  @ViewBuilder
  private func presentedErrorActions(_ error: PlayerPresentationError) -> some View {
    switch error.recoveryAction {
    case .reviewInbox:
      Button("Review Inbox") {
        model.clearPresentedError(id: error.id)
        selection = .inbox
      }
    case .openSettings:
      Button("Open Settings") {
        model.clearPresentedError(id: error.id)
        selection = .settings
      }
    case .contactSupport:
      Button("Open Support") {
        model.clearPresentedError(id: error.id)
        selection = .settings
      }
    case .acknowledge, .retry:
      Button("OK") { model.clearPresentedError(id: error.id) }
    }
  }

  private var currentBook: Book? {
    guard let id = model.library.currentBookID else { return nil }
    return model.library.books.first(where: { $0.id == id })
  }

  private var tabSelection: Binding<AppSection> {
    Binding(
      get: { selection },
      set: { destination in
        if destination == .add {
          isReceivingFromComputer = true
        } else {
          selection = destination
        }
      }
    )
  }

  private func playerTabContent<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .environment(
        \.playerMiniPlayerScrollRunway,
        currentBook == nil ? 0 : PlayerLayout.miniPlayerScrollRunway
      )
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let currentBook, presentedPlayerBook == nil {
          MiniPlayerView(model: model, book: currentBook) {
            presentedPlayerBook = currentBook
          }
          .padding(.horizontal, 10)
          .padding(.bottom, 5)
        }
      }
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
      if E2EMultifileAcquisition.shared.isConfigured,
        E2EMultifileAcquisition.shared.entryPoint == .directAdd
      {
        beginFileImport()
        return
      }
      if E2EZipAcquisition.shared.sourceURL != nil {
        beginFileImport()
        return
      }
    #endif
    isReceivingFromComputer = true
  }

  private func beginFileImport() {
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

  private func drainSharedImports() async {
    guard !isDrainingSharedImports else { return }
    isDrainingSharedImports = true
    defer { isDrainingSharedImports = false }
    guard let queue = sharedImportQueue() else { return }
    do {
      while let handoff = try await queue.claimNext() {
        selection = .inbox
        _ = await model.importSharedHandoff(handoff, from: queue)
        sharedImportQueueRevision += 1
      }
    } catch {
      // A malformed handoff remains quarantined in Processing for a future
      // recovery UI; never discard shared source bytes on launch.
    }
  }

  private func acceptDocumentOpen(_ url: URL) {
    selection = .inbox
    #if E2E
      E2EImportIngressBridge.shared.recordDocumentSource(url)
    #endif
    guard model.isRestored else {
      pendingDocumentURLs.append(url)
      return
    }
    Task { await model.handleDocumentOpen(url) }
  }

  private func drainPendingDocumentURLs() async {
    let urls = pendingDocumentURLs
    pendingDocumentURLs.removeAll()
    for url in urls {
      _ = await model.handleDocumentOpen(url)
    }
  }

  private func sharedImportQueue() -> AppGroupImportHandoffQueue? {
    #if E2E
      if let queue = E2EImportIngressBridge.shared.queue { return queue }
    #endif
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: PlayerAppGroup.identifier
    ) else { return nil }
    return AppGroupImportHandoffQueue(containerURL: container)
  }
}

private enum AppSection: Hashable { case library, inbox, settings, add }

private struct LibraryView: View {
  @Bindable var model: PlayerModel
  let startComputerReceiver: () -> Void
  let startFileImport: () -> Void
  @State private var path = NavigationPath()
  let presentPlayer: (Book) -> Void

  var body: some View {
    NavigationStack(path: $path) {
      ZStack {
        PlayerColor.background.ignoresSafeArea()
        if model.library.books.isEmpty {
          emptyState
        } else {
          LibraryOrganizationHome(model: model) { book in
            if model.library.currentBookID == book.id {
              presentPlayer(book)
            } else {
              Task {
                await model.play(bookID: book.id)
                presentPlayer(book)
              }
            }
          }
        }
      }
      .navigationTitle("Library")
      .navigationDestination(for: UUID.self) { id in
        if model.library.books.contains(where: { $0.id == id }) {
          BookDetailView(model: model, bookID: id) { book, position in
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
        Text("Send books from your computer or choose files already on this iPhone.")
          .multilineTextAlignment(.center)
          .foregroundStyle(PlayerColor.secondary)
          .lineSpacing(3)
      }
      Button { startComputerReceiver() } label: {
        Label("Receive from Computer", systemImage: "laptopcomputer.and.iphone")
          .font(.headline)
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(PlayerColor.accent)
      .frame(maxWidth: 280)
      .accessibilityIdentifier("receive-from-computer-empty-library")
      Button("Choose from Files", systemImage: "folder") { startFileImport() }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(PlayerColor.accent)
        .frame(maxWidth: 280)
        .accessibilityIdentifier("choose-from-files-empty-library")
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
  @State private var pendingAbandonment: ImportJob?
  @State private var path = NavigationPath()

  var body: some View {
    NavigationStack(path: $path) {
      ZStack {
        PlayerColor.background.ignoresSafeArea()
        if inboxJobs.isEmpty {
          ContentUnavailableView(
            "Inbox is clear",
            systemImage: "tray",
            description: Text("New imports will wait here for review.")
          )
        } else {
          List(inboxJobs) { job in
            NavigationLink(value: job.id) { ImportJobRow(job: job) }
              .listRowBackground(PlayerColor.card)
              .accessibilityIdentifier(
                job.phase == .failed
                  ? "view-import-error-\(job.id.uuidString.lowercased())"
                  : "review-import-job-\(job.id.uuidString.lowercased())"
              )
              .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                  pendingAbandonment = job
                }
                .disabled(job.phase == .committing)
                .accessibilityIdentifier("abandon-import-\(job.id.uuidString.lowercased())")
              }
          }
          .playerMiniPlayerScrollRunway()
          .scrollContentBackground(.hidden)
        }
      }
      .navigationTitle("Inbox")
      .navigationDestination(for: UUID.self) { jobID in
        if let job = model.library.importJobs.first(where: { $0.id == jobID }) {
          destination(for: job)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("inbox-screen")
      .accessibilityValue(inboxState)
      .confirmationDialog(
        "Abandon this import?",
        isPresented: Binding(
          get: { pendingAbandonment != nil },
          set: { if !$0 { pendingAbandonment = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("Abandon Import", role: .destructive) {
          guard let job = pendingAbandonment else { return }
          pendingAbandonment = nil
          Task { await model.abandonImport(jobID: job.id) }
        }
        Button("Keep Import", role: .cancel) { pendingAbandonment = nil }
      } message: {
        Text(abandonmentMessage)
      }
    }
  }

  private var inboxJobs: [ImportJob] {
    model.library.importJobs.filter { ![.committed, .cancelled].contains($0.phase) }
  }

  private var abandonmentMessage: String {
    guard pendingAbandonment != nil else { return "" }
    return "This removes the Inbox entry and its temporary copied files. Your original files stay untouched."
  }

  private var inboxState: String {
    let ready = inboxJobs.filter {
      $0.phase == .ready || $0.phase == .needsReview
    }.count
    let processing = inboxJobs.filter {
      [.queued, .acquiring, .extracting, .inspecting, .committing].contains($0.phase)
    }.count
    return "import:\(inboxJobs.count)-review:\(ready)-processing:\(processing)"
  }

  private func finishImport() {
    path = NavigationPath()
    didCommit()
  }

  @ViewBuilder
  private func destination(for job: ImportJob) -> some View {
    if job.recoveryPlan != nil {
      ImportRecoveryView(
        model: model,
        jobID: job.id,
        startImport: startImport,
        didCommit: finishImport
      )
    } else if job.phase == .failed {
      ImportErrorView(model: model, jobID: job.id, startImport: startImport)
    } else {
      ReviewImportView(model: model, jobID: job.id, didCommit: finishImport)
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
          .foregroundStyle(stageColor)
        if [.acquiring, .extracting, .inspecting, .committing].contains(job.phase) {
          ProgressView().tint(PlayerColor.accent)
        }
        actionLabel
      }
      Spacer(minLength: 8)
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("import-job-\(job.id.uuidString.lowercased())")
    .accessibilityValue("\(job.phase.rawValue):action=\(actionToken)")
  }

  @ViewBuilder
  private var actionLabel: some View {
    switch job.phase {
    case .ready:
      Label("Review & Add", systemImage: "arrow.right.circle.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(PlayerColor.accent)
        .accessibilityIdentifier("ready-import-action-\(job.id.uuidString.lowercased())")
    case .needsReview:
      Label("Review required", systemImage: "exclamationmark.circle.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.orange)
        .accessibilityIdentifier("review-required-action-\(job.id.uuidString.lowercased())")
    case .failed:
      Label("View issue", systemImage: "arrow.right.circle.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.red)
    default:
      EmptyView()
    }
  }

  private var actionToken: String {
    switch job.phase {
    case .ready: "review-and-add"
    case .needsReview: "review-required"
    case .failed: "view-issue"
    default: "none"
    }
  }

  private var stageColor: Color {
    switch job.phase {
    case .ready, .committed: .green
    case .needsReview: .orange
    case .failed: .red
    default: PlayerColor.secondary
    }
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
      return "Bookshelf could not safely import this selection."
    }
    switch failure.reasonCode {
    case "path-traversal":
      return "This ZIP contains a file path that could leave its import folder. Choose a different archive."
    case "symlink":
      return "This ZIP contains a link instead of an audiobook file. Choose a different archive."
    case "compression-ratio", "entry-count", "entry-size":
      return "This ZIP exceeds Bookshelf’s safe extraction limits. Choose a smaller archive."
    case "inspection-transient":
      return "The audio files were extracted safely, but inspection was interrupted. Try again."
    default:
      return failure.message
    }
  }
}

struct ReviewImportView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: PlayerModel
  let jobID: UUID
  let didCommit: () -> Void
  @State private var isConfirmingAbandonment = false

  var body: some View {
    ScrollViewReader { _ in
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
            .playerMiniPlayerScrollRunway()
            .accessibilityIdentifier("review-import-scroll")
            .e2eScrollReadiness(
              id: "review-import-scroll-readiness",
              containerID: "review-import-scroll",
              axis: .vertical
            )
          }
        } else {
          ProgressView("Preparing review…")
        }
      }
    }
    .navigationTitle("Review Import")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Abandon Import", systemImage: "trash", role: .destructive) {
          isConfirmingAbandonment = true
        }
        .tint(.red)
        .accessibilityIdentifier("abandon-import")
      }
    }
    .confirmationDialog(
      "Abandon this import?",
      isPresented: $isConfirmingAbandonment,
      titleVisibility: .visible
    ) {
      Button("Abandon Import", role: .destructive) {
        Task {
          if await model.abandonImport(jobID: jobID) { dismiss() }
        }
      }
      Button("Keep Import", role: .cancel) {}
    } message: {
      Text("This removes the Inbox entry and its temporary copied files. Your original files stay untouched.")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("review-import-screen")
    .accessibilityValue(reviewAccessibilityValue)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let job = model.library.importJobs.first(where: { $0.id == jobID }),
         job.proposal != nil {
        primaryAction(job: job)
      }
    }
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
    !dynamicTypeSize.isAccessibilitySize
      && job.proposals.count == 1
      && proposal.assets.count == 1
      && proposal.warnings.isEmpty
  }

  private func reviewContent(job: ImportJob, proposal: BookProposal) -> some View {
    VStack(spacing: 24) {
      ArtworkView(data: proposal.renderedArtworkData, size: 152)
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
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("grouping-evidence-folder-name")
          Spacer()
          Label("Filename stem", systemImage: "textformat")
            .accessibilityElement(children: .combine)
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
      NavigationLink {
        MetadataEditorView(model: model, target: .proposal(jobID: jobID, proposalID: proposal.id))
      } label: {
        Label("Edit Details", systemImage: "pencil")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .tint(PlayerColor.accent)
      .accessibilityIdentifier("edit-metadata")
      .id("review-edit-metadata")
    }
  }

  private func primaryAction(job: ImportJob) -> some View {
    let warnings = job.proposals.reduce(0) { $0 + $1.warnings.count }
    let isCommitting = job.phase == .committing
    let isReady = job.phase == .ready || job.phase == .needsReview
    let canAdd = isReady && warnings == 0
    return VStack(spacing: 7) {
      Button {
        Task {
          if await model.addImportToLibrary(jobID: jobID) != nil {
            UIAccessibility.post(
              notification: .announcement,
              argument: "Audiobook added to Library"
            )
            didCommit()
          }
        }
      } label: {
        Label("Add to Library", systemImage: "plus.circle.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(PlayerColor.accent)
      .disabled(!canAdd)
      .accessibilityIdentifier("add-import-to-library")
      .accessibilityValue(
        isCommitting
          ? "committing:disabled"
          : canAdd
            ? "ready:enabled"
            : warnings > 0
              ? "blocked:\(warnings)-warnings:disabled"
              : "\(job.phase.rawValue):disabled"
      )
      if warnings > 0 {
        Text("Resolve \(warnings) warning\(warnings == 1 ? "" : "s") to add this book.")
          .font(.caption)
          .foregroundStyle(PlayerColor.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 8)
    .background(.regularMaterial)
    .overlay(alignment: .top) { Divider() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("review-import-primary-action")
    .accessibilityValue(
      isCommitting
        ? "committing:disabled"
        : warnings == 0 ? "ready:enabled" : "blocked:\(warnings)-warnings:disabled"
    )
  }

  private func evidence(_ symbol: String, value: String) -> some View {
    HStack {
      Image(systemName: symbol)
      Text(value).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
      Spacer()
    }
    .padding(14)
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
        .playerMiniPlayerScrollRunway()
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
      .accessibilityElement(children: .combine)
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

struct BookRow: View {
  let book: Book
  var body: some View {
    HStack(spacing: 14) {
      ArtworkView(data: book.renderedArtworkData, size: 76)
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

private enum BookDetailContent: String { case chapters, bookmarks }

struct BookDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: PlayerModel
  let bookID: UUID
  let play: (Book, Double?) -> Void
  @State private var isConfirmingRemoval = false
  @State private var isConfirmingFinished = false
  @State private var selectedContent: BookDetailContent = .chapters

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      if let book {
        ScrollView {
          VStack(spacing: 18) {
            ArtworkView(data: book.renderedArtworkData, size: 210)
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
            Button { play(book, nil) } label: {
              Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(PlayerColor.accent)
            .accessibilityIdentifier("play-book")
            .id("book-detail-play")

            adaptiveActionLayout {
              NavigationLink {
                MetadataEditorView(model: model, target: .book(book.id))
              } label: {
                Label("Edit", systemImage: "pencil").frame(maxWidth: .infinity)
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("edit-book-metadata")

              if hasUndoableMetadata(book) {
                Button {
                  Task { _ = await model.undoLastMetadataTransaction(for: .book(book.id)) }
                } label: {
                  Label("Undo Edit", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("undo-metadata-repair")
              }
            }

            adaptiveActionLayout {
              Button {
                Task {
                  if model.library.upNextBookIDs.contains(book.id) {
                    _ = await model.removeFromUpNext(bookID: book.id)
                  } else {
                    _ = await model.addToUpNext(bookID: book.id)
                  }
                }
              } label: {
                Label(
                  model.library.upNextBookIDs.contains(book.id) ? "Remove from Up Next" : "Add to Up Next",
                  systemImage: "text.badge.plus"
                )
                .frame(maxWidth: .infinity)
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("toggle-up-next-\(book.id.uuidString.lowercased())")

              Button {
                if book.listeningState.status == .finished {
                  Task { _ = await model.setBookFinished(bookID: book.id, isFinished: false) }
                } else {
                  isConfirmingFinished = true
                }
              } label: {
                Label(
                  book.listeningState.status == .finished ? "Mark Unfinished" : "Mark Finished",
                  systemImage: book.listeningState.status == .finished ? "arrow.counterclockwise" : "checkmark.circle"
                )
                .frame(maxWidth: .infinity)
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("mark-finished-\(book.id.uuidString.lowercased())")
            }

            Button(role: .destructive) { isConfirmingRemoval = true } label: {
              Label("Move to Trash", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("remove-book")

            if !book.chapters.isEmpty || !model.bookmarks(for: book.id).isEmpty {
              adaptiveActionLayout {
                contentButton("Chapters", value: .chapters, id: "chapters-segment")
                contentButton("Bookmarks", value: .bookmarks, id: "bookmarks-segment")
              }
              .padding(4)
              .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 12))
              .accessibilityElement(children: .contain)
              .accessibilityIdentifier("book-detail-content-picker")
              .accessibilityValue(selectedContent.rawValue)
            }

            if selectedContent == .chapters, !book.chapters.isEmpty {
              VStack(alignment: .leading, spacing: 10) {
                Text("Chapters").font(.title3.bold())
                ForEach(Array(book.chapters.enumerated()), id: \.element.id) { index, chapter in
                  Button { play(book, chapter.startSeconds) } label: {
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
            } else if selectedContent == .bookmarks {
              VStack(alignment: .leading, spacing: 10) {
                Text("Bookmarks").font(.title3.bold())
                BookmarksView(model: model, bookID: book.id)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(24)
          .padding(.bottom, 72)
        }
        .playerMiniPlayerScrollRunway()
        .accessibilityIdentifier("book-detail-scroll")
        .e2eScrollReadiness(
          id: "book-detail-scroll-readiness",
          containerID: "book-detail-scroll",
          axis: .vertical
        )
        metadataProbe(id: "book-metadata-probe", value: bookMetadataValue(book))
        metadataProbe(id: "book-metadata-provenance-probe", value: bookProvenanceValue(book))
        metadataProbe(id: "book-state-probe", value: bookStateValue(book))
        #if E2E
          metadataProbe(id: "book-cover-render-state", value: coverRenderState(book))
          if E2ECommittedMetadataBridge.shared.isConfigured {
            metadataProbe(
              id: "committed-metadata-integrity-probe",
              value: E2ECommittedMetadataBridge.shared.evidenceValue
            )
          }
        #endif
      } else {
        ProgressView("Loading book…")
      }
    }
    .navigationTitle("Book Detail")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(role: .destructive) { isConfirmingRemoval = true } label: {
          Image(systemName: "trash")
        }
        .accessibilityLabel("Move to Trash")
        .accessibilityIdentifier("move-book-to-trash-toolbar")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("book-detail-screen")
    .accessibilityValue(bookDetailValue)
    .confirmationDialog(
      "Move this audiobook to Trash?",
      isPresented: $isConfirmingRemoval,
      titleVisibility: .visible
    ) {
      Button("Move to Trash", role: .destructive) {
        removeBook(mediaPolicy: .moveManagedMediaToTrash)
      }
      .accessibilityIdentifier("remove-book-to-trash")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The audiobook and its app-managed audio stay recoverable in Trash. You can import the same audiobook again, and your original source files are never changed.")
    }
    .alert("Mark as finished?", isPresented: $isConfirmingFinished) {
      Button("Mark Finished") {
        Task { _ = await model.setBookFinished(bookID: bookID, isFinished: true) }
      }
      .accessibilityIdentifier("confirm-mark-finished")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This moves the listening position to the end and removes the book from Continue Listening and Up Next.")
    }
  }

  private var book: Book? {
    model.library.books.first(where: { $0.id == bookID })
  }

  private var adaptiveActionLayout: AnyLayout {
    if dynamicTypeSize.isAccessibilitySize {
      AnyLayout(VStackLayout(spacing: 12))
    } else {
      AnyLayout(HStackLayout(spacing: 12))
    }
  }

  private func contentButton(
    _ title: String,
    value: BookDetailContent,
    id: String
  ) -> some View {
    Button {
      selectedContent = value
    } label: {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(selectedContent == value ? Color.white : PlayerColor.ink)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
          selectedContent == value ? PlayerColor.accent : Color.clear,
          in: RoundedRectangle(cornerRadius: 9)
        )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
    .accessibilityValue(selectedContent == value ? "selected" : "not-selected")
  }

  private var bookDetailValue: String {
    guard let book else { return "book:loading" }
    let container = book.assets.first?.container.lowercased() ?? "unknown"
    return "book:ready:\(book.id.uuidString.lowercased()):\(book.chapters.count)-chapters:\(container)"
  }

  private func coverRenderState(_ book: Book) -> String {
    guard let cover = book.metadata.cover, let crop = cover.crop else {
      return "crop=none:rendered=false"
    }
    return String(
      format: "crop=x:%.3f:y:%.3f:width:%.3f:height:%.3f:rotation:%.1f:rendered=%@",
      crop.x,
      crop.y,
      crop.width,
      crop.height,
      crop.rotationDegrees,
      book.renderedArtworkData == cover.originalData ? "false" : "true"
    )
  }

  private func seriesLabel(name: String, position: String?) -> String {
    guard let position, !position.isEmpty else { return name }
    return "\(name) · Book \(position)"
  }

  private func hasUndoableMetadata(_ book: Book) -> Bool {
    MetadataField.allCases.contains { book.metadata.state(for: $0)?.lastTransactionID != nil }
  }

  private func removeBook(mediaPolicy: LibraryRemovalMediaPolicy) {
    Task {
      if await model.removeBook(bookID: bookID, mediaPolicy: mediaPolicy) != nil { dismiss() }
    }
  }

  private func bookStateValue(_ book: Book) -> String {
    "book:\(book.id.uuidString.lowercased()):finished=\(book.listeningState.status == .finished):position=\(book.listeningState.positionMilliseconds)"
  }

  private func metadataProbe(id: String, value: String) -> some View {
    Color.clear
      .frame(width: 1, height: 1)
      .id(value)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(id)
      .accessibilityIdentifier(id)
      .accessibilityValue(value)
  }

  private func bookMetadataValue(_ book: Book) -> String {
    let metadata = book.metadata
    let series = metadata.seriesMemberships.first.map { membership in
      membership.position.map { "\(membership.name) #\($0)" } ?? membership.name
    } ?? ""
    let cover = metadata.cover == nil
      ? "none"
      : metadata.state(for: .cover)?.provenance == .user ? "replacement" : "original"
    let locked = [
      (MetadataField.title, "title"), (MetadataField.narrators, "narrators"),
      (MetadataField.seriesName, "series"), (MetadataField.cover, "cover"),
    ].compactMap { field, label in
      metadata.state(for: field)?.isLocked == true ? label : nil
    }.joined(separator: ",")
    return "metadata:book:title=\(metadata.title):authors=\(metadata.authors.count):narrators=\(metadata.narrators.count):series=\(series):cover=\(cover):locked=\(locked.isEmpty ? "none" : locked)"
  }

  private func bookProvenanceValue(_ book: Book) -> String {
    let metadata = book.metadata
    return "provenance:title=\(provenanceToken(metadata, .title)):authors=\(provenanceToken(metadata, .authors)):narrators=\(provenanceToken(metadata, .narrators)):series=\(provenanceToken(metadata, .seriesName)):cover=\(provenanceToken(metadata, .cover))"
  }

  private func provenanceToken(_ metadata: AudiobookMetadata, _ field: MetadataField) -> String {
    guard let state = metadata.state(for: field) else { return "legacy-library" }
    if state.isExplicitlyCleared { return "user-clear" }
    switch state.provenance {
    case .embeddedTag: return field == .cover ? "embedded-artwork" : "embedded-tag"
    case .filename: return "filename"
    case .folderName: return "folder-name"
    case .fileOrder: return "file-order"
    case .legacyLibrary: return "legacy-library"
    case .user: return "user"
    }
  }
}

struct PlaybackSliderConfiguration: Equatable {
  let upperBound: Double
  let step: Double

  init(durationSeconds: Double) {
    upperBound = durationSeconds.isFinite && durationSeconds > 0
      ? max(1, durationSeconds)
      : 1
    step = min(30, upperBound)
  }

  func clampedPosition(_ positionSeconds: Double) -> Double {
    guard positionSeconds.isFinite else { return 0 }
    return min(max(0, positionSeconds), upperBound)
  }
}

private struct NowPlayingView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: PlayerModel
  let book: Book
  let showsRewindExpiryControl: Bool
  @State private var requestedPosition: Double?
  @State private var showsTransportPreferences = false
  @State private var showsSleepTimer = false
  @State private var smartRewindUndoPositionMilliseconds: Int64?
  @State private var savedBookmarkID: UUID?
  var body: some View {
    let slider = PlaybackSliderConfiguration(durationSeconds: displayedDuration)
    ZStack {
      NavigationStack {
        ScrollViewReader { _ in
          ZStack {
            PlayerColor.background.ignoresSafeArea()
            VStack(spacing: 24) {
          Spacer()
          ArtworkView(data: book.renderedArtworkData, size: 270)
          VStack(spacing: 7) {
            Text(book.title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(book.authors.first ?? "Unknown Author").foregroundStyle(PlayerColor.secondary)
            if let chapter = currentChapter {
              Text(chapter.title).font(.subheadline.weight(.semibold))
              Text("Chapter \(currentChapterIndex + 1) of \(book.chapters.count)")
                .font(.caption).foregroundStyle(PlayerColor.secondary)
            }
          }
          if let savedBookmark {
            bookmarkSavedBanner(savedBookmark)
          } else if let context = model.sleepResumeContext, context.bookID == book.id {
            sleepResumeBanner(context)
          } else if let transaction = model.pendingResumeRewind {
            smartRewindBanner(transaction)
          } else if let restored = smartRewindUndoPositionMilliseconds {
            Label(
              "Returned to \(timecode(Double(restored) / 1_000))",
              systemImage: "checkmark.circle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PlayerColor.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Returned to saved position")
            .accessibilityIdentifier("smart-rewind-undo-confirmation")
            .accessibilityValue("restored=\(restored)")
          }
          Slider(
            value: Binding(
              get: { slider.clampedPosition(requestedPosition ?? displayedPosition) },
              set: { requestedPosition = slider.clampedPosition($0) }
            ),
            in: 0...slider.upperBound,
            step: slider.step,
            onEditingChanged: { isEditing in
              guard !isEditing, let position = requestedPosition else { return }
              Task {
                await model.seek(to: position, context: preferences.seekContext)
                requestedPosition = nil
              }
            }
          )
          .tint(PlayerColor.accent)
          .accessibilityLabel("Listening position")
          .accessibilityValue(positionAccessibilityValue)
          .accessibilityHint("Swipe up or down to move through this listening timeline")
          .accessibilityIdentifier("player-position-slider")
          .id("now-playing-timeline")
          HStack {
            Text(visibleElapsedLabel)
              .accessibilityLabel("Elapsed time")
              .accessibilityValue(visibleElapsedLabel)
              .accessibilityIdentifier("player-elapsed-time")
            Spacer()
            Text(visibleRemainingLabel)
              .accessibilityLabel("Remaining time")
              .accessibilityValue(visibleRemainingLabel)
              .accessibilityIdentifier("player-remaining-time")
          }
          .font(.caption.monospacedDigit())
          .foregroundStyle(PlayerColor.secondary)
          HStack(spacing: 13) {
            transportButton(
              "Previous chapter",
              systemImage: "backward.end.fill",
              identifier: "player-previous-chapter",
              disabled: currentChapterIndex == 0
            ) { await model.previousChapter() }
            transportButton(
              "Skip back \(Int(preferences.backwardSkipSeconds)) seconds",
              systemImage: "gobackward.\(skipSymbol(preferences.backwardSkipSeconds))",
              identifier: "player-skip-backward"
            ) { await model.skipBackward() }
            Button {
              Task {
                if model.playbackState.status == .playing { await model.pause() }
                else { await model.play(bookID: book.id) }
              }
            } label: {
              Image(systemName: model.playbackState.status == .playing ? "pause.fill" : "play.fill")
                .font(.system(size: 28, weight: .semibold)).frame(width: 66, height: 66)
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.circle).tint(PlayerColor.accent)
            .accessibilityLabel(model.playbackState.status == .playing ? "Pause" : "Play")
            .accessibilityIdentifier("player-play-pause")
            .id("now-playing-transport")
            transportButton(
              "Skip forward \(Int(preferences.forwardSkipSeconds)) seconds",
              systemImage: "goforward.\(skipSymbol(preferences.forwardSkipSeconds))",
              identifier: "player-skip-forward"
            ) { await model.skipForward() }
            transportButton(
              "Next chapter",
              systemImage: "forward.end.fill",
              identifier: "player-next-chapter",
              disabled: currentChapterIndex >= book.chapters.count - 1
            ) { await model.nextChapter() }
          }
          Button {
            showsTransportPreferences = true
          } label: {
            HStack {
              Text(TransportPreferencesEditor.rateLabel(preferences.playbackRate))
                .font(.headline.monospacedDigit())
              Text("Playback settings")
              Spacer()
              Image(systemName: "slider.horizontal.3")
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
          .accessibilityIdentifier("open-transport-preferences")
          .accessibilityValue(transportValue)
            Spacer()
          }
          .padding(24)
          .accessibilityScrollsIfNeeded(
            dynamicTypeSize.isAccessibilitySize,
            identifier: "now-playing-scroll",
            readinessID: "now-playing-scroll-readiness",
            axis: .vertical
          )
          }
        }
        .toolbar { nowPlayingToolbar }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-playing-screen")
        .accessibilityValue(playerValue)
        .e2eLayoutReadiness(
          id: "now-playing-layout-readiness",
          containerID: "now-playing-screen"
        )
        .animation(.easeOut(duration: 0.3), value: model.pendingResumeRewind?.id)
        #if E2E
          .overlay { smartRewindStateProbe }
          .overlay(alignment: .topTrailing) {
            if E2ESleepTimerBridge.shared.isConfigured {
              E2ESleepTimerControlSurface(model: model)
            }
          }
          .overlay(alignment: .bottomLeading) {
            if E2EBookmarkBridge.shared.isConfigured {
              E2EBookmarkControlSurface(model: model)
                .padding(.leading, 4)
                .padding(.bottom, 72)
            }
          }
          .overlay(alignment: .topLeading) {
            if showsRewindExpiryControl {
              Button("Advance five seconds") {
                Task {
                  await model.seek(to: model.playbackState.elapsedSeconds + 5)
                  await model.synchronizePlaybackProgress()
                }
              }
              .accessibilityIdentifier("e2e-advance-rewind-expiry")
            }
          }
        #endif
      }
      if showsSleepTimer {
        PlayerColor.background.ignoresSafeArea()
      }
    }
    .sheet(isPresented: $showsTransportPreferences) {
      NavigationStack {
        TransportPreferencesEditor(model: model, book: currentBookFromModel ?? book)
      }
    }
    .sheet(isPresented: $showsSleepTimer) {
      SleepTimerView(model: model)
    }
  }

  @ToolbarContentBuilder
  private var nowPlayingToolbar: some ToolbarContent {
    if #available(iOS 26.0, *) {
      ToolbarItem(placement: .topBarLeading) {
        Button { dismiss() } label: {
          Text("Done")
            .foregroundStyle(PlayerColor.accent)
            .frame(width: 64, height: 44)
            .background(PlayerColor.card, in: Capsule())
            .overlay { Capsule().stroke(PlayerColor.ink.opacity(0.05), lineWidth: 1) }
            .shadow(color: PlayerColor.ink.opacity(0.10), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .fixedSize()
      }
      .sharedBackgroundVisibility(.hidden)

      ToolbarItem(placement: .topBarTrailing) {
        HStack(spacing: 0) {
          addBookmarkButton
          sleepTimerToolbarButton
        }
        .foregroundStyle(PlayerColor.accent)
        .frame(width: 94, height: 44)
        .background(PlayerColor.card, in: Capsule())
        .overlay { Capsule().stroke(PlayerColor.ink.opacity(0.05), lineWidth: 1) }
        .shadow(color: PlayerColor.ink.opacity(0.10), radius: 12, y: 5)
        .fixedSize()
      }
      .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
      ToolbarItemGroup(placement: .topBarTrailing) {
        addBookmarkButton
        sleepTimerToolbarButton
      }
    }
  }

  private var addBookmarkButton: some View {
    Button {
      Task { savedBookmarkID = await model.addBookmark() }
    } label: {
      Image(systemName: "bookmark").frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Add Bookmark")
    .accessibilityIdentifier("add-bookmark")
  }

  private var sleepTimerToolbarButton: some View {
    Button { showsSleepTimer = true } label: {
      Image(systemName: model.activeSleepTimer == nil ? "moon.zzz" : "timer")
        .frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Sleep Timer")
    .accessibilityIdentifier("open-sleep-timer")
    .accessibilityValue(sleepTimerButtonValue)
  }

  private var preferences: TransportPreferences {
    model.transportPreferences(for: book.id)
  }

  private var currentBookFromModel: Book? {
    model.library.books.first(where: { $0.id == book.id })
  }

  private var savedBookmark: Bookmark? {
    guard let savedBookmarkID else { return nil }
    return model.library.bookmarks.first(where: { $0.id == savedBookmarkID })
  }

  private func bookmarkSavedBanner(_ bookmark: Bookmark) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "bookmark.fill")
        .foregroundStyle(PlayerColor.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text("Bookmark saved").font(.headline)
        Text(bookmark.label)
          .font(.caption)
          .foregroundStyle(PlayerColor.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(PlayerColor.accent.opacity(0.25), lineWidth: 1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Bookmark saved")
    .accessibilityIdentifier("bookmark-saved")
    .accessibilityValue(
      Text(verbatim: "bookmark=\(bookmark.id.uuidString.lowercased()):book=\(bookmark.bookID.uuidString.lowercased()):position=\(bookmark.bookPositionMilliseconds)")
    )
  }

  private var sleepTimerButtonValue: String {
    guard let projection = model.activeSleepTimerProjection else { return "inactive" }
    let remaining = projection.remainingSeconds.map { Int(max(0, $0).rounded(.down)) }
    return "active:\(projection.timerID.uuidString.lowercased()):remaining=\(remaining.map(String.init) ?? "none"):phase=\(projection.phase.rawValue)"
  }

  private func sleepResumeBanner(_ context: SleepResumeContext) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "moon.zzz.fill").foregroundStyle(PlayerColor.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text("Sleep timer ended").font(.headline)
        Text("Pick up the thread before the stop.")
          .font(.caption)
          .foregroundStyle(PlayerColor.secondary)
      }
      Spacer(minLength: 8)
      Button("Resume") {
        Task { _ = await model.resumeFromSleepWithContext() }
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("resume-sleep-context")
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(PlayerColor.accent.opacity(0.25), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("sleep-resume-context")
    .accessibilityValue(
      Text(verbatim: "history=\(context.historyID.uuidString.lowercased()):book=\(context.bookID.uuidString.lowercased()):stop=\(context.stoppedPositionMilliseconds):until=\(Int(context.availableUntil.timeIntervalSince1970))")
    )
  }

  private func smartRewindBanner(_ transaction: ResumeRewindTransaction) -> some View {
    let plan = transaction.plan
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "gobackward")
          .foregroundStyle(PlayerColor.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text("Rewound \(smartRewindDuration(plan.rewindMilliseconds))")
            .font(.headline)
          Text(
            plan.wasClampedToChapterStart
              ? "Stopped at this chapter’s start."
              : "Helping you pick up after time away."
          )
            .font(.caption)
            .foregroundStyle(PlayerColor.secondary)
        }
        Spacer(minLength: 8)
        Button("Undo") {
          Task {
            if await model.undoResumeRewind() {
              smartRewindUndoPositionMilliseconds = plan.originalPositionMilliseconds
            }
          }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("undo-smart-rewind")
        .accessibilityValue("restore=\(plan.originalPositionMilliseconds)")
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(PlayerColor.accent.opacity(0.25), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("smart-rewind-banner")
    .accessibilityValue([
      "rewound",
      book.id.uuidString.lowercased(),
      "from=\(plan.originalPositionMilliseconds)",
      "to=\(plan.targetPositionMilliseconds)",
      "by=\(plan.rewindMilliseconds)",
      "away=\(Int(plan.secondsAway.rounded(.down)))",
      "clamped=\(plan.wasClampedToChapterStart)",
      "status=\(transaction.status.rawValue)",
    ].joined(separator: "|"))
    .transition(.opacity.combined(with: .scale(scale: 0.98)))
  }

  private func smartRewindDuration(_ milliseconds: Int64) -> String {
    let seconds = Double(milliseconds) / 1_000
    if seconds.rounded() == seconds { return "\(Int(seconds)) seconds" }
    return String(format: "%.1f seconds", seconds)
  }

  private var displayedPosition: Double {
    guard preferences.seekContext == .chapter, let chapter = currentChapter else {
      return model.playbackState.elapsedSeconds
    }
    return max(0, model.playbackState.elapsedSeconds - chapter.startSeconds)
  }

  private var displayedDuration: Double {
    preferences.seekContext == .chapter ? (currentChapter?.durationSeconds ?? book.durationSeconds) : book.durationSeconds
  }

  private var visibleTimelinePosition: Double {
    min(max(0, requestedPosition ?? displayedPosition), max(0, displayedDuration))
  }

  private var visibleElapsedLabel: String {
    compactPlaybackTime(visibleTimelinePosition)
  }

  private var visibleRemainingLabel: String {
    compactPlaybackTime(max(displayedDuration - visibleTimelinePosition, 0))
  }

  private var transportValue: String {
    let source = currentBookFromModel?.transportPreferenceOverride == nil ? "global" : "book"
    let seek = preferences.seekContext == .chapter ? "chapter" : "whole-book"
    return "rate=\(TransportPreferencesEditor.rateToken(preferences.playbackRate)):back=\(Int(preferences.backwardSkipSeconds)):forward=\(Int(preferences.forwardSkipSeconds)):seek=\(seek):source=\(source)"
  }

  private var positionAccessibilityValue: String {
    let elapsed = sliderAccessibilityTime(displayedPosition)
    let remaining = sliderAccessibilityTime(max(displayedDuration - displayedPosition, 0))
    let percent = displayedDuration > 0
      ? Int((displayedPosition / displayedDuration * 100).rounded()) : 0
    if let chapter = currentChapter {
      return "\(chapter.title), \(elapsed) elapsed, \(remaining) remaining, \(percent) percent"
    }
    return "\(elapsed) elapsed, \(remaining) remaining, \(percent) percent"
  }

  private func sliderAccessibilityTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    let minutes = value / 60
    let remainder = value % 60
    return "\(minutes) minutes \(remainder) seconds"
  }

  private func skipSymbol(_ seconds: Double) -> String {
    let supported = [10, 15, 30, 45, 60]
    let value = Int(seconds.rounded())
    return supported.contains(value) ? "\(value)" : "30"
  }

  private func transportButton(
    _ label: String,
    systemImage: String,
    identifier: String,
    disabled: Bool = false,
    action: @escaping @MainActor () async -> Void
  ) -> some View {
    Button { Task { await action() } } label: {
      Image(systemName: systemImage)
        .font(.system(size: 20, weight: .semibold))
        .frame(width: 38, height: 44)
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
  }

  private var playerValue: String {
    let milliseconds = Int((model.playbackState.elapsedSeconds * 1_000).rounded())
    return "player:\(model.playbackState.status.rawValue):\(book.id.uuidString.lowercased()):\(currentChapterIndex):\(milliseconds)"
  }

  #if E2E
    private var smartRewindStateProbe: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .id(smartRewindStateValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Smart Rewind state")
        .accessibilityIdentifier("smart-rewind-state-probe")
        .accessibilityValue(smartRewindStateValue)
    }

    private var smartRewindStateValue: String {
      let rewindPreferences = model.library.smartRewindPreferences
      let transactions = model.library.resumeRewindTransactions
      let latest = transactions.last
      let position = model.library.playbackPosition?.positionMilliseconds ?? 0
      let journal = model.library.positionJournal.map {
        "\($0.sequence):\($0.reason.rawValue)@\($0.positionMilliseconds)"
      }.joined(separator: ",")
      var tokens = [
        "smart-rewind",
        "schema=1",
        "enabled=\(rewindPreferences.isEnabled)",
        "maximum=\(Int64((rewindPreferences.maximumRewindSeconds * 1_000).rounded(.down)))",
        "transactions=\(transactions.count)",
        "latest=\(latest?.status.rawValue ?? "none")",
      ]
      if let latest {
        tokens.append(contentsOf: [
          "transaction=\(latest.id.uuidString.lowercased())",
          "from=\(latest.plan.originalPositionMilliseconds)",
          "to=\(latest.plan.targetPositionMilliseconds)",
          "by=\(latest.plan.rewindMilliseconds)",
          "away=\(Int(latest.plan.secondsAway.rounded(.down)))",
          "clamped=\(latest.plan.wasClampedToChapterStart)",
          "pre=\(latest.preRewindEventID.uuidString.lowercased())",
          "rewind=\(latest.rewindEventID.uuidString.lowercased())",
          "undo=\(latest.undoEventID?.uuidString.lowercased() ?? "none")",
        ])
      }
      tokens.append("position=\(position)")
      tokens.append("journal=\(journal)")
      return tokens.joined(separator: "|")
    }
  #endif

  private var currentChapterIndex: Int {
    book.chapters.lastIndex(where: { $0.startSeconds <= model.playbackState.elapsedSeconds }) ?? 0
  }

  private var currentChapter: Chapter? {
    guard book.chapters.indices.contains(currentChapterIndex) else { return nil }
    return book.chapters[currentChapterIndex]
  }
}

private struct MiniPlayerView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.playerReducesDecorativeArtwork) private var reducesDecorativeArtwork
  @Bindable var model: PlayerModel
  let book: Book
  let open: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Button(action: open) {
        HStack(spacing: 12) {
          if !dynamicTypeSize.isAccessibilitySize && !reducesDecorativeArtwork {
            ArtworkView(data: book.renderedArtworkData, size: 44)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(book.title)
              .font(.subheadline.weight(.semibold))
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            HStack(spacing: 6) {
              Text(timelineLabel)
                .monospacedDigit()
                .accessibilityLabel("Playback time")
                .accessibilityValue("\(elapsedLabel) of \(durationLabel)")
                .accessibilityIdentifier("mini-player-timeline")
              if let projection = model.activeSleepTimerProjection {
                Text("·")
                Label(sleepTimerLabel(projection), systemImage: "moon.zzz.fill")
                  .accessibilityIdentifier("mini-player-sleep-timer")
              }
            }
            .font(.caption)
            .foregroundStyle(PlayerColor.secondary)
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
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(PlayerColor.ink.opacity(0.06), lineWidth: 1)
    }
    .shadow(color: PlayerColor.ink.opacity(0.10), radius: 14, y: 6)
    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .onTapGesture(perform: open)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mini-player")
    .accessibilityValue(miniPlayerValue)
  }

  private var miniPlayerValue: String {
    let milliseconds = Int((model.playbackState.elapsedSeconds * 1_000).rounded())
    var value = "player:\(model.playbackState.status.rawValue):\(book.id.uuidString.lowercased()):0:\(milliseconds)"
    if let projection = model.activeSleepTimerProjection {
      let remaining = projection.remainingSeconds.map { Int(max(0, $0).rounded(.down)) }
      let selection = model.activeSleepTimer.map { sleepSelectionToken($0.selection) } ?? "none"
      value += "|sleep=\(projection.timerID.uuidString.lowercased()),selection=\(selection),remaining=\(remaining.map(String.init) ?? "none"),fade=\(projection.fadeEnabled),phase=\(projection.phase.rawValue)"
    }
    return value
  }

  private func sleepTimerLabel(_ projection: SleepTimerProjection) -> String {
    guard let seconds = projection.remainingSeconds else { return projection.selectionLabel }
    let value = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", value / 60, value % 60)
  }

  private func sleepSelectionToken(_ selection: SleepTimerSelection) -> String {
    switch selection {
    case .preset(let preset): "preset-\(preset.rawValue)"
    case .custom(let seconds): "custom-\(Int(seconds.rounded(.down)))"
    case .endOfChapter: "end-chapter"
    case .endOfTrack: "end-track"
    }
  }

  private var elapsedLabel: String {
    compactPlaybackTime(min(model.playbackState.elapsedSeconds, max(0, book.durationSeconds)))
  }

  private var durationLabel: String { compactPlaybackTime(book.durationSeconds) }

  private var timelineLabel: String { "\(elapsedLabel) / \(durationLabel)" }
}

struct ArtworkView: View {
  @Environment(\.playerReducesDecorativeArtwork) private var reducesDecorativeArtwork
  let data: Data?
  let size: CGFloat
  var isEssential = false
  var cornerRadius: CGFloat? = nil
  var shadowRadius: CGFloat? = nil
  var shadowY: CGFloat? = nil
  var accessibilityIdentifierOverride: String? = nil

  var body: some View {
    Group {
      if reducesDecorativeArtwork && !isEssential {
        ZStack {
          PlayerColor.card
          Image(systemName: "book.closed.fill")
            .font(.title2)
            .foregroundStyle(PlayerColor.ink)
        }
      } else if let data, let image = UIImage(data: data) {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        ZStack {
          PlayerColor.ink
          Image(systemName: "waveform").font(.largeTitle).foregroundStyle(PlayerColor.background)
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? max(12, size * 0.07)))
    .shadow(
      color: PlayerColor.ink.opacity(reducesDecorativeArtwork && !isEssential ? 0 : 0.15),
      radius: reducesDecorativeArtwork && !isEssential ? 0 : shadowRadius ?? 18,
      y: reducesDecorativeArtwork && !isEssential ? 0 : shadowY ?? 10
    )
    .accessibilityElement()
    .accessibilityLabel(artworkLabel)
    .accessibilityIdentifier(artworkIdentifier)
  }

  private var artworkLabel: String {
    if reducesDecorativeArtwork && !isEssential { return "Decorative artwork reduced" }
    return data == nil ? "Artwork placeholder" : "Embedded cover artwork"
  }

  private var artworkIdentifier: String {
    if let accessibilityIdentifierOverride { return accessibilityIdentifierOverride }
    if reducesDecorativeArtwork && !isEssential { return "reduced-decorative-artwork" }
    return data == nil ? "placeholder-artwork" : "embedded-cover-artwork"
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

enum PlayerLayout {
  /// Every vertical scroll container under the tab player reserves this much
  /// real content length so its final control can move fully above the player.
  static let miniPlayerScrollRunway: CGFloat = 104
}

private struct PlayerMiniPlayerScrollRunwayKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
  var playerMiniPlayerScrollRunway: CGFloat {
    get { self[PlayerMiniPlayerScrollRunwayKey.self] }
    set { self[PlayerMiniPlayerScrollRunwayKey.self] = newValue }
  }
}

private struct PlayerMiniPlayerScrollRunwayModifier: ViewModifier {
  @Environment(\.playerMiniPlayerScrollRunway) private var runway

  @ViewBuilder
  func body(content: Content) -> some View {
    if runway > 0 {
      content.contentMargins(.bottom, runway, for: .scrollContent)
    } else {
      content
    }
  }
}

extension View {
  /// Apply to every vertical ScrollView, List, and Form that can be presented
  /// beneath the persistent mini-player. The environment is zero elsewhere.
  func playerMiniPlayerScrollRunway() -> some View {
    modifier(PlayerMiniPlayerScrollRunwayModifier())
  }
}

private func duration(_ seconds: Double) -> String {
  let minutes = max(1, Int(seconds.rounded()) / 60)
  return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
}

private func timecode(_ seconds: Double) -> String {
  let wholeSeconds = max(0, Int(seconds.rounded()))
  return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
}

func compactPlaybackTime(_ seconds: Double) -> String {
  let wholeSeconds = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
  let hours = wholeSeconds / 3_600
  let minutes = (wholeSeconds % 3_600) / 60
  let remainder = wholeSeconds % 60
  if hours > 0 {
    return String(format: "%dh%02dm%02ds", hours, minutes, remainder)
  }
  return String(format: "%dm%02ds", minutes, remainder)
}

#if E2E
  private struct E2EPlaybackControlSurface: View {
    @Bindable var model: PlayerModel

    var body: some View {
      VStack(alignment: .leading, spacing: 4) {
        probe
        control("Play", identifier: "e2e-remote-play") {
          E2EPlaybackEventBridge.shared.sendRemote(.play)
        }
        control("Pause", identifier: "e2e-remote-pause") {
          E2EPlaybackEventBridge.shared.sendRemote(.pause)
        }
        control("Toggle", identifier: "e2e-remote-toggle") {
          E2EPlaybackEventBridge.shared.sendRemote(.toggle)
        }
        control("Car Forward", identifier: "e2e-remote-next-track") {
          E2EPlaybackEventBridge.shared.sendRemote(.nextTrack)
        }
        control("Car Backward", identifier: "e2e-remote-previous-track") {
          E2EPlaybackEventBridge.shared.sendRemote(.previousTrack)
        }
        control("Interrupt", identifier: "e2e-interruption-began") {
          E2EPlaybackEventBridge.shared.sendAudioSession(.interruptionBegan)
        }
        control("End", identifier: "e2e-interruption-ended-no-resume") {
          E2EPlaybackEventBridge.shared.sendAudioSession(
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
        E2EPlaybackEventBridge.shared.audioSessionEvidence,
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
      if E2EMultifileAcquisition.shared.entryPoint == .explicitFileChoice {
        return model.library.importJobs.max {
          if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
          return $0.id.uuidString < $1.id.uuidString
        }
      }
      return model.library.importJobs.first {
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
      guard let filesystem = try? E2EMultifileAcquisition.shared.filesystemEvidence(
        library: model.library
      ) else {
        return "transaction:invalid:reason=filesystem-evidence-unavailable"
      }
      if job.phase == .committed {
        return "transaction:committed:books=\(model.library.books.count):assets=\(assetCount):\(filesystem.probeFields):source-unchanged=\(E2EMultifileAcquisition.shared.sourceIsUnchanged)"
      }
      return "transaction:pending:books=\(model.library.books.count):assets=\(assetCount):staging-records=\(job.stagedAssets.count):staging-files=\(filesystem.stagingFileCount):source-unchanged=\(E2EMultifileAcquisition.shared.sourceIsUnchanged)"
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
      let jobID = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
      let filesystem = acquisition.filesystemEvidence(jobID: jobID)
      let outsideWrites = filesystem.outsideWriteCount.map(String.init) ?? "unavailable"
      let integrity =
        "source-unchanged=\(acquisition.sourceIsUnchanged):outside-writes=\(outsideWrites)"
      guard let job = model.library.importJobs.first(where: {
        $0.id == jobID
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
        let staging = filesystem.stagingFileCount.map(String.init) ?? "unavailable"
        return "zip:\(zipCase):cancelled:extracted=\(extracted):staging=\(staging):\(integrity)"
      default:
        return "zip:\(zipCase):processing:entries=\(entries):extracted=\(extracted):\(integrity)"
      }
    }
  }

  private struct E2EImportIngressProbes: View {
    @Bindable var model: PlayerModel
    let queueRevision: Int

    var body: some View {
      VStack {
        if E2EImportIngressBridge.shared.channel == "document-open" {
          probe(
            identifier: "import-ingress-probe",
            label: "Document import ingress state",
            value: documentValue
          )
        }
        if E2EImportIngressBridge.shared.channel == "share-extension" {
          probe(
            identifier: "share-handoff-probe",
            label: "Share handoff state",
            value: shareValue
          )
        }
      }
    }

    private var expectedJob: ImportJob? {
      guard let id = E2EImportIngressBridge.shared.expectedJobID else { return nil }
      return model.library.importJobs.first(where: { $0.id == id })
    }

    private var documentValue: String {
      guard let job = expectedJob else { return "ingress:document:idle" }
      let checkpoint = job.queueCheckpoint
      let state: String
      switch job.phase {
      case .acquiring: state = "acquiring"
      case .inspecting: state = "inspecting"
      case .ready, .needsReview: state = "ready"
      default: state = job.phase.rawValue
      }
      var fields = [
        "ingress:document:\(state)",
        "job=\(job.id.uuidString.lowercased())",
        "jobs=\(model.library.importJobs.count)",
        "staged=\(checkpoint?.acquired.count ?? 0)",
        "inspected=\(checkpoint?.inspected.count ?? 0)",
      ]
      if state == "ready" { fields.append("proposals=\(job.proposals.count)") }
      fields += [
        "duplicates=\(max(0, model.library.importJobs.count - 1))",
        "source-unchanged=\(E2EImportIngressBridge.shared.sourceIsUnchanged)",
      ]
      return fields.joined(separator: ":")
    }

    private var shareValue: String {
      let bridge = E2EImportIngressBridge.shared
      guard let handoffID = bridge.handoffID else {
        return "handoff:share-extension:idle"
      }
      let evidence = bridge.shareEvidence(processingRevision: queueRevision)
      guard
        let jobID = evidence.jobID,
        let job = model.library.importJobs.first(where: { $0.id == jobID })
      else {
        return [
          "handoff:share-extension:unverified",
          "id=\(handoffID.uuidString.lowercased())",
          "jobs=\(model.library.importJobs.count)",
          "pending=\(bridge.pendingRequestCount)",
          "processing=\(bridge.processingRequestCount)",
          "source-unchanged=\(bridge.sourceIsUnchanged)",
        ].joined(separator: ":")
      }
      let receipt = model.library.shareImportReceipts.first(where: {
        $0.handoffID == handoffID
      })
      let receiptState = evidence.outcome == .deduplicated ? "retained" : "recorded"
      return [
        "handoff:share-extension:\(evidence.outcome.rawValue)",
        "id=\(handoffID.uuidString.lowercased())",
        "job=\(job.id.uuidString.lowercased())",
        "jobs=\(model.library.importJobs.count)",
        "staged=\(job.queueCheckpoint?.acquired.count ?? 0)",
        "proposals=\(job.proposals.count)",
        "receipt=\(receipt == nil ? "missing" : receiptState)",
        "pending=\(bridge.pendingRequestCount)",
        "processing=\(bridge.processingRequestCount)",
        "source-unchanged=\(bridge.sourceIsUnchanged)",
      ].joined(separator: ":")
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
#endif
