import SwiftUI

struct LibrarySearchView: View {
  @Bindable var model: PlayerModel
  @State private var query = ""
  @State private var index = LibrarySearchIndex.empty
  @State private var isIndexed = false
  @State private var pendingPreferences: LibrarySearchPreferences?
  @State private var preferenceUpdateTask: Task<Void, Never>?
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      VStack(spacing: 0) {
        searchField
        controls
        resultContent
      }
      .e2eLayoutReadiness(
        id: "library-search-layout-readiness",
        containerID: "library-search-layout"
      )
      StateProbe(id: "library-search-screen", value: isIndexed ? "ready" : "indexing")
      StateProbe(id: "library-search-probe", value: probeValue)
      #if E2E
        StateProbe(id: "library-search-results-probe", value: resultProbeValue)
        LibraryArtworkStateProbe(model: model, id: "library-search-artwork-probe")
        StateProbe(
          id: "library-search-focus-state",
          value: isSearchFocused ? "focused" : "unfocused"
        )
      #endif
    }
    .navigationTitle("Search")
    .task(id: searchRevision) {
      isIndexed = false
      let snapshot = model.library
      let requestedRevision = LibrarySearchRevision(library: snapshot)
      guard let build = await LibrarySearchIndexBuilder.shared.buildLatest(
        library: snapshot,
        revision: requestedRevision
      ), !Task.isCancelled, build.revision == searchRevision else { return }
      index = build.index
      isIndexed = true
    }
  }

  private var searchField: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass").foregroundStyle(PlayerColor.secondary)
      TextField("Search your library", text: $query)
        .focused($isSearchFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.search)
        .onSubmit { isSearchFocused = false }
        .accessibilityIdentifier("library-search-input")
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .foregroundStyle(PlayerColor.secondary)
        .accessibilityLabel("Clear search query")
        .accessibilityIdentifier("clear-search-query")
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 48)
    .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 14))
    .padding(.horizontal, 20)
    .padding(.top, 12)
  }

  private var controls: some View {
    VStack(spacing: 10) {
      HStack(spacing: 12) {
        sortMenu
        filterMenu
        if preferences != .default || !query.isEmpty {
          Button("Clear All") {
            query = ""
            persistPreferences(.default)
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("clear-library-search")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(summary)
        .font(.caption)
        .foregroundStyle(PlayerColor.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("library-search-summary")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private var sortMenu: some View {
    Menu {
      searchSortButton("Title", value: .title, id: "search-sort-title")
      searchSortButton("Author", value: .author, id: "search-sort-author")
      searchSortButton("Series order", value: .series, id: "search-sort-series")
      searchSortButton("Recently added", value: .recentlyAdded, id: "search-sort-recently-added")
      searchSortButton("Duration", value: .duration, id: "search-sort-duration")
      searchSortButton("Progress", value: .progress, id: "search-sort-progress")
      Divider()
      Button(preferences.direction == .ascending ? "Descending" : "Ascending") {
        updatePreferences {
          $0.direction = $0.direction == .ascending ? .descending : .ascending
        }
      }
      .accessibilityIdentifier("search-sort-direction")
    } label: {
      Label("Sort", systemImage: "arrow.up.arrow.down")
    }
    .buttonStyle(.bordered)
    .accessibilityIdentifier("search-sort")
  }

  private var filterMenu: some View {
    Menu {
      statusButton("Any listening state", status: nil, id: "search-filter-any-status")
      statusButton("Unplayed", status: .unplayed, id: "search-filter-unplayed")
      statusButton("In progress", status: .inProgress, id: "search-filter-in-progress")
      statusButton("Finished", status: .finished, id: "search-filter-finished")
      Divider()
      Button {
        updatePreferences { preferences in
          if preferences.formats.contains("M4B") {
            preferences.formats.remove("M4B")
          } else {
            preferences.formats.insert("M4B")
          }
        }
      } label: {
        if preferences.formats.contains("M4B") { Label("M4B", systemImage: "checkmark") }
        else { Text("M4B") }
      }
      .accessibilityIdentifier("search-filter-m4b")
      Button {
        updatePreferences { $0.missingMetadataOnly.toggle() }
      } label: {
        if preferences.missingMetadataOnly { Label("Missing metadata", systemImage: "checkmark") }
        else { Text("Missing metadata") }
      }
      .accessibilityIdentifier("search-filter-missing-metadata")
    } label: {
      Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
    }
    .buttonStyle(.bordered)
    .accessibilityIdentifier("search-filter")
  }

  @ViewBuilder
  private var resultContent: some View {
    if !isIndexed {
      Spacer()
      ProgressView("Indexing library…")
      Spacer()
    } else if result.books.isEmpty {
      Spacer()
      ContentUnavailableView {
        Label(emptyTitle, systemImage: "magnifyingglass")
      } description: {
        Text(emptyDescription)
      } actions: {
        Button("Clear Search and Filters") {
          query = ""
          persistPreferences(.default)
        }
        .buttonStyle(.borderedProminent)
        .tint(PlayerColor.accent)
        .accessibilityIdentifier("empty-search-clear-all")
      }
      .accessibilityIdentifier("library-search-empty")
      Spacer()
    } else {
      ScrollView {
        LazyVStack(spacing: 14) {
          ForEach(result.books) { book in
            NavigationLink {
              BookDetailView(model: model, bookID: book.id) { selectedBook, position in
                Task { await model.play(bookID: selectedBook.id, at: position) }
              }
            } label: {
              BookRow(book: book)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(book.title), \(book.authors.first ?? "Unknown Author")")
            .accessibilityHint("Opens audiobook details")
            .accessibilityIdentifier("search-result-\(book.id.uuidString.lowercased())")
          }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
      }
      .playerMiniPlayerScrollRunway()
      .accessibilityIdentifier("library-search-results-scroll")
      .e2eScrollReadiness(
        id: "library-search-results-scroll-readiness",
        containerID: "library-search-results-scroll",
        axis: .vertical
      )
    }
  }

  private var preferences: LibrarySearchPreferences {
    pendingPreferences ?? model.library.searchPreferences
  }

  private var result: LibrarySearchResult {
    index.search(query: query, preferences: preferences)
  }

  private var searchRevision: LibrarySearchRevision {
    LibrarySearchRevision(library: model.library)
  }

  private var summary: String {
    (["\(result.books.count) \(result.books.count == 1 ? "book" : "books")"]
      + preferences.summaryTokens).joined(separator: " · ")
  }

  private var emptyTitle: String {
    result.normalizedQuery.isEmpty ? "No books match these filters" : "No search matches"
  }

  private var emptyDescription: String {
    result.normalizedQuery.isEmpty
      ? "Clear the active filters to see the rest of your library."
      : "Try another title, contributor, series, chapter, filename, or collection."
  }

  private var probeValue: String {
    "search:revision=\(searchRevision.value):indexed=\(isIndexed):\(resultProbeValue)"
  }

  private var resultProbeValue: String {
    let order = result.books.map { $0.id.uuidString.lowercased() }.joined(separator: ",")
    let status = preferences.status?.rawValue ?? "any"
    let formats = preferences.formats.sorted().joined(separator: ",")
    let empty: String
    if !result.books.isEmpty { empty = "none" }
    else if result.normalizedQuery.isEmpty { empty = "filters" }
    else { empty = "query" }
    return "query=\(result.normalizedQuery):count=\(result.books.count):sort=\(preferences.sort.rawValue):direction=\(preferences.direction.rawValue):status=\(status):formats=\(formats.isEmpty ? "any" : formats):missing=\(preferences.missingMetadataOnly):empty=\(empty):order=\(order.isEmpty ? "none" : order)"
  }

  private func searchSortButton(_ title: String, value: LibrarySearchSort, id: String) -> some View {
    Button {
      updatePreferences { $0.sort = value }
    } label: {
      if preferences.sort == value { Label(title, systemImage: "checkmark") }
      else { Text(title) }
    }
    .accessibilityIdentifier(id)
  }

  private func statusButton(
    _ title: String,
    status: BookListeningStatus?,
    id: String
  ) -> some View {
    Button {
      updatePreferences { $0.status = status }
    } label: {
      if preferences.status == status { Label(title, systemImage: "checkmark") }
      else { Text(title) }
    }
    .accessibilityIdentifier(id)
  }

  private func updatePreferences(_ change: @escaping (inout LibrarySearchPreferences) -> Void) {
    var updated = preferences
    change(&updated)
    persistPreferences(updated)
  }

  private func persistPreferences(_ updated: LibrarySearchPreferences) {
    pendingPreferences = updated
    let precedingUpdate = preferenceUpdateTask
    preferenceUpdateTask = Task {
      _ = await precedingUpdate?.value
      _ = await model.setLibrarySearchPreferences(updated)
      if pendingPreferences == updated {
        pendingPreferences = nil
      }
    }
  }
}
