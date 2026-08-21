import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private let statusLabel = UILabel()
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
    NSLayoutConstraint.activate([
      statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didStart else { return }
    didStart = true
    Task { await acceptSharedFiles() }
  }

  private func acceptSharedFiles() async {
    do {
      let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        .flatMap { $0.attachments ?? [] }
      let selections = attachments.compactMap {
        provider -> (provider: NSItemProvider, type: String, originalName: String?)? in
        guard let type = Self.preferredTypeIdentifier(for: provider) else { return nil }
        return (provider, type, provider.suggestedName)
      }
      guard !selections.isEmpty else { throw ShareViewError.noSupportedFiles }

      let temporaryDirectory = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString.lowercased(),
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: true
      )
      defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

      var materialized: [URL] = []
      var typeIdentifiers: [String?] = []
      var originalFilenames: [String?] = []
      for (index, selection) in selections.enumerated() {
        let file = try await Self.copyFileRepresentation(
          from: selection.0,
          typeIdentifier: selection.1,
          suggestedName: selection.2,
          index: index,
          temporaryDirectory: temporaryDirectory
        )
        materialized.append(file.url)
        typeIdentifiers.append(file.contentTypeIdentifier)
        originalFilenames.append(file.originalFilename)
      }

      guard let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: PlayerAppGroup.identifier
      ) else { throw ShareViewError.appGroupUnavailable }
      let queue = AppGroupImportHandoffQueue(containerURL: container)
      try await queue.enqueueCopying(
        materialized,
        contentTypeIdentifiers: typeIdentifiers,
        originalFilenames: originalFilenames
      )
      statusLabel.text = "Added to Player Inbox"
      try? await Task.sleep(for: .milliseconds(350))
      extensionContext?.completeRequest(returningItems: nil)
    } catch {
      statusLabel.text = "Couldn’t add these files to Player"
      extensionContext?.cancelRequest(withError: error)
    }
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

    // Files may expose a multi-selection as generic file/data providers even
    // when every suggested filename has a supported audiobook extension. Load
    // the representation, then validate its actual extension before copying.
    let genericTypes = [UTType.fileURL, .data, .item]
    return provider.registeredTypeIdentifiers.first { identifier in
      guard let candidate = UTType(identifier) else { return false }
      return genericTypes.contains { candidate.conforms(to: $0) }
    }
  }

  private static func copyFileRepresentation(
    from provider: NSItemProvider,
    typeIdentifier: String,
    suggestedName: String?,
    index: Int,
    temporaryDirectory: URL
  ) async throws -> MaterializedShareFile {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, error in
        do {
          if let error { throw error }
          guard let sourceURL else { throw ShareViewError.missingFileRepresentation }
          let suggestedExtension = suggestedName.map { URL(filePath: $0).pathExtension } ?? ""
          let fileExtension = [
            suggestedExtension,
            sourceURL.pathExtension,
            UTType(typeIdentifier)?.preferredFilenameExtension ?? "",
          ]
            .map { $0.lowercased() }
            .first { ["m4a", "m4b", "mp3", "zip"].contains($0) }
          guard let fileExtension else { throw ShareViewError.noSupportedFiles }
          let destination = temporaryDirectory.appending(
            path: String(format: "%05d.%@", index, fileExtension)
          )
          try FileManager.default.copyItem(at: sourceURL, to: destination)
          let suppliedName = suggestedName.flatMap { name -> String? in
            let safeName = URL(filePath: name).lastPathComponent
            return safeName.isEmpty ? nil : safeName
          }
          let sourceName = sourceURL.lastPathComponent
          let originalFilename = suppliedName
            ?? (sourceName.isEmpty ? nil : sourceName)
            ?? String(format: "Shared audiobook %02d.%@", index + 1, fileExtension)
          continuation.resume(returning: MaterializedShareFile(
            url: destination,
            contentTypeIdentifier: UTType(filenameExtension: fileExtension)?.identifier,
            originalFilename: originalFilename
          ))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

private struct MaterializedShareFile {
  var url: URL
  var contentTypeIdentifier: String?
  var originalFilename: String
}

private enum ShareViewError: LocalizedError {
  case noSupportedFiles
  case appGroupUnavailable
  case missingFileRepresentation

  var errorDescription: String? {
    switch self {
    case .noSupportedFiles: "No supported audiobook files were shared."
    case .appGroupUnavailable: "The Player shared container is unavailable."
    case .missingFileRepresentation: "A shared file could not be read."
    }
  }
}
