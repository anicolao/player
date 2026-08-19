import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @Bindable var model: PlayerModel
  @State private var selection: AppSection = .library
  @State private var isImporting = false
  @State private var presentedPlayerBook: Book?

  var body: some View {
    TabView(selection: $selection) {
      LibraryView(model: model, isImporting: $isImporting) { presentedPlayerBook = $0 }
        .tag(AppSection.library)
        .tabItem { Label("Library", systemImage: "books.vertical") }

      InboxView(model: model) { selection = .library }
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
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let source = urls.first else { return }
      selection = .inbox
      Task { await model.importAudio(from: source) }
    }
    .fullScreenCover(item: $presentedPlayerBook) { book in
      NowPlayingView(model: model, book: book)
    }
    .task { await model.restore() }
  }

  private var reviewCount: Int {
    model.library.importJobs.filter { $0.phase == .ready || $0.phase == .needsReview }.count
  }

  private var importTypes: [UTType] {
    ["m4b", "m4a", "mp3"].compactMap { UTType(filenameExtension: $0) } + [.zip]
  }
}

private enum AppSection: Hashable { case library, inbox, settings }

private struct LibraryView: View {
  @Bindable var model: PlayerModel
  @Binding var isImporting: Bool
  let presentPlayer: (Book) -> Void

  var body: some View {
    NavigationStack {
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
      .toolbar {
        if !model.library.books.isEmpty {
          ToolbarItem(placement: .topBarTrailing) {
            Button { isImporting = true } label: { Image(systemName: "plus") }
              .accessibilityLabel("Add Audiobook")
              .accessibilityIdentifier("add-audiobook-toolbar")
          }
        }
      }
      .navigationDestination(for: UUID.self) { id in
        if let book = model.library.books.first(where: { $0.id == id }) {
          BookDetailView(book: book) { presentPlayer(book) }
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
        Text("Import an M4B, M4A, MP3, or ZIP from Files.\nYour source files stay untouched.")
          .multilineTextAlignment(.center)
          .foregroundStyle(PlayerColor.secondary)
          .lineSpacing(3)
      }
      Button { isImporting = true } label: {
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
              ReviewImportView(model: model, jobID: job.id, didCommit: didCommit)
            } label: { ImportJobRow(job: job) }
              .listRowBackground(PlayerColor.card)
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
    let ready = model.library.importJobs.filter { $0.phase == .ready }.count
    let processing = model.library.importJobs.filter {
      [.queued, .acquiring, .inspecting, .committing].contains($0.phase)
    }.count
    return "import:\(model.library.importJobs.count)-review:\(ready)-processing:\(processing)"
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
        if [.acquiring, .inspecting, .committing].contains(job.phase) {
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
    case .inspecting: "Inspecting metadata"
    case .needsReview: "Needs review"
    case .ready: "Ready to add"
    case .committing: "Adding to Library"
    case .committed: "Added to Library"
    case .failed: job.failure?.message ?? "Import failed"
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
        VStack(spacing: 24) {
          ArtworkView(data: proposal.artworkData, size: 152)
          VStack(spacing: 7) {
            Text(proposal.title).font(.title2.bold())
            Text(proposal.authors.first ?? "Unknown Author").foregroundStyle(PlayerColor.secondary)
            Label("Embedded file details", systemImage: "checkmark.circle.fill")
              .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
          }
          VStack(spacing: 0) {
            evidence("tag", value: "Embedded metadata")
            Divider()
            evidence("doc", value: proposal.asset.originalFilename)
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
          .accessibilityIdentifier("add-import-to-library")
          Spacer()
        }
        .padding(20)
      } else {
        ProgressView("Preparing review…")
      }
    }
    .navigationTitle("Review Import")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("review-import-screen")
    .accessibilityValue("proposal:\(jobID.uuidString.lowercased())")
  }

  private func evidence(_ symbol: String, value: String) -> some View {
    HStack { Image(systemName: symbol); Text(value).lineLimit(1); Spacer() }.padding(14)
  }
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
  let play: () -> Void
  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      VStack(spacing: 20) {
        ArtworkView(data: book.artworkData, size: 210)
        Text(book.title).font(.title.bold()).multilineTextAlignment(.center)
        Text(book.authors.first ?? "Unknown Author").foregroundStyle(PlayerColor.secondary)
        Text("\(book.assets.count) file · \(duration(book.durationSeconds))")
          .font(.subheadline).foregroundStyle(PlayerColor.secondary)
        Button(action: play) { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
          .buttonStyle(.borderedProminent).controlSize(.large).tint(PlayerColor.accent)
          .accessibilityIdentifier("play-book")
        Spacer()
      }
      .padding(24)
    }
    .navigationTitle("Book Detail")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("book-detail-screen")
    .accessibilityValue("book:ready")
  }
}

private struct NowPlayingView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: PlayerModel
  let book: Book
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
          }
          Button {
            if model.playbackState.status == .playing { model.pause() }
            else { Task { await model.play(bookID: book.id) } }
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
      .accessibilityValue("player:\(model.playbackState.status.rawValue):0")
    }
    .task { await model.play(bookID: book.id) }
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
