import CryptoKit
import Foundation

enum PortableBackupMode: String, Codable, Equatable, Sendable {
  case metadataOnly = "metadata-only"
  case includingMedia = "including-media"
}

struct PortableBackupContentPolicy: Codable, Equatable, Sendable {
  var mode: PortableBackupMode
  var includesArtwork: Bool

  static let metadataOnly = PortableBackupContentPolicy(
    mode: .metadataOnly,
    includesArtwork: true
  )
  static let includingMedia = PortableBackupContentPolicy(
    mode: .includingMedia,
    includesArtwork: true
  )
}

enum PortableBackupEntryKind: String, Codable, Equatable, Sendable {
  case libraryDatabase = "library-database"
  case artwork
  case media
}

struct PortableBackupEntry: Codable, Equatable, Identifiable, Sendable {
  var id: String { relativePath }
  var kind: PortableBackupEntryKind
  var relativePath: String
  var byteCount: Int64
  var checksumSHA256: String
  var bookID: UUID?
  var assetID: UUID?

  init(
    kind: PortableBackupEntryKind,
    relativePath: String,
    byteCount: Int64,
    checksumSHA256: String,
    bookID: UUID? = nil,
    assetID: UUID? = nil
  ) throws {
    guard PortableBackupPath.isSafe(relativePath) else {
      throw PortableBackupError.unsafePath(relativePath)
    }
    guard byteCount >= 0 else { throw PortableBackupError.negativeByteCount(relativePath) }
    let checksum = checksumSHA256.lowercased()
    guard BackupChecksum.isValidSHA256(checksum) else {
      throw PortableBackupError.invalidChecksum(relativePath)
    }
    switch kind {
    case .libraryDatabase:
      guard bookID == nil, assetID == nil else {
        throw PortableBackupError.invalidEntryAssociation(relativePath)
      }
    case .artwork:
      guard bookID != nil, assetID == nil else {
        throw PortableBackupError.invalidEntryAssociation(relativePath)
      }
    case .media:
      guard bookID != nil, assetID != nil else {
        throw PortableBackupError.invalidEntryAssociation(relativePath)
      }
    }
    self.kind = kind
    self.relativePath = relativePath
    self.byteCount = byteCount
    self.checksumSHA256 = checksum
    self.bookID = bookID
    self.assetID = assetID
  }

  private enum CodingKeys: String, CodingKey {
    case kind, relativePath, byteCount, checksumSHA256, bookID, assetID
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        kind: values.decode(PortableBackupEntryKind.self, forKey: .kind),
        relativePath: values.decode(String.self, forKey: .relativePath),
        byteCount: values.decode(Int64.self, forKey: .byteCount),
        checksumSHA256: values.decode(String.self, forKey: .checksumSHA256),
        bookID: values.decodeIfPresent(UUID.self, forKey: .bookID),
        assetID: values.decodeIfPresent(UUID.self, forKey: .assetID)
      )
    } catch let error as DecodingError {
      throw error
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .relativePath,
        in: values,
        debugDescription: "Invalid portable backup entry: \(error.localizedDescription)"
      )
    }
  }
}

struct PortableBackupManifest: Codable, Equatable, Sendable {
  static let formatIdentifier = "com.spnss.player.portable-backup"
  static let currentFormatVersion = 1
  static let currentReaderVersion = 1

  var identifier: String
  var formatVersion: Int
  var minimumReaderVersion: Int
  var librarySchemaVersion: Int
  var createdAt: Date
  var policy: PortableBackupContentPolicy
  var entries: [PortableBackupEntry]

  var totalPayloadBytes: Int64 {
    entries.reduce(0) { BackupSaturating.add($0, $1.byteCount) }
  }

  /// A stable fingerprint of the manifest's semantic contents. This does not
  /// depend on JSON key order, encoder date settings, or the caller's original
  /// entry order.
  var canonicalFingerprintSHA256: String {
    BackupChecksum.sha256(PortableBackupCanonical.manifestData(self))
  }

  var libraryEntry: PortableBackupEntry {
    // Structural validation guarantees exactly one database payload.
    entries.first(where: { $0.kind == .libraryDatabase })!
  }

  init(
    identifier: String = Self.formatIdentifier,
    formatVersion: Int = Self.currentFormatVersion,
    minimumReaderVersion: Int = Self.currentReaderVersion,
    librarySchemaVersion: Int,
    createdAt: Date,
    policy: PortableBackupContentPolicy,
    entries: [PortableBackupEntry]
  ) throws {
    guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PortableBackupError.invalidFormatIdentifier(identifier)
    }
    guard formatVersion > 0, minimumReaderVersion > 0 else {
      throw PortableBackupError.invalidManifestVersion(formatVersion)
    }
    guard librarySchemaVersion > 0 else {
      throw PortableBackupError.unsupportedLibrarySchema(librarySchemaVersion)
    }
    guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
      throw PortableBackupError.invalidTimestamp
    }
    let libraryEntries = entries.filter { $0.kind == .libraryDatabase }
    guard libraryEntries.count == 1 else {
      throw libraryEntries.isEmpty
        ? PortableBackupError.missingLibraryPayload
        : PortableBackupError.multipleLibraryPayloads
    }
    var canonicalPaths: Set<String> = []
    for entry in entries {
      let key = PortableBackupPath.collisionKey(entry.relativePath)
      guard canonicalPaths.insert(key).inserted else {
        throw PortableBackupError.duplicatePath(entry.relativePath)
      }
      if policy.mode == .metadataOnly, entry.kind == .media {
        throw PortableBackupError.policyDisallowsEntry(entry.relativePath)
      }
      if !policy.includesArtwork, entry.kind == .artwork {
        throw PortableBackupError.policyDisallowsEntry(entry.relativePath)
      }
    }
    self.identifier = identifier
    self.formatVersion = formatVersion
    self.minimumReaderVersion = minimumReaderVersion
    self.librarySchemaVersion = librarySchemaVersion
    self.createdAt = createdAt
    self.policy = policy
    self.entries = entries.sorted { $0.relativePath < $1.relativePath }
  }

  private enum CodingKeys: String, CodingKey {
    case identifier, formatVersion, minimumReaderVersion, librarySchemaVersion
    case createdAt, policy, entries
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        identifier: values.decode(String.self, forKey: .identifier),
        formatVersion: values.decode(Int.self, forKey: .formatVersion),
        minimumReaderVersion: values.decode(Int.self, forKey: .minimumReaderVersion),
        librarySchemaVersion: values.decode(Int.self, forKey: .librarySchemaVersion),
        createdAt: values.decode(Date.self, forKey: .createdAt),
        policy: values.decode(PortableBackupContentPolicy.self, forKey: .policy),
        entries: values.decode([PortableBackupEntry].self, forKey: .entries)
      )
    } catch let error as DecodingError {
      throw error
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .entries,
        in: values,
        debugDescription: "Invalid portable backup manifest: \(error.localizedDescription)"
      )
    }
  }
}

enum ObservedBackupFileType: String, Codable, Equatable, Sendable {
  case regular
  case directory
  case symbolicLink
  case other
}

struct ObservedBackupFile: Codable, Equatable, Sendable {
  var relativePath: String
  var byteCount: Int64
  var checksumSHA256: String?
  var fileType: ObservedBackupFileType

  init(
    relativePath: String,
    byteCount: Int64,
    checksumSHA256: String?,
    fileType: ObservedBackupFileType = .regular
  ) throws {
    guard PortableBackupPath.isSafe(relativePath) else {
      throw PortableBackupError.unsafePath(relativePath)
    }
    guard byteCount >= 0 else { throw PortableBackupError.negativeByteCount(relativePath) }
    let checksum = checksumSHA256?.lowercased()
    if let checksum, !BackupChecksum.isValidSHA256(checksum) {
      throw PortableBackupError.invalidChecksum(relativePath)
    }
    self.relativePath = relativePath
    self.byteCount = byteCount
    self.checksumSHA256 = checksum
    self.fileType = fileType
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath, byteCount, checksumSHA256, fileType
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        relativePath: values.decode(String.self, forKey: .relativePath),
        byteCount: values.decode(Int64.self, forKey: .byteCount),
        checksumSHA256: values.decodeIfPresent(String.self, forKey: .checksumSHA256),
        fileType: values.decode(ObservedBackupFileType.self, forKey: .fileType)
      )
    } catch let error as DecodingError {
      throw error
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .relativePath,
        in: values,
        debugDescription: "Invalid observed backup file: \(error.localizedDescription)"
      )
    }
  }
}

struct PortableBackupValidationPolicy: Equatable, Sendable {
  var supportedFormatVersions: ClosedRange<Int>
  var supportedLibrarySchemaVersions: ClosedRange<Int>
  var currentLibrarySchemaVersion: Int
  var maximumEntryCount: Int
  var maximumEntryBytes: Int64
  var maximumTotalBytes: Int64

  static func player(currentLibrarySchemaVersion: Int) -> PortableBackupValidationPolicy {
    PortableBackupValidationPolicy(
      supportedFormatVersions: 1...PortableBackupManifest.currentFormatVersion,
      supportedLibrarySchemaVersions: 1...currentLibrarySchemaVersion,
      currentLibrarySchemaVersion: currentLibrarySchemaVersion,
      maximumEntryCount: 100_000,
      maximumEntryBytes: 1_099_511_627_776,
      maximumTotalBytes: 4_398_046_511_104
    )
  }
}

enum BackupLibrarySchemaAction: Codable, Equatable, Sendable {
  case direct(version: Int)
  case migrate(from: Int, to: Int)
}

enum PortableBackupRestoreMode: String, Codable, Equatable, Sendable {
  /// Validate and stage the entire package before atomically replacing the
  /// current library. Portable backups deliberately do not perform ambiguous
  /// record-by-record merges.
  case replaceLibrary = "replace-library"
}

struct PortableBackupRestorePlan: Equatable, Sendable {
  var manifest: PortableBackupManifest
  var restoreMode: PortableBackupRestoreMode
  var libraryEntry: PortableBackupEntry
  var artworkEntries: [PortableBackupEntry]
  var mediaEntries: [PortableBackupEntry]
  var schemaAction: BackupLibrarySchemaAction
  var verifiedPayloadBytes: Int64
}

struct PortableBackupPackage: Equatable, Sendable {
  var manifest: PortableBackupManifest
  var observedFiles: [ObservedBackupFile]

  func validatedRestorePlan(
    policy: PortableBackupValidationPolicy
  ) throws -> PortableBackupRestorePlan {
    try PortableBackupValidator.validate(
      manifest: manifest,
      observedFiles: observedFiles,
      policy: policy
    )
  }
}

enum PortableBackupValidator {
  static func validate(
    manifest: PortableBackupManifest,
    observedFiles: [ObservedBackupFile],
    policy: PortableBackupValidationPolicy
  ) throws -> PortableBackupRestorePlan {
    guard policy.supportedFormatVersions.lowerBound > 0,
      policy.supportedLibrarySchemaVersions.lowerBound > 0,
      policy.supportedLibrarySchemaVersions.contains(policy.currentLibrarySchemaVersion),
      policy.supportedLibrarySchemaVersions.upperBound <= policy.currentLibrarySchemaVersion,
      policy.maximumEntryCount > 0,
      policy.maximumEntryBytes >= 0,
      policy.maximumTotalBytes >= 0
    else { throw PortableBackupError.invalidValidationPolicy }
    let validatedEntries = try manifest.entries.map {
      try PortableBackupEntry(
        kind: $0.kind,
        relativePath: $0.relativePath,
        byteCount: $0.byteCount,
        checksumSHA256: $0.checksumSHA256,
        bookID: $0.bookID,
        assetID: $0.assetID
      )
    }
    _ = try PortableBackupManifest(
      identifier: manifest.identifier,
      formatVersion: manifest.formatVersion,
      minimumReaderVersion: manifest.minimumReaderVersion,
      librarySchemaVersion: manifest.librarySchemaVersion,
      createdAt: manifest.createdAt,
      policy: manifest.policy,
      entries: validatedEntries
    )
    guard manifest.identifier == PortableBackupManifest.formatIdentifier else {
      throw PortableBackupError.invalidFormatIdentifier(manifest.identifier)
    }
    guard policy.supportedFormatVersions.contains(manifest.formatVersion) else {
      throw PortableBackupError.unsupportedFormatVersion(manifest.formatVersion)
    }
    guard manifest.minimumReaderVersion <= PortableBackupManifest.currentReaderVersion else {
      throw PortableBackupError.readerUpgradeRequired(manifest.minimumReaderVersion)
    }
    guard policy.supportedLibrarySchemaVersions.contains(manifest.librarySchemaVersion) else {
      throw PortableBackupError.unsupportedLibrarySchema(manifest.librarySchemaVersion)
    }
    guard manifest.entries.count <= policy.maximumEntryCount else {
      throw PortableBackupError.tooManyEntries(
        actual: manifest.entries.count,
        maximum: policy.maximumEntryCount
      )
    }
    guard observedFiles.count <= policy.maximumEntryCount else {
      throw PortableBackupError.tooManyEntries(
        actual: observedFiles.count,
        maximum: policy.maximumEntryCount
      )
    }
    var total: Int64 = 0
    for entry in manifest.entries {
      guard entry.byteCount <= policy.maximumEntryBytes else {
        throw PortableBackupError.entryTooLarge(
          entry.relativePath,
          actual: entry.byteCount,
          maximum: policy.maximumEntryBytes
        )
      }
      let (nextTotal, overflow) = total.addingReportingOverflow(entry.byteCount)
      guard !overflow else {
        throw PortableBackupError.packageByteCountOverflow
      }
      total = nextTotal
      guard total <= policy.maximumTotalBytes else {
        throw PortableBackupError.packageTooLarge(
          actual: total,
          maximum: policy.maximumTotalBytes
        )
      }
    }

    var observedByPath: [String: ObservedBackupFile] = [:]
    for file in observedFiles {
      _ = try ObservedBackupFile(
        relativePath: file.relativePath,
        byteCount: file.byteCount,
        checksumSHA256: file.checksumSHA256,
        fileType: file.fileType
      )
      let key = PortableBackupPath.collisionKey(file.relativePath)
      guard observedByPath[key] == nil else {
        throw PortableBackupError.duplicatePath(file.relativePath)
      }
      observedByPath[key] = file
    }
    let expectedKeys = Set(manifest.entries.map {
      PortableBackupPath.collisionKey($0.relativePath)
    })
    for file in observedFiles where !expectedKeys.contains(
      PortableBackupPath.collisionKey(file.relativePath)
    ) {
      throw PortableBackupError.unexpectedEntry(file.relativePath)
    }
    for entry in manifest.entries {
      let key = PortableBackupPath.collisionKey(entry.relativePath)
      guard let observed = observedByPath[key] else {
        throw PortableBackupError.missingEntry(entry.relativePath)
      }
      switch observed.fileType {
      case .regular: break
      case .symbolicLink: throw PortableBackupError.linkEntry(observed.relativePath)
      case .directory, .other: throw PortableBackupError.nonRegularEntry(observed.relativePath)
      }
      guard observed.byteCount == entry.byteCount else {
        throw PortableBackupError.sizeMismatch(
          entry.relativePath,
          expected: entry.byteCount,
          actual: observed.byteCount
        )
      }
      guard observed.checksumSHA256 == entry.checksumSHA256 else {
        throw PortableBackupError.checksumMismatch(entry.relativePath)
      }
    }
    let schemaAction: BackupLibrarySchemaAction = manifest.librarySchemaVersion
      == policy.currentLibrarySchemaVersion
      ? .direct(version: manifest.librarySchemaVersion)
      : .migrate(
        from: manifest.librarySchemaVersion,
        to: policy.currentLibrarySchemaVersion
      )
    return PortableBackupRestorePlan(
      manifest: manifest,
      restoreMode: .replaceLibrary,
      libraryEntry: manifest.libraryEntry,
      artworkEntries: manifest.entries.filter { $0.kind == .artwork },
      mediaEntries: manifest.entries.filter { $0.kind == .media },
      schemaAction: schemaAction,
      verifiedPayloadBytes: total
    )
  }
}

enum DatabaseBackupTrigger: Codable, Equatable, Sendable {
  case beforeMigration(from: Int, to: Int)
  case afterSignificantMutation(reason: String)
}

struct DatabaseBackupDescriptor: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var relativePath: String
  var byteCount: Int64
  var checksumSHA256: String
  var librarySchemaVersion: Int
  var createdAt: Date
  var trigger: DatabaseBackupTrigger

  init(
    id: UUID,
    relativePath: String,
    byteCount: Int64,
    checksumSHA256: String,
    librarySchemaVersion: Int,
    createdAt: Date,
    trigger: DatabaseBackupTrigger
  ) throws {
    guard PortableBackupPath.isSafe(relativePath) else {
      throw PortableBackupError.unsafePath(relativePath)
    }
    guard byteCount >= 0 else { throw PortableBackupError.negativeByteCount(relativePath) }
    let checksum = checksumSHA256.lowercased()
    guard BackupChecksum.isValidSHA256(checksum) else {
      throw PortableBackupError.invalidChecksum(relativePath)
    }
    guard librarySchemaVersion > 0 else {
      throw PortableBackupError.unsupportedLibrarySchema(librarySchemaVersion)
    }
    guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
      throw PortableBackupError.invalidTimestamp
    }
    if case let .beforeMigration(from, to) = trigger {
      guard from > 0, to > from else {
        throw PortableBackupError.invalidMigrationTrigger(from: from, to: to)
      }
    }
    if case let .afterSignificantMutation(reason) = trigger,
      reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw PortableBackupError.invalidMutationReason
    }
    self.id = id
    self.relativePath = relativePath
    self.byteCount = byteCount
    self.checksumSHA256 = checksum
    self.librarySchemaVersion = librarySchemaVersion
    self.createdAt = createdAt
    self.trigger = trigger
  }

  private enum CodingKeys: String, CodingKey {
    case id, relativePath, byteCount, checksumSHA256, librarySchemaVersion, createdAt, trigger
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    do {
      try self.init(
        id: values.decode(UUID.self, forKey: .id),
        relativePath: values.decode(String.self, forKey: .relativePath),
        byteCount: values.decode(Int64.self, forKey: .byteCount),
        checksumSHA256: values.decode(String.self, forKey: .checksumSHA256),
        librarySchemaVersion: values.decode(Int.self, forKey: .librarySchemaVersion),
        createdAt: values.decode(Date.self, forKey: .createdAt),
        trigger: values.decode(DatabaseBackupTrigger.self, forKey: .trigger)
      )
    } catch let error as DecodingError {
      throw error
    } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .relativePath,
        in: values,
        debugDescription: "Invalid database backup descriptor: \(error.localizedDescription)"
      )
    }
  }
}

struct DatabaseBackupRetentionPolicy: Equatable, Sendable {
  var maximumBackupCount: Int
  var minimumPreMigrationBackups: Int

  static let `default` = DatabaseBackupRetentionPolicy(
    maximumBackupCount: 5,
    minimumPreMigrationBackups: 1
  )
}

struct DatabaseBackupRotationPlan: Equatable, Sendable {
  var retained: [DatabaseBackupDescriptor]
  var discarded: [DatabaseBackupDescriptor]
}

enum DatabaseBackupRotationPlanner {
  static func plan(
    existing: [DatabaseBackupDescriptor],
    adding candidate: DatabaseBackupDescriptor,
    policy: DatabaseBackupRetentionPolicy = .default
  ) throws -> DatabaseBackupRotationPlan {
    guard policy.maximumBackupCount > 0,
      policy.minimumPreMigrationBackups >= 0,
      policy.minimumPreMigrationBackups <= policy.maximumBackupCount
    else { throw PortableBackupError.invalidRetentionPolicy }
    let (_, countOverflow) = existing.count.addingReportingOverflow(1)
    guard !countOverflow else { throw PortableBackupError.invalidRetentionPolicy }
    var all = existing
    all.append(candidate)
    var ids: Set<UUID> = []
    var paths: Set<String> = []
    for descriptor in all {
      _ = try DatabaseBackupDescriptor(
        id: descriptor.id,
        relativePath: descriptor.relativePath,
        byteCount: descriptor.byteCount,
        checksumSHA256: descriptor.checksumSHA256,
        librarySchemaVersion: descriptor.librarySchemaVersion,
        createdAt: descriptor.createdAt,
        trigger: descriptor.trigger
      )
      guard ids.insert(descriptor.id).inserted else {
        throw PortableBackupError.duplicateBackupID(descriptor.id)
      }
      let path = PortableBackupPath.collisionKey(descriptor.relativePath)
      guard paths.insert(path).inserted else {
        throw PortableBackupError.duplicatePath(descriptor.relativePath)
      }
    }
    let newestFirst = all.sorted {
      if $0.createdAt == $1.createdAt { return $0.id.uuidString > $1.id.uuidString }
      return $0.createdAt > $1.createdAt
    }
    let protectedMigration = newestFirst.filter {
      if case .beforeMigration = $0.trigger { return true }
      return false
    }.prefix(policy.minimumPreMigrationBackups)
    var retainedIDs = Set(protectedMigration.map(\.id))
    for item in newestFirst where retainedIDs.count < policy.maximumBackupCount {
      retainedIDs.insert(item.id)
    }
    return DatabaseBackupRotationPlan(
      retained: newestFirst.filter { retainedIDs.contains($0.id) },
      discarded: newestFirst.filter { !retainedIDs.contains($0.id) }
    )
  }
}

struct DatabaseBackupRecoveryCandidate: Equatable, Sendable {
  var descriptor: DatabaseBackupDescriptor
  var schemaAction: BackupLibrarySchemaAction
}

enum DatabaseBackupValidator {
  static func validate(
    descriptor: DatabaseBackupDescriptor,
    observedFile: ObservedBackupFile,
    supportedLibrarySchemaVersions: ClosedRange<Int>,
    currentLibrarySchemaVersion: Int
  ) throws -> DatabaseBackupRecoveryCandidate {
    guard supportedLibrarySchemaVersions.lowerBound > 0,
      supportedLibrarySchemaVersions.contains(currentLibrarySchemaVersion),
      supportedLibrarySchemaVersions.upperBound <= currentLibrarySchemaVersion
    else { throw PortableBackupError.invalidValidationPolicy }
    _ = try DatabaseBackupDescriptor(
      id: descriptor.id,
      relativePath: descriptor.relativePath,
      byteCount: descriptor.byteCount,
      checksumSHA256: descriptor.checksumSHA256,
      librarySchemaVersion: descriptor.librarySchemaVersion,
      createdAt: descriptor.createdAt,
      trigger: descriptor.trigger
    )
    _ = try ObservedBackupFile(
      relativePath: observedFile.relativePath,
      byteCount: observedFile.byteCount,
      checksumSHA256: observedFile.checksumSHA256,
      fileType: observedFile.fileType
    )
    guard PortableBackupPath.collisionKey(descriptor.relativePath)
      == PortableBackupPath.collisionKey(observedFile.relativePath)
    else { throw PortableBackupError.missingEntry(descriptor.relativePath) }
    guard observedFile.fileType == .regular else {
      throw observedFile.fileType == .symbolicLink
        ? PortableBackupError.linkEntry(observedFile.relativePath)
        : PortableBackupError.nonRegularEntry(observedFile.relativePath)
    }
    guard observedFile.byteCount == descriptor.byteCount else {
      throw PortableBackupError.sizeMismatch(
        descriptor.relativePath,
        expected: descriptor.byteCount,
        actual: observedFile.byteCount
      )
    }
    guard observedFile.checksumSHA256 == descriptor.checksumSHA256 else {
      throw PortableBackupError.checksumMismatch(descriptor.relativePath)
    }
    guard supportedLibrarySchemaVersions.contains(descriptor.librarySchemaVersion) else {
      throw PortableBackupError.unsupportedLibrarySchema(descriptor.librarySchemaVersion)
    }
    let action: BackupLibrarySchemaAction = descriptor.librarySchemaVersion
      == currentLibrarySchemaVersion
      ? .direct(version: currentLibrarySchemaVersion)
      : .migrate(from: descriptor.librarySchemaVersion, to: currentLibrarySchemaVersion)
    return DatabaseBackupRecoveryCandidate(descriptor: descriptor, schemaAction: action)
  }
}

enum BackupPreservedDomain: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case books
  case metadata
  case playbackPosition = "playback-position"
  case bookmarks
  case collections
  case settings
  case managedMediaChecksums = "managed-media-checksums"
}

struct BackupSchemaFixtureContract: Codable, Equatable, Sendable {
  var fixtureName: String
  var sourceLibrarySchemaVersion: Int
  var expectedCanonicalSHA256: String
  var preservedDomains: Set<BackupPreservedDomain>
}

enum BackupSchemaFixtureCoverage {
  static func validate(
    _ contracts: [BackupSchemaFixtureContract],
    requiredSchemaVersions: ClosedRange<Int>
  ) throws {
    var schemas: Set<Int> = []
    var names: Set<String> = []
    let requiredDomains = Set(BackupPreservedDomain.allCases)
    for contract in contracts {
      guard requiredSchemaVersions.contains(contract.sourceLibrarySchemaVersion) else {
        throw PortableBackupError.unexpectedSchemaFixture(contract.sourceLibrarySchemaVersion)
      }
      guard schemas.insert(contract.sourceLibrarySchemaVersion).inserted else {
        throw PortableBackupError.duplicateSchemaFixture(contract.sourceLibrarySchemaVersion)
      }
      let name = contract.fixtureName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, names.insert(name).inserted else {
        throw PortableBackupError.duplicateFixtureName(contract.fixtureName)
      }
      guard BackupChecksum.isValidSHA256(contract.expectedCanonicalSHA256.lowercased()) else {
        throw PortableBackupError.invalidFixtureChecksum(contract.fixtureName)
      }
      guard contract.preservedDomains == requiredDomains else {
        throw PortableBackupError.incompleteFixtureContract(contract.fixtureName)
      }
    }
    let missing = Set(requiredSchemaVersions).subtracting(schemas).sorted()
    guard missing.isEmpty else { throw PortableBackupError.missingSchemaFixtures(missing) }
  }
}

enum BackupOperationKind: String, Codable, Equatable, Sendable {
  case exportPortable = "export-portable"
  case restorePortable = "restore-portable"
  case automaticDatabase = "automatic-database"
}

enum BackupOperationPhase: String, Codable, Equatable, Sendable {
  case queued
  case preparing
  case writing
  case validating
  case completed
  case failed
  case cancelled
}

struct BackupOperationStatus: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var kind: BackupOperationKind
  var phase: BackupOperationPhase
  var completedBytes: Int64
  var totalBytes: Int64?
  var startedAt: Date
  var finishedAt: Date?
  var failureCode: String?
}

enum BackupChecksum {
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func isValidSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit }
  }
}

enum PortableBackupError: LocalizedError, Equatable, Sendable {
  case invalidFormatIdentifier(String)
  case invalidManifestVersion(Int)
  case unsupportedFormatVersion(Int)
  case readerUpgradeRequired(Int)
  case unsupportedLibrarySchema(Int)
  case unsafePath(String)
  case duplicatePath(String)
  case negativeByteCount(String)
  case invalidChecksum(String)
  case invalidEntryAssociation(String)
  case missingLibraryPayload
  case multipleLibraryPayloads
  case policyDisallowsEntry(String)
  case tooManyEntries(actual: Int, maximum: Int)
  case entryTooLarge(String, actual: Int64, maximum: Int64)
  case packageTooLarge(actual: Int64, maximum: Int64)
  case packageByteCountOverflow
  case missingEntry(String)
  case unexpectedEntry(String)
  case linkEntry(String)
  case nonRegularEntry(String)
  case sizeMismatch(String, expected: Int64, actual: Int64)
  case checksumMismatch(String)
  case invalidMigrationTrigger(from: Int, to: Int)
  case invalidMutationReason
  case invalidRetentionPolicy
  case invalidValidationPolicy
  case invalidTimestamp
  case duplicateBackupID(UUID)
  case unexpectedSchemaFixture(Int)
  case duplicateSchemaFixture(Int)
  case duplicateFixtureName(String)
  case invalidFixtureChecksum(String)
  case incompleteFixtureContract(String)
  case missingSchemaFixtures([Int])

  var errorDescription: String? {
    switch self {
    case .invalidFormatIdentifier: "This is not a Player portable backup."
    case .invalidManifestVersion: "The backup manifest version is invalid."
    case .unsupportedFormatVersion(let version):
      "Portable backup format version \(version) is not supported."
    case .readerUpgradeRequired(let version):
      "This backup needs reader version \(version) or newer."
    case .unsupportedLibrarySchema(let version):
      "Library schema version \(version) cannot be restored safely."
    case .unsafePath(let path): "The backup contains an unsafe path: \(path)."
    case .duplicatePath(let path): "The backup path \(path) appears more than once."
    case .negativeByteCount(let path): "The backup byte count for \(path) is invalid."
    case .invalidChecksum(let path): "The backup checksum for \(path) is invalid."
    case .invalidEntryAssociation(let path): "The backup association for \(path) is invalid."
    case .missingLibraryPayload: "The backup has no library database payload."
    case .multipleLibraryPayloads: "The backup has more than one library database payload."
    case .policyDisallowsEntry(let path): "The backup policy does not allow \(path)."
    case .tooManyEntries(let actual, let maximum):
      "The backup has \(actual) entries; the safe maximum is \(maximum)."
    case .entryTooLarge(let path, let actual, let maximum):
      "The backup entry \(path) is \(actual) bytes; the safe maximum is \(maximum)."
    case .packageTooLarge(let actual, let maximum):
      "The backup is \(actual) bytes; the safe maximum is \(maximum)."
    case .packageByteCountOverflow: "The backup payload byte count overflowed."
    case .missingEntry(let path): "The backup entry \(path) is missing."
    case .unexpectedEntry(let path): "The backup contains unlisted entry \(path)."
    case .linkEntry(let path): "The backup entry \(path) is a link and cannot be restored."
    case .nonRegularEntry(let path): "The backup entry \(path) is not a regular file."
    case .sizeMismatch(let path, _, _): "The backup entry \(path) has the wrong size."
    case .checksumMismatch(let path): "The backup entry \(path) failed its checksum."
    case .invalidMigrationTrigger: "The automatic backup migration boundary is invalid."
    case .invalidMutationReason: "The automatic backup mutation reason is empty."
    case .invalidRetentionPolicy: "The automatic backup retention policy is invalid."
    case .invalidValidationPolicy: "The backup validation policy is invalid."
    case .invalidTimestamp: "The backup timestamp is invalid."
    case .duplicateBackupID(let id): "Automatic backup ID \(id.uuidString) appears twice."
    case .unexpectedSchemaFixture(let version): "Schema fixture \(version) is not required."
    case .duplicateSchemaFixture(let version): "Schema fixture \(version) appears twice."
    case .duplicateFixtureName(let name): "Schema fixture name \(name) is duplicated or empty."
    case .invalidFixtureChecksum(let name): "Schema fixture \(name) has an invalid checksum."
    case .incompleteFixtureContract(let name):
      "Schema fixture \(name) does not assert every preserved domain."
    case .missingSchemaFixtures(let versions):
      "Schema fixtures are missing for versions \(versions.map(String.init).joined(separator: ", "))."
    }
  }
}

private enum PortableBackupPath {
  static func isSafe(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else { return false }
    guard !path.contains("\\"), !path.contains("\0") else { return false }
    if path.count >= 3 {
      let prefix = Array(path.prefix(3))
      if prefix[1] == ":", prefix[2] == "/" { return false }
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    return !components.isEmpty && !components.contains {
      $0.isEmpty || $0 == "." || $0 == ".."
    }
  }

  static func collisionKey(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.folding(
      options: [.caseInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }
}

private enum BackupSaturating {
  static func add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : sum
  }
}

private enum PortableBackupCanonical {
  static func manifestData(_ manifest: PortableBackupManifest) -> Data {
    var writer = Writer()
    writer.append("player-portable-backup-canonical-v1")
    writer.append(manifest.identifier)
    writer.append(manifest.formatVersion)
    writer.append(manifest.minimumReaderVersion)
    writer.append(manifest.librarySchemaVersion)
    writer.appendDate(manifest.createdAt)
    writer.append(manifest.policy.mode.rawValue)
    writer.append(manifest.policy.includesArtwork)
    writer.append(manifest.entries.count)
    for entry in manifest.entries.sorted(by: canonicalEntryOrder) {
      writer.append(entry.kind.rawValue)
      writer.append(entry.relativePath)
      writer.append(entry.byteCount)
      writer.append(entry.checksumSHA256)
      writer.append(entry.bookID)
      writer.append(entry.assetID)
    }
    return writer.data
  }

  private static func canonicalEntryOrder(
    _ lhs: PortableBackupEntry,
    _ rhs: PortableBackupEntry
  ) -> Bool {
    let left = PortableBackupPath.collisionKey(lhs.relativePath)
    let right = PortableBackupPath.collisionKey(rhs.relativePath)
    if left == right { return lhs.relativePath < rhs.relativePath }
    return left < right
  }

  private struct Writer {
    var data = Data()

    mutating func append(_ value: Bool) {
      data.append(value ? 1 : 0)
    }

    mutating func append(_ value: Int) {
      append(Int64(value))
    }

    mutating func append(_ value: Int64) {
      append(UInt64(bitPattern: value))
    }

    mutating func append(_ value: String) {
      let bytes = Data(value.precomposedStringWithCanonicalMapping.utf8)
      append(UInt64(bytes.count))
      data.append(bytes)
    }

    mutating func append(_ value: UUID?) {
      guard let value else {
        append(false)
        return
      }
      append(true)
      append(value.uuidString.lowercased())
    }

    mutating func appendDate(_ value: Date) {
      var seconds = value.timeIntervalSinceReferenceDate
      if seconds == 0 { seconds = 0 } // Canonicalize negative zero.
      append(seconds.bitPattern)
    }

    private mutating func append(_ value: UInt64) {
      for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
      }
    }
  }
}
