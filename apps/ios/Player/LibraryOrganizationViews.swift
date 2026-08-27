import SwiftUI
import UIKit

struct LibraryOrganizationHome: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: PlayerModel
  let resume: (Book) -> Void
  @State private var showUpNext = false

  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 26) {
            if !model.library.continueListeningBooks.isEmpty {
              continueListening.padding(.horizontal, 20)
            }
            if !model.library.upNextBooks.isEmpty {
              upNext.padding(.horizontal, 20)
                .id("library-up-next")
            }
            recentlyAdded(availableWidth: geometry.size.width)
            browse.padding(.horizontal, 20)
          }
          .padding(.vertical, 18)
          .background(LibraryVerticalScrollSettler())
        }
        .playerMiniPlayerScrollRunway()
        .accessibilityIdentifier("library-root-scroll")
        #if E2E
          .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.environment["PLAYER_E2E_DYNAMIC_TYPE"] == "accessibility5" {
              Button {
                proxy.scrollTo("library-up-next", anchor: .center)
              } label: {
                Color.white.opacity(0.001)
                  .frame(width: 44, height: 44)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Align Up Next")
              .accessibilityIdentifier("e2e-align-library-up-next")
            }
          }
        #endif
      }
    }
    .navigationDestination(isPresented: $showUpNext) { UpNextView(model: model) }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink {
          LibrarySearchView(model: model)
        } label: {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 21, weight: .semibold))
            .frame(width: 48, height: 48)
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

  @ViewBuilder
  private func recentlyAdded(availableWidth: CGFloat) -> some View {
    let books = Array(model.library.recentlyAddedBooks.prefix(4))
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 12) {
        sectionTitle("Recently Added")
        LazyVStack(spacing: 14) {
          ForEach(books) { book in
            NavigationLink(value: book.id) { BookRow(book: book) }
              .buttonStyle(.plain)
              .accessibilityIdentifier("recent-book-\(book.id.uuidString.lowercased())")
          }
        }
      }
      .padding(.horizontal, 20)
    } else {
      BookshelfSection(
        title: "Recently Added",
        books: books,
        scale: .feature,
        availableWidth: availableWidth,
        scrollIdentifier: "library-home-recent-shelf-scroll"
      ) { book, metrics in
        NavigationLink(value: book.id) {
          BookshelfCoverCard(book: book, metrics: metrics)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(book.authors.first ?? "Unknown Author")")
        .accessibilityHint("Opens audiobook details")
        .accessibilityIdentifier("recent-book-\(book.id.uuidString.lowercased())")
      }
      .accessibilityIdentifier("library-home-recently-added-shelf")
    }
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

private struct LibraryVerticalScrollSettler: UIViewRepresentable {
  func makeUIView(context: Context) -> LibraryVerticalScrollSettlerView {
    LibraryVerticalScrollSettlerView()
  }

  func updateUIView(_ uiView: LibraryVerticalScrollSettlerView, context: Context) {
    uiView.configureEnclosingScrollViewIfNeeded()
  }
}

private final class LibraryVerticalScrollSettlerView: UIView {
  private weak var configuredScrollView: UIScrollView?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    configureEnclosingScrollViewIfNeeded()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    configureEnclosingScrollViewIfNeeded()
  }

  func configureEnclosingScrollViewIfNeeded() {
    guard configuredScrollView == nil else { return }
    var ancestor = superview
    while let view = ancestor {
      if let scrollView = view as? UIScrollView {
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = false
        configuredScrollView = scrollView
        return
      }
      ancestor = view.superview
    }
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
      .playerMiniPlayerScrollRunway()
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
      GeometryReader { geometry in
        ScrollView {
          if model.library.allBooksViewStyle == .shelf {
            if dynamicTypeSize.isAccessibilitySize {
              LazyVStack(spacing: 14) {
                ForEach(sortedBooks) { book in bookLink(book) { BookRow(book: book) } }
              }
              .padding(20)
            } else {
              bookshelf(availableWidth: geometry.size.width)
            }
          } else {
            LazyVStack(spacing: 14) {
              ForEach(sortedBooks) { book in bookLink(book) { BookRow(book: book) } }
            }
            .padding(20)
          }
        }
        .playerMiniPlayerScrollRunway()
      }
      StateProbe(id: "all-books-probe", value: allBooksValue)
      StateProbe(id: "all-books-screen", value: "ready")
      LibraryOrganizerStateProbe(model: model)
    }
    .navigationTitle("All Books")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          let next: LibraryViewStyle = model.library.allBooksViewStyle == .shelf ? .list : .shelf
          Task { _ = await model.setAllBooksViewStyle(next) }
        } label: {
          Image(systemName: model.library.allBooksViewStyle == .shelf ? "list.bullet" : "books.vertical")
        }
        .accessibilityLabel(model.library.allBooksViewStyle == .shelf ? "Use list" : "Use shelf")
        .accessibilityIdentifier(model.library.allBooksViewStyle == .shelf ? "library-view-list" : "library-view-shelf")
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

  private func bookshelf(availableWidth: CGFloat) -> some View {
    LazyVStack(alignment: .leading, spacing: 30) {
      if !continueListeningBooks.isEmpty {
        BookshelfSection(
          title: "Continue Listening",
          books: continueListeningBooks,
          scale: .feature,
          availableWidth: availableWidth,
          scrollIdentifier: "all-books-continue-shelf-scroll"
        ) { book, metrics in
          bookLink(book, identifier: "bookshelf-continue-book-\(book.id.uuidString.lowercased())") {
            BookshelfCoverCard(book: book, metrics: metrics)
          }
        }
      }
      BookshelfSection(
        title: "Recently Added",
        books: recentlyAddedBooks,
        scale: .feature,
        availableWidth: availableWidth,
        scrollIdentifier: "all-books-recent-shelf-scroll"
      ) { book, metrics in
        bookLink(book, identifier: "bookshelf-recent-book-\(book.id.uuidString.lowercased())") {
          BookshelfCoverCard(book: book, metrics: metrics)
        }
      }
      BookshelfSection(
        title: "A–Z",
        books: sortedBooks,
        scale: .compact,
        availableWidth: availableWidth,
        scrollIdentifier: "all-books-a-z-shelf-scroll"
      ) { book, metrics in
        bookLink(book) { BookshelfCoverCard(book: book, metrics: metrics) }
      }
    }
    .padding(.vertical, 18)
    .accessibilityIdentifier("all-books-bookshelf")
  }

  private var continueListeningBooks: [Book] {
    let available = Set(sortedBooks.map(\.id))
    return model.library.continueListeningBooks.filter { available.contains($0.id) }
  }

  private var recentlyAddedBooks: [Book] {
    let available = Set(sortedBooks.map(\.id))
    let recent = model.library.recentlyAddedBooks.filter { available.contains($0.id) }
    return recent.isEmpty ? sortedBooks : recent
  }

  private func bookLink<Label: View>(
    _ book: Book,
    identifier: String? = nil,
    @ViewBuilder label: () -> Label
  ) -> some View {
    NavigationLink {
      BookDetailView(model: model, bookID: book.id) { selectedBook, position in
        Task { await model.play(bookID: selectedBook.id, at: position) }
      }
    } label: {
      label()
    }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(book.title), \(book.authors.first ?? "Unknown Author")")
      .accessibilityHint("Opens audiobook details")
      .accessibilityIdentifier(
        identifier ?? "all-books-book-\(book.id.uuidString.lowercased())"
      )
  }

  private var allBooksValue: String {
    let order = sortedBooks.map { $0.id.uuidString.lowercased() }.joined(separator: ",")
    return "all-books:count=\(sortedBooks.count):view=\(model.library.allBooksViewStyle.rawValue):order=\(order)"
  }
}

private enum BookshelfScale: Equatable {
  case feature
  case compact
}

private struct BookshelfSection<Content: View>: View {
  let title: String
  let books: [Book]
  let scale: BookshelfScale
  let availableWidth: CGFloat
  let scrollIdentifier: String
  private let content: (Book, BookshelfMetrics) -> Content

  init(
    title: String,
    books: [Book],
    scale: BookshelfScale,
    availableWidth: CGFloat,
    scrollIdentifier: String,
    @ViewBuilder content: @escaping (Book, BookshelfMetrics) -> Content
  ) {
    self.title = title
    self.books = books
    self.scale = scale
    self.availableWidth = availableWidth
    self.scrollIdentifier = scrollIdentifier
    self.content = content
  }

  var body: some View {
    let metrics = BookshelfMetrics(scale: scale, availableWidth: availableWidth)
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.title3.bold())
        .foregroundStyle(PlayerColor.ink)
        .padding(.horizontal, 20)

      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: metrics.spacing) {
          ForEach(books) { book in content(book, metrics) }
        }
        .padding(.horizontal, metrics.shelfEndInset)
        .padding(.top, metrics.topInset)
        .frame(minWidth: availableWidth, alignment: .leading)
        .background(alignment: .topLeading) {
          GeometryReader { shelfGeometry in
            Image("BurntOrangeShelf")
              .resizable(
                capInsets: EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12),
                resizingMode: .stretch
              )
              .interpolation(.high)
              .frame(width: shelfGeometry.size.width, height: metrics.shelfHeight)
              .offset(y: metrics.shelfOffset)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
      }
      .scrollIndicators(.hidden)
      .accessibilityIdentifier(scrollIdentifier)
      .frame(width: availableWidth, height: metrics.rowHeight)
    }
  }
}

private struct BookshelfMetrics {
  let scale: BookshelfScale
  let coverSize: CGFloat
  let spacing: CGFloat
  let shelfHeight: CGFloat = 32
  let topInset: CGFloat = 8
  let shelfEndInset: CGFloat = 20

  init(scale: BookshelfScale, availableWidth: CGFloat) {
    self.scale = scale
    switch scale {
    case .feature:
      spacing = 12
      coverSize = min(max((availableWidth - 20 - (spacing * 3)) / 3.5, 88), 108)
    case .compact:
      spacing = 9
      coverSize = min(max((availableWidth - 20 - (spacing * 4)) / 4.8, 64), 78)
    }
  }

  var shelfOffset: CGFloat { topInset + coverSize - 5 }
  var metadataHeight: CGFloat { scale == .feature ? 54 : 47 }
  var rowHeight: CGFloat { topInset + coverSize + shelfHeight + 8 + metadataHeight }
  var cornerRadius: CGFloat { scale == .feature ? 3.5 : 2.5 }
}

private struct BookshelfCoverCard: View {
  let book: Book
  let metrics: BookshelfMetrics

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ArtworkView(
        data: book.artworkData,
        size: metrics.coverSize,
        cornerRadius: metrics.cornerRadius,
        shadowRadius: 0,
        shadowY: 0
      )
        .overlay(alignment: .top) {
          LinearGradient(
            colors: [Color.white.opacity(0.42), Color.white.opacity(0.12), .clear],
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(height: max(4, metrics.coverSize * 0.055))
          .clipShape(
            UnevenRoundedRectangle(
              topLeadingRadius: metrics.cornerRadius,
              topTrailingRadius: metrics.cornerRadius
            )
          )
          .accessibilityHidden(true)
        }
        .overlay(alignment: .leading) {
          LinearGradient(
            colors: [PlayerColor.ink.opacity(0.24), Color.white.opacity(0.20), .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: max(4, metrics.coverSize * 0.05))
          .clipShape(
            UnevenRoundedRectangle(
              topLeadingRadius: metrics.cornerRadius,
              bottomLeadingRadius: metrics.cornerRadius
            )
          )
          .accessibilityHidden(true)
        }
        .overlay {
          RoundedRectangle(cornerRadius: metrics.cornerRadius)
            .strokeBorder(
              LinearGradient(
                colors: [Color.white.opacity(0.38), PlayerColor.ink.opacity(0.30)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              ),
              lineWidth: 0.75
            )
            .accessibilityHidden(true)
        }
        .shadow(color: PlayerColor.ink.opacity(0.30), radius: 3, x: 2, y: 4)
        .shadow(color: PlayerColor.ink.opacity(0.16), radius: 7, x: 1, y: 7)

      Color.clear.frame(height: metrics.shelfHeight + 8)

      VStack(alignment: .leading, spacing: 4) {
        Text(book.title)
          .font(metrics.scale == .feature ? .caption.weight(.semibold) : .caption2.weight(.semibold))
          .foregroundStyle(PlayerColor.ink)
          .lineLimit(2)
        Text(book.authors.first ?? "Unknown Author")
          .font(metrics.scale == .feature ? .caption2 : .system(size: 9.5))
          .foregroundStyle(PlayerColor.secondary)
          .lineLimit(1)
      }
      .frame(height: metrics.metadataHeight, alignment: .top)
    }
    .frame(width: metrics.coverSize, alignment: .leading)
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
      .playerMiniPlayerScrollRunway()
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
      .playerMiniPlayerScrollRunway()
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
      .playerMiniPlayerScrollRunway()
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
        .playerMiniPlayerScrollRunway()
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
      .playerMiniPlayerScrollRunway()
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
        .playerMiniPlayerScrollRunway()
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
  case fullUnlock
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
        case "full-unlock": _path = State(initialValue: [.fullUnlock])
        case "backup": _path = State(initialValue: [.backup])
        case "diagnostics": _path = State(initialValue: [.diagnostics])
        default: break
        }
      }
    #endif
  }

  var body: some View {
    NavigationStack(path: $path) {
      ScrollViewReader { proxy in
        List {
        Section("Bookshelf") {
          NavigationLink(value: LibrarySettingsDestination.fullUnlock) {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text("Full Unlock")
                Text(fullUnlockStatus)
                  .font(.caption)
                  .foregroundStyle(PlayerColor.secondary)
              }
            } icon: {
              Image(systemName: model.monetization.isUnlocked ? "checkmark.seal.fill" : "books.vertical.fill")
            }
          }
          .accessibilityIdentifier("settings-full-unlock")
        }
        Section("Library") {
          Picker("All Books layout", selection: Binding(
            get: { model.library.allBooksViewStyle },
            set: { style in Task { _ = await model.setAllBooksViewStyle(style) } }
          )) {
            Text("Shelf").tag(LibraryViewStyle.shelf)
            Text("List").tag(LibraryViewStyle.list)
          }
          .accessibilityIdentifier("all-books-layout-picker")
          NavigationLink(value: LibrarySettingsDestination.trash) {
            Label("Trash", systemImage: "trash")
          }
          NavigationLink(value: LibrarySettingsDestination.storage) {
            Label("Storage", systemImage: "internaldrive")
          }
          .accessibilityIdentifier("settings-storage")
          NavigationLink(value: LibrarySettingsDestination.backup) {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text("Backup")
                Text("Protect or move your library")
                  .font(.caption)
                  .foregroundStyle(PlayerColor.secondary)
              }
            } icon: {
              Image(systemName: "externaldrive.badge.timemachine")
            }
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
          .id("settings-accessibility")
        }
        Section("Privacy & Support") {
          NavigationLink(value: LibrarySettingsDestination.diagnostics) {
            Label("Offline & Support", systemImage: "checkmark.shield")
          }
          .accessibilityIdentifier("settings-diagnostics")
        }
        }
        .playerMiniPlayerScrollRunway()
        .scrollContentBackground(.hidden)
        .background(PlayerColor.background)
        .navigationTitle("Settings")
        .navigationDestination(for: LibrarySettingsDestination.self) { destination in
          switch destination {
          case .fullUnlock: FullUnlockView(model: model)
          case .trash: LibraryTrashView(model: model)
          case .storage: StorageSettingsView(model: model)
          case .backup: BackupSettingsView(model: model)
          case .playbackDefaults: TransportPreferencesEditor(model: model)
          case .smartRewind: SmartRewindSettingsView(model: model)
          case .accessibility: AccessibilitySettingsView(model: model)
          case .diagnostics: SupportDiagnosticsView(model: model)
          }
        }
        #if E2E
          .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.environment["PLAYER_E2E_DYNAMIC_TYPE"] == "accessibility5" {
              Button {
                proxy.scrollTo("settings-accessibility", anchor: .center)
              } label: {
                Color.white.opacity(0.001)
                  .frame(width: 44, height: 44)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Align Accessibility settings")
              .accessibilityIdentifier("e2e-align-settings-accessibility")
            }
          }
        #endif
      }
    }
  }

  private var fullUnlockStatus: String {
    if model.monetization.isUnlocked { return "Purchased — no subscription" }
    let price = model.monetization.displayPrice.map { " · \($0) once" } ?? ""
    return "\(model.monetization.remainingPlaybackDescription)\(price)"
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
