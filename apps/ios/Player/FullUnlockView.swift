import StoreKit
import SwiftUI

struct FullUnlockView: View {
  @Bindable var model: PlayerModel
  @State private var isRedeemingOfferCode = false

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        Image(systemName: model.monetization.isUnlocked ? "checkmark.seal.fill" : "books.vertical.fill")
          .font(.system(size: 54, weight: .semibold))
          .foregroundStyle(PlayerColor.accent)
          .accessibilityHidden(true)

        VStack(spacing: 8) {
          Text(model.monetization.isUnlocked ? "Bookshelf is unlocked" : "Unlock Bookshelf forever")
            .font(.title2.weight(.bold))
            .multilineTextAlignment(.center)
          Text(subtitle)
            .font(.body)
            .foregroundStyle(PlayerColor.secondary)
            .multilineTextAlignment(.center)
        }

        VStack(alignment: .leading, spacing: 14) {
          FullUnlockBenefit(icon: "infinity", text: "Unlimited playback of your audiobook library")
          if model.monetization.isFamilyShareable == true {
            FullUnlockBenefit(icon: "person.2.fill", text: "Eligible for Apple Family Sharing")
          }
          FullUnlockBenefit(icon: "iphone.and.arrow.forward", text: "Restore on devices using your Apple Account")
          FullUnlockBenefit(icon: "nosign", text: "No subscription, advertising, or account")
        }
        .frame(maxWidth: 460, alignment: .leading)

        if model.monetization.isUnlocked {
          Label("Full Unlock purchased", systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(PlayerColor.accent)
            .accessibilityIdentifier("full-unlock-purchased")
        } else {
          purchaseActions
        }

        if let message = model.monetization.feedbackMessage {
          Text(message)
            .font(.footnote)
            .foregroundStyle(PlayerColor.secondary)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("full-unlock-feedback")
        }

        Text("Reaching the included playback limit never deletes or hides your books, bookmarks, metadata, or listening positions.")
          .font(.footnote)
          .foregroundStyle(PlayerColor.secondary)
          .multilineTextAlignment(.center)

        Link("Bookshelf Support", destination: URL(string: "https://bookshelf.spnss.com/#support")!)
          .font(.footnote.weight(.semibold))
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 32)
      .frame(maxWidth: .infinity)
    }
    .background(PlayerColor.background)
    .navigationTitle("Full Unlock")
    .navigationBarTitleDisplayMode(.inline)
    .offerCodeRedemption(isPresented: $isRedeemingOfferCode) { result in
      let completed: Bool
      switch result {
      case .success:
        completed = true
      case .failure:
        completed = false
      }
      Task { await model.handleOfferCodeRedemption(completed: completed) }
    }
    .task {
      await model.refreshMonetization()
    }
    .accessibilityIdentifier("full-unlock-screen")
    .e2eScrollReadiness(
      id: "full-unlock-scroll-readiness",
      containerID: "full-unlock-screen",
      axis: .vertical
    )
    #if E2E
      .overlay(alignment: .bottomTrailing) {
        if E2EMonetizationStoreKitClient.shared.isConfigured {
          E2EMonetizationControlSurface(model: model)
        }
      }
    #endif
  }

  private var subtitle: String {
    if model.monetization.isUnlocked {
      return "Your one-time purchase is active. Thank you for supporting Bookshelf."
    }
    return "\(model.monetization.remainingPlaybackDescription) from the 50 hours included with Bookshelf. Pay once to keep listening without a limit."
  }

  private var purchaseActions: some View {
    VStack(spacing: 12) {
      Button {
        Task { await model.purchaseFullUnlock() }
      } label: {
        HStack {
          if model.monetization.isActionInProgress {
            ProgressView().tint(.white)
          }
          Text(purchaseButtonTitle)
            .frame(maxWidth: .infinity)
        }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(
        model.monetization.displayPrice == nil
          || model.monetization.isStoreLoading
          || model.monetization.isActionInProgress
      )
      .accessibilityIdentifier("full-unlock-purchase")

      Text("One-time purchase · No subscription")
        .font(.caption.weight(.semibold))
        .foregroundStyle(PlayerColor.secondary)

      HStack(spacing: 18) {
        Button("Restore Purchases") {
          Task { await model.restorePurchases() }
        }
        .accessibilityIdentifier("full-unlock-restore")

        Button("Redeem a Code") {
          beginOfferCodeRedemption()
        }
        .accessibilityIdentifier("full-unlock-redeem-code")
      }
      .font(.subheadline.weight(.semibold))
      .disabled(model.monetization.isActionInProgress)
    }
    .frame(maxWidth: 460)
  }

  private var purchaseButtonTitle: String {
    if model.monetization.isStoreLoading { return "Checking App Store…" }
    if let price = model.monetization.displayPrice { return "Unlock Forever — \(price)" }
    return "Unlock Forever"
  }

  private func beginOfferCodeRedemption() {
    #if E2E
      if E2EMonetizationStoreKitClient.shared.isConfigured {
        E2EMonetizationStoreKitClient.shared.beginOfferCodeCompletion()
        return
      }
    #endif
    isRedeemingOfferCode = true
  }
}

#if E2E
  private struct E2EMonetizationControlSurface: View {
    @Bindable var model: PlayerModel

    var body: some View {
      VStack(spacing: 0) {
        probe
        switch E2EMonetizationStoreKitClient.shared.phase {
        case .awaitingProducts:
          control("Complete product lookup", identifier: "e2e-monetization-complete-products") {
            E2EMonetizationStoreKitClient.shared.completeProductLoad()
          }
        case .awaitingPurchase:
          control("Complete purchase", identifier: "e2e-monetization-complete-purchase") {
            E2EMonetizationStoreKitClient.shared.completePurchase()
          }
        case .awaitingRestore:
          control("Complete restore", identifier: "e2e-monetization-complete-restore-empty") {
            E2EMonetizationStoreKitClient.shared.completeRestoreWithoutEntitlement()
          }
        case .awaitingOfferCompletion:
          control("Complete offer-code sheet", identifier: "e2e-monetization-complete-offer-failure") {
            E2EMonetizationStoreKitClient.shared.completeOfferCodeWithoutSheet()
            Task { await model.handleOfferCodeRedemption(completed: false) }
          }
        case .ready:
          control("Prepare offline relaunch", identifier: "e2e-monetization-prepare-offline") {
            E2EMonetizationStoreKitClient.shared.prepareOfflineRelaunch()
          }
        case .idle, .offline:
          EmptyView()
        }
      }
    }

    private var probe: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Monetization fixture state")
        .accessibilityIdentifier("e2e-monetization-state")
        .accessibilityValue(probeValue)
    }

    private var probeValue: String {
      let snapshot = model.monetization
      return [
        "monetization",
        "schema=1",
        "entitlement=\(snapshot.entitlement.rawValue)",
        "loading=\(snapshot.isStoreLoading)",
        "action=\(snapshot.isActionInProgress)",
        "price=\(snapshot.displayPrice ?? "none")",
        "family=\(snapshot.isFamilyShareable.map(String.init) ?? "unknown")",
        "feedback=\(snapshot.feedbackMessage == nil ? "none" : "present")",
        "restored=\(model.isRestored)",
        "books=\(model.library.books.count)",
        "current=\(model.library.currentBookID?.uuidString.lowercased() ?? "none")",
        E2EMonetizationStoreKitClient.shared.probeValue,
      ].joined(separator: "|")
    }

    private func control(
      _ label: String,
      identifier: String,
      action: @escaping @MainActor () -> Void
    ) -> some View {
      Button(action: action) {
        Color.white.opacity(0.001)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(label)
      .accessibilityIdentifier(identifier)
    }
  }
#endif

private struct FullUnlockBenefit: View {
  let icon: String
  let text: String

  var body: some View {
    Label {
      Text(text)
        .foregroundStyle(PlayerColor.ink)
    } icon: {
      Image(systemName: icon)
        .foregroundStyle(PlayerColor.accent)
        .frame(width: 24)
    }
  }
}
