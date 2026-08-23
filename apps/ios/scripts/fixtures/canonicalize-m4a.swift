#!/usr/bin/env swift

import Foundation

private enum CanonicalizationError: Error, CustomStringConvertible {
  case invalidArguments
  case malformedContainer
  case missingTimestampBoxes

  var description: String {
    switch self {
    case .invalidArguments:
      return "usage: canonicalize-m4a.swift INPUT.m4a"
    case .malformedContainer:
      return "malformed M4A container"
    case .missingTimestampBoxes:
      return "M4A timestamp boxes were not found"
    }
  }
}

private func uint32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
  UInt32(bytes[offset]) << 24
    | UInt32(bytes[offset + 1]) << 16
    | UInt32(bytes[offset + 2]) << 8
    | UInt32(bytes[offset + 3])
}

private func boxType(_ bytes: [UInt8], at offset: Int) -> String {
  String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
}

private func zeroTimestampFields(
  in bytes: inout [UInt8],
  payloadOffset: Int,
  boxEnd: Int
) throws {
  guard payloadOffset < boxEnd else {
    throw CanonicalizationError.malformedContainer
  }
  let version = bytes[payloadOffset]
  let creationOffset = payloadOffset + 4
  let timestampByteCount: Int
  switch version {
  case 0:
    timestampByteCount = 4
  case 1:
    timestampByteCount = 8
  default:
    throw CanonicalizationError.malformedContainer
  }
  let fieldsEnd = creationOffset + timestampByteCount * 2
  guard fieldsEnd <= boxEnd else {
    throw CanonicalizationError.malformedContainer
  }
  for index in creationOffset..<fieldsEnd {
    bytes[index] = 0
  }
}

private func canonicalizeBoxes(
  in bytes: inout [UInt8],
  range: Range<Int>,
  timestampBoxCount: inout Int
) throws {
  let containerTypes: Set<String> = ["moov", "trak", "mdia"]
  var offset = range.lowerBound

  while offset < range.upperBound {
    guard offset + 8 <= range.upperBound else {
      throw CanonicalizationError.malformedContainer
    }
    let declaredSize = Int(uint32BE(bytes, at: offset))
    guard declaredSize >= 8, offset + declaredSize <= range.upperBound else {
      throw CanonicalizationError.malformedContainer
    }
    let type = boxType(bytes, at: offset)
    let payloadOffset = offset + 8
    let end = offset + declaredSize

    if type == "mvhd" || type == "tkhd" || type == "mdhd" {
      try zeroTimestampFields(in: &bytes, payloadOffset: payloadOffset, boxEnd: end)
      timestampBoxCount += 1
    } else if containerTypes.contains(type) {
      try canonicalizeBoxes(
        in: &bytes,
        range: payloadOffset..<end,
        timestampBoxCount: &timestampBoxCount
      )
    }
    offset = end
  }
}

private func canonicalize() throws {
  guard CommandLine.arguments.count == 2 else {
    throw CanonicalizationError.invalidArguments
  }
  let url = URL(fileURLWithPath: CommandLine.arguments[1])
  var bytes = [UInt8](try Data(contentsOf: url))
  var timestampBoxCount = 0
  try canonicalizeBoxes(
    in: &bytes,
    range: 0..<bytes.count,
    timestampBoxCount: &timestampBoxCount
  )
  guard timestampBoxCount >= 3 else {
    throw CanonicalizationError.missingTimestampBoxes
  }
  try Data(bytes).write(to: url, options: .atomic)
}

do {
  try canonicalize()
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(2)
}
