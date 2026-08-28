#!/usr/bin/env swift

import AVFoundation
import CoreImage
import Foundation
import ImageIO

private enum FixtureError: Error {
  case usage
  case buffer
  case append
  case image
  case wrongPixel
}

private func pixelBuffer(pool: CVPixelBufferPool, blue: Bool) throws -> CVPixelBuffer {
  var optional: CVPixelBuffer?
  guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess,
    let buffer = optional
  else { throw FixtureError.buffer }
  CVPixelBufferLockBaseAddress(buffer, [])
  defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
  guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw FixtureError.buffer }
  let bytes = base.assumingMemoryBound(to: UInt8.self)
  for row in 0..<CVPixelBufferGetHeight(buffer) {
    for column in 0..<CVPixelBufferGetWidth(buffer) {
      let offset = row * CVPixelBufferGetBytesPerRow(buffer) + column * 4
      bytes[offset] = blue ? 0xFF : 0x00
      bytes[offset + 1] = 0x00
      bytes[offset + 2] = blue ? 0x00 : 0xFF
      bytes[offset + 3] = 0xFF
    }
  }
  return buffer
}

private func generate(_ path: String) async throws {
  let url = URL(filePath: path)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 16,
      AVVideoHeightKey: 16,
    ]
  )
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 16,
      kCVPixelBufferHeightKey as String: 16,
    ]
  )
  guard writer.canAdd(input) else { throw FixtureError.append }
  writer.add(input)
  guard writer.startWriting() else { throw writer.error ?? FixtureError.append }
  writer.startSession(atSourceTime: .zero)
  guard let pool = adaptor.pixelBufferPool,
    adaptor.append(try pixelBuffer(pool: pool, blue: false), withPresentationTime: .zero),
    adaptor.append(
      try pixelBuffer(pool: pool, blue: true),
      withPresentationTime: CMTime(value: 1, timescale: 1)
    )
  else { throw writer.error ?? FixtureError.append }
  writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
  input.markAsFinished()
  await writer.finishWriting()
  guard writer.status == .completed else { throw writer.error ?? FixtureError.append }
}

private func verifyBlue(_ path: String) throws {
  let url = URL(filePath: path)
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    image.width == 16, image.height == 16
  else { throw FixtureError.image }
  let context = CIContext(options: [.cacheIntermediates: false])
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  var pixel = [UInt8](repeating: 0, count: 4)
  context.render(
    CIImage(cgImage: image),
    toBitmap: &pixel,
    rowBytes: 4,
    bounds: CGRect(x: 8, y: 8, width: 1, height: 1),
    format: .RGBA8,
    colorSpace: colorSpace
  )
  guard pixel[2] > 200, pixel[0] < 40, pixel[1] < 40 else {
    throw FixtureError.wrongPixel
  }
}

guard CommandLine.arguments.count == 3 else { throw FixtureError.usage }
switch CommandLine.arguments[1] {
case "generate": try await generate(CommandLine.arguments[2])
case "verify-blue": try verifyBlue(CommandLine.arguments[2])
default: throw FixtureError.usage
}
