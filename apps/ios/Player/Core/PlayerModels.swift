import CryptoKit
import Foundation

struct Book: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var title: String
  var authors: [String]
  var durationSeconds: Double
  var artworkData: Data?
  var assets: [AudioAsset]
  var dateAdded: Date
  var narrators: [String]
  var seriesName: String?
  var seriesPosition: String?
  var artworkMediaType: String?
  var chapters: [Chapter]

  init(
    id: UUID,
    title: String,
    authors: [String],
    durationSeconds: Double,
    artworkData: Data?,
    assets: [AudioAsset],
    dateAdded: Date,
    narrators: [String] = [],
    seriesName: String? = nil,
    seriesPosition: String? = nil,
    artworkMediaType: String? = nil,
    chapters: [Chapter] = []
  ) {
    self.id = id
    self.title = title
    self.authors = authors
    self.durationSeconds = durationSeconds
    self.artworkData = artworkData
    self.assets = assets
    self.dateAdded = dateAdded
    self.narrators = narrators
    self.seriesName = seriesName
    self.seriesPosition = seriesPosition
    self.artworkMediaType = artworkMediaType
    self.chapters = chapters
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, authors, durationSeconds, artworkData, assets, dateAdded
    case narrators, seriesName, seriesPosition, artworkMediaType, chapters
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    title = try values.decode(String.self, forKey: .title)
    authors = try values.decode([String].self, forKey: .authors)
    durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
    artworkData = try values.decodeIfPresent(Data.self, forKey: .artworkData)
    assets = try values.decode([AudioAsset].self, forKey: .assets)
    dateAdded = try values.decode(Date.self, forKey: .dateAdded)
    narrators = try values.decodeIfPresent([String].self, forKey: .narrators) ?? []
    seriesName = try values.decodeIfPresent(String.self, forKey: .seriesName)
    seriesPosition = try values.decodeIfPresent(String.self, forKey: .seriesPosition)
    artworkMediaType = try values.decodeIfPresent(String.self, forKey: .artworkMediaType)
    chapters = try values.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
  }
}

struct AudioAsset: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var originalFilename: String
  var managedRelativePath: String
  var checksumSHA256: String
  var byteCount: Int64
  var durationSeconds: Double
  var container: String
  var timelineStartSeconds: Double

  init(
    id: UUID,
    originalFilename: String,
    managedRelativePath: String,
    checksumSHA256: String,
    byteCount: Int64,
    durationSeconds: Double,
    container: String,
    timelineStartSeconds: Double = 0
  ) {
    self.id = id
    self.originalFilename = originalFilename
    self.managedRelativePath = managedRelativePath
    self.checksumSHA256 = checksumSHA256
    self.byteCount = byteCount
    self.durationSeconds = durationSeconds
    self.container = container
    self.timelineStartSeconds = timelineStartSeconds
  }

  private enum CodingKeys: String, CodingKey {
    case id, originalFilename, managedRelativePath, checksumSHA256
    case byteCount, durationSeconds, container, timelineStartSeconds
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    originalFilename = try values.decode(String.self, forKey: .originalFilename)
    managedRelativePath = try values.decode(String.self, forKey: .managedRelativePath)
    checksumSHA256 = try values.decode(String.self, forKey: .checksumSHA256)
    byteCount = try values.decode(Int64.self, forKey: .byteCount)
    durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
    container = try values.decode(String.self, forKey: .container)
    timelineStartSeconds = try values.decodeIfPresent(Double.self, forKey: .timelineStartSeconds) ?? 0
  }
}

enum ChapterSource: String, Codable, Equatable, Sendable {
  case embedded
  case file
}

struct Chapter: Codable, Equatable, Identifiable, Sendable {
  let id: String
  var title: String
  var startSeconds: Double
  var durationSeconds: Double
  var source: ChapterSource
  var assetID: UUID?
}

enum ImportPhase: String, Codable, Equatable, Sendable {
  case queued
  case acquiring
  case inspecting
  case needsReview
  case ready
  case committing
  case committed
  case failed
}

struct ImportProgress: Codable, Equatable, Sendable {
  var completed: Int64
  var total: Int64?

  static let none = ImportProgress(completed: 0, total: nil)
}

struct ImportFailure: Codable, Equatable, Sendable {
  var message: String
  var affectedFilename: String?
  var sourceIsUnchanged: Bool
  var isRecoverable: Bool
}

struct BookProposal: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  let proposedBookID: UUID
  var title: String
  var authors: [String]
  var durationSeconds: Double
  var artworkData: Data?
  var asset: AudioAsset
  var warnings: [String]
  var narrators: [String]
  var seriesName: String?
  var seriesPosition: String?
  var artworkMediaType: String?
  var chapters: [Chapter]

  init(
    id: UUID,
    proposedBookID: UUID,
    title: String,
    authors: [String],
    durationSeconds: Double,
    artworkData: Data?,
    asset: AudioAsset,
    warnings: [String],
    narrators: [String] = [],
    seriesName: String? = nil,
    seriesPosition: String? = nil,
    artworkMediaType: String? = nil,
    chapters: [Chapter] = []
  ) {
    self.id = id
    self.proposedBookID = proposedBookID
    self.title = title
    self.authors = authors
    self.durationSeconds = durationSeconds
    self.artworkData = artworkData
    self.asset = asset
    self.warnings = warnings
    self.narrators = narrators
    self.seriesName = seriesName
    self.seriesPosition = seriesPosition
    self.artworkMediaType = artworkMediaType
    self.chapters = chapters
  }

  private enum CodingKeys: String, CodingKey {
    case id, proposedBookID, title, authors, durationSeconds, artworkData, asset, warnings
    case narrators, seriesName, seriesPosition, artworkMediaType, chapters
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    proposedBookID = try values.decode(UUID.self, forKey: .proposedBookID)
    title = try values.decode(String.self, forKey: .title)
    authors = try values.decode([String].self, forKey: .authors)
    durationSeconds = try values.decode(Double.self, forKey: .durationSeconds)
    artworkData = try values.decodeIfPresent(Data.self, forKey: .artworkData)
    asset = try values.decode(AudioAsset.self, forKey: .asset)
    warnings = try values.decode([String].self, forKey: .warnings)
    narrators = try values.decodeIfPresent([String].self, forKey: .narrators) ?? []
    seriesName = try values.decodeIfPresent(String.self, forKey: .seriesName)
    seriesPosition = try values.decodeIfPresent(String.self, forKey: .seriesPosition)
    artworkMediaType = try values.decodeIfPresent(String.self, forKey: .artworkMediaType)
    chapters = try values.decodeIfPresent([Chapter].self, forKey: .chapters) ?? []
  }
}

struct ImportJob: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var sourceFilename: String
  var phase: ImportPhase
  var progress: ImportProgress
  var stagedRelativePath: String?
  var proposal: BookProposal?
  var committedBookID: UUID?
  var failure: ImportFailure?
  var createdAt: Date
  var updatedAt: Date
}

struct LibrarySnapshot: Codable, Equatable, Sendable {
  var books: [Book]
  var importJobs: [ImportJob]
  var currentBookID: UUID?
  var playbackPosition: PlaybackPosition?
  var positionJournal: [PositionEvent]

  init(
    books: [Book],
    importJobs: [ImportJob],
    currentBookID: UUID?,
    playbackPosition: PlaybackPosition? = nil,
    positionJournal: [PositionEvent] = []
  ) {
    self.books = books
    self.importJobs = importJobs
    self.currentBookID = currentBookID
    self.playbackPosition = playbackPosition
    self.positionJournal = positionJournal
  }

  static let empty = LibrarySnapshot(books: [], importJobs: [], currentBookID: nil)
}

enum PositionEventReason: String, Codable, Equatable, Sendable {
  case play
  case periodic
  case pause
  case seek
  case background
  case interruption
  case routeChange
}

enum AudioSessionEvent: Equatable, Sendable {
  case interruptionBegan
  case interruptionEnded(shouldResume: Bool)
  case oldDeviceUnavailable
}

enum RemotePlaybackCommand: Equatable, Sendable {
  case play
  case pause
  case togglePlayPause
  case skipForward(seconds: Double)
  case skipBackward(seconds: Double)
  case changePosition(seconds: Double)
}

struct NowPlayingSnapshot: Equatable, Sendable {
  var bookID: UUID
  var title: String
  var authors: [String]
  var narrators: [String]
  var seriesName: String?
  var chapterTitle: String?
  var durationSeconds: Double
  var elapsedSeconds: Double
  var playbackRate: Double
  var artworkData: Data?
}

struct PlaybackPosition: Codable, Equatable, Sendable {
  var bookID: UUID
  var positionMilliseconds: Int64
  var sequence: Int64
  var sourceEventID: UUID
  var updatedAt: Date

  var seconds: Double { Double(positionMilliseconds) / 1_000 }
}

struct PositionEvent: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var bookID: UUID
  var positionMilliseconds: Int64
  var sequence: Int64
  var reason: PositionEventReason
  var acknowledgedAt: Date
  var previousEventID: UUID?
  var integritySHA256: String

  var seconds: Double { Double(positionMilliseconds) / 1_000 }

  static func acknowledged(
    id: UUID,
    bookID: UUID,
    positionMilliseconds: Int64,
    sequence: Int64,
    reason: PositionEventReason,
    acknowledgedAt: Date,
    previousEventID: UUID?
  ) -> PositionEvent {
    var event = PositionEvent(
      id: id,
      bookID: bookID,
      positionMilliseconds: positionMilliseconds,
      sequence: sequence,
      reason: reason,
      acknowledgedAt: acknowledgedAt,
      previousEventID: previousEventID,
      integritySHA256: ""
    )
    event.integritySHA256 = event.calculatedIntegrity
    return event
  }

  var hasValidIntegrity: Bool {
    integritySHA256 == calculatedIntegrity
  }

  private var calculatedIntegrity: String {
    let canonical = [
      id.uuidString.lowercased(),
      bookID.uuidString.lowercased(),
      String(positionMilliseconds),
      String(sequence),
      reason.rawValue,
      String(Int64(acknowledgedAt.timeIntervalSince1970.rounded(.down))),
      previousEventID?.uuidString.lowercased() ?? "root",
    ].joined(separator: "|")
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

enum PositionJournalRecovery {
  static func recover(from library: LibrarySnapshot) -> PlaybackPosition? {
    let booksByID = Dictionary(uniqueKeysWithValues: library.books.map { ($0.id, $0) })
    let ordered = library.positionJournal.sorted {
      if $0.sequence == $1.sequence { return $0.id.uuidString < $1.id.uuidString }
      return $0.sequence < $1.sequence
    }
    var validEventsByID: [UUID: PositionEvent] = [:]
    var usedSequences: Set<Int64> = []

    for event in ordered {
      guard
        event.sequence > 0,
        !usedSequences.contains(event.sequence),
        event.hasValidIntegrity,
        let book = booksByID[event.bookID],
        event.positionMilliseconds >= 0,
        event.positionMilliseconds <= Int64((book.durationSeconds * 1_000).rounded(.down))
      else { continue }

      if let previousID = event.previousEventID {
        guard
          let previous = validEventsByID[previousID],
          previous.sequence < event.sequence
        else { continue }
      } else if !validEventsByID.isEmpty {
        continue
      }

      validEventsByID[event.id] = event
      usedSequences.insert(event.sequence)
    }

    guard let recovered = validEventsByID.values.max(by: { $0.sequence < $1.sequence }) else {
      return nil
    }
    return PlaybackPosition(
      bookID: recovered.bookID,
      positionMilliseconds: recovered.positionMilliseconds,
      sequence: recovered.sequence,
      sourceEventID: recovered.id,
      updatedAt: recovered.acknowledgedAt
    )
  }
}

struct InspectedAudio: Equatable, Sendable {
  var title: String?
  var authors: [String]
  var durationSeconds: Double
  var artworkData: Data?
  var container: String
  var narrators: [String]
  var seriesName: String?
  var seriesPosition: String?
  var artworkMediaType: String?
  var chapters: [Chapter]

  init(
    title: String?,
    authors: [String],
    durationSeconds: Double,
    artworkData: Data?,
    container: String,
    narrators: [String] = [],
    seriesName: String? = nil,
    seriesPosition: String? = nil,
    artworkMediaType: String? = nil,
    chapters: [Chapter] = []
  ) {
    self.title = title
    self.authors = authors
    self.durationSeconds = durationSeconds
    self.artworkData = artworkData
    self.container = container
    self.narrators = narrators
    self.seriesName = seriesName
    self.seriesPosition = seriesPosition
    self.artworkMediaType = artworkMediaType
    self.chapters = chapters
  }
}

struct StagedAudio: Equatable, Sendable {
  var relativePath: String
  var originalFilename: String
  var checksumSHA256: String
  var byteCount: Int64
}

struct ManagedAudio: Equatable, Sendable {
  var relativePath: String
  var stagedRelativePath: String
}

enum PlaybackStatus: String, Codable, Equatable, Sendable {
  case unloaded
  case paused
  case playing
}

struct PlaybackState: Codable, Equatable, Sendable {
  var status: PlaybackStatus
  var loadedBookID: UUID?
  var elapsedSeconds: Double

  static let unloaded = PlaybackState(
    status: .unloaded,
    loadedBookID: nil,
    elapsedSeconds: 0
  )
}

enum PlayerCoreError: LocalizedError, Equatable, Sendable {
  case unsupportedFile(String)
  case sourceIsNotAFile(String)
  case insufficientStorage(required: Int64, available: Int64)
  case unreadableAudio(String)
  case missingImport(UUID)
  case importNotReady(UUID)
  case missingBook(UUID)
  case missingManagedFile(String)
  case newerStoreVersion(Int)
  case invalidStore
  case fileOperation(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedFile(let name):
      "\(name) is not a supported M4A, M4B, or MP3 audiobook."
    case .sourceIsNotAFile(let name):
      "\(name) is not a readable file."
    case .insufficientStorage(let required, let available):
      "This import needs \(required) bytes, but only \(available) bytes are available."
    case .unreadableAudio(let name):
      "\(name) could not be read as audio."
    case .missingImport(let id):
      "Import \(id.uuidString) no longer exists."
    case .importNotReady:
      "This import is not ready to add to the library."
    case .missingBook(let id):
      "Book \(id.uuidString) no longer exists."
    case .missingManagedFile(let path):
      "The managed audio at \(path) is missing."
    case .newerStoreVersion(let version):
      "The library was written by unsupported schema version \(version)."
    case .invalidStore:
      "The local library could not be decoded."
    case .fileOperation(let description):
      description
    }
  }
}
