import Foundation

enum PlaybackSeekContext: String, Codable, Equatable, Sendable {
  case chapter
  case wholeBook
}

struct TransportPreferences: Codable, Equatable, Sendable {
  var playbackRate: Double
  var backwardSkipSeconds: Double
  var forwardSkipSeconds: Double
  var seekContext: PlaybackSeekContext

  static let `default` = TransportPreferences(
    playbackRate: 1,
    backwardSkipSeconds: 15,
    forwardSkipSeconds: 30,
    seekContext: .chapter
  )

  var isValid: Bool {
    Self.isValidPlaybackRate(playbackRate)
      && backwardSkipSeconds.isFinite && backwardSkipSeconds > 0
      && forwardSkipSeconds.isFinite && forwardSkipSeconds > 0
  }

  static func isValidPlaybackRate(_ rate: Double) -> Bool {
    guard rate.isFinite, rate >= 0.5, rate <= 3 else { return false }
    let nearestStep = (rate * 20).rounded() / 20
    return abs(rate - nearestStep) < 0.000_001
  }
}

struct TransportPreferenceOverride: Codable, Equatable, Sendable {
  var playbackRate: Double?
  var backwardSkipSeconds: Double?
  var forwardSkipSeconds: Double?
  var seekContext: PlaybackSeekContext?

  init(
    playbackRate: Double? = nil,
    backwardSkipSeconds: Double? = nil,
    forwardSkipSeconds: Double? = nil,
    seekContext: PlaybackSeekContext? = nil
  ) {
    self.playbackRate = playbackRate
    self.backwardSkipSeconds = backwardSkipSeconds
    self.forwardSkipSeconds = forwardSkipSeconds
    self.seekContext = seekContext
  }

  static let empty = TransportPreferenceOverride()

  var isEmpty: Bool {
    playbackRate == nil
      && backwardSkipSeconds == nil
      && forwardSkipSeconds == nil
      && seekContext == nil
  }

  func resolved(over defaults: TransportPreferences) -> TransportPreferences {
    TransportPreferences(
      playbackRate: playbackRate ?? defaults.playbackRate,
      backwardSkipSeconds: backwardSkipSeconds ?? defaults.backwardSkipSeconds,
      forwardSkipSeconds: forwardSkipSeconds ?? defaults.forwardSkipSeconds,
      seekContext: seekContext ?? defaults.seekContext
    )
  }

  var isValid: Bool {
    (playbackRate.map(TransportPreferences.isValidPlaybackRate) ?? true)
      && (backwardSkipSeconds.map { $0.isFinite && $0 > 0 } ?? true)
      && (forwardSkipSeconds.map { $0.isFinite && $0 > 0 } ?? true)
  }
}

enum TransportPreferencesError: LocalizedError, Equatable, Sendable {
  case invalidPreferences
  case missingPlaybackTimeline(UUID)

  var errorDescription: String? {
    switch self {
    case .invalidPreferences:
      "Speed must be between 0.5× and 3.0× in 0.05× steps, and skips must be positive."
    case .missingPlaybackTimeline(let bookID):
      "Book \(bookID.uuidString) has no playable audio timeline."
    }
  }
}

struct PlaybackTimelineLocation: Equatable, Sendable {
  var asset: AudioAsset
  var assetIndex: Int
  var bookSeconds: Double
  var assetSeconds: Double
}

struct PlaybackChapterLocation: Equatable, Sendable {
  var chapter: Chapter
  var chapterIndex: Int
  var startSeconds: Double
  var endSeconds: Double

  var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

enum PlaybackTimeline {
  static func location(in book: Book, at requestedSeconds: Double) -> PlaybackTimelineLocation? {
    let ordered = orderedAssets(in: book)
    guard !ordered.isEmpty else { return nil }
    let bookSeconds = min(max(requestedSeconds.isFinite ? requestedSeconds : 0, 0), book.durationSeconds)
    let selectedOffset = ordered.indices.last(where: {
      ordered[$0].asset.timelineStartSeconds <= bookSeconds
    }) ?? ordered.startIndex
    let selected = ordered[selectedOffset]
    let assetSeconds = min(
      max(0, bookSeconds - selected.asset.timelineStartSeconds),
      max(0, selected.asset.durationSeconds)
    )
    return PlaybackTimelineLocation(
      asset: selected.asset,
      assetIndex: selected.originalIndex,
      bookSeconds: bookSeconds,
      assetSeconds: assetSeconds
    )
  }

  static func chapter(in book: Book, at requestedSeconds: Double) -> PlaybackChapterLocation? {
    let ordered = book.chapters.sorted {
      if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
      return $0.id < $1.id
    }
    guard !ordered.isEmpty else { return nil }
    let seconds = min(max(requestedSeconds.isFinite ? requestedSeconds : 0, 0), book.durationSeconds)
    let selectedIndex = ordered.indices.last(where: {
      max(0, ordered[$0].startSeconds) <= seconds
    }) ?? ordered.startIndex
    let selected = ordered[selectedIndex]
    let start = min(max(0, selected.startSeconds), book.durationSeconds)
    let declaredEnd = selected.durationSeconds > 0
      ? start + selected.durationSeconds : book.durationSeconds
    let nextStart = selectedIndex + 1 < ordered.count
      ? max(start, ordered[selectedIndex + 1].startSeconds) : book.durationSeconds
    let end = min(book.durationSeconds, min(declaredEnd, nextStart))
    return PlaybackChapterLocation(
      chapter: selected,
      chapterIndex: selectedIndex,
      startSeconds: start,
      endSeconds: max(start, end)
    )
  }

  static func seekPosition(
    _ requestedSeconds: Double,
    context: PlaybackSeekContext,
    in book: Book,
    from currentBookSeconds: Double
  ) -> Double {
    switch context {
    case .wholeBook:
      return min(max(requestedSeconds.isFinite ? requestedSeconds : 0, 0), book.durationSeconds)
    case .chapter:
      guard let chapter = chapter(in: book, at: currentBookSeconds) else {
        return min(max(requestedSeconds.isFinite ? requestedSeconds : 0, 0), book.durationSeconds)
      }
      let offset = min(
        max(requestedSeconds.isFinite ? requestedSeconds : 0, 0),
        chapter.durationSeconds
      )
      return chapter.startSeconds + offset
    }
  }

  static func previousChapterPosition(in book: Book, at seconds: Double) -> Double? {
    guard let current = chapter(in: book, at: seconds), current.chapterIndex > 0 else {
      return nil
    }
    let ordered = book.chapters.sorted {
      if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
      return $0.id < $1.id
    }
    return min(max(ordered[current.chapterIndex - 1].startSeconds, 0), book.durationSeconds)
  }

  static func nextChapterPosition(in book: Book, at seconds: Double) -> Double? {
    guard let current = chapter(in: book, at: seconds) else { return nil }
    let ordered = book.chapters.sorted {
      if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
      return $0.id < $1.id
    }
    guard current.chapterIndex + 1 < ordered.count else { return nil }
    return min(max(ordered[current.chapterIndex + 1].startSeconds, 0), book.durationSeconds)
  }

  private static func orderedAssets(in book: Book) -> [(originalIndex: Int, asset: AudioAsset)] {
    book.assets.enumerated().map { ($0.offset, $0.element) }.sorted {
      if $0.asset.timelineStartSeconds != $1.asset.timelineStartSeconds {
        return $0.asset.timelineStartSeconds < $1.asset.timelineStartSeconds
      }
      if $0.asset.importOrder != $1.asset.importOrder {
        return $0.asset.importOrder < $1.asset.importOrder
      }
      return $0.asset.id.uuidString < $1.asset.id.uuidString
    }
  }
}
