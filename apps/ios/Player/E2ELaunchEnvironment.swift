import Foundation

@MainActor
extension PlayerEnvironment {
  static func launchEnvironment() throws -> PlayerEnvironment {
    #if E2E
      let arguments = ProcessInfo.processInfo.arguments
      if let marker = arguments.firstIndex(of: "-e2e-fixture"), arguments.indices.contains(marker + 1) {
        switch arguments[marker + 1] {
        case "single-audiobook-ready":
          return try singleAudiobookReadyEnvironment()
        case "committed-current-book":
          return try committedCurrentBookEnvironment(
            reset: arguments.contains("-e2e-reset")
          )
        default:
          break
        }
      }
    #endif
    return try production()
  }

  #if E2E
    private static func singleAudiobookReadyEnvironment() throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2ESingleAudiobook",
        directoryHint: .isDirectory
      )
      try? FileManager.default.removeItem(at: root)

      let jobID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
      let proposalID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
      let bookID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
      let stagedRelativePath = "Staging/\(jobID.uuidString.lowercased())/source.m4a"
      let stagedURL = root.appending(path: stagedRelativePath)
      try FileManager.default.createDirectory(
        at: stagedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("player deterministic e2e media".utf8).write(to: stagedURL)

      let asset = AudioAsset(
        id: assetID,
        originalFilename: "lighthouse-signal.m4a",
        managedRelativePath: "",
        checksumSHA256: "6d7366e728dc036ebd67c6464449885939f5eb06f13a361caf3b08a2dc49fc4d",
        byteCount: 30,
        durationSeconds: 1_113,
        container: "M4A"
      )
      let proposal = BookProposal(
        id: proposalID,
        proposedBookID: bookID,
        title: "The Lighthouse Signal",
        authors: ["Mara Vale"],
        durationSeconds: 1_113,
        artworkData: nil,
        asset: asset,
        warnings: []
      )
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let job = ImportJob(
        id: jobID,
        sourceFilename: asset.originalFilename,
        phase: .ready,
        progress: ImportProgress(completed: 30, total: 30),
        stagedRelativePath: stagedRelativePath,
        proposal: proposal,
        committedBookID: nil,
        failure: nil,
        createdAt: date,
        updatedAt: date
      )
      return PlayerEnvironment(
        persistence: InMemoryLibraryStore(
          snapshot: LibrarySnapshot(books: [], importJobs: [job], currentBookID: nil)
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(
          result: .success(
            InspectedAudio(
              title: proposal.title,
              authors: proposal.authors,
              durationSeconds: proposal.durationSeconds,
              artworkData: nil,
              container: "M4A"
            )
          )
        ),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        ids: DeterministicPlayerIDGenerator(
          values: (1...4).map {
            UUID(uuidString: String(format: "11000000-0000-0000-0000-%012d", $0))!
          }
        )
      )
    }

    private static func committedCurrentBookEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = support.appending(
        path: "PlayerE2EPositionRestore",
        directoryHint: .isDirectory
      )
      if reset { try? FileManager.default.removeItem(at: root) }

      let bookID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
      let seedEventID = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
      let managedPath = "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4a"
      let managedURL = root.appending(path: managedPath)
      if !FileManager.default.fileExists(atPath: managedURL.path) {
        try FileManager.default.createDirectory(
          at: managedURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data("player deterministic position fixture".utf8).write(to: managedURL)
      }

      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "midnight-current.m4a",
        managedRelativePath: managedPath,
        checksumSHA256: "e2e-position-fixture",
        byteCount: 37,
        durationSeconds: 120,
        container: "M4A"
      )
      let book = Book(
        id: bookID,
        title: "The Midnight Current",
        authors: ["Mara Vale"],
        durationSeconds: 120,
        artworkData: nil,
        assets: [asset],
        dateAdded: date
      )
      let seedEvent = PositionEvent.acknowledged(
        id: seedEventID,
        bookID: bookID,
        positionMilliseconds: 12_000,
        sequence: 1,
        reason: .pause,
        acknowledgedAt: date,
        previousEventID: nil
      )
      let seed = LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: bookID,
        playbackPosition: PlaybackPosition(
          bookID: bookID,
          positionMilliseconds: seedEvent.positionMilliseconds,
          sequence: seedEvent.sequence,
          sourceEventID: seedEvent.id,
          updatedAt: date
        ),
        positionJournal: [seedEvent]
      )
      let persisted = CodableLibraryStore(fileURL: root.appending(path: "Library.json"))
      let ids = (1...12).map {
        UUID(uuidString: String(format: "21000000-0000-0000-0000-%012d", $0))!
      }
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(base: persisted, seed: seed),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }
  #endif
}

#if E2E
  private actor E2ESeededLibraryStore: LibraryPersisting {
    let base: CodableLibraryStore
    let seed: LibrarySnapshot

    init(base: CodableLibraryStore, seed: LibrarySnapshot) {
      self.base = base
      self.seed = seed
    }

    func load() async throws -> LibrarySnapshot {
      let existing = try await base.load()
      guard existing == .empty else { return existing }
      try await base.save(seed)
      return seed
    }

    func save(_ snapshot: LibrarySnapshot) async throws {
      try await base.save(snapshot)
    }
  }
#endif
