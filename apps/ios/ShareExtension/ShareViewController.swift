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
      for (index, selection) in selections.enumerated() {
        materialized.append(try await Self.copyFileRepresentation(
          from: selection.0,
          typeIdentifier: selection.1,
          index: index,
          temporaryDirectory: temporaryDirectory
        ))
        typeIdentifiers.append(selection.1)
      }

      guard let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: PlayerAppGroup.identifier
      ) else { throw ShareViewError.appGroupUnavailable }
      let queue = AppGroupImportHandoffQueue(containerURL: container)
      try await queue.enqueueCopying(
        materialized,
        contentTypeIdentifiers: typeIdentifiers,
        originalFilenames: selections.map(\.originalName)
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
    return provider.registeredTypeIdentifiers.first { identifier in
      guard let candidate = UTType(identifier) else { return false }
      return supported.contains { supportedIdentifier in
        guard let supportedType = UTType(supportedIdentifier) else { return false }
        return candidate.conforms(to: supportedType)
      }
    }
  }

  private static func copyFileRepresentation(
    from provider: NSItemProvider,
    typeIdentifier: String,
    index: Int,
    temporaryDirectory: URL
  ) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, error in
        do {
          if let error { throw error }
          guard let sourceURL else { throw ShareViewError.missingFileRepresentation }
          let fileExtension = sourceURL.pathExtension.isEmpty
            ? (UTType(typeIdentifier)?.preferredFilenameExtension ?? "data")
            : sourceURL.pathExtension
          let destination = temporaryDirectory.appending(
            path: String(format: "%05d.%@", index, fileExtension)
          )
          try FileManager.default.copyItem(at: sourceURL, to: destination)
          continuation.resume(returning: destination)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
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
