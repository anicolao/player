#!/usr/bin/env swift

import Foundation

private enum SynthesisError: Error, CustomStringConvertible {
  case invalidArguments
  case invalidNumber(String)

  var description: String {
    switch self {
    case .invalidArguments:
      return "usage: synthesize-pcm.swift OUTPUT.wav FREQUENCY_HZ DURATION_MILLISECONDS"
    case .invalidNumber(let label):
      return "invalid \(label)"
    }
  }
}

private func appendASCII(_ value: String, to bytes: inout [UInt8]) {
  bytes.append(contentsOf: value.utf8)
}

private func appendUInt16LE(_ value: UInt16, to bytes: inout [UInt8]) {
  bytes.append(UInt8(value & 0x00ff))
  bytes.append(UInt8((value >> 8) & 0x00ff))
}

private func appendUInt32LE(_ value: UInt32, to bytes: inout [UInt8]) {
  bytes.append(UInt8(value & 0x000000ff))
  bytes.append(UInt8((value >> 8) & 0x000000ff))
  bytes.append(UInt8((value >> 16) & 0x000000ff))
  bytes.append(UInt8((value >> 24) & 0x000000ff))
}

private func synthesize() throws {
  guard CommandLine.arguments.count == 4 else {
    throw SynthesisError.invalidArguments
  }

  let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
  guard let frequency = Double(CommandLine.arguments[2]), frequency > 0 else {
    throw SynthesisError.invalidNumber("frequency")
  }
  guard let durationMilliseconds = Int(CommandLine.arguments[3]), durationMilliseconds > 0 else {
    throw SynthesisError.invalidNumber("duration")
  }

  let sampleRate = 24_000
  let channelCount = 1
  let bitsPerSample = 16
  let frameCount = sampleRate * durationMilliseconds / 1_000
  let dataByteCount = frameCount * channelCount * bitsPerSample / 8
  let fadeFrameCount = sampleRate / 50

  var bytes: [UInt8] = []
  bytes.reserveCapacity(44 + dataByteCount)
  appendASCII("RIFF", to: &bytes)
  appendUInt32LE(UInt32(36 + dataByteCount), to: &bytes)
  appendASCII("WAVE", to: &bytes)
  appendASCII("fmt ", to: &bytes)
  appendUInt32LE(16, to: &bytes)
  appendUInt16LE(1, to: &bytes)
  appendUInt16LE(UInt16(channelCount), to: &bytes)
  appendUInt32LE(UInt32(sampleRate), to: &bytes)
  appendUInt32LE(UInt32(sampleRate * channelCount * bitsPerSample / 8), to: &bytes)
  appendUInt16LE(UInt16(channelCount * bitsPerSample / 8), to: &bytes)
  appendUInt16LE(UInt16(bitsPerSample), to: &bytes)
  appendASCII("data", to: &bytes)
  appendUInt32LE(UInt32(dataByteCount), to: &bytes)

  for frame in 0..<frameCount {
    let leadingFade = min(1.0, Double(frame) / Double(fadeFrameCount))
    let trailingFade = min(1.0, Double(frameCount - frame - 1) / Double(fadeFrameCount))
    let envelope = min(leadingFade, trailingFade)
    let angle = 2.0 * Double.pi * frequency * Double(frame) / Double(sampleRate)
    let sample = Int16((sin(angle) * envelope * 0.18 * Double(Int16.max)).rounded())
    appendUInt16LE(UInt16(bitPattern: sample), to: &bytes)
  }

  try Data(bytes).write(to: outputURL, options: .atomic)
}

do {
  try synthesize()
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(2)
}
