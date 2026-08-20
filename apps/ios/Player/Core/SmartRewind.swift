import Foundation

struct SmartRewindPreferences: Codable, Equatable, Sendable {
  var isEnabled: Bool
  var maximumRewindSeconds: Double
  var minimumAwaySeconds: TimeInterval
  var mediumAwaySeconds: TimeInterval
  var longAwaySeconds: TimeInterval
  var shortRewindSeconds: Double
  var mediumRewindSeconds: Double
  var longRewindSeconds: Double

  static let `default` = SmartRewindPreferences(
    isEnabled: true,
    maximumRewindSeconds: 30,
    minimumAwaySeconds: 30,
    mediumAwaySeconds: 10 * 60,
    longAwaySeconds: 60 * 60,
    shortRewindSeconds: 5,
    mediumRewindSeconds: 15,
    longRewindSeconds: 30
  )

  var isValid: Bool {
    maximumRewindSeconds.isFinite && maximumRewindSeconds >= 0
      && minimumAwaySeconds.isFinite && minimumAwaySeconds >= 0
      && mediumAwaySeconds.isFinite && mediumAwaySeconds > minimumAwaySeconds
      && longAwaySeconds.isFinite && longAwaySeconds > mediumAwaySeconds
      && shortRewindSeconds.isFinite && shortRewindSeconds >= 0
      && mediumRewindSeconds.isFinite && mediumRewindSeconds >= shortRewindSeconds
      && longRewindSeconds.isFinite && longRewindSeconds >= mediumRewindSeconds
  }

  func rewindSeconds(after secondsAway: TimeInterval) -> Double {
    guard isEnabled, isValid, secondsAway.isFinite, secondsAway >= minimumAwaySeconds else {
      return 0
    }
    let tier: Double
    if secondsAway > longAwaySeconds {
      tier = longRewindSeconds
    } else if secondsAway >= mediumAwaySeconds {
      tier = mediumRewindSeconds
    } else {
      tier = shortRewindSeconds
    }
    return min(maximumRewindSeconds, tier)
  }
}

struct SmartRewindPlan: Codable, Equatable, Sendable {
  var bookID: UUID
  var pausedAt: Date
  var resumedAt: Date
  var secondsAway: TimeInterval
  var originalPositionMilliseconds: Int64
  var targetPositionMilliseconds: Int64
  var rewindMilliseconds: Int64
  var chapterStartMilliseconds: Int64?
  var crossedRecentChapterStart: Bool
  var wasClampedToChapterStart: Bool

  var originalSeconds: Double { Double(originalPositionMilliseconds) / 1_000 }
  var targetSeconds: Double { Double(targetPositionMilliseconds) / 1_000 }
  var rewindSeconds: Double { Double(rewindMilliseconds) / 1_000 }
}

enum ResumeRewindTransactionStatus: String, Codable, Equatable, Sendable {
  case applied
  case undone
  case superseded
}

struct ResumeRewindTransaction: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var plan: SmartRewindPlan
  var preRewindEventID: UUID
  var rewindEventID: UUID
  var status: ResumeRewindTransactionStatus
  var undoneAt: Date?
  var undoEventID: UUID?

  var bookID: UUID { plan.bookID }
}

enum SmartRewindError: LocalizedError, Equatable, Sendable {
  case invalidPreferences
  case noPauseCheckpoint(UUID)
  case noRewindToUndo

  var errorDescription: String? {
    switch self {
    case .invalidPreferences:
      "Smart Rewind thresholds must increase, and rewind bounds must be finite and nonnegative."
    case .noPauseCheckpoint(let bookID):
      "Book \(bookID.uuidString) has no acknowledged pause to resume from."
    case .noRewindToUndo:
      "There is no recent resume rewind to undo."
    }
  }
}

enum SmartRewindPlanner {
  static func plan(
    for book: Book,
    positionMilliseconds: Int64,
    pausedAt: Date,
    resumedAt: Date,
    preferences: SmartRewindPreferences
  ) -> SmartRewindPlan? {
    guard preferences.isValid else { return nil }
    let secondsAway = max(0, resumedAt.timeIntervalSince(pausedAt))
    let desiredRewind = preferences.rewindSeconds(after: secondsAway)
    let bookDurationMilliseconds = Int64(
      (max(0, book.durationSeconds) * 1_000).rounded(.down)
    )
    let originalMilliseconds = min(max(0, positionMilliseconds), bookDurationMilliseconds)
    let desiredMilliseconds = Int64((desiredRewind * 1_000).rounded(.down))
    guard desiredMilliseconds > 0, originalMilliseconds > 0 else { return nil }

    let unclampedTarget = max(0, originalMilliseconds - desiredMilliseconds)
    let chapter = PlaybackTimeline.chapter(
      in: book,
      at: Double(originalMilliseconds) / 1_000
    )
    let chapterStart = chapter.map {
      Int64((max(0, $0.startSeconds) * 1_000).rounded(.down))
    }
    let crossesChapterStart = chapterStart.map { unclampedTarget < $0 } ?? false
    let clampedTarget: Int64
    if crossesChapterStart, let chapterStart {
      clampedTarget = chapterStart
    } else {
      clampedTarget = unclampedTarget
    }
    guard clampedTarget < originalMilliseconds else { return nil }

    return SmartRewindPlan(
      bookID: book.id,
      pausedAt: pausedAt,
      resumedAt: resumedAt,
      secondsAway: secondsAway,
      originalPositionMilliseconds: originalMilliseconds,
      targetPositionMilliseconds: clampedTarget,
      rewindMilliseconds: originalMilliseconds - clampedTarget,
      chapterStartMilliseconds: chapterStart,
      crossedRecentChapterStart: false,
      wasClampedToChapterStart: crossesChapterStart
    )
  }
}
