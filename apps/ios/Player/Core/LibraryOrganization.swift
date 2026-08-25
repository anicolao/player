import Foundation

enum BookListeningStatus: String, Codable, Equatable, Sendable {
  case unplayed
  case inProgress
  case finished
}

struct BookListeningState: Codable, Equatable, Sendable {
  var status: BookListeningStatus
  var positionMilliseconds: Int64
  var lastListenedAt: Date?
  var finishedAt: Date?

  static let unplayed = BookListeningState(
    status: .unplayed,
    positionMilliseconds: 0,
    lastListenedAt: nil,
    finishedAt: nil
  )

  var positionSeconds: Double { Double(positionMilliseconds) / 1_000 }
}

enum LibraryViewStyle: String, Codable, Equatable, Sendable {
  case shelf
  case list

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    switch value {
    case Self.shelf.rawValue, "grid": self = .shelf
    case Self.list.rawValue: self = .list
    default:
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unknown library view style: \(value)"
      )
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

struct BookCollection: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var name: String
  var orderedBookIDs: [UUID]
  var createdAt: Date
  var updatedAt: Date
}

enum LibraryBrowseFacet: String, Codable, Equatable, Sendable {
  case series
  case authors
  case narrators
}

struct LibraryBrowseGroup: Codable, Equatable, Identifiable, Sendable {
  let id: String
  var displayName: String
  var sortName: String?
  var bookIDs: [UUID]
}

enum LibraryRemovalMediaPolicy: String, Codable, Equatable, Sendable {
  case retainManagedMedia
  case moveManagedMediaToTrash
}

struct TrashedMediaManifest: Codable, Equatable, Sendable {
  var transactionID: UUID
  var bookID: UUID
  var originalDirectoryRelativePath: String
  var trashDirectoryRelativePath: String
  var byteCount: Int64
}

struct CollectionBookPlacement: Codable, Equatable, Sendable {
  var collectionID: UUID
  var index: Int
}

enum LibraryTrashStatus: String, Codable, Equatable, Sendable {
  case recoverable
  case restored
  case purged
}

struct LibraryTrashTransaction: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var book: Book
  var originalBookIndex: Int
  var mediaPolicy: LibraryRemovalMediaPolicy
  var mediaManifest: TrashedMediaManifest?
  var upNextIndex: Int?
  var collectionPlacements: [CollectionBookPlacement]
  var wasCurrentBook: Bool
  var playbackPosition: PlaybackPosition?
  var positionEvents: [PositionEvent]
  var metadataTransactions: [MetadataTransaction]
  var removedAt: Date
  var status: LibraryTrashStatus
  var restoredAt: Date?
}

enum LibraryOrganizationError: LocalizedError, Equatable, Sendable {
  case missingCollection(UUID)
  case invalidCollectionName
  case duplicateCollectionName(String)
  case invalidBookOrder
  case missingTrashTransaction(UUID)
  case trashTransactionNotRecoverable(UUID)
  case bookAlreadyExists(UUID)

  var errorDescription: String? {
    switch self {
    case .missingCollection(let id): "Collection \(id.uuidString) no longer exists."
    case .invalidCollectionName: "Collection names cannot be empty."
    case .duplicateCollectionName(let name): "A collection named \(name) already exists."
    case .invalidBookOrder: "The supplied book order is incomplete or contains duplicates."
    case .missingTrashTransaction(let id): "Trash transaction \(id.uuidString) no longer exists."
    case .trashTransactionNotRecoverable(let id):
      "Trash transaction \(id.uuidString) has already been restored."
    case .bookAlreadyExists(let id): "Book \(id.uuidString) is already in the library."
    }
  }
}

extension LibrarySnapshot {
  var continueListeningBooks: [Book] {
    books.filter { $0.listeningState.status == .inProgress }.sorted {
      let lhs = $0.listeningState.lastListenedAt ?? .distantPast
      let rhs = $1.listeningState.lastListenedAt ?? .distantPast
      if lhs != rhs { return lhs > rhs }
      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }

  var upNextBooks: [Book] {
    let byID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
    return upNextBookIDs.compactMap { byID[$0] }
  }

  var recentlyAddedBooks: [Book] {
    books.sorted {
      if $0.dateAdded != $1.dateAdded { return $0.dateAdded > $1.dateAdded }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  func browseGroups(for facet: LibraryBrowseFacet) -> [LibraryBrowseGroup] {
    var groups: [String: LibraryBrowseGroup] = [:]
    var seriesPositions: [String: [UUID: String?]] = [:]

    for book in books {
      switch facet {
      case .series:
        for membership in book.metadata.seriesMemberships {
          let key = membership.seriesID
          var group = groups[key] ?? LibraryBrowseGroup(
            id: key,
            displayName: membership.name,
            sortName: nil,
            bookIDs: []
          )
          if !group.bookIDs.contains(book.id) { group.bookIDs.append(book.id) }
          groups[key] = group
          seriesPositions[key, default: [:]][book.id] = membership.position
        }
      case .authors:
        for contributor in book.metadata.authors {
          append(book, contributor: contributor, to: &groups)
        }
      case .narrators:
        for contributor in book.metadata.narrators {
          append(book, contributor: contributor, to: &groups)
        }
      }
    }

    let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
    return groups.values.map { group in
      var sorted = group
      sorted.bookIDs.sort { lhsID, rhsID in
        if facet == .series {
          let lhs = seriesPositions[group.id]?[lhsID] ?? nil
          let rhs = seriesPositions[group.id]?[rhsID] ?? nil
          switch (lhs, rhs) {
          case (.some(let lhs), .some(let rhs)) where lhs != rhs:
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
          case (.some, .none): return true
          case (.none, .some): return false
          default: break
          }
        }
        let lhsTitle = booksByID[lhsID]?.metadata.sortTitle
          ?? booksByID[lhsID]?.title ?? ""
        let rhsTitle = booksByID[rhsID]?.metadata.sortTitle
          ?? booksByID[rhsID]?.title ?? ""
        if lhsTitle != rhsTitle {
          return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedAscending
        }
        return lhsID.uuidString < rhsID.uuidString
      }
      return sorted
    }.sorted {
      let lhs = $0.sortName ?? $0.displayName
      let rhs = $1.sortName ?? $1.displayName
      if lhs != rhs { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
      return $0.id < $1.id
    }
  }

  private func append(
    _ book: Book,
    contributor: Contributor,
    to groups: inout [String: LibraryBrowseGroup]
  ) {
    var group = groups[contributor.id] ?? LibraryBrowseGroup(
      id: contributor.id,
      displayName: contributor.displayName,
      sortName: contributor.sortName,
      bookIDs: []
    )
    if !group.bookIDs.contains(book.id) { group.bookIDs.append(book.id) }
    groups[contributor.id] = group
  }
}
