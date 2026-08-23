import Observation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
@Observable
final class ComputerReceiverController {
  private static var preparedTransportRoots: Set<String> = []

  enum Phase: Equatable {
    case idle
    case starting
    case ready
    case connected(String)
    case receiving(name: String, completedBytes: Int64, totalBytes: Int64)
    case preparingDrop(name: String, completedItems: Int, totalItems: Int)
    case importing(String)
    case completed(message: String, addedBookCount: Int)
    case needsReview(String)
    case failed(String)
  }

  private(set) var phase: Phase = .idle
  private(set) var address = ""
  private(set) var pairingCode = ""
  private(set) var receiverIsRunning = false
  @ObservationIgnored private let server: ComputerReceiverServer
  @ObservationIgnored private let mirroringDropAdapter: MirroringDropAdapter
  @ObservationIgnored private let usesSimulatedReadyState: Bool
  @ObservationIgnored private let usesSimulatedDropProgress: Bool
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var dropTask: Task<Void, Never>?
  @ObservationIgnored private var dropOperation: MirroringDropMaterializationOperation?
  @ObservationIgnored private var activeDropSession: (any UIDropSession)?

  init(fileManager: FileManager = .default, bundle: Bundle = .main) {
    usesSimulatedReadyState = ProcessInfo.processInfo.arguments.contains(
      "-e2e-computer-receiver-ready"
    )
    usesSimulatedDropProgress = ProcessInfo.processInfo.arguments.contains(
      "-e2e-mirroring-drop-progress"
    )
    let support = (try? fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )) ?? fileManager.temporaryDirectory
    let root = support
      .appending(path: "Player", directoryHint: .isDirectory)
      .appending(path: "ComputerReceiver", directoryHint: .isDirectory)
      .standardizedFileURL
    // Receiver sessions cannot resume after process death. Remove leftovers on
    // the first screen construction in this process, but never when reopening
    // the screen while an accepted background import is still using the root.
    if Self.preparedTransportRoots.insert(root.path).inserted {
      try? fileManager.removeItem(at: root)
      try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }
    server = ComputerReceiverServer(rootURL: root, bundle: bundle)
    mirroringDropAdapter = MirroringDropAdapter(rootURL: root, fileManager: fileManager)
  }

  func start(model: PlayerModel) {
    guard startTask == nil else { return }
    if usesSimulatedReadyState {
      address = "http://192.168.1.42:49152"
      pairingCode = "482731"
      receiverIsRunning = true
      phase = usesSimulatedDropProgress
        ? .preparingDrop(name: "Project Hail Mary", completedItems: 1, totalItems: 3)
        : .ready
      return
    }
    phase = .starting
    startTask = Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await server.start(
          importHandler: { urls in await model.importFromComputer(urls) },
          eventHandler: { [weak self] event in self?.apply(event) }
        )
        receiverIsRunning = true
      } catch {
        receiverIsRunning = false
        phase = .failed(error.localizedDescription)
      }
    }
  }

  func stop() {
    startTask?.cancel()
    startTask = nil
    dropTask?.cancel()
    dropTask = nil
    dropOperation?.cancel()
    dropOperation = nil
    activeDropSession = nil
    receiverIsRunning = false
    if !usesSimulatedReadyState { Task { await server.stop() } }
    phase = .idle
  }

  func retry(model: PlayerModel) {
    if receiverIsRunning {
      // Import failures do not stop the listener. Keep the paired browser and
      // its bearer credential valid so another drag can begin immediately.
      phase = .ready
      return
    }
    startTask?.cancel()
    phase = .starting
    startTask = Task { [weak self] in
      guard let self else { return }
      await server.stop()
      guard !Task.isCancelled else { return }
      do {
        _ = try await server.start(
          importHandler: { urls in await model.importFromComputer(urls) },
          eventHandler: { [weak self] event in self?.apply(event) }
        )
        receiverIsRunning = true
      } catch {
        receiverIsRunning = false
        phase = .failed(error.localizedDescription)
      }
    }
  }

  @discardableResult
  func importDroppedSession(_ session: any UIDropSession, model: PlayerModel) -> Bool {
    let providers = session.items.map(\.itemProvider)
    guard !providers.isEmpty, dropTask == nil else { return false }
    // iPhone Mirroring owns the cross-device data-transfer monitor through the
    // UIDropSession. Retaining only its item providers lets UIKit tear that
    // monitor down while a large Finder file is still being materialized.
    activeDropSession = session
    let operation: MirroringDropMaterializationOperation
    do {
      // This call must remain synchronous with UIDropInteraction.performDrop.
      operation = try mirroringDropAdapter.beginMaterializing(providers)
      dropOperation = operation
    } catch {
      activeDropSession = nil
      phase = .failed(error.localizedDescription)
      return false
    }
    phase = .preparingDrop(name: "Dropped items", completedItems: 0, totalItems: providers.count)
    dropTask = Task { [weak self] in
      guard let self else { return }
      do {
        let materialization = try await operation.value {
          [weak self] progress in
          self?.phase = .preparingDrop(
            name: progress.currentName,
            completedItems: progress.completedItems,
            totalItems: progress.totalItems
          )
        }
        defer { mirroringDropAdapter.cleanup(materialization) }
        phase = .importing(materialization.displayName)
        let outcome = await model.importFromComputer(materialization.selectionURLs)
        switch outcome.state {
        case .completed:
          phase = .completed(message: outcome.message, addedBookCount: outcome.addedBookCount)
        case .needsReview:
          phase = .needsReview(outcome.message)
        case .failed:
          phase = .failed(outcome.message)
        }
      } catch is CancellationError {
        if phase != .idle {
          phase = .failed("The mirrored drop was cancelled and its temporary files were removed.")
        }
      } catch {
        phase = .failed(error.localizedDescription)
      }
      dropTask = nil
      dropOperation = nil
      activeDropSession = nil
    }
    return true
  }

  private func apply(_ event: ComputerReceiverEvent) {
    switch event {
    case .ready(let address, let pairingCode):
      self.address = address
      self.pairingCode = pairingCode
      phase = .ready
    case .connected(let clientName):
      phase = .connected(clientName)
    case .receiving(let name, let completedBytes, let totalBytes):
      phase = .receiving(name: name, completedBytes: completedBytes, totalBytes: totalBytes)
    case .importing(let name):
      phase = .importing(name)
    case .completed(let message, let addedBookCount):
      phase = .completed(message: message, addedBookCount: addedBookCount)
    case .needsReview(let message):
      phase = .needsReview(message)
    case .failed(let message):
      phase = .failed(message)
    case .stopped:
      if phase != .idle { phase = .idle }
    }
  }
}

struct ComputerReceiverView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: PlayerModel
  @State private var controller = ComputerReceiverController()
  @State private var showStopConfirmation = false
  @State private var isDropTargeted = ProcessInfo.processInfo.arguments.contains(
    "-e2e-mirroring-drop-targeted"
  )
  let didFinish: (_ needsInbox: Bool) -> Void

  var body: some View {
    NavigationStack {
      ZStack {
        PlayerColor.background.ignoresSafeArea()
        ScrollView {
          VStack(spacing: 24) {
            statusHeader
            content
          }
          .frame(maxWidth: 560)
          .padding(.horizontal, 24)
          .padding(.vertical, 28)
        }
        if isDropTargeted { dropOverlay }
      }
      .navigationTitle("Receive from Computer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { requestStop() }
        }
      }
      .task { controller.start(model: model) }
      .onDisappear {
        UIApplication.shared.isIdleTimerDisabled = false
        controller.stop()
      }
      .onChange(of: controller.phase) { _, phase in
        UIApplication.shared.isIdleTimerDisabled = phase.isActivelyReceiving
        guard case .completed = phase else { return }
        Task {
          try? await Task.sleep(for: .seconds(1.2))
          didFinish(false)
          dismiss()
        }
      }
      .background {
        MirroringWindowDropInteraction(
          acceptedTypeIdentifiers: MirroringDropAdapter.acceptedTypeIdentifiers,
          isTargeted: $isDropTargeted
        ) { session in
          controller.importDroppedSession(session, model: model)
        }
      }
      .confirmationDialog(
        "Stop receiving from this computer?",
        isPresented: $showStopConfirmation,
        titleVisibility: .visible
      ) {
        Button("Stop and Clean Up", role: .destructive) {
          controller.stop()
          dismiss()
        }
        Button("Keep Receiving", role: .cancel) {}
      } message: {
        Text("The current transfer will stop. Files already added to your Library are not affected.")
      }
      .accessibilityIdentifier("computer-receiver-screen")
      .accessibilityValue(accessibilityState)
    }
  }

  @ViewBuilder
  private var statusHeader: some View {
    switch controller.phase {
    case .idle, .starting:
      Label("Starting receiver…", systemImage: "wifi")
        .font(.headline)
        .foregroundStyle(PlayerColor.secondary)
    case .ready:
      Label("Ready for uploads", systemImage: "checkmark.circle.fill")
        .font(.headline)
        .foregroundStyle(Color.green)
    case .connected(let name):
      Label("\(name) connected", systemImage: "checkmark.circle.fill")
        .font(.headline)
        .foregroundStyle(Color.green)
    case .receiving:
      Label("Receiving audiobook", systemImage: "arrow.down.circle.fill")
        .font(.headline)
        .foregroundStyle(PlayerColor.accent)
    case .preparingDrop:
      Label("Receiving mirrored drop", systemImage: "arrow.down.doc.fill")
        .font(.headline)
        .foregroundStyle(PlayerColor.accent)
    case .importing:
      Label("Checking audiobook", systemImage: "waveform.badge.magnifyingglass")
        .font(.headline)
        .foregroundStyle(PlayerColor.accent)
    case .completed:
      Label("Added to Library", systemImage: "checkmark.circle.fill")
        .font(.headline)
        .foregroundStyle(Color.green)
    case .needsReview:
      Label("Review needed", systemImage: "tray.full.fill")
        .font(.headline)
        .foregroundStyle(PlayerColor.accent)
    case .failed:
      Label("Couldn’t complete import", systemImage: "exclamationmark.triangle.fill")
        .font(.headline)
        .foregroundStyle(Color.red)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch controller.phase {
    case .idle, .starting:
      VStack(spacing: 12) {
        ProgressView().controlSize(.large).tint(PlayerColor.accent)
        Text("This usually takes a moment.").foregroundStyle(PlayerColor.secondary)
      }
      .padding(.vertical, 56)
    case .ready, .connected:
      readyContent
    case .receiving(let name, let completedBytes, let totalBytes):
      transferCard(name: name, completedBytes: completedBytes, totalBytes: totalBytes)
    case .preparingDrop(let name, let completedItems, let totalItems):
      VStack(spacing: 18) {
        ProgressView(value: Double(completedItems), total: Double(max(1, totalItems)))
          .tint(PlayerColor.accent)
        Text(name).font(.title3.bold()).foregroundStyle(PlayerColor.ink)
        Text("Preparing dropped item \(min(completedItems + 1, totalItems)) of \(totalItems)…")
          .multilineTextAlignment(.center)
          .foregroundStyle(PlayerColor.secondary)
      }
      .padding(.vertical, 48)
      .accessibilityIdentifier("mirroring-drop-progress")
    case .importing(let name):
      VStack(spacing: 18) {
        ProgressView().controlSize(.large).tint(PlayerColor.accent)
        Text(name).font(.title3.bold()).foregroundStyle(PlayerColor.ink)
        Text("Player is checking your files and adding valid books automatically.")
          .multilineTextAlignment(.center)
          .foregroundStyle(PlayerColor.secondary)
      }
      .padding(.vertical, 48)
    case .completed(let message, _):
      VStack(spacing: 18) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 58))
          .foregroundStyle(Color.green)
        Text(message).font(.title2.bold()).foregroundStyle(PlayerColor.ink)
        Text("Ready to play").foregroundStyle(PlayerColor.secondary)
      }
      .padding(.vertical, 44)
    case .needsReview(let message):
      VStack(spacing: 18) {
        Text(message)
          .multilineTextAlignment(.center)
          .foregroundStyle(PlayerColor.ink)
        Button("Open Inbox") {
          didFinish(true)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .tint(PlayerColor.accent)
        .accessibilityIdentifier("open-received-import-inbox")
      }
      .padding(.vertical, 32)
    case .failed(let message):
      VStack(spacing: 18) {
        Text(message)
          .multilineTextAlignment(.center)
          .foregroundStyle(PlayerColor.ink)
        Button(controller.receiverIsRunning ? "Try Another Upload" : "Restart Receiver") {
          controller.retry(model: model)
        }
        .buttonStyle(.borderedProminent)
        .tint(PlayerColor.accent)
      }
      .padding(.vertical, 32)
    }
  }

  private var readyContent: some View {
    VStack(spacing: 22) {
      VStack(spacing: 10) {
        Text("On your computer, open").foregroundStyle(PlayerColor.secondary)
        Text(controller.address)
          .font(.system(.body, design: .monospaced).weight(.semibold))
          .foregroundStyle(PlayerColor.accent)
          .textSelection(.enabled)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier("computer-receiver-address")
        Button("Copy Address") { UIPasteboard.general.string = controller.address }
          .buttonStyle(.bordered)
          .tint(PlayerColor.accent)
          .accessibilityIdentifier("copy-computer-receiver-address")
      }

      Divider()

      VStack(spacing: 8) {
        Text("PAIRING CODE")
          .font(.caption.weight(.semibold))
          .tracking(1.4)
          .foregroundStyle(PlayerColor.secondary)
        Text(formattedPairingCode)
          .font(.system(size: 36, weight: .bold, design: .monospaced))
          .tracking(8)
          .foregroundStyle(PlayerColor.accent)
          .accessibilityLabel("Pairing code")
          .accessibilityValue(controller.pairingCode.map(String.init).joined(separator: " "))
          .accessibilityIdentifier("computer-receiver-pairing-code")
        Text("Keep this screen open while books transfer.")
          .font(.subheadline)
          .foregroundStyle(PlayerColor.secondary)
      }

      if MirroringTipPolicy.shouldShow {
        HStack(alignment: .top, spacing: 16) {
          Image(systemName: "laptopcomputer.and.iphone")
            .font(.title2)
            .foregroundStyle(PlayerColor.accent)
            .frame(width: 42)
          VStack(alignment: .leading, spacing: 5) {
            Text("Using a Mac?").font(.headline).foregroundStyle(PlayerColor.ink)
            Text("In supported regions, you can also drag books straight into this Player window with iPhone Mirroring.")
              .font(.subheadline)
              .foregroundStyle(PlayerColor.secondary)
          }
        }
        .padding(18)
        .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(PlayerColor.ink.opacity(0.1))
        }
        .accessibilityIdentifier("mirroring-import-tip")
      }

      Button("Stop Receiving", role: .destructive) { showStopConfirmation = true }
        .buttonStyle(.borderedProminent)
        .tint(PlayerColor.accent)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("stop-computer-receiver")
    }
  }

  private func transferCard(name: String, completedBytes: Int64, totalBytes: Int64) -> some View {
    let fraction = totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    return VStack(alignment: .leading, spacing: 14) {
      Text(name).font(.title3.bold()).foregroundStyle(PlayerColor.ink)
      Text("\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) total")
        .foregroundStyle(PlayerColor.secondary)
      ProgressView(value: fraction)
        .tint(PlayerColor.accent)
      HStack {
        Text(ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file))
        Spacer()
        Text("\(Int(fraction * 100))%")
      }
      .font(.subheadline.monospacedDigit())
      .foregroundStyle(PlayerColor.secondary)
      Text("Valid books are added automatically.")
        .font(.subheadline)
        .foregroundStyle(PlayerColor.secondary)
    }
    .padding(20)
    .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityIdentifier("computer-receiver-transfer")
    .accessibilityValue("receiving:\(completedBytes)-of-\(totalBytes)")
  }

  private var dropOverlay: some View {
    ZStack {
      PlayerColor.background.opacity(0.96).ignoresSafeArea()
      VStack(spacing: 16) {
        Image(systemName: "arrow.down.doc.fill")
          .font(.system(size: 54))
          .foregroundStyle(PlayerColor.accent)
        Text("Drop to import").font(.title.bold()).foregroundStyle(PlayerColor.ink)
        Text("Books, folders, audio files, or ZIPs")
          .foregroundStyle(PlayerColor.secondary)
      }
    }
    .accessibilityIdentifier("computer-receiver-drop-target")
  }

  private var formattedPairingCode: String {
    guard controller.pairingCode.count == 6 else { return controller.pairingCode }
    let midpoint = controller.pairingCode.index(controller.pairingCode.startIndex, offsetBy: 3)
    return "\(controller.pairingCode[..<midpoint]) \(controller.pairingCode[midpoint...])"
  }

  private var accessibilityState: String {
    switch controller.phase {
    case .idle: "receiver:idle"
    case .starting: "receiver:starting"
    case .ready: "receiver:ready"
    case .connected: "receiver:connected"
    case .receiving: "receiver:receiving"
    case .preparingDrop: "receiver:preparing-mirrored-drop"
    case .importing: "receiver:importing"
    case .completed(_, let count): "receiver:completed:\(count)"
    case .needsReview: "receiver:needs-review"
    case .failed: "receiver:failed"
    }
  }

  private func requestStop() {
    if controller.phase.isActivelyReceiving { showStopConfirmation = true }
    else {
      controller.stop()
      dismiss()
    }
  }
}

/// Installs UIKit's native drop interaction on the app window while this screen
/// is visible. A transparent SwiftUI overlay would steal taps and scrolling,
/// while SwiftUI's `onDrop` isn't reliably exposed as a Finder destination by
/// iPhone Mirroring. Attaching the interaction to the existing window makes the
/// whole mirrored phone a destination without changing normal touch handling.
struct MirroringWindowDropInteraction: UIViewRepresentable {
  let acceptedTypeIdentifiers: [String]
  @Binding var isTargeted: Bool
  let performDrop: (any UIDropSession) -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(
      acceptedTypeIdentifiers: acceptedTypeIdentifiers,
      isTargeted: $isTargeted,
      performDrop: performDrop
    )
  }

  func makeUIView(context: Context) -> MirroringWindowProbeView {
    let view = MirroringWindowProbeView()
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = false
    view.didMoveToWindowHandler = { [weak coordinator = context.coordinator] window in
      coordinator?.install(on: window)
    }
    return view
  }

  func updateUIView(_ uiView: MirroringWindowProbeView, context: Context) {
    context.coordinator.update(
      acceptedTypeIdentifiers: acceptedTypeIdentifiers,
      isTargeted: $isTargeted,
      performDrop: performDrop
    )
    context.coordinator.install(on: uiView.window)
  }

  static func dismantleUIView(_ uiView: MirroringWindowProbeView, coordinator: Coordinator) {
    uiView.didMoveToWindowHandler = nil
    coordinator.uninstall()
  }

  final class Coordinator: NSObject, UIDropInteractionDelegate {
    private var acceptedTypeIdentifiers: [String]
    private var isTargeted: Binding<Bool>
    private var performDrop: (any UIDropSession) -> Bool
    private weak var installedView: UIView?
    private lazy var interaction = UIDropInteraction(delegate: self)

    init(
      acceptedTypeIdentifiers: [String],
      isTargeted: Binding<Bool>,
      performDrop: @escaping (any UIDropSession) -> Bool
    ) {
      self.acceptedTypeIdentifiers = acceptedTypeIdentifiers
      self.isTargeted = isTargeted
      self.performDrop = performDrop
    }

    func update(
      acceptedTypeIdentifiers: [String],
      isTargeted: Binding<Bool>,
      performDrop: @escaping (any UIDropSession) -> Bool
    ) {
      self.acceptedTypeIdentifiers = acceptedTypeIdentifiers
      self.isTargeted = isTargeted
      self.performDrop = performDrop
    }

    func install(on view: UIView?) {
      guard installedView !== view else { return }
      uninstall()
      guard let view else { return }
      view.addInteraction(interaction)
      installedView = view
    }

    func uninstall() {
      installedView?.removeInteraction(interaction)
      installedView = nil
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
      session.hasItemsConforming(toTypeIdentifiers: acceptedTypeIdentifiers)
    }

    func dropInteraction(
      _ interaction: UIDropInteraction,
      sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
      UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
      isTargeted.wrappedValue = true
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
      isTargeted.wrappedValue = false
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
      isTargeted.wrappedValue = false
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
      isTargeted.wrappedValue = false
      _ = performDrop(session)
    }
  }
}

final class MirroringWindowProbeView: UIView {
  var didMoveToWindowHandler: ((UIWindow?) -> Void)?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    didMoveToWindowHandler?(window)
  }
}

private extension ComputerReceiverController.Phase {
  var isActivelyReceiving: Bool {
    switch self {
    case .connected, .receiving, .preparingDrop, .importing: true
    default: false
    }
  }
}

enum MirroringTipPolicy {
  private static let europeanUnionRegions: Set<String> = [
    "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE",
    "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
  ]

  static var shouldShow: Bool {
    if ProcessInfo.processInfo.arguments.contains("-e2e-hide-mirroring-tip") { return false }
    if ProcessInfo.processInfo.arguments.contains("-e2e-show-mirroring-tip") { return true }
    guard let region = Locale.current.region?.identifier else { return false }
    return !europeanUnionRegions.contains(region)
  }
}
