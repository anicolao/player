import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @State private var selection: AppSection = .library

  var body: some View {
    TabView(selection: $selection) {
      LibraryView()
        .tag(AppSection.library)
        .tabItem {
          Label("Library", systemImage: "books.vertical")
        }

      PlaceholderView(
        title: "Inbox",
        message: "New imports will wait here for review.",
        systemImage: "tray.full"
      )
      .tag(AppSection.inbox)
      .tabItem {
        Label("Inbox", systemImage: "tray.full")
      }

      PlaceholderView(
        title: "Settings",
        message: "Playback, storage, and import preferences will live here.",
        systemImage: "gearshape"
      )
      .tag(AppSection.settings)
      .tabItem {
        Label("Settings", systemImage: "gearshape")
      }
    }
    .tint(PlayerColor.accent)
  }
}

private enum AppSection: Hashable {
  case library
  case inbox
  case settings
}

private struct LibraryView: View {
  @State private var isImporting = false
  @State private var importNotice: String?

  var body: some View {
    NavigationStack {
      ZStack {
        PlayerColor.background
          .ignoresSafeArea()

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
            Text("Build your listening library")
              .font(.title2.bold())
              .foregroundStyle(PlayerColor.ink)

            Text("Import an M4B, M4A, MP3, or ZIP from Files.\nYour source files stay untouched.")
              .font(.body)
              .multilineTextAlignment(.center)
              .foregroundStyle(PlayerColor.secondary)
              .lineSpacing(3)
          }

          Button {
            isImporting = true
          } label: {
            Label("Add Audiobook", systemImage: "plus")
              .font(.headline)
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(PlayerColor.accent)
          .frame(maxWidth: 280)
          .accessibilityIdentifier("add-audiobook")

          if let importNotice {
            Text(importNotice)
              .font(.footnote)
              .foregroundStyle(PlayerColor.secondary)
              .accessibilityIdentifier("import-notice")
          }

          Spacer()
          Spacer()
        }
        .padding(24)
      }
      .navigationTitle("Library")
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("library-screen")
      .accessibilityValue("ready:library-empty")
      .fileImporter(
        isPresented: $isImporting,
        allowedContentTypes: importTypes,
        allowsMultipleSelection: true
      ) { result in
        switch result {
        case .success(let urls):
          importNotice = urls.count == 1
            ? "1 item selected for the future import inbox."
            : "\(urls.count) items selected for the future import inbox."
        case .failure:
          importNotice = "Nothing was imported."
        }
      }
    }
  }

  private var importTypes: [UTType] {
    let audiobookTypes = ["m4b", "m4a", "mp3"].compactMap {
      UTType(filenameExtension: $0)
    }
    return audiobookTypes + [.zip]
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

private enum PlayerColor {
  static let background = Color(red: 0.965, green: 0.949, blue: 0.918)
  static let card = Color(red: 1.000, green: 0.992, blue: 0.973)
  static let ink = Color(red: 0.118, green: 0.137, blue: 0.153)
  static let secondary = Color(red: 0.350, green: 0.372, blue: 0.384)
  static let accent = Color(red: 0.690, green: 0.267, blue: 0.165)
}
