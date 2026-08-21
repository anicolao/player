import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private let statusLabel = UILabel()
  private let closeButton = UIButton(type: .system)
  private var didStart = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .preferredFont(forTextStyle: .headline)
    statusLabel.adjustsFontForContentSizeCategory = true
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    statusLabel.text = "Preparing audiobook…"
    view.addSubview(statusLabel)
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.configuration = .filled()
    closeButton.configuration?.title = "Close"
    closeButton.isHidden = true
    closeButton.addTarget(self, action: #selector(closeAfterFailure), for: .touchUpInside)
    view.addSubview(closeButton)
    NSLayoutConstraint.activate([
      statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      closeButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 24),
      closeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didStart else { return }
    didStart = true
    Task { await acceptSharedFiles() }
  }

  private func acceptSharedFiles() async {
    var writer: AppGroupImportHandoffWriter?
    do {
      let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        .flatMap { $0.attachments ?? [] }
      let selections = attachments.compactMap {
        provider -> (provider: NSItemProvider, type: String, originalName: String?)? in
        guard let type = Self.preferredTypeIdentifier(for: provider) else { return nil }
        return (provider, type, provider.suggestedName)
      }
      guard !selections.isEmpty else { throw ShareViewError.noSupportedFiles }

      guard let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: PlayerAppGroup.identifier
      ) else { throw ShareViewError.appGroupUnavailable }
      let handoffWriter = try AppGroupImportHandoffWriter(containerURL: container)
      writer = handoffWriter
      for (index, selection) in selections.enumerated() {
        statusLabel.text = selections.count == 1
          ? "Adding audiobook…"
          : "Adding file \(index + 1) of \(selections.count)…"
        try await Self.copyProviderRepresentation(
          from: selection.provider,
          typeIdentifier: selection.type,
          suggestedName: selection.originalName,
          index: index,
          writer: handoffWriter
        )
      }
      try handoffWriter.publish()
      statusLabel.text = "Added to Player Inbox"
      try? await Task.sleep(for: .seconds(1))
      extensionContext?.completeRequest(returningItems: nil)
    } catch {
      writer?.cancel()
      statusLabel.text = "Couldn’t add these files to Player\n\n\(error.localizedDescription)"
      closeButton.isHidden = false
    }
  }

  @objc private func closeAfterFailure() {
    extensionContext?.cancelRequest(withError: ShareViewError.userClosedFailure)
  }

  private static func preferredTypeIdentifier(for provider: NSItemProvider) -> String? {
    let supported = [
      "com.apple.protected-mpeg-4-audio-b",
      "com.apple.m4a-audio",
      "public.mp3",
      "public.zip-archive",
    ]
    if let supportedIdentifier = provider.registeredTypeIdentifiers.first(where: { identifier in
      guard let candidate = UTType(identifier) else { return false }
      return supported.contains { supportedIdentifier in
        guard let supportedType = UTType(supportedIdentifier) else { return false }
        return candidate.conforms(to: supportedType)
      }
    }) {
      return supportedIdentifier
    }

    if let suggestedName = provider.suggestedName,
       ["m4a", "m4b", "mp3", "zip"].contains(URL(filePath: suggestedName).pathExtension.lowercased())
    {
      // Some Files providers expose only a vendor-specific or generic type
      // even though the suggested filename is precise. Request that native
      // representation before falling back to public.data/public.item.
      if let registered = provider.registeredTypeIdentifiers.first {
        return registered
      }
    }

    // Files may expose a multi-selection as generic file/data providers even
    // when every suggested filename has a supported audiobook extension. Load
    // the representation, then validate its actual extension before copying.
    let genericTypes = [UTType.fileURL, .data, .item]
    return provider.registeredTypeIdentifiers.first { identifier in
      guard let candidate = UTType(identifier) else { return false }
      return genericTypes.contains { candidate.conforms(to: $0) }
    }
  }

  private static func copyProviderRepresentation(
    from provider: NSItemProvider,
    typeIdentifier: String,
    suggestedName: String?,
    index: Int,
    writer: AppGroupImportHandoffWriter
  ) async throws {
    do {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) {
          sourceURL, _, error in
          guard error == nil, sourceURL != nil else {
            continuation.resume(throwing: ShareProviderLoadError.inPlaceUnavailable)
            return
          }
          copyRepresentation(
            sourceURL: sourceURL,
            error: nil,
            typeIdentifier: typeIdentifier,
            suggestedName: suggestedName,
            index: index,
            writer: writer,
            continuation: continuation
          )
        }
      }
    } catch ShareProviderLoadError.inPlaceUnavailable {
      // Providers that cannot vend an in-place URL may still vend a temporary
      // file representation. Copy it synchronously inside the callback because
      // the system may delete that URL as soon as the callback returns.
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, error in
          copyRepresentation(
            sourceURL: sourceURL,
            error: error,
            typeIdentifier: typeIdentifier,
            suggestedName: suggestedName,
            index: index,
            writer: writer,
            continuation: continuation
          )
        }
      }
    }
  }

  nonisolated private static func copyRepresentation(
    sourceURL: URL?,
    error: Error?,
    typeIdentifier: String,
    suggestedName: String?,
    index: Int,
    writer: AppGroupImportHandoffWriter,
    continuation: CheckedContinuation<Void, any Error>
  ) {
    autoreleasepool {
      do {
        if let error { throw error }
        guard let sourceURL else { throw ShareViewError.missingFileRepresentation }
        let metadata = try metadata(
          sourceURL: sourceURL,
          typeIdentifier: typeIdentifier,
          suggestedName: suggestedName,
          index: index
        )
        try writer.appendCopying(
          sourceURL,
          fileExtension: metadata.fileExtension,
          contentTypeIdentifier: metadata.contentTypeIdentifier,
          originalFilename: metadata.originalFilename
        )
        continuation.resume()
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  nonisolated private static func metadata(
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
      .first { ["m4a", "m4b", "mp3", "zip"].contains($0) }
    guard let fileExtension else { throw ShareViewError.noSupportedFiles }
    let suppliedName = suggestedName.flatMap { name -> String? in
      let safeName = URL(filePath: name).lastPathComponent
      return safeName.isEmpty ? nil : safeName
    }
    let sourceName = sourceURL.lastPathComponent
    var originalFilename = suppliedName
      ?? (sourceName.isEmpty ? nil : sourceName)
      ?? String(format: "Shared audiobook %02d.%@", index + 1, fileExtension)
    if URL(filePath: originalFilename).pathExtension.isEmpty {
      originalFilename += ".\(fileExtension)"
    }
    return ShareFileMetadata(
      fileExtension: fileExtension,
      contentTypeIdentifier: UTType(filenameExtension: fileExtension)?.identifier,
      originalFilename: originalFilename
    )
  }
}

private struct ShareFileMetadata {
  var fileExtension: String
  var contentTypeIdentifier: String?
  var originalFilename: String
}

private enum ShareProviderLoadError: Error {
  case inPlaceUnavailable
}

private enum ShareViewError: LocalizedError {
  case noSupportedFiles
  case appGroupUnavailable
  case missingFileRepresentation
  case userClosedFailure

  var errorDescription: String? {
    switch self {
    case .noSupportedFiles: "No supported audiobook files were shared."
    case .appGroupUnavailable: "The Player shared container is unavailable."
    case .missingFileRepresentation: "A shared file could not be read."
    case .userClosedFailure: "The failed share request was closed."
    }
  }
}
