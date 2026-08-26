# Bookshelf monetization plan

**Decision date:** August 26, 2026

**Status:** Implemented for TestFlight build 29; the StoreKit product is configured in App Store Connect and remains subject to release qualification and App Review confirmation described below

## Decision

Bookshelf should be a free download with **50 hours of audiobook playback included**, followed by a **single, permanent Full Unlock purchase**. This is a playback meter, not a clock or calendar trial: it advances only while Bookshelf is actively playing audio. Fifty hours may therefore be used over days, months, or years; time since installation, first launch, or first playback does not consume the allowance.

- The launch price should be **US$9.99 or the automatically localized equivalent**.
- The unlock should be a StoreKit **non-consumable in-app purchase**. It never expires and is not a subscription.
- Family Sharing should be enabled for the unlock.
- Bookshelf should have no advertising, account requirement, recurring payment, or separately sold playback credits.
- Only active audio playback consumes the 50 hours. Pausing, stopping, importing, browsing, editing, and leaving the app unused consume nothing.
- The playback meter should remain at zero until the first successful playback.
- Reaching the limit must never delete, hide, or hold the listener's files or metadata hostage.

This finalizes the product direction, with one terminology and review caveat: present the offer as **“50 listening hours included”**, not as an “hour-based free trial.” Apple's published trial exception is written specifically for an `XX-day Trial` implemented as a free non-consumable purchase; it does not explicitly describe usage-metered trials. The proposed model is therefore a metered free tier with a paid unlock. If App Review nevertheless classifies it as a trial and rejects it, the predetermined fallback is a **30-day trial followed by the same one-time unlock**, implemented exactly as Apple describes. See [App Store compliance](#app-store-compliance).

## Why this is the right model

Bookshelf is a local utility for media the listener already owns. It does not provide a continuously refreshed catalog, hosted storage, or another recurring service that naturally justifies rent. A subscription would work against the product's local-first, ownership-oriented promise and the website's “no subscription” positioning.

At the same time, an entirely free player or a permanently free core with only niche management features behind a paywall would make revenue depend on the smallest power-user segment. Playback is the product's recurring value, so the purchase boundary should be legible: people can evaluate the complete app generously, then pay once to keep listening.

Fifty active hours is intentionally generous. It is long enough to test import, background playback, Lock Screen and Bluetooth controls, speed changes, sleep behavior, position reliability, and several real listening sessions. Unlike a calendar trial, it cannot expire while someone is busy or between books. Its main commercial disadvantage—conversion may take weeks or months—is acceptable because trust and word of mouth are central to this product.

The one-time purchase is also easy to explain:

> Listen for 50 hours free. Unlock Bookshelf forever for [localized price]. No subscription.

## Options considered

| Model | Advantages | Disadvantages | Decision |
| --- | --- | --- | --- |
| **50 playback hours + one-time unlock** | Fair to intermittent listeners; users test the complete product; no install-date pressure; clear value exchange; matches the ownership promise | More implementation and test complexity; conversion can be slow; local metering is not perfect anti-abuse protection; App Review has no explicit published usage-trial recipe | **Recommended**, presented as hours included in a free tier |
| Up-front paid app | Simplest implementation; every download produces revenue; no paywall inside the app | No meaningful try-before-buy; weaker discovery and conversion for an unfamiliar product; awkward transition from a free beta; refunds become the evaluation mechanism | Reject |
| Calendar trial + one-time unlock | Simple to explain and explicitly contemplated by Apple's guidelines; easy to synchronize from a start date | Punishes people who install and do not immediately listen; can expire without a fair evaluation; creates artificial urgency | Keep only as the App Review fallback; use 30 days |
| Free playback with paid management features | Most closely preserves permanently free basic playback; easy goodwill story | The most valuable and costly-to-maintain feature remains free; difficult to draw a stable feature boundary; power users subsidize everyone; each new feature invites paywall debate | Do not use for launch |
| Limited number of books + one-time unlock | Concrete and easy to display | A book may be 30 minutes or 60 hours; multi-file imports make “book” boundaries gameable; discourages importing a real library | Reject |
| Subscription | Predictable recurring revenue; can fund ongoing cloud services and continuous development | Poor fit for a local player with no recurring service; subscription fatigue; contradicts Bookshelf's positioning; creates billing, churn, and support complexity | Reject for the core app |
| Free app + optional tips | Frictionless adoption and strong goodwill | Revenue is optional and unpredictable; weak connection between value and payment; unlikely to fund durable support | May be added later, but not as the business model |
| Ads or data monetization | Keeps playback nominally free | Damages a calm listening experience and the privacy promise; adds SDK, policy, and support risk | Reject |

## Offer and pricing

### Launch offer

- Product name: **Bookshelf Full Unlock**
- Product type: **Non-Consumable**
- Product identifier: `com.spnss.player.fullunlock` (App Store Connect product IDs permit periods and underscores but not hyphens, and cannot be casually renamed after creation)
- Base price: **US$9.99**
- Customer promise: permanent access to all Bookshelf playback and all features included at purchase
- Family Sharing: **on**

Apple defines a non-consumable as a product purchased once that does not expire or diminish with use. That is the correct entitlement for a lifetime unlock. [Apple: In-App Purchase types](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-types)

US$9.99 is a credible launch price for the current feature set. As of this decision, the US App Store lists Prologue Premium at $9.99 and MP3 Audiobook Player's unrestricted unlock at $7.99, while BookPlayer offers subscription pricing. These are reference points rather than interchangeable products, but they put a polished one-time local-player unlock around $10 in familiar territory. [Prologue listing](https://apps.apple.com/us/app/prologue-audiobook-player/id1459223267), [MP3 Audiobook Player listing](https://apps.apple.com/us/app/mp3-audiobook-player/id891797540), [BookPlayer listing](https://apps.apple.com/us/app/bookplayer/id1138219998)

Use the localized price returned by StoreKit everywhere in the UI; never hard-code `$9.99`. App Store Connect can derive prices across storefronts and currencies from a chosen base storefront, accounting for exchange rates, taxes, and local conventions. [Apple: Set a price for an In-App Purchase](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/set-a-price-for-an-in-app-purchase)

### What “forever” means

The Full Unlock must continue to unlock the features sold with it. Maintenance, compatibility fixes, and incremental improvements to those features remain included. A future genuinely separate service with ongoing cost—hosted synchronization, for example—could have separate pricing, but it must be optional and must not take away the local functionality an owner already purchased.

Do not launch with a “discounted” countdown or fake crossed-out price. Because different listeners will consume 50 hours at very different rates, a time-limited offer would penalize slow listeners and dilute the calm, trustworthy positioning.

## Exact free-tier boundary

Before the 50-hour allowance is exhausted, the complete app works normally.

After it is exhausted:

- Starting or resuming full playback presents the Full Unlock screen.
- Library browsing, search, import history, metadata inspection and editing, export/backup, file deletion, support, purchase restoration, and access to Settings remain available.
- Existing books, covers, metadata, bookmarks, and listening positions remain intact.
- Import may remain available, but the UI must clearly say that continued playback requires Full Unlock before the user spends time importing a large library.
- A purchase failure, unavailable store, or network outage must not corrupt the library or reset playback position.

The app should not interrupt audio at exactly 50:00:00. If the threshold is crossed during continuous playback, allow that playback session to continue. Enforce the boundary the next time the listener stops and then initiates play or resume. The small amount of extra use is worth avoiding a mid-sentence or in-car interruption.

Do not offer renewable hour packs. They would turn the clear one-time promise into a confusing consumable model and make heavy listeners feel penalized.

## Defining and recording the 50 hours

“Active playback” means elapsed real time while Bookshelf is successfully outputting audio.

### Count

- foreground, background, Lock Screen, Bluetooth, AirPlay, and CarPlay playback;
- repeated listening and rewound passages;
- time played at any speed, at one trial second per real elapsed second.

### Do not count

- paused, stopped, buffering, failed, or interrupted time;
- import, scanning, editing, or library browsing;
- time jumped by seeking or chapter navigation;
- silence after a sleep timer has stopped playback.

Counting real listening time rather than movement of the media playhead is the fairest rule. A listener using 2× speed still receives 50 hours in which to evaluate Bookshelf; seeking forward cannot consume the allowance accidentally, and rewinding cannot restore it.

### Persistence

- Maintain a monotonic accumulated-seconds value; never calculate usage from the current book position.
- Accumulate from a monotonic clock only while the audio engine reports actual playback.
- Checkpoint at a modest interval (for example every 30 seconds) and on pause, stop, interruption, route change, background transition, and orderly termination.
- Store the meter in protected local storage and retain a backup copy/check value so a partial write cannot reset it.
- Store the durable marker in Keychain as well as app data so an ordinary delete/reinstall does not trivially reset the allowance. Do not introduce an account or server solely for metering.
- Treat modest abuse—device changes, backup edge cases, or determined local tampering—as an acceptable tradeoff for privacy and simplicity in the first release.

The allowance is per device in the initial implementation. Synchronizing remaining free hours across devices would require identity or cloud state that is disproportionate to the risk. The paid entitlement, unlike the free meter, follows the purchaser through StoreKit and Family Sharing.

## Customer experience

### First run

Do not open with a blocking paywall. Include a concise explanation during onboarding or immediately before first playback:

> **50 listening hours included**
>
> Everything works from the start. After 50 hours of listening, unlock Bookshelf forever with one purchase. No subscription. Your books and data always remain yours.

The allowance starts only once audio has played successfully. Merely installing the app, browsing the sample library, or importing files does not start or consume it.

### Visibility without nagging

- Settings should always show `Full Unlock`, the live localized price, and either `42h 18m included listening remaining` or `Purchased`.
- Show low-key milestone messages at 25 hours remaining, 10 hours, and 2 hours. Do not show a modal on every launch.
- In the final two hours, the remaining time may appear on the Full Unlock row or playback screen, but it should not visually compete with book progress.
- After purchase, remove all meter and upsell UI except an ownership status and purchase-management/restore affordance in Settings.

### Full Unlock screen

It must contain:

- the live localized one-time price;
- the words **One-time purchase** and **No subscription** near the purchase button;
- a short list of what stays unlocked;
- the remaining included listening time, when applicable;
- `Unlock Forever` as the primary action;
- `Restore Purchases` as a visible secondary action;
- links to support and the privacy policy;
- clear non-destructive behavior when a purchase is pending, cancelled, unavailable, or fails.

It must not use a countdown sale, preselected subscription, disguised close button, or claim that the user's imported books are being purchased.

## StoreKit implementation

Use StoreKit 2 directly unless a future server-backed product creates a demonstrated need for a purchase SDK.

1. Load `Product` by product identifier and display `Product.displayPrice`.
2. On launch and foreground entry, derive ownership from verified current StoreKit entitlements.
3. Listen for transaction updates so purchases, refunds/revocations, and Family Sharing changes take effect without relaunching.
4. Finish verified transactions after granting the entitlement.
5. Cache the last verified paid state so a previously unlocked app continues to work offline. A temporary network or App Store failure must never relock an owner.
6. Provide a user-initiated Restore Purchases action and invoke App Store synchronization from that action.
7. Honor a verified refund/revocation by removing the paid entitlement, but never delete the listener's media or metadata.
8. Handle pending Ask to Buy, user cancellation, StoreKit unavailability, duplicate taps, and interrupted purchases as normal states rather than generic errors.
9. Keep sandbox/TestFlight allowance and entitlement caches in a separate namespace from production. A former beta tester must start the public App Store build with a fresh 50-hour production allowance, and a sandbox purchase must never become a production unlock.

Family Sharing is supported for non-consumable purchases and may share an unlock with up to five additional family members. Apple warns that enabling it for an in-app purchase cannot be undone, so this is a deliberate product commitment. [Apple: Family Sharing for In-App Purchases](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/turn-on-family-sharing-for-in-app-purchases)

The Account Holder must accept the Paid Apps Agreement and provide current banking and tax information before paid IAP can be offered. The first in-app purchase must be submitted with a new app version. [Apple: Configure In-App Purchases](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/), [Apple: Submit an In-App Purchase](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)

If eligible, enroll in Apple's Small Business Program before launch; it provides a 15% commission rate on paid apps and in-app purchases for qualifying developers within the program's proceeds threshold. Do not build forecasts assuming enrollment until Apple confirms it. [Apple: App Store Small Business Program](https://developer.apple.com/app-store/small-business-program/)

## Complimentary unlocks and launch discounts

Use Apple's **offer codes for in-app purchases** for every complimentary or discounted Full Unlock. A successfully redeemed code creates the same verified, permanent non-consumable entitlement as a normal purchase; Bookshelf therefore needs no account system, license-key database, secret gesture, or parallel entitlement path. The shipped Full Unlock screen includes **Redeem a Code**, and recipients may also redeem through Apple's standard App Store redemption flow.

Apple provides two useful code forms:

| Need | Recommended code | Why |
| --- | --- | --- |
| A free unlock for a reviewer, contributor, contest winner, or individual beta tester | **One-time-use code** attached to a Free Offer | Each random code works once, so forwarding it does not create additional grants. This is the default “free ticket.” |
| A public or partner campaign with a known maximum audience | **Custom code** attached to a Free Offer or Paid Offer | A memorable shared code such as `LAUNCH25` is easy to publish and can have a redemption cap, but anyone who learns it can use it until the cap or expiry is reached. |
| A controlled discount for named recipients | **One-time-use code** attached to a Paid Offer | It limits leakage while allowing Apple to collect the reduced one-time price. |

Do not use app promo codes for this purpose. Those grant a paid app download, while Bookshelf is a free app whose premium entitlement is an in-app purchase.

### Production prerequisites

Production offer codes cannot be generated until Bookshelf is **Ready for Distribution** and the Full Unlock in-app purchase is **Approved**. Sandbox offer codes may be created earlier for end-to-end testing. Complete the Paid Apps Agreement, tax, and banking setup first, and create the offers before promising codes to launch partners.

Current App Store Connect limits to plan around:

- At most ten active offers per app at one time.
- Up to one million offer-code redemptions per app per calendar quarter.
- Production one-time-use batches contain 500–25,000 codes and expire no more than six months after creation.
- Custom-code batches can allow up to 25,000 redemptions and may have no expiry or an expiry no more than six months out.
- Sandbox batches contain 10–10,000 codes.

Apple can change these operational limits, so confirm the values displayed by App Store Connect when each batch is created. [Apple: Create offer codes for In-App Purchases](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/create-offer-codes-for-in-app-purchases), [Apple: Supporting offer codes in your app](https://developer.apple.com/documentation/storekit/supporting-offer-codes-in-your-app)

### How to create launch codes

In App Store Connect, an Account Holder, Admin, App Manager, or Marketing user should:

1. Open **Apps → Bookshelf Offline Audio Player → Monetization → Offer Codes** and choose **Create Offer**.
2. Name the offer for internal reporting, select **Bookshelf Full Unlock**, and choose every storefront in which it should work.
3. Select **Free Offer** for a complimentary permanent unlock, or **Paid Offer** and its one-time discounted price for a launch discount.
4. For eligibility, select all three customer groups—never purchased, purchased within 30 days, and purchased more than 30 days ago—unless a campaign deliberately targets a narrower group.
5. Create either **One-Time-Use Codes** or a **Custom Code**, set the redemption count and expiry, review the irreversible choices carefully, then create the batch.
6. Download the one-time-use code file and keep it outside this repository. Record only the campaign name, audience, batch size, owner, and expiry in the private launch log; assign one unique code per recipient.
7. Test the same offer shape with sandbox codes before launch. Redeem in Bookshelf, confirm the Full Unlock becomes active, relaunch offline, restore on another sandbox device/account where practical, and verify the 50-hour meter no longer gates playback.
8. After production launch, redeem one production code from a clean customer account as a smoke test, then monitor redemptions and deactivate or allow the offer to expire when the campaign ends.

Recommended launch setup:

- `BETA-THANK-YOU-FREE`: Free Offer, one-time-use codes, all eligibility groups, all launch storefronts, six-month expiry. Generate the minimum production batch of 500 and distribute only the number needed.
- `PRESS-AND-REVIEW-FREE`: Free Offer, one-time-use codes, otherwise the same configuration. Keeping this separate makes press allocation and redemption visible without exposing tester codes.
- `LAUNCH25`: Paid Offer, custom code, a conservative redemption cap and 30-day expiry, only if a public launch discount is wanted. Finalize the localized paid-offer price before publishing the campaign; “25” should describe the actual discount in every storefront or the code should use a non-numeric name.

For giveaways, record the promotion rules and recipient selection separately and comply with the platform and jurisdiction where the giveaway is run. Never commit live codes, downloaded code lists, App Store Connect credentials, or recipient identities.

## App Store compliance

Two current guidelines matter:

1. Unlocking app functionality must use in-app purchase.
2. Apple's published path for a non-subscription free **time-based trial** calls for a price-tier-zero non-consumable named `XX-day Trial`, with duration, post-trial restrictions, and downstream charges disclosed before it begins.

The second rule describes days, not playback-hour allowances. It also says beta and trial versions do not generally belong on the App Store. Therefore:

- App Store metadata and in-app copy should call this **“50 listening hours included”** or **“50 hours included with the free download,”** not a “50-hour trial.”
- The app must remain a real, safe free tier after the allowance: users can manage and recover their library and data even though continued full playback requires purchase.
- The App Store description and screenshots must clearly disclose that continued playback after 50 hours requires a one-time in-app purchase.
- Review Notes should explain exactly how the meter works, how reviewers can exercise the exhausted state, that no user data is removed, and how to access a full-entitlement review mode or StoreKit test purchase.
- Before release, ask App Review/Developer Support to confirm that the usage allowance is acceptable as a metered free tier. This plan is a reasoned interpretation, not a guarantee of review outcome.

If Apple requires the formal trial mechanism, switch only the allowance mechanism—not the business model—to this fallback:

- free non-consumable named **30-day Trial**;
- trial starts only after the listener confirms the clearly disclosed terms;
- 30 calendar days of full functionality;
- the same US$9.99 non-consumable Full Unlock afterward;
- the same non-destructive library access after expiration.

Do not silently shorten the offer or improvise a subscription in response to review feedback. [Apple: App Review Guidelines 2.2, 2.3.2, and 3.1.1](https://developer.apple.com/app-store/review/guidelines/)

## Existing beta users

TestFlight purchases run in Apple's sandbox and do not charge users; they must not be treated as production ownership. [Apple: Testing In-App Purchases in TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight)

For the initial production release:

- Give every production installation the full 50-hour allowance, including former TestFlight users.
- Do not subtract beta listening time.
- Do not promise an automatic paid entitlement to testers unless a reliable production grant mechanism is implemented first.
- Grant selected testers a production Free Offer code after the app and Full Unlock are approved; do not add license keys or a private unlock gesture.

This is simple, fair, and avoids surprising testers with a meter partly consumed during development.

## Validation plan

### Automated tests

- meter advances only while audio is actually playing;
- 0.5×, 1×, 2×, background, Lock Screen, and Bluetooth playback all consume real elapsed seconds consistently;
- pause, buffering, seeking, interruption, failed playback, and import consume nothing;
- checkpoint recovery loses at most one checkpoint interval and never produces a negative/decreased total;
- exact threshold, threshold crossed during active playback, and next-play enforcement behave as specified;
- purchased, not purchased, pending, cancelled, failed, revoked, Family Shared, and offline cached-entitlement states;
- restore after reinstall and transaction update while app is running;
- library browse, export, delete, support, and restore remain reachable after exhaustion;
- Dynamic Type, VoiceOver labels, localized long prices, and narrow devices do not break the unlock screen;
- deterministic test injection can set remaining time without waiting 50 hours, and is impossible in release builds.

### Store testing

1. Use a StoreKit configuration in local development for deterministic purchase-state tests.
2. Exercise sandbox purchases, refunds, revocations, interrupted purchases, Ask to Buy, and purchase-history clearing.
3. Test the real configured IAP end to end in TestFlight; TestFlight uses the sandbox and no test purchase is charged. [Apple: StoreKit sandbox testing](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox)
4. Test Family Sharing before release.
5. Verify the first IAP and its app version are submitted together and visible to App Review.
6. Include explicit review instructions for both a fresh allowance and an exhausted allowance.

## Success criteria and review point

Do not add a third-party analytics SDK solely to optimize the paywall. Start with App Store units/proceeds, refunds, ratings, support volume, and voluntary beta feedback. If product analytics are later added, update the privacy disclosure first and collect the minimum aggregated events needed.

Review the model after the later of 90 days in production or enough usage to avoid reacting to a handful of purchasers. Questions to answer:

- Are people reaching the playback boundary, or is 50 hours delaying the decision indefinitely?
- Do exhausted listeners understand that the price is one-time?
- Are purchase restoration and offline ownership reliable?
- Are users angry about the boundary, or appreciative of the generous evaluation?
- Do proceeds support ongoing compatibility and support work?
- Is US$9.99 attracting buyers without communicating “disposable utility” pricing?

Prefer adjusting future-customer price before changing the 50-hour promise. Never reduce rights already purchased. A shorter included allowance should be considered only with strong evidence that users can fully evaluate the app sooner; a subscription should be reconsidered only if Bookshelf later provides a genuinely ongoing paid service.

## Launch checklist

- [ ] Confirm the 50-hours-included interpretation with Apple Developer Support/App Review.
- [ ] Accept the Paid Apps Agreement and complete banking and tax setup.
- [ ] Enroll in the Small Business Program if eligible.
- [x] Create the non-consumable Full Unlock at a US$9.99 base price.
- [x] Deliberately enable Family Sharing, acknowledging that the setting is irreversible.
- [x] Implement and test the allowance state machine and StoreKit entitlement service.
- [x] Add the non-destructive exhausted state, Full Unlock screen, Restore Purchases, and Redeem a Code.
- [ ] Create and sandbox-test the launch offers; after approval generate the controlled production batches described above.
- [ ] Store downloaded production code lists and recipient assignments outside the repository.
- [ ] Update App Store description, screenshots, review notes, support material, and privacy disclosures.
- [ ] Ensure the website says “50 hours included, then one-time unlock” rather than implying unlimited free use.
- [ ] Run unit, integration, UI, accessibility, sandbox, TestFlight, offline, refund, and Family Sharing tests.
- [ ] Submit the first IAP with the app version that implements it.
- [ ] Keep the 30-day Apple-compliant fallback ready, but do not ship both allowance models.

## Final recommendation

Proceed with the proposed idea, refined as follows: **50 hours of real active listening included with the free app, then a US$9.99 one-time, Family-Shareable Full Unlock.** Preserve access to the listener's library and data after the allowance, never interrupt an active playback session at the boundary, and avoid calling the offer a trial in customer-facing copy. This is the best balance of evaluation fairness, understandable pricing, sustainable revenue, and Bookshelf's local-ownership values.
