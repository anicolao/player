import Compression
import CryptoKit
import Foundation

struct ZipExtractionPolicy: Equatable, Sendable {
  var maximumEntryCount: Int = 10_000
  var maximumCentralDirectoryBytes: UInt64 = 64 * 1_024 * 1_024
  var maximumEntryBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
  var maximumTotalBytes: UInt64 = 32 * 1_024 * 1_024 * 1_024
  var maximumEntryExpansionRatio: Double = 250
  var maximumTotalExpansionRatio: Double = 150
  var bufferBytes: Int = 256 * 1_024
  var allowedAudioExtensions: Set<String> = ["m4a", "m4b", "mp3"]

  static let audiobook = ZipExtractionPolicy()
}

enum ZipCheckpointState: String, Codable, Equatable, Sendable {
  case extracting
  case cancelled
  case failedRecoverable
  case failedTerminal
  case complete
}

enum ZipImportErrorCode: String, Codable, Equatable, Sendable {
  case invalidArchive
  case multiVolume
  case encryptedEntry
  case unsupportedCompression
  case unsafePath
  case linkEntry
  case duplicatePath
  case tooManyEntries
  case entryTooLarge
  case archiveTooLarge
  case expansionRatio
  case checksumMismatch
  case noAudio
  case archiveChanged
  case fileOperation
}

struct ZipCheckpointFailure: Codable, Equatable, Sendable {
  var code: ZipImportErrorCode
  var message: String
  var entryPath: String?
  var isRecoverable: Bool
}

struct ZipCompletedEntry: Codable, Equatable, Sendable {
  var centralDirectoryIndex: Int
  var relativePath: String
  var byteCount: UInt64
  var crc32: UInt32
}

struct ZipExtractionCheckpoint: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int
  var archiveSHA256: String
  var archiveByteCount: UInt64
  var state: ZipCheckpointState
  var completedEntries: [ZipCompletedEntry]
  var extractedBytes: UInt64
  var totalBytes: UInt64
  var totalEntries: Int
  var failure: ZipCheckpointFailure?

  init(
    archiveSHA256: String,
    archiveByteCount: UInt64,
    state: ZipCheckpointState = .extracting,
    completedEntries: [ZipCompletedEntry] = [],
    extractedBytes: UInt64 = 0,
    totalBytes: UInt64,
    totalEntries: Int = 0,
    failure: ZipCheckpointFailure? = nil
  ) {
    self.version = Self.currentVersion
    self.archiveSHA256 = archiveSHA256
    self.archiveByteCount = archiveByteCount
    self.state = state
    self.completedEntries = completedEntries
    self.extractedBytes = extractedBytes
    self.totalBytes = totalBytes
    self.totalEntries = totalEntries
    self.failure = failure
  }
}

protocol ZipExtracting: Sendable {
  func extract(
    archiveURL: URL,
    destinationRoot: URL,
    checkpointURL: URL,
    progress: @escaping @Sendable (ZipExtractionProgress) async -> Void
  ) async throws -> ZipExtractionResult

  func cancelAndClean(destinationRoot: URL, checkpointURL: URL) async throws
}

struct ZipExtractionProgress: Equatable, Sendable {
  var completedEntries: Int
  var totalEntries: Int
  var extractedBytes: UInt64
  var totalBytes: UInt64
  var currentRelativePath: String?
}

struct ZipExtractedFile: Equatable, Sendable {
  var centralDirectoryIndex: Int
  var relativePath: String
  var fileURL: URL
  var byteCount: UInt64
  var crc32: UInt32
}

struct ZipExtractionResult: Equatable, Sendable {
  var files: [ZipExtractedFile]
  var checkpoint: ZipExtractionCheckpoint
}

struct ZipImportWorkspace: Equatable, Sendable {
  var destinationRoot: URL
  var checkpointURL: URL
  var extractionRelativePath: String
  var checkpointRelativePath: String
}

enum ZipImportError: LocalizedError, Equatable, Sendable {
  case invalidArchive(String)
  case multiVolume
  case encryptedEntry(String)
  case unsupportedCompression(path: String, method: UInt16)
  case unsafePath(String)
  case linkEntry(String)
  case duplicatePath(String)
  case tooManyEntries(limit: Int, actual: UInt64)
  case entryTooLarge(path: String, limit: UInt64, actual: UInt64)
  case archiveTooLarge(limit: UInt64, actual: UInt64)
  case expansionRatio(path: String?, limit: Double, actual: Double)
  case checksumMismatch(String)
  case noAudio
  case archiveChanged
  case fileOperation(String)

  var code: ZipImportErrorCode {
    switch self {
    case .invalidArchive: .invalidArchive
    case .multiVolume: .multiVolume
    case .encryptedEntry: .encryptedEntry
    case .unsupportedCompression: .unsupportedCompression
    case .unsafePath: .unsafePath
    case .linkEntry: .linkEntry
    case .duplicatePath: .duplicatePath
    case .tooManyEntries: .tooManyEntries
    case .entryTooLarge: .entryTooLarge
    case .archiveTooLarge: .archiveTooLarge
    case .expansionRatio: .expansionRatio
    case .checksumMismatch: .checksumMismatch
    case .noAudio: .noAudio
    case .archiveChanged: .archiveChanged
    case .fileOperation: .fileOperation
    }
  }

  var isRecoverable: Bool {
    switch self {
    case .fileOperation: true
    default: false
    }
  }

  var affectedPath: String? {
    switch self {
    case .encryptedEntry(let path), .unsafePath(let path), .linkEntry(let path),
      .duplicatePath(let path), .checksumMismatch(let path): path
    case .unsupportedCompression(let path, _), .entryTooLarge(let path, _, _): path
    case .expansionRatio(let path, _, _): path
    default: nil
    }
  }

  var reasonCode: String {
    switch self {
    case .unsafePath: "path-traversal"
    case .linkEntry: "symlink"
    case .expansionRatio: "compression-ratio"
    case .tooManyEntries: "entry-count"
    case .entryTooLarge: "entry-size"
    case .encryptedEntry: "encrypted-entry"
    case .unsupportedCompression: "unsupported-compression"
    case .duplicatePath: "duplicate-path"
    case .archiveTooLarge: "archive-size"
    case .checksumMismatch: "checksum-mismatch"
    case .noAudio: "no-audio"
    case .archiveChanged: "archive-changed"
    case .multiVolume: "multi-volume"
    case .invalidArchive: "invalid-archive"
    case .fileOperation: "file-operation"
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidArchive(let reason): "This ZIP is invalid: \(reason)"
    case .multiVolume: "Multi-volume ZIP archives are not supported."
    case .encryptedEntry(let path): "The encrypted ZIP entry \(path) cannot be imported."
    case .unsupportedCompression(let path, let method):
      "The ZIP entry \(path) uses unsupported compression method \(method)."
    case .unsafePath(let path): "The ZIP contains an unsafe path: \(path)."
    case .linkEntry(let path): "The ZIP contains a link or special file: \(path)."
    case .duplicatePath(let path): "The ZIP contains duplicate output path \(path)."
    case .tooManyEntries(let limit, let actual):
      "This ZIP contains \(actual) entries; the safety limit is \(limit)."
    case .entryTooLarge(let path, let limit, let actual):
      "The ZIP entry \(path) expands to \(actual) bytes; the safety limit is \(limit)."
    case .archiveTooLarge(let limit, let actual):
      "This ZIP expands to \(actual) bytes; the safety limit is \(limit)."
    case .expansionRatio(let path, let limit, let actual):
      "\(path.map { "The ZIP entry \($0)" } ?? "This ZIP") has expansion ratio \(actual); the safety limit is \(limit)."
    case .checksumMismatch(let path): "The extracted ZIP entry \(path) failed its checksum."
    case .noAudio: "This ZIP contains no supported M4A, M4B, or MP3 audio files."
    case .archiveChanged: "The ZIP changed after extraction began. Start the import again."
    case .fileOperation(let message): message
    }
  }
}

actor SafeZipExtractor: ZipExtracting {
  typealias ProgressHandler = @Sendable (ZipExtractionProgress) async -> Void

  private let fileManager: FileManager
  private let policy: ZipExtractionPolicy

  init(policy: ZipExtractionPolicy = .audiobook, fileManager: FileManager = .default) {
    self.policy = policy
    self.fileManager = fileManager
  }

  func extract(
    archiveURL: URL,
    destinationRoot: URL,
    checkpointURL: URL,
    progress: @escaping ProgressHandler = { _ in }
  ) async throws -> ZipExtractionResult {
    let archiveIdentity = try Self.hashAndSize(of: archiveURL)
    var checkpoint: ZipExtractionCheckpoint?
    do {
      let catalog = try parseAndValidateCatalog(at: archiveURL)
      let audioEntries = catalog.entries.filter {
        !$0.isDirectory && policy.allowedAudioExtensions.contains(
          URL(filePath: $0.relativePath).pathExtension.lowercased()
        )
      }
      guard !audioEntries.isEmpty else { throw ZipImportError.noAudio }

      checkpoint = try loadOrCreateCheckpoint(
        at: checkpointURL,
        identity: archiveIdentity,
        totalBytes: audioEntries.reduce(0) { $0 + $1.uncompressedSize },
        totalEntries: catalog.entries.count
      )
      try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
      var completed = Dictionary(
        uniqueKeysWithValues: checkpoint!.completedEntries.map { ($0.centralDirectoryIndex, $0) }
      )

      for entry in audioEntries {
        try Task.checkCancellation()
        let outputURL = try confinedOutputURL(
          for: entry.relativePath,
          destinationRoot: destinationRoot
        )
        if let prior = completed[entry.index],
          prior.relativePath == entry.relativePath,
          try Self.fileMatches(outputURL, byteCount: prior.byteCount, crc32: prior.crc32)
        {
          continue
        }
        completed.removeValue(forKey: entry.index)
        try? fileManager.removeItem(at: outputURL)
        let partialURL = outputURL.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partialURL)
        try fileManager.createDirectory(
          at: outputURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )

        await progress(
          ZipExtractionProgress(
            completedEntries: completed.count,
            totalEntries: audioEntries.count,
            extractedBytes: checkpoint!.extractedBytes,
            totalBytes: checkpoint!.totalBytes,
            currentRelativePath: entry.relativePath
          )
        )
        do {
          let crc = try extractEntry(entry, from: archiveURL, to: partialURL)
          guard crc == entry.crc32 else { throw ZipImportError.checksumMismatch(entry.relativePath) }
          try fileManager.moveItem(at: partialURL, to: outputURL)
        } catch {
          try? fileManager.removeItem(at: partialURL)
          throw error
        }

        let finished = ZipCompletedEntry(
          centralDirectoryIndex: entry.index,
          relativePath: entry.relativePath,
          byteCount: entry.uncompressedSize,
          crc32: entry.crc32
        )
        completed[entry.index] = finished
        checkpoint!.completedEntries = completed.values.sorted {
          $0.centralDirectoryIndex < $1.centralDirectoryIndex
        }
        checkpoint!.extractedBytes = checkpoint!.completedEntries.reduce(0) { $0 + $1.byteCount }
        checkpoint!.state = .extracting
        checkpoint!.failure = nil
        try Self.saveCheckpoint(checkpoint!, to: checkpointURL)
      }

      checkpoint!.state = .complete
      checkpoint!.extractedBytes = checkpoint!.totalBytes
      checkpoint!.failure = nil
      try Self.saveCheckpoint(checkpoint!, to: checkpointURL)
      await progress(
        ZipExtractionProgress(
          completedEntries: audioEntries.count,
          totalEntries: audioEntries.count,
          extractedBytes: checkpoint!.totalBytes,
          totalBytes: checkpoint!.totalBytes,
          currentRelativePath: nil
        )
      )
      let completedByIndex = Dictionary(
        uniqueKeysWithValues: checkpoint!.completedEntries.map { ($0.centralDirectoryIndex, $0) }
      )
      return ZipExtractionResult(
        files: try audioEntries.map { entry in
          let completedEntry = completedByIndex[entry.index]!
          return ZipExtractedFile(
            centralDirectoryIndex: entry.index,
            relativePath: entry.relativePath,
            fileURL: try confinedOutputURL(
              for: entry.relativePath,
              destinationRoot: destinationRoot
            ),
            byteCount: completedEntry.byteCount,
            crc32: completedEntry.crc32
          )
        },
        checkpoint: checkpoint!
      )
    } catch is CancellationError {
      if var checkpoint {
        checkpoint.state = .cancelled
        checkpoint.failure = nil
        try? Self.saveCheckpoint(checkpoint, to: checkpointURL)
      }
      throw CancellationError()
    } catch {
      let zipError = (error as? ZipImportError)
        ?? ZipImportError.fileOperation(error.localizedDescription)
      var failed = checkpoint ?? ZipExtractionCheckpoint(
        archiveSHA256: archiveIdentity.sha256,
        archiveByteCount: archiveIdentity.byteCount,
        totalBytes: 0,
        totalEntries: (try? declaredEntryCount(at: archiveURL)) ?? 0
      )
      failed.state = zipError.isRecoverable ? .failedRecoverable : .failedTerminal
      failed.failure = ZipCheckpointFailure(
        code: zipError.code,
        message: zipError.localizedDescription,
        entryPath: zipError.affectedPath,
        isRecoverable: zipError.isRecoverable
      )
      try? Self.saveCheckpoint(failed, to: checkpointURL)
      throw zipError
    }
  }

  func cancelAndClean(destinationRoot: URL, checkpointURL: URL) throws {
    try? fileManager.removeItem(at: destinationRoot)
    try? fileManager.removeItem(at: checkpointURL)
  }

  private func loadOrCreateCheckpoint(
    at url: URL,
    identity: ArchiveIdentity,
    totalBytes: UInt64,
    totalEntries: Int
  ) throws -> ZipExtractionCheckpoint {
    guard fileManager.fileExists(atPath: url.path) else {
      let fresh = ZipExtractionCheckpoint(
        archiveSHA256: identity.sha256,
        archiveByteCount: identity.byteCount,
        totalBytes: totalBytes,
        totalEntries: totalEntries
      )
      try Self.saveCheckpoint(fresh, to: url)
      return fresh
    }
    do {
      let existing = try JSONDecoder().decode(
        ZipExtractionCheckpoint.self,
        from: Data(contentsOf: url)
      )
      guard
        existing.version == ZipExtractionCheckpoint.currentVersion,
        existing.archiveSHA256 == identity.sha256,
        existing.archiveByteCount == identity.byteCount,
        existing.totalBytes == totalBytes,
        existing.totalEntries == totalEntries
      else { throw ZipImportError.archiveChanged }
      return existing
    } catch let error as ZipImportError {
      throw error
    } catch {
      throw ZipImportError.fileOperation("The ZIP extraction checkpoint is unreadable.")
    }
  }

  private func declaredEntryCount(at archiveURL: URL) throws -> Int {
    let handle = try FileHandle(forReadingFrom: archiveURL)
    defer { try? handle.close() }
    let archiveSize = try handle.seekToEnd()
    guard archiveSize >= 22 else { return 0 }
    let tailSize = Int(min(archiveSize, 65_557))
    try handle.seek(toOffset: archiveSize - UInt64(tailSize))
    let tail = try Self.readExactly(handle, count: tailSize)
    guard let offset = tail.lastOffset(of: 0x0605_4B50) else { return 0 }
    let eocd = Data(tail.suffix(from: offset))
    return Int(try eocd.littleUInt16(at: 10))
  }

  private func parseAndValidateCatalog(at archiveURL: URL) throws -> ZipCatalog {
    let handle: FileHandle
    do { handle = try FileHandle(forReadingFrom: archiveURL) }
    catch { throw ZipImportError.fileOperation("The ZIP could not be opened for reading.") }
    defer { try? handle.close() }
    let archiveSize = try handle.seekToEnd()
    guard archiveSize >= 22 else { throw ZipImportError.invalidArchive("missing end record") }
    let tailSize = Int(min(archiveSize, 65_557))
    try handle.seek(toOffset: archiveSize - UInt64(tailSize))
    let tail = try Self.readExactly(handle, count: tailSize)
    guard let eocdOffset = tail.lastOffset(of: 0x0605_4B50) else {
      throw ZipImportError.invalidArchive("missing end record")
    }
    let eocd = Data(tail.suffix(from: eocdOffset))
    guard eocd.count >= 22 else { throw ZipImportError.invalidArchive("truncated end record") }
    let commentLength = Int(try eocd.littleUInt16(at: 20))
    guard eocd.count == 22 + commentLength else {
      throw ZipImportError.invalidArchive("unexpected bytes after the end record")
    }
    let disk = try eocd.littleUInt16(at: 4)
    let centralDisk = try eocd.littleUInt16(at: 6)
    guard disk == 0, centralDisk == 0 else { throw ZipImportError.multiVolume }

    var entryCount = UInt64(try eocd.littleUInt16(at: 10))
    var centralSize = UInt64(try eocd.littleUInt32(at: 12))
    var centralOffset = UInt64(try eocd.littleUInt32(at: 16))
    if entryCount == UInt64(UInt16.max)
      || centralSize == UInt64(UInt32.max)
      || centralOffset == UInt64(UInt32.max)
    {
      let absoluteEOCDOffset = archiveSize - UInt64(tailSize) + UInt64(eocdOffset)
      guard absoluteEOCDOffset >= 20 else {
        throw ZipImportError.invalidArchive("missing ZIP64 locator")
      }
      try handle.seek(toOffset: absoluteEOCDOffset - 20)
      let locator = try Self.readExactly(handle, count: 20)
      guard try locator.littleUInt32(at: 0) == 0x0706_4B50 else {
        throw ZipImportError.invalidArchive("missing ZIP64 locator")
      }
      guard try locator.littleUInt32(at: 4) == 0, try locator.littleUInt32(at: 16) == 1 else {
        throw ZipImportError.multiVolume
      }
      let zip64Offset = try locator.littleUInt64(at: 8)
      try handle.seek(toOffset: zip64Offset)
      let zip64 = try Self.readExactly(handle, count: 56)
      guard try zip64.littleUInt32(at: 0) == 0x0606_4B50 else {
        throw ZipImportError.invalidArchive("missing ZIP64 end record")
      }
      guard try zip64.littleUInt32(at: 16) == 0, try zip64.littleUInt32(at: 20) == 0 else {
        throw ZipImportError.multiVolume
      }
      entryCount = try zip64.littleUInt64(at: 32)
      centralSize = try zip64.littleUInt64(at: 40)
      centralOffset = try zip64.littleUInt64(at: 48)
    }

    guard entryCount <= UInt64(policy.maximumEntryCount) else {
      throw ZipImportError.tooManyEntries(limit: policy.maximumEntryCount, actual: entryCount)
    }
    guard centralSize <= policy.maximumCentralDirectoryBytes else {
      throw ZipImportError.archiveTooLarge(
        limit: policy.maximumCentralDirectoryBytes,
        actual: centralSize
      )
    }
    guard centralOffset <= archiveSize, centralSize <= archiveSize - centralOffset else {
      throw ZipImportError.invalidArchive("central directory is outside the archive")
    }

    try handle.seek(toOffset: centralOffset)
    var entries: [ZipCatalogEntry] = []
    var totalUncompressed: UInt64 = 0
    var totalCompressed: UInt64 = 0
    var canonicalPaths: Set<String> = []
    for index in 0..<Int(entryCount) {
      let fixed = try Self.readExactly(handle, count: 46)
      guard try fixed.littleUInt32(at: 0) == 0x0201_4B50 else {
        throw ZipImportError.invalidArchive("invalid central directory entry")
      }
      let versionMadeBy = try fixed.littleUInt16(at: 4)
      let flags = try fixed.littleUInt16(at: 8)
      let method = try fixed.littleUInt16(at: 10)
      let crc32 = try fixed.littleUInt32(at: 16)
      var compressed = UInt64(try fixed.littleUInt32(at: 20))
      var uncompressed = UInt64(try fixed.littleUInt32(at: 24))
      let nameLength = Int(try fixed.littleUInt16(at: 28))
      let extraLength = Int(try fixed.littleUInt16(at: 30))
      let commentLength = Int(try fixed.littleUInt16(at: 32))
      let startDisk = try fixed.littleUInt16(at: 34)
      let externalAttributes = try fixed.littleUInt32(at: 38)
      var localOffset = UInt64(try fixed.littleUInt32(at: 42))
      let nameData = try Self.readExactly(handle, count: nameLength)
      let extra = try Self.readExactly(handle, count: extraLength)
      _ = try Self.readExactly(handle, count: commentLength)
      guard startDisk == 0 else { throw ZipImportError.multiVolume }
      let name = try Self.decodeFilename(nameData, utf8: flags & 0x0800 != 0)
      let relativePath = try Self.safeRelativePath(name)

      var zip64Cursor: Data.Cursor?
      if compressed == UInt64(UInt32.max)
        || uncompressed == UInt64(UInt32.max)
        || localOffset == UInt64(UInt32.max)
      {
        zip64Cursor = try extra.zip64ExtraCursor()
      }
      if uncompressed == UInt64(UInt32.max) {
        uncompressed = try zip64Cursor!.readUInt64()
      }
      if compressed == UInt64(UInt32.max) {
        compressed = try zip64Cursor!.readUInt64()
      }
      if localOffset == UInt64(UInt32.max) {
        localOffset = try zip64Cursor!.readUInt64()
      }

      let unixMode = UInt16((externalAttributes >> 16) & 0xF000)
      let isDirectory = relativePath.hasSuffix("/")
        || unixMode == 0x4000
        || externalAttributes & 0x10 != 0
      if unixMode == 0xA000 || (![0, 0x4000, 0x8000].contains(unixMode)) {
        throw ZipImportError.linkEntry(relativePath)
      }
      if flags & 0x2041 != 0 { throw ZipImportError.encryptedEntry(relativePath) }
      guard isDirectory || method == 0 || method == 8 else {
        throw ZipImportError.unsupportedCompression(path: relativePath, method: method)
      }
      guard uncompressed <= policy.maximumEntryBytes else {
        throw ZipImportError.entryTooLarge(
          path: relativePath,
          limit: policy.maximumEntryBytes,
          actual: uncompressed
        )
      }
      let ratio = Self.expansionRatio(uncompressed: uncompressed, compressed: compressed)
      guard isDirectory || ratio <= policy.maximumEntryExpansionRatio else {
        throw ZipImportError.expansionRatio(
          path: relativePath,
          limit: policy.maximumEntryExpansionRatio,
          actual: ratio
        )
      }
      guard totalUncompressed <= policy.maximumTotalBytes - min(uncompressed, policy.maximumTotalBytes) else {
        throw ZipImportError.archiveTooLarge(
          limit: policy.maximumTotalBytes,
          actual: UInt64.max
        )
      }
      totalUncompressed += uncompressed
      totalCompressed = totalCompressed.addingReportingOverflow(compressed).partialValue
      guard totalUncompressed <= policy.maximumTotalBytes else {
        throw ZipImportError.archiveTooLarge(
          limit: policy.maximumTotalBytes,
          actual: totalUncompressed
        )
      }
      let canonical = Self.canonicalCollisionPath(relativePath)
      guard canonicalPaths.insert(canonical).inserted else {
        throw ZipImportError.duplicatePath(relativePath)
      }
      entries.append(
        ZipCatalogEntry(
          index: index,
          relativePath: relativePath,
          flags: flags,
          method: method,
          crc32: crc32,
          compressedSize: compressed,
          uncompressedSize: uncompressed,
          localHeaderOffset: localOffset,
          isDirectory: isDirectory,
          versionMadeBy: versionMadeBy
        )
      )
    }
    let totalRatio = Self.expansionRatio(
      uncompressed: totalUncompressed,
      compressed: totalCompressed
    )
    guard totalRatio <= policy.maximumTotalExpansionRatio else {
      throw ZipImportError.expansionRatio(
        path: nil,
        limit: policy.maximumTotalExpansionRatio,
        actual: totalRatio
      )
    }

    var occupiedRanges: [(Range<UInt64>, String)] = []
    for index in entries.indices where !entries[index].isDirectory {
      let dataOffset = try localDataOffset(
        for: entries[index],
        handle: handle,
        centralDirectoryOffset: centralOffset
      )
      entries[index].dataOffset = dataOffset
      let end = dataOffset.addingReportingOverflow(entries[index].compressedSize)
      guard !end.overflow, end.partialValue <= centralOffset else {
        throw ZipImportError.invalidArchive("entry data overlaps the central directory")
      }
      occupiedRanges.append((dataOffset..<end.partialValue, entries[index].relativePath))
    }
    occupiedRanges.sort { $0.0.lowerBound < $1.0.lowerBound }
    for pair in zip(occupiedRanges, occupiedRanges.dropFirst()) where pair.0.0.overlaps(pair.1.0) {
      throw ZipImportError.invalidArchive("ZIP entries have overlapping data")
    }
    return ZipCatalog(entries: entries)
  }

  private func localDataOffset(
    for entry: ZipCatalogEntry,
    handle: FileHandle,
    centralDirectoryOffset: UInt64
  ) throws -> UInt64 {
    guard entry.localHeaderOffset <= centralDirectoryOffset,
      centralDirectoryOffset - entry.localHeaderOffset >= 30
    else { throw ZipImportError.invalidArchive("invalid local header offset") }
    try handle.seek(toOffset: entry.localHeaderOffset)
    let local = try Self.readExactly(handle, count: 30)
    guard try local.littleUInt32(at: 0) == 0x0403_4B50 else {
      throw ZipImportError.invalidArchive("missing local entry header")
    }
    let flags = try local.littleUInt16(at: 6)
    let method = try local.littleUInt16(at: 8)
    guard flags & 0x2041 == 0 else { throw ZipImportError.encryptedEntry(entry.relativePath) }
    guard method == entry.method else {
      throw ZipImportError.invalidArchive("local compression method differs from catalog")
    }
    let nameLength = UInt64(try local.littleUInt16(at: 26))
    let extraLength = UInt64(try local.littleUInt16(at: 28))
    let base = entry.localHeaderOffset.addingReportingOverflow(30)
    let withName = base.partialValue.addingReportingOverflow(nameLength)
    let withExtra = withName.partialValue.addingReportingOverflow(extraLength)
    guard !base.overflow, !withName.overflow, !withExtra.overflow else {
      throw ZipImportError.invalidArchive("local entry header overflows the archive")
    }
    return withExtra.partialValue
  }

  private func extractEntry(
    _ entry: ZipCatalogEntry,
    from archiveURL: URL,
    to outputURL: URL
  ) throws -> UInt32 {
    let input = try FileHandle(forReadingFrom: archiveURL)
    defer { try? input.close() }
    try input.seek(toOffset: entry.dataOffset)
    fileManager.createFile(atPath: outputURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let crc: UInt32
    switch entry.method {
    case 0:
      crc = try copyStored(
        input: input,
        output: output,
        compressedSize: entry.compressedSize,
        expectedSize: entry.uncompressedSize
      )
    case 8:
      crc = try Self.inflate(
        input: input,
        output: output,
        compressedSize: entry.compressedSize,
        expectedSize: entry.uncompressedSize,
        bufferBytes: policy.bufferBytes
      )
    default:
      throw ZipImportError.unsupportedCompression(path: entry.relativePath, method: entry.method)
    }
    try output.synchronize()
    return crc
  }

  private func copyStored(
    input: FileHandle,
    output: FileHandle,
    compressedSize: UInt64,
    expectedSize: UInt64
  ) throws -> UInt32 {
    guard compressedSize == expectedSize else {
      throw ZipImportError.invalidArchive("stored entry sizes disagree")
    }
    var remaining = compressedSize
    var crc = CRC32()
    while remaining > 0 {
      try Task.checkCancellation()
      let count = Int(min(UInt64(policy.bufferBytes), remaining))
      let data = try Self.readExactly(input, count: count)
      crc.update(data)
      try output.write(contentsOf: data)
      remaining -= UInt64(data.count)
    }
    return crc.finalized
  }

  private nonisolated static func inflate(
    input: FileHandle,
    output: FileHandle,
    compressedSize: UInt64,
    expectedSize: UInt64,
    bufferBytes: Int
  ) throws -> UInt32 {
    let initialPointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    defer { initialPointer.deallocate() }
    var stream = compression_stream(
      dst_ptr: initialPointer,
      dst_size: 0,
      src_ptr: UnsafePointer(initialPointer),
      src_size: 0,
      state: nil
    )
    guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
      != COMPRESSION_STATUS_ERROR
    else { throw ZipImportError.invalidArchive("the deflate stream could not be initialized") }
    defer { compression_stream_destroy(&stream) }
    var remaining = compressedSize
    var producedTotal: UInt64 = 0
    var crc = CRC32()
    var reachedEnd = false
    let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferBytes)
    defer { outputBuffer.deallocate() }

    while remaining > 0, !reachedEnd {
      try Task.checkCancellation()
      let count = Int(min(UInt64(bufferBytes), remaining))
      let inputData = try Self.readExactly(input, count: count)
      remaining -= UInt64(count)
      try inputData.withUnsafeBytes { rawBuffer in
        guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
        stream.src_ptr = source
        stream.src_size = inputData.count
        repeat {
          stream.dst_ptr = outputBuffer
          stream.dst_size = bufferBytes
          let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
          let status = compression_stream_process(&stream, flags)
          guard status != COMPRESSION_STATUS_ERROR else {
            throw ZipImportError.invalidArchive("an entry contains invalid deflate data")
          }
          let produced = bufferBytes - stream.dst_size
          if produced > 0 {
            guard producedTotal <= expectedSize, UInt64(produced) <= expectedSize - producedTotal else {
              throw ZipImportError.invalidArchive("an entry expanded beyond its declared size")
            }
            let data = Data(bytes: outputBuffer, count: produced)
            crc.update(data)
            try output.write(contentsOf: data)
            producedTotal += UInt64(produced)
          }
          reachedEnd = status == COMPRESSION_STATUS_END
        } while stream.src_size > 0 || (remaining == 0 && !reachedEnd)
      }
    }
    guard reachedEnd, remaining == 0, producedTotal == expectedSize else {
      throw ZipImportError.invalidArchive("an entry's deflate stream ended unexpectedly")
    }
    return crc.finalized
  }

  private func confinedOutputURL(for relativePath: String, destinationRoot: URL) throws -> URL {
    let root = destinationRoot.standardizedFileURL
    let candidate = root.appending(path: relativePath).standardizedFileURL
    guard candidate.path.hasPrefix(root.path + "/") else {
      throw ZipImportError.unsafePath(relativePath)
    }
    return candidate
  }

  private static func saveCheckpoint(_ checkpoint: ZipExtractionCheckpoint, to url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(checkpoint).write(to: url, options: [.atomic])
    } catch {
      throw ZipImportError.fileOperation("The ZIP extraction checkpoint could not be saved.")
    }
  }

  private static func hashAndSize(of url: URL) throws -> ArchiveIdentity {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    var byteCount: UInt64 = 0
    while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
      try Task.checkCancellation()
      hash.update(data: data)
      byteCount += UInt64(data.count)
    }
    return ArchiveIdentity(
      sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
      byteCount: byteCount
    )
  }

  private static func fileMatches(_ url: URL, byteCount: UInt64, crc32: UInt32) throws -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, UInt64(values.fileSize ?? -1) == byteCount else { return false }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var crc = CRC32()
    while let data = try handle.read(upToCount: 256 * 1_024), !data.isEmpty {
      try Task.checkCancellation()
      crc.update(data)
    }
    return crc.finalized == crc32
  }

  private static func decodeFilename(_ data: Data, utf8: Bool) throws -> String {
    let value = utf8 ? String(data: data, encoding: .utf8) : String(data: data, encoding: .isoLatin1)
    guard let value, !value.isEmpty, !value.contains("\0") else {
      throw ZipImportError.unsafePath("<invalid filename>")
    }
    return value
  }

  private static func safeRelativePath(_ rawPath: String) throws -> String {
    let path = rawPath.replacingOccurrences(of: "\\", with: "/")
      .precomposedStringWithCanonicalMapping
    guard
      !path.hasPrefix("/"),
      !path.hasPrefix("~"),
      !(path.count >= 2 && path[path.index(after: path.startIndex)] == ":")
    else { throw ZipImportError.unsafePath(rawPath) }
    let isDirectory = path.hasSuffix("/")
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    let contentComponents = isDirectory ? components.dropLast() : components[...]
    guard
      !contentComponents.isEmpty,
      contentComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw ZipImportError.unsafePath(rawPath) }
    return contentComponents.joined(separator: "/") + (isDirectory ? "/" : "")
  }

  private static func canonicalCollisionPath(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }

  private static func expansionRatio(uncompressed: UInt64, compressed: UInt64) -> Double {
    if uncompressed == 0 { return 0 }
    if compressed == 0 { return .infinity }
    return Double(uncompressed) / Double(compressed)
  }

  private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
    guard count >= 0 else { throw ZipImportError.invalidArchive("invalid field length") }
    var data = Data()
    data.reserveCapacity(count)
    while data.count < count {
      guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
        throw ZipImportError.invalidArchive("unexpected end of file")
      }
      data.append(chunk)
    }
    return data
  }
}

private struct ZipCatalog {
  var entries: [ZipCatalogEntry]
}

private struct ZipCatalogEntry {
  var index: Int
  var relativePath: String
  var flags: UInt16
  var method: UInt16
  var crc32: UInt32
  var compressedSize: UInt64
  var uncompressedSize: UInt64
  var localHeaderOffset: UInt64
  var isDirectory: Bool
  var versionMadeBy: UInt16
  var dataOffset: UInt64 = 0
}

private struct ArchiveIdentity {
  var sha256: String
  var byteCount: UInt64
}

private struct CRC32 {
  private static let table: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 {
      crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
    }
    return crc
  }

  private var value: UInt32 = 0xFFFF_FFFF

  mutating func update(_ data: Data) {
    for byte in data {
      value = Self.table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
    }
  }

  var finalized: UInt32 { value ^ 0xFFFF_FFFF }
}

private extension Data {
  func littleUInt16(at offset: Int) throws -> UInt16 {
    guard offset >= 0, count - offset >= 2 else {
      throw ZipImportError.invalidArchive("truncated integer field")
    }
    return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
  }

  func littleUInt32(at offset: Int) throws -> UInt32 {
    guard offset >= 0, count - offset >= 4 else {
      throw ZipImportError.invalidArchive("truncated integer field")
    }
    return UInt32(self[offset])
      | UInt32(self[offset + 1]) << 8
      | UInt32(self[offset + 2]) << 16
      | UInt32(self[offset + 3]) << 24
  }

  func littleUInt64(at offset: Int) throws -> UInt64 {
    guard offset >= 0, count - offset >= 8 else {
      throw ZipImportError.invalidArchive("truncated integer field")
    }
    var value: UInt64 = 0
    for index in 0..<8 { value |= UInt64(self[offset + index]) << UInt64(index * 8) }
    return value
  }

  func lastOffset(of signature: UInt32) -> Int? {
    guard count >= 4 else { return nil }
    for offset in stride(from: count - 4, through: 0, by: -1) {
      if (try? littleUInt32(at: offset)) == signature { return offset }
    }
    return nil
  }

  func zip64ExtraCursor() throws -> Cursor {
    var offset = 0
    while count - offset >= 4 {
      let identifier = try littleUInt16(at: offset)
      let size = Int(try littleUInt16(at: offset + 2))
      offset += 4
      guard size <= count - offset else {
        throw ZipImportError.invalidArchive("truncated ZIP64 extra field")
      }
      if identifier == 0x0001 {
        return Cursor(data: self, offset: offset, end: offset + size)
      }
      offset += size
    }
    throw ZipImportError.invalidArchive("missing ZIP64 extra field")
  }

  struct Cursor {
    let data: Data
    var offset: Int
    let end: Int

    mutating func readUInt64() throws -> UInt64 {
      guard end - offset >= 8 else {
        throw ZipImportError.invalidArchive("truncated ZIP64 value")
      }
      defer { offset += 8 }
      return try data.littleUInt64(at: offset)
    }
  }
}
