import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SystemSelectionFailure: Equatable, Sendable {
  var domain: String
  var code: Int
  var message: String

  init(_ error: any Error) {
    let error = error as NSError
    domain = error.domain
    code = error.code
    message = error.localizedDescription
  }
}

enum SystemSelectionOutcome<Value: Equatable & Sendable>: Equatable, Sendable {
  case selected(Value)
  case cancelled
  case failed(SystemSelectionFailure)
}

enum SystemFileSelectionClassifier {
  static func classify(
    _ result: Result<[URL], any Error>
  ) -> SystemSelectionOutcome<[URL]> {
    switch result {
    case .success(let urls):
      urls.isEmpty ? .cancelled : .selected(urls)
    case .failure(let error):
      SystemSelectionCancellation.isCancellation(error)
        ? .cancelled
        : .failed(SystemSelectionFailure(error))
    }
  }
}

enum SystemSelectionCancellation {
  static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    return isCancellation(error as NSError, visited: [])
  }

  private static func isCancellation(_ error: NSError, visited: Set<ObjectIdentifier>) -> Bool {
    let identity = ObjectIdentifier(error)
    guard !visited.contains(identity) else { return false }
    var visited = visited
    visited.insert(identity)

    if error.domain == NSCocoaErrorDomain, error.code == NSUserCancelledError {
      return true
    }
    if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
      return true
    }
    if error.domain == NSPOSIXErrorDomain, error.code == ECANCELED {
      return true
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      return isCancellation(underlying, visited: visited)
    }
    return false
  }
}

struct SecurityScopedResourceAccess: Sendable {
  private let startAccess: @Sendable (URL) -> Bool
  private let stopAccess: @Sendable (URL) -> Void

  static let system = SecurityScopedResourceAccess(
    startAccess: { $0.startAccessingSecurityScopedResource() },
    stopAccess: { $0.stopAccessingSecurityScopedResource() }
  )

  init(
    startAccess: @escaping @Sendable (URL) -> Bool,
    stopAccess: @escaping @Sendable (URL) -> Void
  ) {
    self.startAccess = startAccess
    self.stopAccess = stopAccess
  }

  func acquire(_ urls: [URL]) -> SecurityScopedResourceLease {
    var seen: Set<URL> = []
    let accessed = urls.compactMap { url -> URL? in
      let url = url.standardizedFileURL
      guard seen.insert(url).inserted, startAccess(url) else { return nil }
      return url
    }
    return SecurityScopedResourceLease(urls: accessed, stopAccess: stopAccess)
  }
}

final class SecurityScopedResourceLease: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [URL]?
  private let stopAccess: @Sendable (URL) -> Void

  fileprivate init(
    urls: [URL],
    stopAccess: @escaping @Sendable (URL) -> Void
  ) {
    self.urls = urls
    self.stopAccess = stopAccess
  }

  func release() {
    let releasing: [URL]
    lock.lock()
    if let urls {
      releasing = urls
      self.urls = nil
    } else {
      releasing = []
    }
    lock.unlock()
    releasing.forEach(stopAccess)
  }

  deinit {
    release()
  }
}

struct AcquiredCoverArtwork: Equatable, Sendable {
  var data: Data
  var mediaType: String
  var pixelWidth: Int
  var pixelHeight: Int
  var wasNormalized: Bool
}

enum CoverArtworkAcquisitionError: LocalizedError, Equatable, Sendable {
  case emptyData
  case encodedDataTooLarge(maximumBytes: Int)
  case unreadableFile
  case invalidImage
  case invalidDimensions
  case pixelLimitExceeded(width: Int, height: Int, maximumPixels: Int)
  case normalizationFailed

  var errorDescription: String? {
    switch self {
    case .emptyData:
      "The selected image is empty. Choose another image."
    case .encodedDataTooLarge(let maximumBytes):
      "The selected image is larger than \(Self.formattedBytes(maximumBytes)). Choose a smaller image."
    case .unreadableFile:
      "The selected image file could not be read. Download it, then try again."
    case .invalidImage:
      "The selected file does not contain a readable image. Choose another image."
    case .invalidDimensions:
      "The selected image has invalid dimensions. Choose another image."
    case .pixelLimitExceeded(let width, let height, let maximumPixels):
      "The selected image is \(width) by \(height) pixels, above the \(maximumPixels)-pixel safety limit. Choose a smaller image."
    case .normalizationFailed:
      "The selected image format could not be prepared as cover artwork. Choose another image."
    }
  }

  private static func formattedBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }
}

struct CoverArtworkAcquirer: Sendable {
  static let defaultMaximumEncodedByteCount = 50 * 1_024 * 1_024
  static let defaultMaximumPixelCount = 64_000_000
  private static let readChunkByteCount = 1_024 * 1_024
  private static let retainedMediaTypes: Set<String> = [
    "image/png", "image/jpeg", "image/heic", "image/heif",
  ]

  let maximumEncodedByteCount: Int
  let maximumPixelCount: Int

  init(
    maximumEncodedByteCount: Int = Self.defaultMaximumEncodedByteCount,
    maximumPixelCount: Int = Self.defaultMaximumPixelCount
  ) {
    precondition(maximumEncodedByteCount > 0)
    precondition(maximumPixelCount > 0)
    self.maximumEncodedByteCount = maximumEncodedByteCount
    self.maximumPixelCount = maximumPixelCount
  }

  func acquire(
    data: Data,
    declaredMediaType _: String? = nil
  ) throws -> AcquiredCoverArtwork {
    guard !data.isEmpty else { throw CoverArtworkAcquisitionError.emptyData }
    guard data.count <= maximumEncodedByteCount else {
      throw CoverArtworkAcquisitionError.encodedDataTooLarge(
        maximumBytes: maximumEncodedByteCount
      )
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { throw CoverArtworkAcquisitionError.invalidImage }

    let dimensions = try dimensions(of: source)
    try enforcePixelLimit(width: dimensions.width, height: dimensions.height)
    guard CGImageSourceCreateImageAtIndex(
      source,
      0,
      [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
    ) != nil else { throw CoverArtworkAcquisitionError.invalidImage }

    let sourceType = (CGImageSourceGetType(source) as String?)
      .flatMap(UTType.init)
    let mediaType = sourceType?.preferredMIMEType ?? "application/octet-stream"
    if Self.retainedMediaTypes.contains(mediaType) {
      return AcquiredCoverArtwork(
        data: data,
        mediaType: mediaType,
        pixelWidth: dimensions.width,
        pixelHeight: dimensions.height,
        wasNormalized: false
      )
    }

    let normalized = try normalizedPNG(
      source: source,
      maximumDimension: max(dimensions.width, dimensions.height)
    )
    guard normalized.count <= maximumEncodedByteCount else {
      throw CoverArtworkAcquisitionError.encodedDataTooLarge(
        maximumBytes: maximumEncodedByteCount
      )
    }
    return AcquiredCoverArtwork(
      data: normalized,
      mediaType: "image/png",
      pixelWidth: dimensions.width,
      pixelHeight: dimensions.height,
      wasNormalized: true
    )
  }

  func acquire(
    fileURL: URL,
    resourceAccess: SecurityScopedResourceAccess = .system
  ) throws -> AcquiredCoverArtwork {
    let lease = resourceAccess.acquire([fileURL])
    defer { lease.release() }
    let values: URLResourceValues
    do {
      values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    } catch {
      throw CoverArtworkAcquisitionError.unreadableFile
    }
    guard values.isRegularFile == true else {
      throw CoverArtworkAcquisitionError.unreadableFile
    }
    if let fileSize = values.fileSize, fileSize > maximumEncodedByteCount {
      throw CoverArtworkAcquisitionError.encodedDataTooLarge(
        maximumBytes: maximumEncodedByteCount
      )
    }
    let data: Data
    do {
      data = try readBoundedFile(fileURL)
    } catch let error as CoverArtworkAcquisitionError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CoverArtworkAcquisitionError.unreadableFile
    }
    return try acquire(data: data)
  }

  private func readBoundedFile(_ url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    data.reserveCapacity(min(maximumEncodedByteCount, Self.readChunkByteCount))
    while true {
      try Task.checkCancellation()
      let remaining = maximumEncodedByteCount - data.count
      guard remaining >= 0 else {
        throw CoverArtworkAcquisitionError.encodedDataTooLarge(
          maximumBytes: maximumEncodedByteCount
        )
      }
      let chunk = try handle.read(upToCount: min(Self.readChunkByteCount, remaining + 1))
      guard let chunk, !chunk.isEmpty else { return data }
      guard chunk.count <= remaining else {
        throw CoverArtworkAcquisitionError.encodedDataTooLarge(
          maximumBytes: maximumEncodedByteCount
        )
      }
      data.append(chunk)
    }
  }

  private func dimensions(of source: CGImageSource) throws -> (width: Int, height: Int) {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = integer(properties[kCGImagePropertyPixelWidth]),
      let height = integer(properties[kCGImagePropertyPixelHeight]),
      width > 0,
      height > 0
    else { throw CoverArtworkAcquisitionError.invalidDimensions }
    return (width, height)
  }

  private func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let value = value as? Int { return value }
    return nil
  }

  private func enforcePixelLimit(width: Int, height: Int) throws {
    let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
    guard !overflow, pixels <= maximumPixelCount else {
      throw CoverArtworkAcquisitionError.pixelLimitExceeded(
        width: width,
        height: height,
        maximumPixels: maximumPixelCount
      )
    }
  }

  private func normalizedPNG(
    source: CGImageSource,
    maximumDimension: Int
  ) throws -> Data {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { throw CoverArtworkAcquisitionError.normalizationFailed }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      output,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else { throw CoverArtworkAcquisitionError.normalizationFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CoverArtworkAcquisitionError.normalizationFailed
    }
    return output as Data
  }
}
