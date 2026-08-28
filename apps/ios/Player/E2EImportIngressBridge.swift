#if E2E
  import Foundation

  @MainActor
  final class E2EImportIngressBridge {
    static let shared = E2EImportIngressBridge()

    private(set) var channel: String?
    private(set) var handoffID: UUID?
    private(set) var expectedJobID: UUID?
    private(set) var isShareReplay = false
    private(set) var queue: AppGroupImportHandoffQueue?
    private(set) var queueRootURL: URL?
    private var sourceURL: URL?
    private var sourceBytes: Data?
    private var documentBaselineURL: URL?
    private var documentSourceReferenceURL: URL?

    var isConfigured: Bool { channel != nil }

    func configureDocument(jobID: UUID, rootURL: URL) {
      channel = "document-open"
      expectedJobID = jobID
      handoffID = nil
      isShareReplay = false
      queue = nil
      queueRootURL = nil
      documentBaselineURL = rootURL.appending(path: "DocumentSourceBaseline.bin")
      documentSourceReferenceURL = rootURL.appending(path: "DocumentSourceReference.txt")
      sourceBytes = documentBaselineURL.flatMap { try? Data(contentsOf: $0) }
      sourceURL = documentSourceReferenceURL
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        .map { URL(filePath: $0) }
    }

    func recordDocumentSource(_ url: URL) {
      guard channel == "document-open", sourceURL == nil else { return }
      sourceURL = url
      sourceBytes = try? Data(contentsOf: url)
      if let sourceBytes { try? sourceBytes.write(to: documentBaselineURL!, options: .atomic) }
      try? url.path.write(to: documentSourceReferenceURL!, atomically: true, encoding: .utf8)
    }

    func configureShare(
      jobID: UUID,
      handoffID: UUID,
      queue: AppGroupImportHandoffQueue,
      queueRootURL: URL,
      sourceURL: URL,
      sourceBytes: Data,
      isReplay: Bool
    ) {
      channel = "share-extension"
      expectedJobID = jobID
      self.handoffID = handoffID
      isShareReplay = isReplay
      self.queue = queue
      self.queueRootURL = queueRootURL
      self.sourceURL = sourceURL
      self.sourceBytes = sourceBytes
    }

    var sourceIsUnchanged: Bool {
      guard let sourceURL, let sourceBytes else { return false }
      return (try? Data(contentsOf: sourceURL)) == sourceBytes
    }

    var pendingRequestCount: Int { requestCount(in: "Pending") }
    var processingRequestCount: Int { requestCount(in: "Processing") }

    private func requestCount(in directory: String) -> Int {
      guard let root = queueRootURL else { return 0 }
      let url = root.appending(path: directory, directoryHint: .isDirectory)
      return (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
    }
  }

  @MainActor
  extension PlayerEnvironment {
    static func importIngressEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let arguments = ProcessInfo.processInfo.arguments
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = support.appending(
        path: "PlayerE2EImportChannels",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

      let channel = argumentValue(after: "-e2e-import-channel", in: arguments)
        ?? "document-open"
      let pause = argumentValue(after: "-e2e-import-pause", in: arguments)
      let jobID: UUID
      if channel == "share-extension" {
        jobID = UUID(uuidString: "70000000-0000-0000-0000-000000000102")!
        try configureShareFixture(root: root, jobID: jobID, reset: reset)
      } else {
        jobID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
        E2EImportIngressBridge.shared.configureDocument(jobID: jobID, rootURL: root)
      }

      let media = FileSystemMediaManager(rootURL: root.appending(path: "PlayerData"))
      let inspected = InspectedAudio(
        title: "Synthetic Import Channel",
        authors: ["Player Test Lab"],
        durationSeconds: 60,
        artworkData: nil,
        container: "M4A"
      )
      let idPrefix = channel == "share-extension" ? 102 : 1
      let ids = (idPrefix..<(idPrefix + 16)).compactMap {
        UUID(uuidString: String(format: "70000000-0000-0000-0000-%012d", $0))
      }
      return PlayerEnvironment(
        persistence: CodableLibraryStore(fileURL: root.appending(path: "Library.json")),
        media: E2EImportPauseMediaManager(base: media, pauseAtAcquire: pause == "acquire"),
        inspector: E2EImportPauseInspector(result: inspected, pauseAtInspect: pause == "inspect"),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func configureShareFixture(root: URL, jobID: UUID, reset: Bool) throws {
      let environment = ProcessInfo.processInfo.environment
      guard
        let payloadBase64 = environment["PLAYER_E2E_SHARE_PAYLOAD_BASE64"],
        let payload = Data(base64Encoded: payloadBase64),
        let envelopeBase64 = environment["PLAYER_E2E_SHARE_ENVELOPE_BASE64"],
        let envelope = Data(base64Encoded: envelopeBase64)
      else { throw PlayerCoreError.fileOperation("The synthetic share handoff is unavailable.") }

      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let handoff = try decoder.decode(ShareImportHandoff.self, from: envelope)
      guard
        let expectedID = argumentValue(after: "-e2e-stage-share-handoff", in: ProcessInfo.processInfo.arguments)
          .flatMap(UUID.init(uuidString:)),
        handoff.id == expectedID,
        handoff.items.count == 1
      else { throw PlayerCoreError.fileOperation("The synthetic share envelope is invalid.") }

      let sourceURL = root.appending(path: "ShareProviderSource.m4a")
      try payload.write(to: sourceURL, options: .atomic)
      let queueContainer = root.appending(path: "AppGroup", directoryHint: .isDirectory)
      let queue = AppGroupImportHandoffQueue(containerURL: queueContainer)
      let queueRoot = queueContainer.appending(
        path: PlayerAppGroup.importQueueDirectoryName,
        directoryHint: .isDirectory
      )
      let pending = queueRoot.appending(path: "Pending", directoryHint: .isDirectory)
      let processing = queueRoot.appending(path: "Processing", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: processing, withIntermediateDirectories: true)
      let request = pending.appending(
        path: handoff.id.uuidString.lowercased(),
        directoryHint: .isDirectory
      )
      if !FileManager.default.fileExists(atPath: request.path) {
        let itemURL = request.appending(path: handoff.items[0].relativePath)
        try FileManager.default.createDirectory(
          at: itemURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try payload.write(to: itemURL, options: .atomic)
        try envelope.write(to: request.appending(path: "handoff.json"), options: .atomic)
      }
      E2EImportIngressBridge.shared.configureShare(
        jobID: jobID,
        handoffID: handoff.id,
        queue: queue,
        queueRootURL: queueRoot,
        sourceURL: sourceURL,
        sourceBytes: payload,
        isReplay: !reset
      )
    }

    private static func argumentValue(after marker: String, in arguments: [String]) -> String? {
      guard let index = arguments.firstIndex(of: marker), arguments.indices.contains(index + 1) else {
        return nil
      }
      return arguments[index + 1]
    }
  }

  private actor E2EImportPauseMediaManager: MediaManaging {
    let base: any MediaManaging
    let pauseAtAcquire: Bool

    init(base: any MediaManaging, pauseAtAcquire: Bool) {
      self.base = base
      self.pauseAtAcquire = pauseAtAcquire
    }

    func stage(sourceURL: URL, jobID: UUID) async throws -> StagedAudio {
      try await base.stage(sourceURL: sourceURL, jobID: jobID)
    }

    func stagedURL(for relativePath: String) async throws -> URL {
      try await base.stagedURL(for: relativePath)
    }

    func commit(_ staged: StagedAudio, bookID: UUID, assetID: UUID) async throws -> ManagedAudio {
      try await base.commit(staged, bookID: bookID, assetID: assetID)
    }

    func rollback(_ managed: ManagedAudio) async throws { try await base.rollback(managed) }

    func managedURL(for relativePath: String) async throws -> URL {
      try await base.managedURL(for: relativePath)
    }

    func discardStaging(for jobID: UUID) async { await base.discardStaging(for: jobID) }

    func acquireSelection(_ selectedURLs: [URL], jobID: UUID) async throws -> [AcquiredAudioFile] {
      if pauseAtAcquire { try await Task.sleep(for: .seconds(3_600)) }
      return try await base.acquireSelection(selectedURLs, jobID: jobID)
    }

    func stageArchive(sourceURL: URL, jobID: UUID) async throws -> StagedAudio {
      try await base.stageArchive(sourceURL: sourceURL, jobID: jobID)
    }

    func zipWorkspace(for jobID: UUID) async throws -> ZipImportWorkspace {
      try await base.zipWorkspace(for: jobID)
    }

    func acquireExtractedAudio(
      _ files: [ZipExtractedFile],
      in workspace: ZipImportWorkspace,
      jobID: UUID
    ) async throws -> [AcquiredAudioFile] {
      try await base.acquireExtractedAudio(files, in: workspace, jobID: jobID)
    }
  }

  private actor E2EImportPauseInspector: AudioInspecting {
    let result: InspectedAudio
    let pauseAtInspect: Bool

    init(result: InspectedAudio, pauseAtInspect: Bool) {
      self.result = result
      self.pauseAtInspect = pauseAtInspect
    }

    func inspect(url: URL) async throws -> InspectedAudio {
      if pauseAtInspect { try await Task.sleep(for: .seconds(3_600)) }
      return result
    }
  }
#endif
