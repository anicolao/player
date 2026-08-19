import Foundation
import UIKit

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
            reset: arguments.contains("-e2e-reset"),
            eventControls: arguments.contains("-e2e-event-controls")
          )
        case "metadata-rich-book":
          return try metadataRichBookEnvironment()
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

    private static func committedCurrentBookEnvironment(
      reset: Bool,
      eventControls: Bool
    ) throws -> PlayerEnvironment {
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
      if eventControls {
        E2EPlaybackEventBridge.shared.reset()
      }
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(base: persisted, seed: seed),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        audioSession: eventControls
          ? E2EAudioSessionController()
          : DisabledAudioSessionController(),
        remoteCommands: eventControls
          ? E2ERemoteCommandController()
          : DisabledRemoteCommandController(),
        clock: FixedPlayerClock(value: date),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func metadataRichBookEnvironment() throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EMetadataRichBook",
        directoryHint: .isDirectory
      )
      try? FileManager.default.removeItem(at: root)

      let bookID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
      let managedPath = "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
      let managedURL = root.appending(path: managedPath)
      try FileManager.default.createDirectory(
        at: managedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("player deterministic metadata fixture".utf8).write(to: managedURL)

      let chapters = [
        Chapter(
          id: "embedded-1",
          title: "First Light",
          startSeconds: 0,
          durationSeconds: 30,
          source: .embedded,
          assetID: assetID
        ),
        Chapter(
          id: "embedded-2",
          title: "Crossing the Bar",
          startSeconds: 30,
          durationSeconds: 45,
          source: .embedded,
          assetID: assetID
        ),
        Chapter(
          id: "embedded-3",
          title: "Safe Harbor",
          startSeconds: 75,
          durationSeconds: 45,
          source: .embedded,
          assetID: assetID
        ),
      ]
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "harbor-at-dawn.m4b",
        managedRelativePath: managedPath,
        checksumSHA256: "e2e-metadata-fixture",
        byteCount: 37,
        durationSeconds: 120,
        container: "M4B"
      )
      let book = Book(
        id: bookID,
        title: "Harbor at Dawn",
        authors: ["Mara Vale"],
        durationSeconds: 120,
        artworkData: metadataRichArtwork(),
        assets: [asset],
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
        narrators: ["Imani Chen"],
        seriesName: "Harbor Signals",
        seriesPosition: "2",
        artworkMediaType: "image/png",
        chapters: chapters
      )
      let ids = (1...4).map {
        UUID(uuidString: String(format: "31000000-0000-0000-0000-%012d", $0))!
      }
      return PlayerEnvironment(
        persistence: InMemoryLibraryStore(
          snapshot: LibrarySnapshot(books: [book], importJobs: [], currentBookID: nil)
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func metadataRichArtwork() -> Data {
      let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
      return renderer.pngData { context in
        UIColor(red: 0.08, green: 0.16, blue: 0.21, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))

        UIColor(red: 0.82, green: 0.34, blue: 0.20, alpha: 1).setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 78, y: 48, width: 84, height: 84))

        context.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.92).cgColor)
        context.cgContext.setLineWidth(9)
        context.cgContext.setLineCap(.round)
        for offset in stride(from: 0, through: 54, by: 18) {
          context.cgContext.move(to: CGPoint(x: 36, y: 158 + offset))
          context.cgContext.addCurve(
            to: CGPoint(x: 204, y: 158 + offset),
            control1: CGPoint(x: 78, y: 134 + offset),
            control2: CGPoint(x: 156, y: 182 + offset)
          )
        }
        context.cgContext.strokePath()
      }
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
