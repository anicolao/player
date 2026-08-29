#!/usr/bin/env swift

import AVFoundation
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct AttachmentGroup: Decodable {
  let attachments: [ExportedAttachment]
  let testIdentifier: String
}

private struct ExportedAttachment: Decodable {
  let exportedFileName: String
  let suggestedHumanReadableName: String
  let timestamp: Double?
}

private struct Candidate {
  let attachment: ExportedAttachment
  let attachmentTimestamp: Double
  let testIdentifier: String
  let url: URL
}

private struct FailureScreenSource: Encodable {
  let schemaVersion = 1
  let artifact = "Diagnostics/failure-screen.png"
  let source = "xctest-screen-recording"
  let attachment: String
  let testIdentifier: String
  let attachmentTimestamp: Double
  let requestedTimeSeconds: Double
  let actualTimeSeconds: Double
  let pixelWidth: Int
  let pixelHeight: Int
}

private enum ExtractionError: LocalizedError {
  case usage
  case unsafePath(String)
  case outputExists(String)
  case malformedManifest
  case noRecording
  case ambiguousNewestRecording
  case invalidRecording(String)
  case invalidCaptureCommand
  case liveCaptureFailed(Int32)
  case imageDestination

  var errorDescription: String? {
    switch self {
    case .usage:
      "usage: extract-xctest-failure-frame.swift <attachments> <output.png> <source.json>\n"
        + "       extract-xctest-failure-frame.swift --capture-live <simulator-udid> <output.png>"
    case .unsafePath(let path):
      "The XCTest attachment manifest contains an unsafe recording path: \(path)"
    case .outputExists(let path):
      "Refusing to overwrite existing failure evidence: \(path)"
    case .malformedManifest:
      "The XCTest attachment manifest is missing, linked, or malformed."
    case .noRecording:
      "No nonempty exported XCTest Screen Recording is available."
    case .ambiguousNewestRecording:
      "The newest nonempty XCTest Screen Recording is ambiguous."
    case .invalidRecording(let message):
      "The newest nonempty XCTest Screen Recording is invalid: \(message)"
    case .invalidCaptureCommand:
      "The live simulator screenshot command is invalid."
    case .liveCaptureFailed(let status):
      "The live simulator screenshot did not complete within two seconds (status \(status))."
    case .imageDestination:
      "The final XCTest recording frame could not be encoded as PNG."
    }
  }
}

private func captureLiveSimulatorScreen() throws {
  guard CommandLine.arguments.count == 4,
    UUID(uuidString: CommandLine.arguments[2]) != nil
  else { throw ExtractionError.usage }
  let outputURL = URL(filePath: CommandLine.arguments[3]).standardizedFileURL
  guard outputURL.pathExtension.lowercased() == "png",
    !FileManager.default.fileExists(atPath: outputURL.path)
  else { throw ExtractionError.outputExists(outputURL.path) }

  let executablePath = ProcessInfo.processInfo.environment["PLAYER_FAILURE_SCREEN_XCRUN"]
    ?? "/usr/bin/xcrun"
  let executableURL = URL(filePath: executablePath).standardizedFileURL
  guard executablePath.hasPrefix("/"),
    let values = try? executableURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey]
    ),
    values.isRegularFile == true, values.isSymbolicLink != true, values.isExecutable == true
  else { throw ExtractionError.invalidCaptureCommand }

  let process = Process()
  process.executableURL = executableURL
  process.arguments = [
    "simctl", "io", CommandLine.arguments[2], "screenshot", outputURL.path,
  ]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  let completion = DispatchGroup()
  completion.enter()
  process.terminationHandler = { _ in completion.leave() }
  do {
    try process.run()
  } catch {
    completion.leave()
    throw ExtractionError.invalidCaptureCommand
  }

  let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
  deadline.schedule(deadline: .now() + .seconds(2), leeway: .nanoseconds(0))
  deadline.setEventHandler {
    _ = Darwin.kill(process.processIdentifier, SIGKILL)
  }
  deadline.resume()
  completion.wait()
  deadline.cancel()
  guard process.terminationStatus == 0 else {
    try? FileManager.default.removeItem(at: outputURL)
    throw ExtractionError.liveCaptureFailed(process.terminationStatus)
  }
}

private func regularFileValues(_ url: URL) throws -> URLResourceValues {
  try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
}

private func requireRegularFile(_ url: URL) throws -> URLResourceValues {
  let values = try regularFileValues(url)
  guard values.isRegularFile == true, values.isSymbolicLink != true else {
    throw ExtractionError.malformedManifest
  }
  return values
}

private func loadCandidate(from attachmentsURL: URL) throws -> Candidate {
  let manifestURL = attachmentsURL.appending(path: "manifest.json")
  _ = try requireRegularFile(manifestURL)
  let groups: [AttachmentGroup]
  do {
    groups = try JSONDecoder().decode([AttachmentGroup].self, from: Data(contentsOf: manifestURL))
  } catch {
    throw ExtractionError.malformedManifest
  }

  var candidates: [Candidate] = []
  for group in groups {
    for attachment in group.attachments {
      let name = attachment.exportedFileName
      guard attachment.suggestedHumanReadableName.hasPrefix("Screen Recording "),
        attachment.suggestedHumanReadableName.hasSuffix(".mp4")
      else { continue }
      guard let timestamp = attachment.timestamp, timestamp.isFinite else {
        throw ExtractionError.malformedManifest
      }
      guard !name.isEmpty, name == URL(filePath: name).lastPathComponent,
        !name.contains("/"), !name.contains("\\"), name.lowercased().hasSuffix(".mp4")
      else { throw ExtractionError.unsafePath(name) }

      let url = attachmentsURL.appending(path: name)
      guard let values = try? regularFileValues(url), values.isRegularFile == true,
        values.isSymbolicLink != true, (values.fileSize ?? 0) > 0
      else { continue }
      candidates.append(Candidate(
        attachment: attachment,
        attachmentTimestamp: timestamp,
        testIdentifier: group.testIdentifier,
        url: url
      ))
    }
  }
  guard let newestTimestamp = candidates.map(\.attachmentTimestamp).max() else {
    throw ExtractionError.noRecording
  }
  let newest = candidates.filter { $0.attachmentTimestamp == newestTimestamp }
  guard newest.count == 1, let candidate = newest.first else {
    throw ExtractionError.ambiguousNewestRecording
  }
  return candidate
}

private func writePNG(_ image: CGImage, to url: URL) throws {
  guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
  ) else { throw ExtractionError.imageDestination }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw ExtractionError.imageDestination
  }
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    CGImageSourceGetCount(source) == 1,
    let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
    decoded.width == image.width,
    decoded.height == image.height,
    decoded.width > 0,
    decoded.height > 0
  else { throw ExtractionError.imageDestination }
}

private func extract() async throws {
  guard CommandLine.arguments.count == 4 else { throw ExtractionError.usage }
  let attachmentsURL = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
    .standardizedFileURL
  let outputURL = URL(filePath: CommandLine.arguments[2]).standardizedFileURL
  let sourceURL = URL(filePath: CommandLine.arguments[3]).standardizedFileURL
  guard outputURL.pathExtension.lowercased() == "png",
    sourceURL.pathExtension.lowercased() == "json",
    outputURL.deletingLastPathComponent() == sourceURL.deletingLastPathComponent()
  else { throw ExtractionError.usage }
  for url in [outputURL, sourceURL] where FileManager.default.fileExists(atPath: url.path) {
    throw ExtractionError.outputExists(url.path)
  }

  let candidate = try loadCandidate(from: attachmentsURL)
  let asset = AVURLAsset(url: candidate.url)
  let duration: CMTime
  let tracks: [AVAssetTrack]
  do {
    duration = try await asset.load(.duration)
    tracks = try await asset.loadTracks(withMediaType: .video)
  } catch {
    throw ExtractionError.invalidRecording(error.localizedDescription)
  }
  let durationSeconds = CMTimeGetSeconds(duration)
  guard duration.isNumeric, durationSeconds.isFinite, durationSeconds > 0, !tracks.isEmpty else {
    throw ExtractionError.invalidRecording("duration or video track is unavailable")
  }

  let reader: AVAssetReader
  do {
    reader = try AVAssetReader(asset: asset)
  } catch {
    throw ExtractionError.invalidRecording(error.localizedDescription)
  }
  let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
  output.alwaysCopiesSampleData = false
  guard reader.canAdd(output) else {
    throw ExtractionError.invalidRecording("the video track cannot be read")
  }
  reader.add(output)
  guard reader.startReading() else {
    throw ExtractionError.invalidRecording(reader.error?.localizedDescription ?? "reading did not start")
  }
  var requestedTime: CMTime?
  while let sample = output.copyNextSampleBuffer() {
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
    if presentationTime.isNumeric { requestedTime = presentationTime }
  }
  guard reader.status == .completed, let requestedTime else {
    throw ExtractionError.invalidRecording(reader.error?.localizedDescription ?? "no encoded frame exists")
  }
  let requestedSeconds = CMTimeGetSeconds(requestedTime)
  guard requestedSeconds.isFinite, requestedSeconds >= 0 else {
    throw ExtractionError.invalidRecording("the final encoded frame has invalid timing")
  }

  let generator = AVAssetImageGenerator(asset: asset)
  generator.appliesPreferredTrackTransform = true
  generator.requestedTimeToleranceBefore = .zero
  generator.requestedTimeToleranceAfter = .positiveInfinity
  let image: CGImage
  let actualTime: CMTime
  do {
    (image, actualTime) = try await generator.image(at: requestedTime)
  } catch {
    throw ExtractionError.invalidRecording(error.localizedDescription)
  }
  let actualSeconds = CMTimeGetSeconds(actualTime)
  guard actualTime.isNumeric, actualSeconds.isFinite, actualSeconds >= 0,
    actualSeconds <= requestedSeconds, image.width > 0, image.height > 0
  else { throw ExtractionError.invalidRecording("the final frame has invalid timing or dimensions") }

  let outputParent = outputURL.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: outputParent, withIntermediateDirectories: true)
  let token = UUID().uuidString.lowercased()
  let temporaryPNG = outputParent.appending(path: ".failure-screen-\(token).png")
  let temporarySource = outputParent.appending(path: ".failure-screen-\(token).json")
  defer {
    try? FileManager.default.removeItem(at: temporaryPNG)
    try? FileManager.default.removeItem(at: temporarySource)
  }

  try writePNG(image, to: temporaryPNG)
  let provenance = FailureScreenSource(
    attachment: "Attachments/\(candidate.attachment.exportedFileName)",
    testIdentifier: candidate.testIdentifier,
    attachmentTimestamp: candidate.attachmentTimestamp,
    requestedTimeSeconds: requestedSeconds,
    actualTimeSeconds: actualSeconds,
    pixelWidth: image.width,
    pixelHeight: image.height
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(provenance).write(to: temporarySource, options: .atomic)

  do {
    try FileManager.default.moveItem(at: temporarySource, to: sourceURL)
    try FileManager.default.moveItem(at: temporaryPNG, to: outputURL)
  } catch {
    try? FileManager.default.removeItem(at: sourceURL)
    try? FileManager.default.removeItem(at: outputURL)
    throw error
  }
  print(
    "Extracted final XCTest frame from \(candidate.attachment.exportedFileName) "
      + "at \(actualSeconds)s (final encoded time \(requestedSeconds)s, "
      + "duration \(durationSeconds)s, \(image.width)x\(image.height))."
  )
}

do {
  if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--capture-live" {
    try captureLiveSimulatorScreen()
  } else {
    try await extract()
  }
} catch {
  fputs("Failure-frame extraction failed: \(error.localizedDescription)\n", stderr)
  exit(1)
}
