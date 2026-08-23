import CryptoKit
import Foundation

enum ImportFileValidity: Codable, Equatable, Sendable {
  case valid
  case corrupt(details: String?)
  case unsupported(format: String)
  case missing
  case checksumMismatch(expected: String, actual: String)
}

struct ImportFileAssessment: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var relativePath: String
  var filename: String
  var byteCount: Int64
  var checksumSHA256: String?
  var format: String?
  var validity: ImportFileValidity
}

struct ExistingMediaFingerprint: Codable, Equatable, Sendable {
  var checksumSHA256: String
  var bookID: UUID
  var assetID: UUID
  var filename: String
}

struct ImportStoragePreflight: Codable, Equatable, Sendable {
  var requiredCopyBytes: Int64
  var availableBytes: Int64
  var safetyMarginBytes: Int64

  var totalRequiredBytes: Int64 {
    let (total, overflow) = max(0, requiredCopyBytes).addingReportingOverflow(
      max(0, safetyMarginBytes)
    )
    return overflow ? .max : total
  }

  var hasSufficientSpace: Bool {
    max(0, availableBytes) >= totalRequiredBytes
  }
}

enum ImportRecoveryIssueCode: String, Codable, Equatable, Sendable {
  case insufficientStorage = "insufficient-storage"
  case duplicateInSelection = "duplicate-in-selection"
  case duplicateInLibrary = "duplicate-in-library"
  case corruptAudio = "corrupt-audio"
  case unsupportedFormat = "unsupported-format"
  case missingSource = "missing-source"
  case checksumMismatch = "checksum-mismatch"
}

enum ImportRemediationKind: String, Codable, Equatable, Sendable {
  case retryFile
  case removeFile
  case changeSelection
  case openExistingBook
  case freeStorage
  case cancelImport
}

struct ImportRemediation: Codable, Equatable, Sendable {
  var kind: ImportRemediationKind
  var fileID: UUID?
  var bookID: UUID?
}

struct ImportRecoveryIssue: Codable, Equatable, Sendable {
  var code: ImportRecoveryIssueCode
  var message: String
  var fileID: UUID?
  var affectedFilename: String?
  var sourceIsUnchanged: Bool
  var isRecoverable: Bool
  var requiredBytes: Int64?
  var availableBytes: Int64?
  var remediations: [ImportRemediation]
}

enum ImportFileDisposition: String, Codable, Equatable, Sendable {
  case accepted
  case duplicate
  case failed
}

struct ImportFileRecoveryStatus: Codable, Equatable, Sendable {
  var file: ImportFileAssessment
  var disposition: ImportFileDisposition
  var issue: ImportRecoveryIssue?
}

enum ImportRecoveryPhase: String, Codable, Equatable, Sendable {
  case ready
  case needsReview
  case failedRecoverable
  case failedTerminal
}

struct ImportRecoveryPlan: Codable, Equatable, Sendable {
  var phase: ImportRecoveryPhase
  var files: [ImportFileRecoveryStatus]
  var globalIssues: [ImportRecoveryIssue]

  var acceptedFileCount: Int { files.count { $0.disposition == .accepted } }
  var duplicateFileCount: Int { files.count { $0.disposition == .duplicate } }
  var failedFileCount: Int { files.count { $0.disposition == .failed } }
  var canContinueWithAcceptedFiles: Bool {
    phase != .failedRecoverable && phase != .failedTerminal && acceptedFileCount > 0
  }
}

enum ImportRecoveryPlanner {
  static func stableFileID(namespace: UUID, relativePath: String) -> UUID {
    let digest = SHA256.hash(data: Data(
      "\(namespace.uuidString.lowercased())\n\(relativePath)".utf8
    ))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    ))
  }

  static func assess(
    files: [ImportFileAssessment],
    existing: [ExistingMediaFingerprint],
    storage: ImportStoragePreflight? = nil
  ) -> ImportRecoveryPlan {
    let existingByChecksum = Dictionary(
      existing.map { (normalizedChecksum($0.checksumSHA256), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var firstFileByChecksum: [String: ImportFileAssessment] = [:]
    var statuses: [ImportFileRecoveryStatus] = []

    for file in files {
      if let issue = validityIssue(for: file) {
        statuses.append(ImportFileRecoveryStatus(
          file: file,
          disposition: .failed,
          issue: issue
        ))
        continue
      }
      let checksum = file.checksumSHA256.map(normalizedChecksum)
      if let checksum, !checksum.isEmpty, let match = existingByChecksum[checksum] {
        statuses.append(ImportFileRecoveryStatus(
          file: file,
          disposition: .duplicate,
          issue: duplicateLibraryIssue(for: file, match: match)
        ))
      } else if let checksum, !checksum.isEmpty,
        let first = firstFileByChecksum[checksum],
        filenamesIndicateDuplicate(file.filename, first.filename)
      {
        statuses.append(ImportFileRecoveryStatus(
          file: file,
          disposition: .duplicate,
          issue: duplicateSelectionIssue(for: file, first: first)
        ))
      } else {
        if let checksum, !checksum.isEmpty { firstFileByChecksum[checksum] = file }
        statuses.append(ImportFileRecoveryStatus(
          file: file,
          disposition: .accepted,
          issue: nil
        ))
      }
    }

    var globalIssues: [ImportRecoveryIssue] = []
    if let storage, !storage.hasSufficientSpace {
      globalIssues.append(ImportRecoveryIssue(
        code: .insufficientStorage,
        message: "This import needs \(storage.totalRequiredBytes) bytes, but only "
          + "\(max(0, storage.availableBytes)) bytes are available.",
        fileID: nil,
        affectedFilename: nil,
        sourceIsUnchanged: true,
        isRecoverable: true,
        requiredBytes: storage.totalRequiredBytes,
        availableBytes: max(0, storage.availableBytes),
        remediations: [
          ImportRemediation(kind: .freeStorage, fileID: nil, bookID: nil),
          ImportRemediation(kind: .changeSelection, fileID: nil, bookID: nil),
          ImportRemediation(kind: .cancelImport, fileID: nil, bookID: nil),
        ]
      ))
    }

    let phase: ImportRecoveryPhase
    let acceptedCount = statuses.count { $0.disposition == .accepted }
    let duplicates = statuses.count { $0.disposition == .duplicate }
    let fileIssues = statuses.compactMap(\.issue)
    if !globalIssues.isEmpty {
      phase = .failedRecoverable
    } else if fileIssues.isEmpty {
      phase = .ready
    } else if acceptedCount > 0 || duplicates > 0 {
      phase = .needsReview
    } else if fileIssues.contains(where: \.isRecoverable) {
      phase = .failedRecoverable
    } else {
      phase = .failedTerminal
    }
    return ImportRecoveryPlan(phase: phase, files: statuses, globalIssues: globalIssues)
  }

  private static func validityIssue(for file: ImportFileAssessment) -> ImportRecoveryIssue? {
    switch file.validity {
    case .valid:
      return nil
    case .corrupt(let details):
      return fileIssue(
        code: .corruptAudio,
        file: file,
        message: details.map { "\(file.filename) is corrupt: \($0)" }
          ?? "\(file.filename) could not be read as audio.",
        recoverable: true,
        actions: [.retryFile, .removeFile, .changeSelection]
      )
    case .unsupported(let format):
      return fileIssue(
        code: .unsupportedFormat,
        file: file,
        message: "\(file.filename) uses unsupported format \(format).",
        recoverable: false,
        actions: [.removeFile, .changeSelection]
      )
    case .missing:
      return fileIssue(
        code: .missingSource,
        file: file,
        message: "\(file.filename) is no longer available from its source.",
        recoverable: true,
        actions: [.retryFile, .removeFile, .changeSelection]
      )
    case .checksumMismatch:
      return fileIssue(
        code: .checksumMismatch,
        file: file,
        message: "\(file.filename) changed while it was being copied.",
        recoverable: true,
        actions: [.retryFile, .removeFile, .changeSelection]
      )
    }
  }

  private static func duplicateLibraryIssue(
    for file: ImportFileAssessment,
    match: ExistingMediaFingerprint
  ) -> ImportRecoveryIssue {
    ImportRecoveryIssue(
      code: .duplicateInLibrary,
      message: "\(file.filename) is already stored as \(match.filename).",
      fileID: file.id,
      affectedFilename: file.filename,
      sourceIsUnchanged: true,
      isRecoverable: false,
      requiredBytes: nil,
      availableBytes: nil,
      remediations: [
        ImportRemediation(kind: .openExistingBook, fileID: file.id, bookID: match.bookID),
        ImportRemediation(kind: .removeFile, fileID: file.id, bookID: nil),
        ImportRemediation(kind: .changeSelection, fileID: nil, bookID: nil),
      ]
    )
  }

  private static func duplicateSelectionIssue(
    for file: ImportFileAssessment,
    first: ImportFileAssessment
  ) -> ImportRecoveryIssue {
    ImportRecoveryIssue(
      code: .duplicateInSelection,
      message: "\(file.filename) duplicates selected file \(first.filename).",
      fileID: file.id,
      affectedFilename: file.filename,
      sourceIsUnchanged: true,
      isRecoverable: false,
      requiredBytes: nil,
      availableBytes: nil,
      remediations: [
        ImportRemediation(kind: .removeFile, fileID: file.id, bookID: nil),
        ImportRemediation(kind: .changeSelection, fileID: nil, bookID: nil),
      ]
    )
  }

  private static func fileIssue(
    code: ImportRecoveryIssueCode,
    file: ImportFileAssessment,
    message: String,
    recoverable: Bool,
    actions: [ImportRemediationKind]
  ) -> ImportRecoveryIssue {
    ImportRecoveryIssue(
      code: code,
      message: message,
      fileID: file.id,
      affectedFilename: file.filename,
      sourceIsUnchanged: true,
      isRecoverable: recoverable,
      requiredBytes: nil,
      availableBytes: nil,
      remediations: actions.map {
        ImportRemediation(kind: $0, fileID: $0 == .changeSelection ? nil : file.id, bookID: nil)
      }
    )
  }

  private static func normalizedChecksum(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// A checksum match alone is not enough for audiobook parts: publishers can
  /// legitimately repeat short intros, silence, or chapter audio. Selection
  /// duplicates require a filename signal as well, while library duplicates
  /// remain exact checksum matches because the managed copy already exists.
  private static func filenamesIndicateDuplicate(_ lhs: String, _ rhs: String) -> Bool {
    let normalized: (String) -> String = {
      URL(filePath: $0).deletingPathExtension().lastPathComponent
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        .lowercased()
    }
    let left = normalized(lhs)
    let right = normalized(rhs)
    if left == right { return true }
    let copySignals = ["copy", "duplicate", "duplicated", "dup", "copie", "copia"]
    return copySignals.contains { signal in
      left.split(whereSeparator: { !$0.isLetter }).contains(Substring(signal))
        || right.split(whereSeparator: { !$0.isLetter }).contains(Substring(signal))
    }
  }
}

enum StorageScope: Codable, Equatable, Sendable {
  case managedBook(UUID)
  case stagingJob(UUID)
  case trashTransaction(UUID)
  case database
}

struct StorageManifestEntry: Codable, Equatable, Sendable {
  var relativePath: String
  var byteCount: Int64
}

struct StorageManifest: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var scope: StorageScope
  var entries: [StorageManifestEntry]
  var createdAt: Date

  var byteCount: Int64 {
    entries.reduce(0) { total, entry in
      let (sum, overflow) = total.addingReportingOverflow(entry.byteCount)
      return overflow ? .max : sum
    }
  }
  var fileCount: Int { entries.count }

  init(
    id: UUID,
    scope: StorageScope,
    entries: [StorageManifestEntry],
    createdAt: Date
  ) throws {
    var paths: Set<String> = []
    for entry in entries {
      guard entry.byteCount >= 0 else { throw StorageInventoryError.negativeByteCount }
      guard Self.isSafeRelativePath(entry.relativePath) else {
        throw StorageInventoryError.unsafeRelativePath(entry.relativePath)
      }
      guard paths.insert(entry.relativePath).inserted else {
        throw StorageInventoryError.duplicateRelativePath(entry.relativePath)
      }
    }
    self.id = id
    self.scope = scope
    self.entries = entries
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, scope, entries, createdAt
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let id = try values.decode(UUID.self, forKey: .id)
    let scope = try values.decode(StorageScope.self, forKey: .scope)
    let entries = try values.decode([StorageManifestEntry].self, forKey: .entries)
    let createdAt = try values.decode(Date.self, forKey: .createdAt)
    do {
      try self.init(id: id, scope: scope, entries: entries, createdAt: createdAt)
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .entries,
        in: values,
        debugDescription: "The storage manifest contains invalid entries: "
          + error.localizedDescription
      )
    }
  }

  private static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else { return false }
    if path.count >= 3 {
      let characters = Array(path.prefix(3))
      if characters[1] == ":", characters[2] == "/" || characters[2] == "\\" { return false }
    }
    let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
    return !components.isEmpty && !components.contains(where: { $0 == "." || $0 == ".." })
  }
}

enum StorageInventoryError: LocalizedError, Equatable, Sendable {
  case negativeByteCount
  case unsafeRelativePath(String)
  case duplicateRelativePath(String)

  var errorDescription: String? {
    switch self {
    case .negativeByteCount: "Storage byte counts cannot be negative."
    case .unsafeRelativePath(let path): "Storage path \(path) is not safely relative."
    case .duplicateRelativePath(let path): "Storage path \(path) appears more than once."
    }
  }
}

struct BookStorageSummary: Codable, Equatable, Sendable {
  var bookID: UUID
  var byteCount: Int64
  var fileCount: Int
}

struct StorageSummary: Codable, Equatable, Sendable {
  var managedMediaBytes: Int64
  var stagingBytes: Int64
  var trashBytes: Int64
  var databaseBytes: Int64
  var availableBytes: Int64?
  var perBook: [BookStorageSummary]

  var usedBytes: Int64 {
    saturatingAdd(
      saturatingAdd(managedMediaBytes, stagingBytes),
      saturatingAdd(trashBytes, databaseBytes)
    )
  }
  var reclaimableBytes: Int64 { saturatingAdd(stagingBytes, trashBytes) }
}

struct StorageInventorySnapshot: Codable, Equatable, Sendable {
  var manifests: [StorageManifest]
  var availableBytes: Int64?
}

enum StorageSummaryPlanner {
  static func summarize(
    manifests: [StorageManifest],
    availableBytes: Int64?
  ) -> StorageSummary {
    var managed: Int64 = 0
    var staging: Int64 = 0
    var trash: Int64 = 0
    var database: Int64 = 0
    var perBook: [UUID: BookStorageSummary] = [:]
    for manifest in manifests {
      switch manifest.scope {
      case .managedBook(let bookID):
        managed = saturatingAdd(managed, manifest.byteCount)
        var summary = perBook[bookID] ?? BookStorageSummary(
          bookID: bookID,
          byteCount: 0,
          fileCount: 0
        )
        summary.byteCount = saturatingAdd(summary.byteCount, manifest.byteCount)
        summary.fileCount = saturatingAdd(summary.fileCount, manifest.fileCount)
        perBook[bookID] = summary
      case .stagingJob:
        staging = saturatingAdd(staging, manifest.byteCount)
      case .trashTransaction:
        trash = saturatingAdd(trash, manifest.byteCount)
      case .database:
        database = saturatingAdd(database, manifest.byteCount)
      }
    }
    return StorageSummary(
      managedMediaBytes: managed,
      stagingBytes: staging,
      trashBytes: trash,
      databaseBytes: database,
      availableBytes: availableBytes.map { max(0, $0) },
      perBook: perBook.values.sorted { $0.bookID.uuidString < $1.bookID.uuidString }
    )
  }
}

private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
  let (sum, overflow) = lhs.addingReportingOverflow(rhs)
  return overflow ? .max : sum
}

private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
  let (sum, overflow) = lhs.addingReportingOverflow(rhs)
  return overflow ? .max : sum
}
