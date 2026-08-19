import CryptoKit
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
        case "messy-multifile-unicode":
          return try messyMultifileEnvironment(reset: arguments.contains("-e2e-reset"))
        case "safe-zip-import":
          return try safeZipEnvironment(reset: arguments.contains("-e2e-reset"))
        case "synthetic-import-channels":
          return try importIngressEnvironment(reset: arguments.contains("-e2e-reset"))
        case "synthetic-metadata-repair":
          return try metadataRepairEnvironment()
        case "synthetic-populated-library":
          return try populatedLibraryEnvironment(reset: arguments.contains("-e2e-reset"))
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
      try? FileManager.default.removeItem(at: root)
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
      if reset { try? FileManager.default.removeItem(at: root) }
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
        allBooksViewStyle: LibraryViewStyle(rawValue: descriptor.viewPreference) ?? .grid
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

    private static func messyMultifileEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EMessyMultifile",
        directoryHint: .isDirectory
      )
      if reset { try? FileManager.default.removeItem(at: root) }
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
      if reset { try? FileManager.default.removeItem(at: root) }
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
