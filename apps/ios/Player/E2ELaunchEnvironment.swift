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
        ids: DeterministicPlayerIDGenerator(values: [])
      )
    }
  #endif
}
