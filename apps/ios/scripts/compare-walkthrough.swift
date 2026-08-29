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
  case invalidPolicy(String)
  case comparisonsFailed(Int)

  var errorDescription: String? {
    switch self {
    case .usage:
      "usage: compare-walkthrough.swift <baseline-directory> <actual-directory> [diagnostics-directory [--retain-all-evidence]]"
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
    case .invalidPolicy(let reason):
      "Screenshot comparison policy is invalid: \(reason)"
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
  allowedChannelDelta: UInt8,
  qualifiedRegions: [QualifiedSystemRegion]
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
            let delta =
              expectedValue > actualValue
              ? expectedValue - actualValue
              : actualValue - expectedValue
            maximumDelta = max(maximumDelta, delta)
          }
          if maximumDelta > allowedChannelDelta {
            let pixel = offset / 4
            let x = pixel % expected.width
            let y = pixel / expected.width
            let isQualified = qualifiedRegions.contains { $0.contains(x: x, y: y) }
            outputBase[offset] = isQualified ? 35 : 255
            outputBase[offset + 1] = isQualified ? 120 : 0
            outputBase[offset + 2] = isQualified ? 255 : 0
          } else {
            let luminance =
              UInt16(expectedBase[offset]) + UInt16(expectedBase[offset + 1])
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

func copyEvidence(from source: URL, to destination: URL) throws {
  if FileManager.default.fileExists(atPath: destination.path) {
    try FileManager.default.removeItem(at: destination)
  }
  try FileManager.default.copyItem(at: source, to: destination)
}

func writeEvidencePlaceholder(_ message: String, to destination: URL) throws {
  try Data((message + "\n").utf8).write(to: destination, options: .atomic)
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
  let qualifiedSystemPixelCount: Int
  let bounds: CGRect?
  let maximumChannelDelta: UInt8
}

struct QualifiedSystemRegion: Codable {
  let x: Int
  let y: Int
  let width: Int
  let height: Int
  let reason: String

  func contains(x candidateX: Int, y candidateY: Int) -> Bool {
    candidateX >= x && candidateX < x + width
      && candidateY >= y && candidateY < y + height
  }
}

struct ComparisonPolicy: Codable {
  let schemaVersion: Int
  let qualifiedSystemRegions: [String: [QualifiedSystemRegion]]

  static let exact = ComparisonPolicy(schemaVersion: 1, qualifiedSystemRegions: [:])
}

func comparisonPolicy(in baselineDirectory: URL) throws -> ComparisonPolicy {
  let policyURL = baselineDirectory.appending(path: "comparison-policy.json")
  guard FileManager.default.fileExists(atPath: policyURL.path) else { return .exact }
  do {
    let policy = try JSONDecoder().decode(
      ComparisonPolicy.self,
      from: Data(contentsOf: policyURL)
    )
    guard policy.schemaVersion == 1 else {
      throw ComparisonError.invalidPolicy(
        "unsupported schemaVersion \(policy.schemaVersion) in \(policyURL.path)"
      )
    }
    return policy
  } catch let error as ComparisonError {
    throw error
  } catch {
    throw ComparisonError.invalidPolicy("could not decode \(policyURL.path): \(error)")
  }
}

func pixelDifference(
  _ expected: Data,
  _ actual: Data,
  width: Int,
  allowedChannelDelta: UInt8,
  qualifiedRegions: [QualifiedSystemRegion]
) -> PixelDifference {
  expected.withUnsafeBytes { expectedBytes in
    actual.withUnsafeBytes { actualBytes in
      guard
        let expectedBase = expectedBytes.bindMemory(to: UInt8.self).baseAddress,
        let actualBase = actualBytes.bindMemory(to: UInt8.self).baseAddress
      else {
        return PixelDifference(
          count: 0, toleratedCount: 0, qualifiedSystemPixelCount: 0,
          bounds: nil, maximumChannelDelta: 0)
      }

      var count = 0
      var toleratedCount = 0
      var qualifiedSystemPixelCount = 0
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
          let delta =
            expectedValue > actualValue
            ? expectedValue - actualValue
            : actualValue - expectedValue
          pixelMaximumChannelDelta = max(pixelMaximumChannelDelta, delta)
        }
        maximumChannelDelta = max(maximumChannelDelta, pixelMaximumChannelDelta)

        if pixelMaximumChannelDelta > allowedChannelDelta {
          let pixel = offset / 4
          let x = pixel % width
          let y = pixel / width
          if qualifiedRegions.contains(where: { $0.contains(x: x, y: y) }) {
            qualifiedSystemPixelCount += 1
            continue
          }
          count += 1
          minimumX = min(minimumX, x)
          minimumY = min(minimumY, y)
          maximumX = max(maximumX, x)
          maximumY = max(maximumY, y)
        } else if pixelMaximumChannelDelta > 0 {
          toleratedCount += 1
        }
      }
      let bounds =
        count == 0
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
        qualifiedSystemPixelCount: qualifiedSystemPixelCount,
        bounds: bounds,
        maximumChannelDelta: maximumChannelDelta
      )
    }
  }
}

func compareWalkthrough() throws {
  guard (3...5).contains(CommandLine.arguments.count) else {
    throw ComparisonError.usage
  }
  if CommandLine.arguments.count == 5,
    CommandLine.arguments[4] != "--retain-all-evidence"
  {
    throw ComparisonError.usage
  }

  let baselineDirectory = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
  let actualDirectory = URL(filePath: CommandLine.arguments[2], directoryHint: .isDirectory)
  let diagnosticsDirectory =
    CommandLine.arguments.count >= 4
    ? URL(filePath: CommandLine.arguments[3], directoryHint: .isDirectory)
    : nil
  let retainAllEvidence = CommandLine.arguments.count == 5
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
  let policy = try comparisonPolicy(in: baselineDirectory)
  let unknownPolicyNames = Set(policy.qualifiedSystemRegions.keys).subtracting(baselineNames)
  guard unknownPolicyNames.isEmpty else {
    throw ComparisonError.invalidPolicy(
      "qualified regions name screenshots outside the reviewed baseline: \(unknownPolicyNames.sorted())"
    )
  }

  let allowedChannelDelta: UInt8 = 8
  var summaries: [[String: Any]] = []
  var failureCount = 0
  let allNames = Set(baselineNames).union(actualNames).sorted()
  for name in allNames {
    let expectedURL = baselineDirectory.appending(path: name)
    let actualURL = actualDirectory.appending(path: name)
    let expectedExists = baselineNames.contains(name)
    let actualExists = actualNames.contains(name)
    let stem = String(name.dropLast(4))

    if !actualExists {
      failureCount += 1
      let message = "Expected screenshot \(name) has no actual capture."
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      var summary: [String: Any] = [
        "name": name,
        "result": "missing-actual",
      ]
      if let diagnosticsDirectory {
        let expectedName = "\(stem)-expected.png"
        let actualName = "\(stem)-actual-missing.txt"
        let diffName = "\(stem)-diff-unavailable.txt"
        try copyEvidence(
          from: expectedURL,
          to: diagnosticsDirectory.appending(path: expectedName)
        )
        try writeEvidencePlaceholder(message, to: diagnosticsDirectory.appending(path: actualName))
        try writeEvidencePlaceholder(
          "No diff can be rendered because the actual screenshot is missing.",
          to: diagnosticsDirectory.appending(path: diffName)
        )
        summary["expectedArtifact"] = expectedName
        summary["actualArtifact"] = actualName
        summary["diffArtifact"] = diffName
      }
      summaries.append(summary)
      continue
    }

    if !expectedExists {
      failureCount += 1
      let message = "Unexpected actual screenshot \(name) has no reviewed baseline."
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      var summary: [String: Any] = [
        "name": name,
        "result": "unexpected-actual",
      ]
      if let diagnosticsDirectory {
        let expectedName = "\(stem)-expected-missing.txt"
        let actualName = "\(stem)-actual.png"
        let diffName = "\(stem)-diff-unavailable.txt"
        try writeEvidencePlaceholder(
          message, to: diagnosticsDirectory.appending(path: expectedName))
        try copyEvidence(
          from: actualURL,
          to: diagnosticsDirectory.appending(path: actualName)
        )
        try writeEvidencePlaceholder(
          "No diff can be rendered because the reviewed screenshot is missing.",
          to: diagnosticsDirectory.appending(path: diffName)
        )
        summary["expectedArtifact"] = expectedName
        summary["actualArtifact"] = actualName
        summary["diffArtifact"] = diffName
      }
      summaries.append(summary)
      continue
    }

    var expected: CanonicalImage?
    var actual: CanonicalImage?
    var decodeFailures: [String] = []
    do {
      expected = try canonicalImage(at: expectedURL)
    } catch {
      decodeFailures.append("reviewed image: \(error.localizedDescription)")
    }
    do {
      actual = try canonicalImage(at: actualURL)
    } catch {
      decodeFailures.append("actual image: \(error.localizedDescription)")
    }
    if !decodeFailures.isEmpty {
      failureCount += 1
      let message =
        "Screenshot \(name) could not be decoded (\(decodeFailures.joined(separator: "; ")))."
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      var summary: [String: Any] = [
        "name": name,
        "result": "image-unreadable",
        "errors": decodeFailures,
      ]
      if let diagnosticsDirectory {
        let expectedName = "\(stem)-expected.png"
        let actualName = "\(stem)-actual.png"
        let diffName = "\(stem)-diff-unavailable.txt"
        try copyEvidence(
          from: expectedURL,
          to: diagnosticsDirectory.appending(path: expectedName)
        )
        try copyEvidence(
          from: actualURL,
          to: diagnosticsDirectory.appending(path: actualName)
        )
        try writeEvidencePlaceholder(
          "No pixel diff can be rendered because one or both screenshot files could not be decoded.",
          to: diagnosticsDirectory.appending(path: diffName)
        )
        summary["expectedArtifact"] = expectedName
        summary["actualArtifact"] = actualName
        summary["diffArtifact"] = diffName
      }
      summaries.append(summary)
      continue
    }
    guard let expected, let actual else {
      throw ComparisonError.imageUnreadable(name)
    }
    guard expected.width == actual.width, expected.height == actual.height else {
      failureCount += 1
      let message = ComparisonError.dimensionDifference(
        name,
        expected: CGSize(width: CGFloat(expected.width), height: CGFloat(expected.height)),
        actual: CGSize(width: CGFloat(actual.width), height: CGFloat(actual.height))
      ).localizedDescription
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      var summary: [String: Any] = [
        "name": name,
        "result": "dimension-difference",
        "expectedWidth": expected.width,
        "expectedHeight": expected.height,
        "actualWidth": actual.width,
        "actualHeight": actual.height,
      ]
      if let diagnosticsDirectory {
        let expectedName = "\(stem)-expected.png"
        let actualName = "\(stem)-actual.png"
        let diffName = "\(stem)-diff-unavailable.txt"
        try copyEvidence(
          from: expectedURL,
          to: diagnosticsDirectory.appending(path: expectedName)
        )
        try copyEvidence(
          from: actualURL,
          to: diagnosticsDirectory.appending(path: actualName)
        )
        try writeEvidencePlaceholder(
          "No pixel diff can be rendered for images with different dimensions: expected \(expected.width)x\(expected.height), actual \(actual.width)x\(actual.height).",
          to: diagnosticsDirectory.appending(path: diffName)
        )
        summary["expectedArtifact"] = expectedName
        summary["actualArtifact"] = actualName
        summary["diffArtifact"] = diffName
      }
      summaries.append(summary)
      continue
    }

    let qualifiedRegions = policy.qualifiedSystemRegions[name] ?? []
    for region in qualifiedRegions {
      guard
        region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
        region.x + region.width <= expected.width,
        region.y + region.height <= expected.height,
        !region.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw ComparisonError.invalidPolicy(
          "\(name) has an empty, out-of-bounds, or unexplained qualified system region"
        )
      }
    }

    let difference = pixelDifference(
      expected.pixels,
      actual.pixels,
      width: expected.width,
      allowedChannelDelta: allowedChannelDelta,
      qualifiedRegions: qualifiedRegions
    )
    if difference.count > 0 {
      failureCount += 1
      let boundsDescription = difference.bounds.map(String.init(describing:)) ?? "none"
      let message =
        "Screenshot \(name) differs by \(difference.count) pixels beyond 8/255; "
        + "bounds=\(boundsDescription), maximumChannelDelta=\(difference.maximumChannelDelta).\n"
      FileHandle.standardError.write(Data(message.utf8))
      var summary: [String: Any] = [
        "name": name,
        "result": "pixel-difference",
        "pixelCount": difference.count,
        "toleratedPixelCount": difference.toleratedCount,
        "qualifiedSystemPixelCount": difference.qualifiedSystemPixelCount,
        "bounds": boundsDescription,
        "maximumChannelDelta": difference.maximumChannelDelta,
      ]
      if let diagnosticsDirectory {
        let expectedName = "\(stem)-expected.png"
        let actualName = "\(stem)-actual.png"
        let diffName = "\(stem)-diff.png"
        try copyEvidence(
          from: expectedURL,
          to: diagnosticsDirectory.appending(path: expectedName)
        )
        try copyEvidence(
          from: actualURL,
          to: diagnosticsDirectory.appending(path: actualName)
        )
        try writePNG(
          differenceImage(
            expected: expected,
            actual: actual,
            allowedChannelDelta: allowedChannelDelta,
            qualifiedRegions: qualifiedRegions
          ),
          to: diagnosticsDirectory.appending(path: diffName)
        )
        summary["expectedArtifact"] = expectedName
        summary["actualArtifact"] = actualName
        summary["diffArtifact"] = diffName
      }
      summaries.append(summary)
      continue
    }

    var summary: [String: Any] = [
      "name": name,
      "result": difference.toleratedCount == 0 && difference.qualifiedSystemPixelCount == 0
        ? "exact" : "canonical",
      "toleratedPixelCount": difference.toleratedCount,
      "qualifiedSystemPixelCount": difference.qualifiedSystemPixelCount,
      "maximumChannelDelta": difference.maximumChannelDelta,
    ]
    if retainAllEvidence, let diagnosticsDirectory {
      let expectedName = "\(stem)-expected.png"
      let actualName = "\(stem)-actual.png"
      try copyEvidence(
        from: expectedURL,
        to: diagnosticsDirectory.appending(path: expectedName)
      )
      try copyEvidence(
        from: actualURL,
        to: diagnosticsDirectory.appending(path: actualName)
      )
      summary["expectedArtifact"] = expectedName
      summary["actualArtifact"] = actualName
      summary["diffArtifact"] = "not-required"
    }
    summaries.append(summary)
    if difference.toleratedCount == 0 && difference.qualifiedSystemPixelCount == 0 {
      print("Exact pixel match: \(name)")
    } else {
      print(
        "Canonical pixel match: \(name) "
          + "(\(difference.toleratedCount) pixels within 8/255 channel allowance, "
          + "\(difference.qualifiedSystemPixelCount) pixels confined to reviewed system regions)"
      )
    }
  }

  if let diagnosticsDirectory {
    let summary: [String: Any] = [
      "allowedChannelDelta": allowedChannelDelta,
      "failureCount": failureCount,
      "fileSetMatches": baselineNames == actualNames,
      "expectedNames": baselineNames,
      "actualNames": actualNames,
      "images": summaries,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
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
