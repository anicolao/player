import Foundation
import XCTest
@testable import Player

final class AccessibilityPreferencesTests: XCTestCase {
  func testAccessibilityPreferencesPersistAndRoundTrip() async throws {
    let fixture = try makeStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    var snapshot = LibrarySnapshot.empty
    snapshot.accessibilityPreferences = AccessibilityPreferences(
      prefersHighContrast: true,
      reducesDecorativeArtwork: true
    )
    try await fixture.store.save(snapshot)

    let restored = try await fixture.store.load()
    XCTAssertEqual(restored.accessibilityPreferences, snapshot.accessibilityPreferences)
  }

  func testVersionFourteenMigratesToSystemAuthoritativeDefaults() async throws {
    let fixture = try makeStore()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    try await fixture.store.save(.empty)
    let data = try Data(contentsOf: fixture.file)
    var envelope = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    envelope["schemaVersion"] = 14
    var library = try XCTUnwrap(envelope["library"] as? [String: Any])
    library.removeValue(forKey: "accessibilityPreferences")
    envelope["library"] = library
    try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
      .write(to: fixture.file, options: .atomic)

    let migrated = try await fixture.store.load()
    XCTAssertEqual(migrated.accessibilityPreferences, .default)

    try await fixture.store.save(migrated)
    let current = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [String: Any]
    )
    XCTAssertEqual(current["schemaVersion"] as? Int, 15)
  }

  private func makeStore() throws -> (
    directory: URL,
    file: URL,
    store: CodableLibraryStore
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "player-accessibility-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let file = directory.appending(path: "library.json")
    return (directory, file, CodableLibraryStore(fileURL: file))
  }
}

final class E2EDynamicTypeConfigurationTests: XCTestCase {
  func testAbsentValueDefaultsToMedium() throws {
    XCTAssertEqual(
      try E2EDynamicTypeConfiguration.parse(environment: [:]),
      .medium
    )
  }

  func testEveryCanonicalValueParsesExactly() throws {
    for configuration in E2EDynamicTypeConfiguration.allCases {
      XCTAssertEqual(
        try E2EDynamicTypeConfiguration.parse(environment: [
          E2EDynamicTypeConfiguration.environmentKey: configuration.rawValue,
        ]),
        configuration
      )
    }
  }

  func testExplicitEmptyWhitespaceAndUnknownValuesFailClosed() {
    for value in ["", " ", " accessibility5", "accessibility5 ", "extra-large"] {
      XCTAssertThrowsError(
        try E2EDynamicTypeConfiguration.parse(environment: [
          E2EDynamicTypeConfiguration.environmentKey: value,
        ]),
        "Expected strict Dynamic Type parsing to reject \(value.debugDescription)"
      )
    }
  }
}
