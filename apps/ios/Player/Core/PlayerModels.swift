import Foundation

struct Book: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var title: String
  var authors: [String]
  var durationSeconds: Double
  var artworkData: Data?
  var assets: [AudioAsset]
  var dateAdded: Date
}

struct AudioAsset: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var originalFilename: String
  var managedRelativePath: String
  var checksumSHA256: String
  var byteCount: Int64
  var durationSeconds: Double
  var container: String
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

  static let empty = LibrarySnapshot(books: [], importJobs: [], currentBookID: nil)
}

struct InspectedAudio: Equatable, Sendable {
  var title: String?
  var authors: [String]
  var durationSeconds: Double
  var artworkData: Data?
  var container: String
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
