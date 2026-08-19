#!/usr/bin/env swift

import Foundation

private struct ZIPEntry {
  let path: String
  let data: Data
  let unixMode: UInt16
}

private enum ZIPFixtureError: Error, CustomStringConvertible {
  case invalidArguments
  case invalidMode
  case oversizedEntry

  var description: String {
    switch self {
    case .invalidArguments:
      "usage: generate-zip-fixtures.swift MODE OUTPUT.zip [VALID_AUDIO_1 VALID_AUDIO_2]"
    case .invalidMode: "unknown ZIP fixture mode"
    case .oversizedEntry: "ZIP fixture entry is too large"
    }
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

private func writeArchive(entries: [ZIPEntry], to url: URL) throws {
  var archive = Data()
  var centralDirectory = Data()
  let dosTime: UInt16 = 0
  let dosDate: UInt16 = UInt16((2024 - 1980) << 9 | 1 << 5 | 1)
  let utf8Flag: UInt16 = 0x0800

  for entry in entries {
    let name = Data(entry.path.utf8)
    guard entry.data.count <= Int(UInt32.max), archive.count <= Int(UInt32.max) else {
      throw ZIPFixtureError.oversizedEntry
    }
    let size = UInt32(entry.data.count)
    let checksum = crc32(entry.data)
    let localOffset = UInt32(archive.count)

    appendUInt32LE(0x0403_4b50, to: &archive)
    appendUInt16LE(20, to: &archive)
    appendUInt16LE(utf8Flag, to: &archive)
    appendUInt16LE(0, to: &archive)
    appendUInt16LE(dosTime, to: &archive)
    appendUInt16LE(dosDate, to: &archive)
    appendUInt32LE(checksum, to: &archive)
    appendUInt32LE(size, to: &archive)
    appendUInt32LE(size, to: &archive)
    appendUInt16LE(UInt16(name.count), to: &archive)
    appendUInt16LE(0, to: &archive)
    archive.append(name)
    archive.append(entry.data)

    appendUInt32LE(0x0201_4b50, to: &centralDirectory)
    appendUInt16LE(0x0314, to: &centralDirectory)
    appendUInt16LE(20, to: &centralDirectory)
    appendUInt16LE(utf8Flag, to: &centralDirectory)
    appendUInt16LE(0, to: &centralDirectory)
    appendUInt16LE(dosTime, to: &centralDirectory)
    appendUInt16LE(dosDate, to: &centralDirectory)
    appendUInt32LE(checksum, to: &centralDirectory)
    appendUInt32LE(size, to: &centralDirectory)
    appendUInt32LE(size, to: &centralDirectory)
    appendUInt16LE(UInt16(name.count), to: &centralDirectory)
    appendUInt16LE(0, to: &centralDirectory)
    appendUInt16LE(0, to: &centralDirectory)
    appendUInt16LE(0, to: &centralDirectory)
    appendUInt16LE(0, to: &centralDirectory)
    appendUInt32LE(UInt32(entry.unixMode) << 16, to: &centralDirectory)
    appendUInt32LE(localOffset, to: &centralDirectory)
    centralDirectory.append(name)
  }

  let centralOffset = UInt32(archive.count)
  archive.append(centralDirectory)
  appendUInt32LE(0x0605_4b50, to: &archive)
  appendUInt16LE(0, to: &archive)
  appendUInt16LE(0, to: &archive)
  appendUInt16LE(UInt16(entries.count), to: &archive)
  appendUInt16LE(UInt16(entries.count), to: &archive)
  appendUInt32LE(UInt32(centralDirectory.count), to: &archive)
  appendUInt32LE(centralOffset, to: &archive)
  appendUInt16LE(0, to: &archive)
  try archive.write(to: url, options: .atomic)
}

private func entries(for mode: String, arguments: [String]) throws -> [ZIPEntry] {
  let regularMode: UInt16 = 0o100644
  switch mode {
  case "valid":
    guard arguments.count == 2 else { throw ZIPFixtureError.invalidArguments }
    return [
      ZIPEntry(
        path: "Safe Signals/Part 1.m4a",
        data: try Data(contentsOf: URL(fileURLWithPath: arguments[0])),
        unixMode: regularMode
      ),
      ZIPEntry(
        path: "Safe Signals/Part 2.m4a",
        data: try Data(contentsOf: URL(fileURLWithPath: arguments[1])),
        unixMode: regularMode
      ),
    ]
  case "traversal":
    return [
      ZIPEntry(path: "Safe/part.m4a", data: Data("safe".utf8), unixMode: regularMode),
      ZIPEntry(path: "../escaped.m4a", data: Data("escape".utf8), unixMode: regularMode),
      ZIPEntry(path: "/absolute.m4a", data: Data("absolute".utf8), unixMode: regularMode),
    ]
  case "symlink":
    return [
      ZIPEntry(path: "Safe/part.m4a", data: Data("safe".utf8), unixMode: regularMode),
      ZIPEntry(
        path: "Safe/linked.m4a",
        data: Data("../../outside.m4a".utf8),
        unixMode: 0o120777
      ),
    ]
  case "count":
    return (1...33).map { index in
      ZIPEntry(
        path: String(format: "Count Limit/Part %02d.txt", index),
        data: Data("x".utf8),
        unixMode: regularMode
      )
    }
  case "size":
    return [
      ZIPEntry(
        path: "Size Limit/oversized.bin",
        data: Data(repeating: 0x53, count: 131_073),
        unixMode: regularMode
      )
    ]
  default:
    throw ZIPFixtureError.invalidMode
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments.count >= 2 else { throw ZIPFixtureError.invalidArguments }
  let mode = arguments[0]
  let output = URL(fileURLWithPath: arguments[1])
  try writeArchive(entries: entries(for: mode, arguments: Array(arguments.dropFirst(2))), to: output)
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(2)
}
