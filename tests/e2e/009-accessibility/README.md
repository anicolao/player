# Test: Core journeys remain usable with accessibility features

> As a listener using larger text, VoiceOver, or display accommodations, I can import, repair, organize, and listen without losing information or relying on gestures, motion, or color alone.

## Deterministic preconditions

- Fixtures are the existing legal synthetic `import-recovery-storage`,
  `synthetic-metadata-repair`, `messy-multifile-unicode`, and `bookmarks`
  corpora. Story 009 adds no media and never reads `books/`.
- Device target: iPhone 17, iOS 26.5, portrait, light appearance.
- Locale and time zone: `en_CA`, `America/Toronto`.
- Dynamic Type is fixed at Accessibility Extra Extra Extra Large
  (`accessibility5`).
- E2E environment profiles only override SwiftUI accessibility environment
  values. They never seed library state or replace product actions.
- All assertions use visible production controls, accessibility labels/values,
  the production model's existing state probes, or XCTest accessibility audits.

## Largest text keeps import recovery understandable and actionable

Proposed screenshot after semantic green:
`000-largest-text-import-recovery.png`.

**Required verifications:**

- [ ] The summary, section heading, and files follow visible reading order.
- [ ] Long filenames and issue explanations wrap without clipping or overlap.
- [ ] Retry and Remove remain at least 44 by 44 points and reachable by scroll.
- [ ] Every problem is communicated by text and symbol, not orange/red alone.
- [ ] Source-safe recovery values remain unchanged at the largest text size.

## Metadata repair exposes provenance and locks at the largest text size

**Required verifications:**

- [ ] Identity, contributors, series, cover, and Save remain reachable by scroll.
- [ ] Each field announces its label, value, source, confidence, and lock state once.
- [ ] Clear and lock controls have unambiguous labels and 44-point hit targets.
- [ ] The system audit reports no clipped text, unlabeled action, or invalid trait.

## Review Order never requires drag-and-drop

**Required verifications:**

- [ ] Each row announces position, filename, ordering evidence, and selection.
- [ ] Select, Move Earlier, Move Later, and Move to Book are VoiceOver actions.
- [ ] The equivalent visible buttons remain available without a drag gesture.
- [ ] Moving the Unicode prelude changes the production order revision exactly once.

## Now Playing and Bookmarks remain fully operable

Proposed screenshot after semantic green:
`001-largest-text-now-playing.png`.

**Required verifications:**

- [ ] The scrubber announces elapsed and total time and supports adjustable actions.
- [ ] Play, skip, bookmark, timer, and settings controls remain visible and tappable.
- [ ] Bookmark rows announce label, time, chapter, and note without duplicate speech.
- [ ] Jump, Edit, and Delete are both custom actions and visible accessible controls.
- [ ] Reduce Motion, increased contrast, and Differentiate Without Color are active
  together without changing playback or library state.
- [ ] Status and selection use shape, symbol, and text rather than color alone.

The screenshots stay pending until every programmatic assertion and the manual
VoiceOver checklist are green. No baseline may be recorded from a private library.
