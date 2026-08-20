#!/usr/bin/env xcrun swift

import CryptoKit
import Foundation

private struct ZIPEntry {
  let path: String
  let data: Data
}

private struct BackupPolicy: Encodable {
  let mode: String
  let includesArtwork: Bool
}

private struct BackupEntry: Encodable {
  let kind: String
  let relativePath: String
  let byteCount: Int
  let checksumSHA256: String
  let bookID: String?
  let assetID: String?
}

private struct BackupManifest: Encodable {
  let identifier: String
  let formatVersion: Int
  let minimumReaderVersion: Int
  let librarySchemaVersion: Int
  let createdAt: Date
  let policy: BackupPolicy
  let entries: [BackupEntry]
}

private enum GeneratorError: Error, CustomStringConvertible {
  case invalidArguments
  case invalidMode
  case oversizedArchive

  var description: String {
    switch self {
    case .invalidArguments:
      return "usage: generate-backup-restore-fixtures.swift MODE OUTPUT.playerbackup LIBRARY.json AUDIO.m4b"
    case .invalidMode:
      return "unknown backup fixture mode"
    case .oversizedArchive:
      return "backup fixture is too large for the deterministic ZIP writer"
    }
  }
}

private let firstAssetID = "a1000000-0000-0000-0000-000000000101"
private let secondAssetID = "a1000000-0000-0000-0000-000000000102"
private let firstBookID = "a1000000-0000-0000-0000-000000000001"
private let secondBookID = "a1000000-0000-0000-0000-000000000002"
private let timestamp = ISO8601DateFormatter().date(from: "2026-08-20T13:41:00Z")!
private let libraryPath = "Library/Library.json"

private func mediaPath(bookID: String, assetID: String) -> String {
  "Media/\(bookID)/\(assetID).m4b"
}

private func checksum(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func encodedManifest(
  librarySchemaVersion: Int,
  mode: String,
  library: Data,
  audio: Data,
  includeMedia: Bool
) throws -> Data {
  var entries = [BackupEntry(
    kind: "library-database",
    relativePath: libraryPath,
    byteCount: library.count,
    checksumSHA256: checksum(library),
    bookID: nil,
    assetID: nil
  )]
  if includeMedia {
    entries += [(firstBookID, firstAssetID), (secondBookID, secondAssetID)].map {
      bookID, assetID in
      BackupEntry(
        kind: "media",
        relativePath: mediaPath(bookID: bookID, assetID: assetID),
        byteCount: audio.count,
        checksumSHA256: checksum(audio),
        bookID: bookID,
        assetID: assetID
      )
    }
  }
  let manifest = BackupManifest(
    identifier: "com.spnss.player.portable-backup",
    formatVersion: 1,
    minimumReaderVersion: 1,
    librarySchemaVersion: librarySchemaVersion,
    createdAt: timestamp,
    policy: BackupPolicy(mode: mode, includesArtwork: false),
    entries: entries.sorted { $0.relativePath < $1.relativePath }
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  var data = try encoder.encode(manifest)
  data.append(0x0a)
  return data
}

private func entries(mode: String, library: Data, audio: Data) throws -> [ZIPEntry] {
  switch mode {
  case "metadata":
    return [
      ZIPEntry(
        path: "manifest.json",
        data: try encodedManifest(
          librarySchemaVersion: 14,
          mode: "metadata-only",
          library: library,
          audio: audio,
          includeMedia: false
        )
      ),
      ZIPEntry(path: libraryPath, data: library),
    ]
  case "media":
    return [
      ZIPEntry(
        path: "manifest.json",
        data: try encodedManifest(
          librarySchemaVersion: 14,
          mode: "including-media",
          library: library,
          audio: audio,
          includeMedia: true
        )
      ),
      ZIPEntry(path: libraryPath, data: library),
      ZIPEntry(path: mediaPath(bookID: firstBookID, assetID: firstAssetID), data: audio),
      ZIPEntry(path: mediaPath(bookID: secondBookID, assetID: secondAssetID), data: audio),
    ]
  case "tampered":
    var changedAudio = audio
    changedAudio[changedAudio.startIndex] ^= 0xff
    return [
      ZIPEntry(
        path: "manifest.json",
        data: try encodedManifest(
          librarySchemaVersion: 14,
          mode: "including-media",
          library: library,
          audio: audio,
          includeMedia: true
        )
      ),
      ZIPEntry(path: libraryPath, data: library),
      ZIPEntry(
        path: mediaPath(bookID: firstBookID, assetID: firstAssetID),
        data: changedAudio
      ),
      ZIPEntry(path: mediaPath(bookID: secondBookID, assetID: secondAssetID), data: audio),
    ]
  case "traversal":
    return [
      ZIPEntry(
        path: "manifest.json",
        data: try encodedManifest(
          librarySchemaVersion: 14,
          mode: "metadata-only",
          library: library,
          audio: audio,
          includeMedia: false
        )
      ),
      ZIPEntry(path: libraryPath, data: library),
      ZIPEntry(path: "../Library.json", data: Data("escape blocked\n".utf8)),
    ]
  case "too-new":
    return [
      ZIPEntry(
        path: "manifest.json",
        data: try encodedManifest(
          librarySchemaVersion: 999,
          mode: "metadata-only",
          library: library,
          audio: audio,
          includeMedia: false
        )
      ),
      ZIPEntry(path: libraryPath, data: library),
    ]
  default:
    throw GeneratorError.invalidMode
  }
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
  data.append(UInt8(value & 0xff))
  data.append(UInt8((value >> 8) & 0xff))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
  data.append(UInt8(value & 0xff))
  data.append(UInt8((value >> 8) & 0xff))
  data.append(UInt8((value >> 16) & 0xff))
  data.append(UInt8((value >> 24) & 0xff))
}

private func crc32(_ data: Data) -> UInt32 {
  var crc: UInt32 = 0xffff_ffff
  for byte in data {
    crc ^= UInt32(byte)
    for _ in 0..<8 {
      crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1)))
    }
  }
  return crc ^ 0xffff_ffff
}

private func writeArchive(_ entries: [ZIPEntry], to output: URL) throws {
  var archive = Data()
  var central = Data()
  let utf8Flag: UInt16 = 0x0800
  let dosDate: UInt16 = UInt16((2026 - 1980) << 9 | 8 << 5 | 20)

  for entry in entries {
    let name = Data(entry.path.utf8)
    guard
      name.count <= Int(UInt16.max),
      entry.data.count <= Int(UInt32.max),
      archive.count <= Int(UInt32.max)
    else { throw GeneratorError.oversizedArchive }
    let size = UInt32(entry.data.count)
    let crc = crc32(entry.data)
    let offset = UInt32(archive.count)

    appendUInt32LE(0x0403_4b50, to: &archive)
    appendUInt16LE(20, to: &archive)
    appendUInt16LE(utf8Flag, to: &archive)
    appendUInt16LE(0, to: &archive)
    appendUInt16LE(0, to: &archive)
    appendUInt16LE(dosDate, to: &archive)
    appendUInt32LE(crc, to: &archive)
    appendUInt32LE(size, to: &archive)
    appendUInt32LE(size, to: &archive)
    appendUInt16LE(UInt16(name.count), to: &archive)
    appendUInt16LE(0, to: &archive)
    archive.append(name)
    archive.append(entry.data)

    appendUInt32LE(0x0201_4b50, to: &central)
    appendUInt16LE(0x0314, to: &central)
    appendUInt16LE(20, to: &central)
    appendUInt16LE(utf8Flag, to: &central)
    appendUInt16LE(0, to: &central)
    appendUInt16LE(0, to: &central)
    appendUInt16LE(dosDate, to: &central)
    appendUInt32LE(crc, to: &central)
    appendUInt32LE(size, to: &central)
    appendUInt32LE(size, to: &central)
    appendUInt16LE(UInt16(name.count), to: &central)
    appendUInt16LE(0, to: &central)
    appendUInt16LE(0, to: &central)
    appendUInt16LE(0, to: &central)
    appendUInt16LE(0, to: &central)
    appendUInt32LE(UInt32(0o100644) << 16, to: &central)
    appendUInt32LE(offset, to: &central)
    central.append(name)
  }

  guard entries.count <= Int(UInt16.max), central.count <= Int(UInt32.max) else {
    throw GeneratorError.oversizedArchive
  }
  let centralOffset = UInt32(archive.count)
  archive.append(central)
  appendUInt32LE(0x0605_4b50, to: &archive)
  appendUInt16LE(0, to: &archive)
  appendUInt16LE(0, to: &archive)
  appendUInt16LE(UInt16(entries.count), to: &archive)
  appendUInt16LE(UInt16(entries.count), to: &archive)
  appendUInt32LE(UInt32(central.count), to: &archive)
  appendUInt32LE(centralOffset, to: &archive)
  appendUInt16LE(0, to: &archive)
  try archive.write(to: output, options: .atomic)
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments.count == 4 else { throw GeneratorError.invalidArguments }
  let library = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
  let audio = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
  try writeArchive(
    try entries(mode: arguments[0], library: library, audio: audio),
    to: URL(fileURLWithPath: arguments[1])
  )
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(2)
}
