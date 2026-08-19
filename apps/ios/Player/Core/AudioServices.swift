import AVFoundation
import Foundation

actor AVFoundationAudioInspector: AudioInspecting {
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

    let metadata = try await asset.load(.commonMetadata)
    let title = await stringValue(for: .commonIdentifierTitle, in: metadata)
    let artist = await stringValue(for: .commonIdentifierArtist, in: metadata)
    let artwork = await dataValue(for: .commonIdentifierArtwork, in: metadata)

    return InspectedAudio(
      title: title,
      authors: artist.map { [$0] } ?? [],
      durationSeconds: seconds,
      artworkData: artwork,
      container: fileExtension.uppercased()
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
    return try? await item.load(.dataValue)
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

  func load(url: URL, bookID: UUID, at seconds: Double) async throws {
    loadedURL = url
    state = PlaybackState(status: .paused, loadedBookID: bookID, elapsedSeconds: seconds)
  }

  func play() {
    guard state.loadedBookID != nil else { return }
    state.status = .playing
  }

  func pause() {
    guard state.loadedBookID != nil else { return }
    state.status = .paused
  }
}
