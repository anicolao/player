import CryptoKit
import Foundation

enum PlayerAppGroup {
  static let identifier = "group.com.spnss.player"
  static let importQueueDirectoryName = "ImportHandoffs"
}

struct ShareImportHandoff: Codable, Equatable, Identifiable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  let id: UUID
  var createdAt: Date
  var items: [ShareImportHandoffItem]

  init(id: UUID = UUID(), createdAt: Date = Date(), items: [ShareImportHandoffItem]) {
    self.schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.createdAt = createdAt
    self.items = items
  }

  var payloadFingerprint: String {
    let canonical = items.map {
      [
        $0.relativePath,
        $0.originalFilename,
        $0.contentTypeIdentifier ?? "",
        String($0.byteCount),
        $0.checksumSHA256.lowercased(),
      ].joined(separator: "|")
    }.joined(separator: "\n")
    return SHA256.hash(data: Data(canonical.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }
}

struct ShareImportHandoffItem: Codable, Equatable, Sendable {
  var relativePath: String
  var originalFilename: String
  var contentTypeIdentifier: String?
  var byteCount: Int64
  var checksumSHA256: String
}

struct ClaimedShareImport: Equatable, Sendable {
  var handoff: ShareImportHandoff
  var fileURLs: [URL]
}

enum ShareImportHandoffError: LocalizedError, Equatable, Sendable {
  case emptySelection
  case unsupportedSchema(Int)
  case invalidPayload
  case unsafeRelativePath(String)
  case missingItem(String)
  case fileOperation(String)

  var errorDescription: String? {
    switch self {
    case .emptySelection: "The share request contains no files."
    case .unsupportedSchema(let version): "Share handoff schema \(version) is not supported."
    case .invalidPayload: "The share handoff is invalid."
    case .unsafeRelativePath(let path): "The share handoff contains an unsafe path: \(path)."
    case .missingItem(let path): "A shared import item is missing: \(path)."
    case .fileOperation(let message): message
    }
  }
}

/// Builds a handoff directly in the shared container while provider URLs are
/// valid. Share extensions have a much smaller memory budget than the host
/// app, so every item is copied and hashed as a bounded stream. The request is
/// kept under Incoming until `publish()` atomically makes the complete
/// selection visible to the app.
final class AppGroupImportHandoffWriter: @unchecked Sendable {
  let id: UUID

  private let createdAt: Date
  private let incomingURL: URL
  private let publishedURL: URL
  private let itemsURL: URL
  private let fileManager: FileManager
  private var items: [ShareImportHandoffItem] = []
  private var isFinished = false

  init(
    containerURL: URL,
    id: UUID = UUID(),
    createdAt: Date = Date(),
    fileManager: FileManager = .default
  ) throws {
    self.id = id
    self.createdAt = createdAt
    self.fileManager = fileManager

    let root = containerURL.appending(
      path: PlayerAppGroup.importQueueDirectoryName,
      directoryHint: .isDirectory
    )
    let incomingRoot = root.appending(path: "Incoming", directoryHint: .isDirectory)
    let pendingRoot = root.appending(path: "Pending", directoryHint: .isDirectory)
    let processingRoot = root.appending(path: "Processing", directoryHint: .isDirectory)
    for directory in [root, incomingRoot, pendingRoot, processingRoot] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let requestName = id.uuidString.lowercased()
    incomingURL = incomingRoot.appending(path: requestName, directoryHint: .isDirectory)
    publishedURL = pendingRoot.appending(path: requestName, directoryHint: .isDirectory)
    itemsURL = incomingURL.appending(path: "Items", directoryHint: .isDirectory)
    guard
      !fileManager.fileExists(atPath: incomingURL.path),
      !fileManager.fileExists(atPath: publishedURL.path),
      !fileManager.fileExists(
        atPath: processingRoot.appending(path: requestName, directoryHint: .isDirectory).path
      )
    else { throw ShareImportHandoffError.fileOperation("This share request already exists.") }
    try fileManager.createDirectory(at: itemsURL, withIntermediateDirectories: true)
  }

  func appendCopying(
    _ sourceURL: URL,
    fileExtension: String,
    contentTypeIdentifier: String?,
    originalFilename: String
  ) throws {
    guard !isFinished else {
      throw ShareImportHandoffError.fileOperation("This share request is already complete.")
    }
    let normalizedExtension = fileExtension.lowercased()
    guard ["m4a", "m4b", "mp3", "zip"].contains(normalizedExtension) else {
      throw ShareImportHandoffError.fileOperation(
        "The shared item \(originalFilename) is not a supported audiobook file."
      )
    }

    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
    let sourceValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
    guard sourceValues.isRegularFile == true else {
      throw ShareImportHandoffError.fileOperation(
        "The shared item \(originalFilename) is not a regular file."
      )
    }

    let storedName = String(format: "%05d.%@", items.count, normalizedExtension)
    let destination = itemsURL.appending(path: storedName)
    let checksum = try copyAndHash(from: sourceURL, to: destination)
    let destinationValues = try destination.resourceValues(forKeys: [.fileSizeKey])
    guard let byteCount = destinationValues.fileSize else {
      throw ShareImportHandoffError.fileOperation(
        "The copied size of \(originalFilename) could not be verified."
      )
    }
    items.append(ShareImportHandoffItem(
      relativePath: "Items/\(storedName)",
      originalFilename: originalFilename,
      contentTypeIdentifier: contentTypeIdentifier,
      byteCount: Int64(byteCount),
      checksumSHA256: checksum
    ))
  }

  @discardableResult
  func publish() throws -> UUID {
    guard !isFinished else {
      throw ShareImportHandoffError.fileOperation("This share request is already complete.")
    }
    guard !items.isEmpty else { throw ShareImportHandoffError.emptySelection }
    let handoff = ShareImportHandoff(id: id, createdAt: createdAt, items: items)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(handoff).write(
      to: incomingURL.appending(path: "handoff.json"),
      options: [.atomic]
    )
    try fileManager.moveItem(at: incomingURL, to: publishedURL)
    isFinished = true
    return id
  }

  func cancel() {
    guard !isFinished else { return }
    try? fileManager.removeItem(at: incomingURL)
    isFinished = true
  }

  deinit {
    if !isFinished { try? fileManager.removeItem(at: incomingURL) }
  }

  private func copyAndHash(from source: URL, to destination: URL) throws -> String {
    guard fileManager.createFile(atPath: destination.path, contents: nil) else {
      throw ShareImportHandoffError.fileOperation(
        "Player could not create storage for \(source.lastPathComponent)."
      )
    }
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: destination)
    defer {
      try? input.close()
      try? output.close()
    }
    var hash = SHA256()
    while try autoreleasepool(invoking: {
      try Task.checkCancellation()
      guard let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty else {
        return false
      }
      hash.update(data: data)
      try output.write(contentsOf: data)
      return true
    }) {}
    try output.synchronize()
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// A small filesystem queue shared by the app and Share Extension. A request is
/// invisible until every source copy and its manifest are durable, then one
/// directory rename publishes it atomically.
actor AppGroupImportHandoffQueue {
  private let rootURL: URL
  private let incomingURL: URL
  private let pendingURL: URL
  private let processingURL: URL
  private let fileManager: FileManager
  /// A newly-created queue actor recovers Processing requests after a process
  /// crash. Within one process, this lease prevents concurrent drains from
  /// claiming the same request more than once before acknowledgement or retry.
  private var activeClaims: Set<UUID> = []

  init(containerURL: URL, fileManager: FileManager = .default) {
    rootURL = containerURL.appending(
      path: PlayerAppGroup.importQueueDirectoryName,
      directoryHint: .isDirectory
    )
    incomingURL = rootURL.appending(path: "Incoming", directoryHint: .isDirectory)
    pendingURL = rootURL.appending(path: "Pending", directoryHint: .isDirectory)
    processingURL = rootURL.appending(path: "Processing", directoryHint: .isDirectory)
    self.fileManager = fileManager
  }

  @discardableResult
  func enqueueCopying(
    _ sourceURLs: [URL],
    id: UUID = UUID(),
    createdAt: Date = Date(),
    contentTypeIdentifiers: [String?] = [],
    originalFilenames: [String?] = []
  ) throws -> UUID {
    guard !sourceURLs.isEmpty else { throw ShareImportHandoffError.emptySelection }
    try prepareDirectories()
    let requestName = id.uuidString.lowercased()
    let incoming = incomingURL.appending(path: requestName, directoryHint: .isDirectory)
    let published = pendingURL.appending(path: requestName, directoryHint: .isDirectory)
    guard
      !fileManager.fileExists(atPath: incoming.path),
      !fileManager.fileExists(atPath: published.path),
      !fileManager.fileExists(
        atPath: processingURL.appending(path: requestName, directoryHint: .isDirectory).path
      )
    else { throw ShareImportHandoffError.fileOperation("This share request already exists.") }

    let itemsDirectory = incoming.appending(path: "Items", directoryHint: .isDirectory)
    do {
      try fileManager.createDirectory(at: itemsDirectory, withIntermediateDirectories: true)
      var items: [ShareImportHandoffItem] = []
      for (index, sourceURL) in sourceURLs.enumerated() {
        try Task.checkCancellation()
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
          throw ShareImportHandoffError.fileOperation(
            "The shared item \(sourceURL.lastPathComponent) is not a regular file."
          )
        }
        let suffix = sourceURL.pathExtension.isEmpty
          ? "" : ".\(sourceURL.pathExtension.lowercased())"
        let storedName = String(format: "%05d", index) + suffix
        let destination = itemsDirectory.appending(path: storedName)
        let checksum = try copyAndHash(from: sourceURL, to: destination)
        let suppliedName = index < originalFilenames.count ? originalFilenames[index] : nil
        let safeDisplayName = suppliedName.flatMap {
          let name = URL(filePath: $0).lastPathComponent
          return name.isEmpty ? nil : name
        }
        items.append(ShareImportHandoffItem(
          relativePath: "Items/\(storedName)",
          originalFilename: safeDisplayName ?? sourceURL.lastPathComponent,
          contentTypeIdentifier: index < contentTypeIdentifiers.count
            ? contentTypeIdentifiers[index] : nil,
          byteCount: Int64(values.fileSize ?? 0),
          checksumSHA256: checksum
        ))
      }
      let handoff = ShareImportHandoff(id: id, createdAt: createdAt, items: items)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let manifestURL = incoming.appending(path: "handoff.json")
      try encoder.encode(handoff).write(to: manifestURL, options: [.atomic])
      try fileManager.moveItem(at: incoming, to: published)
      return id
    } catch {
      try? fileManager.removeItem(at: incoming)
      if let error = error as? ShareImportHandoffError { throw error }
      throw ShareImportHandoffError.fileOperation(error.localizedDescription)
    }
  }

  /// Returns an orphaned Processing request first, making a process crash after
  /// claim idempotently recoverable without a separate lease database.
  func claimNext() throws -> ClaimedShareImport? {
    try prepareDirectories()
    for processing in try requestDirectories(in: processingURL) {
      guard
        let directoryID = UUID(uuidString: processing.lastPathComponent),
        !activeClaims.contains(directoryID)
      else { continue }
      let claim = try loadClaim(at: processing)
      activeClaims.insert(claim.handoff.id)
      return claim
    }
    guard let pending = try requestDirectories(in: pendingURL).first else { return nil }
    let claimedURL = processingURL.appending(
      path: pending.lastPathComponent,
      directoryHint: .isDirectory
    )
    try fileManager.moveItem(at: pending, to: claimedURL)
    let claim = try loadClaim(at: claimedURL)
    activeClaims.insert(claim.handoff.id)
    return claim
  }

  func acknowledge(_ id: UUID) throws {
    let request = processingURL.appending(
      path: id.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    guard fileManager.fileExists(atPath: request.path) else {
      activeClaims.remove(id)
      return
    }
    try fileManager.removeItem(at: request)
    activeClaims.remove(id)
  }

  func returnForRetry(_ id: UUID) throws {
    try prepareDirectories()
    let requestName = id.uuidString.lowercased()
    let source = processingURL.appending(path: requestName, directoryHint: .isDirectory)
    guard fileManager.fileExists(atPath: source.path) else {
      activeClaims.remove(id)
      return
    }
    let destination = pendingURL.appending(path: requestName, directoryHint: .isDirectory)
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw ShareImportHandoffError.fileOperation("The share request is already pending.")
    }
    try fileManager.moveItem(at: source, to: destination)
    activeClaims.remove(id)
  }

  private func loadClaim(at requestURL: URL) throws -> ClaimedShareImport {
    let manifest = requestURL.appending(path: "handoff.json")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let handoff = try? decoder.decode(
      ShareImportHandoff.self,
      from: Data(contentsOf: manifest)
    ) else { throw ShareImportHandoffError.invalidPayload }
    guard handoff.schemaVersion == ShareImportHandoff.currentSchemaVersion else {
      throw ShareImportHandoffError.unsupportedSchema(handoff.schemaVersion)
    }
    guard requestURL.lastPathComponent == handoff.id.uuidString.lowercased() else {
      throw ShareImportHandoffError.invalidPayload
    }
    guard !handoff.items.isEmpty else { throw ShareImportHandoffError.emptySelection }
    let requiredPrefix = requestURL.standardizedFileURL.path + "/"
    var uniquePaths: Set<String> = []
    let fileURLs = try handoff.items.map { item -> URL in
      guard Self.isSafeRelativePath(item.relativePath) else {
        throw ShareImportHandoffError.unsafeRelativePath(item.relativePath)
      }
      guard uniquePaths.insert(item.relativePath).inserted else {
        throw ShareImportHandoffError.invalidPayload
      }
      let url = requestURL.appending(path: item.relativePath).standardizedFileURL
      guard url.path.hasPrefix(requiredPrefix), fileManager.fileExists(atPath: url.path) else {
        throw ShareImportHandoffError.missingItem(item.relativePath)
      }
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard
        values.isRegularFile == true,
        Int64(values.fileSize ?? -1) == item.byteCount,
        try hashFile(at: url) == item.checksumSHA256.lowercased()
      else { throw ShareImportHandoffError.invalidPayload }
      return url
    }
    return ClaimedShareImport(handoff: handoff, fileURLs: fileURLs)
  }

  private func prepareDirectories() throws {
    for url in [rootURL, incomingURL, pendingURL, processingURL] {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  private func requestDirectories(in directory: URL) throws -> [URL] {
    try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ).filter {
      (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".."
    }
  }

  private func copyAndHash(from source: URL, to destination: URL) throws -> String {
    fileManager.createFile(atPath: destination.path, contents: nil)
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: destination)
    defer {
      try? input.close()
      try? output.close()
    }
    var hash = SHA256()
    while try autoreleasepool(invoking: {
      try Task.checkCancellation()
      guard let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty else {
        return false
      }
      hash.update(data: data)
      try output.write(contentsOf: data)
      return true
    }) {}
    try output.synchronize()
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func hashFile(at url: URL) throws -> String {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var hash = SHA256()
    while try autoreleasepool(invoking: {
      try Task.checkCancellation()
      guard let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty else {
        return false
      }
      hash.update(data: data)
      return true
    }) {}
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
