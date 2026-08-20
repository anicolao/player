import Foundation

enum SleepTimerPreset: Int, Codable, CaseIterable, Equatable, Sendable {
  case ten = 10
  case fifteen = 15
  case thirty = 30
  case fortyFive = 45
  case sixty = 60

  var durationSeconds: TimeInterval { TimeInterval(rawValue * 60) }
}

enum SleepTimerSelection: Codable, Equatable, Sendable {
  case preset(SleepTimerPreset)
  case custom(durationSeconds: TimeInterval)
  case endOfChapter
  case endOfTrack

  var durationSeconds: TimeInterval? {
    switch self {
    case .preset(let preset): preset.durationSeconds
    case .custom(let durationSeconds): durationSeconds
    case .endOfChapter, .endOfTrack: nil
    }
  }

  var isValid: Bool {
    guard let durationSeconds else { return true }
    return durationSeconds.isFinite && durationSeconds > 0
  }

  var displayLabel: String {
    switch self {
    case .preset(let preset): "\(preset.rawValue) min"
    case .custom(let seconds): "\(max(1, Int(ceil(seconds / 60)))) min custom"
    case .endOfChapter: "End of Chapter"
    case .endOfTrack: "End of Track"
    }
  }
}

enum SleepTimerPhase: String, Codable, Equatable, Sendable {
  case active
  case fading
}

struct ActiveSleepTimer: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var bookID: UUID
  var selection: SleepTimerSelection
  var fadeEnabled: Bool
  var startedAt: Date
  var deadline: Date?
  var boundaryPositionMilliseconds: Int64?
  var startedPositionMilliseconds: Int64
  var phase: SleepTimerPhase

  var fadeDurationSeconds: TimeInterval { fadeEnabled ? 5 : 0 }
}

enum SleepTimerHistoryStatus: String, Codable, Equatable, Sendable {
  case completed
  case cancelled
  case replaced
}

struct SleepTimerHistoryEntry: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var timerID: UUID
  var bookID: UUID
  var selection: SleepTimerSelection
  var fadeEnabled: Bool
  var startedAt: Date
  var expectedDeadline: Date?
  var expectedBoundaryPositionMilliseconds: Int64?
  var actualStopPositionMilliseconds: Int64
  var completedAt: Date
  var status: SleepTimerHistoryStatus
  var positionEventID: UUID?
  var resumeContextUsedAt: Date?

  var actualStopSeconds: Double { Double(actualStopPositionMilliseconds) / 1_000 }
  var resumeContextExpiresAt: Date { completedAt.addingTimeInterval(10 * 60) }
}

struct SleepTimerProjection: Codable, Equatable, Sendable {
  var timerID: UUID
  var selectionLabel: String
  var remainingSeconds: TimeInterval?
  var targetPositionMilliseconds: Int64?
  var fadeEnabled: Bool
  var phase: SleepTimerPhase
}

struct SleepResumeContext: Codable, Equatable, Sendable {
  var historyID: UUID
  var bookID: UUID
  var stoppedPositionMilliseconds: Int64
  var availableUntil: Date
}

enum SleepTimerError: LocalizedError, Equatable, Sendable {
  case noCurrentBook
  case invalidDuration
  case missingChapterBoundary
  case missingTrackBoundary
  case noActiveTimer
  case noResumeContext

  var errorDescription: String? {
    switch self {
    case .noCurrentBook: "Open a book before starting a sleep timer."
    case .invalidDuration: "Choose a sleep duration greater than zero."
    case .missingChapterBoundary: "The current chapter has no usable end boundary."
    case .missingTrackBoundary: "The current audio track has no usable end boundary."
    case .noActiveTimer: "There is no active sleep timer."
    case .noResumeContext: "There is no recent sleep stop to resume with context."
    }
  }
}

enum SleepTimerPlanner {
  static func makeTimer(
    id: UUID,
    book: Book,
    selection: SleepTimerSelection,
    fadeEnabled: Bool,
    currentPositionSeconds: Double,
    now: Date
  ) throws -> ActiveSleepTimer {
    guard selection.isValid else { throw SleepTimerError.invalidDuration }
    let current = clampedPosition(currentPositionSeconds, in: book)
    let boundary: Double?
    switch selection {
    case .preset, .custom:
      boundary = nil
    case .endOfChapter:
      guard let chapter = PlaybackTimeline.chapter(in: book, at: current),
        chapter.endSeconds > current
      else { throw SleepTimerError.missingChapterBoundary }
      boundary = chapter.endSeconds
    case .endOfTrack:
      guard let location = PlaybackTimeline.location(in: book, at: current) else {
        throw SleepTimerError.missingTrackBoundary
      }
      let end = min(
        book.durationSeconds,
        location.asset.timelineStartSeconds + location.asset.durationSeconds
      )
      guard end > current else { throw SleepTimerError.missingTrackBoundary }
      boundary = end
    }
    return ActiveSleepTimer(
      id: id,
      bookID: book.id,
      selection: selection,
      fadeEnabled: fadeEnabled,
      startedAt: now,
      deadline: selection.durationSeconds.map { now.addingTimeInterval($0) },
      boundaryPositionMilliseconds: boundary.map {
        Int64(($0 * 1_000).rounded(.down))
      },
      startedPositionMilliseconds: Int64((current * 1_000).rounded(.down)),
      phase: .active
    )
  }

  static func shouldBeginFade(
    _ timer: ActiveSleepTimer,
    now: Date,
    currentPositionSeconds: Double,
    playbackRate: Double = 1
  ) -> Bool {
    let fadeLeadSeconds = timer.fadeDurationSeconds
    if let deadline = timer.deadline,
      deadline.addingTimeInterval(-fadeLeadSeconds) <= now
    {
      return true
    }
    if let boundary = timer.boundaryPositionMilliseconds {
      let current = Int64((max(0, currentPositionSeconds) * 1_000).rounded(.down))
      let fadeLeadMilliseconds = Int64(
        (fadeLeadSeconds * max(0.5, playbackRate) * 1_000).rounded(.down)
      )
      return current >= max(timer.startedPositionMilliseconds, boundary - fadeLeadMilliseconds)
    }
    return false
  }

  static func hasReachedStopBoundary(
    _ timer: ActiveSleepTimer,
    now: Date,
    currentPositionSeconds: Double
  ) -> Bool {
    if let deadline = timer.deadline, deadline <= now { return true }
    if let boundary = timer.boundaryPositionMilliseconds {
      let current = Int64((max(0, currentPositionSeconds) * 1_000).rounded(.down))
      return current >= boundary
    }
    return false
  }

  static func projection(
    for timer: ActiveSleepTimer,
    now: Date,
    currentPositionSeconds: Double,
    playbackRate: Double
  ) -> SleepTimerProjection {
    let remaining: TimeInterval?
    if let deadline = timer.deadline {
      remaining = max(0, deadline.timeIntervalSince(now))
    } else if let boundary = timer.boundaryPositionMilliseconds {
      let currentMilliseconds = Int64(
        (max(0, currentPositionSeconds) * 1_000).rounded(.down)
      )
      let bookSeconds = Double(max(0, boundary - currentMilliseconds)) / 1_000
      remaining = bookSeconds / max(0.5, playbackRate)
    } else {
      remaining = nil
    }
    return SleepTimerProjection(
      timerID: timer.id,
      selectionLabel: timer.selection.displayLabel,
      remainingSeconds: remaining,
      targetPositionMilliseconds: timer.boundaryPositionMilliseconds,
      fadeEnabled: timer.fadeEnabled,
      phase: timer.phase
    )
  }

  /// Builds the explicitly requested "Resume with context" rewind from a
  /// completed sleep stop. It deliberately guarantees the short rewind tier
  /// without manufacturing a pause journal event, so ordinary resume remains
  /// independent from sleep history.
  static func resumePlan(
    from history: SleepTimerHistoryEntry,
    book: Book,
    resumedAt: Date,
    preferences: SmartRewindPreferences
  ) -> SmartRewindPlan? {
    guard history.status == .completed, history.bookID == book.id else { return nil }
    let actualAway = max(0, resumedAt.timeIntervalSince(history.completedAt))
    let contextualAway = max(actualAway, preferences.minimumAwaySeconds)
    return SmartRewindPlanner.plan(
      for: book,
      positionMilliseconds: history.actualStopPositionMilliseconds,
      pausedAt: resumedAt.addingTimeInterval(-contextualAway),
      resumedAt: resumedAt,
      preferences: preferences
    )
  }

  private static func clampedPosition(_ seconds: Double, in book: Book) -> Double {
    min(max(seconds.isFinite ? seconds : 0, 0), book.durationSeconds)
  }
}
