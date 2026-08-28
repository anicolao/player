import CryptoKit
import Foundation
import UIKit

#if E2E
  func resetE2EFixtureRoot(_ root: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: root.path) {
      try fileManager.removeItem(at: root)
    }
    guard !fileManager.fileExists(atPath: root.path) else {
      throw PlayerCoreError.fileOperation("Could not reset E2E fixture root: \(root.lastPathComponent)")
    }
  }

  enum E2EMetadataRichBookNamespace {
    static let argument = "-e2e-metadata-rich-namespace"
    static let defaultValue = "default"

    static func parse(arguments: [String]) throws -> String {
      let markers = arguments.indices.filter { arguments[$0] == argument }
      guard markers.count <= 1 else {
        throw PlayerCoreError.fileOperation("Duplicate Metadata Rich Book E2E namespace.")
      }
      guard let marker = markers.first else { return defaultValue }
      guard arguments.indices.contains(marker + 1) else {
        throw PlayerCoreError.fileOperation("Missing Metadata Rich Book E2E namespace.")
      }
      let namespace = arguments[marker + 1]
      let bytes = Array(namespace.utf8)
      let isLowercaseLetterOrDigit: (UInt8) -> Bool = {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
          || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
      }
      guard (1...64).contains(bytes.count),
        bytes.first.map(isLowercaseLetterOrDigit) == true,
        bytes.last.map(isLowercaseLetterOrDigit) == true,
        bytes.allSatisfy({ isLowercaseLetterOrDigit($0) || $0 == UInt8(ascii: "-") })
      else {
        throw PlayerCoreError.fileOperation("Invalid Metadata Rich Book E2E namespace.")
      }
      return namespace
    }

    static func root(in support: URL, namespace: String) -> URL {
      let suffix = namespace == defaultValue ? "" : "-\(namespace)"
      return support.appending(
        path: "PlayerE2EMetadataRichBook\(suffix)",
        directoryHint: .isDirectory
      )
    }
  }

  enum E2ESleepTimerNamespace: String, CaseIterable {
    static let argument = "-e2e-sleep-timer-namespace"

    case preset10 = "preset-10"
    case preset15 = "preset-15"
    case preset30 = "preset-30"
    case preset45 = "preset-45"
    case preset60 = "preset-60"
    case custom25 = "custom-25"
    case endChapter = "end-chapter"
    case endTrack = "end-track"
    case replaceCancel = "replace-cancel"
    case persistent

    static func parseRequired(arguments: [String]) throws -> E2ESleepTimerNamespace {
      let markers = arguments.indices.filter { arguments[$0] == argument }
      guard markers.count == 1 else {
        let reason = markers.isEmpty ? "Missing" : "Duplicate"
        throw PlayerCoreError.fileOperation("\(reason) Sleep Timer E2E namespace.")
      }
      let marker = markers[0]
      guard arguments.indices.contains(marker + 1) else {
        throw PlayerCoreError.fileOperation("Missing Sleep Timer E2E namespace value.")
      }
      let value = arguments[marker + 1]
      guard !value.isEmpty, !value.hasPrefix("-"), let namespace = Self(rawValue: value) else {
        throw PlayerCoreError.fileOperation("Invalid Sleep Timer E2E namespace: \(value)")
      }
      return namespace
    }
  }

  enum E2ESmartRewindScenario: String, CaseIterable {
    static let argument = "-e2e-smart-rewind-scenario"

    case belowThreshold = "below-threshold"
    case short
    case medium
    case long
    case maximum
    case disabled
    case chapterClamp = "chapter-clamp"

    static func parseRequired(arguments: [String]) throws -> E2ESmartRewindScenario {
      let markers = arguments.indices.filter { arguments[$0] == argument }
      guard markers.count == 1 else {
        let reason = markers.isEmpty ? "Missing" : "Duplicate"
        throw PlayerCoreError.fileOperation("\(reason) Smart Rewind E2E scenario.")
      }
      let marker = markers[0]
      guard arguments.indices.contains(marker + 1) else {
        throw PlayerCoreError.fileOperation("Missing Smart Rewind E2E scenario value.")
      }
      let value = arguments[marker + 1]
      guard !value.isEmpty, !value.hasPrefix("-"), let scenario = Self(rawValue: value) else {
        throw PlayerCoreError.fileOperation("Invalid Smart Rewind E2E scenario: \(value)")
      }
      return scenario
    }
  }
#endif

@MainActor
extension PlayerEnvironment {
  static func launchEnvironment() throws -> PlayerEnvironment {
    #if E2E
      let arguments = ProcessInfo.processInfo.arguments
      if let marker = arguments.firstIndex(of: "-e2e-fixture"), arguments.indices.contains(marker + 1) {
        switch arguments[marker + 1] {
        case "empty-library":
          return try emptyLibraryEnvironment(reset: arguments.contains("-e2e-reset"))
        case "single-audiobook-ready":
          return try singleAudiobookReadyEnvironment()
        case "committed-current-book":
          return try committedCurrentBookEnvironment(
            reset: arguments.contains("-e2e-reset"),
            eventControls: arguments.contains("-e2e-event-controls")
          )
        case "monetization-exhausted":
          return try monetizationExhaustedEnvironment()
        case "zero-duration-current-book":
          return try zeroDurationCurrentBookEnvironment()
        case "metadata-rich-book":
          return try metadataRichBookEnvironment(
            reset: arguments.contains("-e2e-reset"),
            namespace: E2EMetadataRichBookNamespace.parse(arguments: arguments)
          )
        case "messy-multifile-unicode":
          return try messyMultifileEnvironment(reset: arguments.contains("-e2e-reset"))
        case "safe-zip-import":
          return try safeZipEnvironment(reset: arguments.contains("-e2e-reset"))
        case "import-recovery-storage":
          return try E2EImportRecoveryEnvironment.make(
            reset: arguments.contains("-e2e-reset"),
            scenario: argumentValue(after: "-e2e-recovery-scenario", in: arguments) ?? "mixed"
          )
        case "synthetic-import-channels":
          return try importIngressEnvironment(reset: arguments.contains("-e2e-reset"))
        case "synthetic-metadata-repair":
          return try metadataRepairEnvironment()
        case "synthetic-populated-library":
          return try populatedLibraryEnvironment(reset: arguments.contains("-e2e-reset"))
        case "smart-rewind":
          return try smartRewindEnvironment(
            reset: arguments.contains("-e2e-reset"),
            scenario: E2ESmartRewindScenario.parseRequired(arguments: arguments).rawValue
          )
        case "sleep-timer":
          return try sleepTimerEnvironment(
            reset: arguments.contains("-e2e-reset"),
            namespace: E2ESleepTimerNamespace.parseRequired(arguments: arguments).rawValue
          )
        case "bookmarks":
          return try bookmarksEnvironment(reset: arguments.contains("-e2e-reset"))
        case "portable-backup":
          return try portableBackupEnvironment()
        case "offline-recovery":
          return try offlineRecoveryEnvironment(reset: arguments.contains("-e2e-reset"))
        default:
          throw PlayerCoreError.fileOperation(
            "Unknown deterministic E2E fixture: \(arguments[marker + 1])"
          )
        }
      }
      if arguments.contains("-e2e") {
        throw PlayerCoreError.fileOperation("An E2E launch requires an explicit fixture.")
      }
    #endif
    return try production()
  }

  #if E2E
    private static func emptyLibraryEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EEmptyLibrary",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      return PlayerEnvironment(
        persistence: InMemoryLibraryStore(snapshot: .empty),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(
          values: (1...32).map {
            UUID(uuidString: String(format: "01000000-0000-0000-0000-%012d", $0))!
          }
        )
      )
    }

    private static func singleAudiobookReadyEnvironment() throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2ESingleAudiobook",
        directoryHint: .isDirectory
      )
      try resetE2EFixtureRoot(root)

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
      eventControls: Bool,
      monetization: (any MonetizationManaging)? = nil
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
      if reset { try resetE2EFixtureRoot(root) }

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
      let playbackEventBridge = E2EPlaybackEventBridge.shared
      if eventControls { playbackEventBridge.reset() }
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(base: persisted, seed: seed),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        audioSession: eventControls
          ? AVAudioSessionController(
            platform: playbackEventBridge,
            notificationSource: playbackEventBridge
          )
          : DisabledAudioSessionController(),
        remoteCommands: eventControls
          ? MPRemoteCommandController(source: playbackEventBridge)
          : DisabledRemoteCommandController(),
        clock: FixedPlayerClock(value: date),
        ids: DeterministicPlayerIDGenerator(values: ids),
        monetization: monetization ?? DisabledMonetizationManager()
      )
    }

    private static func monetizationExhaustedEnvironment() throws -> PlayerEnvironment {
      var snapshot = MonetizationSnapshot.included
      snapshot.consumedPlaybackSeconds = MonetizationSnapshot.includedPlaybackSeconds
      snapshot.displayPrice = "$9.99"
      return try committedCurrentBookEnvironment(
        reset: true,
        eventControls: false,
        monetization: DeterministicMonetizationManager(snapshot: snapshot)
      )
    }

    private static func zeroDurationCurrentBookEnvironment() throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EZeroDuration",
        directoryHint: .isDirectory
      )
      try resetE2EFixtureRoot(root)
      let bookID = UUID(uuidString: "22000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "22000000-0000-0000-0000-000000000002")!
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "atmosphere.m4b",
        managedRelativePath: "Media/atmosphere.m4b",
        checksumSHA256: "e2e-zero-duration-fixture",
        byteCount: 1,
        durationSeconds: 0,
        container: "M4B"
      )
      let book = Book(
        id: bookID,
        title: "Atmosphere",
        authors: ["Taylor Jenkins Reid"],
        durationSeconds: 0,
        artworkData: nil,
        assets: [asset],
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
      )
      let managedURL = root.appending(path: asset.managedRelativePath)
      try FileManager.default.createDirectory(
        at: managedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data([0]).write(to: managedURL)
      return PlayerEnvironment(
        persistence: InMemoryLibraryStore(
          snapshot: LibrarySnapshot(books: [book], importJobs: [], currentBookID: bookID)
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: [])
      )
    }

    private static func sleepTimerEnvironment(
      reset: Bool,
      namespace: String
    ) throws -> PlayerEnvironment {
      guard namespace.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
        throw PlayerCoreError.fileOperation("Invalid Sleep Timer E2E namespace.")
      }
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = support.appending(
        path: "PlayerE2ESleepTimer-\(namespace)",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }

      let bookID = UUID(uuidString: "52000000-0000-0000-0000-000000000001")!
      let firstAssetID = UUID(uuidString: "52000000-0000-0000-0000-000000000002")!
      let secondAssetID = UUID(uuidString: "52000000-0000-0000-0000-000000000003")!
      let pauseEventID = UUID(uuidString: "52000000-0000-0000-0000-000000000004")!
      let managedAssets = [
        (
          firstAssetID,
          "quiet-hours-part-01.m4b",
          "Media/\(bookID.uuidString.lowercased())/\(firstAssetID.uuidString.lowercased()).m4b",
          0.0
        ),
        (
          secondAssetID,
          "quiet-hours-part-02.m4b",
          "Media/\(bookID.uuidString.lowercased())/\(secondAssetID.uuidString.lowercased()).m4b",
          90.0
        ),
      ]
      for (_, filename, path, _) in managedAssets {
        let url = root.appending(path: path)
        if !FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try Data("player deterministic sleep timer fixture \(filename)".utf8)
            .write(to: url)
        }
      }

      let date = Date(timeIntervalSince1970: 1_700_020_000)
      let assets = managedAssets.enumerated().map { index, item in
        AudioAsset(
          id: item.0,
          originalFilename: item.1,
          managedRelativePath: item.2,
          checksumSHA256: "e2e-sleep-timer-part-\(index + 1)",
          byteCount: 50,
          durationSeconds: 90,
          container: "M4B",
          timelineStartSeconds: item.3,
          discNumber: 1,
          trackNumber: index + 1,
          importOrder: index
        )
      }
      let book = Book(
        id: bookID,
        title: "The Quiet Hours",
        authors: ["Mara Vale"],
        durationSeconds: 180,
        artworkData: nil,
        assets: assets,
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
        chapters: [
          Chapter(
            id: "sleep-1", title: "Settling In", startSeconds: 0,
            durationSeconds: 60, source: .embedded, assetID: firstAssetID
          ),
          Chapter(
            id: "sleep-2", title: "Drifting", startSeconds: 60,
            durationSeconds: 60, source: .embedded, assetID: firstAssetID
          ),
          Chapter(
            id: "sleep-3", title: "Morning Light", startSeconds: 120,
            durationSeconds: 60, source: .embedded, assetID: secondAssetID
          ),
        ]
      )
      let pause = PositionEvent.acknowledged(
        id: pauseEventID,
        bookID: bookID,
        positionMilliseconds: 70_000,
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
          positionMilliseconds: 70_000,
          sequence: 1,
          sourceEventID: pause.id,
          updatedAt: date
        ),
        positionJournal: [pause]
      )
      let libraryURL = root.appending(path: "Library.json")
      let firstAvailableSuffix = nextSleepTimerIDSuffix(in: libraryURL)
      let ids = (firstAvailableSuffix...(firstAvailableSuffix + 79)).map {
        UUID(uuidString: String(format: "52000000-0000-0000-0000-%012d", $0))!
      }
      let clock = E2EMutablePlayerClock(value: date)
      E2ESleepTimerBridge.shared.configure(clock: clock)
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: libraryURL),
          seed: seed
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: clock,
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func nextSleepTimerIDSuffix(in libraryURL: URL) -> Int {
      guard
        let data = try? Data(contentsOf: libraryURL),
        let encoded = String(data: data, encoding: .utf8),
        let expression = try? NSRegularExpression(
          pattern: "52000000-0000-0000-0000-([0-9]{12})",
          options: [.caseInsensitive]
        )
      else { return 101 }
      let range = NSRange(encoded.startIndex..<encoded.endIndex, in: encoded)
      let suffixes = expression.matches(in: encoded, range: range).compactMap { match -> Int? in
        guard let suffixRange = Range(match.range(at: 1), in: encoded) else { return nil }
        return Int(encoded[suffixRange])
      }
      return max(101, (suffixes.max() ?? 100) + 1)
    }

    private static func bookmarksEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = support.appending(
        path: "PlayerE2EBookmarks",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }

      let bookID = UUID(uuidString: "53000000-0000-0000-0000-000000000001")!
      let firstAssetID = UUID(uuidString: "53000000-0000-0000-0000-000000000002")!
      let secondAssetID = UUID(uuidString: "53000000-0000-0000-0000-000000000003")!
      let pauseEventID = UUID(uuidString: "53000000-0000-0000-0000-000000000004")!
      let assetDetails = [
        (
          firstAssetID,
          "mapped-signals-part-01.m4b",
          "Media/\(bookID.uuidString.lowercased())/\(firstAssetID.uuidString.lowercased()).m4b",
          0.0
        ),
        (
          secondAssetID,
          "mapped-signals-part-02.m4b",
          "Media/\(bookID.uuidString.lowercased())/\(secondAssetID.uuidString.lowercased()).m4b",
          60.0
        ),
      ]
      for (_, filename, relativePath, _) in assetDetails {
        let url = root.appending(path: relativePath)
        if !FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try Data("player deterministic bookmark fixture \(filename)".utf8).write(to: url)
        }
      }

      let date = Date(timeIntervalSince1970: 1_700_030_000)
      let assets = assetDetails.enumerated().map { index, details in
        AudioAsset(
          id: details.0,
          originalFilename: details.1,
          managedRelativePath: details.2,
          checksumSHA256: "e2e-bookmark-part-\(index + 1)",
          byteCount: 48,
          durationSeconds: 60,
          container: "M4B",
          timelineStartSeconds: details.3,
          discNumber: 1,
          trackNumber: index + 1,
          importOrder: index
        )
      }
      let book = Book(
        id: bookID,
        title: "Mapped Signals",
        authors: ["Mara Vale"],
        durationSeconds: 120,
        artworkData: nil,
        assets: assets,
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
        chapters: [
          Chapter(
            id: "opening", title: "Opening Signal", startSeconds: 0,
            durationSeconds: 60, source: .embedded, assetID: firstAssetID
          ),
          Chapter(
            id: "crossing", title: "The Crossing", startSeconds: 60,
            durationSeconds: 60, source: .embedded, assetID: secondAssetID
          ),
        ]
      )
      let pause = PositionEvent.acknowledged(
        id: pauseEventID,
        bookID: bookID,
        positionMilliseconds: 60_000,
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
          positionMilliseconds: 60_000,
          sequence: 1,
          sourceEventID: pause.id,
          updatedAt: date
        ),
        positionJournal: [pause]
      )
      let libraryURL = root.appending(path: "Library.json")
      let firstAvailableSuffix = nextBookmarkIDSuffix(in: libraryURL)
      let ids = (firstAvailableSuffix...(firstAvailableSuffix + 39)).map {
        UUID(uuidString: String(format: "53000000-0000-0000-0000-%012d", $0))!
      }
      let clock = E2EBookmarkClock(value: date)
      E2EBookmarkBridge.shared.configure(clock: clock)
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: libraryURL),
          seed: seed
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: clock,
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func nextBookmarkIDSuffix(in libraryURL: URL) -> Int {
      guard
        let data = try? Data(contentsOf: libraryURL),
        let encoded = String(data: data, encoding: .utf8),
        let expression = try? NSRegularExpression(
          pattern: "53000000-0000-0000-0000-([0-9]{12})",
          options: [.caseInsensitive]
        )
      else { return 101 }
      let range = NSRange(encoded.startIndex..<encoded.endIndex, in: encoded)
      let suffixes = expression.matches(in: encoded, range: range).compactMap { match -> Int? in
        guard let suffixRange = Range(match.range(at: 1), in: encoded) else { return nil }
        return Int(encoded[suffixRange])
      }
      return max(101, (suffixes.max() ?? 100) + 1)
    }

    private static func smartRewindEnvironment(
      reset: Bool,
      scenario: String
    ) throws -> PlayerEnvironment {
      struct Scenario {
        var secondsAway: TimeInterval
        var positionMilliseconds: Int64
        var preferences: SmartRewindPreferences
      }

      var preferences = SmartRewindPreferences.default
      let configuration: Scenario
      switch scenario {
      case "below-threshold":
        configuration = Scenario(
          secondsAway: 29,
          positionMilliseconds: 120_000,
          preferences: preferences
        )
      case "short":
        configuration = Scenario(
          secondsAway: 30,
          positionMilliseconds: 120_000,
          preferences: preferences
        )
      case "medium":
        configuration = Scenario(
          secondsAway: 600,
          positionMilliseconds: 120_000,
          preferences: preferences
        )
      case "long":
        configuration = Scenario(
          secondsAway: 3_601,
          positionMilliseconds: 170_000,
          preferences: preferences
        )
      case "maximum":
        configuration = Scenario(
          secondsAway: 3_601,
          positionMilliseconds: 170_000,
          preferences: preferences
        )
      case "disabled":
        preferences.isEnabled = false
        configuration = Scenario(
          secondsAway: 3_601,
          positionMilliseconds: 120_000,
          preferences: preferences
        )
      case "chapter-clamp":
        configuration = Scenario(
          secondsAway: 600,
          positionMilliseconds: 110_000,
          preferences: preferences
        )
      default:
        throw PlayerCoreError.fileOperation("Unknown Smart Rewind E2E scenario: \(scenario)")
      }

      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = support.appending(
        path: "PlayerE2ESmartRewind-\(scenario)",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }

      let bookID = UUID(uuidString: "51000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "51000000-0000-0000-0000-000000000002")!
      let pauseEventID = UUID(uuidString: "51000000-0000-0000-0000-000000000003")!
      let managedPath = "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
      let managedURL = root.appending(path: managedPath)
      if !FileManager.default.fileExists(atPath: managedURL.path) {
        try FileManager.default.createDirectory(
          at: managedURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data("player deterministic smart rewind fixture".utf8).write(to: managedURL)
      }

      let resumedAt = Date(timeIntervalSince1970: 1_700_010_000)
      let pausedAt = resumedAt.addingTimeInterval(-configuration.secondsAway)
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "intervals-of-quiet.m4b",
        managedRelativePath: managedPath,
        checksumSHA256: "e2e-smart-rewind-fixture",
        byteCount: 41,
        durationSeconds: 180,
        container: "M4B"
      )
      let book = Book(
        id: bookID,
        title: "Intervals of Quiet",
        authors: ["Mara Vale"],
        durationSeconds: 180,
        artworkData: nil,
        assets: [asset],
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
        chapters: [
          Chapter(
            id: "smart-rewind-1",
            title: "Before the Pause",
            startSeconds: 0,
            durationSeconds: 60,
            source: .embedded,
            assetID: assetID
          ),
          Chapter(
            id: "smart-rewind-2",
            title: "A Familiar Thread",
            startSeconds: 60,
            durationSeconds: 40,
            source: .embedded,
            assetID: assetID
          ),
          Chapter(
            id: "smart-rewind-3",
            title: "Finding the Thread",
            startSeconds: 100,
            durationSeconds: 40,
            source: .embedded,
            assetID: assetID
          ),
          Chapter(
            id: "smart-rewind-4",
            title: "Moving Forward",
            startSeconds: 140,
            durationSeconds: 40,
            source: .embedded,
            assetID: assetID
          ),
        ]
      )
      let pauseEvent = PositionEvent.acknowledged(
        id: pauseEventID,
        bookID: bookID,
        positionMilliseconds: configuration.positionMilliseconds,
        sequence: 1,
        reason: .pause,
        acknowledgedAt: pausedAt,
        previousEventID: nil
      )
      let seed = LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: bookID,
        playbackPosition: PlaybackPosition(
          bookID: bookID,
          positionMilliseconds: configuration.positionMilliseconds,
          sequence: 1,
          sourceEventID: pauseEvent.id,
          updatedAt: pausedAt
        ),
        positionJournal: [pauseEvent],
        smartRewindPreferences: configuration.preferences
      )
      struct SnapshotEnvelope: Decodable {
        var library: LibrarySnapshot
      }
      let libraryURL = root.appending(path: "Library.json")
      let snapshotDecoder = JSONDecoder()
      snapshotDecoder.dateDecodingStrategy = .iso8601
      let persistedLibrary = try? snapshotDecoder.decode(
        SnapshotEnvelope.self,
        from: Data(contentsOf: libraryURL)
      ).library
      let journalIDs = persistedLibrary?.positionJournal.map(\.id) ?? []
      let transactionIDs = persistedLibrary?.resumeRewindTransactions.flatMap {
          [$0.id, $0.preRewindEventID, $0.rewindEventID]
            + [$0.undoEventID].compactMap { $0 }
        } ?? []
      let persistedIDs = journalIDs + transactionIDs
      let largestPersistedSuffix = persistedIDs.compactMap { id in
        Int(id.uuidString.split(separator: "-").last ?? "")
      }.max() ?? 100
      let firstAvailableSuffix = max(101, largestPersistedSuffix + 1)
      let ids = (firstAvailableSuffix...(firstAvailableSuffix + 39)).map {
        UUID(uuidString: String(format: "51000000-0000-0000-0000-%012d", $0))!
      }
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: libraryURL),
          seed: seed
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: resumedAt),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func metadataRichBookEnvironment(
      reset: Bool,
      namespace: String
    ) throws -> PlayerEnvironment {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = E2EMetadataRichBookNamespace.root(in: support, namespace: namespace)
      if reset { try resetE2EFixtureRoot(root) }

      let bookID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
      let managedPath = "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
      let managedURL = root.appending(path: managedPath)
      if !FileManager.default.fileExists(atPath: managedURL.path) {
        try FileManager.default.createDirectory(
          at: managedURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data("player deterministic metadata fixture".utf8).write(to: managedURL)
      }

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
      let ids = (1...40).map {
        UUID(uuidString: String(format: "31000000-0000-0000-0000-%012d", $0))!
      }
      let seed = LibrarySnapshot(books: [book], importJobs: [], currentBookID: nil)
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: root.appending(path: "Library.json")),
          seed: seed
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func metadataRepairEnvironment() throws -> PlayerEnvironment {
      let environment = ProcessInfo.processInfo.environment
      guard
        let audioEncoded = environment["PLAYER_E2E_METADATA_AUDIO_BASE64"],
        let audio = Data(base64Encoded: audioEncoded),
        let coverEncoded = environment["PLAYER_E2E_METADATA_ORIGINAL_COVER_BASE64"],
        let cover = Data(base64Encoded: coverEncoded)
      else {
        throw PlayerCoreError.fileOperation("The synthetic metadata-repair fixture is unavailable.")
      }

      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EMetadataRepair",
        directoryHint: .isDirectory
      )
      try resetE2EFixtureRoot(root)
      let jobID = UUID(uuidString: "80000000-0000-0000-0000-000000000001")!
      let proposalID = UUID(uuidString: "80000000-0000-0000-0000-000000000002")!
      let assetID = UUID(uuidString: "80000000-0000-0000-0000-000000000003")!
      let bookID = UUID(uuidString: "80000000-0000-0000-0000-000000000004")!
      let sourceURL = root.appending(path: "Input/metadata-repair-source.m4b")
      let stagedRelativePath = "Staging/\(jobID.uuidString.lowercased())/metadata-repair-source.m4b"
      let stagedURL = root.appending(path: stagedRelativePath)
      for url in [sourceURL, stagedURL] {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try audio.write(to: url, options: .atomic)
      }

      let checksum = "6c5a700ee340ace483b4cd45188403ca9a77fd60d94ba248063ee2c7fc6366f7"
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "metadata-repair-source.m4b",
        managedRelativePath: "",
        checksumSHA256: checksum,
        byteCount: Int64(audio.count),
        durationSeconds: 2.4,
        container: "M4B"
      )
      let metadata = AudiobookMetadata.imported(
        title: "The Brass Lantern",
        authors: ["Mira Sol"],
        narrators: ["Anika Reed"],
        seriesName: "Night Signals",
        seriesPosition: "4",
        artworkData: cover,
        artworkMediaType: "image/png",
        provenance: .embeddedTag,
        confidence: .high
      )
      let proposal = BookProposal(
        id: proposalID,
        proposedBookID: bookID,
        title: metadata.title,
        authors: metadata.authors.map(\.displayName),
        durationSeconds: asset.durationSeconds,
        artworkData: cover,
        asset: asset,
        warnings: [],
        narrators: metadata.narrators.map(\.displayName),
        seriesName: metadata.seriesMemberships.first?.name,
        seriesPosition: metadata.seriesMemberships.first?.position,
        artworkMediaType: "image/png",
        metadata: metadata
      )
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let job = ImportJob(
        id: jobID,
        sourceFilename: asset.originalFilename,
        phase: .ready,
        progress: ImportProgress(completed: Int64(audio.count), total: Int64(audio.count)),
        stagedRelativePath: stagedRelativePath,
        proposal: proposal,
        committedBookID: nil,
        failure: nil,
        createdAt: date,
        updatedAt: date
      )
      let managedURL = root.appending(
        path: "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
      )
      E2EMetadataRepairBridge.shared.configure(
        sourceURL: sourceURL,
        sourceBytes: audio,
        managedURL: managedURL,
        checksum: checksum
      )
      let ids = (10...30).compactMap {
        UUID(uuidString: String(format: "80000000-0000-0000-0000-%012d", $0))
      }
      return PlayerEnvironment(
        persistence: InMemoryLibraryStore(
          snapshot: LibrarySnapshot(books: [], importJobs: [job], currentBookID: nil)
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func populatedLibraryEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let launchEnvironment = ProcessInfo.processInfo.environment
      guard
        let descriptorEncoded = launchEnvironment["PLAYER_E2E_LIBRARY_DESCRIPTOR_BASE64"],
        let descriptorData = Data(base64Encoded: descriptorEncoded),
        let audioEncoded = launchEnvironment["PLAYER_E2E_LIBRARY_AUDIO_BASE64"],
        let audio = Data(base64Encoded: audioEncoded)
      else {
        throw PlayerCoreError.fileOperation("The synthetic populated-library fixture is unavailable.")
      }
      let descriptor = try JSONDecoder().decode(E2EPopulatedLibraryDescriptor.self, from: descriptorData)
      guard
        descriptor.schemaVersion == 1,
        descriptor.books.count == 5,
        descriptor.audio.byteCount == audio.count,
        descriptor.audio.sha256 == SHA256.hash(data: audio).map({ String(format: "%02x", $0) }).joined()
      else {
        throw PlayerCoreError.fileOperation("The synthetic populated-library fixture failed validation.")
      }

      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = support.appending(path: "PlayerE2EPopulatedLibrary", directoryHint: .isDirectory)
      if reset { try resetE2EFixtureRoot(root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

      let clock = ISO8601DateFormatter().date(from: descriptor.clock)
        ?? Date(timeIntervalSince1970: 1_776_000_000)
      var books: [Book] = []
      for (index, fixtureBook) in descriptor.books.enumerated() {
        guard
          let bookID = UUID(uuidString: fixtureBook.id),
          let assetID = UUID(uuidString: fixtureBook.assetID),
          let coverEncoded = launchEnvironment["PLAYER_E2E_LIBRARY_COVER_B\(index + 1)_BASE64"],
          let cover = Data(base64Encoded: coverEncoded)
        else {
          throw PlayerCoreError.fileOperation("A synthetic populated-library record is invalid.")
        }
        let relativePath = "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
        let managedURL = root.appending(path: relativePath)
        if !FileManager.default.fileExists(atPath: managedURL.path) {
          try FileManager.default.createDirectory(
            at: managedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try audio.write(to: managedURL, options: .atomic)
        }
        let asset = AudioAsset(
          id: assetID,
          originalFilename: "library-book-audio.m4b",
          managedRelativePath: relativePath,
          checksumSHA256: descriptor.audio.sha256,
          byteCount: Int64(audio.count),
          durationSeconds: Double(descriptor.audio.logicalBookDurationMilliseconds) / 1_000,
          container: "M4B"
        )
        let author = Contributor(
          id: fixtureBook.author.id,
          displayName: fixtureBook.author.name
        )
        let narrator = Contributor(
          id: fixtureBook.narrator.id,
          displayName: fixtureBook.narrator.name
        )
        let memberships = fixtureBook.series.map {
          [SeriesMembership(seriesID: $0.id, name: $0.name, position: $0.position)]
        } ?? []
        let metadata = AudiobookMetadata(
          title: fixtureBook.title,
          authors: [author],
          narrators: [narrator],
          seriesMemberships: memberships,
          cover: CoverArtwork(originalData: cover, mediaType: "image/png", source: .embedded)
        )
        let position = fixtureBook.positionMilliseconds
        let listeningState = BookListeningState(
          status: fixtureBook.finished ? .finished : (position > 0 ? .inProgress : .unplayed),
          positionMilliseconds: position,
          lastListenedAt: position > 0 ? clock.addingTimeInterval(Double(-10 - index * 10)) : nil,
          finishedAt: fixtureBook.finished ? clock.addingTimeInterval(-100) : nil
        )
        books.append(
          Book(
            id: bookID,
            title: fixtureBook.title,
            authors: [fixtureBook.author.name],
            durationSeconds: asset.durationSeconds,
            artworkData: cover,
            assets: [asset],
            dateAdded: clock.addingTimeInterval(Double(fixtureBook.addedOrder)),
            narrators: [fixtureBook.narrator.name],
            seriesName: fixtureBook.series?.name,
            seriesPosition: fixtureBook.series?.position,
            artworkMediaType: "image/png",
            chapters: [
              Chapter(
                id: "file-\(assetID.uuidString.lowercased())",
                title: "Full Book",
                startSeconds: 0,
                durationSeconds: asset.durationSeconds,
                source: .file,
                assetID: assetID
              )
            ],
            metadata: metadata,
            listeningState: listeningState
          )
        )
      }

      guard
        let currentBookID = UUID(uuidString: descriptor.currentBookID),
        let currentBook = books.first(where: { $0.id == currentBookID }),
        let seedEventID = UUID(uuidString: "90000000-0000-0000-0000-000000000701"),
        let collectionID = UUID(uuidString: descriptor.generatedIDs.collection),
        let trashID = UUID(uuidString: descriptor.generatedIDs.trashTransaction)
      else {
        throw PlayerCoreError.fileOperation("The synthetic populated-library identity map is invalid.")
      }
      let seedEvent = PositionEvent.acknowledged(
        id: seedEventID,
        bookID: currentBookID,
        positionMilliseconds: currentBook.listeningState.positionMilliseconds,
        sequence: 1,
        reason: .pause,
        acknowledgedAt: clock,
        previousEventID: nil
      )
      let seed = LibrarySnapshot(
        books: books,
        importJobs: [],
        currentBookID: currentBookID,
        playbackPosition: PlaybackPosition(
          bookID: currentBookID,
          positionMilliseconds: seedEvent.positionMilliseconds,
          sequence: seedEvent.sequence,
          sourceEventID: seedEvent.id,
          updatedAt: clock
        ),
        positionJournal: [seedEvent],
        upNextBookIDs: descriptor.upNext.compactMap(UUID.init(uuidString:)),
        allBooksViewStyle: LibraryViewStyle(rawValue: descriptor.viewPreference) ?? .shelf
      )
      E2ELibraryOrganizationBridge.shared.configure(
        rootURL: root,
        trackedBookID: descriptor.books[4].id,
        expectedChecksum: descriptor.audio.sha256
      )
      let libraryFileURL = root.appending(path: "Library.json")
      let generatedIDs: [UUID]
      if
        let persistedData = try? Data(contentsOf: libraryFileURL),
        let envelope = try? JSONSerialization.jsonObject(with: persistedData) as? [String: Any],
        let library = envelope["library"] as? [String: Any],
        let collections = library["collections"] as? [[String: Any]],
        collections.contains(where: { ($0["id"] as? String)?.lowercased() == collectionID.uuidString.lowercased() })
      {
        generatedIDs = [trashID]
      } else {
        generatedIDs = [collectionID, trashID]
      }
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: libraryFileURL),
          seed: seed
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: clock),
        ids: DeterministicPlayerIDGenerator(values: generatedIDs)
      )
    }

    private static func offlineRecoveryEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EOfflineRecovery",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let date = Date(timeIntervalSince1970: 1_750_000_000)
      let bookID = UUID(uuidString: "d1000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "d1000000-0000-0000-0000-000000000002")!
      let forbidden = [
        "Private Recovery Book",
        "Private Recovery Author",
        "private-recovery-source.m4b",
        "private-recovery-checksum",
        "Private recovery note",
        "private-pairing-secret",
      ]
      let mediaPath =
        "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
      let mediaURL = root.appending(path: mediaPath)
      try FileManager.default.createDirectory(
        at: mediaURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("deterministic recovered audio".utf8).write(to: mediaURL)
      let asset = AudioAsset(
        id: assetID,
        originalFilename: forbidden[2],
        managedRelativePath: mediaPath,
        checksumSHA256: forbidden[3],
        byteCount: 29,
        durationSeconds: 180,
        container: "M4B"
      )
      let book = Book(
        id: bookID,
        title: forbidden[0],
        authors: [forbidden[1]],
        durationSeconds: 180,
        artworkData: nil,
        assets: [asset],
        dateAdded: date
      )
      let snapshot = LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: nil,
        bookmarks: [Bookmark(
          id: UUID(uuidString: "d1000000-0000-0000-0000-000000000003")!,
          bookID: bookID,
          bookPositionMilliseconds: 48_000,
          assetID: assetID,
          assetPositionMilliseconds: 48_000,
          chapterID: nil,
          chapterTitleSnapshot: nil,
          label: "Private recovery bookmark",
          note: forbidden[4],
          createdAt: date,
          updatedAt: date
        )]
      )
      let backupDirectory = root.appending(
        path: "AutomaticBackups",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: backupDirectory,
        withIntermediateDirectories: true
      )
      let envelope = E2EOfflineRecoveryEnvelope(
        schemaVersion: CodableLibraryStore.currentSchemaVersion,
        library: snapshot
      )
      try JSONEncoder.playerEncoder.encode(envelope).write(
        to: backupDirectory.appending(path: "library-safe-copy.json"),
        options: .atomic
      )
      try Data("corrupt primary with private catalog bytes".utf8).write(
        to: root.appending(path: "Library.json"),
        options: .atomic
      )
      let orphans: [(String, String)] = [
        ("Media/d2000000-0000-0000-0000-000000000001/private-orphan.m4b", "media"),
        ("Staging/d2000000-0000-0000-0000-000000000002/private.partial", "staging"),
        ("Trash/d2000000-0000-0000-0000-000000000003/private-trash.m4b", "trash"),
      ]
      for (path, contents) in orphans {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
      }
      E2EOfflineRecoveryBridge.shared.configure(forbiddenValues: forbidden)
      return PlayerEnvironment(
        persistence: CodableLibraryStore(fileURL: root.appending(path: "Library.json")),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        diagnostics: FileSystemSupportDiagnosticsManager(
          rootURL: root,
          clock: FixedPlayerClock(value: date),
          appVersion: "0.1.0",
          appBuild: "17"
        )
      )
    }

    private static func portableBackupEnvironment() throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EPortableBackup",
        directoryHint: .isDirectory
      )
      try resetE2EFixtureRoot(root)
      let bookID = UUID(uuidString: "a1000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "a1000000-0000-0000-0000-000000000002")!
      let eventID = UUID(uuidString: "a1000000-0000-0000-0000-000000000003")!
      let bookmarkID = UUID(uuidString: "a1000000-0000-0000-0000-000000000004")!
      let date = Date(timeIntervalSince1970: 1_750_000_000)
      let audio = Data("player deterministic portable backup audio".utf8)
      let managedPath = "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
      let managedURL = root.appending(path: managedPath)
      try FileManager.default.createDirectory(
        at: managedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try audio.write(to: managedURL)
      let checksum = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "portable-lighthouse.m4b",
        managedRelativePath: managedPath,
        checksumSHA256: checksum,
        byteCount: Int64(audio.count),
        durationSeconds: 300,
        container: "M4B"
      )
      let book = Book(
        id: bookID,
        title: "The Portable Lighthouse",
        authors: ["Mara Vale"],
        durationSeconds: 300,
        artworkData: Data([0x89, 0x50, 0x4e, 0x47]),
        assets: [asset],
        dateAdded: date,
        narrators: ["Nora Reed"],
        seriesName: "Signal Stories",
        seriesPosition: "1",
        artworkMediaType: "image/png",
        chapters: [Chapter(
          id: "opening", title: "Opening", startSeconds: 0,
          durationSeconds: 300, source: .embedded, assetID: assetID
        )],
        listeningState: BookListeningState(
          status: .inProgress,
          positionMilliseconds: 42_000,
          lastListenedAt: date,
          finishedAt: nil
        )
      )
      let event = PositionEvent.acknowledged(
        id: eventID,
        bookID: bookID,
        positionMilliseconds: 42_000,
        sequence: 1,
        reason: .pause,
        acknowledgedAt: date,
        previousEventID: nil
      )
      let snapshot = LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: bookID,
        playbackPosition: PlaybackPosition(
          bookID: bookID,
          positionMilliseconds: 42_000,
          sequence: 1,
          sourceEventID: eventID,
          updatedAt: date
        ),
        positionJournal: [event],
        upNextBookIDs: [bookID],
        allBooksViewStyle: .list,
        bookmarks: [Bookmark(
          id: bookmarkID,
          bookID: bookID,
          bookPositionMilliseconds: 42_000,
          assetID: assetID,
          assetPositionMilliseconds: 42_000,
          chapterID: "opening",
          chapterTitleSnapshot: "Opening",
          label: "Important signal",
          note: "Return here",
          createdAt: date,
          updatedAt: date
        )]
      )
      E2EBackupBridge.shared.configure(
        rootURL: root,
        expectedLibrary: snapshot,
        expectedAudio: audio,
        managedRelativePath: managedPath
      )
      return PlayerEnvironment(
        persistence: InMemoryLibraryStore(snapshot: snapshot),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        backups: FileSystemLibraryBackupManager(
          rootURL: root,
          clock: FixedPlayerClock(value: date)
        )
      )
    }

    private static func messyMultifileEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EMessyMultifile",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      let inputRoot = root.appending(path: "Input", directoryHint: .isDirectory)
      let folder = inputRoot.appending(
        path: "Signal Δ — Folder",
        directoryHint: .isDirectory
      )
      let loose = inputRoot.appending(path: "Loose Files", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)

      let folderFiles = [
        "Signal Δ — Part 1.m4a",
        "Signal Δ — Part 2.m4a",
        "Signal Δ — Part 10.m4a",
        "Prélude – été.m4a",
      ]
      let looseFiles = [
        "L’Écho — piste 3.m4a",
        "L’Écho — piste 4 – café.m4a",
        "L’Écho — piste 5.m4a",
        "L’Écho — piste 6 – fin.m4a",
      ]
      for (index, name) in folderFiles.enumerated() {
        let url = folder.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) {
          try Data("player synthetic folder audio \(index)".utf8).write(to: url)
        }
      }
      for (index, name) in looseFiles.enumerated() {
        let url = loose.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) {
          try Data("player synthetic loose audio \(index)".utf8).write(to: url)
        }
      }

      let selection = [folder] + looseFiles.map { loose.appending(path: $0) }
      E2EMultifileAcquisition.shared.configure(selectionURLs: selection)
      let ids = [
        "30000000-0000-0000-0000-000000000001",
        "30000000-0000-0000-0000-000000000101",
        "30000000-0000-0000-0000-000000000102",
        "30000000-0000-0000-0000-000000000110",
        "30000000-0000-0000-0000-000000000111",
        "30000000-0000-0000-0000-000000000203",
        "30000000-0000-0000-0000-000000000204",
        "30000000-0000-0000-0000-000000000205",
        "30000000-0000-0000-0000-000000000206",
        "30000000-0000-0000-0000-000000000010",
        "30000000-0000-0000-0000-000000000100",
        "30000000-0000-0000-0000-000000000020",
        "30000000-0000-0000-0000-000000000200",
        "30000000-0000-0000-0000-000000000030",
        "30000000-0000-0000-0000-000000000300",
      ].compactMap(UUID.init(uuidString:))
      return PlayerEnvironment(
        persistence: CodableLibraryStore(fileURL: root.appending(path: "Library.json")),
        media: FileSystemMediaManager(rootURL: root.appending(path: "PlayerData")),
        inspector: DeterministicAudioInspector(
          result: .success(
            InspectedAudio(
              title: nil,
              authors: [],
              durationSeconds: 60,
              artworkData: nil,
              container: "M4A"
            )
          )
        ),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func safeZipEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let arguments = ProcessInfo.processInfo.arguments
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2ESafeZIP",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

      let zipCase = argumentValue(after: "-e2e-zip-case", in: arguments) ?? "valid"
      guard
        let encoded = ProcessInfo.processInfo.environment["PLAYER_E2E_ZIP_FIXTURE_BASE64"],
        let bytes = Data(base64Encoded: encoded)
      else {
        throw PlayerCoreError.fileOperation("The E2E ZIP fixture was not provided.")
      }
      let sourceURL = root.appending(path: "selected-audiobook.zip")
      try bytes.write(to: sourceURL, options: .atomic)
      E2EZipAcquisition.shared.configure(zipCase: zipCase, sourceURL: sourceURL, sourceBytes: bytes)

      var policy = ZipExtractionPolicy.audiobook
      if let limits = argumentValue(after: "-e2e-zip-limits", in: arguments) {
        let values = limits.split(separator: ",").compactMap { Double($0) }
        if values.count == 3 {
          policy.maximumEntryCount = Int(values[0])
          policy.maximumEntryBytes = UInt64(values[1])
          policy.maximumEntryExpansionRatio = values[2]
        }
      }
      let result = InspectedAudio(
        title: nil,
        authors: [],
        durationSeconds: 60,
        artworkData: nil,
        container: "M4A"
      )
      let shouldFailOnce = arguments.contains("-e2e-zip-fail-once")
        && argumentValue(after: "-e2e-zip-fail-once", in: arguments) == "inspection"
      let ids = (1...12).compactMap {
        UUID(uuidString: String(format: "60000000-0000-0000-0000-%012d", $0))
      }
      return PlayerEnvironment(
        persistence: CodableLibraryStore(fileURL: root.appending(path: "Library.json")),
        media: FileSystemMediaManager(rootURL: root.appending(path: "PlayerData")),
        inspector: E2EZipAudioInspector(result: result, failOnce: shouldFailOnce),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: ids),
        zipExtractor: SafeZipExtractor(policy: policy)
      )
    }

    private static func argumentValue(after marker: String, in arguments: [String]) -> String? {
      guard let index = arguments.firstIndex(of: marker), arguments.indices.contains(index + 1) else {
        return nil
      }
      return arguments[index + 1]
    }

    private static func metadataRichArtwork() -> Data {
      if
        let encoded = ProcessInfo.processInfo.environment["PLAYER_E2E_METADATA_RICH_COVER_BASE64"],
        let artwork = Data(base64Encoded: encoded)
      {
        return artwork
      }

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
  private struct E2EPopulatedLibraryDescriptor: Decodable {
    struct Audio: Decodable {
      var byteCount: Int
      var sha256: String
      var logicalBookDurationMilliseconds: Int64
    }

    struct Identity: Decodable {
      var id: String
      var name: String
    }

    struct Series: Decodable {
      var id: String
      var name: String
      var position: String
    }

    struct FixtureBook: Decodable {
      var id: String
      var assetID: String
      var title: String
      var author: Identity
      var narrator: Identity
      var series: Series?
      var positionMilliseconds: Int64
      var finished: Bool
      var addedOrder: Int
    }

    struct GeneratedIDs: Decodable {
      var collection: String
      var trashTransaction: String
    }

    var schemaVersion: Int
    var clock: String
    var audio: Audio
    var books: [FixtureBook]
    var currentBookID: String
    var upNext: [String]
    var viewPreference: String
    var generatedIDs: GeneratedIDs
  }

  @MainActor
  final class E2ELibraryOrganizationBridge {
    static let shared = E2ELibraryOrganizationBridge()

    private var rootURL: URL?
    private var trackedBookID: String?
    private var expectedChecksum: String?

    func configure(rootURL: URL, trackedBookID: String, expectedChecksum: String) {
      self.rootURL = rootURL
      self.trackedBookID = trackedBookID.lowercased()
      self.expectedChecksum = expectedChecksum
    }

    var managedChecksumPreserved: Bool {
      guard let rootURL, let trackedBookID, let expectedChecksum else { return false }
      let fileManager = FileManager.default
      guard let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) else { return false }
      let candidates = enumerator.compactMap { $0 as? URL }.filter { url in
        url.pathExtension.lowercased() == "m4b"
          && url.path.lowercased().contains(trackedBookID)
      }
      guard candidates.count == 1, let data = try? Data(contentsOf: candidates[0]) else { return false }
      let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      return checksum == expectedChecksum
    }
  }

  @MainActor
  final class E2EMetadataRepairBridge {
    static let shared = E2EMetadataRepairBridge()

    private var sourceURL: URL?
    private var sourceBytes: Data?
    private var managedURL: URL?
    private var checksum: String?

    var isConfigured: Bool { sourceURL != nil && sourceBytes != nil && managedURL != nil }

    func configure(sourceURL: URL, sourceBytes: Data, managedURL: URL, checksum: String) {
      self.sourceURL = sourceURL
      self.sourceBytes = sourceBytes
      self.managedURL = managedURL
      self.checksum = checksum
    }

    var integrityValue: String {
      guard
        let sourceURL, let sourceBytes, let managedURL, let checksum
      else { return "audio:unconfigured" }
      let sourceUnchanged = (try? Data(contentsOf: sourceURL)) == sourceBytes
      let managed: String
      if FileManager.default.fileExists(atPath: managedURL.path) {
        managed = (try? Data(contentsOf: managedURL)) == sourceBytes ? checksum : "changed"
      } else {
        managed = "none"
      }
      return "audio:source=\(checksum):managed=\(managed):source-unchanged=\(sourceUnchanged)"
    }
  }

  @MainActor
  final class E2EMultifileAcquisition {
    static let shared = E2EMultifileAcquisition()

    private(set) var selectionURLs: [URL] = []
    private var sourceBytes: [String: Data] = [:]

    var isConfigured: Bool { !selectionURLs.isEmpty }

    func configure(selectionURLs: [URL]) {
      self.selectionURLs = selectionURLs
      sourceBytes = sourceFiles(in: selectionURLs).reduce(into: [:]) { result, url in
        result[url.path] = try? Data(contentsOf: url)
      }
    }

    var sourceIsUnchanged: Bool {
      let current = sourceFiles(in: selectionURLs)
      guard current.count == sourceBytes.count else { return false }
      return current.allSatisfy { url in
        guard let expected = sourceBytes[url.path] else { return false }
        return (try? Data(contentsOf: url)) == expected
      }
    }

    private func sourceFiles(in selectionURLs: [URL]) -> [URL] {
      var files: [URL] = []
      for url in selectionURLs {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDirectory,
          let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
          )
        {
          for case let child as URL in enumerator where child.pathExtension.lowercased() == "m4a" {
            files.append(child)
          }
        } else {
          files.append(url)
        }
      }
      return files.sorted { $0.path < $1.path }
    }
  }

  @MainActor
  final class E2EZipAcquisition {
    static let shared = E2EZipAcquisition()

    private(set) var zipCase: String?
    private(set) var sourceURL: URL?
    private var sourceBytes: Data?

    var isConfigured: Bool { zipCase != nil && sourceURL != nil }

    func configure(zipCase: String, sourceURL: URL, sourceBytes: Data) {
      self.zipCase = zipCase
      self.sourceURL = sourceURL
      self.sourceBytes = sourceBytes
    }

    var sourceIsUnchanged: Bool {
      guard let sourceURL, let sourceBytes else { return false }
      return (try? Data(contentsOf: sourceURL)) == sourceBytes
    }
  }

  @MainActor
  final class E2EBackupBridge {
    static let shared = E2EBackupBridge()

    private var rootURL: URL?
    private var expectedLibrary: LibrarySnapshot?
    private var expectedAudio: Data?
    private var managedRelativePath: String?
    private var preparedBackup: PreparedLibraryBackup?

    var isConfigured: Bool { rootURL != nil }

    func configure(
      rootURL: URL,
      expectedLibrary: LibrarySnapshot,
      expectedAudio: Data,
      managedRelativePath: String
    ) {
      self.rootURL = rootURL
      self.expectedLibrary = expectedLibrary
      self.expectedAudio = expectedAudio
      self.managedRelativePath = managedRelativePath
      preparedBackup = nil
    }

    func export(using model: PlayerModel) async throws {
      preparedBackup = try await model.prepareLibraryBackup(kind: .includingMedia)
    }

    func clear(using model: PlayerModel) async throws {
      guard let rootURL else { return }
      let mediaRoot = rootURL.appending(path: "Media")
      if FileManager.default.fileExists(atPath: mediaRoot.path) {
        try FileManager.default.removeItem(at: mediaRoot)
      }
      try await model.replaceLibraryForBackupE2E(with: .empty)
    }

    func restore(using model: PlayerModel) async throws {
      guard let preparedBackup else {
        throw PlayerCoreError.fileOperation("The deterministic backup has not been exported.")
      }
      try await model.restoreLibraryBackup(from: preparedBackup.url)
      await model.discardPreparedLibraryBackup(preparedBackup)
      self.preparedBackup = nil
    }

    func value(for model: PlayerModel) -> String {
      guard let rootURL, let expectedLibrary, let expectedAudio, let managedRelativePath else {
        return "backup:unconfigured"
      }
      let mediaURL = rootURL.appending(path: managedRelativePath)
      let audioMatches = (try? Data(contentsOf: mediaURL)) == expectedAudio
      let mediaFiles: Int
      if let enumerator = FileManager.default.enumerator(
        at: rootURL.appending(path: "Media"),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) {
        mediaFiles = enumerator.compactMap { $0 as? URL }.filter {
          (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.count
      } else {
        mediaFiles = 0
      }
      let state: String
      if equivalentCatalog(model.library, expectedLibrary), audioMatches, preparedBackup != nil {
        state = "exported"
      } else if model.library == .empty, mediaFiles == 0, preparedBackup != nil {
        state = "cleared"
      } else if equivalentCatalog(model.library, expectedLibrary), audioMatches,
        preparedBackup == nil
      {
        state = "restored"
      } else {
        state = "unexpected"
      }
      return "backup:\(state):books=\(model.library.books.count):bookmarks=\(model.library.bookmarks.count):position=\(model.library.playbackPosition?.positionMilliseconds ?? -1):media=\(mediaFiles):audio=\(audioMatches)"
    }

    private func equivalentCatalog(
      _ actual: LibrarySnapshot,
      _ expected: LibrarySnapshot
    ) -> Bool {
      var actual = actual
      var expected = expected
      actual.storageManifests = []
      expected.storageManifests = []
      return actual == expected
    }
  }

  private actor E2EZipAudioInspector: AudioInspecting {
    let result: InspectedAudio
    var shouldFail: Bool

    init(result: InspectedAudio, failOnce: Bool) {
      self.result = result
      self.shouldFail = failOnce
    }

    func inspect(url: URL) async throws -> InspectedAudio {
      if shouldFail {
        shouldFail = false
        throw PlayerCoreError.fileOperation("Audio inspection was interrupted. Try again.")
      }
      return result
    }
  }

  actor E2ESeededLibraryStore: LibraryPersisting {
    let base: CodableLibraryStore
    let seed: LibrarySnapshot

    init(base: CodableLibraryStore, seed: LibrarySnapshot) {
      self.base = base
      self.seed = seed
    }

    func load() async throws -> LibrarySnapshot {
      if let existing = try await base.loadIfPresent() { return existing }
      try await base.save(seed)
      return seed
    }

    func save(_ snapshot: LibrarySnapshot) async throws {
      try await base.save(snapshot)
    }
  }

  private struct E2EOfflineRecoveryEnvelope: Codable {
    var schemaVersion: Int
    var library: LibrarySnapshot
  }
#endif
