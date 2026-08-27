# Bookshelf App Store Listing Design

> Generated from `app-store/listing.json` by `scripts/app-store-listing prepare`. Edit the JSON or this template, not the generated document by hand.

## Goal

Turn a quick App Store glance into four immediate answers:

1. **Can I get my books in?** Yes—from any computer through a private local browser upload.
2. **Is there an even faster Mac path?** Yes—drag straight from Finder with iPhone Mirroring.
3. **What is it?** A beautiful, offline home for audiobooks you own.
4. **Will it fit me?** Yes—speed, skips, seeking, chapters, and sleep are adjustable.

The first four screenshots carry that whole story. Later images deepen confidence and clearly disclose the 50-hour allowance and one-time Full Unlock.

## What the research says

- Apple allows **one to ten screenshots**. With no App Preview, the **first one to three screenshots may appear in search results**, so the opening trio must explain the product without a swipe. [Apple: Creating your product page](https://developer.apple.com/app-store/product-page/)
- Apple recommends a concise opening description followed by a short feature list, and says the first sentence matters most because it is visible before “more.” The listing copy follows that structure. [Apple: Creating your product page](https://developer.apple.com/app-store/product-page/)
- The chosen output is **1320 × 2868**, an accepted portrait size for the 6.9-inch iPhone screenshot set. PNGs are flattened and contain no alpha channel. Apple can scale this highest-resolution set for smaller iPhones. [Apple: Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/), [Apple: Upload screenshots](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/)
- Screenshots must show the app in use and stay accurate. The pipeline uses real E2E screens with fictional metadata and synthetic artwork, satisfying Apple’s accuracy and rights guidance. [Apple: App Review Guidelines 2.3](https://developer.apple.com/app-store/review/guidelines/)
- AppTweak reported an **8.56% average page-view-to-download conversion rate** and a **3.8% impression-to-download rate** across U.S. App Store categories in 2025. Category and traffic source vary widely, so those are context—not launch targets. [AppTweak: 2025 conversion benchmarks](https://www.apptweak.com/en/aso-blog/average-app-conversion-rate-per-category)
- Apple’s Product Page Optimization supports up to three treatments and reports conversion rate, relative lift, and confidence. A result reaches Apple’s “performing better/worse” label at **90% confidence**; tests should run to significance and isolate one hypothesis at a time. [Apple: Product Page Optimization analytics](https://developer.apple.com/help/app-store-connect-analytics/acquisition/product-page-optimization), [Apple: Product Page Optimization](https://developer.apple.com/app-store/product-page-optimization/)

## Visual direction

- Match the website’s paper, ember, charcoal, and warm-wood mood.
- Use benefit-led headlines instead of UI labels.
- Keep one promise per image and make the real interface the largest element.
- Use the same typographic rhythm across the full gallery so it feels like one story.
- Alternate light, ember, and charcoal backgrounds to create rhythm while retaining one visual system.
- Use only deterministic synthetic books and artwork—never personal library data.

## Screenshot storyboard

| # | Promise | Conversion job | Source |
| --- | --- | --- | --- |
| 1 | **Open a browser. Drop in a book.** | Private local upload from Mac, Windows, Linux, or Chromebook. | 001-receiver-ready.png |
| 2 | **Drag. Drop. Done.** | Use iPhone Mirroring to drop books straight from Finder. | 002-mirroring-drop-progress.png |
| 3 | **Beautifully offline.** | A calm library for every audiobook you own. | 000-library.png |
| 4 | **Every control, just how you like it.** | Choose speed, skips, and chapter-aware seeking. | 003-playback-settings.png |
| 5 | **Your story. Your pace.** | Chapters, precise progress, and controls that stay close. | 004-now-playing.png |
| 6 | **Drift off. Keep your place.** | Stop after a timer, chapter, or track—with a gentle fade. | 005-sleep-timer.png |
| 7 | **50 hours included. Unlock once.** | Keep listening without a recurring subscription. | 006-full-unlock.png |

The opening sequence is deliberately ordered **any-computer upload → fastest Mac path → library → control**. It removes the biggest setup objection before showing the payoff, while keeping Files, AirDrop, the share sheet, and ZIP import as useful secondary paths in the description.

### 1. Any Computer

- **Eyebrow:** WORKS WITH ANY COMPUTER
- **Headline:** Open a browser. / Drop in a book.
- **Supporting line:** Private local upload from Mac, Windows, Linux, or Chromebook.
- **Theme:** paper

<img src="tests/e2e/013-app-store-listing/screenshots/ios/001-receiver-ready.png" width="260" alt="Real Bookshelf E2E source for 01-any-computer">

### 2. iPhone Mirroring

- **Eyebrow:** FASTEST ON A MAC
- **Headline:** Drag. Drop. / Done.
- **Supporting line:** Use iPhone Mirroring to drop books straight from Finder.
- **Theme:** ember

<img src="tests/e2e/013-app-store-listing/screenshots/ios/002-mirroring-drop-progress.png" width="260" alt="Real Bookshelf E2E source for 02-iphone-mirroring">

### 3. Library

- **Eyebrow:** YOUR BOOKS. YOUR PLACE.
- **Headline:** Beautifully / offline.
- **Supporting line:** A calm library for every audiobook you own.
- **Theme:** paper

<img src="tests/e2e/013-app-store-listing/screenshots/ios/000-library.png" width="260" alt="Real Bookshelf E2E source for 03-library">

### 4. Playback Settings

- **Eyebrow:** LISTEN YOUR WAY
- **Headline:** Every control, / just how you like it.
- **Supporting line:** Choose speed, skips, and chapter-aware seeking.
- **Theme:** night

<img src="tests/e2e/013-app-store-listing/screenshots/ios/003-playback-settings.png" width="260" alt="Real Bookshelf E2E source for 04-playback-settings">

### 5. Now Playing

- **Eyebrow:** MADE FOR LONG LISTENS
- **Headline:** Your story. / Your pace.
- **Supporting line:** Chapters, precise progress, and controls that stay close.
- **Theme:** paper

<img src="tests/e2e/013-app-store-listing/screenshots/ios/004-now-playing.png" width="260" alt="Real Bookshelf E2E source for 05-now-playing">

### 6. Sleep Timer

- **Eyebrow:** REST EASY
- **Headline:** Drift off. / Keep your place.
- **Supporting line:** Stop after a timer, chapter, or track—with a gentle fade.
- **Theme:** ember

<img src="tests/e2e/013-app-store-listing/screenshots/ios/005-sleep-timer.png" width="260" alt="Real Bookshelf E2E source for 06-sleep-timer">

### 7. Unlock

- **Eyebrow:** NO SUBSCRIPTION
- **Headline:** 50 hours included. / Unlock once.
- **Supporting line:** Keep listening without a recurring subscription.
- **Theme:** night

<img src="tests/e2e/013-app-store-listing/screenshots/ios/006-full-unlock.png" width="260" alt="Real Bookshelf E2E source for 07-unlock">

## Listing copy

### Name

`Bookshelf Offline Audio Player`

### Subtitle

`Your MP3 & M4B Audiobooks`

### Promotional text

Bring books in from any computer with a private browser upload—or drag them straight from Finder with iPhone Mirroring—then listen your way.

### Description

```text
Your books. Your files. Your place.

Bookshelf is a private, offline audiobook player for the MP3, M4A, and M4B files you own. Bring books in from any computer, then listen exactly your way.

FROM ANY COMPUTER
Open Bookshelf’s private receiver, enter its local address in a browser, and drop in your books. It works from Mac, Windows, Linux, or Chromebook, and the transfer stays on your local network.

FASTEST ON A MAC
With iPhone Mirroring, drag an audiobook straight from Finder onto Bookshelf. No upload form and no cable—just drag, drop, and listen.

You can also import through Files, AirDrop, the share sheet, or ZIP archives when those fit better. Bookshelf preserves embedded chapters, metadata, and cover artwork, and lets you review details before adding a book.

A LIBRARY THAT FEELS LIKE YOURS
• See cover art on warm wooden shelves
• Keep multi-part books together
• Search by title, author, narrator, or series
• Pick up at the exact place you stopped

LISTEN YOUR WAY
• Set playback speed from 0.5× to 3×
• Choose your own forward and backward skips
• Move by chapter or across the whole book
• Use a sleep timer with presets, custom times, chapter and track endings, and a gentle fade
• Save bookmarks and notes for moments worth keeping

PRIVATE BY DESIGN
Your library and listening history stay on your device. Bookshelf needs no account and includes no advertising or tracking.

TRY THE WHOLE EXPERIENCE
Bookshelf includes 50 hours of playback. A one-time in-app purchase unlocks unlimited playback. No subscription.

Bookshelf does not sell or provide audiobooks. Only import recordings you are legally permitted to use.
```

### Keywords

`m4a,files,import,airdrop,chapters,bookmark,sleep,timer,speed,local,library,listen,reader,drm-free`

### URLs

- Marketing: https://bookshelf.spnss.com/
- Support: https://bookshelf.spnss.com/#support

## Measurement plan

Record the first 14 and 28 days by acquisition source before changing the gallery.

- **Primary:** product-page conversion rate = first-time downloads ÷ unique product-page views.
- **Search/browse check:** install rate = first-time downloads ÷ unique impressions. This captures downloads made without opening the full page.
- **Diagnostic:** impressions → page views, split by App Store Search, Browse, App Referrer, and Web Referrer.
- **Quality guardrails:** day-1/day-7 retention, crash rate, and Full Unlock conversion. A gallery that attracts the wrong listener is not a win.
- **Benchmark:** use App Store Connect’s private peer-group benchmark for the Books category and free-with-IAP business model rather than treating the cross-category 8.56% figure as a target. [Apple: Peer group benchmarks](https://developer.apple.com/help/app-store-connect-analytics/benchmarks/peer-group-benchmarks/)

After enough traffic arrives, run Product Page Optimization tests in this order:

1. **Universal import framing:** “Open a browser. Drop in a book.” versus “Any computer. Straight to Bookshelf.” Change only slide 1.
2. **Mac-speed framing:** “Drag. Drop. Done.” versus “Finder to Bookshelf.” Change only slide 2.
3. **Control framing:** “Every control, just how you like it” versus “Listen exactly your way.” Change only slide 4.

Do not declare a winner before Apple reports at least 90% confidence. Keep screenshots and metadata unchanged while each experiment runs.

## Fresh-image pipeline

`tests/e2e/013-app-store-listing` is the only canonical screenshot baseline for marketing surfaces.

```text
E2E UI test → fresh ActualWalkthrough → listing renderer → temporary 1320×2868 PNGs → App Store Connect
                                  └──→ temporary website artifact → GitHub Pages
```

- The App Store PNGs live only under ignored `build/app-store-listing/` output.
- The website’s screenshots live only in the temporary site artifact.
- `docs/assets/` contains the durable app icon, but no copied app screenshots.
- Every prepare, upload, or website build reruns the E2E story and compares the fresh capture with its reviewed baseline before using it.

### Prepare the document and images

```bash
scripts/app-store-listing prepare
open build/app-store-listing/screenshots
```

### Preview an App Store Connect update

```bash
scripts/app-store-listing upload --version <editable-version>
```

### Apply the App Store Connect update

```bash
scripts/app-store-listing upload --version <editable-version> --apply
```

The upload command replaces the en-US 6.9-inch screenshot set, so `--apply` is required. Without it, the command is read-only and prints the exact metadata and screenshot plan.

### Build the website

```bash
scripts/build-website
open build/website/index.html
```
