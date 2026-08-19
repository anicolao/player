#!/usr/bin/env swift

import Foundation

private enum FreeBoxError: Error, CustomStringConvertible {
  case invalidArguments
  case invalidMP4
  case invalidToken

  var description: String {
    switch self {
    case .invalidArguments: "usage: append-mp4-free-box.swift INPUT.m4a ASCII_TOKEN"
    case .invalidMP4: "input is not an expected MPEG-4 audio container"
    case .invalidToken: "token must be 1...64 printable ASCII bytes"
    }
  }
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
  data.append(UInt8((value >> 24) & 0xff))
  data.append(UInt8((value >> 16) & 0xff))
  data.append(UInt8((value >> 8) & 0xff))
  data.append(UInt8(value & 0xff))
}

private func appendFreeBox() throws {
  guard CommandLine.arguments.count == 3 else { throw FreeBoxError.invalidArguments }
  let url = URL(fileURLWithPath: CommandLine.arguments[1])
  let token = Array(CommandLine.arguments[2].utf8)
  guard (1...64).contains(token.count), token.allSatisfy({ (0x20...0x7e).contains($0) })
  else { throw FreeBoxError.invalidToken }

  var data = try Data(contentsOf: url)
  guard data.count >= 12, String(decoding: data[4..<8], as: UTF8.self) == "ftyp"
  else { throw FreeBoxError.invalidMP4 }

  appendUInt32BE(UInt32(8 + token.count), to: &data)
  data.append(contentsOf: "free".utf8)
  data.append(contentsOf: token)
  try data.write(to: url, options: .atomic)
}

do {
  try appendFreeBox()
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(2)
}
