import Foundation

enum PlayerErrorDomain: String, Equatable, Sendable {
  case importFlow
  case playback
  case transportPreferences
  case metadata
  case bookmark
  case storage
  case backup
  case recovery
  case sleepTimer
  case smartRewind
  case monetization
  case library
  case diagnostics
}

enum PlayerErrorRecoveryAction: String, Equatable, Sendable {
  case acknowledge
  case retry
  case reviewInbox
  case openSettings
  case contactSupport
}

enum PlayerErrorPresentationOwner: String, Equatable, Sendable {
  case root
  case transportPreferences
  case computerReceiver
  case metadataEditor
  case sleepTimer
  case backupSettings
  case startupRecovery
  case supportDiagnostics
  case fullUnlock
}

struct PlayerPresentationError: Identifiable, Equatable, Sendable {
  let id: UUID
  let domain: PlayerErrorDomain
  let owner: PlayerErrorPresentationOwner
  let title: String
  let message: String
  let recoveryAction: PlayerErrorRecoveryAction
  let diagnosticDetail: String?

  static func presenting(
    _ error: any Error,
    in domain: PlayerErrorDomain,
    owner: PlayerErrorPresentationOwner? = nil,
    recoveryAction: PlayerErrorRecoveryAction? = nil
  ) -> PlayerPresentationError {
    let diagnostic = diagnosticDescription(for: error)
    let resolvedRecoveryAction = recoveryAction
      ?? inferredRecoveryAction(for: error, in: domain)
    let message = userMessage(for: error, in: domain)
    return presenting(
      message,
      in: domain,
      owner: owner,
      recoveryAction: resolvedRecoveryAction,
      diagnosticDetail: diagnostic
    )
  }

  static func presenting(
    _ message: String,
    in domain: PlayerErrorDomain,
    owner: PlayerErrorPresentationOwner? = nil,
    recoveryAction: PlayerErrorRecoveryAction? = nil,
    diagnosticDetail: String? = nil
  ) -> PlayerPresentationError {
    PlayerPresentationError(
      id: UUID(),
      domain: domain,
      owner: owner ?? domain.defaultOwner,
      title: domain.title,
      message: message,
      recoveryAction: recoveryAction ?? domain.defaultRecoveryAction,
      diagnosticDetail: diagnosticDetail
    )
  }

  private static func diagnosticDescription(for error: any Error) -> String {
    let nsError = error as NSError
    if nsError.domain == NSOSStatusErrorDomain {
      return "OSStatus \(nsError.code)"
    }
    return "\(nsError.domain) \(nsError.code)"
  }

  private static func userMessage(
    for error: any Error,
    in domain: PlayerErrorDomain
  ) -> String {
    let nsError = error as NSError
    if domain == .playback && nsError.domain == NSOSStatusErrorDomain {
      return
        "Bookshelf couldn’t configure audio playback. Restart the app; if this continues, export Support Diagnostics and contact support."
    }
    if domain == .transportPreferences,
      nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain
    {
      return
        "Bookshelf couldn’t save these playback settings. Check that your device has free space, then try again. Your current settings are unchanged."
    }
    if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain {
      return
        "Bookshelf couldn’t access a required file. Check that it is still available and that your device has free space, then try again."
    }
    if let metadataError = error as? MetadataRepairError,
      case .transactionNotApplied = metadataError
    {
      return "That edit can no longer be undone. Reopen the book details to see the current version."
    }
    if let bookmarkError = error as? BookmarkError {
      switch bookmarkError {
      case .missingBookmark, .noDeletionToUndo:
        return "That bookmark is no longer available. Reopen the bookmark list to refresh it."
      case .noCurrentBook:
        return "Open an audiobook before adding a bookmark."
      case .missingTimeline:
        return "This audiobook has no playable location for that bookmark."
      case .invalidLabel:
        return "Enter a bookmark label, then try again."
      }
    }
    return error.localizedDescription
  }

  private static func inferredRecoveryAction(
    for error: any Error,
    in domain: PlayerErrorDomain
  ) -> PlayerErrorRecoveryAction? {
    let nsError = error as NSError
    if domain == .playback && nsError.domain == NSOSStatusErrorDomain {
      return .contactSupport
    }
    if let metadataError = error as? MetadataRepairError,
      case .transactionNotApplied = metadataError
    {
      return .acknowledge
    }
    if let bookmarkError = error as? BookmarkError {
      switch bookmarkError {
      case .invalidLabel: return .retry
      case .noCurrentBook, .missingTimeline, .missingBookmark, .noDeletionToUndo:
        return .acknowledge
      }
    }
    if error is LibraryOrganizationError { return .acknowledge }
    if error is TransportPreferencesError { return .openSettings }
    if let sleepError = error as? SleepTimerError {
      switch sleepError {
      case .invalidDuration, .missingChapterBoundary, .missingTrackBoundary: return .retry
      case .noCurrentBook, .noActiveTimer, .noResumeContext: return .acknowledge
      }
    }
    if let rewindError = error as? SmartRewindError {
      switch rewindError {
      case .invalidPreferences: return .openSettings
      case .noPauseCheckpoint, .noRewindToUndo: return .acknowledge
      }
    }
    return nil
  }
}

extension PlayerErrorDomain {
  fileprivate var title: String {
    switch self {
    case .importFlow: "Couldn’t Import Audiobook"
    case .playback: "Playback Isn’t Available"
    case .transportPreferences: "Couldn’t Save Playback Settings"
    case .metadata: "Couldn’t Save Details"
    case .bookmark: "Couldn’t Update Bookmark"
    case .storage: "Couldn’t Update Storage"
    case .backup: "Couldn’t Complete Backup"
    case .recovery: "Couldn’t Restore Library"
    case .sleepTimer: "Couldn’t Update Sleep Timer"
    case .smartRewind: "Couldn’t Update Smart Rewind"
    case .monetization: "Couldn’t Update Purchase"
    case .library: "Couldn’t Update Library"
    case .diagnostics: "Couldn’t Create Support Bundle"
    }
  }

  fileprivate var defaultRecoveryAction: PlayerErrorRecoveryAction {
    switch self {
    case .importFlow: .reviewInbox
    case .playback, .transportPreferences, .metadata, .bookmark, .storage, .backup, .recovery, .sleepTimer,
      .smartRewind, .monetization, .library, .diagnostics: .retry
    }
  }

  fileprivate var defaultOwner: PlayerErrorPresentationOwner {
    switch self {
    case .transportPreferences: .transportPreferences
    case .metadata: .metadataEditor
    case .sleepTimer: .sleepTimer
    case .backup: .backupSettings
    case .recovery: .startupRecovery
    case .monetization: .fullUnlock
    case .diagnostics: .supportDiagnostics
    case .importFlow, .playback, .bookmark, .storage, .smartRewind, .library: .root
    }
  }
}
