import CryptoKit
import Foundation

enum PortableBackupKind: String, Codable, CaseIterable, Sendable {
  case metadataOnly
  case includingMedia

  var displayName: String {
    switch self {
    case .metadataOnly: "Metadata only"
    case .includingMedia: "Metadata and audio"
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
      "This backup uses unsupported format version \(version). Update Player before restoring it."
    case .unsupportedLibrarySchema(let version):
      "This backup contains library schema \(version), which this version of Player cannot read."
    case .invalidPackage(let detail):
      "This Player backup is invalid: \(detail)"
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
  func prepareExport(library: LibrarySnapshot, kind: PortableBackupKind) async throws
    -> PreparedLibraryBackup
  func discardPreparedExport(_ backup: PreparedLibraryBackup) async
  func restore(from backupURL: URL) async throws -> LibrarySnapshot
}

actor DisabledLibraryBackupManager: LibraryBackupManaging {
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

  init(
    rootURL: URL,
    fileManager: FileManager = .default,
    clock: any PlayerClock = SystemPlayerClock()
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
    self.clock = clock
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
    let exportRoot = rootURL.appending(path: "BackupExports", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
    let packageURL = exportRoot.appending(
      path: "Player Library \(Self.filenameTimestamp(clock.now())).playerbackup",
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
          let relativePath = try validatedMediaPath(asset.managedRelativePath)
          let source = rootURL.appending(path: relativePath).standardizedFileURL
          guard fileManager.fileExists(atPath: source.path) else {
            throw LibraryBackupError.missingPayload(relativePath)
          }
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
          exportedBytes += identity.byteCount
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
      try manifestData.write(
        to: packageURL.appending(path: "manifest.json"),
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      exportedBytes += Int64(manifestData.count)
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

  func discardPreparedExport(_ backup: PreparedLibraryBackup) {
    let exportRoot =
      rootURL.appending(path: "BackupExports", directoryHint: .isDirectory)
      .standardizedFileURL.path + "/"
    guard backup.url.standardizedFileURL.path.hasPrefix(exportRoot) else { return }
    try? fileManager.removeItem(at: backup.url)
  }

  func restore(from backupURL: URL) async throws -> LibrarySnapshot {
    let accessed = backupURL.startAccessingSecurityScopedResource()
    defer { if accessed { backupURL.stopAccessingSecurityScopedResource() } }

    let manifestURL = backupURL.appending(path: "manifest.json")
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      throw LibraryBackupError.invalidPackage("manifest.json is missing.")
    }
    let manifest: PortableLibraryManifest
    do {
      manifest = try JSONDecoder.playerDecoder.decode(
        PortableLibraryManifest.self,
        from: Data(contentsOf: manifestURL)
      )
    } catch {
      throw LibraryBackupError.invalidPackage("manifest.json could not be decoded.")
    }
    guard manifest.formatVersion == PortableLibraryManifest.currentFormatVersion else {
      throw LibraryBackupError.unsupportedFormat(manifest.formatVersion)
    }
    guard manifest.librarySchemaVersion <= CodableLibraryStore.currentSchemaVersion else {
      throw LibraryBackupError.unsupportedLibrarySchema(manifest.librarySchemaVersion)
    }
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
      for asset in manifest.library.books.flatMap(\.assets) {
        let relativePath = try validatedMediaPath(asset.managedRelativePath)
        let localURL = rootURL.appending(path: relativePath)
        guard fileManager.fileExists(atPath: localURL.path) else {
          throw LibraryBackupError.localMediaRequired(relativePath)
        }
        let identity = try hashFile(at: localURL)
        guard identity.checksumSHA256 == asset.checksumSHA256.lowercased() else {
          throw LibraryBackupError.invalidPayload(relativePath)
        }
      }
      try await CodableLibraryStore(fileURL: rootURL.appending(path: "Library.json")).save(
        manifest.library
      )
      return manifest.library
    }

    let normalizedPayloads = try manifest.media.map { payload in
      (try validatedMediaPath(payload.relativePath), payload)
    }
    guard Set(normalizedPayloads.map(\.0)).count == normalizedPayloads.count else {
      throw LibraryBackupError.invalidPackage("the media catalog contains duplicate paths.")
    }
    let payloadByPath = Dictionary(uniqueKeysWithValues: normalizedPayloads)
    guard Set(payloadByPath.keys) == expectedPaths else {
      throw LibraryBackupError.invalidPackage("the media catalog does not match the library.")
    }

    let restoreID = UUID().uuidString.lowercased()
    let transactionRoot = rootURL.appending(path: "BackupRestore/\(restoreID)")
    let stagedMedia = transactionRoot.appending(path: "Media", directoryHint: .isDirectory)
    let previousMedia = transactionRoot.appending(
      path: "PreviousMedia", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: stagedMedia, withIntermediateDirectories: true)
    do {
      for relativePath in expectedPaths.sorted() {
        guard let payload = payloadByPath[relativePath] else {
          throw LibraryBackupError.missingPayload(relativePath)
        }
        guard
          let asset = manifest.library.books.flatMap(\.assets).first(where: {
            $0.managedRelativePath == relativePath
          }), payload.byteCount == asset.byteCount,
          payload.checksumSHA256.lowercased() == asset.checksumSHA256.lowercased()
        else { throw LibraryBackupError.invalidPayload(relativePath) }
        let source = backupURL.appending(path: relativePath).standardizedFileURL
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

      let liveMedia = rootURL.appending(path: "Media", directoryHint: .isDirectory)
      var movedPreviousMedia = false
      if fileManager.fileExists(atPath: liveMedia.path) {
        try fileManager.moveItem(at: liveMedia, to: previousMedia)
        movedPreviousMedia = true
      }
      do {
        try fileManager.moveItem(at: stagedMedia, to: liveMedia)
        try await CodableLibraryStore(fileURL: rootURL.appending(path: "Library.json")).save(
          manifest.library
        )
      } catch {
        try? fileManager.removeItem(at: liveMedia)
        if movedPreviousMedia { try? fileManager.moveItem(at: previousMedia, to: liveMedia) }
        throw error
      }
      try? fileManager.removeItem(at: transactionRoot)
      return manifest.library
    } catch {
      try? fileManager.removeItem(at: transactionRoot)
      throw error
    }
  }

  private func validateArtwork(in manifest: PortableLibraryManifest) throws {
    let expected = Dictionary(
      uniqueKeysWithValues: manifest.library.books.compactMap {
        book -> (UUID, Data)? in book.artworkData.map { (book.id, $0) }
      })
    guard Set(manifest.artwork.map(\.bookID)).count == manifest.artwork.count else {
      throw LibraryBackupError.invalidPackage("the artwork catalog contains duplicate entries.")
    }
    let supplied = Dictionary(uniqueKeysWithValues: manifest.artwork.map { ($0.bookID, $0) })
    guard expected.count == supplied.count else {
      throw LibraryBackupError.invalidPackage("the artwork catalog does not match the library.")
    }
    for (bookID, data) in expected {
      guard let digest = supplied[bookID], digest.byteCount == Int64(data.count),
        digest.checksumSHA256.lowercased() == Self.hash(data)
      else { throw LibraryBackupError.invalidPackage("artwork failed its integrity check.") }
    }
  }

  private func validatedMediaPath(_ path: String) throws -> String {
    let candidate = rootURL.appending(path: path).standardizedFileURL
    let mediaRoot =
      rootURL.appending(path: "Media", directoryHint: .isDirectory)
      .standardizedFileURL.path + "/"
    guard candidate.path.hasPrefix(mediaRoot), !path.hasPrefix("/"), !path.contains("..") else {
      throw LibraryBackupError.invalidPackage("a media path escapes managed storage.")
    }
    return String(candidate.path.dropFirst(rootURL.path.count + 1))
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
