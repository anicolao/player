import Foundation

enum StartupRecoveryIssue: String, Codable, Equatable, Sendable {
  case unreadableLibrary = "unreadable-library"
  case newerLibraryVersion = "newer-library-version"
  case storageUnavailable = "storage-unavailable"
}

struct StartupRecoveryStatus: Codable, Equatable, Sendable {
  var issue: StartupRecoveryIssue
  var validAutomaticBackupCount: Int
  var invalidAutomaticBackupCount: Int

  var canRestoreAutomaticBackup: Bool { validAutomaticBackupCount > 0 }
}

struct StartupStorageReconciliation: Equatable, Sendable {
  var library: LibrarySnapshot
  var quarantinedManagedBookCount: Int
  var quarantinedStagingJobCount: Int
  var quarantinedTrashTransactionCount: Int

  static func unchanged(_ library: LibrarySnapshot) -> StartupStorageReconciliation {
    StartupStorageReconciliation(
      library: library,
      quarantinedManagedBookCount: 0,
      quarantinedStagingJobCount: 0,
      quarantinedTrashTransactionCount: 0
    )
  }

  var quarantinedItemCount: Int {
    quarantinedManagedBookCount + quarantinedStagingJobCount
      + quarantinedTrashTransactionCount
  }
}

struct PreparedSupportBundle: Equatable, Sendable, Identifiable {
  var url: URL
  var byteCount: Int64

  var id: URL { url }
}

struct SanitizedSupportReport: Codable, Equatable, Sendable {
  static let currentFormatVersion = 1

  var formatVersion: Int
  var createdAt: Date
  var appVersion: String
  var appBuild: String
  var librarySchemaVersion: Int
  var bookCount: Int
  var audioAssetCount: Int
  var pendingImportCount: Int
  var failedImportCount: Int
  var collectionCount: Int
  var bookmarkCount: Int
  var validAutomaticBackupCount: Int
  var startupRecoveryIssue: StartupRecoveryIssue?
  var quarantinedManagedBookCount: Int
  var quarantinedStagingJobCount: Int
  var quarantinedTrashTransactionCount: Int
  var localFeaturesRequireInternet: Bool
}

protocol SupportDiagnosticsManaging: Sendable {
  func prepareBundle(
    library: LibrarySnapshot,
    recovery: StartupRecoveryStatus?,
    reconciliation: StartupStorageReconciliation?,
    automaticBackupCount: Int
  ) async throws -> PreparedSupportBundle
  func discardPreparedBundle(_ bundle: PreparedSupportBundle) async
}

actor DisabledSupportDiagnosticsManager: SupportDiagnosticsManaging {
  func prepareBundle(
    library: LibrarySnapshot,
    recovery: StartupRecoveryStatus?,
    reconciliation: StartupStorageReconciliation?,
    automaticBackupCount: Int
  ) throws -> PreparedSupportBundle {
    throw PlayerCoreError.fileOperation("Support diagnostics are unavailable in this environment.")
  }

  func discardPreparedBundle(_ bundle: PreparedSupportBundle) {}
}

actor FileSystemSupportDiagnosticsManager: SupportDiagnosticsManaging {
  private let rootURL: URL
  private let fileManager: FileManager
  private let clock: any PlayerClock
  private let appVersion: String
  private let appBuild: String

  init(
    rootURL: URL,
    fileManager: FileManager = .default,
    clock: any PlayerClock = SystemPlayerClock(),
    appVersion: String = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "unknown",
    appBuild: String = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "unknown"
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
    self.clock = clock
    self.appVersion = appVersion
    self.appBuild = appBuild
    try? fileManager.removeItem(
      at: rootURL.appending(path: "SupportExports", directoryHint: .isDirectory)
    )
  }

  func prepareBundle(
    library: LibrarySnapshot,
    recovery: StartupRecoveryStatus?,
    reconciliation: StartupStorageReconciliation?,
    automaticBackupCount: Int
  ) throws -> PreparedSupportBundle {
    let directory = rootURL.appending(path: "SupportExports", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(
      path: "Player Support \(Self.filenameTimestamp(clock.now())).playersupport"
    )
    let report = SanitizedSupportReport(
      formatVersion: SanitizedSupportReport.currentFormatVersion,
      createdAt: clock.now(),
      appVersion: appVersion,
      appBuild: appBuild,
      librarySchemaVersion: CodableLibraryStore.currentSchemaVersion,
      bookCount: library.books.count,
      audioAssetCount: library.books.reduce(0) { $0 + $1.assets.count },
      pendingImportCount: library.importJobs.count {
        ![.committed, .cancelled].contains($0.phase)
      },
      failedImportCount: library.importJobs.count { $0.phase == .failed },
      collectionCount: library.collections.count,
      bookmarkCount: library.bookmarks.count,
      validAutomaticBackupCount: automaticBackupCount,
      startupRecoveryIssue: recovery?.issue,
      quarantinedManagedBookCount: reconciliation?.quarantinedManagedBookCount ?? 0,
      quarantinedStagingJobCount: reconciliation?.quarantinedStagingJobCount ?? 0,
      quarantinedTrashTransactionCount:
        reconciliation?.quarantinedTrashTransactionCount ?? 0,
      localFeaturesRequireInternet: false
    )
    let data = try JSONEncoder.playerEncoder.encode(report)
    try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    return PreparedSupportBundle(url: url, byteCount: Int64(data.count))
  }

  func discardPreparedBundle(_ bundle: PreparedSupportBundle) {
    let requiredPrefix =
      rootURL.appending(
        path: "SupportExports",
        directoryHint: .isDirectory
      ).standardizedFileURL.path + "/"
    guard bundle.url.standardizedFileURL.path.hasPrefix(requiredPrefix) else { return }
    try? fileManager.removeItem(at: bundle.url)
  }

  private static func filenameTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: date)
  }
}
