import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Player

final class SystemIngressTests: XCTestCase {
  func testFileSelectionClassifierDistinguishesSelectionCancellationAndFailure() throws {
    let first = URL(filePath: "/tmp/first.m4b")
    let second = URL(filePath: "/tmp/second.mp3")
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.success([first, second])),
      .selected([first, second])
    )
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.success([])),
      .cancelled
    )
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.failure(CancellationError())),
      .cancelled
    )
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.failure(CocoaError(.userCancelled))),
      .cancelled
    )
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.failure(URLError(.cancelled))),
      .cancelled
    )
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.failure(POSIXError(.ECANCELED))),
      .cancelled
    )

    let providerFailure = NSError(domain: "FixtureProvider", code: 91, userInfo: [
      NSLocalizedDescriptionKey: "The cloud item is offline.",
    ])
    XCTAssertEqual(
      SystemFileSelectionClassifier.classify(.failure(providerFailure)),
      .failed(SystemSelectionFailure(providerFailure))
    )
  }

  func testNestedCancellationIsRecognizedWithoutMisclassifyingProviderFailures() {
    let cancellation = NSError(
      domain: "FixtureProvider",
      code: 2,
      userInfo: [NSUnderlyingErrorKey: CocoaError(.userCancelled)]
    )
    XCTAssertTrue(SystemSelectionCancellation.isCancellation(cancellation))
    XCTAssertFalse(SystemSelectionCancellation.isCancellation(
      NSError(domain: NSItemProvider.errorDomain, code: -1)
    ))
  }

  func testSecurityScopedLeaseStartsUniqueURLsAndStopsEachSuccessfulStartExactlyOnce() {
    let probe = SecurityScopeProbe(accessibleNames: ["first.m4b", "second.mp3"])
    let access = probe.access
    let first = URL(filePath: "/tmp/first.m4b")
    let second = URL(filePath: "/tmp/second.mp3")
    let local = URL(filePath: "/tmp/local.zip")

    let lease = access.acquire([first, first, second, local])
    XCTAssertEqual(probe.startedNames, ["first.m4b", "second.mp3", "local.zip"])
    XCTAssertTrue(probe.stoppedNames.isEmpty)

    lease.release()
    lease.release()
    XCTAssertEqual(probe.stoppedNames, ["first.m4b", "second.mp3"])

    do {
      _ = access.acquire([first])
    }
    XCTAssertEqual(probe.startedNames, ["first.m4b", "second.mp3", "local.zip", "first.m4b"])
    XCTAssertEqual(probe.stoppedNames, ["first.m4b", "second.mp3", "first.m4b"])
  }

  func testCoverAcquirerUsesActualTypeAndRetainsValidPNG() throws {
    let png = try imageData(type: .png, width: 3, height: 2)
    let acquired = try CoverArtworkAcquirer().acquire(
      data: png,
      declaredMediaType: "image/jpeg"
    )
    XCTAssertEqual(acquired.data, png)
    XCTAssertEqual(acquired.mediaType, "image/png")
    XCTAssertEqual(acquired.pixelWidth, 3)
    XCTAssertEqual(acquired.pixelHeight, 2)
    XCTAssertFalse(acquired.wasNormalized)
  }

  func testCoverAcquirerRejectsEmptyOversizedCorruptAndExcessivePixelPayloads() throws {
    XCTAssertThrowsError(try CoverArtworkAcquirer().acquire(data: Data())) { error in
      XCTAssertEqual(error as? CoverArtworkAcquisitionError, .emptyData)
    }
    XCTAssertThrowsError(
      try CoverArtworkAcquirer(maximumEncodedByteCount: 3).acquire(data: Data(repeating: 1, count: 4))
    ) { error in
      XCTAssertEqual(
        error as? CoverArtworkAcquisitionError,
        .encodedDataTooLarge(maximumBytes: 3)
      )
    }
    XCTAssertThrowsError(try CoverArtworkAcquirer().acquire(data: Data("not image".utf8))) {
      error in
      XCTAssertEqual(error as? CoverArtworkAcquisitionError, .invalidImage)
    }
    let png = try imageData(type: .png, width: 11, height: 10)
    XCTAssertThrowsError(
      try CoverArtworkAcquirer(maximumPixelCount: 100).acquire(data: png)
    ) { error in
      XCTAssertEqual(
        error as? CoverArtworkAcquisitionError,
        .pixelLimitExceeded(width: 11, height: 10, maximumPixels: 100)
      )
    }
  }

  func testCoverAcquirerNormalizesReadableUnsupportedEncodingToPNG() throws {
    let tiff = try imageData(type: .tiff, width: 4, height: 3)
    let acquired = try CoverArtworkAcquirer().acquire(data: tiff)
    XCTAssertEqual(acquired.mediaType, "image/png")
    XCTAssertEqual(acquired.pixelWidth, 4)
    XCTAssertEqual(acquired.pixelHeight, 3)
    XCTAssertTrue(acquired.wasNormalized)
    XCTAssertNotEqual(acquired.data, tiff)
    XCTAssertNotNil(CGImageSourceCreateWithData(acquired.data as CFData, nil))
  }

  func testCoverAcquirerRetainsHEICAndReportsItsActualMediaType() throws {
    let heic = try imageData(type: .heic, width: 16, height: 16)
    let acquired = try CoverArtworkAcquirer().acquire(
      data: heic,
      declaredMediaType: "image/jpeg"
    )
    XCTAssertEqual(acquired.mediaType, "image/heic")
    XCTAssertEqual(acquired.pixelWidth, 16)
    XCTAssertEqual(acquired.pixelHeight, 16)
    XCTAssertFalse(acquired.wasNormalized)
    XCTAssertEqual(acquired.data, heic)
  }

  func testCoverFileAcquisitionBalancesScopeOnSuccessAndEveryFailure() throws {
    let root = temporaryRoot("cover-files")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let valid = root.appending(path: "valid.png")
    let corrupt = root.appending(path: "corrupt.png")
    let tooLarge = root.appending(path: "large.png")
    try imageData(type: .png, width: 2, height: 2).write(to: valid)
    try Data("not an image".utf8).write(to: corrupt)
    try Data(repeating: 7, count: 32).write(to: tooLarge)
    let probe = SecurityScopeProbe(accessibleNames: [
      valid.lastPathComponent, corrupt.lastPathComponent, tooLarge.lastPathComponent,
    ])

    XCTAssertEqual(
      try CoverArtworkAcquirer().acquire(fileURL: valid, resourceAccess: probe.access).mediaType,
      "image/png"
    )
    XCTAssertThrowsError(
      try CoverArtworkAcquirer().acquire(fileURL: corrupt, resourceAccess: probe.access)
    )
    XCTAssertThrowsError(
      try CoverArtworkAcquirer(maximumEncodedByteCount: 8).acquire(
        fileURL: tooLarge,
        resourceAccess: probe.access
      )
    )
    XCTAssertEqual(probe.startedNames, ["valid.png", "corrupt.png", "large.png"])
    XCTAssertEqual(probe.stoppedNames, ["valid.png", "corrupt.png", "large.png"])
  }

  private func imageData(type: UTType, width: Int, height: Int) throws -> Data {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let output = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
      output,
      type.identifier as CFString,
      1,
      nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  private func temporaryRoot(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "player-system-ingress-\(name)-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  }
}

private final class SecurityScopeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let accessibleNames: Set<String>
  private var starts: [String] = []
  private var stops: [String] = []

  init(accessibleNames: Set<String>) {
    self.accessibleNames = accessibleNames
  }

  var access: SecurityScopedResourceAccess {
    SecurityScopedResourceAccess(
      startAccess: { [self] url in
        lock.withLock { starts.append(url.lastPathComponent) }
        return accessibleNames.contains(url.lastPathComponent)
      },
      stopAccess: { [self] url in
        lock.withLock { stops.append(url.lastPathComponent) }
      }
    )
  }

  var startedNames: [String] { lock.withLock { starts } }
  var stoppedNames: [String] { lock.withLock { stops } }
}
