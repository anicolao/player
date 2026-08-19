#!/usr/bin/env xcrun swift
import Foundation

private enum CoverGeneratorError: Error {
  case invalidArguments
}

private struct RGB {
  var red: UInt8
  var green: UInt8
  var blue: UInt8
}

private func crc32(_ data: Data) -> UInt32 {
  var value: UInt32 = 0xFFFF_FFFF
  for byte in data {
    value ^= UInt32(byte)
    for _ in 0..<8 {
      value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
    }
  }
  return value ^ 0xFFFF_FFFF
}

private func adler32(_ data: Data) -> UInt32 {
  var first: UInt32 = 1
  var second: UInt32 = 0
  for byte in data {
    first = (first + UInt32(byte)) % 65_521
    second = (second + first) % 65_521
  }
  return second << 16 | first
}

private func appendBigEndian(_ value: UInt32, to data: inout Data) {
  data.append(UInt8((value >> 24) & 0xFF))
  data.append(UInt8((value >> 16) & 0xFF))
  data.append(UInt8((value >> 8) & 0xFF))
  data.append(UInt8(value & 0xFF))
}

private func appendChunk(_ type: String, payload: Data, to png: inout Data) {
  appendBigEndian(UInt32(payload.count), to: &png)
  let typeData = Data(type.utf8)
  png.append(typeData)
  png.append(payload)
  appendBigEndian(crc32(typeData + payload), to: &png)
}

private func zlibStored(_ raw: Data) -> Data {
  precondition(raw.count <= Int(UInt16.max))
  var encoded = Data([0x78, 0x01, 0x01])
  let length = UInt16(raw.count)
  let inverted = ~length
  encoded.append(UInt8(length & 0xFF))
  encoded.append(UInt8(length >> 8))
  encoded.append(UInt8(inverted & 0xFF))
  encoded.append(UInt8(inverted >> 8))
  encoded.append(raw)
  appendBigEndian(adler32(raw), to: &encoded)
  return encoded
}

private func coverPixels(primary: RGB, accent: RGB, inverted: Bool) -> Data {
  let size = 32
  var pixels = Data()
  pixels.reserveCapacity(size * (1 + size * 3))
  for y in 0..<size {
    pixels.append(0)
    for x in 0..<size {
      let border = x < 3 || x >= size - 3 || y < 3 || y >= size - 3
      let diagonal = inverted ? (x + y) % 11 < 4 : abs(x - y) < 4
      let circle = (x - 16) * (x - 16) + (y - 16) * (y - 16) < 64
      let color = border || diagonal || circle ? accent : primary
      pixels.append(contentsOf: [color.red, color.green, color.blue])
    }
  }
  return pixels
}

private func makePNG(primary: RGB, accent: RGB, inverted: Bool) -> Data {
  var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
  var header = Data()
  appendBigEndian(32, to: &header)
  appendBigEndian(32, to: &header)
  header.append(contentsOf: [8, 2, 0, 0, 0])
  appendChunk("IHDR", payload: header, to: &png)
  appendChunk(
    "IDAT",
    payload: zlibStored(coverPixels(primary: primary, accent: accent, inverted: inverted)),
    to: &png
  )
  appendChunk("IEND", payload: Data(), to: &png)
  return png
}

guard CommandLine.arguments.count == 3 else { throw CoverGeneratorError.invalidArguments }
let original = makePNG(
  primary: RGB(red: 26, green: 52, blue: 71),
  accent: RGB(red: 238, green: 190, blue: 80),
  inverted: false
)
let replacement = makePNG(
  primary: RGB(red: 176, green: 68, blue: 42),
  accent: RGB(red: 239, green: 226, blue: 188),
  inverted: true
)
try original.write(to: URL(filePath: CommandLine.arguments[1]), options: .withoutOverwriting)
try replacement.write(to: URL(filePath: CommandLine.arguments[2]), options: .withoutOverwriting)
