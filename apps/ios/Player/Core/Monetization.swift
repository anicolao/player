import Foundation
import Security
import StoreKit

enum MonetizationStoreEnvironment: String, Sendable {
  case sandbox
  case production

  static var current: Self {
    if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
      return .sandbox
    }
    #if DEBUG
      return .sandbox
    #else
      return .production
    #endif
  }
}

enum OfferCodeRedemptionOutcome: Equatable, Sendable {
  case completed(entitlementConfirmed: Bool)
  case failed
}

enum PremiumEntitlement: String, Codable, Equatable, Sendable {
  case includedPlayback
  case fullUnlock
}

struct MonetizationSnapshot: Equatable, Sendable {
  static let includedPlaybackSeconds: TimeInterval = 50 * 60 * 60

  var entitlement: PremiumEntitlement
  var consumedPlaybackSeconds: TimeInterval
  var displayPrice: String?
  var isStoreLoading: Bool
  var isActionInProgress: Bool
  var feedbackMessage: String?
  var isFamilyShareable: Bool? = nil
  var offerCodeRedemptionOutcome: OfferCodeRedemptionOutcome? = nil

  static let included = MonetizationSnapshot(
    entitlement: .includedPlayback,
    consumedPlaybackSeconds: 0,
    displayPrice: nil,
    isStoreLoading: false,
    isActionInProgress: false,
    feedbackMessage: nil
  )

  static let unlockedForTesting = MonetizationSnapshot(
    entitlement: .fullUnlock,
    consumedPlaybackSeconds: 0,
    displayPrice: "$9.99",
    isStoreLoading: false,
    isActionInProgress: false,
    feedbackMessage: nil
  )

  var isUnlocked: Bool { entitlement == .fullUnlock }

  var remainingPlaybackSeconds: TimeInterval {
    max(0, Self.includedPlaybackSeconds - consumedPlaybackSeconds)
  }

  var canStartPlayback: Bool {
    isUnlocked || remainingPlaybackSeconds > 0
  }

  var remainingPlaybackDescription: String {
    let roundedMinutes = Int(ceil(remainingPlaybackSeconds / 60))
    let hours = roundedMinutes / 60
    let minutes = roundedMinutes % 60
    if hours > 0, minutes > 0 { return "\(hours)h \(minutes)m remaining" }
    if hours > 0 { return "\(hours)h remaining" }
    return "\(minutes)m remaining"
  }
}

@MainActor
protocol MonetizationManaging: AnyObject {
  var snapshot: MonetizationSnapshot { get }
  var snapshotUpdates: AsyncStream<MonetizationSnapshot> { get }
  func prepare() async
  func recordPlayback(seconds: TimeInterval) async
  func purchaseFullUnlock() async
  func restorePurchases() async
  func refreshEntitlement() async
  func handleOfferCodeRedemption(completed: Bool) async
}

extension MonetizationManaging {
  var snapshotUpdates: AsyncStream<MonetizationSnapshot> {
    let snapshot = snapshot
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      continuation.yield(snapshot)
      continuation.finish()
    }
  }

  func handleOfferCodeRedemption(completed: Bool) async {}
}

@MainActor
final class DisabledMonetizationManager: MonetizationManaging {
  private(set) var snapshot = MonetizationSnapshot.unlockedForTesting

  func prepare() async {}
  func recordPlayback(seconds: TimeInterval) async {}
  func purchaseFullUnlock() async {}
  func restorePurchases() async {}
  func refreshEntitlement() async {}
}

@MainActor
final class DeterministicMonetizationManager: MonetizationManaging {
  private(set) var snapshot: MonetizationSnapshot

  init(snapshot: MonetizationSnapshot) {
    self.snapshot = snapshot
  }

  func prepare() async {}

  func recordPlayback(seconds: TimeInterval) async {
    guard !snapshot.isUnlocked, seconds.isFinite, seconds > 0 else { return }
    snapshot.consumedPlaybackSeconds = min(
      MonetizationSnapshot.includedPlaybackSeconds,
      snapshot.consumedPlaybackSeconds + seconds
    )
  }

  func purchaseFullUnlock() async {
    snapshot.entitlement = .fullUnlock
    snapshot.feedbackMessage = "Bookshelf is unlocked on this device."
  }

  func restorePurchases() async {
    snapshot.entitlement = .fullUnlock
    snapshot.feedbackMessage = "Your Full Unlock was restored."
  }

  func refreshEntitlement() async {}
}

@MainActor
final class StoreKitMonetizationManager: MonetizationManaging {
  static let fullUnlockProductID = "com.spnss.player.fullunlock"

  private(set) var snapshot: MonetizationSnapshot {
    didSet { publishSnapshot() }
  }
  private let persistence: PlaybackAllowancePersistence
  private let storeEnvironment: MonetizationStoreEnvironment
  private let storeKit: any StoreKitClient
  private var product: StoreKitProduct?
  private var transactionUpdatesTask: Task<Void, Never>?
  private var snapshotContinuations: [UUID: AsyncStream<MonetizationSnapshot>.Continuation] = [:]

  init(
    persistence: PlaybackAllowancePersistence? = nil,
    storeEnvironment: MonetizationStoreEnvironment = .current,
    userDefaults: UserDefaults = .standard,
    storeKit: any StoreKitClient = SystemStoreKitClient()
  ) {
    let persistence =
      persistence
      ?? PlaybackAllowancePersistence(
        storeEnvironment: storeEnvironment,
        userDefaults: userDefaults
      )
    self.persistence = persistence
    self.storeEnvironment = storeEnvironment
    self.storeKit = storeKit
    let consumed = persistence.loadConsumedPlaybackSeconds()
    let cachedUnlock = persistence.loadCachedUnlock()
    snapshot = MonetizationSnapshot(
      entitlement: cachedUnlock ? .fullUnlock : .includedPlayback,
      consumedPlaybackSeconds: consumed,
      displayPrice: nil,
      isStoreLoading: false,
      isActionInProgress: false,
      feedbackMessage: nil
    )
    transactionUpdatesTask = Task { @MainActor [weak self, storeKit] in
      for await result in storeKit.transactionUpdates() {
        guard !Task.isCancelled, let self else { return }
        await self.processTransactionUpdate(result)
      }
    }
  }

  deinit {
    transactionUpdatesTask?.cancel()
  }

  var snapshotUpdates: AsyncStream<MonetizationSnapshot> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let id = UUID()
      snapshotContinuations[id] = continuation
      continuation.yield(snapshot)
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor in
          self?.snapshotContinuations.removeValue(forKey: id)
        }
      }
    }
  }

  func prepare() async {
    snapshot.isStoreLoading = true
    snapshot.feedbackMessage = nil
    await refreshEntitlement()
    do {
      let loadedProduct = try await storeKit.products(for: [Self.fullUnlockProductID])
        .first(where: { $0.id == Self.fullUnlockProductID })
      guard let loadedProduct else {
        product = nil
        snapshot.displayPrice = nil
        snapshot.isFamilyShareable = nil
        snapshot.feedbackMessage = "The Full Unlock is not available from the App Store yet."
        snapshot.isStoreLoading = false
        return
      }
      guard loadedProduct.type == .nonConsumable else {
        product = nil
        snapshot.displayPrice = nil
        snapshot.isFamilyShareable = nil
        snapshot.feedbackMessage =
          "The App Store returned an invalid Full Unlock product. Please contact Bookshelf Support."
        snapshot.isStoreLoading = false
        return
      }
      product = loadedProduct
      snapshot.displayPrice = loadedProduct.displayPrice
      snapshot.isFamilyShareable = loadedProduct.isFamilyShareable
    } catch {
      snapshot.feedbackMessage =
        "The App Store could not be reached. You can keep using your included playback and try again later."
    }
    snapshot.isStoreLoading = false
  }

  func recordPlayback(seconds: TimeInterval) async {
    guard !snapshot.isUnlocked, seconds.isFinite, seconds > 0 else { return }
    snapshot.consumedPlaybackSeconds = min(
      MonetizationSnapshot.includedPlaybackSeconds,
      snapshot.consumedPlaybackSeconds + seconds
    )
    let persistenceStatus = persistence.saveConsumedPlaybackSeconds(
      snapshot.consumedPlaybackSeconds
    )
    if persistenceStatus != errSecSuccess {
      snapshot.feedbackMessage =
        "Bookshelf couldn't securely save your included playback usage. "
        + "Your library is unchanged; restart Bookshelf before continuing playback."
    }
  }

  func purchaseFullUnlock() async {
    guard !snapshot.isActionInProgress else { return }
    guard !snapshot.isUnlocked else {
      snapshot.feedbackMessage = "Bookshelf is already unlocked."
      return
    }
    guard let product else {
      snapshot.feedbackMessage = "The Full Unlock is not available from the App Store yet."
      return
    }
    snapshot.isActionInProgress = true
    snapshot.feedbackMessage = nil
    defer { snapshot.isActionInProgress = false }
    do {
      switch try await storeKit.purchase(productID: product.id) {
      case .success(let verification):
        switch verification {
        case .verified(let transaction):
          guard transaction.productID == Self.fullUnlockProductID else {
            throw StoreKitMonetizationError.unexpectedProduct
          }
          guard transaction.environment == storeEnvironment else {
            snapshot.feedbackMessage = environmentMismatchMessage
            return
          }
          setUnlocked(!transaction.isRevoked)
          snapshot.feedbackMessage =
            snapshot.isUnlocked
            ? "Bookshelf is unlocked on this device."
            : "This purchase was refunded or revoked. Your library is unchanged."
          await transaction.finish()
        case .unverified:
          snapshot.feedbackMessage =
            "Apple returned a Full Unlock purchase that Bookshelf couldn't verify. "
            + "No unlock was applied. Try Restore Purchases, or contact Bookshelf Support if Apple charged you."
        }
      case .pending:
        snapshot.feedbackMessage =
          "The purchase is waiting for approval. Bookshelf will unlock when Apple confirms it."
      case .userCancelled:
        snapshot.feedbackMessage = nil
      case .unknown:
        snapshot.feedbackMessage = "The App Store did not complete the purchase. Please try again."
      }
    } catch StoreKitMonetizationError.unexpectedProduct {
      snapshot.feedbackMessage =
        "The App Store returned the wrong product. No unlock was applied; please contact Bookshelf Support."
    } catch {
      snapshot.feedbackMessage =
        "Bookshelf couldn't confirm the purchase. Try again, or use Restore Purchases if Apple completed the charge."
    }
  }

  func restorePurchases() async {
    guard !snapshot.isActionInProgress else { return }
    snapshot.isActionInProgress = true
    snapshot.feedbackMessage = nil
    defer { snapshot.isActionInProgress = false }
    do {
      try await storeKit.sync()
      switch await entitlementStatus() {
      case .active(let transaction):
        setUnlocked(true)
        snapshot.feedbackMessage = "Your Full Unlock was restored."
        await transaction.finish()
      case .revoked(let transaction):
        setUnlocked(false)
        snapshot.feedbackMessage =
          "The Full Unlock for this Apple Account was refunded or revoked. Your library is unchanged."
        await transaction.finish()
      case .noEntitlement:
        // A successful explicit App Store sync followed by an empty entitlement
        // result is authoritative. Ordinary refresh deliberately does not make
        // this inference because an offline StoreKit cache may be incomplete.
        setUnlocked(false)
        snapshot.feedbackMessage = "No Full Unlock was found for this Apple Account."
      case .unverified:
        snapshot.feedbackMessage = unverifiedEntitlementMessage
      case .environmentMismatch:
        snapshot.feedbackMessage = environmentMismatchMessage
      case .unavailable:
        snapshot.feedbackMessage =
          "Apple synced your purchases, but Bookshelf couldn't confirm the Full Unlock. "
          + "Your existing access is unchanged; try again later."
      }
    } catch {
      snapshot.feedbackMessage =
        "Purchases could not be restored. Check your connection and Apple Account, then try again."
    }
  }

  func refreshEntitlement() async {
    switch await entitlementStatus() {
    case .active(let transaction):
      setUnlocked(true)
      await transaction.finish()
    case .revoked(let transaction):
      setUnlocked(false)
      snapshot.feedbackMessage =
        "The Full Unlock was refunded or revoked. Your library is unchanged."
      await transaction.finish()
    case .noEntitlement:
      // Absence during an ordinary refresh is not authoritative enough to erase
      // an entitlement previously verified and cached in this environment.
      break
    case .unverified:
      snapshot.feedbackMessage = unverifiedEntitlementMessage
    case .environmentMismatch:
      snapshot.feedbackMessage = environmentMismatchMessage
    case .unavailable:
      // Preserve a verified cached owner through storefront/network ambiguity.
      break
    }
  }

  func handleOfferCodeRedemption(completed: Bool) async {
    guard !snapshot.isActionInProgress else { return }
    snapshot.isActionInProgress = true
    defer { snapshot.isActionInProgress = false }
    guard completed else {
      snapshot.offerCodeRedemptionOutcome = .failed
      snapshot.feedbackMessage =
        "The offer-code sheet couldn't be completed. No Bookshelf access was changed."
      return
    }

    switch await entitlementStatus() {
    case .active(let transaction):
      setUnlocked(true)
      snapshot.offerCodeRedemptionOutcome = .completed(entitlementConfirmed: true)
      snapshot.feedbackMessage = "Your offer code unlocked Bookshelf."
      await transaction.finish()
    case .revoked(let transaction):
      setUnlocked(false)
      snapshot.offerCodeRedemptionOutcome = .completed(entitlementConfirmed: false)
      snapshot.feedbackMessage =
        "The offer-code sheet closed, but the Full Unlock was refunded or revoked."
      await transaction.finish()
    case .noEntitlement:
      snapshot.offerCodeRedemptionOutcome = .completed(entitlementConfirmed: false)
      snapshot.feedbackMessage =
        "The offer-code sheet closed, but Apple hasn't confirmed a Full Unlock yet. "
        + "Bookshelf will unlock automatically when confirmation arrives."
    case .unverified:
      snapshot.offerCodeRedemptionOutcome = .completed(entitlementConfirmed: false)
      snapshot.feedbackMessage = unverifiedEntitlementMessage
    case .environmentMismatch:
      snapshot.offerCodeRedemptionOutcome = .completed(entitlementConfirmed: false)
      snapshot.feedbackMessage = environmentMismatchMessage
    case .unavailable:
      snapshot.offerCodeRedemptionOutcome = .completed(entitlementConfirmed: false)
      snapshot.feedbackMessage =
        "The offer-code sheet closed, but Bookshelf couldn't contact the App Store to confirm an unlock."
    }
  }

  private func processTransactionUpdate(
    _ result: StoreKitTransactionVerification
  ) async {
    switch result {
    case .verified(let transaction):
      guard transaction.productID == Self.fullUnlockProductID else { return }
      guard transaction.environment == storeEnvironment else {
        snapshot.feedbackMessage = environmentMismatchMessage
        return
      }
      setUnlocked(!transaction.isRevoked)
      snapshot.feedbackMessage =
        snapshot.isUnlocked
        ? "Bookshelf is unlocked on this device."
        : "The Full Unlock was refunded or revoked. Your library is unchanged."
      await transaction.finish()
    case .unverified(let productID):
      guard productID == Self.fullUnlockProductID else { return }
      snapshot.feedbackMessage = unverifiedEntitlementMessage
    }
  }

  private func setUnlocked(_ isUnlocked: Bool) {
    snapshot.entitlement = isUnlocked ? .fullUnlock : .includedPlayback
    persistence.saveCachedUnlock(isUnlocked)
  }

  private func entitlementStatus() async -> StoreKitEntitlementStatus {
    do {
      let status = try await storeKit.entitlementStatus(productID: Self.fullUnlockProductID)
      switch status {
      case .active(let transaction):
        return transaction.environment == storeEnvironment
          ? .active(transaction) : .environmentMismatch
      case .revoked(let transaction):
        return transaction.environment == storeEnvironment
          ? .revoked(transaction) : .environmentMismatch
      case .noEntitlement, .unverified, .environmentMismatch, .unavailable:
        return status
      }
    } catch {
      return .unavailable
    }
  }

  private var unverifiedEntitlementMessage: String {
    "Apple returned Full Unlock information that Bookshelf couldn't verify. "
      + "Your existing access is unchanged; try Restore Purchases again later."
  }

  private var environmentMismatchMessage: String {
    "Apple returned Full Unlock information from a different App Store environment. "
      + "Bookshelf did not apply it, so test and production purchases remain separate."
  }

  private func publishSnapshot() {
    for continuation in snapshotContinuations.values {
      continuation.yield(snapshot)
    }
  }
}

private enum StoreKitMonetizationError: Error {
  case unexpectedProduct
}

enum StoreKitProductType: Equatable, Sendable {
  case nonConsumable
  case other
}

struct StoreKitProduct: Equatable, Sendable {
  var id: String
  var displayPrice: String
  var isFamilyShareable: Bool
  var type: StoreKitProductType
}

struct StoreKitTransaction: Sendable {
  var id: UInt64
  var productID: String
  var environment: MonetizationStoreEnvironment?
  var isRevoked: Bool
  private let finishOperation: @Sendable () async -> Void

  init(
    id: UInt64,
    productID: String,
    environment: MonetizationStoreEnvironment?,
    isRevoked: Bool,
    finish: @escaping @Sendable () async -> Void = {}
  ) {
    self.id = id
    self.productID = productID
    self.environment = environment
    self.isRevoked = isRevoked
    finishOperation = finish
  }

  func finish() async {
    await finishOperation()
  }
}

enum StoreKitTransactionVerification: Sendable {
  case verified(StoreKitTransaction)
  case unverified(productID: String)
}

enum StoreKitPurchaseResult: Sendable {
  case success(StoreKitTransactionVerification)
  case pending
  case userCancelled
  case unknown
}

enum StoreKitEntitlementStatus: Sendable {
  case active(StoreKitTransaction)
  case revoked(StoreKitTransaction)
  case noEntitlement
  case unverified
  case environmentMismatch
  case unavailable
}

@MainActor
protocol StoreKitClient: AnyObject {
  func products(for identifiers: [String]) async throws -> [StoreKitProduct]
  func purchase(productID: String) async throws -> StoreKitPurchaseResult
  func sync() async throws
  func entitlementStatus(productID: String) async throws -> StoreKitEntitlementStatus
  func transactionUpdates() -> AsyncStream<StoreKitTransactionVerification>
}

@MainActor
final class SystemStoreKitClient: StoreKitClient {
  private var productsByID: [String: Product] = [:]

  func products(for identifiers: [String]) async throws -> [StoreKitProduct] {
    let products = try await Product.products(for: identifiers)
    productsByID.merge(products.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    return products.map(Self.product)
  }

  func purchase(productID: String) async throws -> StoreKitPurchaseResult {
    guard let product = productsByID[productID] else {
      throw StoreKitMonetizationError.unexpectedProduct
    }
    switch try await product.purchase() {
    case .success(let result): return .success(Self.verification(result))
    case .pending: return .pending
    case .userCancelled: return .userCancelled
    @unknown default: return .unknown
    }
  }

  func sync() async throws {
    try await AppStore.sync()
  }

  func entitlementStatus(productID: String) async throws -> StoreKitEntitlementStatus {
    var foundUnverified = false
    for await result in Transaction.currentEntitlements {
      switch result {
      case .verified(let transaction) where transaction.productID == productID:
        let value = Self.transaction(transaction)
        return value.isRevoked ? .revoked(value) : .active(value)
      case .unverified(let transaction, _) where transaction.productID == productID:
        foundUnverified = true
      default:
        continue
      }
    }

    if let latest = await Transaction.latest(for: productID) {
      switch latest {
      case .verified(let transaction):
        let value = Self.transaction(transaction)
        return value.isRevoked ? .revoked(value) : .active(value)
      case .unverified:
        foundUnverified = true
      }
    }
    return foundUnverified ? .unverified : .noEntitlement
  }

  func transactionUpdates() -> AsyncStream<StoreKitTransactionVerification> {
    AsyncStream { continuation in
      let task = Task {
        for await result in Transaction.updates {
          guard !Task.isCancelled else { break }
          continuation.yield(Self.verification(result))
        }
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  private static func product(_ product: Product) -> StoreKitProduct {
    StoreKitProduct(
      id: product.id,
      displayPrice: product.displayPrice,
      isFamilyShareable: product.isFamilyShareable,
      type: product.type == .nonConsumable ? .nonConsumable : .other
    )
  }

  private static func verification(
    _ result: VerificationResult<Transaction>
  ) -> StoreKitTransactionVerification {
    switch result {
    case .verified(let transaction): .verified(Self.transaction(transaction))
    case .unverified(let transaction, _): .unverified(productID: transaction.productID)
    }
  }

  private static func transaction(_ transaction: Transaction) -> StoreKitTransaction {
    StoreKitTransaction(
      id: transaction.id,
      productID: transaction.productID,
      environment: storeEnvironment(transaction.environment),
      isRevoked: transaction.revocationDate != nil,
      finish: { await transaction.finish() }
    )
  }

  private static func storeEnvironment(
    _ environment: AppStore.Environment
  ) -> MonetizationStoreEnvironment? {
    if environment == .production { return .production }
    if environment == .sandbox || environment == .xcode { return .sandbox }
    return nil
  }
}

@MainActor
protocol PlaybackAllowanceKeychain {
  func loadSeconds(service: String, account: String) -> TimeInterval?
  func saveSeconds(_ seconds: TimeInterval, service: String, account: String) -> OSStatus
}

@MainActor
struct SystemPlaybackAllowanceKeychain: PlaybackAllowanceKeychain {
  func loadSeconds(service: String, account: String) -> TimeInterval? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data,
      let text = String(data: data, encoding: .utf8),
      let seconds = TimeInterval(text), seconds.isFinite
    else { return nil }
    return seconds
  }

  func saveSeconds(_ seconds: TimeInterval, service: String, account: String) -> OSStatus {
    let data = Data(String(format: "%.3f", seconds).utf8)
    let lookup: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
    guard status == errSecItemNotFound else { return status }
    var addition = lookup
    addition[kSecValueData as String] = data
    addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(addition as CFDictionary, nil)
  }
}

@MainActor
final class PlaybackAllowancePersistence {
  private static let keychainService = "com.spnss.player.monetization"

  private let userDefaults: UserDefaults
  private let cachedUnlockKey: String
  private let defaultsSecondsKey: String
  private let keychainService: String
  private let keychainAccount: String
  private let keychain: any PlaybackAllowanceKeychain

  init(
    storeEnvironment: MonetizationStoreEnvironment = .current,
    userDefaults: UserDefaults = .standard,
    keychainService: String = PlaybackAllowancePersistence.keychainService,
    keychain: any PlaybackAllowanceKeychain = SystemPlaybackAllowanceKeychain()
  ) {
    self.userDefaults = userDefaults
    self.keychainService = keychainService
    self.keychain = keychain
    let namespace = storeEnvironment.rawValue
    cachedUnlockKey = "monetization.\(namespace).full-unlock.cached-v1"
    defaultsSecondsKey = "monetization.\(namespace).playback-seconds-v1"
    keychainAccount = "\(namespace).included-playback-seconds-v1"
  }

  func loadConsumedPlaybackSeconds() -> TimeInterval {
    let defaultsValue = userDefaults.double(forKey: defaultsSecondsKey)
    let keychainValue =
      keychain.loadSeconds(
        service: keychainService,
        account: keychainAccount
      ) ?? 0
    return min(
      MonetizationSnapshot.includedPlaybackSeconds,
      max(0, max(defaultsValue, keychainValue))
    )
  }

  @discardableResult
  func saveConsumedPlaybackSeconds(_ seconds: TimeInterval) -> OSStatus {
    let normalized = min(
      MonetizationSnapshot.includedPlaybackSeconds,
      max(0, seconds.isFinite ? seconds : 0)
    )
    userDefaults.set(normalized, forKey: defaultsSecondsKey)
    return keychain.saveSeconds(
      normalized,
      service: keychainService,
      account: keychainAccount
    )
  }

  func loadCachedUnlock() -> Bool {
    userDefaults.bool(forKey: cachedUnlockKey)
  }

  func saveCachedUnlock(_ isUnlocked: Bool) {
    userDefaults.set(isUnlocked, forKey: cachedUnlockKey)
  }

}

protocol PlaybackUptimeProviding: Sendable {
  func now() -> TimeInterval
}

struct SystemPlaybackUptime: PlaybackUptimeProviding {
  func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

final class MutablePlaybackUptime: PlaybackUptimeProviding, @unchecked Sendable {
  var value: TimeInterval

  init(value: TimeInterval = 0) {
    self.value = value
  }

  func now() -> TimeInterval { value }
}
