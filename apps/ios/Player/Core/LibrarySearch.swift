import CryptoKit
import Foundation

enum LibrarySearchSort: String, Codable, CaseIterable, Equatable, Sendable {
  case title
  case author
  case series
  case recentlyAdded
  case duration
  case progress
}

enum LibrarySearchDirection: String, Codable, Equatable, Sendable {
  case ascending
  case descending
}

struct LibrarySearchPreferences: Codable, Equatable, Sendable {
  var sort: LibrarySearchSort
  var direction: LibrarySearchDirection
  var status: BookListeningStatus?
  var formats: Set<String>
  var missingMetadataOnly: Bool

  static let `default` = LibrarySearchPreferences(
    sort: .title,
    direction: .ascending,
    status: nil,
    formats: [],
    missingMetadataOnly: false
  )

  var hasFilters: Bool {
    status != nil || !formats.isEmpty || missingMetadataOnly
  }
}

struct LibrarySearchResult: Equatable, Sendable {
  var books: [Book]
  var normalizedQuery: String

  func window(offset: Int, limit: Int) -> ArraySlice<Book> {
    guard offset >= 0, limit > 0, offset < books.count else { return [] }
    return books[offset..<(offset + min(limit, books.count - offset))]
  }
}

/// A deterministic digest of everything that can affect search text, filters,
/// or ordering. It deliberately excludes transaction counts: applying and
/// undoing a transaction can leave those counts unchanged while changing the
/// visible library.
struct LibrarySearchRevision: Equatable, Hashable, Sendable {
  let value: String

  init(library: LibrarySnapshot) {
    let payload = LibrarySearchRevisionPayload(library: library)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(payload)) ?? Data()
    value = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private struct LibrarySearchRevisionPayload: Encodable {
  struct ContributorValue: Encodable {
    var id: String
    var displayName: String
    var sortName: String?
    var role: ContributorRole
    var order: Int
  }

  struct SeriesValue: Encodable {
    var id: String
    var name: String
    var position: String?
  }

  struct AssetValue: Encodable {
    var id: UUID
    var originalFilename: String
    var container: String
  }

  struct BookValue: Encodable {
    var id: UUID
    var title: String
    var sortTitle: String?
    var subtitle: String?
    var contributors: [ContributorValue]
    var series: [SeriesValue]
    var description: String?
    var genres: [String]
    var tags: [String]
    var language: String?
    var publicationYear: Int?
    var publisher: String?
    var edition: String?
    var abridgement: AbridgementStatus?
    var assets: [AssetValue]
    var chapterTitles: [String]
    var dateAdded: Date
    var durationSeconds: Double
    var listeningState: BookListeningState
  }

  struct CollectionValue: Encodable {
    var id: UUID
    var name: String
    var orderedBookIDs: [UUID]
  }

  struct BookmarkValue: Encodable {
    var id: UUID
    var bookID: UUID
    var label: String?
    var note: String?
    var chapterTitle: String?
  }

  var books: [BookValue]
  var collections: [CollectionValue]
  var bookmarks: [BookmarkValue]

  init(library: LibrarySnapshot) {
    books = library.books.sorted { $0.id.uuidString < $1.id.uuidString }.map { book in
      BookValue(
        id: book.id,
        title: book.title,
        sortTitle: book.metadata.sortTitle,
        subtitle: book.metadata.subtitle,
        contributors: book.metadata.contributors.map {
          ContributorValue(
            id: $0.contributor.id,
            displayName: $0.contributor.displayName,
            sortName: $0.contributor.sortName,
            role: $0.role,
            order: $0.order
          )
        },
        series: book.metadata.seriesMemberships.map {
          SeriesValue(id: $0.seriesID, name: $0.name, position: $0.position)
        },
        description: book.metadata.description,
        genres: book.metadata.genres,
        tags: book.metadata.tags,
        language: book.metadata.language,
        publicationYear: book.metadata.publicationYear,
        publisher: book.metadata.publisher,
        edition: book.metadata.edition,
        abridgement: book.metadata.abridgement,
        assets: book.assets.map {
          AssetValue(id: $0.id, originalFilename: $0.originalFilename, container: $0.container)
        },
        chapterTitles: book.chapters.map(\.title),
        dateAdded: book.dateAdded,
        durationSeconds: book.durationSeconds,
        listeningState: book.listeningState
      )
    }
    collections = library.collections.sorted { $0.id.uuidString < $1.id.uuidString }.map {
      CollectionValue(id: $0.id, name: $0.name, orderedBookIDs: $0.orderedBookIDs)
    }
    bookmarks = library.bookmarks.sorted { $0.id.uuidString < $1.id.uuidString }.map {
      BookmarkValue(
        id: $0.id,
        bookID: $0.bookID,
        label: $0.label,
        note: $0.note,
        chapterTitle: $0.chapterTitleSnapshot
      )
    }
  }
}

struct LibrarySearchBuild: Sendable {
  var revision: LibrarySearchRevision
  var index: LibrarySearchIndex
}

/// Serializes expensive index rebuilds on an executor that is distinct from
/// the UI's MainActor. Views await only the completed immutable index.
actor LibrarySearchIndexBuilder {
  static let shared = LibrarySearchIndexBuilder()

  typealias BuildOperation = @Sendable (
    LibrarySnapshot,
    [UUID: [String]]
  ) async -> LibrarySearchIndex

  private(set) var completedBuildCount = 0
  private var latestGeneration = 0
  private let buildOperation: BuildOperation

  init(buildOperation: @escaping BuildOperation = { library, bookmarkNotes in
    LibrarySearchIndex(library: library, bookmarkNotesByBookID: bookmarkNotes)
  }) {
    self.buildOperation = buildOperation
  }

  func build(
    library: LibrarySnapshot,
    bookmarkNotesByBookID: [UUID: [String]] = [:]
  ) -> LibrarySearchIndex {
    let index = LibrarySearchIndex(
      library: library,
      bookmarkNotesByBookID: bookmarkNotesByBookID
    )
    completedBuildCount += 1
    return index
  }

  /// Builds off-actor and publishes only the newest request. Actor reentrancy
  /// at the detached-task await lets a later revision invalidate an expensive
  /// earlier build rather than allowing stale results to reach the view.
  func buildLatest(
    library: LibrarySnapshot,
    revision: LibrarySearchRevision,
    bookmarkNotesByBookID: [UUID: [String]] = [:]
  ) async -> LibrarySearchBuild? {
    latestGeneration += 1
    let generation = latestGeneration
    let buildOperation = self.buildOperation
    let task = Task.detached(priority: .userInitiated) {
      await buildOperation(library, bookmarkNotesByBookID)
    }
    let index = await task.value
    guard !Task.isCancelled, generation == latestGeneration else { return nil }
    completedBuildCount += 1
    return LibrarySearchBuild(revision: revision, index: index)
  }
}

/// An immutable, in-memory full-text index. It is rebuilt from the durable
/// library whenever searchable records change and can be queried without I/O.
struct LibrarySearchIndex: Sendable {
  private struct Entry: Sendable {
    var book: Book
    var normalizedText: String
    var collectionNames: [String]
  }

  private var entries: [Entry]

  static let empty = LibrarySearchIndex(entries: [])

  init(
    library: LibrarySnapshot,
    bookmarkNotesByBookID: [UUID: [String]] = [:]
  ) {
    var collectionsByBookID: [UUID: [String]] = [:]
    for collection in library.collections {
      for bookID in collection.orderedBookIDs {
        collectionsByBookID[bookID, default: []].append(collection.name)
      }
    }
    let persistedBookmarkTextByBookID = Dictionary(grouping: library.bookmarks, by: \.bookID)
      .mapValues { bookmarks in
        bookmarks.flatMap { bookmark in
          [bookmark.label, bookmark.note, bookmark.chapterTitleSnapshot].compactMap { $0 }
        }
      }

    entries = library.books.map { book in
      let collectionNames = collectionsByBookID[book.id] ?? []
      let searchableValues: [String] = [
        book.title,
        book.metadata.sortTitle,
        book.metadata.subtitle,
        book.metadata.description,
        book.metadata.language,
        book.metadata.publisher,
        book.metadata.edition,
      ].compactMap { $0 }
        + book.metadata.contributors.flatMap {
          [$0.contributor.displayName, $0.contributor.sortName].compactMap { $0 }
        }
        + book.metadata.seriesMemberships.flatMap { [$0.name, $0.position].compactMap { $0 } }
        + book.metadata.genres
        + book.metadata.tags
        + book.assets.map(\.originalFilename)
        + book.chapters.map(\.title)
        + collectionNames
        + (persistedBookmarkTextByBookID[book.id] ?? [])
        + (bookmarkNotesByBookID[book.id] ?? [])

      return Entry(
        book: book,
        normalizedText: Self.normalize(searchableValues.joined(separator: "\n")),
        collectionNames: collectionNames
      )
    }
  }

  private init(entries: [Entry]) {
    self.entries = entries
  }

  func search(
    query: String,
    preferences: LibrarySearchPreferences
  ) -> LibrarySearchResult {
    let normalizedQuery = Self.normalize(query)
    let terms = normalizedQuery.split(separator: " ").map(String.init)
    let filtered = entries.filter { entry in
      terms.allSatisfy(entry.normalizedText.contains)
        && matchesFilters(entry.book, preferences: preferences)
    }

    let books = filtered.map(\.book).sorted {
      compare($0, $1, preferences: preferences)
    }
    return LibrarySearchResult(books: books, normalizedQuery: normalizedQuery)
  }

  static func normalize(_ value: String) -> String {
    let folded = value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    let components = folded.unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
    }
    return String(components)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private func matchesFilters(
    _ book: Book,
    preferences: LibrarySearchPreferences
  ) -> Bool {
    if let status = preferences.status, book.listeningState.status != status { return false }
    if !preferences.formats.isEmpty {
      let containers = Set(book.assets.map { $0.container.uppercased() })
      if containers.isDisjoint(with: preferences.formats.map { $0.uppercased() }) { return false }
    }
    if preferences.missingMetadataOnly {
      let titleMissing = book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let authorsMissing = book.metadata.authors.isEmpty
      let narratorMissing = book.metadata.narrators.isEmpty
      if !titleMissing && !authorsMissing && !narratorMissing { return false }
    }
    return true
  }

  private func compare(
    _ lhs: Book,
    _ rhs: Book,
    preferences: LibrarySearchPreferences
  ) -> Bool {
    let orderedAscending: Bool
    switch preferences.sort {
    case .title:
      orderedAscending = compareText(
        lhs.metadata.sortTitle ?? lhs.title,
        rhs.metadata.sortTitle ?? rhs.title,
        lhsID: lhs.id,
        rhsID: rhs.id
      )
    case .author:
      orderedAscending = compareText(
        lhs.metadata.authors.first?.sortName ?? lhs.metadata.authors.first?.displayName ?? "",
        rhs.metadata.authors.first?.sortName ?? rhs.metadata.authors.first?.displayName ?? "",
        lhsID: lhs.id,
        rhsID: rhs.id
      )
    case .series:
      let lhsSeries = lhs.metadata.seriesMemberships.first
      let rhsSeries = rhs.metadata.seriesMemberships.first
      let lhsValue = [lhsSeries?.name, lhsSeries?.position, lhs.metadata.sortTitle ?? lhs.title]
        .compactMap { $0 }.joined(separator: " ")
      let rhsValue = [rhsSeries?.name, rhsSeries?.position, rhs.metadata.sortTitle ?? rhs.title]
        .compactMap { $0 }.joined(separator: " ")
      orderedAscending = compareText(lhsValue, rhsValue, lhsID: lhs.id, rhsID: rhs.id)
    case .recentlyAdded:
      orderedAscending = lhs.dateAdded != rhs.dateAdded
        ? lhs.dateAdded < rhs.dateAdded : lhs.id.uuidString < rhs.id.uuidString
    case .duration:
      orderedAscending = lhs.durationSeconds != rhs.durationSeconds
        ? lhs.durationSeconds < rhs.durationSeconds : lhs.id.uuidString < rhs.id.uuidString
    case .progress:
      orderedAscending = lhs.listeningState.positionMilliseconds != rhs.listeningState.positionMilliseconds
        ? lhs.listeningState.positionMilliseconds < rhs.listeningState.positionMilliseconds
        : lhs.id.uuidString < rhs.id.uuidString
    }
    return preferences.direction == .ascending ? orderedAscending : !orderedAscending
  }

  private func compareText(
    _ lhs: String,
    _ rhs: String,
    lhsID: UUID,
    rhsID: UUID
  ) -> Bool {
    let comparison = lhs.localizedStandardCompare(rhs)
    if comparison != .orderedSame { return comparison == .orderedAscending }
    return lhsID.uuidString < rhsID.uuidString
  }
}

extension LibrarySearchPreferences {
  var summaryTokens: [String] {
    var values: [String] = []
    if let status {
      switch status {
      case .unplayed: values.append("Unplayed")
      case .inProgress: values.append("In progress")
      case .finished: values.append("Finished")
      }
    }
    if !formats.isEmpty { values.append(formats.sorted().joined(separator: ", ")) }
    if missingMetadataOnly { values.append("Missing metadata") }
    switch sort {
    case .title: values.append("Title")
    case .author: values.append("Author")
    case .series: values.append("Series order")
    case .recentlyAdded: values.append("Recently added")
    case .duration: values.append("Duration")
    case .progress: values.append("Progress")
    }
    return values
  }
}
