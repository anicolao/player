import CryptoKit
import Foundation

actor FileSystemMediaManager: MediaManaging {
  private static let supportedExtensions: Set<String> = ["m4a", "m4b", "mp3"]
  private static let storageSafetyMargin: Int64 = 16 * 1_024 * 1_024

  private let rootURL: URL
  private let stagingURL: URL
  private let mediaURL: URL
  private let fileManager: FileManager

  init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL.standardizedFileURL
    self.stagingURL = rootURL.appending(path: "Staging", directoryHint: .isDirectory)
    self.mediaURL = rootURL.appending(path: "Media", directoryHint: .isDirectory)
    self.fileManager = fileManager
  }

  func stage(sourceURL: URL, jobID: UUID) throws -> StagedAudio {
    let filename = sourceURL.lastPathComponent
    let fileExtension = sourceURL.pathExtension.lowercased()
    guard Self.supportedExtensions.contains(fileExtension) else {
      throw PlayerCoreError.unsupportedFile(filename)
    }

    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if accessed { sourceURL.stopAccessingSecurityScopedResource() }
    }

    let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else {
      throw PlayerCoreError.sourceIsNotAFile(filename)
    }

    let byteCount = Int64(values.fileSize ?? 0)
    try prepareDirectories()
    try preflight(requiredBytes: byteCount)

    let jobDirectory = stagingURL.appending(
      path: jobID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    let stagedURL = jobDirectory.appending(path: "source.\(fileExtension)")
    guard !fileManager.fileExists(atPath: stagedURL.path) else {
      throw PlayerCoreError.fileOperation("A staged copy already exists for \(filename).")
    }

    fileManager.createFile(atPath: stagedURL.path, contents: nil)
    do {
      let checksum = try copyAndHash(from: sourceURL, to: stagedURL)
      let relativePath = relativePath(for: stagedURL)
      return StagedAudio(
        relativePath: relativePath,
        originalFilename: filename,
        checksumSHA256: checksum,
        byteCount: byteCount
      )
    } catch {
      try? fileManager.removeItem(at: stagedURL)
      throw error
    }
  }

  func stagedURL(for relativePath: String) throws -> URL {
    try confinedURL(for: relativePath, beneath: stagingURL)
  }

  func commit(
    _ staged: StagedAudio,
    bookID: UUID,
    assetID: UUID
  ) throws -> ManagedAudio {
    let source = try stagedURL(for: staged.relativePath)
    guard fileManager.fileExists(atPath: source.path) else {
      throw PlayerCoreError.missingManagedFile(staged.relativePath)
    }

    let bookDirectory = mediaURL.appending(
      path: bookID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
    let fileExtension = source.pathExtension.lowercased()
    let destination = bookDirectory.appending(
      path: "\(assetID.uuidString.lowercased()).\(fileExtension)"
    )
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw PlayerCoreError.fileOperation("The managed audio destination already exists.")
    }

    // Staging and Media share a volume. rename(2), used by FileManager here, makes the
    // fully copied file visible at its destination in one atomic filesystem operation.
    try fileManager.moveItem(at: source, to: destination)
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o444))],
      ofItemAtPath: destination.path
    )
    return ManagedAudio(
      relativePath: relativePath(for: destination),
      stagedRelativePath: staged.relativePath
    )
  }

  func rollback(_ managed: ManagedAudio) throws {
    let source = try managedURL(for: managed.relativePath)
    let destination = try confinedURL(for: managed.stagedRelativePath, beneath: stagingURL)
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o644))],
      ofItemAtPath: source.path
    )
    try fileManager.moveItem(at: source, to: destination)
  }

  func managedURL(for relativePath: String) throws -> URL {
    let url = try confinedURL(for: relativePath, beneath: mediaURL)
    guard fileManager.fileExists(atPath: url.path) else {
      throw PlayerCoreError.missingManagedFile(relativePath)
    }
    return url
  }

  func discardStaging(for jobID: UUID) {
    let directory = stagingURL.appending(
      path: jobID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try? fileManager.removeItem(at: directory)
  }

  private func prepareDirectories() throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: mediaURL, withIntermediateDirectories: true)
  }

  private func preflight(requiredBytes: Int64) throws {
    let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let capacity = values.volumeAvailableCapacityForImportantUsage else { return }
    let available = Int64(capacity)
    let required = requiredBytes + Self.storageSafetyMargin
    guard available >= required else {
      throw PlayerCoreError.insufficientStorage(required: required, available: available)
    }
  }

  private func copyAndHash(from source: URL, to destination: URL) throws -> String {
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: destination)
    defer {
      try? input.close()
      try? output.close()
    }

    var hash = SHA256()
    while true {
      try Task.checkCancellation()
      guard let chunk = try input.read(upToCount: 1_024 * 1_024), !chunk.isEmpty else {
        break
      }
      hash.update(data: chunk)
      try output.write(contentsOf: chunk)
    }
    try output.synchronize()
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func relativePath(for url: URL) -> String {
    String(url.standardizedFileURL.path.dropFirst(rootURL.path.count + 1))
  }

  private func confinedURL(for relativePath: String, beneath directory: URL) throws -> URL {
    let candidate = rootURL.appending(path: relativePath).standardizedFileURL
    let requiredPrefix = directory.standardizedFileURL.path + "/"
    guard candidate.path.hasPrefix(requiredPrefix) else {
      throw PlayerCoreError.fileOperation("A managed path escaped its storage directory.")
    }
    return candidate
  }
}
