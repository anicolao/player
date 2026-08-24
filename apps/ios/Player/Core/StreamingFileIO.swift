import CryptoKit
import Foundation

struct StreamingDigest: Equatable, Sendable {
  let byteCount: Int64
  let checksumSHA256: String
}

/// Shared bounded-memory file processing used by imports and portable backups.
/// The closure form keeps the production loop directly testable with virtual
/// multi-gigabyte sources without ever materializing a whole payload in memory.
enum StreamingFileIO {
  static let maximumChunkByteCount = 1_024 * 1_024

  static func copyAndHash(
    read: (_ maximumByteCount: Int) throws -> Data?,
    write: @escaping (Data) throws -> Void
  ) throws -> StreamingDigest {
    try process(read: read, write: write)
  }

  static func hash(
    read: (_ maximumByteCount: Int) throws -> Data?
  ) throws -> StreamingDigest {
    try process(read: read, write: nil)
  }

  static func copyAndHash(from source: URL, to destination: URL) throws -> StreamingDigest {
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: destination)
    defer {
      try? input.close()
      try? output.close()
    }
    let digest = try copyAndHash(
      read: { try input.read(upToCount: $0) },
      write: { try output.write(contentsOf: $0) }
    )
    try output.synchronize()
    return digest
  }

  static func hashFile(at url: URL) throws -> StreamingDigest {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    return try hash(read: { try input.read(upToCount: $0) })
  }

  private static func process(
    read: (_ maximumByteCount: Int) throws -> Data?,
    write: ((Data) throws -> Void)?
  ) throws -> StreamingDigest {
    var hash = SHA256()
    var byteCount: Int64 = 0
    while try autoreleasepool(invoking: {
      try Task.checkCancellation()
      guard let chunk = try read(maximumChunkByteCount), !chunk.isEmpty else { return false }
      guard chunk.count <= maximumChunkByteCount else {
        throw PlayerCoreError.fileOperation("A streaming source exceeded the bounded-memory limit.")
      }
      hash.update(data: chunk)
      try write?(chunk)
      let (nextCount, overflow) = byteCount.addingReportingOverflow(Int64(chunk.count))
      guard !overflow else { throw PlayerCoreError.fileOperation("The streamed file is too large.") }
      byteCount = nextCount
      return true
    }) {}
    return StreamingDigest(
      byteCount: byteCount,
      checksumSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined()
    )
  }
}
