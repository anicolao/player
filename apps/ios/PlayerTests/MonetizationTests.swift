import Security
import XCTest
@testable import Player

@MainActor
final class MonetizationTests: XCTestCase {
  func testIncludedPlaybackDescriptionAndBoundaryAreExact() {
    var snapshot = MonetizationSnapshot.included
    XCTAssertEqual(snapshot.remainingPlaybackSeconds, 180_000)
    XCTAssertEqual(snapshot.remainingPlaybackDescription, "50h remaining")
    XCTAssertTrue(snapshot.canStartPlayback)

    snapshot.consumedPlaybackSeconds = 179_941
    XCTAssertEqual(snapshot.remainingPlaybackDescription, "1m remaining")

    snapshot.consumedPlaybackSeconds = 180_000
    XCTAssertEqual(snapshot.remainingPlaybackDescription, "0m remaining")
    XCTAssertFalse(snapshot.canStartPlayback)

    snapshot.entitlement = .fullUnlock
    XCTAssertTrue(snapshot.canStartPlayback)
  }

  func testMeterCountsOnlyUptimeWhilePlaybackIsActive() async throws {
    let harness = try makeHarness(consumedSeconds: 0)
    await harness.model.restore()
    await harness.model.prepareMonetization()

    harness.uptime.value = 100
    await harness.model.play(bookID: harness.bookID)
    XCTAssertEqual(harness.model.playbackState.status, .playing)

    harness.uptime.value = 107
    await harness.model.synchronizePlaybackProgress()
    XCTAssertEqual(harness.manager.snapshot.consumedPlaybackSeconds, 7, accuracy: 0.001)

    harness.uptime.value = 110
    await harness.model.pause()
    XCTAssertEqual(harness.manager.snapshot.consumedPlaybackSeconds, 10, accuracy: 0.001)

    harness.uptime.value = 10_000
    await harness.model.synchronizePlaybackProgress()
    XCTAssertEqual(
      harness.manager.snapshot.consumedPlaybackSeconds,
      10,
      accuracy: 0.001,
      "Time while paused must never consume the included playback allowance"
    )
  }

  func testSessionCrossingLimitContinuesUntilPauseThenNextPlayIsBlocked() async throws {
    let harness = try makeHarness(
      consumedSeconds: MonetizationSnapshot.includedPlaybackSeconds - 6
    )
    await harness.model.restore()

    harness.uptime.value = 20
    await harness.model.play(bookID: harness.bookID)
    harness.uptime.value = 25
    await harness.model.synchronizePlaybackProgress()
    XCTAssertEqual(harness.model.playbackState.status, .playing)
    XCTAssertEqual(harness.manager.snapshot.remainingPlaybackSeconds, 1, accuracy: 0.001)

    harness.uptime.value = 26
    await harness.model.pause()
    XCTAssertEqual(harness.manager.snapshot.remainingPlaybackSeconds, 0, accuracy: 0.001)
    XCTAssertEqual(harness.model.playbackState.status, .paused)

    await harness.model.play(bookID: harness.bookID)
    XCTAssertEqual(harness.model.playbackState.status, .paused)
    XCTAssertTrue(harness.model.isFullUnlockPresented)

    await harness.model.purchaseFullUnlock()
    await harness.model.play(bookID: harness.bookID)
    XCTAssertEqual(harness.model.playbackState.status, .playing)
    XCTAssertTrue(harness.model.monetization.isUnlocked)
  }

  func testSandboxAndProductionAllowancesAndUnlocksAreIndependent() {
    let suiteName = "MonetizationTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Could not create isolated defaults")
    }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let keychain = TestPlaybackAllowanceKeychain()

    let sandbox = PlaybackAllowancePersistence(
      storeEnvironment: .sandbox,
      userDefaults: defaults,
      keychainService: suiteName,
      keychain: keychain
    )
    let production = PlaybackAllowancePersistence(
      storeEnvironment: .production,
      userDefaults: defaults,
      keychainService: suiteName,
      keychain: keychain
    )

    XCTAssertEqual(sandbox.saveConsumedPlaybackSeconds(12_345), errSecSuccess)
    sandbox.saveCachedUnlock(true)

    XCTAssertEqual(sandbox.loadConsumedPlaybackSeconds(), 12_345, accuracy: 0.001)
    XCTAssertTrue(sandbox.loadCachedUnlock())
    XCTAssertEqual(production.loadConsumedPlaybackSeconds(), 0, accuracy: 0.001)
    XCTAssertFalse(production.loadCachedUnlock())
  }

  func testKeychainWriteFailureIsReportedToPersistenceAndManager() async {
    let suiteName = "MonetizationTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Could not create isolated defaults")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = TestPlaybackAllowanceKeychain()
    keychain.saveStatus = errSecInteractionNotAllowed
    let persistence = PlaybackAllowancePersistence(
      storeEnvironment: .sandbox,
      userDefaults: defaults,
      keychainService: suiteName,
      keychain: keychain
    )

    XCTAssertEqual(
      persistence.saveConsumedPlaybackSeconds(12),
      errSecInteractionNotAllowed
    )
    let manager = StoreKitMonetizationManager(persistence: persistence)
    await manager.recordPlayback(seconds: 1)
    XCTAssertEqual(manager.snapshot.consumedPlaybackSeconds, 13)
    XCTAssertTrue(
      manager.snapshot.feedbackMessage?.contains("couldn't securely save") == true
    )
  }

  private func makeHarness(consumedSeconds: TimeInterval) throws -> MonetizationHarness {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "MonetizationTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let bookID = UUID(uuidString: "F1000000-0000-0000-0000-000000000001")!
    let assetID = UUID(uuidString: "F1000000-0000-0000-0000-000000000002")!
    let managedPath = "Media/\(bookID.uuidString.lowercased())/test.m4b"
    let managedURL = root.appending(path: managedPath)
    try FileManager.default.createDirectory(
      at: managedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("meter fixture".utf8).write(to: managedURL)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let book = Book(
      id: bookID,
      title: "Metered Book",
      authors: ["Fixture Author"],
      durationSeconds: 360_000,
      artworkData: nil,
      assets: [
        AudioAsset(
          id: assetID,
          originalFilename: "test.m4b",
          managedRelativePath: managedPath,
          checksumSHA256: "meter-fixture",
          byteCount: 13,
          durationSeconds: 360_000,
          container: "M4B"
        )
      ],
      dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
    )
    var monetization = MonetizationSnapshot.included
    monetization.consumedPlaybackSeconds = consumedSeconds
    monetization.displayPrice = "$9.99"
    let manager = DeterministicMonetizationManager(snapshot: monetization)
    let uptime = MutablePlaybackUptime()
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: InMemoryLibraryStore(
        snapshot: LibrarySnapshot(books: [book], importJobs: [], currentBookID: bookID)
      ),
      media: FileSystemMediaManager(rootURL: root),
      inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
      playback: DeterministicPlaybackController(),
      monetization: manager,
      playbackUptime: uptime
    ))
    return MonetizationHarness(
      model: model,
      manager: manager,
      uptime: uptime,
      bookID: bookID
    )
  }
}

@MainActor
private struct MonetizationHarness {
  let model: PlayerModel
  let manager: DeterministicMonetizationManager
  let uptime: MutablePlaybackUptime
  let bookID: UUID
}

@MainActor
private final class TestPlaybackAllowanceKeychain: PlaybackAllowanceKeychain {
  var saveStatus = errSecSuccess
  private var values: [String: TimeInterval] = [:]

  func loadSeconds(service: String, account: String) -> TimeInterval? {
    values["\(service)|\(account)"]
  }

  func saveSeconds(
    _ seconds: TimeInterval,
    service: String,
    account: String
  ) -> OSStatus {
    guard saveStatus == errSecSuccess else { return saveStatus }
    values["\(service)|\(account)"] = seconds
    return errSecSuccess
  }
}
