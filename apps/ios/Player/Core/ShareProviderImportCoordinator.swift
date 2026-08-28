import Foundation
import UniformTypeIdentifiers
import UIKit

/// A sendable boundary around NSItemProvider so provider lifetime, cancellation,
/// and temporary-URL rules can be tested without replacing the handoff writer.
struct ShareImportItemProvider: @unchecked Sendable {
  var registeredTypeIdentifiers: [String]
  var suggestedName: String?
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
    self.loadInPlace = loadInPlace
    self.loadFile = loadFile
  }

  init(_ provider: NSItemProvider) {
    let box = ShareUncheckedItemProviderBox(provider)
    registeredTypeIdentifiers = provider.registeredTypeIdentifiers
    suggestedName = provider.suggestedName
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

struct ShareProviderImportCoordinator: Sendable {
  struct Selection: Sendable {
    var provider: ShareImportItemProvider
    var typeIdentifier: String
    var suggestedName: String?
  }

  func selections(from providers: [ShareImportItemProvider]) throws -> [Selection] {
    guard !providers.isEmpty else { throw ShareProviderImportError.noSupportedFiles }
    let selections = providers.map { provider -> Selection? in
      guard let typeIdentifier = preferredTypeIdentifier(for: provider) else { return nil }
      return Selection(
        provider: provider,
        typeIdentifier: typeIdentifier,
        suggestedName: provider.suggestedName
      )
    }
    // A share request is one transaction. Never silently drop unsupported
    // siblings and publish only the subset that happened to load.
    guard selections.allSatisfy({ $0 != nil }) else {
      throw ShareProviderImportError.mixedUnsupportedSelection
    }
    return selections.compactMap { $0 }
  }

  func copy(
    _ selections: [Selection],
    to writer: AppGroupImportHandoffWriter,
    progress: @MainActor @Sendable (_ completed: Int, _ total: Int) -> Void
  ) async throws {
    guard !selections.isEmpty else { throw ShareProviderImportError.noSupportedFiles }
    for (index, selection) in selections.enumerated() {
      try Task.checkCancellation()
      await progress(index, selections.count)
      try await copyProviderRepresentation(selection, index: index, writer: writer)
    }
    await progress(selections.count, selections.count)
  }

  private func preferredTypeIdentifier(for provider: ShareImportItemProvider) -> String? {
    let supported = [
      "com.apple.protected-mpeg-4-audio-b",
      "com.apple.m4a-audio",
      "public.mp3",
      "public.zip-archive",
    ]
    if let identifier = provider.registeredTypeIdentifiers.first(where: { identifier in
      guard let candidate = UTType(identifier) else { return false }
      return supported.contains { supportedIdentifier in
        guard let supportedType = UTType(supportedIdentifier) else { return false }
        return candidate.conforms(to: supportedType)
      }
    }) {
      return identifier
    }

    if let suggestedName = provider.suggestedName,
       Self.supportedExtensions.contains(URL(filePath: suggestedName).pathExtension.lowercased())
    {
      return provider.registeredTypeIdentifiers.first
    }

    if let suggestedName = provider.suggestedName {
      let advertisedExtension = URL(filePath: suggestedName).pathExtension.lowercased()
      if !advertisedExtension.isEmpty, !Self.supportedExtensions.contains(advertisedExtension) {
        return nil
      }
    }

    let genericTypes = [UTType.fileURL, .data, .item]
    return provider.registeredTypeIdentifiers.first { identifier in
      guard let candidate = UTType(identifier) else { return false }
      return genericTypes.contains { candidate.conforms(to: $0) }
    }
  }

  private func copyProviderRepresentation(
    _ selection: Selection,
    index: Int,
    writer: AppGroupImportHandoffWriter
  ) async throws {
    do {
      try await loadRepresentation(
        selection,
        index: index,
        writer: writer,
        inPlace: true
      )
    } catch let unavailable as ShareInPlaceRepresentationUnavailable {
      do {
        try await loadRepresentation(
          selection,
          index: index,
          writer: writer,
          inPlace: false
        )
      } catch ShareProviderImportError.missingFileRepresentation {
        if let providerError = unavailable.providerError { throw providerError }
        throw ShareProviderImportError.missingFileRepresentation
      }
    }
  }

  private func loadRepresentation(
    _ selection: Selection,
    index: Int,
    writer: AppGroupImportHandoffWriter,
    inPlace: Bool
  ) async throws {
    let state = ShareProviderRequestState()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        state.install(continuation)
        if inPlace {
          let providerProgress = selection.provider.loadInPlace(
            selection.typeIdentifier
          ) { sourceURL, _, error in
            Self.consumeRepresentation(
              sourceURL: sourceURL,
              error: error,
              selection: selection,
              index: index,
              writer: writer,
              unavailableInPlace: true,
              state: state
            )
          }
          state.setProgress(providerProgress)
        } else {
          let providerProgress = selection.provider.loadFile(
            selection.typeIdentifier
          ) { sourceURL, error in
            Self.consumeRepresentation(
              sourceURL: sourceURL,
              error: error,
              selection: selection,
              index: index,
              writer: writer,
              unavailableInPlace: false,
              state: state
            )
          }
          state.setProgress(providerProgress)
        }
      }
    } onCancel: {
      state.cancel()
    }
  }

  /// Provider-owned temporary URLs are valid only during their callback, so
  /// metadata validation and the complete bounded streaming copy happen here.
  nonisolated private static func consumeRepresentation(
    sourceURL: URL?,
    error: Error?,
    selection: Selection,
    index: Int,
    writer: AppGroupImportHandoffWriter,
    unavailableInPlace: Bool,
    state: ShareProviderRequestState
  ) {
    autoreleasepool {
      do {
        try state.checkCancellation()
        guard error == nil, let sourceURL else {
          if unavailableInPlace {
            throw ShareInPlaceRepresentationUnavailable(providerError: error)
          }
          if let error { throw error }
          throw ShareProviderImportError.missingFileRepresentation
        }
        let metadata = try metadata(
          sourceURL: sourceURL,
          typeIdentifier: selection.typeIdentifier,
          suggestedName: selection.suggestedName,
          index: index
        )
        try writer.appendCopying(
          sourceURL,
          fileExtension: metadata.fileExtension,
          contentTypeIdentifier: metadata.contentTypeIdentifier,
          originalFilename: metadata.originalFilename
        )
        state.complete(.success(()))
      } catch {
        state.complete(.failure(error))
      }
    }
  }

  static func metadata(
    sourceURL: URL,
    typeIdentifier: String,
    suggestedName: String?,
    index: Int
  ) throws -> ShareFileMetadata {
    let suggestedExtension = suggestedName.map { URL(filePath: $0).pathExtension } ?? ""
    let fileExtension = [
      suggestedExtension,
      sourceURL.pathExtension,
      UTType(typeIdentifier)?.preferredFilenameExtension ?? "",
    ]
      .map { $0.lowercased() }
      .first { supportedExtensions.contains($0) }
    guard let fileExtension else { throw ShareProviderImportError.noSupportedFiles }
    let fallback = String(format: "Shared audiobook %02d.%@", index + 1, fileExtension)
    var originalFilename = sanitizedFilename(
      suggestedName ?? sourceURL.lastPathComponent,
      fallback: fallback
    )
    if URL(filePath: originalFilename).pathExtension.isEmpty {
      originalFilename += ".\(fileExtension)"
    }
    return ShareFileMetadata(
      fileExtension: fileExtension,
      contentTypeIdentifier: UTType(filenameExtension: fileExtension)?.identifier,
      originalFilename: originalFilename
    )
  }

  private static let supportedExtensions = ["m4a", "m4b", "mp3", "zip"]

  private static func sanitizedFilename(_ value: String, fallback: String) -> String {
    let lastComponent = URL(filePath: value).lastPathComponent
    let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
    let cleaned = lastComponent.unicodeScalars
      .map { forbidden.contains($0) ? "-" : String($0) }
      .joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return fallback }
    return String(cleaned.prefix(220))
  }
}

struct ShareFileMetadata: Equatable, Sendable {
  var fileExtension: String
  var contentTypeIdentifier: String?
  var originalFilename: String
}

enum ShareProviderImportError: LocalizedError, Equatable, Sendable {
  case noSupportedFiles
  case mixedUnsupportedSelection
  case missingFileRepresentation

  var errorDescription: String? {
    switch self {
    case .noSupportedFiles:
      "No supported audiobook files were shared."
    case .mixedUnsupportedSelection:
      "The selection includes a file Bookshelf cannot import. Share only M4A, M4B, MP3, or ZIP files."
    case .missingFileRepresentation:
      "A shared file could not be read."
    }
  }
}

private final class ShareUncheckedItemProviderBox: @unchecked Sendable {
  let provider: NSItemProvider

  init(_ provider: NSItemProvider) {
    self.provider = provider
  }
}

private struct ShareInPlaceRepresentationUnavailable: Error {
  var providerError: Error?
}

private final class ShareProviderRequestState: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var providerProgress: Progress?
  private var isFinished = false
  private var isCancelled = false

  func install(_ continuation: CheckedContinuation<Void, any Error>) {
    lock.lock()
    guard !isFinished else {
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

  func complete(_ result: Result<Void, any Error>) {
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
