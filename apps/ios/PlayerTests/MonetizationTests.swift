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

  func testPlaybackAllowancePersistsAcrossManagerRelaunch() async {
    let suiteName = "MonetizationRelaunch-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Could not create isolated defaults")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = TestPlaybackAllowanceKeychain()

    func persistence() -> PlaybackAllowancePersistence {
      PlaybackAllowancePersistence(
        storeEnvironment: .sandbox,
        userDefaults: defaults,
        keychainService: suiteName,
        keychain: keychain
      )
    }

    let first = StoreKitMonetizationManager(
      persistence: persistence(),
      storeEnvironment: .sandbox,
      storeKit: StrictStoreKitClient()
    )
    await first.recordPlayback(seconds: 12_345)

    let relaunched = StoreKitMonetizationManager(
      persistence: persistence(),
      storeEnvironment: .sandbox,
      storeKit: StrictStoreKitClient()
    )
    XCTAssertEqual(relaunched.snapshot.consumedPlaybackSeconds, 12_345, accuracy: 0.001)
    XCTAssertEqual(relaunched.snapshot.remainingPlaybackSeconds, 167_655, accuracy: 0.001)
  }

  func testStalledPlaybackDoesNotConsumeAllowanceOrBackfillAfterResuming() async throws {
    let harness = try makeHarness(consumedSeconds: 0)
    await harness.model.restore()

    harness.uptime.value = 100
    await harness.model.play(bookID: harness.bookID)
    harness.playback.isAdvancing = false
    harness.uptime.value = 1_000
    await harness.model.synchronizePlaybackProgress()
    XCTAssertEqual(harness.manager.snapshot.consumedPlaybackSeconds, 0, accuracy: 0.001)

    harness.playback.isAdvancing = true
    harness.uptime.value = 2_000
    await harness.model.synchronizePlaybackProgress()
    XCTAssertEqual(
      harness.manager.snapshot.consumedPlaybackSeconds,
      0,
      accuracy: 0.001,
      "Resuming must establish a new uptime checkpoint instead of charging stalled time"
    )

    harness.uptime.value = 2_006
    await harness.model.synchronizePlaybackProgress()
    XCTAssertEqual(harness.manager.snapshot.consumedPlaybackSeconds, 6, accuracy: 0.001)
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

  func testStoreKitPrepareLoadsOnlyTheExactNonConsumableAndPublishesMetadata() async {
    let gate = StoreKitProductsGate()
    let storeKit = StrictStoreKitClient(
      productGate: gate,
      entitlementResults: [.success(.noEntitlement)]
    )
    let manager = makeStoreManager(storeKit: storeKit)

    let preparation = Task { @MainActor in await manager.prepare() }
    await gate.waitUntilRequested()

    XCTAssertTrue(manager.snapshot.isStoreLoading)
    XCTAssertEqual(
      storeKit.productRequests,
      [[StoreKitMonetizationManager.fullUnlockProductID]]
    )
    XCTAssertEqual(
      storeKit.entitlementRequests,
      [StoreKitMonetizationManager.fullUnlockProductID]
    )

    gate.succeed(with: [Self.fullUnlockProduct])
    await preparation.value

    XCTAssertFalse(manager.snapshot.isStoreLoading)
    XCTAssertEqual(manager.snapshot.displayPrice, "$9.99")
    XCTAssertEqual(manager.snapshot.isFamilyShareable, true)
  }

  func testStoreKitPrepareRejectsMissingAndWrongTypeProducts() async {
    for products in [
      [StoreKitProduct](),
      [
        StoreKitProduct(
          id: StoreKitMonetizationManager.fullUnlockProductID,
          displayPrice: "$9.99",
          isFamilyShareable: true,
          type: .other
        )
      ],
      [
        StoreKitProduct(
          id: "com.spnss.player.not-the-unlock",
          displayPrice: "$0.01",
          isFamilyShareable: false,
          type: .nonConsumable
        )
      ],
    ] {
      let storeKit = StrictStoreKitClient(
        productResults: [.success(products)],
        entitlementResults: [.success(.noEntitlement)]
      )
      let manager = makeStoreManager(storeKit: storeKit)

      await manager.prepare()

      XCTAssertNil(manager.snapshot.displayPrice)
      XCTAssertNil(manager.snapshot.isFamilyShareable)
      XCTAssertNotNil(manager.snapshot.feedbackMessage)
      await manager.purchaseFullUnlock()
      XCTAssertTrue(storeKit.purchaseRequests.isEmpty)
    }
  }

  func testCachedOwnerSurvivesRefreshAmbiguityAndStoreOutage() async {
    let ambiguousEntitlements: [Result<StoreKitEntitlementStatus, Error>] = [
      .success(.noEntitlement),
      .success(.unverified),
      .success(.unavailable),
      .failure(StoreKitTestError.offline),
    ]

    for entitlement in ambiguousEntitlements {
      let storeKit = StrictStoreKitClient(entitlementResults: [entitlement])
      let manager = makeStoreManager(storeKit: storeKit, cachedUnlock: true)

      await manager.refreshEntitlement()

      XCTAssertTrue(manager.snapshot.isUnlocked)
      XCTAssertTrue(storeKit.finishRequests.isEmpty)
    }

    let storeKit = StrictStoreKitClient(
      productResults: [.failure(StoreKitTestError.offline)],
      entitlementResults: [.success(.noEntitlement)]
    )
    let manager = makeStoreManager(storeKit: storeKit, cachedUnlock: true)
    await manager.prepare()
    XCTAssertTrue(manager.snapshot.isUnlocked)
    XCTAssertFalse(manager.snapshot.isStoreLoading)
    XCTAssertTrue(manager.snapshot.feedbackMessage?.contains("could not be reached") == true)
  }

  func testRefreshAppliesVerifiedActiveAndRevokedOnlyInMatchingEnvironment() async {
    let activeStore = StrictStoreKitClient(entitlementResults: [
      .success(.active(Self.transaction(id: 101, environment: .sandbox)))
    ])
    let activeManager = makeStoreManager(storeKit: activeStore)
    await activeManager.refreshEntitlement()
    XCTAssertTrue(activeManager.snapshot.isUnlocked)
    XCTAssertEqual(activeStore.finishRequests, [101])

    let revokedStore = StrictStoreKitClient(entitlementResults: [
      .success(.revoked(Self.transaction(id: 102, environment: .sandbox, isRevoked: true)))
    ])
    let revokedManager = makeStoreManager(storeKit: revokedStore, cachedUnlock: true)
    await revokedManager.refreshEntitlement()
    XCTAssertFalse(revokedManager.snapshot.isUnlocked)
    XCTAssertEqual(revokedStore.finishRequests, [102])

    let mismatchStore = StrictStoreKitClient(entitlementResults: [
      .success(.active(Self.transaction(id: 103, environment: .production)))
    ])
    let mismatchManager = makeStoreManager(storeKit: mismatchStore, cachedUnlock: true)
    await mismatchManager.refreshEntitlement()
    XCTAssertTrue(mismatchManager.snapshot.isUnlocked)
    XCTAssertTrue(mismatchStore.finishRequests.isEmpty)
    XCTAssertTrue(
      mismatchManager.snapshot.feedbackMessage?.contains("different App Store environment") == true)
  }

  func testPurchaseOutcomesAreStrictAndOnlyAcceptedTransactionIsFinished() async {
    let verifiedStore = StrictStoreKitClient(
      productResults: [.success([Self.fullUnlockProduct])],
      purchaseResults: [.success(.success(.verified(Self.transaction(id: 201))))],
      entitlementResults: [.success(.noEntitlement)]
    )
    let verifiedManager = makeStoreManager(storeKit: verifiedStore)
    await verifiedManager.prepare()
    await verifiedManager.purchaseFullUnlock()
    XCTAssertTrue(verifiedManager.snapshot.isUnlocked)
    XCTAssertFalse(verifiedManager.snapshot.isActionInProgress)
    XCTAssertEqual(
      verifiedStore.purchaseRequests, [StoreKitMonetizationManager.fullUnlockProductID])
    XCTAssertEqual(verifiedStore.finishRequests, [201])

    let outcomes: [(StoreKitPurchaseResult, String?, Bool)] = [
      (
        .success(.unverified(productID: StoreKitMonetizationManager.fullUnlockProductID)),
        "couldn't verify", false
      ),
      (
        .success(.verified(Self.transaction(id: 202, productID: "wrong.product"))), "wrong product",
        false
      ),
      (
        .success(.verified(Self.transaction(id: 203, environment: .production))),
        "different App Store environment", false
      ),
      (.pending, "waiting for approval", false),
      (.userCancelled, nil, false),
      (.unknown, "did not complete", false),
    ]
    for (outcome, message, shouldFinish) in outcomes {
      let storeKit = StrictStoreKitClient(
        productResults: [.success([Self.fullUnlockProduct])],
        purchaseResults: [.success(outcome)],
        entitlementResults: [.success(.noEntitlement)]
      )
      let manager = makeStoreManager(storeKit: storeKit)
      await manager.prepare()
      await manager.purchaseFullUnlock()
      XCTAssertFalse(manager.snapshot.isUnlocked)
      XCTAssertFalse(manager.snapshot.isActionInProgress)
      XCTAssertEqual(
        manager.snapshot.feedbackMessage?.contains(message ?? ""), message == nil ? nil : true)
      XCTAssertEqual(!storeKit.finishRequests.isEmpty, shouldFinish)
    }

    let failingStore = StrictStoreKitClient(
      productResults: [.success([Self.fullUnlockProduct])],
      purchaseResults: [.failure(StoreKitTestError.offline)],
      entitlementResults: [.success(.noEntitlement)]
    )
    let failingManager = makeStoreManager(storeKit: failingStore)
    await failingManager.prepare()
    await failingManager.purchaseFullUnlock()
    XCTAssertFalse(failingManager.snapshot.isUnlocked)
    XCTAssertFalse(failingManager.snapshot.isActionInProgress)
    XCTAssertTrue(failingManager.snapshot.feedbackMessage?.contains("couldn't confirm") == true)
    XCTAssertTrue(failingStore.finishRequests.isEmpty)
  }

  func testRestoreIsAuthoritativeOnlyAfterSuccessfulSync() async {
    let activeStore = StrictStoreKitClient(
      syncResults: [.success(())],
      entitlementResults: [.success(.active(Self.transaction(id: 301)))]
    )
    let activeManager = makeStoreManager(storeKit: activeStore)
    await activeManager.restorePurchases()
    XCTAssertTrue(activeManager.snapshot.isUnlocked)
    XCTAssertEqual(activeStore.syncCallCount, 1)
    XCTAssertEqual(activeStore.finishRequests, [301])

    let emptyStore = StrictStoreKitClient(
      syncResults: [.success(())],
      entitlementResults: [.success(.noEntitlement)]
    )
    let emptyManager = makeStoreManager(storeKit: emptyStore, cachedUnlock: true)
    await emptyManager.restorePurchases()
    XCTAssertFalse(emptyManager.snapshot.isUnlocked)
    XCTAssertTrue(emptyManager.snapshot.feedbackMessage?.contains("No Full Unlock") == true)

    let failedStore = StrictStoreKitClient(syncResults: [.failure(StoreKitTestError.offline)])
    let failedManager = makeStoreManager(storeKit: failedStore, cachedUnlock: true)
    await failedManager.restorePurchases()
    XCTAssertTrue(failedManager.snapshot.isUnlocked)
    XCTAssertTrue(failedStore.entitlementRequests.isEmpty)
    XCTAssertFalse(failedManager.snapshot.isActionInProgress)
  }

  func testTransactionUpdatesApplyVerifiedStateAndIgnoreUnsafeUpdates() async {
    let storeKit = StrictStoreKitClient()
    let manager = makeStoreManager(storeKit: storeKit)
    await storeKit.waitUntilTransactionUpdatesSubscribed()

    let active = expectation(description: "verified update applied")
    let observer = Task { @MainActor in
      for await snapshot in manager.snapshotUpdates {
        if snapshot.isUnlocked {
          active.fulfill()
          return
        }
      }
    }
    storeKit.sendUpdate(.verified(Self.transaction(id: 401)))
    await fulfillment(of: [active], timeout: 2)
    observer.cancel()
    XCTAssertEqual(storeKit.finishRequests, [401])

    storeKit.sendUpdate(.verified(Self.transaction(id: 402, productID: "wrong.product")))
    storeKit.sendUpdate(.verified(Self.transaction(id: 403, environment: .production)))
    storeKit.sendUpdate(.unverified(productID: StoreKitMonetizationManager.fullUnlockProductID))
    let rejected = expectation(description: "unsafe updates classified")
    let rejectedObserver = Task { @MainActor in
      for await snapshot in manager.snapshotUpdates {
        if snapshot.feedbackMessage?.contains("couldn't verify") == true {
          rejected.fulfill()
          return
        }
      }
    }
    await fulfillment(of: [rejected], timeout: 2)
    rejectedObserver.cancel()
    XCTAssertTrue(manager.snapshot.isUnlocked)
    XCTAssertEqual(storeKit.finishRequests, [401])

    let revoked = expectation(description: "revocation update applied")
    let revokedObserver = Task { @MainActor in
      for await snapshot in manager.snapshotUpdates {
        if !snapshot.isUnlocked {
          revoked.fulfill()
          return
        }
      }
    }
    storeKit.sendUpdate(.verified(Self.transaction(id: 404, isRevoked: true)))
    await fulfillment(of: [revoked], timeout: 2)
    revokedObserver.cancel()
    XCTAssertEqual(storeKit.finishRequests, [401, 404])
  }

  func testOfferCodeOutcomesPreserveOrApplyEntitlementAuthoritatively() async {
    let cancelledStore = StrictStoreKitClient()
    let cancelledManager = makeStoreManager(storeKit: cancelledStore, cachedUnlock: true)
    await cancelledManager.handleOfferCodeRedemption(completed: false)
    XCTAssertEqual(cancelledManager.snapshot.offerCodeRedemptionOutcome, .failed)
    XCTAssertTrue(cancelledManager.snapshot.isUnlocked)
    XCTAssertTrue(cancelledStore.entitlementRequests.isEmpty)

    let cases: [(StoreKitEntitlementStatus, Bool, Bool, UInt64?)] = [
      (.active(Self.transaction(id: 501)), true, true, 501),
      (.revoked(Self.transaction(id: 502, isRevoked: true)), false, false, 502),
      (.noEntitlement, false, true, nil),
      (.unverified, false, true, nil),
      (.environmentMismatch, false, true, nil),
      (.unavailable, false, true, nil),
    ]
    for (status, confirmed, remainsUnlocked, finishedID) in cases {
      let storeKit = StrictStoreKitClient(entitlementResults: [.success(status)])
      let manager = makeStoreManager(storeKit: storeKit, cachedUnlock: true)
      await manager.handleOfferCodeRedemption(completed: true)
      XCTAssertEqual(
        manager.snapshot.offerCodeRedemptionOutcome,
        .completed(entitlementConfirmed: confirmed)
      )
      XCTAssertEqual(manager.snapshot.isUnlocked, remainsUnlocked)
      XCTAssertFalse(manager.snapshot.isActionInProgress)
      XCTAssertEqual(storeKit.finishRequests, finishedID.map { [$0] } ?? [])
    }
  }

  func testStoreKitManagerCacheIsIsolatedByEnvironment() async {
    let suiteName = "MonetizationStoreIsolation-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("Could not create isolated defaults")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = TestPlaybackAllowanceKeychain()
    let sandboxPersistence = PlaybackAllowancePersistence(
      storeEnvironment: .sandbox,
      userDefaults: defaults,
      keychainService: suiteName,
      keychain: keychain
    )
    let productionPersistence = PlaybackAllowancePersistence(
      storeEnvironment: .production,
      userDefaults: defaults,
      keychainService: suiteName,
      keychain: keychain
    )
    let sandboxStore = StrictStoreKitClient(entitlementResults: [
      .success(.active(Self.transaction(id: 601, environment: .sandbox)))
    ])
    let sandbox = StoreKitMonetizationManager(
      persistence: sandboxPersistence,
      storeEnvironment: .sandbox,
      storeKit: sandboxStore
    )
    await sandbox.refreshEntitlement()
    XCTAssertTrue(sandbox.snapshot.isUnlocked)

    let productionStore = StrictStoreKitClient(entitlementResults: [.success(.noEntitlement)])
    let production = StoreKitMonetizationManager(
      persistence: productionPersistence,
      storeEnvironment: .production,
      storeKit: productionStore
    )
    XCTAssertFalse(production.snapshot.isUnlocked)
    await production.refreshEntitlement()
    XCTAssertFalse(production.snapshot.isUnlocked)
    XCTAssertTrue(sandboxPersistence.loadCachedUnlock())
    XCTAssertFalse(productionPersistence.loadCachedUnlock())
  }

  private static let fullUnlockProduct = StoreKitProduct(
    id: StoreKitMonetizationManager.fullUnlockProductID,
    displayPrice: "$9.99",
    isFamilyShareable: true,
    type: .nonConsumable
  )

  private static func transaction(
    id: UInt64,
    productID: String = StoreKitMonetizationManager.fullUnlockProductID,
    environment: MonetizationStoreEnvironment? = .sandbox,
    isRevoked: Bool = false
  ) -> StoreKitTransaction {
    StoreKitTransaction(
      id: id,
      productID: productID,
      environment: environment,
      isRevoked: isRevoked
    )
  }

  private func makeStoreManager(
    storeKit: StrictStoreKitClient,
    environment: MonetizationStoreEnvironment = .sandbox,
    cachedUnlock: Bool = false
  ) -> StoreKitMonetizationManager {
    let suiteName = "StoreKitMonetizationTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Could not create isolated defaults")
    }
    addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
    let persistence = PlaybackAllowancePersistence(
      storeEnvironment: environment,
      userDefaults: defaults,
      keychainService: suiteName,
      keychain: TestPlaybackAllowanceKeychain()
    )
    persistence.saveCachedUnlock(cachedUnlock)
    return StoreKitMonetizationManager(
      persistence: persistence,
      storeEnvironment: environment,
      storeKit: storeKit
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
    let playback = StallablePlaybackController()
    let model = PlayerModel(
      environment: PlayerEnvironment(
        persistence: InMemoryLibraryStore(
          snapshot: LibrarySnapshot(books: [book], importJobs: [], currentBookID: bookID)
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: playback,
        monetization: manager,
        playbackUptime: uptime
      ))
    return MonetizationHarness(
      model: model,
      manager: manager,
      uptime: uptime,
      bookID: bookID,
      playback: playback
    )
  }
}

private enum StoreKitTestError: Error {
  case offline
  case unexpectedCall(String)
}

@MainActor
private final class StoreKitProductsGate {
  private var wasRequested = false
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private var resultContinuation: CheckedContinuation<[StoreKitProduct], Error>?

  func perform() async throws -> [StoreKitProduct] {
    precondition(resultContinuation == nil, "The product gate supports one request")
    wasRequested = true
    for waiter in requestWaiters {
      waiter.resume()
    }
    requestWaiters.removeAll()
    return try await withCheckedThrowingContinuation { continuation in
      resultContinuation = continuation
    }
  }

  func waitUntilRequested() async {
    if wasRequested { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func succeed(with products: [StoreKitProduct]) {
    guard let resultContinuation else {
      return XCTFail("Product request has not reached its gate")
    }
    self.resultContinuation = nil
    resultContinuation.resume(returning: products)
  }
}

@MainActor
private final class StrictStoreKitClient: StoreKitClient {
  private var productResults: [Result<[StoreKitProduct], Error>]
  private var purchaseResults: [Result<StoreKitPurchaseResult, Error>]
  private var syncResults: [Result<Void, Error>]
  private var entitlementResults: [Result<StoreKitEntitlementStatus, Error>]
  private let productGate: StoreKitProductsGate?
  private let updates: AsyncStream<StoreKitTransactionVerification>
  private let updatesContinuation: AsyncStream<StoreKitTransactionVerification>.Continuation
  private var updateSubscriptionWaiters: [CheckedContinuation<Void, Never>] = []

  private(set) var productRequests: [[String]] = []
  private(set) var purchaseRequests: [String] = []
  private(set) var syncCallCount = 0
  private(set) var entitlementRequests: [String] = []
  private(set) var transactionUpdatesCallCount = 0
  private(set) var finishRequests: [UInt64] = []

  init(
    productGate: StoreKitProductsGate? = nil,
    productResults: [Result<[StoreKitProduct], Error>] = [],
    purchaseResults: [Result<StoreKitPurchaseResult, Error>] = [],
    syncResults: [Result<Void, Error>] = [],
    entitlementResults: [Result<StoreKitEntitlementStatus, Error>] = []
  ) {
    self.productGate = productGate
    self.productResults = productResults
    self.purchaseResults = purchaseResults
    self.syncResults = syncResults
    self.entitlementResults = entitlementResults
    let stream = AsyncStream<StoreKitTransactionVerification>.makeStream(
      bufferingPolicy: .unbounded
    )
    updates = stream.stream
    updatesContinuation = stream.continuation
  }

  func products(for identifiers: [String]) async throws -> [StoreKitProduct] {
    productRequests.append(identifiers)
    if let productGate {
      return try await productGate.perform()
    }
    return try next(&productResults, operation: "products")
  }

  func purchase(productID: String) async throws -> StoreKitPurchaseResult {
    purchaseRequests.append(productID)
    return replacingFinish(in: try next(&purchaseResults, operation: "purchase"))
  }

  func sync() async throws {
    syncCallCount += 1
    _ = try next(&syncResults, operation: "sync")
  }

  func entitlementStatus(productID: String) async throws -> StoreKitEntitlementStatus {
    entitlementRequests.append(productID)
    return replacingFinish(in: try next(&entitlementResults, operation: "entitlement"))
  }

  func transactionUpdates() -> AsyncStream<StoreKitTransactionVerification> {
    transactionUpdatesCallCount += 1
    for waiter in updateSubscriptionWaiters {
      waiter.resume()
    }
    updateSubscriptionWaiters.removeAll()
    return updates
  }

  func waitUntilTransactionUpdatesSubscribed() async {
    if transactionUpdatesCallCount > 0 { return }
    await withCheckedContinuation { continuation in
      updateSubscriptionWaiters.append(continuation)
    }
  }

  func sendUpdate(_ update: StoreKitTransactionVerification) {
    updatesContinuation.yield(replacingFinish(in: update))
  }

  private func replacingFinish(
    in update: StoreKitTransactionVerification
  ) -> StoreKitTransactionVerification {
    switch update {
    case .verified(let transaction):
      let id = transaction.id
      return .verified(
        StoreKitTransaction(
          id: id,
          productID: transaction.productID,
          environment: transaction.environment,
          isRevoked: transaction.isRevoked,
          finish: { [weak self] in await self?.recordFinish(id) }
        ))
    case .unverified:
      return update
    }
  }

  private func replacingFinish(in result: StoreKitPurchaseResult) -> StoreKitPurchaseResult {
    switch result {
    case .success(let verification): .success(replacingFinish(in: verification))
    case .pending: .pending
    case .userCancelled: .userCancelled
    case .unknown: .unknown
    }
  }

  private func replacingFinish(
    in status: StoreKitEntitlementStatus
  ) -> StoreKitEntitlementStatus {
    switch status {
    case .active(let transaction):
      guard case .verified(let replacement) = replacingFinish(in: .verified(transaction)) else {
        preconditionFailure("Verified transaction replacement must remain verified")
      }
      return .active(replacement)
    case .revoked(let transaction):
      guard case .verified(let replacement) = replacingFinish(in: .verified(transaction)) else {
        preconditionFailure("Verified transaction replacement must remain verified")
      }
      return .revoked(replacement)
    case .noEntitlement: return .noEntitlement
    case .unverified: return .unverified
    case .environmentMismatch: return .environmentMismatch
    case .unavailable: return .unavailable
    }
  }

  private func recordFinish(_ id: UInt64) {
    finishRequests.append(id)
  }

  private func next<Value>(
    _ results: inout [Result<Value, Error>],
    operation: String
  ) throws -> Value {
    guard !results.isEmpty else {
      XCTFail("Unexpected StoreKit \(operation) call")
      throw StoreKitTestError.unexpectedCall(operation)
    }
    return try results.removeFirst().get()
  }
}

@MainActor
private struct MonetizationHarness {
  let model: PlayerModel
  let manager: DeterministicMonetizationManager
  let uptime: MutablePlaybackUptime
  let bookID: UUID
  let playback: StallablePlaybackController
}

@MainActor
private final class StallablePlaybackController: AudioPlaybackControlling {
  private let base = DeterministicPlaybackController()
  var isAdvancing = true

  var state: PlaybackState { base.state }
  var currentPositionSeconds: Double { base.currentPositionSeconds }
  var playbackRate: Double { base.playbackRate }
  var isPlaybackAdvancing: Bool { state.status == .playing && isAdvancing }

  func load(url: URL, bookID: UUID, at seconds: Double) async throws {
    try await base.load(url: url, bookID: bookID, at: seconds)
  }

  func seek(to seconds: Double) async { await base.seek(to: seconds) }
  func setPlaybackRate(_ rate: Double) { base.setPlaybackRate(rate) }
  func play() { base.play() }
  func pause() { base.pause() }
  func beginSleepFade(durationSeconds: TimeInterval) {
    base.beginSleepFade(durationSeconds: durationSeconds)
  }
  func completeSleepFadeAndPause() { base.completeSleepFadeAndPause() }
  func cancelSleepFade() { base.cancelSleepFade() }
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
