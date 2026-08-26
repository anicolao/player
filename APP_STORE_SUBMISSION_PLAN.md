# Bookshelf App Store submission plan

## Purpose

This plan takes Bookshelf from its current internal/public TestFlight state to
a complete App Store version 1.0 submission. It covers product identity,
release qualification, product-page assets, privacy and compliance, App Review
instructions, submission, and post-submission monitoring.

The plan is intentionally ordered so that screenshots, metadata, and the final
binary describe the same product. App Store Connect mutations should wait until
the underlying copy and release decisions are final enough to avoid rework.

## Current-state snapshot

Audited on 2026-08-26 against the repository and the live App Store Connect
record for `com.spnss.player`.

### Already in place

- App Store Connect app name: `Bookshelf Offline Audio Player`
- Installed app name: `Bookshelf`
- Subtitle: `Local MP3 & M4B Audiobook App`
- A 99-character keyword set documented in `APP_STORE_LISTING.md`
- App Store version record: `1.0`, state `PREPARE_FOR_SUBMISSION`
- Valid uploaded TestFlight builds through build 29; build 29 contains the
  monetization implementation and is assigned to the internal testing group
- Public TestFlight group and public invitation link
- A 1024×1024 RGB app icon without transparency
- `ITSAppUsesNonExemptEncryption = false`
- Privacy manifest declaring no tracking and no collected data
- No third-party SDK or remote analytics dependency found in the app
- A deterministic unit/integration and twelve-story end-to-end release suite
- A 50-hour active-playback allowance, permanent StoreKit Full Unlock, purchase
  restoration, offline entitlement cache, and in-app offer-code redemption
- A draft `com.spnss.player.fullunlock` non-consumable configured for US$9.99,
  all 175 storefronts, Family Sharing, en-US localization, and an App Review
  screenshot

### Submission blockers

- All uploaded builds use marketing version `0.1.0`; App Store version `1.0`
  therefore has no selectable build.
- User-visible `Player` branding remains in the app, share extension, receiver,
  recovery, backup, and diagnostic copy.
- The App Store description, support URL, and privacy-policy URL are empty.
- No App Store screenshots are uploaded.
- Copyright and primary category are unset.
- Age-rating answers are unset.
- Content-rights and IDFA declarations are unset.
- Pricing, storefront availability, and distribution choices are incomplete.
- The Full Unlock draft must be attached to the 1.0 submission and approved;
  production launch offer codes can only be generated after approval.
- EU Digital Services Act status needs confirmation.
- App Store review contact/instructions have not been created for version 1.0.
- No build is selected and no App Store review submission exists.

## Decisions required before submission

Resolve these decisions early because they affect metadata, screenshots, legal
pages, and release behavior.

- [ ] Confirm the public product name remains `Bookshelf Offline Audio Player`.
- [ ] Confirm the installed name remains `Bookshelf`.
- [x] Use a free app download with 50 active playback hours included, followed
      by a US$9.99 one-time Full Unlock in-app purchase. See
      `MONETIZATION_PLAN.md`.
- [ ] Choose launch territories.
- [ ] Confirm public App Store distribution rather than private or unlisted
      distribution.
- [ ] Confirm automatic release after approval versus manual release.
- [ ] Choose the permanent support-site and privacy-policy URLs.
- [ ] Assess and declare the account/app's EU DSA trader status.
- [ ] Decide which accessibility features meet Apple's all-common-tasks
      criteria and can be published accurately.

## Phase 1 — Complete the Bookshelf product identity

Replace user-visible `Player` branding with `Bookshelf` before producing store
screenshots or the final build.

### Change user-visible identity

- [ ] Share extension display name and success/error messages
- [ ] Local-network permission explanation
- [ ] Nearby-computer receiver service name, instructions, and errors
- [ ] Import and metadata-editor explanations
- [ ] Backup, restore, recovery, and support-diagnostic copy
- [ ] User-visible backup and support-bundle filenames where compatibility
      permits
- [ ] Documentation and reviewer-facing terminology

### Preserve compatibility identifiers

Do not rename these merely for branding:

- Bundle IDs beginning with `com.spnss.player`
- Shared app-group identifier
- Existing application-support and managed-media directories
- Existing UTI identifiers
- Existing backup/support file extensions and the ability to import old files
- Persistence schema identifiers and migration history

Changing compatibility identifiers would risk losing access to libraries,
share-extension handoffs, backups, or existing TestFlight data. User-facing
labels may change while their underlying identifiers remain stable.

### Exit criteria

- [ ] A repository search finds no unintended user-visible `Player` copy.
- [ ] Upgrade testing preserves a library created by a current `0.1.0` build.
- [ ] The app, share extension, receiver, exported files, and screenshots
      present a coherent Bookshelf identity.

## Phase 2 — Produce the App Store 1.0 release candidate

The App Store version record is `1.0`, but the current build configuration is
`0.1.0`. Apple associates builds with version records using the bundle's
marketing version, so the final candidate must use version `1.0`.

- [ ] Set `MARKETING_VERSION = 1.0` in `apps/ios/Config/Shared.xcconfig`.
- [ ] Increment `CURRENT_PROJECT_VERSION` beyond build 29.
- [ ] Generate the Xcode project reproducibly.
- [ ] Build and test the Release configuration.
- [ ] Archive with distribution signing.
- [ ] Validate the archive before upload.
- [ ] Confirm the archive contains the app icon, privacy manifest, share
      extension, entitlements, local-network usage description, and version
      `1.0`.
- [ ] Upload the candidate and wait for App Store Connect to report `VALID`.
- [ ] Resolve every upload warning that could affect review or distribution.
- [ ] Assign the candidate to internal TestFlight for a final smoke test.
- [ ] Confirm a TestFlight sandbox purchase never changes the production
      allowance or entitlement cache.

The public beta review for a `0.1.0` build is useful confidence but does not
make that build selectable for the App Store `1.0` record.

### Exit criteria

- [ ] A valid version 1.0 build appears in App Store Connect.
- [ ] The build can be selected on the iOS 1.0 product-version page.
- [ ] Existing beta-user libraries survive the upgrade.

## Phase 3 — Publish support and privacy pages

Apple requires current support contact information and a public privacy-policy
URL. Create stable pages before completing the product-page metadata.

### Support page

Include:

- Bookshelf name and app icon
- Link to `r/BookshelfAudiobooks`
- Support email or another durable contact method
- Current supported iOS and file formats
- A concise help-request template
- A warning not to send copyrighted audiobook files
- Link to the privacy policy

### Privacy policy

Describe the shipped behavior accurately:

- Audiobooks, library metadata, playback history, bookmarks, and backups remain
  on the user's device unless the user explicitly exports them.
- The nearby-computer receiver uses the local network only while its screen is
  open.
- Bookshelf does not require an account.
- Bookshelf does not contain tracking or advertising SDKs.
- Bookshelf does not upload a library, listening history, or diagnostics by
  default.
- Support and diagnostic exports are user initiated and reviewable before
  sharing.
- Explain any website-side logging or analytics separately from the app.
- Provide a contact address for privacy questions.

### Exit criteria

- [ ] Both URLs are public, stable, HTTPS, and readable without an account.
- [ ] The policy matches the final binary and App Privacy answers.
- [ ] The support page contains current contact information.

## Phase 4 — Complete App Store product-page metadata

`APP_STORE_LISTING.md` is authoritative for the existing English (U.S.) title,
subtitle, keywords, and installed name.

- [ ] Write the full English (U.S.) description.
- [ ] Add the support URL.
- [ ] Add the privacy-policy URL.
- [ ] Add an optional marketing URL if a useful landing page exists.
- [ ] Set the primary category, likely `Books`.
- [ ] Decide whether a secondary category is useful.
- [ ] Enter copyright ownership for 2026.
- [ ] Confirm the title and subtitle still fit Apple's 30-character limits.
- [ ] Proofread claims against the final binary; remove roadmap-only features.
- [ ] Add localizations only when their screenshots, support, and copy can be
      maintained.

`What's New` is not required for the first version, but App Review notes and
TestFlight `What to Test` copy are separate and should still be complete.

### Exit criteria

- [ ] No required product-page field is blank.
- [ ] Every advertised capability is demonstrable in the selected build.

## Phase 5 — Produce and upload App Store screenshots

Create a coherent 5–7-image story from deterministic app states. Use genuine
app UI, synthetic or licensed cover art, and no copyrighted audiobook content.

Recommended sequence:

1. Library and Continue Listening
2. Import inbox and explainable grouping/order
3. Book detail and metadata/chapter repair
4. Now Playing and audiobook-specific controls
5. Bookmarks and sleep timer
6. Nearby-computer receiver
7. Backup, offline operation, or recovery

### Asset requirements

- [ ] Capture an accepted 6.9-inch iPhone portrait size, preferably
      1320×2868, 1290×2796, or 1260×2736.
- [ ] Upload between one and ten screenshots for `en-US`.
- [ ] Use PNG or JPEG without alpha transparency.
- [ ] Keep status bars, device state, titles, and sample metadata consistent.
- [ ] Verify screenshot text remains legible on the product page.
- [ ] Avoid unsupported claims, prices, rankings, and calls to competing
      platforms.
- [ ] Decide whether raw screenshots or restrained branded captions best match
      the launch presentation.

The existing 1206×2622 deterministic captures are useful source material and
composition references but are not the preferred 6.9-inch upload tier.

### Exit criteria

- [ ] App Store Connect accepts every image without scaling warnings.
- [ ] The screenshot order explains Bookshelf's core value without requiring
      the description.
- [ ] Screenshots match version 1.0 exactly.

## Phase 6 — Configure monetization and launch grants

- [ ] Accept the Paid Apps Agreement and complete banking and tax setup.
- [x] Create `com.spnss.player.fullunlock` as a US$9.99 non-consumable named
      **Bookshelf Full Unlock** with accurate localization and review notes.
- [x] Enable Family Sharing deliberately; Apple does not allow this setting to
      be turned off later.
- [ ] Submit the first in-app purchase with the 1.0 app version.
- [ ] Test purchase, pending, cancellation, restore, refund/revocation, offline
      ownership, and Family Sharing using StoreKit sandbox and TestFlight.
- [ ] Create sandbox Free Offer codes and verify **Redeem a Code** grants the
      permanent entitlement.
- [ ] After both app and IAP approval, generate production one-time-use Free
      Offer batches for selected beta testers, press, contributors, and other
      complimentary recipients using the runbook in `MONETIZATION_PLAN.md`.
- [ ] If desired, create a separately capped and expiring custom Paid Offer
      code for a public launch discount.
- [ ] Keep downloaded codes and recipient assignments out of source control.

### Exit criteria

- [ ] The localized product and real TestFlight sandbox flow work end to end.
- [ ] Sandbox state cannot consume or unlock the public App Store allowance.
- [ ] Complimentary and discounted grants use verified StoreKit entitlements,
      not a private code or account system.

## Phase 7 — Complete app-level privacy, ratings, and commercial compliance

### App Privacy

- [ ] Re-audit the final binary and all embedded SDKs.
- [ ] If still accurate, answer that the app does not collect data.
- [ ] Publish the App Privacy responses rather than leaving them as drafts.
- [ ] Confirm the published answers match `PrivacyInfo.xcprivacy` and the
      privacy policy.

### Age rating

- [ ] Complete every age-rating questionnaire field.
- [ ] Treat user-imported content accurately while noting that Bookshelf does
      not provide or curate a content catalog.
- [ ] Use no override unless a policy or legal requirement justifies it.

### Content rights

- [ ] Complete the content-rights declaration accurately.
- [ ] State consistently that Bookshelf distributes no audiobook catalog,
      bypasses no DRM, and accesses only files the user selects and is
      authorized to use.

### Advertising identifier and export compliance

- [ ] Declare that the app does not use IDFA if the final binary still contains
      no advertising or tracking code.
- [ ] Confirm App Store Connect recognizes
      `ITSAppUsesNonExemptEncryption = false` without a missing-compliance
      warning.

### Pricing, availability, and regulations

- [ ] Set the app itself to free; paid playback access is the non-consumable
      Full Unlock configured in Phase 6.
- [ ] Select launch storefronts and public distribution.
- [ ] Complete DSA trader/non-trader status; verify public contact details if
      declaring trader status for EU distribution.
- [ ] Review country-specific requirements before enabling China mainland,
      South Korea, Vietnam, or other regulated storefronts.
- [ ] Confirm the selected release method: automatic after approval, manual,
      or phased release where applicable.

### Accessibility Nutrition Labels

These labels are currently optional but valuable for Bookshelf.

- [ ] Evaluate common tasks against Apple's criteria for VoiceOver.
- [ ] Evaluate Larger Text, Differentiate Without Color Alone, Sufficient
      Contrast, Voice Control, Reduced Motion, and Dark Interface separately.
- [ ] Publish only the features supported throughout all common tasks.
- [ ] Optionally publish an accessibility URL based on the repository audit.

### Exit criteria

- [ ] App Store Connect shows no missing app-level compliance items.
- [ ] All answers are supportable from the final binary and documentation.

## Phase 8 — Prepare the App Review package

Create App Store review details for version 1.0.

- [ ] Reuse the verified NPA review contact identity in App Store Connect; do
      not commit personal contact details to this repository.
- [ ] Set `demoAccountRequired` to false because Bookshelf has no account.
- [ ] Explain that the app is local-first and works offline.
- [ ] Explain that the local-network receiver is optional and runs only while
      its screen is open.
- [ ] Explain that the user supplies authorized DRM-free M4B, M4A, MP3,
      folders, or ZIP archives.
- [ ] Provide exact import, playback, background-audio, and backup test steps.
- [ ] Give reviewers a small synthetic or public-domain audiobook fixture via
      a stable public URL or permitted review attachment.
- [ ] Ensure the test media exercises chapters and playback without requiring
      copyrighted material.
- [ ] Include any hardware, Files-app, or local-network setup details that are
      not obvious.

Suggested review flow:

1. Download the provided synthetic audiobook to Files.
2. Open or share it into Bookshelf.
3. Review the import and add it to the library.
4. Start playback, change chapters, create a bookmark, and start a sleep timer.
5. Background the app and verify Lock Screen controls.
6. Optionally test nearby-computer import from the receiver screen.
7. Export and verify a library backup.
8. Open Settings → Full Unlock and verify the localized one-time price,
   Restore Purchases, Redeem a Code, and non-destructive exhausted state.

### Exit criteria

- [ ] A reviewer can exercise the core value from a clean install without
      contacting the developer.
- [ ] Review contact fields are complete and current.
- [ ] No secret, personal test credential, or copyrighted media is committed.

## Phase 9 — Run the release qualification gate

Run the complete deterministic suite:

```sh
apps/ios/scripts/run-complete-suite.sh
```

Then perform release-specific manual checks on physical devices.

- [ ] Fresh install on the minimum supported iOS version where practical
- [ ] Upgrade from the current TestFlight `0.1.0` build with a populated library
- [ ] Former beta users receive a fresh production 50-hour allowance.
- [ ] TestFlight sandbox purchases do not carry into production.
- [ ] Files, document-open, AirDrop, and share-extension import
- [ ] Single-file, multifile, and ZIP import
- [ ] Nearby-computer receiver and local-network permission handling
- [ ] Background audio, interruptions, Lock Screen, Bluetooth, and headset
      controls
- [ ] Exact playback-position recovery after termination
- [ ] Search, metadata editing, chapters, bookmarks, sleep timer, and smart
      rewind
- [ ] Backup/export, destructive confirmation, restore, and recovery
- [ ] Airplane Mode startup and playback
- [ ] VoiceOver and largest Dynamic Type across all common tasks
- [ ] Low-storage and interrupted-import behavior
- [ ] Support bundle contains no unintended private data
- [ ] No crash, assertion, placeholder copy, debug control, or synthetic E2E
      state is reachable in Release

Archive checks:

- [ ] Correct distribution certificate and provisioning profiles
- [ ] Main app and share extension entitlements are correct
- [ ] App Group membership works in the distributed build
- [ ] Version is `1.0` and build number is the intended candidate
- [ ] App icon is present and has no alpha channel
- [ ] Privacy manifest is embedded
- [ ] Export-compliance state is resolved
- [ ] Archive validation reports no blocking warnings

### Exit criteria

- [ ] Automated suite passes from a clean generated project.
- [ ] Manual release matrix passes on the selected candidate.
- [ ] The exact tested archive is the archive uploaded for submission.

## Phase 10 — Assemble and submit version 1.0

- [ ] Select the validated version 1.0 build in App Store Connect.
- [ ] Recheck product-page metadata and screenshot order.
- [ ] Recheck privacy, ratings, content rights, DSA, pricing, and availability.
- [ ] Recheck App Review contact information and test-media URL.
- [ ] Confirm the release method.
- [ ] Click **Add for Review** and create or select the draft submission.
- [ ] Add the first Full Unlock in-app purchase to the same submission.
- [ ] Inspect the draft submission for missing or unintended items.
- [ ] Click **Submit for Review**.
- [ ] Verify the item and submission both move to `WAITING_FOR_REVIEW`.

Apple's submission flow requires both steps: adding the version to a draft and
then submitting that draft. Merely reaching `READY_FOR_REVIEW` does not send the
version to Apple.

## Phase 11 — Monitor review and release

- [ ] Monitor App Store Connect status and review messages.
- [ ] Respond promptly with reproducible instructions if App Review has a
      question.
- [ ] Do not replace the binary or screenshots while waiting unless necessary.
- [ ] If rejected, preserve the review message, reproduce the issue, and decide
      whether metadata clarification or a new build is required.
- [ ] After approval, verify the selected release method behaves as intended.
- [ ] Install the public App Store build on a clean device.
- [ ] Verify the product page, privacy label, screenshots, support link, and
      version number in each launch storefront.
- [ ] Verify upgrade from TestFlight/public beta to the App Store build.
- [ ] Generate the approved production launch-code batches and make controlled
      recipient assignments.
- [ ] Post the release and support instructions in `r/BookshelfAudiobooks`.

## Recommended execution order

The work can be organized into four practical milestones:

1. **Product freeze:** complete rebranding and decide price, territories,
   release method, URLs, and compliance posture.
2. **Store package:** publish support/privacy pages, finish metadata, configure
   the Full Unlock and sandbox offers, prepare screenshots, and assemble
   reviewer test media.
3. **Release candidate:** set version 1.0, run the full qualification gate,
   archive, upload, and perform the final TestFlight smoke test.
4. **Submission:** select the build, complete declarations and review details,
   create the draft, submit, monitor, and verify release.

Do not capture final screenshots before the rebrand is complete, and do not
submit a build that differs from the archive that passed the release gate.

## Apple references

- [Required, localizable, and editable properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties)
- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [Upload app previews and screenshots](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots)
- [App Store review details](https://developer.apple.com/documentation/appstoreconnectapi/app-store-review-details)
- [EU Digital Services Act trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements)
- [Accessibility Nutrition Labels](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels/)
- [Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app)
