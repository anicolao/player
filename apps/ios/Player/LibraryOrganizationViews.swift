import SwiftUI

struct LibraryOrganizationHome: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: PlayerModel
  let resume: (Book) -> Void
  @State private var showUpNext = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        if !model.library.continueListeningBooks.isEmpty { continueListening }
        if !model.library.upNextBooks.isEmpty { upNext }
        recentlyAdded
        browse
      }
      .padding(.horizontal, 20)
      .padding(.top, 18)
      .padding(
        .bottom,
        model.library.currentBookID == nil
          ? 18
          : 18 + PlayerLayout.miniPlayerScrollRunway
      )
    }
    .accessibilityIdentifier("library-root-scroll")
    .navigationDestination(isPresented: $showUpNext) { UpNextView(model: model) }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink {
          LibrarySearchView(model: model)
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel("Search Library")
        .accessibilityIdentifier("open-library-search")
      }
    }
    LibraryOrganizerStateProbe(model: model)
  }

  private var continueListening: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionTitle("Continue Listening")
      if dynamicTypeSize.isAccessibilitySize {
        LazyVStack(spacing: 14) {
          ForEach(model.library.continueListeningBooks) { book in
            continueListeningCard(book, stacksVertically: true)
          }
        }
      } else {
        ScrollView(.horizontal) {
          LazyHStack(spacing: 14) {
            ForEach(model.library.continueListeningBooks) { book in
              continueListeningCard(book, stacksVertically: false)
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
  }

  @ViewBuilder
  private func continueListeningCard(_ book: Book, stacksVertically: Bool) -> some View {
    Button { resume(book) } label: {
      Group {
        if stacksVertically {
          VStack(alignment: .leading, spacing: 12) {
            ArtworkView(data: book.artworkData, size: 92)
            continueListeningDetails(book, fixedWidth: false)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          HStack(spacing: 14) {
            ArtworkView(data: book.artworkData, size: 92)
            continueListeningDetails(book, fixedWidth: true)
          }
        }
      }
      .padding(14)
      .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 18))
      .playerAccessibleCard(cornerRadius: 18)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Resume \(book.title)")
    .accessibilityValue("\(Int(progress(book) * 100)) percent complete, \(remaining(book)) remaining")
    .accessibilityHint("Starts playback from the saved position")
    .accessibilityIdentifier("resume-book-\(book.id.uuidString.lowercased())")
  }

  private func continueListeningDetails(_ book: Book, fixedWidth: Bool) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(book.title).font(.headline).foregroundStyle(PlayerColor.ink).lineLimit(2)
      Text(book.authors.first ?? "Unknown Author")
        .font(.subheadline).foregroundStyle(PlayerColor.secondary).lineLimit(2)
      ProgressView(value: progress(book)).tint(PlayerColor.accent)
      Text("\(Int(progress(book) * 100))% · \(remaining(book)) left")
        .font(.caption).foregroundStyle(PlayerColor.secondary)
    }
    .frame(width: fixedWidth ? 190 : nil, alignment: .leading)
  }

  private var upNext: some View {
    Button {
      showUpNext = true
    } label: {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          sectionTitle("Up Next")
          Spacer()
          Text("\(model.library.upNextBooks.count)").foregroundStyle(PlayerColor.secondary)
          Image(systemName: "chevron.right").font(.caption.bold())
        }

        VStack(spacing: 0) {
          ForEach(model.library.upNextBooks.prefix(3)) { book in
            CompactBookRow(book: book)
            if book.id != model.library.upNextBooks.prefix(3).last?.id { Divider() }
          }
        }
        .padding(.horizontal, 14)
        .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 18))
      }
    }
    .buttonStyle(.plain)
    .foregroundStyle(PlayerColor.ink)
    .accessibilityIdentifier("open-up-next")
  }

  private var recentlyAdded: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionTitle("Recently Added")
      LazyVGrid(columns: recentColumns, spacing: 18) {
        ForEach(model.library.recentlyAddedBooks.prefix(4)) { book in
          NavigationLink(value: book.id) {
            LibraryCoverCard(book: book)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("recent-book-\(book.id.uuidString.lowercased())")
        }
      }
    }
  }

  private var recentColumns: [GridItem] {
    Array(
      repeating: GridItem(.flexible()),
      count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
    )
  }

  private var browse: some View {
    VStack(alignment: .leading, spacing: 12) {
      sectionTitle("Browse")
      VStack(spacing: 0) {
        browseLink("All Books", icon: "books.vertical", id: "browse-all-books") {
          AllBooksView(model: model)
        }
        Divider()
        browseLink("Series", icon: "square.stack.3d.up", id: "browse-series") {
          LibraryFacetBrowser(model: model, facet: .series)
        }
        Divider()
        browseLink("Authors", icon: "person.2", id: "browse-authors") {
          LibraryFacetBrowser(model: model, facet: .authors)
        }
        Divider()
        browseLink("Narrators", icon: "waveform.and.mic", id: "browse-narrators") {
          LibraryFacetBrowser(model: model, facet: .narrators)
        }
        Divider()
        browseLink("Collections", icon: "rectangle.stack", id: "browse-collections") {
          CollectionsView(model: model)
        }
        Divider()
        browseLink("Trash", icon: "trash", id: "open-trash") {
          LibraryTrashView(model: model)
        }
      }
      .padding(.horizontal, 16)
      .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 18))
    }
  }

  private func browseLink<Destination: View>(
    _ title: String,
    icon: String,
    id: String,
    @ViewBuilder destination: () -> Destination
  ) -> some View {
    NavigationLink(destination: destination) {
      HStack(spacing: 14) {
        Image(systemName: icon).foregroundStyle(PlayerColor.accent).frame(width: 28)
        Text(title).font(.headline).foregroundStyle(PlayerColor.ink)
        Spacer()
        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(PlayerColor.secondary)
      }
      .padding(.vertical, 15)
    }
    .accessibilityIdentifier(id)
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(.title3.bold()).foregroundStyle(PlayerColor.ink)
  }

  private func progress(_ book: Book) -> Double {
    guard book.durationSeconds > 0 else { return 0 }
    return min(max(book.listeningState.positionSeconds / book.durationSeconds, 0), 1)
  }

  private func remaining(_ book: Book) -> String {
    organizationDuration(max(book.durationSeconds - book.listeningState.positionSeconds, 0))
  }

}

struct UpNextView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: PlayerModel

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      List {
        ForEach(Array(model.library.upNextBooks.enumerated()), id: \.element.id) { index, book in
          Group {
            if dynamicTypeSize.isAccessibilitySize {
              VStack(alignment: .leading, spacing: 12) {
                upNextBookLink(book, index: index)
                HStack(spacing: 12) {
                  moveButton(book, index: index, offset: -1)
                  moveButton(book, index: index, offset: 1)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
              }
            } else {
              HStack(spacing: 10) {
                upNextBookLink(book, index: index)
                Spacer()
                moveButton(book, index: index, offset: -1)
                moveButton(book, index: index, offset: 1)
              }
            }
          }
          .listRowBackground(PlayerColor.card)
        }
      }
      .scrollContentBackground(.hidden)
      StateProbe(id: "up-next-probe", value: upNextValue)
      StateProbe(id: "up-next-screen", value: "ready")
    }
    .navigationTitle("Up Next")
  }

  private var upNextValue: String {
    let order = model.library.upNextBookIDs.map { $0.uuidString.lowercased() }.joined(separator: ",")
    return "up-next:count=\(model.library.upNextBookIDs.count):order=\(order)"
  }

  private func upNextBookLink(_ book: Book, index: Int) -> some View {
    NavigationLink {
      BookDetailView(model: model, bookID: book.id) { selectedBook, position in
        Task { await model.play(bookID: selectedBook.id, at: position) }
      }
    } label: {
      HStack(spacing: 12) {
        Text("\(index + 1)").font(.caption.bold()).foregroundStyle(PlayerColor.accent)
        ArtworkView(data: book.artworkData, size: 58)
        VStack(alignment: .leading) {
          Text(book.title).font(.headline).foregroundStyle(PlayerColor.ink)
          Text(book.authors.first ?? "Unknown Author")
            .font(.caption)
            .foregroundStyle(PlayerColor.secondary)
        }
      }
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("up-next-book-\(book.id.uuidString.lowercased())")
  }

  private func moveButton(_ book: Book, index: Int, offset: Int) -> some View {
    let isEarlier = offset < 0
    return Button {
      move(bookID: book.id, offset: offset)
    } label: {
      if dynamicTypeSize.isAccessibilitySize {
        Label(isEarlier ? "Earlier" : "Later", systemImage: isEarlier ? "arrow.up" : "arrow.down")
      } else {
        Image(systemName: isEarlier ? "arrow.up" : "arrow.down")
      }
    }
    .buttonStyle(.borderless)
    .disabled(isEarlier ? index == 0 : index == model.library.upNextBooks.count - 1)
    .accessibilityLabel("Move \(book.title) \(isEarlier ? "earlier" : "later")")
    .accessibilityHint(
      isEarlier
        ? "Moves this audiobook one position toward the start of Up Next"
        : "Moves this audiobook one position toward the end of Up Next"
    )
    .accessibilityIdentifier(
      "up-next-move-\(isEarlier ? "up" : "down")-\(book.id.uuidString.lowercased())"
    )
  }

  private func move(bookID: UUID, offset: Int) {
    var ids = model.library.upNextBookIDs
    guard let index = ids.firstIndex(of: bookID), ids.indices.contains(index + offset) else { return }
    ids.swapAt(index, index + offset)
    Task { _ = await model.reorderUpNext(bookIDs: ids) }
  }
}

struct AllBooksView: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: PlayerModel

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      ScrollView {
        if model.library.allBooksViewStyle == .grid {
          LazyVGrid(columns: gridColumns, spacing: 20) {
            ForEach(sortedBooks) { book in bookLink(book) { LibraryCoverCard(book: book) } }
          }
          .padding(20)
        } else {
          LazyVStack(spacing: 14) {
            ForEach(sortedBooks) { book in bookLink(book) { BookRow(book: book) } }
          }
          .padding(20)
        }
      }
      StateProbe(id: "all-books-probe", value: allBooksValue)
      StateProbe(id: "all-books-screen", value: "ready")
      LibraryOrganizerStateProbe(model: model)
    }
    .navigationTitle("All Books")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          let next: LibraryViewStyle = model.library.allBooksViewStyle == .grid ? .list : .grid
          Task { _ = await model.setAllBooksViewStyle(next) }
        } label: {
          Image(systemName: model.library.allBooksViewStyle == .grid ? "list.bullet" : "square.grid.2x2")
        }
        .accessibilityLabel(model.library.allBooksViewStyle == .grid ? "Use list" : "Use grid")
        .accessibilityIdentifier(model.library.allBooksViewStyle == .grid ? "library-view-list" : "library-view-grid")
      }
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink {
          LibraryTrashView(model: model)
        } label: { Image(systemName: "trash") }
          .accessibilityLabel("Open Trash")
          .accessibilityIdentifier("open-trash")
      }
    }
  }

  private var sortedBooks: [Book] {
    model.library.books.sorted {
      let lhs = $0.metadata.sortTitle ?? $0.title
      let rhs = $1.metadata.sortTitle ?? $1.title
      if lhs != rhs { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  private var gridColumns: [GridItem] {
    Array(
      repeating: GridItem(.flexible()),
      count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
    )
  }

  private func bookLink<Label: View>(_ book: Book, @ViewBuilder label: () -> Label) -> some View {
    NavigationLink {
      BookDetailView(model: model, bookID: book.id) { selectedBook, position in
        Task { await model.play(bookID: selectedBook.id, at: position) }
      }
    } label: {
      label()
    }
      .buttonStyle(.plain)
      .accessibilityIdentifier("all-books-book-\(book.id.uuidString.lowercased())")
  }

  private var allBooksValue: String {
    let order = sortedBooks.map { $0.id.uuidString.lowercased() }.joined(separator: ",")
    return "all-books:count=\(sortedBooks.count):view=\(model.library.allBooksViewStyle.rawValue):order=\(order)"
  }
}

struct LibraryFacetBrowser: View {
  @Bindable var model: PlayerModel
  let facet: LibraryBrowseFacet

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      List(groups) { group in
        NavigationLink {
          LibraryBrowseGroupView(model: model, group: group)
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(group.displayName).font(.headline)
              Text("\(group.bookIDs.count) \(group.bookIDs.count == 1 ? "book" : "books")")
                .font(.caption).foregroundStyle(PlayerColor.secondary)
            }
            Spacer()
          }
        }
        .listRowBackground(PlayerColor.card)
        .accessibilityIdentifier("\(rowPrefix)-\(group.id.lowercased())")
      }
      .scrollContentBackground(.hidden)
      StateProbe(id: "\(facet.rawValue)-browser-probe", value: probeValue)
      StateProbe(id: "\(facet.rawValue)-browser-screen", value: "ready")
    }
    .navigationTitle(title)
  }

  private var groups: [LibraryBrowseGroup] { model.library.browseGroups(for: facet) }

  private var title: String {
    switch facet { case .series: "Series"; case .authors: "Authors"; case .narrators: "Narrators" }
  }

  private var probeValue: String {
    let books = groups.reduce(0) { $0 + $1.bookIDs.count }
    let order = groups.map { $0.id.lowercased() }.joined(separator: ",")
    return "browse:\(facet.rawValue):groups=\(groups.count):books=\(books):order=\(order)"
  }

  private var rowPrefix: String {
    switch facet { case .series: "series"; case .authors: "author"; case .narrators: "narrator" }
  }
}

private struct LibraryBrowseGroupView: View {
  @Bindable var model: PlayerModel
  let group: LibraryBrowseGroup

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      ScrollView {
        LazyVStack(spacing: 14) {
          ForEach(books) { book in
            NavigationLink(value: book.id) { BookRow(book: book) }.buttonStyle(.plain)
          }
        }
        .padding(20)
      }
    }
    .navigationTitle(group.displayName)
  }

  private var books: [Book] {
    let byID = Dictionary(uniqueKeysWithValues: model.library.books.map { ($0.id, $0) })
    return group.bookIDs.compactMap { byID[$0] }
  }
}

struct CollectionsView: View {
  @Bindable var model: PlayerModel
  @State private var isCreating = false
  @State private var name = ""
  @State private var createdCollectionID: UUID?
  @State private var showCreatedCollection = false

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      List {
        if isCreating {
          VStack(alignment: .leading, spacing: 12) {
            TextField("Collection name", text: $name)
              .textInputAutocapitalization(.words)
              .accessibilityIdentifier("collection-name-input")
            Button("Save Collection") {
              Task {
                if let id = await model.createCollection(name: name) {
                  createdCollectionID = id
                  name = ""
                  isCreating = false
                  showCreatedCollection = true
                }
              }
            }
            .buttonStyle(.borderedProminent)
            .tint(PlayerColor.accent)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("save-collection")
          }
          .listRowBackground(PlayerColor.card)
        }
        ForEach(model.library.collections) { collection in
          NavigationLink {
            CollectionDetailView(model: model, collectionID: collection.id)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(collection.name).font(.headline)
              Text("\(collection.orderedBookIDs.count) books")
                .font(.caption).foregroundStyle(PlayerColor.secondary)
            }
          }
          .listRowBackground(PlayerColor.card)
          .accessibilityIdentifier("collection-\(collection.id.uuidString.lowercased())")
        }
      }
      .scrollContentBackground(.hidden)
    }
    .navigationTitle("Collections")
    .toolbar {
      Button { isCreating = true } label: { Image(systemName: "plus") }
        .accessibilityLabel("Create Collection")
        .accessibilityIdentifier("create-collection")
    }
    .accessibilityIdentifier("collections-screen")
    .navigationDestination(isPresented: $showCreatedCollection) {
      if let createdCollectionID {
        CollectionDetailView(model: model, collectionID: createdCollectionID)
      }
    }
  }
}

struct CollectionDetailView: View {
  @Bindable var model: PlayerModel
  let collectionID: UUID

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      if let collection {
        List {
          ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
            HStack(spacing: 12) {
              ArtworkView(data: book.artworkData, size: 58)
              Text(book.title).font(.headline)
              Spacer()
              Button { move(book.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                .disabled(index == 0)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("collection-move-up-\(book.id.uuidString.lowercased())")
            }
            .accessibilityElement(children: .contain)
            .listRowBackground(PlayerColor.card)
            .accessibilityIdentifier("collection-book-\(book.id.uuidString.lowercased())")
          }
        }
        .scrollContentBackground(.hidden)
        StateProbe(id: "collection-probe", value: collectionValue(collection))
      }
    }
    .navigationTitle(collection?.name ?? "Collection")
    .toolbar {
      NavigationLink {
        CollectionBookPicker(model: model, collectionID: collectionID)
      } label: { Image(systemName: "plus") }
        .accessibilityLabel("Add Books")
        .accessibilityIdentifier("add-collection-books")
    }
  }

  private var collection: BookCollection? {
    model.library.collections.first { $0.id == collectionID }
  }

  private var books: [Book] {
    guard let collection else { return [] }
    let byID = Dictionary(uniqueKeysWithValues: model.library.books.map { ($0.id, $0) })
    return collection.orderedBookIDs.compactMap { byID[$0] }
  }

  private func move(_ id: UUID, offset: Int) {
    guard let collection else { return }
    var ids = collection.orderedBookIDs
    guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
    ids.swapAt(index, index + offset)
    Task { _ = await model.reorderCollection(collectionID, bookIDs: ids) }
  }

  private func collectionValue(_ collection: BookCollection) -> String {
    let order = collection.orderedBookIDs.map { $0.uuidString.lowercased() }.joined(separator: ",")
    return "collection:\(collection.id.uuidString.lowercased()):name=\(collection.name):count=\(collection.orderedBookIDs.count):order=\(order)"
  }
}

private struct CollectionBookPicker: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: PlayerModel
  let collectionID: UUID
  @State private var selected: Set<UUID> = []

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      List(model.library.books) { book in
        Button {
          if selected.contains(book.id) { selected.remove(book.id) } else { selected.insert(book.id) }
        } label: {
          HStack {
            CompactBookRow(book: book)
            Spacer()
            if selected.contains(book.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(PlayerColor.accent) }
          }
        }
        .buttonStyle(.plain)
        .listRowBackground(PlayerColor.card)
        .accessibilityIdentifier("collection-select-book-\(book.id.uuidString.lowercased())")
      }
      .scrollContentBackground(.hidden)
    }
    .navigationTitle("Add Books")
    .toolbar {
      Button("Save") {
        Task {
          for id in model.library.books.map(\.id).filter(selected.contains) {
            _ = await model.addBook(id, toCollection: collectionID)
          }
          dismiss()
        }
      }
      .disabled(selected.isEmpty)
      .accessibilityIdentifier("save-collection-books")
    }
  }
}

struct LibraryTrashView: View {
  @Bindable var model: PlayerModel
  @State private var pendingDeletion: LibraryTrashTransaction?

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      if recoverable.isEmpty {
        ContentUnavailableView("Trash is empty", systemImage: "trash", description: Text("Removed books can be restored here."))
      } else {
        List(recoverable) { transaction in
          HStack(spacing: 12) {
            ArtworkView(data: transaction.book.artworkData, size: 58)
            VStack(alignment: .leading, spacing: 4) {
              Text(transaction.book.title).font(.headline)
              Text(ByteCountFormatter.string(fromByteCount: transactionBytes(transaction), countStyle: .file))
                .font(.caption).foregroundStyle(PlayerColor.secondary)
            }
            Spacer()
            Button("Restore") {
              Task { _ = await model.restoreTrashedBook(transactionID: transaction.id) }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("restore-trash-\(transaction.id.uuidString.lowercased())")
            Button(role: .destructive) { pendingDeletion = transaction } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Delete Forever")
            .accessibilityIdentifier("delete-trash-\(transaction.id.uuidString.lowercased())")
          }
          .accessibilityElement(children: .contain)
          .listRowBackground(PlayerColor.card)
          .accessibilityIdentifier("trash-book-\(transaction.book.id.uuidString.lowercased())")
        }
        .scrollContentBackground(.hidden)
      }
      StateProbe(id: "trash-probe", value: trashValue)
      StateProbe(id: "trash-screen", value: "ready")
    }
    .navigationTitle("Trash")
    .confirmationDialog(
      "Delete this audiobook forever?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Forever", role: .destructive) {
        guard let transaction = pendingDeletion else { return }
        pendingDeletion = nil
        Task {
          _ = await model.clearRecoverableStorage(scope: .trashTransaction(transaction.id))
        }
      }
      .accessibilityIdentifier("confirm-delete-trash")
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text("This permanently deletes the app-managed audio in Trash. Your original source files are never changed.")
    }
  }

  private var recoverable: [LibraryTrashTransaction] {
    model.library.trashTransactions.filter { $0.status == .recoverable }
  }

  private func transactionBytes(_ transaction: LibraryTrashTransaction) -> Int64 {
    transaction.mediaManifest?.byteCount ?? transaction.book.assets.reduce(0) { $0 + $1.byteCount }
  }

  private var trashValue: String {
    let books = recoverable.map { $0.book.id.uuidString.lowercased() }.joined(separator: ",")
    let assets = recoverable.reduce(0) { $0 + $1.book.assets.count }
    let bytes = recoverable.reduce(Int64(0)) { $0 + transactionBytes($1) }
    #if E2E
      let checksumPreserved = E2ELibraryOrganizationBridge.shared.managedChecksumPreserved
    #else
      let checksumPreserved = true
    #endif
    return "trash:transactions=\(recoverable.count):books=\(books.isEmpty ? "none" : books):assets=\(assets):bytes=\(bytes):restorable=\(!recoverable.isEmpty):managed-checksum-preserved=\(checksumPreserved)"
  }
}

private enum LibrarySettingsDestination: Hashable {
  case trash
  case storage
  case backup
  case playbackDefaults
  case smartRewind
  case accessibility
  case diagnostics
}

struct LibraryOrganizationSettingsView: View {
  @Bindable var model: PlayerModel
  @State private var path: [LibrarySettingsDestination] = []

  init(model: PlayerModel) {
    self.model = model
    #if E2E
      let arguments = ProcessInfo.processInfo.arguments
      if let option = arguments.firstIndex(of: "-e2e-start-settings-route"),
        arguments.indices.contains(option + 1)
      {
        switch arguments[option + 1] {
        case "backup": _path = State(initialValue: [.backup])
        case "diagnostics": _path = State(initialValue: [.diagnostics])
        default: break
        }
      }
    #endif
  }

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Section("Library") {
          Picker("All Books layout", selection: Binding(
            get: { model.library.allBooksViewStyle },
            set: { style in Task { _ = await model.setAllBooksViewStyle(style) } }
          )) {
            Text("Grid").tag(LibraryViewStyle.grid)
            Text("List").tag(LibraryViewStyle.list)
          }
          NavigationLink(value: LibrarySettingsDestination.trash) {
            Label("Trash", systemImage: "trash")
          }
          NavigationLink(value: LibrarySettingsDestination.storage) {
            Label("Storage", systemImage: "internaldrive")
          }
          .accessibilityIdentifier("settings-storage")
          NavigationLink(value: LibrarySettingsDestination.backup) {
            Label("Backup", systemImage: "externaldrive.badge.timemachine")
          }
          .accessibilityIdentifier("settings-backup")
        }
        Section("Playback") {
          NavigationLink(value: LibrarySettingsDestination.playbackDefaults) {
            Label("Playback defaults", systemImage: "gauge.with.dots.needle.50percent")
          }
          .accessibilityIdentifier("playback-defaults")
          NavigationLink(value: LibrarySettingsDestination.smartRewind) {
            Label("Smart Rewind", systemImage: "gobackward")
          }
          .accessibilityIdentifier("smart-rewind-settings")
        }
        Section("Accessibility") {
          NavigationLink(value: LibrarySettingsDestination.accessibility) {
            Label("Accessibility", systemImage: "accessibility")
          }
          .accessibilityIdentifier("settings-accessibility")
        }
        Section("Privacy & Support") {
          NavigationLink(value: LibrarySettingsDestination.diagnostics) {
            Label("Offline & Support", systemImage: "checkmark.shield")
          }
          .accessibilityIdentifier("settings-diagnostics")
        }
      }
      .scrollContentBackground(.hidden)
      .background(PlayerColor.background)
      .navigationTitle("Settings")
      .navigationDestination(for: LibrarySettingsDestination.self) { destination in
        switch destination {
        case .trash: LibraryTrashView(model: model)
        case .storage: StorageSettingsView(model: model)
        case .backup: BackupSettingsView(model: model)
        case .playbackDefaults: TransportPreferencesEditor(model: model)
        case .smartRewind: SmartRewindSettingsView(model: model)
        case .accessibility: AccessibilitySettingsView(model: model)
        case .diagnostics: SupportDiagnosticsView(model: model)
        }
      }
    }
  }
}

private struct LibraryCoverCard: View {
  let book: Book
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ArtworkView(data: book.artworkData, size: 154)
      Text(book.title).font(.headline).foregroundStyle(PlayerColor.ink).lineLimit(2)
      Text(book.authors.first ?? "Unknown Author")
        .font(.caption).foregroundStyle(PlayerColor.secondary).lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CompactBookRow: View {
  let book: Book
  var body: some View {
    HStack(spacing: 12) {
      ArtworkView(data: book.artworkData, size: 54)
      VStack(alignment: .leading, spacing: 4) {
        Text(book.title).font(.headline).foregroundStyle(PlayerColor.ink).lineLimit(1)
        Text(book.authors.first ?? "Unknown Author")
          .font(.caption).foregroundStyle(PlayerColor.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
  }
}

struct StateProbe: View {
  let id: String
  let value: String
  var body: some View {
    Color.clear
      .frame(width: 1, height: 1)
      .id(value)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(id)
      .accessibilityIdentifier(id)
      .accessibilityValue(value)
  }
}

struct LibraryOrganizerStateProbe: View {
  @Bindable var model: PlayerModel

  var body: some View {
    let continued = model.library.continueListeningBooks
      .map { $0.id.uuidString.lowercased() }.joined(separator: ",")
    let upNext = model.library.upNextBookIDs
      .map { $0.uuidString.lowercased() }.joined(separator: ",")
    let finished = model.library.books.filter { $0.listeningState.status == .finished }
      .sorted {
        let lhs = $0.listeningState.finishedAt ?? .distantPast
        let rhs = $1.listeningState.finishedAt ?? .distantPast
        if lhs != rhs { return lhs > rhs }
        return $0.id.uuidString < $1.id.uuidString
      }
      .map { $0.id.uuidString.lowercased() }.joined(separator: ",")
    let current = model.library.currentBookID?.uuidString.lowercased() ?? "none"
    let position = model.library.playbackPosition?.positionMilliseconds ?? 0
    let trash = model.library.trashTransactions.filter { $0.status == .recoverable }.count
    let value = "library:books=\(model.library.books.count):continue=\(continued):up-next=\(upNext):finished=\(finished):collections=\(model.library.collections.count):trash=\(trash):view=\(model.library.allBooksViewStyle.rawValue):current=\(current):position=\(position)"
    StateProbe(id: "library-organizer-probe", value: value)
  }
}

private func organizationDuration(_ seconds: Double) -> String {
  let minutes = max(Int(seconds / 60), 0)
  if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
  return "\(minutes)m"
}
