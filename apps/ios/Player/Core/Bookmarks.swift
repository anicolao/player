import Foundation

struct Bookmark: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var bookID: UUID
  var bookPositionMilliseconds: Int64
  var assetID: UUID
  var assetPositionMilliseconds: Int64
  var chapterID: String?
  var chapterTitleSnapshot: String?
  var label: String
  var note: String?
  var createdAt: Date
  var updatedAt: Date

  var bookPositionSeconds: Double { Double(bookPositionMilliseconds) / 1_000 }
  var assetPositionSeconds: Double { Double(assetPositionMilliseconds) / 1_000 }
}

enum BookmarkSort: String, Codable, CaseIterable, Equatable, Sendable {
  case positionAscending
  case positionDescending
  case dateNewest
  case dateOldest
  case label
}

enum BookmarkDeletionStatus: String, Codable, Equatable, Sendable {
  case deleted
  case undone
}

struct BookmarkDeletionTransaction: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var bookmark: Bookmark
  var originalIndex: Int
  var deletedAt: Date
  var status: BookmarkDeletionStatus
  var undoneAt: Date?
}

enum BookmarkError: LocalizedError, Equatable, Sendable {
  case noCurrentBook
  case missingTimeline(UUID)
  case missingBookmark(UUID)
  case invalidLabel
  case noDeletionToUndo(UUID)

  var errorDescription: String? {
    switch self {
    case .noCurrentBook:
      "Open a book before adding a bookmark."
    case .missingTimeline(let bookID):
      "Book \(bookID.uuidString) has no playable bookmark location."
    case .missingBookmark(let bookmarkID):
      "Bookmark \(bookmarkID.uuidString) no longer exists."
    case .invalidLabel:
      "A bookmark label cannot be empty."
    case .noDeletionToUndo(let transactionID):
      "Bookmark deletion \(transactionID.uuidString) cannot be undone."
    }
  }
}

enum BookmarkPlanner {
  static func makeBookmark(
    id: UUID,
    book: Book,
    positionSeconds: Double,
    note: String? = nil,
    createdAt: Date
  ) throws -> Bookmark {
    guard let location = PlaybackTimeline.location(in: book, at: positionSeconds) else {
      throw BookmarkError.missingTimeline(book.id)
    }
    let chapter = PlaybackTimeline.chapter(in: book, at: location.bookSeconds)
    let chapterTitle = normalizedOptionalText(chapter?.chapter.title)
    return Bookmark(
      id: id,
      bookID: book.id,
      bookPositionMilliseconds: milliseconds(location.bookSeconds),
      assetID: location.asset.id,
      assetPositionMilliseconds: milliseconds(location.assetSeconds),
      chapterID: chapter?.chapter.id,
      chapterTitleSnapshot: chapterTitle,
      label: generatedLabel(
        chapterTitle: chapterTitle,
        positionMilliseconds: milliseconds(location.bookSeconds)
      ),
      note: normalizedOptionalText(note),
      createdAt: createdAt,
      updatedAt: createdAt
    )
  }

  static func edited(
    _ bookmark: Bookmark,
    label: String,
    note: String?,
    updatedAt: Date
  ) throws -> Bookmark {
    let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedLabel.isEmpty else { throw BookmarkError.invalidLabel }
    var edited = bookmark
    edited.label = normalizedLabel
    edited.note = normalizedOptionalText(note)
    edited.updatedAt = updatedAt
    return edited
  }

  static func generatedLabel(
    chapterTitle: String?,
    positionMilliseconds: Int64
  ) -> String {
    let prefix = normalizedOptionalText(chapterTitle) ?? "Bookmark"
    return "\(prefix) · \(timecode(positionMilliseconds: positionMilliseconds))"
  }

  static func timecode(positionMilliseconds: Int64) -> String {
    let totalSeconds = max(0, positionMilliseconds) / 1_000
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%lld:%02lld:%02lld", hours, minutes, seconds)
    }
    return String(format: "%lld:%02lld", minutes, seconds)
  }

  private static func milliseconds(_ seconds: Double) -> Int64 {
    Int64((max(0, seconds.isFinite ? seconds : 0) * 1_000).rounded(.down))
  }

  private static func normalizedOptionalText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

struct BookmarkIndex: Sendable {
  private var bookmarks: [Bookmark]

  init(bookmarks: [Bookmark]) {
    self.bookmarks = bookmarks
  }

  func search(query: String, sort: BookmarkSort) -> [Bookmark] {
    let normalizedQuery = LibrarySearchIndex.normalize(query)
    let terms = normalizedQuery.split(separator: " ").map(String.init)
    return bookmarks.filter { bookmark in
      let searchable = LibrarySearchIndex.normalize([
        bookmark.label,
        bookmark.note,
        bookmark.chapterTitleSnapshot,
      ].compactMap { $0 }.joined(separator: "\n"))
      return terms.allSatisfy(searchable.contains)
    }.sorted { compare($0, $1, sort: sort) }
  }

  private func compare(_ lhs: Bookmark, _ rhs: Bookmark, sort: BookmarkSort) -> Bool {
    switch sort {
    case .positionAscending:
      return comparePosition(lhs, rhs, ascending: true)
    case .positionDescending:
      return comparePosition(lhs, rhs, ascending: false)
    case .dateNewest:
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
    case .dateOldest:
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    case .label:
      let comparison = lhs.label.localizedStandardCompare(rhs.label)
      if comparison != .orderedSame { return comparison == .orderedAscending }
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private func comparePosition(
    _ lhs: Bookmark,
    _ rhs: Bookmark,
    ascending: Bool
  ) -> Bool {
    if lhs.bookPositionMilliseconds != rhs.bookPositionMilliseconds {
      return ascending
        ? lhs.bookPositionMilliseconds < rhs.bookPositionMilliseconds
        : lhs.bookPositionMilliseconds > rhs.bookPositionMilliseconds
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
