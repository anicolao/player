import Compression
import XCTest
@testable import Player

@MainActor
final class SafeZipExtractorTests: XCTestCase {
  func testExtractsStoredAndDeflatedAudioWithCheckpointAndProgress() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "safe.zip")
    let first = Data("first synthetic mp3 payload".utf8)
    let second = Data((0..<8_192).map { index in
      UInt8(truncatingIfNeeded: (index &* 31) ^ (index >> 3))
    })
    let archive = try ZipFixture.make([
      .init(name: "Book/Part 1.mp3", data: first, method: .stored),
      .init(name: "Book/Part 2.m4b", data: second, method: .deflated),
      .init(name: "Book/notes.txt", data: Data("ignored".utf8), method: .stored),
    ])
    try archive.write(to: archiveURL)
    let destination = root.appending(path: "Extracted")
    let checkpointURL = root.appending(path: "checkpoint.json")
    let progress = ZipProgressRecorder()

    let result = try await SafeZipExtractor().extract(
      archiveURL: archiveURL,
      destinationRoot: destination,
      checkpointURL: checkpointURL
    ) { value in
      await progress.record(value)
    }

    XCTAssertEqual(result.files.map(\.relativePath), ["Book/Part 1.mp3", "Book/Part 2.m4b"])
    XCTAssertEqual(try Data(contentsOf: result.files[0].fileURL), first)
    XCTAssertEqual(try Data(contentsOf: result.files[1].fileURL), second)
    XCTAssertEqual(result.checkpoint.state, .complete)
    XCTAssertEqual(result.checkpoint.completedEntries.count, 2)
    XCTAssertEqual(result.checkpoint.extractedBytes, UInt64(first.count + second.count))
    let progressValues = await progress.values
    XCTAssertEqual(progressValues.last?.completedEntries, 2)
    XCTAssertEqual(try Data(contentsOf: archiveURL), archive, "The ZIP source remains unchanged")
  }

  func testCancellationCheckpointsCompletedEntriesAndRetrySkipsVerifiedOutput() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "cancel.zip")
    let first = Data(repeating: 0x31, count: 4_096)
    let second = Data(repeating: 0x32, count: 4_096)
    try ZipFixture.make([
      .init(name: "Book Part 1.mp3", data: first, method: .stored),
      .init(name: "Book Part 2.mp3", data: second, method: .stored),
    ]).write(to: archiveURL)
    let destination = root.appending(path: "Extracted")
    let checkpointURL = root.appending(path: "checkpoint.json")
    let reachedCheckpoint = AsyncSignal()
    let extractor = SafeZipExtractor()
    let task = Task {
      try await extractor.extract(
        archiveURL: archiveURL,
        destinationRoot: destination,
        checkpointURL: checkpointURL
      ) { value in
        if value.completedEntries == 1 {
          await reachedCheckpoint.signal()
          try? await Task.sleep(for: .seconds(30))
        }
      }
    }
    await reachedCheckpoint.wait()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancellation should stop extraction")
    } catch is CancellationError {
      // Expected.
    }

    let cancelled = try JSONDecoder().decode(
      ZipExtractionCheckpoint.self,
      from: Data(contentsOf: checkpointURL)
    )
    XCTAssertEqual(cancelled.state, .cancelled)
    XCTAssertEqual(cancelled.completedEntries.count, 1)
    let firstURL = destination.appending(path: "Book Part 1.mp3")
    XCTAssertEqual(try Data(contentsOf: firstURL), first)

    let retried = try await extractor.extract(
      archiveURL: archiveURL,
      destinationRoot: destination,
      checkpointURL: checkpointURL
    )
    XCTAssertEqual(retried.checkpoint.state, .complete)
    XCTAssertEqual(retried.checkpoint.completedEntries.count, 2)
    XCTAssertEqual(try Data(contentsOf: firstURL), first)
    XCTAssertEqual(try Data(contentsOf: destination.appending(path: "Book Part 2.mp3")), second)
  }

  func testRejectsTraversalAbsoluteBackslashAndDrivePathsBeforeWriting() async throws {
    for (index, path) in ["../escape.mp3", "/absolute.mp3", "..\\escape.mp3", "C:/drive.mp3"].enumerated() {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let archiveURL = root.appending(path: "unsafe-\(index).zip")
      try ZipFixture.make([
        .init(name: path, data: Data("hostile".utf8), method: .stored)
      ]).write(to: archiveURL)
      let destination = root.appending(path: "Extracted")
      let checkpoint = root.appending(path: "checkpoint.json")

      await XCTAssertThrowsZipError(.unsafePath) {
        try await SafeZipExtractor().extract(
          archiveURL: archiveURL,
          destinationRoot: destination,
          checkpointURL: checkpoint
        )
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
      let durableFailure = try JSONDecoder().decode(
        ZipExtractionCheckpoint.self,
        from: Data(contentsOf: checkpoint)
      )
      XCTAssertEqual(durableFailure.state, .failedTerminal)
      XCTAssertEqual(durableFailure.failure?.code, .unsafePath)
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appending(path: "escape.mp3").path))
    }
  }

  func testRejectsSymlinksDuplicateCanonicalPathsEncryptionAndUnsupportedMethods() async throws {
    let cases: [(ZipFixture.Entry, ZipFixture.Entry?, ZipImportErrorCode)] = [
      (
        .init(
          name: "link.mp3",
          data: Data("target".utf8),
          method: .stored,
          externalAttributes: UInt32(0xA1FF) << 16
        ),
        nil,
        .linkEntry
      ),
      (
        .init(name: "Book/Part.mp3", data: Data("one".utf8), method: .stored),
        .init(name: "book/párt.mp3", data: Data("two".utf8), method: .stored),
        .duplicatePath
      ),
      (
        .init(name: "secret.mp3", data: Data("one".utf8), method: .stored, flags: 0x0801),
        nil,
        .encryptedEntry
      ),
      (
        .init(name: "legacy.mp3", data: Data("one".utf8), methodRawValue: 99),
        nil,
        .unsupportedCompression
      ),
    ]

    for (index, item) in cases.enumerated() {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }
      let archiveURL = root.appending(path: "hostile-\(index).zip")
      try ZipFixture.make([item.0] + (item.1.map { [$0] } ?? [])).write(to: archiveURL)
      await XCTAssertThrowsZipError(item.2) {
        try await SafeZipExtractor().extract(
          archiveURL: archiveURL,
          destinationRoot: root.appending(path: "Extracted"),
          checkpointURL: root.appending(path: "checkpoint.json")
        )
      }
    }
  }

  func testRejectsEntryCountSizeAndExpansionRatioLimitsBeforeWriting() async throws {
    let entries = [
      ZipFixture.Entry(name: "one.mp3", data: Data("1111".utf8), method: .stored),
      ZipFixture.Entry(name: "two.mp3", data: Data("2222".utf8), method: .stored),
    ]
    var countPolicy = ZipExtractionPolicy.audiobook
    countPolicy.maximumEntryCount = 1
    try await assertPolicyFailure(entries: entries, policy: countPolicy, expected: .tooManyEntries)

    var sizePolicy = ZipExtractionPolicy.audiobook
    sizePolicy.maximumEntryBytes = 3
    try await assertPolicyFailure(entries: [entries[0]], policy: sizePolicy, expected: .entryTooLarge)

    var ratioPolicy = ZipExtractionPolicy.audiobook
    ratioPolicy.maximumEntryExpansionRatio = 2
    try await assertPolicyFailure(
      entries: [
        .init(
          name: "bomb.mp3",
          data: Data([0]),
          method: .stored,
          declaredUncompressedSize: 1_000
        )
      ],
      policy: ratioPolicy,
      expected: .expansionRatio
    )
  }

  func testChecksumMismatchRemovesPartialAndRecordsTerminalFailure() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archiveURL = root.appending(path: "bad-crc.zip")
    try ZipFixture.make([
      .init(
        name: "bad.mp3",
        data: Data("payload".utf8),
        method: .stored,
        crcOverride: 0x1234_5678
      )
    ]).write(to: archiveURL)
    let destination = root.appending(path: "Extracted")
    let checkpoint = root.appending(path: "checkpoint.json")

    await XCTAssertThrowsZipError(.checksumMismatch) {
      try await SafeZipExtractor().extract(
        archiveURL: archiveURL,
        destinationRoot: destination,
        checkpointURL: checkpoint
      )
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "bad.mp3").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "bad.mp3.partial").path))
    let failure = try JSONDecoder().decode(
      ZipExtractionCheckpoint.self,
      from: Data(contentsOf: checkpoint)
    )
    XCTAssertEqual(failure.failure?.code, .checksumMismatch)
    XCTAssertEqual(failure.failure?.entryPath, "bad.mp3")
  }

  func testPlayerModelRetriesInspectionFromCompletedCheckpointWithoutDuplicates() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "book.zip")
    let sourceData = try ZipFixture.make([
      .init(name: "Book/01.mp3", data: Data("one".utf8)),
      .init(name: "Book/02.mp3", data: Data("two".utf8)),
    ])
    try sourceData.write(to: source)
    let ids = (1...5).map {
      UUID(uuidString: String(format: "60000000-0000-0000-0000-%012d", $0))!
    }
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: InMemoryLibraryStore(),
      media: FileSystemMediaManager(rootURL: root.appending(path: "Storage")),
      inspector: ZipTestInspector(failuresRemaining: 1),
      playback: ZipTestPlaybackController(),
      ids: DeterministicPlayerIDGenerator(values: ids)
    ))

    let importedJobID = await model.importAudioSelection(from: [source])
    let jobID = try XCTUnwrap(importedJobID)
    var job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.phase, .failed)
    XCTAssertEqual(job.failure?.reasonCode, "inspection-transient")
    XCTAssertEqual(job.failure?.recoveryAction, .retry)
    XCTAssertEqual(job.zipStatus?.totalEntryCount, 2)
    XCTAssertEqual(job.zipStatus?.extractedEntryCount, 2)

    let retried = await model.retryImport(jobID: jobID)
    XCTAssertTrue(retried)
    job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.phase, .ready)
    XCTAssertEqual(job.proposals.count, 1)
    XCTAssertEqual(job.proposals.first?.assets.count, 2)
    XCTAssertEqual(job.stagedAssets.count, 2)
    XCTAssertEqual(model.library.importJobs.count, 1)
    XCTAssertEqual(try Data(contentsOf: source), sourceData)
  }

  func testPlayerModelPersistsPrevalidationCountAndCancelsUnsafeArchive() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "unsafe.zip")
    try ZipFixture.make([
      .init(name: "../escape.mp3", data: Data("bad".utf8)),
      .init(name: "safe.mp3", data: Data("safe".utf8)),
      .init(name: "/absolute.mp3", data: Data("bad".utf8)),
    ]).write(to: source)
    let jobID = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
    let storage = root.appending(path: "Storage")
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: InMemoryLibraryStore(),
      media: FileSystemMediaManager(rootURL: storage),
      inspector: ZipTestInspector(),
      playback: ZipTestPlaybackController(),
      ids: DeterministicPlayerIDGenerator(values: [jobID])
    ))

    let importedJobID = await model.importAudioSelection(from: [source])
    XCTAssertEqual(importedJobID, jobID)
    var job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.failure?.reasonCode, "path-traversal")
    XCTAssertEqual(job.failure?.recoveryAction, .changeSelection)
    XCTAssertEqual(job.zipStatus?.totalEntryCount, 3)
    XCTAssertEqual(job.zipStatus?.extractedEntryCount, 0)
    XCTAssertFalse(job.zipStatus?.retryAllowed ?? true)

    await model.cancelImport(jobID: jobID)
    job = try XCTUnwrap(model.library.importJobs.first(where: { $0.id == jobID }))
    XCTAssertEqual(job.phase, .cancelled)
    XCTAssertEqual(job.zipStatus?.extractedEntryCount, 0)
    let staging = storage.appending(path: "Staging/\(jobID.uuidString.lowercased())")
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
  }

  private func assertPolicyFailure(
    entries: [ZipFixture.Entry],
    policy: ZipExtractionPolicy,
    expected: ZipImportErrorCode
  ) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appending(path: "policy.zip")
    try ZipFixture.make(entries).write(to: archive)
    let destination = root.appending(path: "Extracted")
    await XCTAssertThrowsZipError(expected) {
      try await SafeZipExtractor(policy: policy).extract(
        archiveURL: archive,
        destinationRoot: destination,
        checkpointURL: root.appending(path: "checkpoint.json")
      )
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "SafeZipExtractorTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private actor ZipTestInspector: AudioInspecting {
  private var failuresRemaining: Int

  init(failuresRemaining: Int = 0) {
    self.failuresRemaining = failuresRemaining
  }

  func inspect(url: URL) throws -> InspectedAudio {
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw PlayerCoreError.fileOperation("Temporary inspection failure.")
    }
    return InspectedAudio(
      title: "Book",
      authors: [],
      durationSeconds: 10,
      artworkData: nil,
      container: url.pathExtension.uppercased()
    )
  }
}

@MainActor
private final class ZipTestPlaybackController: AudioPlaybackControlling {
  var state: PlaybackState = .unloaded
  var currentPositionSeconds: Double { state.elapsedSeconds }
  func load(url: URL, bookID: UUID, at seconds: Double) async throws {
    state = PlaybackState(status: .paused, loadedBookID: bookID, elapsedSeconds: seconds)
  }
  func seek(to seconds: Double) async { state.elapsedSeconds = seconds }
  func play() { state.status = .playing }
  func pause() { state.status = .paused }
}

private func XCTAssertThrowsZipError<T: Sendable>(
  _ expectedCode: ZipImportErrorCode,
  operation: @Sendable () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await operation()
    XCTFail("Expected ZIP error \(expectedCode)", file: file, line: line)
  } catch let error as ZipImportError {
    XCTAssertEqual(error.code, expectedCode, file: file, line: line)
  } catch {
    XCTFail("Unexpected error \(error)", file: file, line: line)
  }
}

private actor ZipProgressRecorder {
  private(set) var values: [ZipExtractionProgress] = []
  func record(_ value: ZipExtractionProgress) { values.append(value) }
}

private actor AsyncSignal {
  private var hasSignalled = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func signal() {
    hasSignalled = true
    let waiting = continuations
    continuations.removeAll()
    waiting.forEach { $0.resume() }
  }

  func wait() async {
    if hasSignalled { return }
    await withCheckedContinuation { continuations.append($0) }
  }
}

private enum ZipFixture {
  enum Method: UInt16 {
    case stored = 0
    case deflated = 8
  }

  struct Entry {
    var name: String
    var data: Data
    var method: Method
    var methodRawValue: UInt16
    var externalAttributes: UInt32
    var flags: UInt16
    var declaredUncompressedSize: UInt32?
    var crcOverride: UInt32?

    init(
      name: String,
      data: Data,
      method: Method = .stored,
      methodRawValue: UInt16? = nil,
      externalAttributes: UInt32 = UInt32(0x81A4) << 16,
      flags: UInt16 = 0x0800,
      declaredUncompressedSize: UInt32? = nil,
      crcOverride: UInt32? = nil
    ) {
      self.name = name
      self.data = data
      self.method = method
      self.methodRawValue = methodRawValue ?? method.rawValue
      self.externalAttributes = externalAttributes
      self.flags = flags
      self.declaredUncompressedSize = declaredUncompressedSize
      self.crcOverride = crcOverride
    }
  }

  static func make(_ entries: [Entry]) throws -> Data {
    var archive = Data()
    var central = Data()
    for entry in entries {
      let name = Data(entry.name.utf8)
      let compressed = entry.method == .deflated ? try deflate(entry.data) : entry.data
      let crc = entry.crcOverride ?? TestCRC32.checksum(entry.data)
      let uncompressedSize = entry.declaredUncompressedSize ?? UInt32(entry.data.count)
      let localOffset = UInt32(archive.count)
      archive.appendLE(UInt32(0x0403_4B50))
      archive.appendLE(UInt16(20))
      archive.appendLE(entry.flags)
      archive.appendLE(entry.methodRawValue)
      archive.appendLE(UInt16(0))
      archive.appendLE(UInt16(0))
      archive.appendLE(crc)
      archive.appendLE(UInt32(compressed.count))
      archive.appendLE(uncompressedSize)
      archive.appendLE(UInt16(name.count))
      archive.appendLE(UInt16(0))
      archive.append(name)
      archive.append(compressed)

      central.appendLE(UInt32(0x0201_4B50))
      central.appendLE(UInt16(0x0314))
      central.appendLE(UInt16(20))
      central.appendLE(entry.flags)
      central.appendLE(entry.methodRawValue)
      central.appendLE(UInt16(0))
      central.appendLE(UInt16(0))
      central.appendLE(crc)
      central.appendLE(UInt32(compressed.count))
      central.appendLE(uncompressedSize)
      central.appendLE(UInt16(name.count))
      central.appendLE(UInt16(0))
      central.appendLE(UInt16(0))
      central.appendLE(UInt16(0))
      central.appendLE(UInt16(0))
      central.appendLE(entry.externalAttributes)
      central.appendLE(localOffset)
      central.append(name)
    }
    let centralOffset = UInt32(archive.count)
    archive.append(central)
    archive.appendLE(UInt32(0x0605_4B50))
    archive.appendLE(UInt16(0))
    archive.appendLE(UInt16(0))
    archive.appendLE(UInt16(entries.count))
    archive.appendLE(UInt16(entries.count))
    archive.appendLE(UInt32(central.count))
    archive.appendLE(centralOffset)
    archive.appendLE(UInt16(0))
    return archive
  }

  private static func deflate(_ data: Data) throws -> Data {
    let capacity = max(64, data.count * 2 + 64)
    var destination = Data(count: capacity)
    let size = data.withUnsafeBytes { source in
      destination.withUnsafeMutableBytes { output in
        compression_encode_buffer(
          output.bindMemory(to: UInt8.self).baseAddress!,
          capacity,
          source.bindMemory(to: UInt8.self).baseAddress!,
          data.count,
          nil,
          COMPRESSION_ZLIB
        )
      }
    }
    guard size > 0 else { throw ZipImportError.fileOperation("Fixture deflate failed.") }
    destination.count = size
    return destination
  }
}

private extension Data {
  mutating func appendLE(_ value: UInt16) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
  }

  mutating func appendLE(_ value: UInt32) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
    append(UInt8((value >> 16) & 0xFF))
    append(UInt8((value >> 24) & 0xFF))
  }
}

private enum TestCRC32 {
  private static let table: [UInt32] = (0..<256).map { value in
    var crc = UInt32(value)
    for _ in 0..<8 {
      crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
    }
    return crc
  }

  static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
  }
}
