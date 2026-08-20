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
  var metadata: AudiobookMetadata
  var listeningState: BookListeningState
  var transportPreferenceOverride: TransportPreferenceOverride?

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
    chapters: [Chapter] = [],
    metadata: AudiobookMetadata? = nil,
    listeningState: BookListeningState = .unplayed,
    transportPreferenceOverride: TransportPreferenceOverride? = nil
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
    self.metadata = metadata ?? .imported(
      title: title,
      authors: authors,
      narrators: narrators,
      seriesName: seriesName,
      seriesPosition: seriesPosition,
      artworkData: artworkData,
      artworkMediaType: artworkMediaType,
      provenance: .legacyLibrary,
      confidence: .medium
    )
    self.listeningState = listeningState
    self.transportPreferenceOverride = transportPreferenceOverride
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, authors, durationSeconds, artworkData, assets, dateAdded
    case narrators, seriesName, seriesPosition, artworkMediaType, chapters, metadata
    case listeningState, transportPreferenceOverride
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
    metadata = try values.decodeIfPresent(AudiobookMetadata.self, forKey: .metadata) ?? .imported(
      title: title,
      authors: authors,
      narrators: narrators,
      seriesName: seriesName,
      seriesPosition: seriesPosition,
      artworkData: artworkData,
      artworkMediaType: artworkMediaType,
      provenance: .legacyLibrary,
      confidence: .medium
    )
    listeningState = try values.decodeIfPresent(
      BookListeningState.self,
      forKey: .listeningState
    ) ?? .unplayed
    transportPreferenceOverride = try values.decodeIfPresent(
      TransportPreferenceOverride.self,
      forKey: .transportPreferenceOverride
    )
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
  var discNumber: Int?
  var trackNumber: Int?
  var importOrder: Int

  init(
    id: UUID,
    originalFilename: String,
    managedRelativePath: String,
    checksumSHA256: String,
    byteCount: Int64,
    durationSeconds: Double,
    container: String,
    timelineStartSeconds: Double = 0,
    discNumber: Int? = nil,
    trackNumber: Int? = nil,
    importOrder: Int = 0
  ) {
    self.id = id
    self.originalFilename = originalFilename
    self.managedRelativePath = managedRelativePath
    self.checksumSHA256 = checksumSHA256
    self.byteCount = byteCount
    self.durationSeconds = durationSeconds
    self.container = container
    self.timelineStartSeconds = timelineStartSeconds
    self.discNumber = discNumber
    self.trackNumber = trackNumber
    self.importOrder = importOrder
  }

  private enum CodingKeys: String, CodingKey {
    case id, originalFilename, managedRelativePath, checksumSHA256
    case byteCount, durationSeconds, container, timelineStartSeconds
    case discNumber, trackNumber, importOrder
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
    discNumber = try values.decodeIfPresent(Int.self, forKey: .discNumber)
    trackNumber = try values.decodeIfPresent(Int.self, forKey: .trackNumber)
    importOrder = try values.decodeIfPresent(Int.self, forKey: .importOrder) ?? 0
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
  case extracting
  case inspecting
  case needsReview
  case ready
  case committing
  case committed
  case failed
  case cancelled
}

struct ImportProgress: Codable, Equatable, Sendable {
  var completed: Int64
  var total: Int64?

  static let none = ImportProgress(completed: 0, total: nil)
}

enum ImportRecoveryAction: String, Codable, Equatable, Sendable {
  case retry
  case changeSelection
}

struct ImportFailure: Codable, Equatable, Sendable {
  var message: String
  var affectedFilename: String?
  var sourceIsUnchanged: Bool
  var isRecoverable: Bool
  var reasonCode: String?
  var recoveryAction: ImportRecoveryAction?

  init(
    message: String,
    affectedFilename: String?,
    sourceIsUnchanged: Bool,
    isRecoverable: Bool,
    reasonCode: String? = nil,
    recoveryAction: ImportRecoveryAction? = nil
  ) {
    self.message = message
    self.affectedFilename = affectedFilename
    self.sourceIsUnchanged = sourceIsUnchanged
    self.isRecoverable = isRecoverable
    self.reasonCode = reasonCode
    self.recoveryAction = recoveryAction
  }

  private enum CodingKeys: String, CodingKey {
    case message, affectedFilename, sourceIsUnchanged, isRecoverable, reasonCode, recoveryAction
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    message = try values.decode(String.self, forKey: .message)
    affectedFilename = try values.decodeIfPresent(String.self, forKey: .affectedFilename)
    sourceIsUnchanged = try values.decode(Bool.self, forKey: .sourceIsUnchanged)
    isRecoverable = try values.decode(Bool.self, forKey: .isRecoverable)
    reasonCode = try values.decodeIfPresent(String.self, forKey: .reasonCode)
    recoveryAction = try values.decodeIfPresent(ImportRecoveryAction.self, forKey: .recoveryAction)
  }
}

struct ZipImportStatus: Codable, Equatable, Sendable {
  var archiveStagedRelativePath: String
  var extractionRelativePath: String
  var checkpointRelativePath: String
  var totalEntryCount: Int
  var extractedEntryCount: Int
  var failureReasonCode: String?
  var retryAllowed: Bool
}

enum ImportEntryPoint: String, Codable, Equatable, Sendable {
  case files
  case folder
  case documentOpen
  case airDrop
  case shareExtension
}

struct ImportRequest: Equatable, Sendable {
  var entryPoint: ImportEntryPoint
  var selectedURLs: [URL]
  var shareHandoffID: UUID?
  var sourceDisplayNames: [String]?

  init(
    entryPoint: ImportEntryPoint,
    selectedURLs: [URL],
    shareHandoffID: UUID? = nil,
    sourceDisplayNames: [String]? = nil
  ) {
    self.entryPoint = entryPoint
    self.selectedURLs = selectedURLs
    self.shareHandoffID = shareHandoffID
    self.sourceDisplayNames = sourceDisplayNames
  }
}

struct DurableImportSource: Codable, Equatable, Sendable {
  var displayName: String
  var bookmarkData: Data?
  var fallbackURLString: String
  var isDirectory: Bool
}

struct InspectedImportAsset: Codable, Equatable, Sendable {
  var asset: AudioAsset
  var inspected: InspectedAudio
  var acquired: AcquiredAudioFile
}

struct ImportQueueCheckpoint: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int
  var entryPoint: ImportEntryPoint
  var sources: [DurableImportSource]
  var acquired: [AcquiredAudioFile]
  var inspected: [InspectedImportAsset]
  var acquisitionComplete: Bool
  var shareHandoffID: UUID?

  init(
    entryPoint: ImportEntryPoint,
    sources: [DurableImportSource],
    acquired: [AcquiredAudioFile] = [],
    inspected: [InspectedImportAsset] = [],
    acquisitionComplete: Bool = false,
    shareHandoffID: UUID? = nil
  ) {
    version = Self.currentVersion
    self.entryPoint = entryPoint
    self.sources = sources
    self.acquired = acquired
    self.inspected = inspected
    self.acquisitionComplete = acquisitionComplete
    self.shareHandoffID = shareHandoffID
  }
}

struct ShareImportReceipt: Codable, Equatable, Identifiable, Sendable {
  var id: UUID { handoffID }
  var handoffID: UUID
  var payloadFingerprint: String
  var jobID: UUID
  var receivedAt: Date
}

enum GroupingEvidenceKind: String, Codable, Equatable, Sendable {
  case selectedTogether
  case commonFolder
  case commonEmbeddedTitle
  case filenameStem
}

struct GroupingEvidence: Codable, Equatable, Sendable {
  var kind: GroupingEvidenceKind
  var explanation: String
}

enum OrderingEvidenceSource: String, Codable, Equatable, Sendable {
  case embeddedDiscTrack
  case filenameNumbers
  case filenameText
  case selectionOrder
  case manual
}

struct TrackOrderingEvidence: Codable, Equatable, Identifiable, Sendable {
  var id: UUID { assetID }
  var assetID: UUID
  var source: OrderingEvidenceSource
  var explanation: String
}

struct StagedImportAsset: Codable, Equatable, Identifiable, Sendable {
  var id: UUID { assetID }
  var assetID: UUID
  var stagedRelativePath: String
  var sourceRelativePath: String
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
  var additionalAssets: [AudioAsset]
  var groupingEvidence: [GroupingEvidence]
  var orderingEvidence: [TrackOrderingEvidence]
  var metadata: AudiobookMetadata

  var assets: [AudioAsset] {
    get { [asset] + additionalAssets }
    set {
      guard let first = newValue.first else { return }
      asset = first
      additionalAssets = Array(newValue.dropFirst())
    }
  }

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
    chapters: [Chapter] = [],
    additionalAssets: [AudioAsset] = [],
    groupingEvidence: [GroupingEvidence] = [],
    orderingEvidence: [TrackOrderingEvidence] = [],
    metadata: AudiobookMetadata? = nil
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
    self.additionalAssets = additionalAssets
    self.groupingEvidence = groupingEvidence
    self.orderingEvidence = orderingEvidence
    self.metadata = metadata ?? .imported(
      title: title,
      authors: authors,
      narrators: narrators,
      seriesName: seriesName,
      seriesPosition: seriesPosition,
      artworkData: artworkData,
      artworkMediaType: artworkMediaType
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id, proposedBookID, title, authors, durationSeconds, artworkData, asset, warnings
    case narrators, seriesName, seriesPosition, artworkMediaType, chapters
    case additionalAssets, groupingEvidence, orderingEvidence, metadata
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
    additionalAssets = try values.decodeIfPresent([AudioAsset].self, forKey: .additionalAssets) ?? []
    groupingEvidence = try values.decodeIfPresent([GroupingEvidence].self, forKey: .groupingEvidence) ?? []
    orderingEvidence = try values.decodeIfPresent([TrackOrderingEvidence].self, forKey: .orderingEvidence) ?? []
    metadata = try values.decodeIfPresent(AudiobookMetadata.self, forKey: .metadata) ?? .imported(
      title: title,
      authors: authors,
      narrators: narrators,
      seriesName: seriesName,
      seriesPosition: seriesPosition,
      artworkData: artworkData,
      artworkMediaType: artworkMediaType,
      provenance: .legacyLibrary,
      confidence: .medium
    )
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
  var stagedAssets: [StagedImportAsset]
  var additionalProposals: [BookProposal]
  var reviewRevision: Int
  var zipStatus: ZipImportStatus?
  var queueCheckpoint: ImportQueueCheckpoint?

  var proposals: [BookProposal] {
    get { proposal.map { [$0] + additionalProposals } ?? additionalProposals }
    set {
      proposal = newValue.first
      additionalProposals = Array(newValue.dropFirst())
    }
  }

  init(
    id: UUID,
    sourceFilename: String,
    phase: ImportPhase,
    progress: ImportProgress,
    stagedRelativePath: String? = nil,
    proposal: BookProposal? = nil,
    committedBookID: UUID? = nil,
    failure: ImportFailure? = nil,
    createdAt: Date,
    updatedAt: Date,
    stagedAssets: [StagedImportAsset] = [],
    additionalProposals: [BookProposal] = [],
    reviewRevision: Int = 0,
    zipStatus: ZipImportStatus? = nil,
    queueCheckpoint: ImportQueueCheckpoint? = nil
  ) {
    self.id = id
    self.sourceFilename = sourceFilename
    self.phase = phase
    self.progress = progress
    self.stagedRelativePath = stagedRelativePath
    self.proposal = proposal
    self.committedBookID = committedBookID
    self.failure = failure
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.stagedAssets = stagedAssets
    self.additionalProposals = additionalProposals
    self.reviewRevision = reviewRevision
    self.zipStatus = zipStatus
    self.queueCheckpoint = queueCheckpoint
  }

  private enum CodingKeys: String, CodingKey {
    case id, sourceFilename, phase, progress, stagedRelativePath, proposal
    case committedBookID, failure, createdAt, updatedAt, stagedAssets, additionalProposals
    case reviewRevision, zipStatus, queueCheckpoint
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    sourceFilename = try values.decode(String.self, forKey: .sourceFilename)
    phase = try values.decode(ImportPhase.self, forKey: .phase)
    progress = try values.decode(ImportProgress.self, forKey: .progress)
    stagedRelativePath = try values.decodeIfPresent(String.self, forKey: .stagedRelativePath)
    proposal = try values.decodeIfPresent(BookProposal.self, forKey: .proposal)
    committedBookID = try values.decodeIfPresent(UUID.self, forKey: .committedBookID)
    failure = try values.decodeIfPresent(ImportFailure.self, forKey: .failure)
    createdAt = try values.decode(Date.self, forKey: .createdAt)
    updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    stagedAssets = try values.decodeIfPresent([StagedImportAsset].self, forKey: .stagedAssets) ?? []
    additionalProposals = try values.decodeIfPresent([BookProposal].self, forKey: .additionalProposals) ?? []
    reviewRevision = try values.decodeIfPresent(Int.self, forKey: .reviewRevision) ?? 0
    zipStatus = try values.decodeIfPresent(ZipImportStatus.self, forKey: .zipStatus)
    queueCheckpoint = try values.decodeIfPresent(ImportQueueCheckpoint.self, forKey: .queueCheckpoint)
  }
}

struct LibrarySnapshot: Codable, Equatable, Sendable {
  var books: [Book]
  var importJobs: [ImportJob]
  var currentBookID: UUID?
  var playbackPosition: PlaybackPosition?
  var positionJournal: [PositionEvent]
  var shareImportReceipts: [ShareImportReceipt]
  var metadataTransactions: [MetadataTransaction]
  var upNextBookIDs: [UUID]
  var collections: [BookCollection]
  var allBooksViewStyle: LibraryViewStyle
  var trashTransactions: [LibraryTrashTransaction]
  var searchPreferences: LibrarySearchPreferences
  var globalTransportPreferences: TransportPreferences
  var smartRewindPreferences: SmartRewindPreferences
  var resumeRewindTransactions: [ResumeRewindTransaction]
  var activeSleepTimer: ActiveSleepTimer?
  var sleepTimerHistory: [SleepTimerHistoryEntry]

  init(
    books: [Book],
    importJobs: [ImportJob],
    currentBookID: UUID?,
    playbackPosition: PlaybackPosition? = nil,
    positionJournal: [PositionEvent] = [],
    shareImportReceipts: [ShareImportReceipt] = [],
    metadataTransactions: [MetadataTransaction] = [],
    upNextBookIDs: [UUID] = [],
    collections: [BookCollection] = [],
    allBooksViewStyle: LibraryViewStyle = .grid,
    trashTransactions: [LibraryTrashTransaction] = [],
    searchPreferences: LibrarySearchPreferences = .default,
    globalTransportPreferences: TransportPreferences = .default,
    smartRewindPreferences: SmartRewindPreferences = .default,
    resumeRewindTransactions: [ResumeRewindTransaction] = [],
    activeSleepTimer: ActiveSleepTimer? = nil,
    sleepTimerHistory: [SleepTimerHistoryEntry] = []
  ) {
    self.books = books
    self.importJobs = importJobs
    self.currentBookID = currentBookID
    self.playbackPosition = playbackPosition
    self.positionJournal = positionJournal
    self.shareImportReceipts = shareImportReceipts
    self.metadataTransactions = metadataTransactions
    self.upNextBookIDs = upNextBookIDs
    self.collections = collections
    self.allBooksViewStyle = allBooksViewStyle
    self.trashTransactions = trashTransactions
    self.searchPreferences = searchPreferences
    self.globalTransportPreferences = globalTransportPreferences
    self.smartRewindPreferences = smartRewindPreferences
    self.resumeRewindTransactions = resumeRewindTransactions
    self.activeSleepTimer = activeSleepTimer
    self.sleepTimerHistory = sleepTimerHistory
  }


  private enum CodingKeys: String, CodingKey {
    case books, importJobs, currentBookID, playbackPosition, positionJournal, shareImportReceipts
    case metadataTransactions
    case upNextBookIDs, collections, allBooksViewStyle, trashTransactions, searchPreferences
    case globalTransportPreferences
    case smartRewindPreferences, resumeRewindTransactions
    case activeSleepTimer, sleepTimerHistory
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    books = try values.decode([Book].self, forKey: .books)
    importJobs = try values.decode([ImportJob].self, forKey: .importJobs)
    currentBookID = try values.decodeIfPresent(UUID.self, forKey: .currentBookID)
    playbackPosition = try values.decodeIfPresent(PlaybackPosition.self, forKey: .playbackPosition)
    positionJournal = try values.decodeIfPresent([PositionEvent].self, forKey: .positionJournal) ?? []
    shareImportReceipts = try values.decodeIfPresent(
      [ShareImportReceipt].self,
      forKey: .shareImportReceipts
    ) ?? []
    metadataTransactions = try values.decodeIfPresent(
      [MetadataTransaction].self,
      forKey: .metadataTransactions
    ) ?? []
    upNextBookIDs = try values.decodeIfPresent([UUID].self, forKey: .upNextBookIDs) ?? []
    collections = try values.decodeIfPresent([BookCollection].self, forKey: .collections) ?? []
    allBooksViewStyle = try values.decodeIfPresent(
      LibraryViewStyle.self,
      forKey: .allBooksViewStyle
    ) ?? .grid
    trashTransactions = try values.decodeIfPresent(
      [LibraryTrashTransaction].self,
      forKey: .trashTransactions
    ) ?? []
    searchPreferences = try values.decodeIfPresent(
      LibrarySearchPreferences.self,
      forKey: .searchPreferences
    ) ?? .default
    globalTransportPreferences = try values.decodeIfPresent(
      TransportPreferences.self,
      forKey: .globalTransportPreferences
    ) ?? .default
    smartRewindPreferences = try values.decodeIfPresent(
      SmartRewindPreferences.self,
      forKey: .smartRewindPreferences
    ) ?? .default
    resumeRewindTransactions = try values.decodeIfPresent(
      [ResumeRewindTransaction].self,
      forKey: .resumeRewindTransactions
    ) ?? []
    activeSleepTimer = try values.decodeIfPresent(
      ActiveSleepTimer.self,
      forKey: .activeSleepTimer
    )
    sleepTimerHistory = try values.decodeIfPresent(
      [SleepTimerHistoryEntry].self,
      forKey: .sleepTimerHistory
    ) ?? []
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
  case preResumeRewind
  case resumeRewind
  case undoResumeRewind
  case sleepTimer
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
  case previousChapter
  case nextChapter
  case skipForward(seconds: Double)
  case skipBackward(seconds: Double)
  case changePosition(seconds: Double)
  case changePlaybackRate(Double)
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

struct InspectedAudio: Codable, Equatable, Sendable {
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
  var discNumber: Int?
  var trackNumber: Int?

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
    chapters: [Chapter] = [],
    discNumber: Int? = nil,
    trackNumber: Int? = nil
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
    self.discNumber = discNumber
    self.trackNumber = trackNumber
  }
}

struct AcquiredAudioFile: Codable, Equatable, Sendable {
  var staged: StagedAudio
  var sourceRelativePath: String
  var commonFolderName: String?
}

struct StagedAudio: Codable, Equatable, Sendable {
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
  case missingProposal(UUID)
  case invalidAssetSelection

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
    case .missingProposal(let id):
      "Import proposal \(id.uuidString) no longer exists."
    case .invalidAssetSelection:
      "The selected tracks do not form a valid book order."
    }
  }
}

enum NaturalTrackOrdering {
  static func order(
    _ assets: [AudioAsset]
  ) -> (assets: [AudioAsset], evidence: [TrackOrderingEvidence], warnings: [String]) {
    let indexed = assets.enumerated().map { (offset: $0.offset, asset: $0.element) }
    let ordered = indexed.sorted { lhs, rhs in
      let lhsExplicit = lhs.asset.trackNumber != nil || lhs.asset.discNumber != nil
      let rhsExplicit = rhs.asset.trackNumber != nil || rhs.asset.discNumber != nil
      if lhsExplicit != rhsExplicit { return lhsExplicit }
      if lhsExplicit && rhsExplicit {
        let lhsPair = (lhs.asset.discNumber ?? 1, lhs.asset.trackNumber ?? Int.max)
        let rhsPair = (rhs.asset.discNumber ?? 1, rhs.asset.trackNumber ?? Int.max)
        if lhsPair != rhsPair {
          return lhsPair.0 == rhsPair.0 ? lhsPair.1 < rhsPair.1 : lhsPair.0 < rhsPair.0
        }
      }
      let lhsHasNumber = filenameHasNumber(lhs.asset.originalFilename)
      let rhsHasNumber = filenameHasNumber(rhs.asset.originalFilename)
      if lhsHasNumber != rhsHasNumber { return lhsHasNumber }
      let comparison = compareFilenames(lhs.asset.originalFilename, rhs.asset.originalFilename)
      return comparison == .orderedSame ? lhs.offset < rhs.offset : comparison == .orderedAscending
    }
    var positioned = ordered.map(\.asset)
    for index in positioned.indices { positioned[index].importOrder = index }

    let evidence = positioned.map { asset in
      if asset.trackNumber != nil || asset.discNumber != nil {
        return TrackOrderingEvidence(
          assetID: asset.id,
          source: .embeddedDiscTrack,
          explanation: "Embedded disc \(asset.discNumber ?? 1), track \(asset.trackNumber ?? 0)"
        )
      }
      if filenameHasNumber(asset.originalFilename) {
        return TrackOrderingEvidence(
          assetID: asset.id,
          source: .filenameNumbers,
          explanation: "Numeric components in \(asset.originalFilename)"
        )
      }
      return TrackOrderingEvidence(
        assetID: asset.id,
        source: .filenameText,
        explanation: "Natural filename order for \(asset.originalFilename)"
      )
    }
    let duplicatePairs = Dictionary(grouping: positioned.compactMap { asset -> String? in
      guard let track = asset.trackNumber else { return nil }
      return "\(asset.discNumber ?? 1)-\(track)"
    }, by: { $0 }).filter { $0.value.count > 1 }
    let warnings = duplicatePairs.keys.sorted().map { "Conflicting embedded disc/track \($0)." }
    return (positioned, evidence, warnings)
  }

  private static func compareFilenames(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = tokens(in: lhs)
    let right = tokens(in: rhs)
    for (a, b) in zip(left, right) where a != b {
      switch (a, b) {
      case (.number(let x), .number(let y)):
        return x < y ? .orderedAscending : .orderedDescending
      case (.text(let x), .text(let y)):
        return x < y ? .orderedAscending : .orderedDescending
      case (.number, .text):
        return .orderedAscending
      case (.text, .number):
        return .orderedDescending
      }
    }
    if left.count == right.count { return .orderedSame }
    return left.count < right.count ? .orderedAscending : .orderedDescending
  }

  private static func filenameHasNumber(_ filename: String) -> Bool {
    URL(filePath: filename).deletingPathExtension().lastPathComponent.contains { $0.isNumber }
  }

  private static func tokens(in value: String) -> [NaturalToken] {
    var result: [NaturalToken] = []
    var buffer = ""
    var readingNumber: Bool?
    func flush() {
      guard !buffer.isEmpty else { return }
      if readingNumber == true {
        result.append(.number(Int(buffer) ?? Int.max))
      } else {
        result.append(.text(buffer.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))))
      }
      buffer = ""
    }
    for character in value {
      let isNumber = character.isNumber
      if let readingNumber, readingNumber != isNumber { flush() }
      readingNumber = isNumber
      buffer.append(character)
    }
    flush()
    return result
  }
}

private enum NaturalToken: Equatable {
  case number(Int)
  case text(String)
}

enum ProposalTimeline {
  static func rebuilding(_ proposal: BookProposal, orderedAssets: [AudioAsset]) -> BookProposal {
    var rebuilt = proposal
    let oldStarts = Dictionary(uniqueKeysWithValues: proposal.assets.map { ($0.id, $0.timelineStartSeconds) })
    var positioned = orderedAssets
    var nextStart = 0.0
    for index in positioned.indices {
      positioned[index].timelineStartSeconds = nextStart
      positioned[index].importOrder = index
      nextStart += positioned[index].durationSeconds
    }
    let newStarts = Dictionary(uniqueKeysWithValues: positioned.map { ($0.id, $0.timelineStartSeconds) })
    rebuilt.chapters = proposal.chapters.compactMap { chapter in
      guard
        let assetID = chapter.assetID,
        let oldStart = oldStarts[assetID],
        let newStart = newStarts[assetID]
      else { return nil }
      var moved = chapter
      moved.startSeconds = max(0, chapter.startSeconds - oldStart) + newStart
      return moved
    }.sorted { $0.startSeconds < $1.startSeconds }
    rebuilt.assets = positioned
    rebuilt.durationSeconds = nextStart
    return rebuilt
  }
}
