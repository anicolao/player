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
  func prepare() async
  func recordPlayback(seconds: TimeInterval) async
  func purchaseFullUnlock() async
  func restorePurchases() async
  func refreshEntitlement() async
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

  private(set) var snapshot: MonetizationSnapshot
  private let persistence: PlaybackAllowancePersistence
  private var product: Product?
  private var transactionUpdatesTask: Task<Void, Never>?

  init(
    persistence: PlaybackAllowancePersistence? = nil,
    storeEnvironment: MonetizationStoreEnvironment = .current,
    userDefaults: UserDefaults = .standard
  ) {
    let persistence = persistence ?? PlaybackAllowancePersistence(
      storeEnvironment: storeEnvironment,
      userDefaults: userDefaults
    )
    self.persistence = persistence
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
    transactionUpdatesTask = Task { @MainActor [weak self] in
      for await result in Transaction.updates {
        guard !Task.isCancelled, let self else { return }
        await self.processTransactionUpdate(result)
      }
    }
  }

  func prepare() async {
    snapshot.isStoreLoading = true
    snapshot.feedbackMessage = nil
    await refreshEntitlement()
    do {
      product = try await Product.products(for: [Self.fullUnlockProductID]).first
      snapshot.displayPrice = product?.displayPrice
      if product == nil {
        snapshot.feedbackMessage = "The Full Unlock is not available from the App Store yet."
      }
    } catch {
      snapshot.feedbackMessage = "The App Store could not be reached. You can keep using your included playback and try again later."
    }
    snapshot.isStoreLoading = false
  }

  func recordPlayback(seconds: TimeInterval) async {
    guard !snapshot.isUnlocked, seconds.isFinite, seconds > 0 else { return }
    snapshot.consumedPlaybackSeconds = min(
      MonetizationSnapshot.includedPlaybackSeconds,
      snapshot.consumedPlaybackSeconds + seconds
    )
    persistence.saveConsumedPlaybackSeconds(snapshot.consumedPlaybackSeconds)
  }

  func purchaseFullUnlock() async {
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
      switch try await product.purchase() {
      case .success(let verification):
        let transaction = try verified(verification)
        guard transaction.productID == Self.fullUnlockProductID else {
          throw StoreKitMonetizationError.unexpectedProduct
        }
        setUnlocked(transaction.revocationDate == nil)
        snapshot.feedbackMessage = snapshot.isUnlocked
          ? "Bookshelf is unlocked on this device."
          : "This purchase is no longer active."
        await transaction.finish()
      case .pending:
        snapshot.feedbackMessage = "The purchase is waiting for approval. Bookshelf will unlock when Apple confirms it."
      case .userCancelled:
        snapshot.feedbackMessage = nil
      @unknown default:
        snapshot.feedbackMessage = "The App Store did not complete the purchase. Please try again."
      }
    } catch {
      snapshot.feedbackMessage = "The purchase could not be completed. No charge was made. Please try again."
    }
  }

  func restorePurchases() async {
    snapshot.isActionInProgress = true
    snapshot.feedbackMessage = nil
    defer { snapshot.isActionInProgress = false }
    do {
      try await AppStore.sync()
      await refreshEntitlement()
      snapshot.feedbackMessage = snapshot.isUnlocked
        ? "Your Full Unlock was restored."
        : "No Full Unlock was found for this Apple Account."
    } catch {
      snapshot.feedbackMessage = "Purchases could not be restored. Check your connection and Apple Account, then try again."
    }
  }

  func refreshEntitlement() async {
    var verifiedUnlock: Transaction?
    for await result in Transaction.currentEntitlements {
      guard case .verified(let transaction) = result,
        transaction.productID == Self.fullUnlockProductID
      else { continue }
      verifiedUnlock = transaction
      break
    }

    if let verifiedUnlock {
      setUnlocked(verifiedUnlock.revocationDate == nil)
      return
    }

    if let latest = await Transaction.latest(for: Self.fullUnlockProductID),
      case .verified(let transaction) = latest,
      transaction.revocationDate != nil
    {
      setUnlocked(false)
    }
    // When StoreKit has no definitive result, retain a previously verified
    // cached unlock so a network or storefront outage never relocks an owner.
  }

  private func processTransactionUpdate(
    _ result: VerificationResult<Transaction>
  ) async {
    guard case .verified(let transaction) = result,
      transaction.productID == Self.fullUnlockProductID
    else { return }
    setUnlocked(transaction.revocationDate == nil)
    snapshot.feedbackMessage = snapshot.isUnlocked
      ? "Bookshelf is unlocked on this device."
      : "The Full Unlock was refunded or revoked. Your library is unchanged."
    await transaction.finish()
  }

  private func setUnlocked(_ isUnlocked: Bool) {
    snapshot.entitlement = isUnlocked ? .fullUnlock : .includedPlayback
    persistence.saveCachedUnlock(isUnlocked)
  }

  private func verified<T>(_ result: VerificationResult<T>) throws -> T {
    switch result {
    case .verified(let value): value
    case .unverified: throw StoreKitMonetizationError.failedVerification
    }
  }
}

private enum StoreKitMonetizationError: Error {
  case failedVerification
  case unexpectedProduct
}

@MainActor
final class PlaybackAllowancePersistence {
  private static let keychainService = "com.spnss.player.monetization"

  private let userDefaults: UserDefaults
  private let cachedUnlockKey: String
  private let defaultsSecondsKey: String
  private let keychainService: String
  private let keychainAccount: String

  init(
    storeEnvironment: MonetizationStoreEnvironment = .current,
    userDefaults: UserDefaults = .standard,
    keychainService: String = PlaybackAllowancePersistence.keychainService
  ) {
    self.userDefaults = userDefaults
    self.keychainService = keychainService
    let namespace = storeEnvironment.rawValue
    cachedUnlockKey = "monetization.\(namespace).full-unlock.cached-v1"
    defaultsSecondsKey = "monetization.\(namespace).playback-seconds-v1"
    keychainAccount = "\(namespace).included-playback-seconds-v1"
  }

  func loadConsumedPlaybackSeconds() -> TimeInterval {
    let defaultsValue = userDefaults.double(forKey: defaultsSecondsKey)
    let keychainValue = loadKeychainSeconds() ?? 0
    return min(
      MonetizationSnapshot.includedPlaybackSeconds,
      max(0, max(defaultsValue, keychainValue))
    )
  }

  func saveConsumedPlaybackSeconds(_ seconds: TimeInterval) {
    let normalized = min(
      MonetizationSnapshot.includedPlaybackSeconds,
      max(0, seconds.isFinite ? seconds : 0)
    )
    userDefaults.set(normalized, forKey: defaultsSecondsKey)
    saveKeychainSeconds(normalized)
  }

  func loadCachedUnlock() -> Bool {
    userDefaults.bool(forKey: cachedUnlockKey)
  }

  func saveCachedUnlock(_ isUnlocked: Bool) {
    userDefaults.set(isUnlocked, forKey: cachedUnlockKey)
  }

  private func loadKeychainSeconds() -> TimeInterval? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
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

  private func saveKeychainSeconds(_ seconds: TimeInterval) {
    let data = Data(String(format: "%.3f", seconds).utf8)
    let lookup: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
    ]
    let attributes: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
    guard status == errSecItemNotFound else { return }
    var addition = lookup
    addition[kSecValueData as String] = data
    addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(addition as CFDictionary, nil)
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
