#!/usr/bin/env xcrun swift
import Foundation

private enum GeneratorError: Error { case invalidArguments }
private struct RGB { var r: UInt8; var g: UInt8; var b: UInt8 }

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
  var a: UInt32 = 1
  var b: UInt32 = 0
  for byte in data {
    a = (a + UInt32(byte)) % 65_521
    b = (b + a) % 65_521
  }
  return b << 16 | a
}

private func appendBigEndian(_ value: UInt32, to data: inout Data) {
  data.append(UInt8((value >> 24) & 0xFF))
  data.append(UInt8((value >> 16) & 0xFF))
  data.append(UInt8((value >> 8) & 0xFF))
  data.append(UInt8(value & 0xFF))
}

private func appendChunk(_ type: String, _ payload: Data, to png: inout Data) {
  appendBigEndian(UInt32(payload.count), to: &png)
  let typeData = Data(type.utf8)
  png.append(typeData)
  png.append(payload)
  appendBigEndian(crc32(typeData + payload), to: &png)
}

private func storedZlib(_ raw: Data) -> Data {
  precondition(raw.count <= Int(UInt16.max))
  var data = Data([0x78, 0x01, 0x01])
  let length = UInt16(raw.count)
  let inverse = ~length
  data.append(contentsOf: [
    UInt8(length & 0xFF), UInt8(length >> 8),
    UInt8(inverse & 0xFF), UInt8(inverse >> 8),
  ])
  data.append(raw)
  appendBigEndian(adler32(raw), to: &data)
  return data
}

private func makeCover(index: Int, primary: RGB, accent: RGB) -> Data {
  let size = 32
  var pixels = Data()
  for y in 0..<size {
    pixels.append(0)
    for x in 0..<size {
      let frame = x < 3 || x >= 29 || y < 3 || y >= 29
      let stripe = (x + index * y) % (6 + index) < 2
      let disc = (x - 16) * (x - 16) + (y - 16) * (y - 16) < 20 + index * 8
      let color = frame || stripe || disc ? accent : primary
      pixels.append(contentsOf: [color.r, color.g, color.b])
    }
  }
  var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
  var header = Data()
  appendBigEndian(32, to: &header)
  appendBigEndian(32, to: &header)
  header.append(contentsOf: [8, 2, 0, 0, 0])
  appendChunk("IHDR", header, to: &png)
  appendChunk("IDAT", storedZlib(pixels), to: &png)
  appendChunk("IEND", Data(), to: &png)
  return png
}

private let palettes: [(RGB, RGB)] = [
  (RGB(r: 37, g: 62, b: 75), RGB(r: 240, g: 183, b: 79)),
  (RGB(r: 43, g: 75, b: 111), RGB(r: 211, g: 229, b: 220)),
  (RGB(r: 67, g: 91, b: 55), RGB(r: 231, g: 199, b: 119)),
  (RGB(r: 99, g: 52, b: 61), RGB(r: 236, g: 211, b: 174)),
  (RGB(r: 69, g: 55, b: 93), RGB(r: 204, g: 186, b: 226)),
]

guard CommandLine.arguments.count == palettes.count + 1 else {
  throw GeneratorError.invalidArguments
}
for (offset, palette) in palettes.enumerated() {
  try makeCover(index: offset + 1, primary: palette.0, accent: palette.1).write(
    to: URL(filePath: CommandLine.arguments[offset + 1]),
    options: .withoutOverwriting
  )
}
