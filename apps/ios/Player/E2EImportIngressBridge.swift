#if E2E
  import Foundation

  private func suspendImportPhaseUntilCancellation() async throws {
    let (events, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    for await _ in events {}
    try Task.checkCancellation()
  }

  struct E2EImportIngressArguments: Equatable {
    enum Channel: String, CaseIterable {
      case documentOpen = "document-open"
      case shareExtension = "share-extension"
    }

    enum Pause: String, CaseIterable {
      case acquire
      case inspect
    }

    static let channelArgument = "-e2e-import-channel"
    static let pauseArgument = "-e2e-import-pause"
    static let shareHandoffArgument = "-e2e-stage-share-handoff"

    let channel: Channel
    let pause: Pause?
    let shareHandoffID: UUID?

    static func parse(arguments: [String]) throws -> E2EImportIngressArguments {
      let channelValue = try requiredValue(after: channelArgument, in: arguments)
      guard let channel = Channel(rawValue: channelValue) else {
        throw PlayerCoreError.fileOperation("Invalid Import Ingress E2E channel: \(channelValue)")
      }

      let pauseValue = try optionalValue(after: pauseArgument, in: arguments)
      let pause: Pause?
      if let pauseValue {
        guard let parsed = Pause(rawValue: pauseValue) else {
          throw PlayerCoreError.fileOperation("Invalid Import Ingress E2E pause: \(pauseValue)")
        }
        pause = parsed
      } else {
        pause = nil
      }

      let handoffValue = try optionalValue(after: shareHandoffArgument, in: arguments)
      let handoffID: UUID?
      if let handoffValue {
        guard let parsed = UUID(uuidString: handoffValue) else {
          throw PlayerCoreError.fileOperation(
            "Invalid Import Ingress E2E share handoff: \(handoffValue)"
          )
        }
        handoffID = parsed
      } else {
        handoffID = nil
      }

      switch channel {
      case .documentOpen:
        guard handoffID == nil else {
          throw PlayerCoreError.fileOperation(
            "A document-open Import Ingress E2E fixture cannot stage a share handoff."
          )
        }
      case .shareExtension:
        guard pause == nil, handoffID != nil else {
          throw PlayerCoreError.fileOperation(
            "A share-extension Import Ingress E2E fixture requires one handoff and no pause."
          )
        }
      }

      return E2EImportIngressArguments(
        channel: channel,
        pause: pause,
        shareHandoffID: handoffID
      )
    }

    private static func requiredValue(after marker: String, in arguments: [String]) throws -> String {
      let markers = arguments.indices.filter { arguments[$0] == marker }
      guard markers.count == 1 else {
        let reason = markers.isEmpty ? "Missing" : "Duplicate"
        throw PlayerCoreError.fileOperation("\(reason) Import Ingress E2E option: \(marker)")
      }
      return try value(after: marker, at: markers[0], in: arguments)
    }

    private static func optionalValue(after marker: String, in arguments: [String]) throws -> String? {
      let markers = arguments.indices.filter { arguments[$0] == marker }
      guard markers.count <= 1 else {
        throw PlayerCoreError.fileOperation("Duplicate Import Ingress E2E option: \(marker)")
      }
      guard let index = markers.first else { return nil }
      return try value(after: marker, at: index, in: arguments)
    }

    private static func value(after marker: String, at index: Int, in arguments: [String]) throws -> String {
      guard arguments.indices.contains(index + 1) else {
        throw PlayerCoreError.fileOperation("Missing Import Ingress E2E value for: \(marker)")
      }
      let value = arguments[index + 1]
      guard !value.isEmpty, !value.hasPrefix("-") else {
        throw PlayerCoreError.fileOperation("Invalid Import Ingress E2E value for: \(marker)")
      }
      return value
    }
  }

  struct E2EShareFixturePayload {
    let payload: Data
    let envelope: Data
    let handoff: ShareImportHandoff

    static func parse(
      environment: [String: String],
      expectedHandoffID: UUID
    ) throws -> E2EShareFixturePayload {
      guard
        let payloadBase64 = environment["PLAYER_E2E_SHARE_PAYLOAD_BASE64"],
        let payload = Data(base64Encoded: payloadBase64),
        let envelopeBase64 = environment["PLAYER_E2E_SHARE_ENVELOPE_BASE64"],
        let envelope = Data(base64Encoded: envelopeBase64)
      else { throw PlayerCoreError.fileOperation("The synthetic share handoff is unavailable.") }

      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let handoff = try decoder.decode(ShareImportHandoff.self, from: envelope)
      guard handoff.id == expectedHandoffID, handoff.items.count == 1 else {
        throw PlayerCoreError.fileOperation("The synthetic share envelope is invalid.")
      }
      return E2EShareFixturePayload(
        payload: payload,
        envelope: envelope,
        handoff: handoff
      )
    }
  }

  enum E2EImportIngressIDSequence {
    private static let prefix = "70000000-0000-0000-0000-"

    static func values(
      channel: E2EImportIngressArguments.Channel,
      reset: Bool,
      libraryURL: URL,
      count: Int = 16
    ) throws -> [UUID] {
      let minimumSuffix = channel == .shareExtension ? 102 : 1
      let firstSuffix = reset
        ? minimumSuffix
        : try nextDurableSuffix(in: libraryURL, minimum: minimumSuffix)
      return (firstSuffix..<(firstSuffix + count)).compactMap {
        UUID(uuidString: prefix + String(format: "%012d", $0))
      }
    }

    static func nextDurableSuffix(in libraryURL: URL, minimum: Int) throws -> Int {
      guard FileManager.default.fileExists(atPath: libraryURL.path) else { return minimum }
      let data = try Data(contentsOf: libraryURL)
      guard
        let encoded = String(data: data, encoding: .utf8),
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        root["library"] is [String: Any]
      else {
        throw PlayerCoreError.fileOperation(
          "The persisted Import Ingress E2E library is invalid."
        )
      }
      let expression = try NSRegularExpression(
        pattern: "70000000-0000-0000-0000-([0-9]{12})",
        options: [.caseInsensitive]
      )
      let range = NSRange(encoded.startIndex..<encoded.endIndex, in: encoded)
      let suffixes = expression.matches(in: encoded, range: range).compactMap { match -> Int? in
        guard let suffixRange = Range(match.range(at: 1), in: encoded) else { return nil }
        return Int(encoded[suffixRange])
      }
      return max(minimum, (suffixes.max() ?? (minimum - 1)) + 1)
    }
  }

  enum E2EImportIngressDurableLibrary {
    private struct Envelope: Decodable {
      let library: LibrarySnapshot
    }

    static func loadIfPresent(at url: URL) throws -> LibrarySnapshot? {
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      do {
        return try JSONDecoder.playerDecoder.decode(
          Envelope.self,
          from: Data(contentsOf: url)
        ).library
      } catch {
        throw PlayerCoreError.fileOperation(
          "The persisted Import Ingress E2E library could not be observed."
        )
      }
    }
  }

  enum E2EImportIngressSourceReference {
    // The system bookmark broker is independently covered by production
    // media-manager tests and remains a physical ingress acceptance gate. This
    // journey needs an exact, restartable reference without importing the
    // broker's hosted-simulator I/O latency into its two-second app contract.
    static let bookmarkAccess = ImportSourceBookmarkAccess(
      createBookmark: { url in Data(url.absoluteString.utf8) },
      resolveBookmark: { data in
        guard
          let encoded = String(data: data, encoding: .utf8),
          let url = URL(string: encoded),
          url.isFileURL
        else {
          throw PlayerCoreError.fileOperation(
            "The Import Ingress E2E source reference is invalid."
          )
        }
        return ResolvedImportSourceBookmark(url: url, isStale: false)
      }
    )
  }

  struct E2EShareIngressSnapshot: Equatable {
    let jobIDs: Set<UUID>
    let receipt: ShareImportReceipt?

    static let empty = E2EShareIngressSnapshot(jobIDs: [], receipt: nil)

    static func capture(
      library: LibrarySnapshot,
      handoffID: UUID
    ) -> E2EShareIngressSnapshot? {
      let receipts = library.shareImportReceipts.filter { $0.handoffID == handoffID }
      guard receipts.count <= 1 else { return nil }
      let jobIDs = Set(library.importJobs.map(\.id))
      guard let receipt = receipts.first else {
        return E2EShareIngressSnapshot(jobIDs: jobIDs, receipt: nil)
      }
      guard jobIDs.contains(receipt.jobID) else { return nil }
      return E2EShareIngressSnapshot(jobIDs: jobIDs, receipt: receipt)
    }
  }

  struct E2EShareIngressEvidence: Equatable {
    enum Outcome: String, Equatable {
      case consumed
      case deduplicated
      case unverified
    }

    let outcome: Outcome
    let jobID: UUID?

    static func evaluate(
      baseline: E2EShareIngressSnapshot,
      current: E2EShareIngressSnapshot?,
      expectedFingerprint: String,
      initialPendingCount: Int,
      initialProcessingCount: Int,
      processingRevision: Int,
      pendingCount: Int,
      processingCount: Int
    ) -> E2EShareIngressEvidence {
      guard
        initialPendingCount + initialProcessingCount == 1,
        processingRevision > 0,
        pendingCount == 0,
        processingCount == 0,
        let current,
        let receipt = current.receipt,
        receipt.payloadFingerprint == expectedFingerprint
      else { return E2EShareIngressEvidence(outcome: .unverified, jobID: nil) }

      if let originalReceipt = baseline.receipt {
        guard
          originalReceipt.payloadFingerprint == expectedFingerprint,
          receipt == originalReceipt,
          current.jobIDs == baseline.jobIDs
        else { return E2EShareIngressEvidence(outcome: .unverified, jobID: nil) }
        return E2EShareIngressEvidence(outcome: .deduplicated, jobID: receipt.jobID)
      }

      var expectedJobIDs = baseline.jobIDs
      expectedJobIDs.insert(receipt.jobID)
      guard current.jobIDs == expectedJobIDs else {
        return E2EShareIngressEvidence(outcome: .unverified, jobID: nil)
      }
      return E2EShareIngressEvidence(outcome: .consumed, jobID: receipt.jobID)
    }
  }

  @MainActor
  final class E2EImportIngressBridge {
    static let shared = E2EImportIngressBridge()

    private(set) var channel: String?
    private(set) var handoffID: UUID?
    private(set) var expectedJobID: UUID?
    private(set) var queue: AppGroupImportHandoffQueue?
    private(set) var queueRootURL: URL?
    private var shareBaseline = E2EShareIngressSnapshot.empty
    private var sharePayloadFingerprint: String?
    private var shareLibraryURL: URL?
    private var initialPendingRequestCount = 0
    private var initialProcessingRequestCount = 0
    private var sourceURL: URL?
    private var sourceBytes: Data?
    private var documentBaselineURL: URL?
    private var documentSourceReferenceURL: URL?

    var isConfigured: Bool { channel != nil }

    func configureDocument(jobID: UUID, rootURL: URL) {
      channel = "document-open"
      expectedJobID = jobID
      handoffID = nil
      queue = nil
      queueRootURL = nil
      shareBaseline = .empty
      sharePayloadFingerprint = nil
      shareLibraryURL = nil
      initialPendingRequestCount = 0
      initialProcessingRequestCount = 0
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
      payloadFingerprint: String,
      libraryURL: URL,
      baseline: E2EShareIngressSnapshot
    ) {
      channel = "share-extension"
      expectedJobID = baseline.receipt?.jobID ?? jobID
      self.handoffID = handoffID
      self.queue = queue
      self.queueRootURL = queueRootURL
      self.sourceURL = sourceURL
      self.sourceBytes = sourceBytes
      shareBaseline = baseline
      sharePayloadFingerprint = payloadFingerprint
      shareLibraryURL = libraryURL
      initialPendingRequestCount = pendingRequestCount
      initialProcessingRequestCount = processingRequestCount
    }

    var sourceIsUnchanged: Bool {
      guard let sourceURL, let sourceBytes else { return false }
      return (try? Data(contentsOf: sourceURL)) == sourceBytes
    }

    var pendingRequestCount: Int { requestCount(in: "Pending") }
    var processingRequestCount: Int { requestCount(in: "Processing") }

    func shareEvidence(processingRevision: Int) -> E2EShareIngressEvidence {
      guard
        let handoffID,
        let sharePayloadFingerprint,
        let shareLibraryURL,
        let durableLibrary = try? E2EImportIngressDurableLibrary.loadIfPresent(at: shareLibraryURL)
      else { return E2EShareIngressEvidence(outcome: .unverified, jobID: nil) }
      return E2EShareIngressEvidence.evaluate(
        baseline: shareBaseline,
        current: E2EShareIngressSnapshot.capture(
          library: durableLibrary,
          handoffID: handoffID
        ),
        expectedFingerprint: sharePayloadFingerprint,
        initialPendingCount: initialPendingRequestCount,
        initialProcessingCount: initialProcessingRequestCount,
        processingRevision: processingRevision,
        pendingCount: pendingRequestCount,
        processingCount: processingRequestCount
      )
    }

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
      let options = try E2EImportIngressArguments.parse(arguments: arguments)
      let shareFixture: E2EShareFixturePayload?
      if options.channel == .shareExtension {
        guard let expectedHandoffID = options.shareHandoffID else {
          throw PlayerCoreError.fileOperation(
            "The share-extension Import Ingress E2E fixture has no handoff."
          )
        }
        shareFixture = try E2EShareFixturePayload.parse(
          environment: ProcessInfo.processInfo.environment,
          expectedHandoffID: expectedHandoffID
        )
      } else {
        shareFixture = nil
      }
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

      let libraryURL = root.appending(path: "Library.json")
      let durableLibrary = try E2EImportIngressDurableLibrary.loadIfPresent(at: libraryURL)
      let ids = try E2EImportIngressIDSequence.values(
        channel: options.channel,
        reset: reset,
        libraryURL: libraryURL
      )
      guard let jobID = ids.first else {
        throw PlayerCoreError.fileOperation("The Import Ingress E2E ID stream is empty.")
      }
      if options.channel == .shareExtension {
        guard let shareFixture else {
          throw PlayerCoreError.fileOperation("The synthetic share fixture was not validated.")
        }
        try configureShareFixture(
          root: root,
          jobID: jobID,
          fixture: shareFixture,
          durableLibrary: durableLibrary
        )
      } else {
        let resumedDocumentJobs = durableLibrary?.importJobs.filter {
          $0.queueCheckpoint?.entryPoint == .documentOpen
        } ?? []
        guard resumedDocumentJobs.count <= 1 else {
          throw PlayerCoreError.fileOperation(
            "The persisted document ingress fixture has ambiguous resumed jobs."
          )
        }
        E2EImportIngressBridge.shared.configureDocument(
          jobID: resumedDocumentJobs.first?.id ?? jobID,
          rootURL: root
        )
      }

      let media = FileSystemMediaManager(
        rootURL: root.appending(path: "PlayerData"),
        bookmarkAccess: E2EImportIngressSourceReference.bookmarkAccess
      )
      let inspected = InspectedAudio(
        title: "Synthetic Import Channel",
        authors: ["Player Test Lab"],
        durationSeconds: 60,
        artworkData: nil,
        container: "M4A"
      )
      return PlayerEnvironment(
        persistence: CodableLibraryStore(fileURL: libraryURL),
        media: E2EImportPauseMediaManager(base: media, pauseAtAcquire: options.pause == .acquire),
        inspector: E2EImportPauseInspector(result: inspected, pauseAtInspect: options.pause == .inspect),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func configureShareFixture(
      root: URL,
      jobID: UUID,
      fixture: E2EShareFixturePayload,
      durableLibrary: LibrarySnapshot?
    ) throws {
      let payload = fixture.payload
      let envelope = fixture.envelope
      let handoff = fixture.handoff

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
      let processingRequest = processing.appending(
        path: handoff.id.uuidString.lowercased(),
        directoryHint: .isDirectory
      )
      if !FileManager.default.fileExists(atPath: request.path),
        !FileManager.default.fileExists(atPath: processingRequest.path)
      {
        let itemURL = request.appending(path: handoff.items[0].relativePath)
        try FileManager.default.createDirectory(
          at: itemURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try payload.write(to: itemURL, options: .atomic)
        try envelope.write(to: request.appending(path: "handoff.json"), options: .atomic)
      }
      guard let baseline = E2EShareIngressSnapshot.capture(
        library: durableLibrary ?? .empty,
        handoffID: handoff.id
      ) else {
        throw PlayerCoreError.fileOperation(
          "The persisted share ingress evidence is internally inconsistent."
        )
      }
      E2EImportIngressBridge.shared.configureShare(
        jobID: jobID,
        handoffID: handoff.id,
        queue: queue,
        queueRootURL: queueRoot,
        sourceURL: sourceURL,
        sourceBytes: payload,
        payloadFingerprint: handoff.payloadFingerprint,
        libraryURL: root.appending(path: "Library.json"),
        baseline: baseline
      )
    }

  }

  actor E2EImportPauseMediaManager: MediaManaging {
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

    // This wrapper changes only the acquisition suspension point. Import URLs
    // must still pass through the concrete media manager so document-open and
    // provider URLs retain their security-scoped lease and durable bookmark
    // behavior. Falling through to MediaManaging's convenience defaults makes
    // readability depend on transient simulator sandbox state.
    func referenceImportSources(
      _ selectedURLs: [URL],
      displayNames: [String]?
    ) async throws -> [DurableImportSource] {
      try await base.referenceImportSources(selectedURLs, displayNames: displayNames)
    }

    func referenceApplicationOwnedImportSources(
      _ selectedURLs: [URL],
      displayNames: [String]?
    ) async throws -> [DurableImportSource] {
      try await base.referenceApplicationOwnedImportSources(
        selectedURLs,
        displayNames: displayNames
      )
    }

    func resolveImportSources(_ sources: [DurableImportSource]) async throws -> [URL] {
      try await base.resolveImportSources(sources)
    }

    func acquireSelection(_ selectedURLs: [URL], jobID: UUID) async throws -> [AcquiredAudioFile] {
      if pauseAtAcquire { try await suspendImportPhaseUntilCancellation() }
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
      if pauseAtInspect { try await suspendImportPhaseUntilCancellation() }
      return result
    }
  }
#endif
