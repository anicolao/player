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
          FullUnlockBenefit(icon: "person.2.fill", text: "Eligible for Apple Family Sharing")
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
    .offerCodeRedemption(isPresented: $isRedeemingOfferCode) { _ in
      Task { await model.refreshMonetization() }
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
          isRedeemingOfferCode = true
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
}

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
