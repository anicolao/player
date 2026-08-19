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
