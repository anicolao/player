import UIKit

final class ShareViewController: UIViewController {
  private let statusLabel = UILabel()
  private let closeButton = UIButton(type: .system)
  private var didStart = false
  private var importTask: Task<Void, Never>?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .preferredFont(forTextStyle: .headline)
    statusLabel.adjustsFontForContentSizeCategory = true
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    statusLabel.text = "Preparing audiobook…"
    statusLabel.accessibilityIdentifier = "share-extension-status"
    view.addSubview(statusLabel)
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.configuration = .filled()
    closeButton.configuration?.title = "Close"
    closeButton.accessibilityIdentifier = "share-extension-close"
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
    importTask = Task { await acceptSharedFiles() }
  }

  private func acceptSharedFiles() async {
    var writer: AppGroupImportHandoffWriter?
    do {
      let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        .flatMap { $0.attachments ?? [] }
      let coordinator = ShareProviderImportCoordinator()
      let selections = try coordinator.selections(
        from: attachments.map(ShareImportItemProvider.init)
      )

      guard let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: PlayerAppGroup.identifier
      ) else { throw ShareViewError.appGroupUnavailable }
      let handoffWriter = try AppGroupImportHandoffWriter(containerURL: container)
      writer = handoffWriter
      try await coordinator.copy(selections, to: handoffWriter) { completed, total in
        guard completed < total else { return }
        statusLabel.text = total == 1
          ? "Adding audiobook…"
          : "Adding file \(completed + 1) of \(total)…"
      }
      try handoffWriter.publish()
      statusLabel.text = "Added to Bookshelf Inbox"
      extensionContext?.completeRequest(returningItems: nil)
    } catch is CancellationError {
      writer?.cancel()
    } catch {
      writer?.cancel()
      statusLabel.text = "Couldn’t add these files to Bookshelf\n\n\(error.localizedDescription)"
      closeButton.isHidden = false
    }
  }

  @objc private func closeAfterFailure() {
    importTask?.cancel()
    extensionContext?.cancelRequest(withError: ShareViewError.userClosedFailure)
  }
}

private enum ShareViewError: LocalizedError {
  case appGroupUnavailable
  case userClosedFailure

  var errorDescription: String? {
    switch self {
    case .appGroupUnavailable: "The Bookshelf shared container is unavailable."
    case .userClosedFailure: "The failed share request was closed."
    }
  }
}
