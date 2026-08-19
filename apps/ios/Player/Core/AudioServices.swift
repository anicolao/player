import AVFoundation
import Foundation

struct AVFoundationAudioInspector: AudioInspecting {
  private static let maximumArtworkBytes = 20 * 1_024 * 1_024

  func inspect(url: URL) async throws -> InspectedAudio {
    let fileExtension = url.pathExtension.lowercased()
    guard ["m4a", "m4b", "mp3"].contains(fileExtension) else {
      throw PlayerCoreError.unsupportedFile(url.lastPathComponent)
    }

    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let seconds = CMTimeGetSeconds(duration)
    guard seconds.isFinite, seconds > 0 else {
      throw PlayerCoreError.unreadableAudio(url.lastPathComponent)
    }

    let commonMetadata = try await asset.load(.commonMetadata)
    let formatMetadata = try await asset.load(.metadata)
    let metadata = commonMetadata + formatMetadata
    let title = await stringValue(for: .commonIdentifierTitle, in: metadata)
    let artist = await stringValue(for: .commonIdentifierArtist, in: metadata)
    let artwork = await dataValue(for: .commonIdentifierArtwork, in: metadata)
    let narrator = await textValue(
      matchingIdentifierFragments: ["narrator", "readby", "reader"],
      in: metadata
    )
    let seriesPosition = await textValue(
      matchingIdentifierFragments: [
        "series-part", "series_part", "seriesposition", "series-position", "seriesnumber",
      ],
      in: metadata
    )
    let series = await textValue(
      matchingIdentifierFragments: ["series"],
      excludingIdentifierFragments: ["part", "position", "number"],
      in: metadata
    )
    let chapters = try await chapters(in: asset, durationSeconds: seconds, filename: url.lastPathComponent)

    return InspectedAudio(
      title: title,
      authors: ContributorParser.names(from: artist),
      durationSeconds: seconds,
      artworkData: artwork,
      container: fileExtension.uppercased(),
      narrators: ContributorParser.names(from: narrator),
      seriesName: series?.trimmedNilIfEmpty,
      seriesPosition: seriesPosition?.trimmedNilIfEmpty,
      artworkMediaType: artwork.flatMap(ArtworkType.mediaType),
      chapters: chapters
    )
  }

  private func stringValue(
    for identifier: AVMetadataIdentifier,
    in metadata: [AVMetadataItem]
  ) async -> String? {
    guard let item = AVMetadataItem.metadataItems(
      from: metadata,
      filteredByIdentifier: identifier
    ).first else { return nil }
    return try? await item.load(.stringValue)
  }

  private func dataValue(
    for identifier: AVMetadataIdentifier,
    in metadata: [AVMetadataItem]
  ) async -> Data? {
    guard let item = AVMetadataItem.metadataItems(
      from: metadata,
      filteredByIdentifier: identifier
    ).first else { return nil }
    guard let data = try? await item.load(.dataValue), data.count <= Self.maximumArtworkBytes else {
      return nil
    }
    return data
  }

  private func textValue(
    matchingIdentifierFragments included: [String],
    excludingIdentifierFragments excluded: [String] = [],
    in metadata: [AVMetadataItem]
  ) async -> String? {
    for item in metadata {
      let identifier = item.identifier?.rawValue.lowercased() ?? ""
      guard
        included.contains(where: identifier.contains),
        !excluded.contains(where: identifier.contains),
        let value = try? await item.load(.stringValue),
        value.trimmedNilIfEmpty != nil
      else { continue }
      return value
    }
    return nil
  }

  private func chapters(
    in asset: AVAsset,
    durationSeconds: Double,
    filename: String
  ) async throws -> [Chapter] {
    let locales = try await asset.load(.availableChapterLocales)
    for locale in locales {
      let groups = try await asset.loadChapterMetadataGroups(
        withTitleLocale: locale,
        containingItemsWithCommonKeys: [.commonKeyTitle]
      )
      guard !groups.isEmpty else { continue }
      var candidates: [EmbeddedChapterCandidate] = []
      for group in groups {
        let title = await stringValue(for: .commonIdentifierTitle, in: group.items)
        candidates.append(
          EmbeddedChapterCandidate(
            title: title,
            startSeconds: CMTimeGetSeconds(group.timeRange.start),
            durationSeconds: CMTimeGetSeconds(group.timeRange.duration)
          )
        )
      }
      let normalized = ChapterTimeline.embeddedChapters(
        candidates,
        assetDurationSeconds: durationSeconds
      )
      if !normalized.isEmpty { return normalized }
    }

    return [
      Chapter(
        id: "file-0",
        title: URL(filePath: filename).deletingPathExtension().lastPathComponent,
        startSeconds: 0,
        durationSeconds: durationSeconds,
        source: .file,
        assetID: nil
      )
    ]
  }
}

struct EmbeddedChapterCandidate: Equatable, Sendable {
  var title: String?
  var startSeconds: Double
  var durationSeconds: Double
}

enum ChapterTimeline {
  static func embeddedChapters(
    _ candidates: [EmbeddedChapterCandidate],
    assetDurationSeconds: Double
  ) -> [Chapter] {
    guard assetDurationSeconds.isFinite, assetDurationSeconds > 0 else { return [] }
    let ordered = candidates
      .filter {
        $0.startSeconds.isFinite && $0.durationSeconds.isFinite
          && $0.startSeconds >= 0 && $0.startSeconds < assetDurationSeconds
      }
      .sorted { $0.startSeconds < $1.startSeconds }

    return ordered.enumerated().compactMap { index, candidate in
      let nextStart = ordered.indices.contains(index + 1)
        ? ordered[index + 1].startSeconds
        : assetDurationSeconds
      let maximumDuration = max(0, min(nextStart, assetDurationSeconds) - candidate.startSeconds)
      let proposedDuration = candidate.durationSeconds > 0
        ? candidate.durationSeconds
        : maximumDuration
      let duration = min(proposedDuration, maximumDuration)
      guard duration > 0 else { return nil }
      let startMilliseconds = Int64((candidate.startSeconds * 1_000).rounded(.down))
      return Chapter(
        id: "embedded-\(index)-\(startMilliseconds)",
        title: candidate.title?.trimmedNilIfEmpty ?? "Chapter \(index + 1)",
        startSeconds: candidate.startSeconds,
        durationSeconds: duration,
        source: .embedded,
        assetID: nil
      )
    }
  }
}

enum ContributorParser {
  static func names(from value: String?) -> [String] {
    guard let value else { return [] }
    return value
      .components(separatedBy: CharacterSet(charactersIn: ";\n"))
      .compactMap(\.trimmedNilIfEmpty)
  }
}

private enum ArtworkType {
  static func mediaType(for data: Data) -> String? {
    let bytes = Array(data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if bytes.count >= 12,
      String(decoding: bytes[4..<12], as: UTF8.self) == "ftypheic"
    {
      return "image/heic"
    }
    return nil
  }
}

private extension String {
  var trimmedNilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

actor DeterministicAudioInspector: AudioInspecting {
  private let result: Result<InspectedAudio, PlayerCoreError>

  init(result: Result<InspectedAudio, PlayerCoreError>) {
    self.result = result
  }

  func inspect(url: URL) throws -> InspectedAudio {
    try result.get()
  }
}

@MainActor
final class AVPlayerPlaybackController: AudioPlaybackControlling {
  private var player: AVPlayer?
  private(set) var state: PlaybackState = .unloaded

  var currentPositionSeconds: Double {
    guard let seconds = player?.currentTime().seconds, seconds.isFinite else {
      return state.elapsedSeconds
    }
    return max(0, seconds)
  }

  func load(url: URL, bookID: UUID, at seconds: Double = 0) async throws {
    let asset = AVURLAsset(url: url)
    guard try await asset.load(.isPlayable) else {
      throw PlayerCoreError.unreadableAudio(url.lastPathComponent)
    }

    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    if seconds > 0 {
      await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1_000))
    }
    self.player = player
    state = PlaybackState(status: .paused, loadedBookID: bookID, elapsedSeconds: seconds)
  }

  func play() {
    player?.play()
    guard state.loadedBookID != nil else { return }
    state.status = .playing
  }

  func seek(to seconds: Double) async {
    guard let player else { return }
    let destination = max(0, seconds)
    await player.seek(to: CMTime(seconds: destination, preferredTimescale: 1_000))
    state.elapsedSeconds = currentPositionSeconds
  }

  func pause() {
    player?.pause()
    guard state.loadedBookID != nil else { return }
    if let seconds = player?.currentTime().seconds, seconds.isFinite {
      state.elapsedSeconds = seconds
    }
    state.status = .paused
  }
}

@MainActor
final class DeterministicPlaybackController: AudioPlaybackControlling {
  private(set) var state: PlaybackState
  private(set) var loadedURL: URL?

  init(state: PlaybackState = .unloaded) {
    self.state = state
  }

  var currentPositionSeconds: Double { state.elapsedSeconds }

  func load(url: URL, bookID: UUID, at seconds: Double) async throws {
    loadedURL = url
    state = PlaybackState(status: .paused, loadedBookID: bookID, elapsedSeconds: seconds)
  }

  func play() {
    guard state.loadedBookID != nil else { return }
    state.status = .playing
  }

  func seek(to seconds: Double) async {
    guard state.loadedBookID != nil else { return }
    state.elapsedSeconds = max(0, seconds)
  }

  func pause() {
    guard state.loadedBookID != nil else { return }
    state.status = .paused
  }
}
