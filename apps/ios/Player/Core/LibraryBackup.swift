import CryptoKit
import Foundation

enum PortableBackupKind: String, Codable, CaseIterable, Sendable {
  case metadataOnly
  case includingMedia

  var displayName: String {
    switch self {
    case .metadataOnly: "Metadata only"
    case .includingMedia: "With audio"
    }
  }
}

struct PortableBackupPayload: Codable, Equatable, Sendable {
  var relativePath: String
  var byteCount: Int64
  var checksumSHA256: String
}

struct PortableArtworkDigest: Codable, Equatable, Sendable {
  var bookID: UUID
  var byteCount: Int64
  var checksumSHA256: String
}

struct PortableLibraryManifest: Codable, Equatable, Sendable {
  static let currentFormatVersion = 1

  var formatVersion: Int
  var librarySchemaVersion: Int
  var createdAt: Date
  var kind: PortableBackupKind
  var library: LibrarySnapshot
  var media: [PortableBackupPayload]
  var artwork: [PortableArtworkDigest]
}

struct PreparedLibraryBackup: Equatable, Sendable {
  var url: URL
  var kind: PortableBackupKind
  var bookCount: Int
  var byteCount: Int64
}

struct AutomaticLibraryBackup: Equatable, Sendable {
  var url: URL
  var createdAt: Date
  var byteCount: Int64
}

enum PortableRestoreTransactionPhase: String, Codable, CaseIterable, Sendable {
  case prepared
  case previousLibraryMoved
  case previousMediaMoved
  case stagedMediaInstalled
  case stagedLibraryInstalled
  case committed
}

struct PortableRestoreTransactionJournal: Codable, Equatable, Sendable {
  var phase: PortableRestoreTransactionPhase
  var replacesMedia: Bool
  var hadPreviousLibrary: Bool
  var hadPreviousMedia: Bool
}

struct PortableLibraryBackupPolicy: Equatable, Sendable {
  var maximumManifestByteCount: Int64 = 64 * 1_024 * 1_024
  var maximumBookCount = 100_000
  var maximumMediaCount = 500_000
  var maximumArtworkCount = 100_000
  var maximumArtworkByteCount: Int64 = 64 * 1_024 * 1_024
  var maximumAggregateArtworkByteCount: Int64 = 2 * 1_024 * 1_024 * 1_024
  var maximumMediaByteCount: Int64 = 1_024 * 1_024 * 1_024 * 1_024
  var maximumAggregateMediaByteCount: Int64 = 4 * 1_024 * 1_024 * 1_024 * 1_024
  var maximumPackageByteCount: Int64 = 4 * 1_024 * 1_024 * 1_024 * 1_024

  static let production = Self()
}

enum LibraryBackupError: LocalizedError, Equatable, Sendable {
  case unsupportedFormat(Int)
  case unsupportedLibrarySchema(Int)
  case invalidPackage(String)
  case missingPayload(String)
  case invalidPayload(String)
  case localMediaRequired(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedFormat(let version):
      "This backup uses unsupported format version \(version). Update Bookshelf before restoring it."
    case .unsupportedLibrarySchema(let version):
      "This backup contains library schema \(version), which this version of Bookshelf cannot read."
    case .invalidPackage(let detail):
      "This Bookshelf backup is invalid: \(detail)"
    case .missingPayload(let path):
      "This backup is missing \(path)."
    case .invalidPayload(let path):
      "The backup copy of \(path) did not pass its integrity check."
    case .localMediaRequired(let path):
      "The metadata-only backup needs the existing local audio at \(path). Use a backup that includes audio on a new device."
    }
  }
}

protocol LibraryBackupManaging: Sendable {
  func recoverInterruptedRestores() async throws
  func prepareExport(library: LibrarySnapshot, kind: PortableBackupKind) async throws
    -> PreparedLibraryBackup
  func discardPreparedExport(_ backup: PreparedLibraryBackup) async
  func restore(from backupURL: URL) async throws -> LibrarySnapshot
}

actor DisabledLibraryBackupManager: LibraryBackupManaging {
  func recoverInterruptedRestores() {}

  func prepareExport(library: LibrarySnapshot, kind: PortableBackupKind) throws
    -> PreparedLibraryBackup
  {
    throw PlayerCoreError.fileOperation("Backup is unavailable in this environment.")
  }

  func discardPreparedExport(_ backup: PreparedLibraryBackup) {}

  func restore(from backupURL: URL) async throws -> LibrarySnapshot {
    throw PlayerCoreError.fileOperation("Restore is unavailable in this environment.")
  }
}

actor FileSystemLibraryBackupManager: LibraryBackupManaging {
  private let rootURL: URL
  private let fileManager: FileManager
  private let clock: any PlayerClock
  private let policy: PortableLibraryBackupPolicy
  private let beforeRestoreCommit: (@Sendable () async -> Void)?
  private let restorePhaseFailpoint: (@Sendable (PortableRestoreTransactionPhase) throws -> Void)?
  private let restoreID: @Sendable () -> UUID

  init(
    rootURL: URL,
    fileManager: FileManager = .default,
    clock: any PlayerClock = SystemPlayerClock(),
    policy: PortableLibraryBackupPolicy = .production,
    beforeRestoreCommit: (@Sendable () async -> Void)? = nil,
    restorePhaseFailpoint: (@Sendable (PortableRestoreTransactionPhase) throws -> Void)? = nil,
    restoreID: @escaping @Sendable () -> UUID = { UUID() }
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
    self.clock = clock
    self.policy = policy
    self.beforeRestoreCommit = beforeRestoreCommit
    self.restorePhaseFailpoint = restorePhaseFailpoint
    self.restoreID = restoreID
    // A prepared package is only a transient hand-off to the system picker.
    // If the process was killed while the picker was open, remove that copy on
    // the next launch so it cannot become hidden duplicate storage.
    try? fileManager.removeItem(
      at: rootURL.appending(path: "BackupExports", directoryHint: .isDirectory)
    )
  }

  func prepareExport(
    library: LibrarySnapshot,
    kind: PortableBackupKind
  ) throws -> PreparedLibraryBackup {
    try ensureInterruptedTransactionsRecovered()
    try Task.checkCancellation()
    try validateLibraryCounts(library)
    let exportRoot = rootURL.appending(path: "BackupExports", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
    let packageURL = exportRoot.appending(
      path: "Bookshelf Library \(Self.filenameTimestamp(clock.now())).playerbackup",
      directoryHint: .isDirectory
    )
    guard !fileManager.fileExists(atPath: packageURL.path) else {
      throw PlayerCoreError.fileOperation("A prepared backup with this name already exists.")
    }
    try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)

    do {
      let assetPaths = try library.books.flatMap(\.assets).map {
        try validatedMediaPath($0.managedRelativePath)
      }
      guard Set(assetPaths).count == assetPaths.count else {
        throw LibraryBackupError.invalidPackage(
          "more than one track points to the same media file.")
      }
      var payloads: [PortableBackupPayload] = []
      var exportedBytes: Int64 = 0
      if kind == .includingMedia {
        for asset in library.books.flatMap(\.assets) {
          try Task.checkCancellation()
          let relativePath = try validatedMediaPath(asset.managedRelativePath)
          let source = rootURL.appending(path: relativePath).standardizedFileURL
          try requireRegularFileWithoutSymlink(source, missingPath: relativePath)
          let destination = packageURL.appending(path: relativePath)
          try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          let identity = try copyAndHash(from: source, to: destination)
          guard identity.byteCount == asset.byteCount,
            identity.checksumSHA256 == asset.checksumSHA256.lowercased()
          else {
            throw LibraryBackupError.invalidPayload(relativePath)
          }
          payloads.append(
            PortableBackupPayload(
              relativePath: relativePath,
              byteCount: identity.byteCount,
              checksumSHA256: identity.checksumSHA256
            ))
          exportedBytes = try checkedTotal(
            exportedBytes,
            adding: identity.byteCount,
            maximum: policy.maximumAggregateMediaByteCount,
            detail: "the media payloads exceed the supported size."
          )
        }
      }

      var portableLibrary = library
      portableLibrary.importJobs = []
      portableLibrary.shareImportReceipts = []
      portableLibrary.trashTransactions = []
      portableLibrary.storageManifests = []
      portableLibrary.activeSleepTimer = nil

      let artwork = portableLibrary.books.compactMap { book -> PortableArtworkDigest? in
        guard let data = book.artworkData else { return nil }
        return PortableArtworkDigest(
          bookID: book.id,
          byteCount: Int64(data.count),
          checksumSHA256: Self.hash(data)
        )
      }.sorted { $0.bookID.uuidString < $1.bookID.uuidString }
      try validateArtworkCatalog(artwork, library: portableLibrary)

      let manifest = PortableLibraryManifest(
        formatVersion: PortableLibraryManifest.currentFormatVersion,
        librarySchemaVersion: CodableLibraryStore.currentSchemaVersion,
        createdAt: clock.now(),
        kind: kind,
        library: portableLibrary,
        media: payloads.sorted { $0.relativePath < $1.relativePath },
        artwork: artwork
      )
      let manifestData = try JSONEncoder.playerEncoder.encode(manifest)
      guard Int64(manifestData.count) <= policy.maximumManifestByteCount else {
        throw LibraryBackupError.invalidPackage("manifest.json exceeds the supported size.")
      }
      exportedBytes = try checkedTotal(
        exportedBytes,
        adding: Int64(manifestData.count),
        maximum: policy.maximumPackageByteCount,
        detail: "the backup exceeds the supported size."
      )
      try Task.checkCancellation()
      try manifestData.write(
        to: packageURL.appending(path: "manifest.json"),
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      return PreparedLibraryBackup(
        url: packageURL,
        kind: kind,
        bookCount: portableLibrary.books.count,
        byteCount: exportedBytes
      )
    } catch {
      try? fileManager.removeItem(at: packageURL)
      throw error
    }
  }

  func recoverInterruptedRestores() async throws {
    try recoverInterruptedRestoreTransactions()
  }

  private func commitRestore(
    library: LibrarySnapshot,
    stagedMedia: URL?,
    transactionRoot suppliedTransactionRoot: URL? = nil
  ) throws {
    let transactionRoot =
      suppliedTransactionRoot
      ?? rootURL.appending(
        path: "BackupRestore/\(restoreID().uuidString.lowercased())"
      )
    try fileManager.createDirectory(at: transactionRoot, withIntermediateDirectories: true)

    let stagedLibrary = transactionRoot.appending(path: "StagedLibrary.json")
    do {
      let encodedLibrary = try CodableLibraryStore.encodedCurrentSnapshot(library)
      try encodedLibrary.write(
        to: stagedLibrary,
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      let stagedLibraryData = try Data(contentsOf: stagedLibrary)
      guard try CodableLibraryStore.decodedCurrentSnapshot(stagedLibraryData) == library else {
        throw LibraryBackupError.invalidPackage("the staged library could not be verified.")
      }
    } catch {
      try? fileManager.removeItem(at: transactionRoot)
      throw error
    }

    let liveLibrary = rootURL.appending(path: "Library.json")
    let liveMedia = rootURL.appending(path: "Media", directoryHint: .isDirectory)
    var journal = PortableRestoreTransactionJournal(
      phase: .prepared,
      replacesMedia: stagedMedia != nil,
      hadPreviousLibrary: fileManager.fileExists(atPath: liveLibrary.path),
      hadPreviousMedia: fileManager.fileExists(atPath: liveMedia.path)
    )
    try write(journal, in: transactionRoot)

    do {
      try restorePhaseFailpoint?(.prepared)
      try Task.checkCancellation()

      if journal.hadPreviousLibrary {
        try fileManager.moveItem(
          at: liveLibrary,
          to: transactionRoot.appending(path: "PreviousLibrary.json")
        )
      }
      try advance(&journal, to: .previousLibraryMoved, in: transactionRoot)

      if let stagedMedia {
        if journal.hadPreviousMedia {
          try fileManager.moveItem(
            at: liveMedia,
            to: transactionRoot.appending(path: "PreviousMedia", directoryHint: .isDirectory)
          )
        }
        try advance(&journal, to: .previousMediaMoved, in: transactionRoot)
        try fileManager.moveItem(at: stagedMedia, to: liveMedia)
        try advance(&journal, to: .stagedMediaInstalled, in: transactionRoot)
      }

      try fileManager.moveItem(at: stagedLibrary, to: liveLibrary)
      try advance(&journal, to: .stagedLibraryInstalled, in: transactionRoot)
      try advance(&journal, to: .committed, in: transactionRoot, invokesFailpoint: false)

      // The commit marker makes the new pair authoritative. Cleanup is safe to
      // retry during the next operation if interruption happens here.
      try? fileManager.removeItem(at: transactionRoot)
    } catch {
      do {
        try rollbackRestoreTransaction(at: transactionRoot, journal: journal)
      } catch {
        throw LibraryBackupError.invalidPackage(
          "the restore failed and its previous library could not be recovered automatically; recovery evidence was retained."
        )
      }
      throw error
    }
  }

  private func advance(
    _ journal: inout PortableRestoreTransactionJournal,
    to phase: PortableRestoreTransactionPhase,
    in transactionRoot: URL,
    invokesFailpoint: Bool = true
  ) throws {
    journal.phase = phase
    try write(journal, in: transactionRoot)
    if invokesFailpoint { try restorePhaseFailpoint?(phase) }
  }

  private func write(
    _ journal: PortableRestoreTransactionJournal,
    in transactionRoot: URL
  ) throws {
    let data = try JSONEncoder.playerEncoder.encode(journal)
    try data.write(
      to: transactionRoot.appending(path: "journal.json"),
      options: [.atomic, .completeFileProtectionUnlessOpen]
    )
  }

  private func ensureInterruptedTransactionsRecovered() throws {
    try recoverInterruptedRestoreTransactions()
  }

  private func recoverInterruptedRestoreTransactions() throws {
    let restoreRoot = rootURL.appending(path: "BackupRestore", directoryHint: .isDirectory)
    guard fileManager.fileExists(atPath: restoreRoot.path) else { return }
    let transactions = try fileManager.contentsOfDirectory(
      at: restoreRoot,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    for transactionRoot in transactions.sorted(by: { $0.path < $1.path }) {
      guard try itemType(at: transactionRoot) == .typeDirectory else {
        throw LibraryBackupError.invalidPackage(
          "portable restore recovery contains an unexpected entry."
        )
      }
      let journalURL = transactionRoot.appending(path: "journal.json")
      guard fileManager.fileExists(atPath: journalURL.path) else {
        // No journal means live storage was never touched.
        try fileManager.removeItem(at: transactionRoot)
        continue
      }
      let journal: PortableRestoreTransactionJournal
      do {
        journal = try JSONDecoder.playerDecoder.decode(
          PortableRestoreTransactionJournal.self,
          from: Data(contentsOf: journalURL)
        )
      } catch {
        throw LibraryBackupError.invalidPackage(
          "portable restore recovery metadata is unreadable; recovery evidence was retained."
        )
      }
      if journal.phase == .committed {
        try fileManager.removeItem(at: transactionRoot)
      } else {
        try rollbackRestoreTransaction(at: transactionRoot, journal: journal)
      }
    }
    if (try? fileManager.contentsOfDirectory(atPath: restoreRoot.path).isEmpty) == true {
      try? fileManager.removeItem(at: restoreRoot)
    }
  }

  private func rollbackRestoreTransaction(
    at transactionRoot: URL,
    journal: PortableRestoreTransactionJournal
  ) throws {
    let liveLibrary = rootURL.appending(path: "Library.json")
    let stagedLibrary = transactionRoot.appending(path: "StagedLibrary.json")
    let previousLibrary = transactionRoot.appending(path: "PreviousLibrary.json")
    let liveMedia = rootURL.appending(path: "Media", directoryHint: .isDirectory)
    let stagedMedia = transactionRoot.appending(path: "Media", directoryHint: .isDirectory)
    let previousMedia = transactionRoot.appending(
      path: "PreviousMedia", directoryHint: .isDirectory
    )

    if journal.replacesMedia {
      if fileManager.fileExists(atPath: previousMedia.path) {
        if fileManager.fileExists(atPath: liveMedia.path) {
          try fileManager.removeItem(at: liveMedia)
        }
        try fileManager.moveItem(at: previousMedia, to: liveMedia)
      } else if !journal.hadPreviousMedia,
        !fileManager.fileExists(atPath: stagedMedia.path),
        fileManager.fileExists(atPath: liveMedia.path)
      {
        try fileManager.removeItem(at: liveMedia)
      }
    }

    if fileManager.fileExists(atPath: previousLibrary.path) {
      if fileManager.fileExists(atPath: liveLibrary.path) {
        try fileManager.removeItem(at: liveLibrary)
      }
      try fileManager.moveItem(at: previousLibrary, to: liveLibrary)
    } else if !journal.hadPreviousLibrary,
      !fileManager.fileExists(atPath: stagedLibrary.path),
      fileManager.fileExists(atPath: liveLibrary.path)
    {
      try fileManager.removeItem(at: liveLibrary)
    }

    try fileManager.removeItem(at: transactionRoot)
  }

  func discardPreparedExport(_ backup: PreparedLibraryBackup) {
    let exportRoot =
      rootURL.appending(path: "BackupExports", directoryHint: .isDirectory)
      .standardizedFileURL.path + "/"
    guard backup.url.standardizedFileURL.path.hasPrefix(exportRoot) else { return }
    try? fileManager.removeItem(at: backup.url)
  }

  func restore(from backupURL: URL) async throws -> LibrarySnapshot {
    try ensureInterruptedTransactionsRecovered()
    let accessed = backupURL.startAccessingSecurityScopedResource()
    defer { if accessed { backupURL.stopAccessingSecurityScopedResource() } }

    try Task.checkCancellation()
    let packageURL = backupURL.standardizedFileURL
    try requireDirectoryWithoutSymlink(packageURL, detail: "the package root is not a directory.")
    let manifestURL = packageURL.appending(path: "manifest.json")
    try requireRegularFileWithoutSymlink(manifestURL, missingPath: "manifest.json")
    let manifestByteCount = try fileByteCount(at: manifestURL)
    guard manifestByteCount <= policy.maximumManifestByteCount else {
      throw LibraryBackupError.invalidPackage("manifest.json exceeds the supported size.")
    }
    let manifest: PortableLibraryManifest
    do {
      let manifestData = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
      guard Int64(manifestData.count) <= policy.maximumManifestByteCount else {
        throw LibraryBackupError.invalidPackage("manifest.json exceeds the supported size.")
      }
      manifest = try JSONDecoder.playerDecoder.decode(
        PortableLibraryManifest.self,
        from: manifestData
      )
    } catch let error as LibraryBackupError {
      throw error
    } catch {
      throw LibraryBackupError.invalidPackage("manifest.json could not be decoded.")
    }
    guard manifest.formatVersion == PortableLibraryManifest.currentFormatVersion else {
      throw LibraryBackupError.unsupportedFormat(manifest.formatVersion)
    }
    guard manifest.librarySchemaVersion <= CodableLibraryStore.currentSchemaVersion else {
      throw LibraryBackupError.unsupportedLibrarySchema(manifest.librarySchemaVersion)
    }
    try Task.checkCancellation()
    try validateLibraryCounts(manifest.library)
    try validateArtwork(in: manifest)

    let expectedPaths = try Set(
      manifest.library.books.flatMap(\.assets).map {
        try validatedMediaPath($0.managedRelativePath)
      })
    guard expectedPaths.count == manifest.library.books.flatMap(\.assets).count else {
      throw LibraryBackupError.invalidPackage("more than one track points to the same media file.")
    }

    if manifest.kind == .metadataOnly {
      guard manifest.media.isEmpty else {
        throw LibraryBackupError.invalidPackage("a metadata-only manifest contains media records.")
      }
      try validatePackageContents(at: packageURL, expectedPayloadPaths: [])
      for asset in manifest.library.books.flatMap(\.assets) {
        try Task.checkCancellation()
        let relativePath = try validatedMediaPath(asset.managedRelativePath)
        let localURL = rootURL.appending(path: relativePath)
        guard fileManager.fileExists(atPath: localURL.path) else {
          throw LibraryBackupError.localMediaRequired(relativePath)
        }
        let identity = try hashFile(at: localURL)
        guard identity.byteCount == asset.byteCount,
          identity.checksumSHA256 == asset.checksumSHA256.lowercased()
        else {
          throw LibraryBackupError.invalidPayload(relativePath)
        }
      }
      if let beforeRestoreCommit { await beforeRestoreCommit() }
      try Task.checkCancellation()
      try commitRestore(library: manifest.library, stagedMedia: nil)
      return manifest.library
    }

    let normalizedPayloads = try manifest.media.map { payload in
      let relativePath = try validatedMediaPath(payload.relativePath)
      try validateMediaByteCount(payload.byteCount, path: relativePath)
      try validateChecksum(payload.checksumSHA256, path: relativePath)
      return (relativePath, payload)
    }
    guard Set(normalizedPayloads.map(\.0)).count == normalizedPayloads.count else {
      throw LibraryBackupError.invalidPackage("the media catalog contains duplicate paths.")
    }
    let payloadByPath = Dictionary(uniqueKeysWithValues: normalizedPayloads)
    guard Set(payloadByPath.keys) == expectedPaths else {
      throw LibraryBackupError.invalidPackage("the media catalog does not match the library.")
    }
    var aggregateMediaByteCount: Int64 = 0
    for (relativePath, payload) in normalizedPayloads {
      aggregateMediaByteCount = try checkedTotal(
        aggregateMediaByteCount,
        adding: payload.byteCount,
        maximum: policy.maximumAggregateMediaByteCount,
        detail: "the media payloads exceed the supported size."
      )
      guard
        let asset = manifest.library.books.flatMap(\.assets).first(where: {
          $0.managedRelativePath == relativePath
        }), payload.byteCount == asset.byteCount,
        payload.checksumSHA256.lowercased() == asset.checksumSHA256.lowercased()
      else { throw LibraryBackupError.invalidPayload(relativePath) }
    }
    _ = try checkedTotal(
      manifestByteCount,
      adding: aggregateMediaByteCount,
      maximum: policy.maximumPackageByteCount,
      detail: "the backup exceeds the supported size."
    )
    try validatePackageContents(
      at: packageURL,
      expectedPayloadPaths: Set(normalizedPayloads.map(\.0))
    )

    let transactionRoot = rootURL.appending(
      path: "BackupRestore/\(restoreID().uuidString.lowercased())"
    )
    let stagedMedia = transactionRoot.appending(path: "Media", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: stagedMedia, withIntermediateDirectories: true)
    do {
      for relativePath in expectedPaths.sorted() {
        try Task.checkCancellation()
        guard let payload = payloadByPath[relativePath] else {
          throw LibraryBackupError.missingPayload(relativePath)
        }
        guard
          let asset = manifest.library.books.flatMap(\.assets).first(where: {
            $0.managedRelativePath == relativePath
          }), payload.byteCount == asset.byteCount,
          payload.checksumSHA256.lowercased() == asset.checksumSHA256.lowercased()
        else { throw LibraryBackupError.invalidPayload(relativePath) }
        let source = packageURL.appending(path: relativePath).standardizedFileURL
        try requireRegularFileWithoutSymlink(source, missingPath: relativePath)
        guard try fileByteCount(at: source) == payload.byteCount else {
          throw LibraryBackupError.invalidPayload(relativePath)
        }
        let destination = transactionRoot.appending(path: relativePath).standardizedFileURL
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let identity = try copyAndHash(from: source, to: destination)
        guard identity.byteCount == payload.byteCount,
          identity.checksumSHA256 == payload.checksumSHA256.lowercased()
        else { throw LibraryBackupError.invalidPayload(relativePath) }
      }

      if let beforeRestoreCommit { await beforeRestoreCommit() }
      try Task.checkCancellation()
      try commitRestore(
        library: manifest.library,
        stagedMedia: stagedMedia,
        transactionRoot: transactionRoot
      )
      return manifest.library
    } catch {
      // Before a journal exists the transaction contains only uncommitted
      // staging and can be discarded. Once commitRestore creates its journal,
      // it owns rollback and evidence retention.
      if !fileManager.fileExists(
        atPath: transactionRoot.appending(path: "journal.json").path
      ) {
        try? fileManager.removeItem(at: transactionRoot)
      }
      throw error
    }
  }

  private func validateArtwork(in manifest: PortableLibraryManifest) throws {
    try validateArtworkCatalog(manifest.artwork, library: manifest.library)
  }

  private func validateArtworkCatalog(
    _ artwork: [PortableArtworkDigest],
    library: LibrarySnapshot
  ) throws {
    guard artwork.count <= policy.maximumArtworkCount else {
      throw LibraryBackupError.invalidPackage("the artwork catalog contains too many entries.")
    }
    let expected = Dictionary(
      uniqueKeysWithValues: library.books.compactMap {
        book -> (UUID, Data)? in book.artworkData.map { (book.id, $0) }
      })
    guard Set(artwork.map(\.bookID)).count == artwork.count else {
      throw LibraryBackupError.invalidPackage("the artwork catalog contains duplicate entries.")
    }
    let supplied = Dictionary(uniqueKeysWithValues: artwork.map { ($0.bookID, $0) })
    guard expected.count == supplied.count else {
      throw LibraryBackupError.invalidPackage("the artwork catalog does not match the library.")
    }
    var aggregateArtworkByteCount: Int64 = 0
    for (bookID, data) in expected {
      guard let digest = supplied[bookID], digest.byteCount >= 0,
        digest.byteCount <= policy.maximumArtworkByteCount,
        digest.byteCount == Int64(data.count)
      else { throw LibraryBackupError.invalidPackage("artwork failed its integrity check.") }
      try validateChecksum(digest.checksumSHA256, path: "artwork")
      guard digest.checksumSHA256.lowercased() == Self.hash(data) else {
        throw LibraryBackupError.invalidPackage("artwork failed its integrity check.")
      }
      aggregateArtworkByteCount = try checkedTotal(
        aggregateArtworkByteCount,
        adding: digest.byteCount,
        maximum: policy.maximumAggregateArtworkByteCount,
        detail: "the artwork catalog exceeds the supported size."
      )
    }
  }

  private func validateLibraryCounts(_ library: LibrarySnapshot) throws {
    guard library.books.count <= policy.maximumBookCount,
      Set(library.books.map(\.id)).count == library.books.count
    else {
      throw LibraryBackupError.invalidPackage("the library contains too many or duplicate books.")
    }
    var assetCount = 0
    for book in library.books {
      guard assetCount <= policy.maximumMediaCount,
        book.assets.count <= policy.maximumMediaCount - assetCount
      else {
        throw LibraryBackupError.invalidPackage("the library contains too many media records.")
      }
      assetCount += book.assets.count
      for asset in book.assets {
        let relativePath = try validatedMediaPath(asset.managedRelativePath)
        try validateMediaByteCount(asset.byteCount, path: relativePath)
        try validateChecksum(asset.checksumSHA256, path: relativePath)
      }
    }
  }

  private func validatedMediaPath(_ path: String) throws -> String {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard path == path.precomposedStringWithCanonicalMapping,
      !path.hasPrefix("/"),
      components.count >= 2,
      components.first == "Media",
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw LibraryBackupError.invalidPackage("a media path escapes managed storage.")
    }
    let candidate = rootURL.appending(path: path).standardizedFileURL
    let mediaRoot =
      rootURL.appending(path: "Media", directoryHint: .isDirectory)
      .standardizedFileURL.path + "/"
    let normalized = String(candidate.path.dropFirst(rootURL.path.count + 1))
    guard candidate.path.hasPrefix(mediaRoot), normalized == path else {
      throw LibraryBackupError.invalidPackage("a media path escapes managed storage.")
    }
    return normalized
  }

  private func validatePackageContents(
    at packageURL: URL,
    expectedPayloadPaths: Set<String>
  ) throws {
    var expectedFiles = expectedPayloadPaths
    expectedFiles.insert("manifest.json")
    var expectedDirectories: Set<String> = []
    for path in expectedPayloadPaths {
      var components = path.split(separator: "/").map(String.init)
      components.removeLast()
      var ancestor = ""
      for component in components {
        ancestor = ancestor.isEmpty ? component : "\(ancestor)/\(component)"
        expectedDirectories.insert(ancestor)
      }
    }

    var actualFiles: Set<String> = []
    var actualDirectories: Set<String> = []
    var directoriesToVisit = [packageURL]
    while let directory = directoriesToVisit.popLast() {
      try Task.checkCancellation()
      for child in try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: []
      ) {
        let relativePath = try packageRelativePath(child, root: packageURL)
        let type = try itemType(at: child)
        guard type != .typeSymbolicLink else {
          throw LibraryBackupError.invalidPackage("\(relativePath) is a symbolic link.")
        }
        if type == .typeDirectory {
          guard expectedDirectories.contains(relativePath) else {
            throw LibraryBackupError.invalidPackage("the package contains undeclared entries.")
          }
          actualDirectories.insert(relativePath)
          directoriesToVisit.append(child)
        } else if type == .typeRegular {
          guard expectedFiles.contains(relativePath) else {
            throw LibraryBackupError.invalidPackage("the package contains undeclared entries.")
          }
          actualFiles.insert(relativePath)
        } else {
          throw LibraryBackupError.invalidPackage("\(relativePath) has an unsupported file type.")
        }
      }
    }
    guard actualFiles == expectedFiles, actualDirectories == expectedDirectories else {
      throw LibraryBackupError.invalidPackage("the package contents do not match its manifest.")
    }
  }

  private func packageRelativePath(_ url: URL, root: URL) throws -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else {
      throw LibraryBackupError.invalidPackage("an entry escapes the package root.")
    }
    return String(path.dropFirst(rootPath.count + 1))
  }

  private func itemType(at url: URL) throws -> FileAttributeType {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let type = attributes[.type] as? FileAttributeType else {
      throw LibraryBackupError.invalidPackage("an entry has no filesystem type.")
    }
    return type
  }

  private func requireDirectoryWithoutSymlink(_ url: URL, detail: String) throws {
    guard fileManager.fileExists(atPath: url.path), try itemType(at: url) == .typeDirectory else {
      throw LibraryBackupError.invalidPackage(detail)
    }
  }

  private func requireRegularFileWithoutSymlink(_ url: URL, missingPath: String) throws {
    guard fileManager.fileExists(atPath: url.path) else {
      throw LibraryBackupError.missingPayload(missingPath)
    }
    let type = try itemType(at: url)
    guard type != .typeSymbolicLink else {
      throw LibraryBackupError.invalidPackage("\(missingPath) is a symbolic link.")
    }
    guard type == .typeRegular else {
      throw LibraryBackupError.invalidPackage("\(missingPath) is not a regular file.")
    }
  }

  private func fileByteCount(at url: URL) throws -> Int64 {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let value = attributes[.size] as? NSNumber else {
      throw LibraryBackupError.invalidPackage("an entry has no valid size.")
    }
    let byteCount = value.int64Value
    guard byteCount >= 0 else {
      throw LibraryBackupError.invalidPackage("an entry has an invalid size.")
    }
    return byteCount
  }

  private func validateMediaByteCount(_ byteCount: Int64, path: String) throws {
    guard byteCount >= 0, byteCount <= policy.maximumMediaByteCount else {
      throw LibraryBackupError.invalidPackage("\(path) has an unsupported size.")
    }
  }

  private func validateChecksum(_ checksum: String, path: String) throws {
    guard checksum.count == 64,
      checksum.unicodeScalars.allSatisfy({
        (48...57).contains($0.value) || (65...70).contains($0.value)
          || (97...102).contains($0.value)
      })
    else {
      throw LibraryBackupError.invalidPackage("\(path) has an invalid checksum.")
    }
  }

  private func checkedTotal(
    _ total: Int64,
    adding value: Int64,
    maximum: Int64,
    detail: String
  ) throws -> Int64 {
    guard value >= 0, total >= 0, total <= maximum, value <= maximum - total else {
      throw LibraryBackupError.invalidPackage(detail)
    }
    return total + value
  }

  private func copyAndHash(from source: URL, to destination: URL) throws
    -> (byteCount: Int64, checksumSHA256: String)
  {
    guard fileManager.fileExists(atPath: source.path) else {
      throw LibraryBackupError.missingPayload(source.lastPathComponent)
    }
    fileManager.createFile(atPath: destination.path, contents: nil)
    let digest = try StreamingFileIO.copyAndHash(from: source, to: destination)
    return (digest.byteCount, digest.checksumSHA256)
  }

  private func hashFile(at url: URL) throws -> (byteCount: Int64, checksumSHA256: String) {
    let digest = try StreamingFileIO.hashFile(at: url)
    return (digest.byteCount, digest.checksumSHA256)
  }

  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func filenameTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
    return formatter.string(from: date)
  }
}
