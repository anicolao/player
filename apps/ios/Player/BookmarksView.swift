import SwiftUI

struct BookmarksView: View {
  @Bindable var model: PlayerModel
  let bookID: UUID

  @State private var query = ""
  @State private var sort: BookmarkSort = .positionAscending
  @State private var editingBookmark: Bookmark?
  @State private var lastJumpedBookmarkID: UUID?
  @State private var lastDeletedTransactionID: UUID?
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      searchField
      HStack {
        sortMenu
        Spacer()
        Text("\(results.count) \(results.count == 1 ? "bookmark" : "bookmarks")")
          .font(.caption)
          .foregroundStyle(PlayerColor.secondary)
      }

      if let transaction = undoableTransaction {
        undoBanner(transaction)
      }

      if results.isEmpty {
        ContentUnavailableView {
          Label(query.isEmpty ? "No Bookmarks Yet" : "No Matching Bookmarks", systemImage: "bookmark")
        } description: {
          Text(query.isEmpty ? "Add one from Now Playing." : "Try a label, note, or chapter title.")
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("bookmarks-empty")
      } else {
        LazyVStack(spacing: 10) {
          ForEach(results) { bookmark in
            bookmarkRow(bookmark)
          }
        }
      }

      StateProbe(id: "bookmarks-screen", value: screenValue)
      #if E2E
        StateProbe(
          id: "bookmark-search-focus-state",
          value: isSearchFocused ? "focused" : "unfocused"
        )
      #endif
    }
    .sheet(item: $editingBookmark) { bookmark in
      BookmarkEditorView(model: model, bookmark: bookmark)
    }
    #if E2E
      .overlay(alignment: .topTrailing) {
        if E2EBookmarkBridge.shared.isConfigured {
          E2EBookmarkStateProbe(model: model)
        }
      }
    #endif
  }

  private var searchField: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(PlayerColor.secondary)
      TextField("Search bookmarks", text: $query)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($isSearchFocused)
        .submitLabel(.done)
        .onSubmit { isSearchFocused = false }
        .accessibilityIdentifier("bookmark-search")
      if !query.isEmpty {
        Button {
          query = ""
          isSearchFocused = false
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .foregroundStyle(PlayerColor.secondary)
        .accessibilityLabel("Clear bookmark search")
        .accessibilityIdentifier("clear-bookmark-search")
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 44)
    .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 12))
  }

  private var sortMenu: some View {
    Menu {
      sortButton("Position, first to last", .positionAscending, "bookmark-sort-position-ascending")
      sortButton("Position, last to first", .positionDescending, "bookmark-sort-position-descending")
      sortButton("Newest first", .dateNewest, "bookmark-sort-date-newest")
      sortButton("Oldest first", .dateOldest, "bookmark-sort-date-oldest")
      sortButton("Label", .label, "bookmark-sort-label")
    } label: {
      Label(sortLabel, systemImage: "arrow.up.arrow.down")
    }
    .buttonStyle(.bordered)
    .accessibilityIdentifier("bookmark-sort")
    .accessibilityValue(sort.rawValue)
  }

  private func sortButton(_ title: String, _ value: BookmarkSort, _ id: String) -> some View {
    Button {
      sort = value
    } label: {
      if sort == value { Label(title, systemImage: "checkmark") }
      else { Text(title) }
    }
    .accessibilityIdentifier(id)
  }

  private func bookmarkRow(_ bookmark: Bookmark) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        Button {
          Task {
            if await model.jumpToBookmark(id: bookmark.id) {
              lastJumpedBookmarkID = bookmark.id
            }
          }
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(bookmark.label)
              .font(.headline)
              .foregroundStyle(PlayerColor.ink)
              .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
              Text(timecode(bookmark.bookPositionMilliseconds))
              if let chapter = bookmark.chapterTitleSnapshot {
                Text("·")
                Text(chapter).lineLimit(1)
              }
            }
            .font(.caption)
            .foregroundStyle(PlayerColor.secondary)
            if let note = bookmark.note {
              Text(note)
                .font(.subheadline)
                .foregroundStyle(PlayerColor.secondary)
                .multilineTextAlignment(.leading)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to \(bookmark.label)")
        .accessibilityIdentifier("jump-to-bookmark-\(token(bookmark.id))")

        Button {
          editingBookmark = bookmark
        } label: {
          Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Edit bookmark")
        .accessibilityIdentifier("edit-bookmark-\(token(bookmark.id))")

        Button(role: .destructive) {
          Task {
            lastDeletedTransactionID = await model.deleteBookmark(id: bookmark.id)
          }
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Delete bookmark")
        .accessibilityIdentifier("delete-bookmark-\(token(bookmark.id))")
      }

      if lastJumpedBookmarkID == bookmark.id {
        Label("Jumped to \(timecode(bookmark.bookPositionMilliseconds))", systemImage: "checkmark.circle.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(PlayerColor.accent)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Jumped to \(timecode(bookmark.bookPositionMilliseconds))")
          .accessibilityIdentifier("bookmark-jump-confirmation")
          .accessibilityValue(Text(verbatim: "bookmark=\(token(bookmark.id)):position=\(bookmark.bookPositionMilliseconds)"))
      }
    }
    .padding(14)
    .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bookmark-row-\(token(bookmark.id))")
    .accessibilityValue(Text(verbatim: rowValue(bookmark)))
  }

  private func undoBanner(_ transaction: BookmarkDeletionTransaction) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "trash")
        .foregroundStyle(PlayerColor.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text("Bookmark deleted").font(.headline)
        Text(transaction.bookmark.label)
          .font(.caption)
          .foregroundStyle(PlayerColor.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button("Undo") {
        Task {
          if await model.undoDeleteBookmark(transactionID: transaction.id) {
            lastDeletedTransactionID = nil
          }
        }
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("undo-delete-bookmark")
      .accessibilityValue(Text(verbatim: "transaction=\(token(transaction.id)):bookmark=\(token(transaction.bookmark.id))"))
    }
    .padding(12)
    .background(PlayerColor.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bookmark-delete-undo")
  }

  private var undoableTransaction: BookmarkDeletionTransaction? {
    if let lastDeletedTransactionID {
      return model.library.bookmarkDeletionTransactions.first {
        $0.id == lastDeletedTransactionID && $0.status == .deleted
      }
    }
    return model.library.bookmarkDeletionTransactions.last {
      $0.bookmark.bookID == bookID && $0.status == .deleted
    }
  }

  private var results: [Bookmark] {
    model.searchBookmarks(bookID: bookID, query: query, sort: sort)
  }

  private var screenValue: String {
    let order = results.map { token($0.id) }.joined(separator: ",")
    return "bookmarks:query=\(LibrarySearchIndex.normalize(query)):sort=\(sort.rawValue):count=\(results.count):order=\(order.isEmpty ? "none" : order)"
  }

  private var sortLabel: String {
    switch sort {
    case .positionAscending: "Position"
    case .positionDescending: "Reverse position"
    case .dateNewest: "Newest"
    case .dateOldest: "Oldest"
    case .label: "Label"
    }
  }

  private func rowValue(_ bookmark: Bookmark) -> String {
    [
      "book=\(token(bookmark.bookID))",
      "asset=\(token(bookmark.assetID))",
      "chapter=\(bookmark.chapterID ?? "none")",
      "bookMs=\(bookmark.bookPositionMilliseconds)",
      "assetMs=\(bookmark.assetPositionMilliseconds)",
      "label=\(bookmark.label)",
      "note=\(bookmark.note ?? "none")",
    ].joined(separator: "|")
  }

  private func timecode(_ milliseconds: Int64) -> String {
    BookmarkPlanner.timecode(positionMilliseconds: milliseconds)
  }

  private func token(_ id: UUID) -> String { id.uuidString.lowercased() }
}

private struct BookmarkEditorView: View {
  private enum FocusedField: String { case label, note }

  @Environment(\.dismiss) private var dismiss
  @Bindable var model: PlayerModel
  let bookmark: Bookmark
  @State private var label: String
  @State private var note: String
  @FocusState private var focusedField: FocusedField?

  init(model: PlayerModel, bookmark: Bookmark) {
    self.model = model
    self.bookmark = bookmark
    _label = State(initialValue: bookmark.label)
    _note = State(initialValue: bookmark.note ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Label") {
          HStack(spacing: 10) {
            TextField("Bookmark label", text: $label)
              .focused($focusedField, equals: .label)
              .accessibilityIdentifier("bookmark-label-editor")
            if !label.isEmpty {
              Button {
                label = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(PlayerColor.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Clear bookmark label")
              .accessibilityIdentifier("clear-bookmark-label")
            }
          }
        }
        Section {
          TextEditor(text: $note)
            .focused($focusedField, equals: .note)
            .frame(minHeight: 110)
            .accessibilityIdentifier("bookmark-note-editor")
        } header: {
          Text("Note")
        } footer: {
          Text("Leave the note empty to clear it.")
        }
      }
      .playerMiniPlayerScrollRunway()
      .navigationTitle("Edit Bookmark")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task {
              if await model.editBookmark(id: bookmark.id, label: label, note: note) {
                dismiss()
              }
            }
          }
          .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("save-bookmark")
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("bookmark-editor")
      .accessibilityValue(Text(verbatim: "bookmark=\(bookmark.id.uuidString.lowercased()):valid=\(!label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)"))
      #if E2E
        .overlay {
          ZStack {
            StateProbe(
              id: "bookmark-editor-focus-state",
              value: focusedField?.rawValue ?? "none"
            )
            StateProbe(id: "bookmark-label-editor-value", value: label)
            StateProbe(id: "bookmark-note-editor-value", value: note)
          }
        }
      #endif
    }
  }
}
