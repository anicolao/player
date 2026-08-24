import Foundation
import OSLog

actor FileSystemMediaManager: MediaManaging {
  private static let supportedExtensions: Set<String> = ["m4a", "m4b", "mp3"]
  private static let storageSafetyMargin: Int64 = 16 * 1_024 * 1_024

  private let rootURL: URL
  private let stagingURL: URL
  private let mediaURL: URL
  private let trashURL: URL
  private let fileManager: FileManager
  private let logger = Logger(subsystem: "com.spnss.player", category: "MediaStorage")

  init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL.standardizedFileURL
    self.stagingURL = rootURL.appending(path: "Staging", directoryHint: .isDirectory)
    self.mediaURL = rootURL.appending(path: "Media", directoryHint: .isDirectory)
    self.trashURL = rootURL.appending(path: "Trash", directoryHint: .isDirectory)
    self.fileManager = fileManager
  }

  func stage(sourceURL: URL, jobID: UUID) throws -> StagedAudio {
    try stageFile(sourceURL: sourceURL, jobID: jobID, storageName: "source")
  }

  func stageArchive(sourceURL: URL, jobID: UUID) throws -> StagedAudio {
    try stageFile(
      sourceURL: sourceURL,
      jobID: jobID,
      storageName: "archive",
      allowedExtensions: ["zip"]
    )
  }

  func zipWorkspace(for jobID: UUID) throws -> ZipImportWorkspace {
    try prepareDirectories()
    let jobDirectory = stagingURL.appending(
      path: jobID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    let destination = jobDirectory.appending(path: "Extracted", directoryHint: .isDirectory)
    let checkpoint = jobDirectory.appending(path: "zip-checkpoint.json")
    return ZipImportWorkspace(
      destinationRoot: destination,
      checkpointURL: checkpoint,
      extractionRelativePath: relativePath(for: destination),
      checkpointRelativePath: relativePath(for: checkpoint)
    )
  }

  func acquireExtractedAudio(
    _ files: [ZipExtractedFile],
    in workspace: ZipImportWorkspace,
    jobID: UUID
  ) throws -> [AcquiredAudioFile] {
    let expectedRoot = workspace.destinationRoot.standardizedFileURL.path + "/"
    return try files.map { file in
      let url = file.fileURL.standardizedFileURL
      guard url.path.hasPrefix(expectedRoot), fileManager.fileExists(atPath: url.path) else {
        throw PlayerCoreError.fileOperation("Extracted audio escaped its ZIP workspace.")
      }
      let pathComponents = file.relativePath.split(separator: "/").map(String.init)
      return AcquiredAudioFile(
        staged: StagedAudio(
          relativePath: relativePath(for: url),
          originalFilename: url.lastPathComponent,
          checksumSHA256: try hashFile(at: url),
          byteCount: Int64(file.byteCount)
        ),
        sourceRelativePath: file.relativePath,
        commonFolderName: pathComponents.count > 1 ? pathComponents[0] : nil
      )
    }
  }

  func acquireSelection(_ selectedURLs: [URL], jobID: UUID) throws -> [AcquiredAudioFile] {
    var securityScopedURLs: [URL] = []
    for url in selectedURLs where url.startAccessingSecurityScopedResource() {
      securityScopedURLs.append(url)
    }
    defer { securityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

    var candidates: [(url: URL, sourceRelativePath: String, commonFolderName: String?)] = []
    for selectedURL in selectedURLs {
      let values = try selectedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
      if values.isDirectory == true {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
          at: selectedURL,
          includingPropertiesForKeys: Array(keys),
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { continue }
        var children: [(url: URL, relativePath: String)] = []
        for case let child as URL in enumerator {
          let childValues = try child.resourceValues(forKeys: keys)
          guard
            childValues.isRegularFile == true,
            Self.supportedExtensions.contains(child.pathExtension.lowercased())
          else { continue }
          let relative = String(child.path.dropFirst(selectedURL.path.count + 1))
          children.append((child, relative))
        }
        children.sort {
          let lhsHasNumber = URL(filePath: $0.relativePath)
            .deletingPathExtension().lastPathComponent.contains { $0.isNumber }
          let rhsHasNumber = URL(filePath: $1.relativePath)
            .deletingPathExtension().lastPathComponent.contains { $0.isNumber }
          if lhsHasNumber != rhsHasNumber { return lhsHasNumber }
          return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        for child in children {
          let relativeComponents = child.relativePath.split(separator: "/").map(String.init)
          let groupingFolder = relativeComponents.count > 1
            ? relativeComponents[0]
            : selectedURL.lastPathComponent
          candidates.append((child.url, child.relativePath, groupingFolder))
        }
      } else if values.isRegularFile == true {
        candidates.append((selectedURL, selectedURL.lastPathComponent, nil))
      }
    }
    guard !candidates.isEmpty else {
      throw PlayerCoreError.fileOperation("The selection contains no readable files.")
    }

    var requiredBytes: Int64 = 0
    for candidate in candidates {
      let fileSize = Int64(try candidate.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
      let (sum, overflow) = requiredBytes.addingReportingOverflow(max(0, fileSize))
      requiredBytes = overflow ? .max : sum
    }
    try prepareDirectories()
    let adoptsReceiverFiles = candidates.allSatisfy { isComputerReceiverSource($0.url) }
    try preflight(requiredBytes: adoptsReceiverFiles ? 0 : requiredBytes)

    return try candidates.enumerated().map { index, candidate in
      let selectedExtension = candidate.url.pathExtension.lowercased()
      return AcquiredAudioFile(
        staged: try stageFile(
          sourceURL: candidate.url,
          jobID: jobID,
          storageName: String(format: "item-%05d", index),
          allowedExtensions: [selectedExtension],
          performsStoragePreflight: false
        ),
        sourceRelativePath: candidate.sourceRelativePath,
        commonFolderName: candidate.commonFolderName
      )
    }
  }

  private func stageFile(
    sourceURL: URL,
    jobID: UUID,
    storageName: String,
    allowedExtensions: Set<String> = supportedExtensions,
    performsStoragePreflight: Bool = true
  ) throws -> StagedAudio {
    let filename = sourceURL.lastPathComponent
    let fileExtension = sourceURL.pathExtension.lowercased()
    guard allowedExtensions.contains(fileExtension) else {
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
    let adoptsReceiverFile = isComputerReceiverSource(sourceURL)
    if performsStoragePreflight { try preflight(requiredBytes: adoptsReceiverFile ? 0 : byteCount) }

    let jobDirectory = stagingURL.appending(
      path: jobID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    let stagedURL = jobDirectory.appending(path: "\(storageName).\(fileExtension)")
    guard !fileManager.fileExists(atPath: stagedURL.path) else {
      throw PlayerCoreError.fileOperation("A staged copy already exists for \(filename).")
    }

    if adoptsReceiverFile {
      do {
        try fileManager.linkItem(at: sourceURL, to: stagedURL)
        let checksum = try hashFile(at: stagedURL)
        logger.info("Adopted receiver file without a second physical copy")
        return StagedAudio(
          relativePath: relativePath(for: stagedURL),
          originalFilename: filename,
          checksumSHA256: checksum,
          byteCount: byteCount
        )
      } catch is CancellationError {
        try? fileManager.removeItem(at: stagedURL)
        throw CancellationError()
      } catch {
        try? fileManager.removeItem(at: stagedURL)
        logger.warning("Could not hard-link a receiver file; falling back to a durable copy")
        try preflight(requiredBytes: byteCount)
      }
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

  func moveManagedMediaToTrash(
    bookID: UUID,
    transactionID: UUID
  ) throws -> TrashedMediaManifest {
    try prepareDirectories()
    let bookComponent = bookID.uuidString.lowercased()
    let transactionComponent = transactionID.uuidString.lowercased()
    let source = mediaURL.appending(path: bookComponent, directoryHint: .isDirectory)
    guard fileManager.fileExists(atPath: source.path) else {
      throw PlayerCoreError.missingManagedFile("Media/\(bookComponent)")
    }
    let transactionDirectory = trashURL.appending(
      path: transactionComponent,
      directoryHint: .isDirectory
    )
    guard !fileManager.fileExists(atPath: transactionDirectory.path) else {
      throw PlayerCoreError.fileOperation("A trash transaction already exists.")
    }
    let destination = transactionDirectory.appending(
      path: "Media/\(bookComponent)",
      directoryHint: .isDirectory
    )
    let manifest = TrashedMediaManifest(
      transactionID: transactionID,
      bookID: bookID,
      originalDirectoryRelativePath: "Media/\(bookComponent)",
      trashDirectoryRelativePath: "Trash/\(transactionComponent)/Media/\(bookComponent)",
      byteCount: try directoryByteCount(source)
    )
    do {
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(manifest).write(
        to: transactionDirectory.appending(path: "manifest.json"),
        options: [.atomic, .completeFileProtectionUnlessOpen]
      )
      try fileManager.moveItem(at: source, to: destination)
      return manifest
    } catch {
      if fileManager.fileExists(atPath: source.path) {
        try? fileManager.removeItem(at: transactionDirectory)
      }
      throw error
    }
  }

  func restoreManagedMediaFromTrash(_ manifest: TrashedMediaManifest) throws {
    try prepareDirectories()
    let source = try confinedURL(
      for: manifest.trashDirectoryRelativePath,
      beneath: trashURL
    )
    let destination = try confinedURL(
      for: manifest.originalDirectoryRelativePath,
      beneath: mediaURL
    )
    guard fileManager.fileExists(atPath: source.path) else {
      throw PlayerCoreError.missingManagedFile(manifest.trashDirectoryRelativePath)
    }
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw PlayerCoreError.fileOperation("Managed media already exists for this book.")
    }
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.moveItem(at: source, to: destination)
    let transactionDirectory = trashURL.appending(
      path: manifest.transactionID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try? fileManager.removeItem(at: transactionDirectory)
  }

  func discardStaging(for jobID: UUID) async {
    let directory = stagingURL.appending(
      path: jobID.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try? fileManager.removeItem(at: directory)
  }

  func discardStagedFile(relativePath: String) async throws {
    let file = try confinedURL(for: relativePath, beneath: stagingURL)
    guard fileManager.fileExists(atPath: file.path) else {
      throw PlayerCoreError.missingManagedFile(relativePath)
    }
    try fileManager.removeItem(at: file)
  }

  func discardStorage(scope: StorageScope) async throws {
    let target: URL
    switch scope {
    case .stagingJob(let jobID):
      target = stagingURL.appending(
        path: jobID.uuidString.lowercased(),
        directoryHint: .isDirectory
      )
    case .trashTransaction(let transactionID):
      target = trashURL.appending(
        path: transactionID.uuidString.lowercased(),
        directoryHint: .isDirectory
      )
    case .managedBook, .database:
      throw PlayerCoreError.fileOperation(
        "Only recoverable staging or trash storage can be cleared without removing a library record."
      )
    }
    if fileManager.fileExists(atPath: target.path) {
      try fileManager.removeItem(at: target)
    }
  }

  func storageInventory() async throws -> StorageInventorySnapshot {
    try prepareDirectories()
    var inventoryManifests: [StorageManifest] = []
    inventoryManifests += try manifests(in: mediaURL) { .managedBook($0) }
    inventoryManifests += try manifests(in: stagingURL) { .stagingJob($0) }
    inventoryManifests += try manifests(in: trashURL) { .trashTransaction($0) }
    let databaseURL = rootURL.appending(path: "Library.json")
    if fileManager.fileExists(atPath: databaseURL.path) {
      let values = try databaseURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if values.isRegularFile == true {
        inventoryManifests.append(try StorageManifest(
          id: UUID(uuidString: "ffffffff-ffff-5fff-8fff-fffffffffff0")!,
          scope: .database,
          entries: [StorageManifestEntry(
            relativePath: "Library.json",
            byteCount: Int64(values.fileSize ?? 0)
          )],
          createdAt: .distantPast
        ))
      }
    }
    let capacity = try rootURL.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    ).volumeAvailableCapacityForImportantUsage
    return StorageInventorySnapshot(
      manifests: inventoryManifests,
      availableBytes: capacity.map { Int64($0) }
    )
  }

  func reconcileStartupStorage(with library: LibrarySnapshot) async throws
    -> StartupStorageReconciliation
  {
    try prepareDirectories()
    let knownBooks = Set(library.books.map(\.id))
    let knownJobs = Set(library.importJobs.map(\.id))
    let knownTrash = Set(
      library.trashTransactions.filter { $0.status == .recoverable }.map(\.id)
    )
    let managed = try quarantineUnknownDirectories(
      in: mediaURL,
      category: "managed",
      expected: knownBooks
    )
    let staging = try quarantineUnknownDirectories(
      in: stagingURL,
      category: "staging",
      expected: knownJobs
    )
    let trash = try quarantineUnknownDirectories(
      in: trashURL,
      category: "trash",
      expected: knownTrash
    )
    let inventory = try await storageInventory()
    var reconciled = library
    reconciled.storageManifests = inventory.manifests
    return StartupStorageReconciliation(
      library: reconciled,
      quarantinedManagedBookCount: managed,
      quarantinedStagingJobCount: staging,
      quarantinedTrashTransactionCount: trash
    )
  }

  private func quarantineUnknownDirectories(
    in categoryDirectory: URL,
    category: String,
    expected: Set<UUID>
  ) throws -> Int {
    let children = try fileManager.contentsOfDirectory(
      at: categoryDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    let quarantine = rootURL.appending(
      path: "Recovery/Orphans",
      directoryHint: .isDirectory
    )
    var count = 0
    for child in children {
      let values = try child.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true,
        let identifier = UUID(uuidString: child.lastPathComponent),
        !expected.contains(identifier)
      else { continue }
      try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
      var destination = quarantine.appending(
        path: "\(category)-\(identifier.uuidString.lowercased())",
        directoryHint: .isDirectory
      )
      if fileManager.fileExists(atPath: destination.path) {
        destination = quarantine.appending(
          path: "\(category)-\(identifier.uuidString.lowercased())-"
            + UUID().uuidString.lowercased(),
          directoryHint: .isDirectory
        )
      }
      try fileManager.moveItem(at: child, to: destination)
      count += 1
    }
    return count
  }

  private func prepareDirectories() throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: mediaURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: trashURL, withIntermediateDirectories: true)
  }

  private func directoryByteCount(_ directory: URL) throws -> Int64 {
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
    }
    return total
  }

  private func manifests(
    in categoryDirectory: URL,
    scope: (UUID) -> StorageScope
  ) throws -> [StorageManifest] {
    let children = try fileManager.contentsOfDirectory(
      at: categoryDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try children.compactMap { child in
      let values = try child.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true,
        let identifier = UUID(uuidString: child.lastPathComponent)
      else { return nil }
      return try StorageManifest(
        id: identifier,
        scope: scope(identifier),
        entries: storageEntries(in: child),
        createdAt: .distantPast
      )
    }
  }

  private func storageEntries(in directory: URL) throws -> [StorageManifestEntry] {
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }
    var entries: [StorageManifestEntry] = []
    for case let file as URL in enumerator {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true else { continue }
      entries.append(StorageManifestEntry(
        relativePath: relativePath(for: file),
        byteCount: Int64(values.fileSize ?? 0)
      ))
    }
    return entries.sorted { $0.relativePath < $1.relativePath }
  }

  private func preflight(requiredBytes: Int64) throws {
    let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let capacity = values.volumeAvailableCapacityForImportantUsage else { return }
    let available = Int64(capacity)
    let (requiredWithMargin, overflow) = max(0, requiredBytes).addingReportingOverflow(
      Self.storageSafetyMargin
    )
    let required = overflow ? Int64.max : requiredWithMargin
    guard available >= required else {
      throw PlayerCoreError.insufficientStorage(required: required, available: available)
    }
  }

  private func copyAndHash(from source: URL, to destination: URL) throws -> String {
    try StreamingFileIO.copyAndHash(from: source, to: destination).checksumSHA256
  }

  private func hashFile(at url: URL) throws -> String {
    try StreamingFileIO.hashFile(at: url).checksumSHA256
  }

  private func isComputerReceiverSource(_ sourceURL: URL) -> Bool {
    let receiverRoot = rootURL
      .appending(path: "ComputerReceiver", directoryHint: .isDirectory)
      .standardizedFileURL.path + "/"
    return sourceURL.standardizedFileURL.path.hasPrefix(receiverRoot)
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
