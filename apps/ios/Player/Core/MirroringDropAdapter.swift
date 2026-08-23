import Foundation
import UniformTypeIdentifiers
import UIKit

struct MirroringDropProgress: Sendable, Equatable {
  var currentName: String
  var completedItems: Int
  var totalItems: Int
}

struct MirroringDropMaterialization: Sendable, Equatable {
  var selectionURLs: [URL]
  var sessionRoot: URL
  var displayName: String
}

enum MirroringDropError: LocalizedError, Equatable {
  case noSupportedItems
  case providerUnavailable(String)
  case folderUnavailable
  case unsafeFolderEntry(String)
  case tooManyFiles
  case duplicatePath(String)
  case mixedArchiveSelection
  case insufficientStorage(required: Int64, available: Int64)

  var errorDescription: String? {
    switch self {
    case .noSupportedItems:
      "That drop did not contain an M4B, M4A, MP3, ZIP, or readable audiobook folder."
    case .providerUnavailable(let name):
      "This Mac could not provide \(name). Zip the folder or use the web uploader shown on this screen."
    case .folderUnavailable:
      "This Mac could not provide the folder contents. Zip the folder or use the web uploader shown on this screen."
    case .unsafeFolderEntry(let name):
      "The dropped folder contains an unsafe link at \(name). Remove it or use a ZIP archive."
    case .tooManyFiles:
      "That folder contains too many files to import at once."
    case .duplicatePath(let name):
      "Two dropped files would have the same path on this iPhone: \(name)."
    case .mixedArchiveSelection:
      "Drop one ZIP archive at a time, without additional files or folders."
    case .insufficientStorage(let required, let available):
      "This iPhone needs \(Self.bytes(required)) free to receive that drop, but only \(Self.bytes(available)) is available."
    }
  }

  private static func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }
}

final class MirroringDropAdapter: @unchecked Sendable {
  static let maximumEntries = 20_000
  private static let storageSafetyMargin: Int64 = 16 * 1_024 * 1_024
  private static let supportedExtensions: Set<String> = ["m4a", "m4b", "mp3", "zip"]
  private static let supportedAudioExtensions: Set<String> = ["m4a", "m4b", "mp3"]
  private static let explicitTypeIdentifiers = [
    "com.apple.protected-mpeg-4-audio-b",
    "com.apple.m4a-audio",
    "public.mp3",
    "public.zip-archive",
  ]

  static let acceptedTypeIdentifiers: [String] = {
    var identifiers = explicitTypeIdentifiers + [
      UTType.folder.identifier,
      UTType.directory.identifier,
      UTType.fileURL.identifier,
      UTType.data.identifier,
      UTType.item.identifier,
    ]
    for fileExtension in supportedExtensions {
      if let identifier = UTType(filenameExtension: fileExtension)?.identifier {
        identifiers.append(identifier)
      }
    }
    return Array(Set(identifiers)).sorted()
  }()

  private let rootURL: URL
  private let fileManager: FileManager

  init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
  }

  @MainActor
  func materialize(
    _ itemProviders: [NSItemProvider],
    progress: @escaping @MainActor @Sendable (MirroringDropProgress) -> Void = { _ in }
  ) async throws -> MirroringDropMaterialization {
    try await materialize(itemProviders.map(MirroringItemProvider.init), progress: progress)
  }

  @MainActor
  func materialize(
    _ providers: [MirroringItemProvider],
    progress: @escaping @MainActor @Sendable (MirroringDropProgress) -> Void = { _ in }
  ) async throws -> MirroringDropMaterialization {
    guard !providers.isEmpty else { throw MirroringDropError.noSupportedItems }

    let sessionRoot = rootURL.appending(
      path: "Mirroring-\(UUID().uuidString.lowercased())",
      directoryHint: .isDirectory
    )
    let payloadRoot = sessionRoot.appending(path: "Payload", directoryHint: .isDirectory)
    do {
      try fileManager.createDirectory(at: payloadRoot, withIntermediateDirectories: true)
      var selectionURLs: [URL] = []
      for (index, provider) in providers.enumerated() {
        try Task.checkCancellation()
        let displayName = nonBlank(provider.suggestedName) ?? "Dropped item \(index + 1)"
        progress(MirroringDropProgress(
          currentName: displayName,
          completedItems: index,
          totalItems: providers.count
        ))
        let url = try await materialize(
          provider,
          index: index,
          payloadRoot: payloadRoot
        )
        selectionURLs.append(url)
        progress(MirroringDropProgress(
          currentName: displayName,
          completedItems: index + 1,
          totalItems: providers.count
        ))
      }

      guard !selectionURLs.isEmpty else { throw MirroringDropError.noSupportedItems }
      let archiveCount = selectionURLs.filter { $0.pathExtension.lowercased() == "zip" }.count
      guard archiveCount == 0 || (archiveCount == 1 && selectionURLs.count == 1) else {
        throw MirroringDropError.mixedArchiveSelection
      }
      let displayName = selectionURLs.count == 1
        ? selectionURLs[0].deletingPathExtension().lastPathComponent
        : "\(selectionURLs.count) dropped items"
      return MirroringDropMaterialization(
        selectionURLs: selectionURLs,
        sessionRoot: sessionRoot,
        displayName: displayName
      )
    } catch {
      try? fileManager.removeItem(at: sessionRoot)
      throw error
    }
  }

  func cleanup(_ materialization: MirroringDropMaterialization) {
    try? fileManager.removeItem(at: materialization.sessionRoot)
  }

  private func materialize(
    _ provider: MirroringItemProvider,
    index: Int,
    payloadRoot: URL
  ) async throws -> URL {
    let typeIdentifiers = preferredTypeIdentifiers(for: provider)
    guard provider.canLoadURLObject || !typeIdentifiers.isEmpty else {
      throw MirroringDropError.noSupportedItems
    }

    var lastMaterializationError: MirroringDropError?
    if provider.canLoadURLObject {
      do {
        return try await loadURLObject(
          provider: provider,
          typeIdentifier: typeIdentifiers.first ?? UTType.fileURL.identifier,
          suggestedName: provider.suggestedName,
          index: index,
          payloadRoot: payloadRoot
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as MirroringDropError {
        if shouldStopTryingRepresentations(after: error) { throw error }
        lastMaterializationError = error
      } catch {}
    }

    for typeIdentifier in typeIdentifiers {
      for inPlace in [true, false] {
        do {
          return try await loadRepresentation(
            provider: provider,
            typeIdentifier: typeIdentifier,
            suggestedName: provider.suggestedName,
            index: index,
            payloadRoot: payloadRoot,
            inPlace: inPlace
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as MirroringDropError {
          if shouldStopTryingRepresentations(after: error) { throw error }
          lastMaterializationError = error
        } catch {}
      }
    }

    if let lastMaterializationError { throw lastMaterializationError }
    if typeIdentifiers.contains(where: typeConformsToFolder) {
      throw MirroringDropError.folderUnavailable
    }
    throw MirroringDropError.providerUnavailable(
      nonBlank(provider.suggestedName) ?? "that dropped item"
    )
  }

  private func shouldStopTryingRepresentations(after error: MirroringDropError) -> Bool {
    switch error {
    case .unsafeFolderEntry, .tooManyFiles, .duplicatePath, .mixedArchiveSelection,
      .insufficientStorage:
      true
    case .noSupportedItems, .providerUnavailable, .folderUnavailable:
      false
    }
  }

  private func loadURLObject(
    provider: MirroringItemProvider,
    typeIdentifier: String,
    suggestedName: String?,
    index: Int,
    payloadRoot: URL
  ) async throws -> URL {
    let state = ProviderRepresentationState()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<URL, any Error>) in
        state.install(continuation)
        let providerProgress = provider.loadURLObject { [self, state] sourceURL, error in
          do {
            try state.checkCancellation()
            if let error { throw error }
            guard let sourceURL else { throw ProviderRepresentationError.unavailable }
            let result = try materializeRepresentation(
              sourceURL: sourceURL,
              typeIdentifier: typeIdentifier,
              suggestedName: suggestedName,
              index: index,
              payloadRoot: payloadRoot,
              state: state
            )
            state.complete(.success(result))
          } catch {
            state.complete(.failure(error))
          }
        }
        state.setProgress(providerProgress)
      }
    } onCancel: {
      state.cancel()
    }
  }

  private func loadRepresentation(
    provider: MirroringItemProvider,
    typeIdentifier: String,
    suggestedName: String?,
    index: Int,
    payloadRoot: URL,
    inPlace: Bool
  ) async throws -> URL {
    let state = ProviderRepresentationState()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<URL, any Error>) in
        state.install(continuation)
        let completion: @Sendable (URL?, Error?) -> Void = { [self, state] sourceURL, error in
          do {
            try state.checkCancellation()
            if let error { throw error }
            guard let sourceURL else { throw ProviderRepresentationError.unavailable }
            let result = try materializeRepresentation(
              sourceURL: sourceURL,
              typeIdentifier: typeIdentifier,
              suggestedName: suggestedName,
              index: index,
              payloadRoot: payloadRoot,
              state: state
            )
            state.complete(.success(result))
          } catch {
            state.complete(.failure(error))
          }
        }
        let providerProgress: Progress
        if inPlace {
          providerProgress = provider.loadInPlace(typeIdentifier) { url, _, error in
            completion(url, error)
          }
        } else {
          providerProgress = provider.loadFile(typeIdentifier, completion)
        }
        state.setProgress(providerProgress)
      }
    } onCancel: {
      state.cancel()
    }
  }

  private func materializeRepresentation(
    sourceURL: URL,
    typeIdentifier: String,
    suggestedName: String?,
    index: Int,
    payloadRoot: URL,
    state: ProviderRepresentationState
  ) throws -> URL {
    try state.checkCancellation()
    let accessed = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if accessed { sourceURL.stopAccessingSecurityScopedResource() }
    }
    let values = try sourceURL.resourceValues(
      forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    guard values.isSymbolicLink != true else {
      throw MirroringDropError.unsafeFolderEntry(sourceURL.lastPathComponent)
    }
    if values.isDirectory == true {
      return try materializeDirectory(
        sourceURL,
        suggestedName: suggestedName,
        payloadRoot: payloadRoot,
        state: state
      )
    }
    guard values.isRegularFile == true else { throw ProviderRepresentationError.unavailable }
    return try materializeFile(
      sourceURL,
      typeIdentifier: typeIdentifier,
      suggestedName: suggestedName,
      fallbackIndex: index,
      payloadRoot: payloadRoot,
      state: state
    )
  }

  private func materializeDirectory(
    _ sourceURL: URL,
    suggestedName: String?,
    payloadRoot: URL,
    state: ProviderRepresentationState
  ) throws -> URL {
    let directoryName = sanitizedComponent(
      nonBlank(suggestedName) ?? sourceURL.lastPathComponent,
      fallback: "Dropped Audiobook"
    )
    let destinationRoot = uniqueDestination(
      in: payloadRoot,
      filename: directoryName,
      isDirectory: true
    )
    try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ]
    guard let enumerator = fileManager.enumerator(
      at: sourceURL,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { throw MirroringDropError.folderUnavailable }

    var copiedCount = 0
    var canonicalPaths = Set<String>()
    for case let child as URL in enumerator {
      try state.checkCancellation()
      let values = try child.resourceValues(forKeys: keys)
      let relativePath = String(child.path.dropFirst(sourceURL.path.count + 1))
      guard !relativePath.isEmpty else { continue }
      if values.isSymbolicLink == true {
        throw MirroringDropError.unsafeFolderEntry(relativePath)
      }
      if values.isDirectory == true { continue }
      guard values.isRegularFile == true else { continue }
      let fileExtension = child.pathExtension.lowercased()
      guard Self.supportedAudioExtensions.contains(fileExtension) else { continue }
      copiedCount += 1
      guard copiedCount <= Self.maximumEntries else { throw MirroringDropError.tooManyFiles }
      let canonical = relativePath
        .precomposedStringWithCanonicalMapping
        .folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: Locale(identifier: "en_US_POSIX")
        )
      guard canonicalPaths.insert(canonical).inserted else {
        throw MirroringDropError.duplicatePath(relativePath)
      }
      let destination = destinationRoot.appending(path: relativePath)
      guard destination.standardizedFileURL.path.hasPrefix(
        destinationRoot.standardizedFileURL.path + "/"
      ) else { throw MirroringDropError.unsafeFolderEntry(relativePath) }
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try adoptOrCopy(child, to: destination, state: state)
    }
    guard copiedCount > 0 else {
      try? fileManager.removeItem(at: destinationRoot)
      throw MirroringDropError.noSupportedItems
    }
    return destinationRoot
  }

  private func materializeFile(
    _ sourceURL: URL,
    typeIdentifier: String,
    suggestedName: String?,
    fallbackIndex: Int,
    payloadRoot: URL,
    state: ProviderRepresentationState
  ) throws -> URL {
    let suggestedExtension = suggestedName.map { URL(filePath: $0).pathExtension } ?? ""
    guard let fileExtension = [
      suggestedExtension,
      sourceURL.pathExtension,
      UTType(typeIdentifier)?.preferredFilenameExtension ?? "",
    ]
      .map({ $0.lowercased() })
      .first(where: { Self.supportedExtensions.contains($0) })
    else { throw MirroringDropError.noSupportedItems }

    var filename = sanitizedComponent(
      nonBlank(suggestedName) ?? sourceURL.lastPathComponent,
      fallback: String(format: "Dropped audiobook %02d.%@", fallbackIndex + 1, fileExtension)
    )
    if URL(filePath: filename).pathExtension.isEmpty { filename += ".\(fileExtension)" }
    let destination = uniqueDestination(in: payloadRoot, filename: filename, isDirectory: false)
    try adoptOrCopy(sourceURL, to: destination, state: state)
    return destination
  }

  private func adoptOrCopy(
    _ sourceURL: URL,
    to destinationURL: URL,
    state: ProviderRepresentationState
  ) throws {
    do {
      try fileManager.linkItem(at: sourceURL, to: destinationURL)
      return
    } catch {
      try? fileManager.removeItem(at: destinationURL)
    }

    let size = Int64(try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    try preflight(requiredBytes: size, destinationRoot: destinationURL.deletingLastPathComponent())
    fileManager.createFile(atPath: destinationURL.path, contents: nil)
    do {
      let input = try FileHandle(forReadingFrom: sourceURL)
      let output = try FileHandle(forWritingTo: destinationURL)
      defer {
        try? input.close()
        try? output.close()
      }
      while try autoreleasepool(invoking: {
        try state.checkCancellation()
        guard let chunk = try input.read(upToCount: 1_024 * 1_024), !chunk.isEmpty else {
          return false
        }
        try output.write(contentsOf: chunk)
        return true
      }) {}
      try output.synchronize()
    } catch {
      try? fileManager.removeItem(at: destinationURL)
      throw error
    }
  }

  private func preflight(requiredBytes: Int64, destinationRoot: URL) throws {
    let values = try destinationRoot.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    )
    guard let capacity = values.volumeAvailableCapacityForImportantUsage else { return }
    let available = Int64(capacity)
    let addition = max(0, requiredBytes).addingReportingOverflow(Self.storageSafetyMargin)
    let required = addition.overflow ? Int64.max : addition.partialValue
    guard available >= required else {
      throw MirroringDropError.insufficientStorage(required: required, available: available)
    }
  }

  private func preferredTypeIdentifiers(for provider: MirroringItemProvider) -> [String] {
    let identifiers = provider.registeredTypeIdentifiers
    var preferred: [String] = []
    func append(_ identifier: String) {
      guard !preferred.contains(identifier) else { return }
      preferred.append(identifier)
    }
    identifiers.filter(typeConformsToFolder).forEach(append)
    identifiers.filter { identifier in
      guard let candidate = UTType(identifier) else { return false }
      return Self.explicitTypeIdentifiers.contains { supportedIdentifier in
        guard let supportedType = UTType(supportedIdentifier) else { return false }
        return candidate.conforms(to: supportedType)
      }
    }.forEach(append)
    if let name = provider.suggestedName,
      Self.supportedExtensions.contains(URL(filePath: name).pathExtension.lowercased())
    {
      identifiers.forEach(append)
    }
    identifiers.filter { identifier in
      guard let candidate = UTType(identifier) else { return false }
      return candidate.conforms(to: .fileURL)
        || candidate.conforms(to: .data)
        || candidate.conforms(to: .item)
    }.forEach(append)
    return preferred
  }

  private func typeConformsToFolder(_ identifier: String) -> Bool {
    guard let type = UTType(identifier) else { return false }
    return type.conforms(to: .folder) || type.conforms(to: .directory)
  }

  private func uniqueDestination(in directory: URL, filename: String, isDirectory: Bool) -> URL {
    let candidate = directory.appending(path: filename, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
    let source = URL(filePath: filename)
    let stem = source.deletingPathExtension().lastPathComponent
    let suffix = source.pathExtension
    var counter = 2
    while true {
      let adjusted = suffix.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(suffix)"
      let url = directory.appending(path: adjusted, directoryHint: isDirectory ? .isDirectory : .notDirectory)
      if !fileManager.fileExists(atPath: url.path) { return url }
      counter += 1
    }
  }

  private func sanitizedComponent(_ value: String, fallback: String) -> String {
    let last = URL(filePath: value).lastPathComponent
    let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
    let cleaned = last.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
    let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return fallback }
    return String(trimmed.prefix(220))
  }

  private func nonBlank(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

struct MirroringItemProvider: @unchecked Sendable {
  var registeredTypeIdentifiers: [String]
  var suggestedName: String?
  var canLoadURLObject: Bool
  var loadURLObject: (@Sendable (
    _ completion: @escaping @Sendable (URL?, Error?) -> Void
  ) -> Progress)
  var loadInPlace: (@Sendable (
    _ typeIdentifier: String,
    _ completion: @escaping @Sendable (URL?, Bool, Error?) -> Void
  ) -> Progress)
  var loadFile: (@Sendable (
    _ typeIdentifier: String,
    _ completion: @escaping @Sendable (URL?, Error?) -> Void
  ) -> Progress)

  init(
    registeredTypeIdentifiers: [String],
    suggestedName: String?,
    canLoadURLObject: Bool,
    loadURLObject: @escaping @Sendable (
      _ completion: @escaping @Sendable (URL?, Error?) -> Void
    ) -> Progress,
    loadInPlace: @escaping @Sendable (
      _ typeIdentifier: String,
      _ completion: @escaping @Sendable (URL?, Bool, Error?) -> Void
    ) -> Progress,
    loadFile: @escaping @Sendable (
      _ typeIdentifier: String,
      _ completion: @escaping @Sendable (URL?, Error?) -> Void
    ) -> Progress
  ) {
    self.registeredTypeIdentifiers = registeredTypeIdentifiers
    self.suggestedName = suggestedName
    self.canLoadURLObject = canLoadURLObject
    self.loadURLObject = loadURLObject
    self.loadInPlace = loadInPlace
    self.loadFile = loadFile
  }

  init(_ provider: NSItemProvider) {
    let box = UncheckedItemProviderBox(provider)
    registeredTypeIdentifiers = provider.registeredTypeIdentifiers
    suggestedName = provider.suggestedName
    canLoadURLObject = provider.canLoadObject(ofClass: NSURL.self)
    loadURLObject = { completion in
      box.provider.loadObject(ofClass: NSURL.self) { value, error in
        completion((value as? NSURL).map { $0 as URL }, error)
      }
    }
    loadInPlace = { typeIdentifier, completion in
      box.provider.loadInPlaceFileRepresentation(
        forTypeIdentifier: typeIdentifier,
        completionHandler: completion
      )
    }
    loadFile = { typeIdentifier, completion in
      box.provider.loadFileRepresentation(
        forTypeIdentifier: typeIdentifier,
        completionHandler: completion
      )
    }
  }
}

private final class UncheckedItemProviderBox: @unchecked Sendable {
  let provider: NSItemProvider

  init(_ provider: NSItemProvider) {
    self.provider = provider
  }
}

private final class ProviderRepresentationState: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URL, any Error>?
  private var providerProgress: Progress?
  private var isFinished = false
  private var isCancelled = false

  func install(_ continuation: CheckedContinuation<URL, any Error>) {
    lock.lock()
    if isFinished {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func setProgress(_ progress: Progress) {
    lock.lock()
    let cancelImmediately = isCancelled
    if !isFinished { providerProgress = progress }
    lock.unlock()
    if cancelImmediately { progress.cancel() }
  }

  func complete(_ result: Result<URL, any Error>) {
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    isFinished = true
    let continuation = continuation
    self.continuation = nil
    providerProgress = nil
    lock.unlock()
    continuation?.resume(with: result)
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    guard !isFinished else {
      let progress = providerProgress
      lock.unlock()
      progress?.cancel()
      return
    }
    isFinished = true
    let continuation = continuation
    let progress = providerProgress
    self.continuation = nil
    providerProgress = nil
    lock.unlock()
    progress?.cancel()
    continuation?.resume(throwing: CancellationError())
  }

  func checkCancellation() throws {
    lock.lock()
    let cancelled = isCancelled
    lock.unlock()
    if cancelled { throw CancellationError() }
  }
}

private enum ProviderRepresentationError: Error {
  case unavailable
}
