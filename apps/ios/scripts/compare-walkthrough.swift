import CoreGraphics
import Darwin
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
  case comparisonsFailed(Int)

  var errorDescription: String? {
    switch self {
    case .usage:
      "usage: compare-walkthrough.swift <baseline-directory> <actual-directory> [diagnostics-directory]"
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
      "Screenshot \(name) differs by \(pixelCount) pixels beyond the 8/255 channel allowance."
    case .comparisonsFailed(let count):
      "\(count) screenshot comparison(s) failed."
    }
  }
}

func writePNG(_ image: CanonicalImage, to url: URL) throws {
  guard
    let provider = CGDataProvider(data: image.pixels as CFData),
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let cgImage = CGImage(
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: image.width * 4,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ),
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, "public.png" as CFString, 1, nil)
  else {
    throw ComparisonError.imageUnreadable(url.path)
  }
  CGImageDestinationAddImage(destination, cgImage, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw ComparisonError.imageUnreadable(url.path)
  }
}

func differenceImage(
  expected: CanonicalImage,
  actual: CanonicalImage,
  allowedChannelDelta: UInt8
) -> CanonicalImage {
  var output = Data(count: expected.pixels.count)
  expected.pixels.withUnsafeBytes { expectedBytes in
    actual.pixels.withUnsafeBytes { actualBytes in
      output.withUnsafeMutableBytes { outputBytes in
        guard
          let expectedBase = expectedBytes.bindMemory(to: UInt8.self).baseAddress,
          let actualBase = actualBytes.bindMemory(to: UInt8.self).baseAddress,
          let outputBase = outputBytes.bindMemory(to: UInt8.self).baseAddress
        else { return }
        for offset in stride(from: 0, to: expected.pixels.count, by: 4) {
          var maximumDelta: UInt8 = 0
          for channel in 0..<4 {
            let expectedValue = expectedBase[offset + channel]
            let actualValue = actualBase[offset + channel]
            let delta = expectedValue > actualValue
              ? expectedValue - actualValue
              : actualValue - expectedValue
            maximumDelta = max(maximumDelta, delta)
          }
          if maximumDelta > allowedChannelDelta {
            outputBase[offset] = 255
            outputBase[offset + 1] = 0
            outputBase[offset + 2] = 0
          } else {
            let luminance = UInt16(expectedBase[offset]) + UInt16(expectedBase[offset + 1])
              + UInt16(expectedBase[offset + 2])
            let context = UInt8(min(245, 190 + Int(luminance / 15)))
            outputBase[offset] = context
            outputBase[offset + 1] = context
            outputBase[offset + 2] = context
          }
          outputBase[offset + 3] = 255
        }
      }
    }
  }
  return CanonicalImage(width: expected.width, height: expected.height, pixels: output)
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

struct PixelDifference {
  let count: Int
  let toleratedCount: Int
  let bounds: CGRect?
  let maximumChannelDelta: UInt8
}

func pixelDifference(
  _ expected: Data,
  _ actual: Data,
  width: Int,
  allowedChannelDelta: UInt8
) -> PixelDifference {
  expected.withUnsafeBytes { expectedBytes in
    actual.withUnsafeBytes { actualBytes in
      guard
        let expectedBase = expectedBytes.bindMemory(to: UInt8.self).baseAddress,
        let actualBase = actualBytes.bindMemory(to: UInt8.self).baseAddress
      else {
        return PixelDifference(
          count: 0, toleratedCount: 0, bounds: nil, maximumChannelDelta: 0)
      }

      var count = 0
      var toleratedCount = 0
      var minimumX = width
      var minimumY = expected.count / 4 / width
      var maximumX = -1
      var maximumY = -1
      var maximumChannelDelta: UInt8 = 0
      for offset in stride(from: 0, to: expected.count, by: 4) {
        var pixelMaximumChannelDelta: UInt8 = 0
        for channel in 0..<4 {
          let expectedValue = expectedBase[offset + channel]
          let actualValue = actualBase[offset + channel]
          let delta = expectedValue > actualValue
            ? expectedValue - actualValue
            : actualValue - expectedValue
          pixelMaximumChannelDelta = max(pixelMaximumChannelDelta, delta)
        }
        maximumChannelDelta = max(maximumChannelDelta, pixelMaximumChannelDelta)

        if pixelMaximumChannelDelta > allowedChannelDelta {
          count += 1
          let pixel = offset / 4
          let x = pixel % width
          let y = pixel / width
          minimumX = min(minimumX, x)
          minimumY = min(minimumY, y)
          maximumX = max(maximumX, x)
          maximumY = max(maximumY, y)
        } else if pixelMaximumChannelDelta > 0 {
          toleratedCount += 1
        }
      }
      let bounds = count == 0
        ? nil
        : CGRect(
          x: minimumX,
          y: minimumY,
          width: maximumX - minimumX + 1,
          height: maximumY - minimumY + 1
        )
      return PixelDifference(
        count: count,
        toleratedCount: toleratedCount,
        bounds: bounds,
        maximumChannelDelta: maximumChannelDelta
      )
    }
  }
}

func compareWalkthrough() throws {
  guard (3...4).contains(CommandLine.arguments.count) else {
    throw ComparisonError.usage
  }

  let baselineDirectory = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
  let actualDirectory = URL(filePath: CommandLine.arguments[2], directoryHint: .isDirectory)
  let diagnosticsDirectory = CommandLine.arguments.count == 4
    ? URL(filePath: CommandLine.arguments[3], directoryHint: .isDirectory)
    : nil
  if let diagnosticsDirectory {
    try FileManager.default.createDirectory(
      at: diagnosticsDirectory,
      withIntermediateDirectories: true
    )
  }

  let baselineNames = try pngNames(in: baselineDirectory)
  let actualNames = try pngNames(in: actualDirectory)
  guard !baselineNames.isEmpty else {
    throw ComparisonError.noImages(baselineDirectory.path)
  }
  guard baselineNames == actualNames else {
    throw ComparisonError.fileSetDifference(expected: baselineNames, actual: actualNames)
  }

  let allowedChannelDelta: UInt8 = 8
  var summaries: [[String: Any]] = []
  var failureCount = 0
  for name in baselineNames {
    let expectedURL = baselineDirectory.appending(path: name)
    let actualURL = actualDirectory.appending(path: name)
    let expected = try canonicalImage(at: expectedURL)
    let actual = try canonicalImage(at: actualURL)
    guard expected.width == actual.width, expected.height == actual.height else {
      failureCount += 1
      let message = ComparisonError.dimensionDifference(
        name,
        expected: CGSize(width: CGFloat(expected.width), height: CGFloat(expected.height)),
        actual: CGSize(width: CGFloat(actual.width), height: CGFloat(actual.height))
      ).localizedDescription
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      summaries.append([
        "name": name,
        "result": "dimension-difference",
        "expectedWidth": expected.width,
        "expectedHeight": expected.height,
        "actualWidth": actual.width,
        "actualHeight": actual.height,
      ])
      if let diagnosticsDirectory {
        try FileManager.default.copyItem(
          at: expectedURL,
          to: diagnosticsDirectory.appending(path: "\(name.dropLast(4))-expected.png")
        )
        try FileManager.default.copyItem(
          at: actualURL,
          to: diagnosticsDirectory.appending(path: "\(name.dropLast(4))-actual.png")
        )
      }
      continue
    }

    let difference = pixelDifference(
      expected.pixels,
      actual.pixels,
      width: expected.width,
      allowedChannelDelta: allowedChannelDelta
    )
    if difference.count > 0 {
      failureCount += 1
      let boundsDescription = difference.bounds.map(String.init(describing:)) ?? "none"
      let message =
        "Screenshot \(name) differs by \(difference.count) pixels beyond 8/255; "
          + "bounds=\(boundsDescription), maximumChannelDelta=\(difference.maximumChannelDelta).\n"
      FileHandle.standardError.write(Data(message.utf8))
      summaries.append([
        "name": name,
        "result": "pixel-difference",
        "pixelCount": difference.count,
        "toleratedPixelCount": difference.toleratedCount,
        "bounds": boundsDescription,
        "maximumChannelDelta": difference.maximumChannelDelta,
      ])
      if let diagnosticsDirectory {
        let stem = String(name.dropLast(4))
        try FileManager.default.copyItem(
          at: expectedURL,
          to: diagnosticsDirectory.appending(path: "\(stem)-expected.png")
        )
        try FileManager.default.copyItem(
          at: actualURL,
          to: diagnosticsDirectory.appending(path: "\(stem)-actual.png")
        )
        try writePNG(
          differenceImage(
            expected: expected,
            actual: actual,
            allowedChannelDelta: allowedChannelDelta
          ),
          to: diagnosticsDirectory.appending(path: "\(stem)-diff.png")
        )
      }
      continue
    }

    summaries.append([
      "name": name,
      "result": difference.toleratedCount == 0 ? "exact" : "canonical",
      "toleratedPixelCount": difference.toleratedCount,
      "maximumChannelDelta": difference.maximumChannelDelta,
    ])
    if difference.toleratedCount == 0 {
      print("Exact pixel match: \(name)")
    } else {
      print(
        "Canonical pixel match: \(name) "
          + "(\(difference.toleratedCount) pixels within 8/255 channel allowance)"
      )
    }
  }

  if let diagnosticsDirectory {
    let summary: [String: Any] = [
      "allowedChannelDelta": allowedChannelDelta,
      "failureCount": failureCount,
      "images": summaries,
    ]
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: diagnosticsDirectory.appending(path: "summary.json"), options: .atomic)
  }
  if failureCount > 0 {
    throw ComparisonError.comparisonsFailed(failureCount)
  }
}

do {
  try compareWalkthrough()
} catch {
  let message = "E2E screenshot comparison failed: \(error.localizedDescription)\n"
  FileHandle.standardError.write(Data(message.utf8))
  exit(1)
}
