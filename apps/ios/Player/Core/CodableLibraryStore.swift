import Foundation

actor CodableLibraryStore: LibraryPersisting {
  static let currentSchemaVersion = 8

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
        return migrateImportGroupingDefaults(
          in: migrateMetadataDefaults(in: LibrarySnapshot(
            books: legacy.books,
            importJobs: legacy.importJobs,
            currentBookID: legacy.currentBookID
          ))
        )
      } catch {
        throw PlayerCoreError.invalidStore
      }
    case 2:
      do {
        let legacy = try JSONDecoder.playerDecoder.decode(EnvelopeV2.self, from: data).library
        return migrateImportGroupingDefaults(in: migrateMetadataDefaults(in: legacy))
      } catch {
        throw PlayerCoreError.invalidStore
      }
    case 3:
      do {
        let legacy = try JSONDecoder.playerDecoder.decode(EnvelopeV3.self, from: data).library
        return migrateImportGroupingDefaults(in: legacy)
      } catch {
        throw PlayerCoreError.invalidStore
      }
    case 4:
      do {
        return try JSONDecoder.playerDecoder.decode(EnvelopeV4.self, from: data).library
      } catch {
        throw PlayerCoreError.invalidStore
      }
    case 5:
      do {
        return try JSONDecoder.playerDecoder.decode(EnvelopeV5.self, from: data).library
      } catch {
        throw PlayerCoreError.invalidStore
      }
    case 6:
      do {
        return migrateMetadataRepairDefaults(
          in: try JSONDecoder.playerDecoder.decode(EnvelopeV6.self, from: data).library
        )
      } catch {
        throw PlayerCoreError.invalidStore
      }
    case 7:
      do {
        return migrateLibraryOrganizationDefaults(
          in: try JSONDecoder.playerDecoder.decode(EnvelopeV7.self, from: data).library
        )
      } catch {
        throw PlayerCoreError.invalidStore
      }
    case 8:
      do {
        return try JSONDecoder.playerDecoder.decode(EnvelopeV8.self, from: data).library
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

    let envelope = EnvelopeV8(
      schemaVersion: Self.currentSchemaVersion,
      library: snapshot
    )
    let data = try JSONEncoder.playerEncoder.encode(envelope)
    try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
  }

  private func migrateImportGroupingDefaults(in snapshot: LibrarySnapshot) -> LibrarySnapshot {
    var migrated = snapshot
    for jobIndex in migrated.importJobs.indices {
      guard
        migrated.importJobs[jobIndex].stagedAssets.isEmpty,
        let proposal = migrated.importJobs[jobIndex].proposal,
        let stagedPath = migrated.importJobs[jobIndex].stagedRelativePath
      else { continue }
      migrated.importJobs[jobIndex].stagedAssets = [
        StagedImportAsset(
          assetID: proposal.asset.id,
          stagedRelativePath: stagedPath,
          sourceRelativePath: proposal.asset.originalFilename
        )
      ]
    }
    return migrated
  }

  private func migrateMetadataDefaults(in snapshot: LibrarySnapshot) -> LibrarySnapshot {
    var migrated = snapshot
    for bookIndex in migrated.books.indices {
      var timelineStart = 0.0
      for assetIndex in migrated.books[bookIndex].assets.indices {
        migrated.books[bookIndex].assets[assetIndex].timelineStartSeconds = timelineStart
        timelineStart += migrated.books[bookIndex].assets[assetIndex].durationSeconds
      }
      if migrated.books[bookIndex].chapters.isEmpty {
        migrated.books[bookIndex].chapters = migrated.books[bookIndex].assets.map { asset in
          Chapter(
            id: "file-\(asset.id.uuidString.lowercased())",
            title: URL(filePath: asset.originalFilename).deletingPathExtension().lastPathComponent,
            startSeconds: asset.timelineStartSeconds,
            durationSeconds: asset.durationSeconds,
            source: .file,
            assetID: asset.id
          )
        }
      }
    }
    for jobIndex in migrated.importJobs.indices {
      guard var proposal = migrated.importJobs[jobIndex].proposal else { continue }
      proposal.asset.timelineStartSeconds = 0
      if proposal.chapters.isEmpty {
        proposal.chapters = [
          Chapter(
            id: "file-\(proposal.asset.id.uuidString.lowercased())",
            title: URL(filePath: proposal.asset.originalFilename)
              .deletingPathExtension().lastPathComponent,
            startSeconds: 0,
            durationSeconds: proposal.asset.durationSeconds,
            source: .file,
            assetID: proposal.asset.id
          )
        ]
      }
      migrated.importJobs[jobIndex].proposal = proposal
    }
    return migrated
  }

  /// Book and proposal decoders synthesize metadata from their v6 display
  /// fields. Keeping this migration explicit makes the schema boundary visible
  /// and provides one place for future normalization of those synthesized values.
  private func migrateMetadataRepairDefaults(in snapshot: LibrarySnapshot) -> LibrarySnapshot {
    var migrated = snapshot
    migrated.metadataTransactions = []
    return migrated
  }

  private func migrateLibraryOrganizationDefaults(in snapshot: LibrarySnapshot) -> LibrarySnapshot {
    var migrated = snapshot
    if let position = migrated.playbackPosition,
      let index = migrated.books.firstIndex(where: { $0.id == position.bookID })
    {
      migrated.books[index].listeningState = BookListeningState(
        status: position.positionMilliseconds > 0 ? .inProgress : .unplayed,
        positionMilliseconds: position.positionMilliseconds,
        lastListenedAt: position.updatedAt,
        finishedAt: nil
      )
    }
    return migrated
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

private struct EnvelopeV3: Codable {
  let schemaVersion: Int
  let library: LibrarySnapshot
}

private struct EnvelopeV4: Codable {
  let schemaVersion: Int
  let library: LibrarySnapshot
}

private struct EnvelopeV5: Codable {
  let schemaVersion: Int
  let library: LibrarySnapshot
}

private struct EnvelopeV6: Codable {
  let schemaVersion: Int
  let library: LibrarySnapshot
}

private struct EnvelopeV7: Codable {
  let schemaVersion: Int
  let library: LibrarySnapshot
}

private struct EnvelopeV8: Codable {
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
