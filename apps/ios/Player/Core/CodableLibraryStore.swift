import Foundation

actor CodableLibraryStore: LibraryPersisting {
  static let currentSchemaVersion = 2

  private let fileURL: URL
  private let fileManager: FileManager

  init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  func load() throws -> LibrarySnapshot {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return .empty
    }

    let data = try Data(contentsOf: fileURL)
    let header: SchemaHeader
    do {
      header = try JSONDecoder.playerDecoder.decode(SchemaHeader.self, from: data)
    } catch {
      throw PlayerCoreError.invalidStore
    }

    guard header.schemaVersion <= Self.currentSchemaVersion else {
      throw PlayerCoreError.newerStoreVersion(header.schemaVersion)
    }

    switch header.schemaVersion {
    case 1:
      do {
        let legacy = try JSONDecoder.playerDecoder.decode(EnvelopeV1.self, from: data).library
        return LibrarySnapshot(
          books: legacy.books,
          importJobs: legacy.importJobs,
          currentBookID: legacy.currentBookID
        )
      } catch {
        throw PlayerCoreError.invalidStore
      }
    case 2:
      do {
        return try JSONDecoder.playerDecoder.decode(EnvelopeV2.self, from: data).library
      } catch {
        throw PlayerCoreError.invalidStore
      }
    default:
      throw PlayerCoreError.invalidStore
    }
  }

  func save(_ snapshot: LibrarySnapshot) throws {
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let envelope = EnvelopeV2(
      schemaVersion: Self.currentSchemaVersion,
      library: snapshot
    )
    let data = try JSONEncoder.playerEncoder.encode(envelope)
    try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
  }
}

actor InMemoryLibraryStore: LibraryPersisting {
  private var snapshot: LibrarySnapshot

  init(snapshot: LibrarySnapshot = .empty) {
    self.snapshot = snapshot
  }

  func load() -> LibrarySnapshot { snapshot }

  func save(_ snapshot: LibrarySnapshot) {
    self.snapshot = snapshot
  }
}

private struct SchemaHeader: Decodable {
  let schemaVersion: Int
}

private struct LegacyLibrarySnapshotV1: Codable {
  var books: [Book]
  var importJobs: [ImportJob]
  var currentBookID: UUID?
}

private struct EnvelopeV1: Codable {
  let schemaVersion: Int
  let library: LegacyLibrarySnapshotV1
}

private struct EnvelopeV2: Codable {
  let schemaVersion: Int
  let library: LibrarySnapshot
}

private extension JSONEncoder {
  static var playerEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

private extension JSONDecoder {
  static var playerDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
