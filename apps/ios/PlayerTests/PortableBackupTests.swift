import XCTest
@testable import Player

final class PortableBackupTests: XCTestCase {
  func testMetadataOnlyPackageValidatesExactPayloadAndCurrentSchema() throws {
    let libraryData = Data("portable-library".utf8)
    let artworkData = Data("portable-artwork".utf8)
    let library = try entry(
      .libraryDatabase,
      "Library/library.json",
      data: libraryData
    )
    let artwork = try entry(
      .artwork,
      "Artwork/book-cover.jpg",
      data: artworkData,
      bookID: uuid(10)
    )
    let manifest = try PortableBackupManifest(
      librarySchemaVersion: 14,
      createdAt: date(100),
      policy: .metadataOnly,
      entries: [artwork, library]
    )
    let package = PortableBackupPackage(
      manifest: manifest,
      observedFiles: [
        try observed(library.relativePath, data: libraryData),
        try observed(artwork.relativePath, data: artworkData),
      ]
    )

    let plan = try package.validatedRestorePlan(
      policy: .player(currentLibrarySchemaVersion: 14)
    )

    XCTAssertEqual(plan.schemaAction, .direct(version: 14))
    XCTAssertEqual(plan.restoreMode, .replaceLibrary)
    XCTAssertEqual(plan.libraryEntry, library)
    XCTAssertEqual(plan.artworkEntries, [artwork])
    XCTAssertTrue(plan.mediaEntries.isEmpty)
    XCTAssertEqual(plan.verifiedPayloadBytes, Int64(libraryData.count + artworkData.count))
    XCTAssertEqual(manifest.entries.map(\.relativePath), [
      "Artwork/book-cover.jpg", "Library/library.json"
    ])
  }

  func testMediaInclusivePackageMapsOlderLibraryToMigration() throws {
    let database = Data("schema-9".utf8)
    let audio = Data("streamed-audio-placeholder".utf8)
    let library = try entry(.libraryDatabase, "Library/library.json", data: database)
    let media = try entry(
      .media,
      "Media/book/part-1.m4b",
      data: audio,
      bookID: uuid(10),
      assetID: uuid(11)
    )
    let manifest = try PortableBackupManifest(
      librarySchemaVersion: 9,
      createdAt: date(100),
      policy: .includingMedia,
      entries: [library, media]
    )

    let plan = try PortableBackupValidator.validate(
      manifest: manifest,
      observedFiles: [
        try observed(library.relativePath, data: database),
        try observed(media.relativePath, data: audio),
      ],
      policy: .player(currentLibrarySchemaVersion: 14)
    )

    XCTAssertEqual(plan.schemaAction, .migrate(from: 9, to: 14))
    XCTAssertEqual(plan.mediaEntries, [media])
  }

  func testManifestEnforcesContentPolicyAndExactlyOneLibraryPayload() throws {
    let library = try entry(.libraryDatabase, "Library/library.json", data: Data("db".utf8))
    let media = try entry(
      .media,
      "Media/book/audio.m4b",
      data: Data("audio".utf8),
      bookID: uuid(10),
      assetID: uuid(11)
    )
    let artwork = try entry(
      .artwork,
      "Artwork/book.jpg",
      data: Data("art".utf8),
      bookID: uuid(10)
    )

    XCTAssertThrowsBackupError(.policyDisallowsEntry(media.relativePath)) {
      _ = try PortableBackupManifest(
        librarySchemaVersion: 14,
        createdAt: date(1),
        policy: .metadataOnly,
        entries: [library, media]
      )
    }
    XCTAssertThrowsBackupError(.policyDisallowsEntry(artwork.relativePath)) {
      _ = try PortableBackupManifest(
        librarySchemaVersion: 14,
        createdAt: date(1),
        policy: PortableBackupContentPolicy(mode: .metadataOnly, includesArtwork: false),
        entries: [library, artwork]
      )
    }
    XCTAssertThrowsBackupError(.missingLibraryPayload) {
      _ = try PortableBackupManifest(
        librarySchemaVersion: 14,
        createdAt: date(1),
        policy: .includingMedia,
        entries: [media]
      )
    }
    let secondLibrary = try entry(
      .libraryDatabase,
      "Library/other.json",
      data: Data("other".utf8)
    )
    XCTAssertThrowsBackupError(.multipleLibraryPayloads) {
      _ = try PortableBackupManifest(
        librarySchemaVersion: 14,
        createdAt: date(1),
        policy: .includingMedia,
        entries: [library, secondLibrary]
      )
    }
  }

  func testManifestRejectsTraversalAndCaseOrUnicodePathCollisions() throws {
    XCTAssertThrowsBackupError(.unsafePath("../Library.json")) {
      _ = try PortableBackupEntry(
        kind: .libraryDatabase,
        relativePath: "../Library.json",
        byteCount: 2,
        checksumSHA256: checksum("db")
      )
    }
    let library = try entry(.libraryDatabase, "Library/library.json", data: Data("db".utf8))
    let first = try entry(
      .artwork,
      "Artwork/Caf\u{00e9}.jpg",
      data: Data("one".utf8),
      bookID: uuid(10)
    )
    let collision = try entry(
      .artwork,
      "artwork/Cafe\u{0301}.jpg",
      data: Data("two".utf8),
      bookID: uuid(11)
    )
    XCTAssertThrowsBackupError(.duplicatePath(collision.relativePath)) {
      _ = try PortableBackupManifest(
        librarySchemaVersion: 14,
        createdAt: date(1),
        policy: .metadataOnly,
        entries: [library, first, collision]
      )
    }
  }

  func testManifestDecoderCannotBypassStructuralValidation() throws {
    let manifest = try validManifest()
    let encoded = try JSONEncoder().encode(manifest)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
    entries[0]["relativePath"] = "/absolute/library.json"
    object["entries"] = entries

    XCTAssertThrowsError(try JSONDecoder().decode(
      PortableBackupManifest.self,
      from: JSONSerialization.data(withJSONObject: object)
    ))

    let observed = try ObservedBackupFile(
      relativePath: "Library/library.json",
      byteCount: 10,
      checksumSHA256: checksum("library")
    )
    var observedObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(observed)) as? [String: Any]
    )
    observedObject["byteCount"] = -1
    XCTAssertThrowsError(try JSONDecoder().decode(
      ObservedBackupFile.self,
      from: JSONSerialization.data(withJSONObject: observedObject)
    ))
  }

  func testCanonicalManifestFingerprintIgnoresEncodingAndInputOrder() throws {
    let library = try entry(
      .libraryDatabase,
      "Library/library.json",
      data: Data("portable-library".utf8)
    )
    let artwork = try entry(
      .artwork,
      "Artwork/Caf\u{00e9}.jpg",
      data: Data("portable-artwork".utf8),
      bookID: uuid(10)
    )
    let first = try PortableBackupManifest(
      librarySchemaVersion: 14,
      createdAt: date(100),
      policy: .metadataOnly,
      entries: [library, artwork]
    )
    let reordered = try PortableBackupManifest(
      librarySchemaVersion: 14,
      createdAt: date(100),
      policy: .metadataOnly,
      entries: [artwork, library]
    )
    let decoded = try JSONDecoder().decode(
      PortableBackupManifest.self,
      from: JSONEncoder().encode(first)
    )
    let decomposedArtwork = try entry(
      .artwork,
      "Artwork/Cafe\u{0301}.jpg",
      data: Data("portable-artwork".utf8),
      bookID: uuid(10)
    )
    let canonicallyEquivalent = try PortableBackupManifest(
      librarySchemaVersion: 14,
      createdAt: date(100),
      policy: .metadataOnly,
      entries: [decomposedArtwork, library]
    )

    XCTAssertEqual(first.canonicalFingerprintSHA256, reordered.canonicalFingerprintSHA256)
    XCTAssertEqual(first.canonicalFingerprintSHA256, decoded.canonicalFingerprintSHA256)
    XCTAssertEqual(
      first.canonicalFingerprintSHA256,
      canonicallyEquivalent.canonicalFingerprintSHA256
    )
    XCTAssertEqual(first.canonicalFingerprintSHA256.count, 64)

    let changed = try PortableBackupManifest(
      librarySchemaVersion: 14,
      createdAt: date(101),
      policy: .metadataOnly,
      entries: [library, artwork]
    )
    XCTAssertNotEqual(first.canonicalFingerprintSHA256, changed.canonicalFingerprintSHA256)
  }

  func testSafeRestoreRejectsMissingExtraLinkSizeAndChecksumMismatch() throws {
    let manifest = try validManifest()
    let library = manifest.libraryEntry
    let exact = try ObservedBackupFile(
      relativePath: library.relativePath,
      byteCount: library.byteCount,
      checksumSHA256: library.checksumSHA256
    )
    let policy = PortableBackupValidationPolicy.player(currentLibrarySchemaVersion: 14)

    XCTAssertThrowsBackupError(.missingEntry(library.relativePath)) {
      _ = try PortableBackupValidator.validate(
        manifest: manifest,
        observedFiles: [],
        policy: policy
      )
    }
    let extra = try observed("Extra/unlisted.bin", data: Data("extra".utf8))
    XCTAssertThrowsBackupError(.unexpectedEntry(extra.relativePath)) {
      _ = try PortableBackupValidator.validate(
        manifest: manifest,
        observedFiles: [exact, extra],
        policy: policy
      )
    }
    let link = try ObservedBackupFile(
      relativePath: library.relativePath,
      byteCount: library.byteCount,
      checksumSHA256: library.checksumSHA256,
      fileType: .symbolicLink
    )
    XCTAssertThrowsBackupError(.linkEntry(library.relativePath)) {
      _ = try PortableBackupValidator.validate(
        manifest: manifest,
        observedFiles: [link],
        policy: policy
      )
    }
    let wrongSize = try ObservedBackupFile(
      relativePath: library.relativePath,
      byteCount: library.byteCount + 1,
      checksumSHA256: library.checksumSHA256
    )
    XCTAssertThrowsBackupError(.sizeMismatch(
      library.relativePath,
      expected: library.byteCount,
      actual: library.byteCount + 1
    )) {
      _ = try PortableBackupValidator.validate(
        manifest: manifest,
        observedFiles: [wrongSize],
        policy: policy
      )
    }
    let wrongChecksum = try ObservedBackupFile(
      relativePath: library.relativePath,
      byteCount: library.byteCount,
      checksumSHA256: checksum("wrong")
    )
    XCTAssertThrowsBackupError(.checksumMismatch(library.relativePath)) {
      _ = try PortableBackupValidator.validate(
        manifest: manifest,
        observedFiles: [wrongChecksum],
        policy: policy
      )
    }
  }

  func testValidationRejectsTooNewVersionsAndResourceLimits() throws {
    let base = try validManifest()
    let observed = [try ObservedBackupFile(
      relativePath: base.libraryEntry.relativePath,
      byteCount: base.libraryEntry.byteCount,
      checksumSHA256: base.libraryEntry.checksumSHA256
    )]
    var tooNew = base
    tooNew.formatVersion = 2
    XCTAssertThrowsBackupError(.unsupportedFormatVersion(2)) {
      _ = try PortableBackupValidator.validate(
        manifest: tooNew,
        observedFiles: observed,
        policy: .player(currentLibrarySchemaVersion: 14)
      )
    }
    var newSchema = base
    newSchema.librarySchemaVersion = 15
    XCTAssertThrowsBackupError(.unsupportedLibrarySchema(15)) {
      _ = try PortableBackupValidator.validate(
        manifest: newSchema,
        observedFiles: observed,
        policy: .player(currentLibrarySchemaVersion: 14)
      )
    }
    var tight = PortableBackupValidationPolicy.player(currentLibrarySchemaVersion: 14)
    tight.maximumEntryBytes = base.libraryEntry.byteCount - 1
    XCTAssertThrowsBackupError(.entryTooLarge(
      base.libraryEntry.relativePath,
      actual: base.libraryEntry.byteCount,
      maximum: tight.maximumEntryBytes
    )) {
      _ = try PortableBackupValidator.validate(
        manifest: base,
        observedFiles: observed,
        policy: tight
      )
    }


    var invalidPolicy = PortableBackupValidationPolicy.player(
      currentLibrarySchemaVersion: 14
    )
    invalidPolicy.maximumEntryCount = -1
    XCTAssertThrowsBackupError(.invalidValidationPolicy) {
      _ = try PortableBackupValidator.validate(
        manifest: base,
        observedFiles: observed,
        policy: invalidPolicy
      )
    }
  }

  func testValidationRejectsByteTotalOverflowEvenAtInt64MaximumLimit() throws {
    let library = try PortableBackupEntry(
      kind: .libraryDatabase,
      relativePath: "Library/library.json",
      byteCount: .max,
      checksumSHA256: checksum("library")
    )
    let artwork = try PortableBackupEntry(
      kind: .artwork,
      relativePath: "Artwork/cover.jpg",
      byteCount: 1,
      checksumSHA256: checksum("artwork"),
      bookID: uuid(10)
    )
    let manifest = try PortableBackupManifest(
      librarySchemaVersion: 14,
      createdAt: date(1),
      policy: .metadataOnly,
      entries: [library, artwork]
    )
    let policy = PortableBackupValidationPolicy(
      supportedFormatVersions: 1...1,
      supportedLibrarySchemaVersions: 1...14,
      currentLibrarySchemaVersion: 14,
      maximumEntryCount: 2,
      maximumEntryBytes: .max,
      maximumTotalBytes: .max
    )

    XCTAssertEqual(manifest.totalPayloadBytes, .max)
    XCTAssertThrowsBackupError(.packageByteCountOverflow) {
      _ = try PortableBackupValidator.validate(
        manifest: manifest,
        observedFiles: [],
        policy: policy
      )
    }
  }

  func testRotationRetainsNewestAndProtectsRecentPreMigrationBackup() throws {
    let oldMigration = try descriptor(
      1,
      at: 10,
      trigger: .beforeMigration(from: 12, to: 13)
    )
    let oldMutation = try descriptor(
      2,
      at: 20,
      trigger: .afterSignificantMutation(reason: "metadata repair")
    )
    let recentMutation = try descriptor(
      3,
      at: 30,
      trigger: .afterSignificantMutation(reason: "import commit")
    )
    let candidate = try descriptor(
      4,
      at: 40,
      trigger: .afterSignificantMutation(reason: "bookmark edit")
    )

    let plan = try DatabaseBackupRotationPlanner.plan(
      existing: [oldMigration, recentMutation, oldMutation],
      adding: candidate,
      policy: DatabaseBackupRetentionPolicy(
        maximumBackupCount: 3,
        minimumPreMigrationBackups: 1
      )
    )

    XCTAssertEqual(plan.retained.map(\.id), [candidate.id, recentMutation.id, oldMigration.id])
    XCTAssertEqual(plan.discarded.map(\.id), [oldMutation.id])
  }

  func testRotationRejectsDuplicateDescriptorsAndInvalidRetention() throws {
    let descriptor = try descriptor(
      1,
      at: 10,
      trigger: .afterSignificantMutation(reason: "import")
    )
    XCTAssertThrowsBackupError(.duplicateBackupID(descriptor.id)) {
      _ = try DatabaseBackupRotationPlanner.plan(
        existing: [descriptor],
        adding: descriptor
      )
    }
    XCTAssertThrowsBackupError(.invalidRetentionPolicy) {
      _ = try DatabaseBackupRotationPlanner.plan(
        existing: [],
        adding: descriptor,
        policy: DatabaseBackupRetentionPolicy(
          maximumBackupCount: 0,
          minimumPreMigrationBackups: 1
        )
      )
    }
  }

  func testRotationTieBreakIsDeterministicAndRejectsInvalidTimestamp() throws {
    let lowerID = try descriptor(
      1,
      at: 10,
      trigger: .afterSignificantMutation(reason: "first")
    )
    let higherID = try descriptor(
      2,
      at: 10,
      trigger: .afterSignificantMutation(reason: "second")
    )
    let plan = try DatabaseBackupRotationPlanner.plan(
      existing: [higherID],
      adding: lowerID,
      policy: DatabaseBackupRetentionPolicy(
        maximumBackupCount: 1,
        minimumPreMigrationBackups: 0
      )
    )
    XCTAssertEqual(plan.retained.map(\.id), [higherID.id])

    XCTAssertThrowsBackupError(.invalidTimestamp) {
      _ = try DatabaseBackupDescriptor(
        id: uuid(3),
        relativePath: "AutomaticBackups/invalid.json",
        byteCount: 1,
        checksumSHA256: checksum("invalid"),
        librarySchemaVersion: 14,
        createdAt: Date(timeIntervalSinceReferenceDate: .infinity),
        trigger: .afterSignificantMutation(reason: "invalid date")
      )
    }
  }

  func testDatabaseBackupDescriptorDecoderAndRecoveryAreValidated() throws {
    let descriptor = try descriptor(
      1,
      at: 10,
      schema: 13,
      trigger: .beforeMigration(from: 13, to: 14)
    )
    let observed = try ObservedBackupFile(
      relativePath: descriptor.relativePath,
      byteCount: descriptor.byteCount,
      checksumSHA256: descriptor.checksumSHA256
    )
    let candidate = try DatabaseBackupValidator.validate(
      descriptor: descriptor,
      observedFile: observed,
      supportedLibrarySchemaVersions: 1...14,
      currentLibrarySchemaVersion: 14
    )
    XCTAssertEqual(candidate.schemaAction, .migrate(from: 13, to: 14))

    let encoded = try JSONEncoder().encode(descriptor)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["relativePath"] = "../escaped.json"
    XCTAssertThrowsError(try JSONDecoder().decode(
      DatabaseBackupDescriptor.self,
      from: JSONSerialization.data(withJSONObject: object)
    ))
  }

  func testEveryShippedSchemaFixtureContractRequiresRoundTripDomains() throws {
    let allDomains = Set(BackupPreservedDomain.allCases)
    let contracts = (1...14).map { schema in
      BackupSchemaFixtureContract(
        fixtureName: "schema-v\(schema).json",
        sourceLibrarySchemaVersion: schema,
        expectedCanonicalSHA256: checksum("schema-\(schema)"),
        preservedDomains: allDomains
      )
    }
    XCTAssertNoThrow(try BackupSchemaFixtureCoverage.validate(
      contracts,
      requiredSchemaVersions: 1...14
    ))

    XCTAssertThrowsBackupError(.missingSchemaFixtures([5])) {
      try BackupSchemaFixtureCoverage.validate(
        contracts.filter { $0.sourceLibrarySchemaVersion != 5 },
        requiredSchemaVersions: 1...14
      )
    }
    var incomplete = contracts
    incomplete[0].preservedDomains.remove(.bookmarks)
    XCTAssertThrowsBackupError(.incompleteFixtureContract("schema-v1.json")) {
      try BackupSchemaFixtureCoverage.validate(incomplete, requiredSchemaVersions: 1...14)
    }
  }

  func testChecksumAndOperationStatusRoundTripDeterministically() throws {
    XCTAssertEqual(
      BackupChecksum.sha256(Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    let status = BackupOperationStatus(
      id: uuid(99),
      kind: .exportPortable,
      phase: .validating,
      completedBytes: 100,
      totalBytes: 100,
      startedAt: date(1),
      finishedAt: nil,
      failureCode: nil
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        BackupOperationStatus.self,
        from: JSONEncoder().encode(status)
      ),
      status
    )
  }

  private func validManifest() throws -> PortableBackupManifest {
    try PortableBackupManifest(
      librarySchemaVersion: 14,
      createdAt: date(100),
      policy: .metadataOnly,
      entries: [try entry(
        .libraryDatabase,
        "Library/library.json",
        data: Data("portable-library".utf8)
      )]
    )
  }

  private func entry(
    _ kind: PortableBackupEntryKind,
    _ path: String,
    data: Data,
    bookID: UUID? = nil,
    assetID: UUID? = nil
  ) throws -> PortableBackupEntry {
    try PortableBackupEntry(
      kind: kind,
      relativePath: path,
      byteCount: Int64(data.count),
      checksumSHA256: BackupChecksum.sha256(data),
      bookID: bookID,
      assetID: assetID
    )
  }

  private func observed(_ path: String, data: Data) throws -> ObservedBackupFile {
    try ObservedBackupFile(
      relativePath: path,
      byteCount: Int64(data.count),
      checksumSHA256: BackupChecksum.sha256(data)
    )
  }

  private func descriptor(
    _ suffix: Int,
    at timestamp: TimeInterval,
    schema: Int = 14,
    trigger: DatabaseBackupTrigger
  ) throws -> DatabaseBackupDescriptor {
    try DatabaseBackupDescriptor(
      id: uuid(suffix),
      relativePath: "AutomaticBackups/backup-\(suffix).json",
      byteCount: 100,
      checksumSHA256: checksum("backup-\(suffix)"),
      librarySchemaVersion: schema,
      createdAt: date(timestamp),
      trigger: trigger
    )
  }

  private func checksum(_ value: String) -> String {
    BackupChecksum.sha256(Data(value.utf8))
  }

  private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "f1000000-0000-0000-0000-%012d", suffix))!
  }

  private func date(_ timestamp: TimeInterval) -> Date {
    Date(timeIntervalSince1970: timestamp)
  }
}

private func XCTAssertThrowsBackupError<T>(
  _ expected: PortableBackupError,
  file: StaticString = #filePath,
  line: UInt = #line,
  _ expression: () throws -> T
) {
  XCTAssertThrowsError(try expression(), file: file, line: line) { error in
    XCTAssertEqual(error as? PortableBackupError, expected, file: file, line: line)
  }
}
