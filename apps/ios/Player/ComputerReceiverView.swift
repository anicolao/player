import Observation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct E2EComputerReceiverLaunchConfiguration: Equatable {
  enum TransportRoot: Equatable {
    case production
    case e2e(namespace: String)

    func url(applicationSupportURL: URL, temporaryDirectory: URL) -> URL {
      switch self {
      case .production:
        applicationSupportURL
          .appending(path: "Player", directoryHint: .isDirectory)
          .appending(path: "ComputerReceiver", directoryHint: .isDirectory)
      case .e2e(let namespace):
        temporaryDirectory.appending(path: namespace, directoryHint: .isDirectory)
      }
    }
  }

    enum Scenario: String, CaseIterable {
      case ready
      case dropProgress = "drop-progress"
      case completed
      case paused
    }

    enum MirroringTip: Equatable {
      case automatic
      case show
      case hide
    }

    static let readyArgument = "-e2e-computer-receiver-ready"
    static let dropProgressArgument = "-e2e-mirroring-drop-progress"
    static let completedArgument = "-e2e-computer-receiver-completed"
    static let pausedArgument = "-e2e-computer-receiver-paused"
    static let showMirroringTipArgument = "-e2e-show-mirroring-tip"
    static let hideMirroringTipArgument = "-e2e-hide-mirroring-tip"

    let scenario: Scenario?
    let mirroringTip: MirroringTip
    let transportRoot: TransportRoot

    static let production = E2EComputerReceiverLaunchConfiguration(
      scenario: nil,
      mirroringTip: .automatic,
      transportRoot: .production
    )

    static func parse(
      arguments: [String],
      e2eLaunchConfiguration: E2ELaunchConfiguration?,
      launchIdentifier: String = String(ProcessInfo.processInfo.processIdentifier)
    ) throws -> E2EComputerReceiverLaunchConfiguration {
      guard let e2eLaunchConfiguration else {
        guard !arguments.contains(where: isReceiverArgument) else {
          throw PlayerCoreError.fileOperation(
            "Computer Receiver E2E options require E2E launch mode."
          )
        }
        return .production
      }
      guard !launchIdentifier.isEmpty,
        launchIdentifier.utf8.allSatisfy({
          (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
            || $0 == UInt8(ascii: "-")
        })
      else {
        throw PlayerCoreError.fileOperation("Invalid Computer Receiver E2E launch identifier.")
      }

      let recognizedArguments: Set<String> = [
        readyArgument,
        dropProgressArgument,
        completedArgument,
        pausedArgument,
        showMirroringTipArgument,
        hideMirroringTipArgument,
      ]
      if let unknown = arguments.first(where: {
        isReceiverArgument($0) && !recognizedArguments.contains($0)
      }) {
        throw PlayerCoreError.fileOperation(
          "Unknown Computer Receiver E2E option: \(unknown)"
        )
      }

      for argument in recognizedArguments where arguments.filter({ $0 == argument }).count > 1 {
        throw PlayerCoreError.fileOperation(
          "Duplicate Computer Receiver E2E option: \(argument)"
        )
      }

      let ready = arguments.contains(readyArgument)
      let phases: [(argument: String, scenario: Scenario)] = [
        (dropProgressArgument, .dropProgress),
        (completedArgument, .completed),
        (pausedArgument, .paused),
      ]
      let selectedPhases = phases.filter { arguments.contains($0.argument) }
      guard selectedPhases.count <= 1 else {
        throw PlayerCoreError.fileOperation(
          "Computer Receiver E2E phases are mutually exclusive."
        )
      }
      guard selectedPhases.isEmpty || ready else {
        throw PlayerCoreError.fileOperation(
          "A Computer Receiver E2E phase requires the ready scenario."
        )
      }
      let scenario = selectedPhases.first?.scenario ?? (ready ? .ready : nil)

      let showsTip = arguments.contains(showMirroringTipArgument)
      let hidesTip = arguments.contains(hideMirroringTipArgument)
      guard !(showsTip && hidesTip) else {
        throw PlayerCoreError.fileOperation(
          "Computer Receiver E2E mirroring-tip overrides are mutually exclusive."
        )
      }
      let mirroringTip: MirroringTip = showsTip ? .show : (hidesTip ? .hide : .automatic)
      let scenarioName = scenario?.rawValue ?? "live"

      return E2EComputerReceiverLaunchConfiguration(
        scenario: scenario,
        mirroringTip: mirroringTip,
        transportRoot: .e2e(
          namespace:
            "PlayerE2EComputerReceiver-\(e2eLaunchConfiguration.fixture.rawValue)-"
            + "\(scenarioName)-\(launchIdentifier)"
        )
      )
    }

    private static func isReceiverArgument(_ argument: String) -> Bool {
      argument.hasPrefix("-e2e-computer-receiver-")
        || argument.hasPrefix("-e2e-mirroring-drop-")
        || argument.hasPrefix("-e2e-show-mirroring-tip")
        || argument.hasPrefix("-e2e-hide-mirroring-tip")
    }
  }

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
    case paused(name: String, completedBytes: Int64, totalBytes: Int64)
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
  private(set) var httpExchange: ComputerReceiverHTTPExchange?
  @ObservationIgnored private let server: ComputerReceiverServer
  @ObservationIgnored private let mirroringDropAdapter: MirroringDropAdapter
  let transportRootURL: URL
  #if E2E
    @ObservationIgnored private let simulatedScenario: E2EComputerReceiverLaunchConfiguration.Scenario?
  #endif
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var dropTask: Task<Void, Never>?
  @ObservationIgnored private var dropOperation: MirroringDropMaterializationOperation?
  @ObservationIgnored private var activeDropSession: (any UIDropSession)?

  init(
    fileManager: FileManager = .default,
    bundle: Bundle = .main,
    launchConfiguration: E2EComputerReceiverLaunchConfiguration = .production,
    applicationSupportURL: URL? = nil,
    temporaryDirectory: URL? = nil
  ) {
    #if E2E
      simulatedScenario = launchConfiguration.scenario
    #endif
    let support = applicationSupportURL ?? (try? fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )) ?? fileManager.temporaryDirectory
    let root = launchConfiguration.transportRoot.url(
      applicationSupportURL: support,
      temporaryDirectory: temporaryDirectory ?? fileManager.temporaryDirectory
    )
      .standardizedFileURL
    transportRootURL = root
    switch launchConfiguration.transportRoot {
    case .production:
      // Receiver sessions cannot resume after process death. Remove leftovers
      // on first construction, but preserve accepted background imports when
      // the production screen is reopened in the same process.
      if Self.preparedTransportRoots.insert(root.path).inserted {
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
      }
    case .e2e:
      // The launch identifier makes this root private to one E2E app process.
      // Reopening the sheet in that process must retain accepted imports.
      try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }
    #if E2E
      let binding: (any ComputerReceiverBinding)? = simulatedScenario != nil
        ? E2EDeterministicComputerReceiverBinding()
        : nil
      let credentials: ComputerReceiverCredentials? = simulatedScenario != nil
        ? ComputerReceiverCredentials(
          pairingCode: "482731",
          bearerToken: "e2e-deterministic-receiver-token"
        )
        : nil
    #else
      let binding: (any ComputerReceiverBinding)? = nil
      let credentials: ComputerReceiverCredentials? = nil
    #endif
    server = ComputerReceiverServer(
      rootURL: root,
      bundle: bundle,
      binding: binding,
      credentials: credentials
    )
    mirroringDropAdapter = MirroringDropAdapter(rootURL: root, fileManager: fileManager)
  }

  func start(model: PlayerModel) {
    guard startTask == nil else { return }
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
    Task { await server.stop() }
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

  func receiveAnother() {
    guard receiverIsRunning else { return }
    phase = .ready
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
    case .httpExchange(let exchange):
      httpExchange = exchange
      #if E2E
        switch simulatedScenario {
        case .completed:
          phase = .completed(message: "Project Hail Mary added", addedBookCount: 1)
        case .paused:
          phase = .paused(
            name: "Project Hail Mary",
            completedBytes: 734_003_200,
            totalBytes: 1_468_006_400
          )
        case .dropProgress:
          phase = .preparingDrop(name: "Project Hail Mary", completedItems: 1, totalItems: 3)
        case .ready, nil:
          break
        }
      #endif
    case .connected(let clientName):
      phase = .connected(clientName)
    case .receiving(let name, let completedBytes, let totalBytes):
      phase = .receiving(name: name, completedBytes: completedBytes, totalBytes: totalBytes)
    case .paused(let name, let completedBytes, let totalBytes):
      phase = .paused(name: name, completedBytes: completedBytes, totalBytes: totalBytes)
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
  @State private var controller: ComputerReceiverController
  @State private var showStopConfirmation = false
  @State private var isDropTargeted = false
  let launchConfiguration: E2EComputerReceiverLaunchConfiguration
  let chooseFromFiles: () -> Void
  let didFinish: (_ needsInbox: Bool) -> Void

  init(
    model: PlayerModel,
    launchConfiguration: E2EComputerReceiverLaunchConfiguration,
    chooseFromFiles: @escaping () -> Void,
    didFinish: @escaping (_ needsInbox: Bool) -> Void
  ) {
    self.model = model
    self.launchConfiguration = launchConfiguration
    _controller = State(initialValue: ComputerReceiverController(
      launchConfiguration: launchConfiguration
    ))
    self.chooseFromFiles = chooseFromFiles
    self.didFinish = didFinish
  }

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
        .accessibilityIdentifier("computer-receiver-scroll")
        .e2eScrollReadiness(
          id: "computer-receiver-scroll-readiness",
          containerID: "computer-receiver-scroll",
          axis: .vertical
        )
        .playerMiniPlayerScrollRunway()
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
      #if E2E
        .overlay(alignment: .topLeading) {
          Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Computer receiver HTTP exchange")
            .accessibilityIdentifier("computer-receiver-http-probe")
            .accessibilityValue(httpExchangeValue)
        }
      #endif
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
    case .paused:
      Label("Transfer paused", systemImage: "pause.circle.fill")
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
    case .paused(let name, let completedBytes, let totalBytes):
      VStack(spacing: 16) {
        transferCard(name: name, completedBytes: completedBytes, totalBytes: totalBytes)
        Text("The computer can retry from the confirmed progress shown here.")
          .multilineTextAlignment(.center)
          .foregroundStyle(PlayerColor.secondary)
      }
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
        Button("Receive Another") { controller.receiveAnother() }
          .buttonStyle(.borderedProminent)
          .tint(PlayerColor.accent)
          .accessibilityIdentifier("receive-another-audiobook")
        Button("Done") {
          didFinish(false)
          dismiss()
        }
        .buttonStyle(.bordered)
        .tint(PlayerColor.accent)
        .accessibilityIdentifier("finish-computer-receiver")
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

      if MirroringTipPolicy.shouldShow(configuration: launchConfiguration) {
        HStack(alignment: .top, spacing: 16) {
          Image(systemName: "laptopcomputer.and.iphone")
            .font(.title2)
            .foregroundStyle(PlayerColor.accent)
            .frame(width: 42)
          VStack(alignment: .leading, spacing: 5) {
            Text("Using a Mac?").font(.headline).foregroundStyle(PlayerColor.ink)
            Text("For the fastest Mac import, drag books straight into this Bookshelf window with iPhone Mirroring.")
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

      Button("Choose from Files", systemImage: "folder") { chooseFromFiles() }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(PlayerColor.accent)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("choose-from-files-computer-receiver")

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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("computer-receiver-transfer")
    .accessibilityValue(
      Text(verbatim: "receiving:\(completedBytes)-of-\(totalBytes)")
    )
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
    case .paused: "receiver:paused"
    case .preparingDrop: "receiver:preparing-mirrored-drop"
    case .importing: "receiver:importing"
    case .completed(_, let count): "receiver:completed:\(count)"
    case .needsReview: "receiver:needs-review"
    case .failed: "receiver:failed"
    }
  }

  #if E2E
    private var httpExchangeValue: String {
      guard let exchange = controller.httpExchange else { return "http:none" }
      return "http:\(exchange.method):\(exchange.path):status=\(exchange.status)"
    }
  #endif

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
    case .connected, .receiving, .paused, .preparingDrop, .importing: true
    default: false
    }
  }
}

enum MirroringTipPolicy {
  private static let europeanUnionRegions: Set<String> = [
    "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE",
    "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
  ]

  static func shouldShow(
    configuration: E2EComputerReceiverLaunchConfiguration,
    region: String? = Locale.current.region?.identifier
  ) -> Bool {
      switch configuration.mirroringTip {
      case .show: return true
      case .hide: return false
      case .automatic: break
      }
    guard let region else { return false }
    return !europeanUnionRegions.contains(region)
  }
}
