import CoreGraphics
import Foundation
import ImageIO

enum ComparisonError: LocalizedError {
  case usage
  case directoryUnreadable(String)
  case noImages(String)
  case fileSetDifference(expected: [String], actual: [String])
  case imageUnreadable(String)
  case dimensionDifference(String, expected: CGSize, actual: CGSize)
  case pixelDifference(String, pixelCount: Int)

  var errorDescription: String? {
    switch self {
    case .usage:
      "usage: compare-walkthrough.swift <baseline-directory> <actual-directory>"
    case .directoryUnreadable(let path):
      "Could not read screenshot directory: \(path)"
    case .noImages(let path):
      "No PNG screenshots found in: \(path)"
    case .fileSetDifference(let expected, let actual):
      "Screenshot file sets differ. Expected \(expected); received \(actual)."
    case .imageUnreadable(let path):
      "Could not decode screenshot: \(path)"
    case .dimensionDifference(let name, let expected, let actual):
      "Screenshot \(name) dimensions differ: expected \(expected), received \(actual)."
    case .pixelDifference(let name, let pixelCount):
      "Screenshot \(name) differs by \(pixelCount) pixels (zero are allowed)."
    }
  }
}

struct CanonicalImage {
  let width: Int
  let height: Int
  let pixels: Data
}

func pngNames(in directory: URL) throws -> [String] {
  guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
    throw ComparisonError.directoryUnreadable(directory.path)
  }
  return names.filter { $0.hasSuffix(".png") }.sorted()
}

func canonicalImage(at url: URL) throws -> CanonicalImage {
  guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
  else {
    throw ComparisonError.imageUnreadable(url.path)
  }

  let bytesPerRow = image.width * 4
  var pixels = Data(count: bytesPerRow * image.height)
  let rendered = pixels.withUnsafeMutableBytes { buffer in
    guard
      let address = buffer.baseAddress,
      let context = CGContext(
        data: address,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return false
    }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return true
  }

  guard rendered else { throw ComparisonError.imageUnreadable(url.path) }
  return CanonicalImage(width: image.width, height: image.height, pixels: pixels)
}

func differingPixelCount(_ expected: Data, _ actual: Data) -> Int {
  expected.withUnsafeBytes { expectedBytes in
    actual.withUnsafeBytes { actualBytes in
      guard
        let expectedBase = expectedBytes.bindMemory(to: UInt8.self).baseAddress,
        let actualBase = actualBytes.bindMemory(to: UInt8.self).baseAddress
      else {
        return 0
      }

      var count = 0
      for offset in stride(from: 0, to: expected.count, by: 4) {
        if expectedBase[offset] != actualBase[offset]
          || expectedBase[offset + 1] != actualBase[offset + 1]
          || expectedBase[offset + 2] != actualBase[offset + 2]
          || expectedBase[offset + 3] != actualBase[offset + 3]
        {
          count += 1
        }
      }
      return count
    }
  }
}

guard CommandLine.arguments.count == 3 else {
  throw ComparisonError.usage
}

let baselineDirectory = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
let actualDirectory = URL(filePath: CommandLine.arguments[2], directoryHint: .isDirectory)
let baselineNames = try pngNames(in: baselineDirectory)
let actualNames = try pngNames(in: actualDirectory)

guard !baselineNames.isEmpty else {
  throw ComparisonError.noImages(baselineDirectory.path)
}

guard baselineNames == actualNames else {
  throw ComparisonError.fileSetDifference(expected: baselineNames, actual: actualNames)
}

for name in baselineNames {
  let expected = try canonicalImage(at: baselineDirectory.appending(path: name))
  let actual = try canonicalImage(at: actualDirectory.appending(path: name))
  guard expected.width == actual.width, expected.height == actual.height else {
    throw ComparisonError.dimensionDifference(
      name,
      expected: CGSize(width: CGFloat(expected.width), height: CGFloat(expected.height)),
      actual: CGSize(width: CGFloat(actual.width), height: CGFloat(actual.height))
    )
  }

  let difference = differingPixelCount(expected.pixels, actual.pixels)
  guard difference == 0 else {
    throw ComparisonError.pixelDifference(name, pixelCount: difference)
  }
  print("Exact pixel match: \(name)")
}
