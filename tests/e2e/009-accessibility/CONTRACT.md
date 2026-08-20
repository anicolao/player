# Story 009 accessibility E2E contract

## Scope and evidence boundary

Story 009 extends existing synthetic journeys instead of inventing accessible
fixture-only screens. E2E may select accessibility environment values and expose
read-only environment/rendering probes. Import, repair, reorder, seek, bookmark,
and recovery actions must still cross the ordinary production UI and model.

The automated contract has three layers:

1. exact production model values prove actions still change the intended state;
2. labels, values, hit regions, reading order, and XCTest accessibility audits
   prove a machine-checkable accessibility surface;
3. `VOICEOVER_CHECKLIST.md` proves focus, speech, rotor, and custom-action behavior
   that XCUI cannot enumerate reliably.

## Synthetic fixture and privacy contract

Only these already checked-in/generated fixture identities are allowed:

| Journey | Fixture | Existing stable data |
| --- | --- | --- |
| Import recovery | `import-recovery-storage`, scenario `mixed` | jobs/files under UUID prefix `61000000` |
| Metadata repair | `synthetic-metadata-repair` | generated M4B/covers, job prefix `80000000` |
| Review Order | `messy-multifile-unicode` | generated tones, job/assets prefix `30000000` |
| Playback/bookmarks | `bookmarks` | 120-second synthetic book, prefix `53000000` |

Story 009 adds no media fixture, network request, discovered tag, artwork, path,
or checksum. It must never read `books/`. Screenshots and diagnostics may contain
only the invented fixture copy already approved in the source stories.

## Accessibility profile launch channel

Every launch uses the largest public content-size preference:

```text
-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL
```

The E2E-only argument below overrides environment values at the app root before
the first frame. It must not branch view content or mutate `PlayerModel`:

```text
-e2e-accessibility-profile largest-text
-e2e-accessibility-profile voiceover
-e2e-accessibility-profile assistive-display
```

The read-only `accessibility-environment-probe` is computed from the effective
SwiftUI environment, not from the argument string:

```text
accessibility:dynamic-type=accessibility5:reduce-motion=false:contrast=standard:differentiate=false
accessibility:dynamic-type=accessibility5:reduce-motion=true:contrast=increased:differentiate=true
```

`voiceover` retains standard display values; it is a deterministic semantic
audit profile and does not claim XCTest has enabled the VoiceOver service.
Actual VoiceOver is covered by the manual checklist.

For the combined `assistive-display` profile, `accessibility-rendering-probe`
must be derived from the same production rendering policy used by the views:

```text
rendering:motion=reduced:contrast=increased:status=shape-symbol-text
```

Reduced motion replaces decorative transitions with identity/opacity changes and
never delays a state update. Increased contrast uses tested high-contrast color
tokens. Differentiate Without Color requires a stable symbol/shape and text for
warning, success, selected, playing, and disabled states. The probe cannot itself
be the implementation.

## Global semantic rules

- Interactive targets are at least 44 by 44 points at every tested size.
- Text that conveys identity, state, or recovery is allowed to wrap and is never
  truncated merely to retain the standard-size layout.
- Accessibility order matches visible top-to-bottom, leading-to-trailing order;
  hidden probes are last and are not VoiceOver focusable outside E2E.
- Screen titles and section names use heading traits.
- Buttons announce Button once; selected controls expose selected traits/values;
  disabled controls remain explained but cannot be activated.
- A successful mutation moves focus to confirmation or updated content; a closed
  sheet returns focus to its opener; destructive actions announce the Undo path.
- Composite rows emit one concise label/value. Their child controls remain
  separately focusable or are mirrored as custom actions, never both spoken twice.
- XCTest audits must pass contrast, Dynamic Type, element detection, hit region,
  sufficient-description, clipped-text, and trait categories. iOS XCUI cannot
  enumerate custom actions, so action names/order/activation remain a required
  manual VoiceOver audit rather than a hidden-probe substitute.
- The audit handler may ignore only elements whose stable identifier ends in
  `-probe`, because those are one-point read-only E2E instrumentation. It must not
  suppress an issue by description, type, view, fixture, or production identifier.

## Import and recovery contract

At `accessibility5`, opening mixed job
`61000000-0000-0000-0000-000000000002` exposes:

| ID | Label | Value or required order |
| --- | --- | --- |
| `import-recovery-screen` | `Review Import` | Existing exact recovery state value |
| `recovery-summary` | `Some files need attention` | `1 file ready. 2 duplicates. 2 files need attention. Sources unchanged.` |
| `recovery-files-heading` | `Selected files` | Heading, after summary |
| `recovery-file-…0102` | `02-retry-signal.m4a` | `Audio could not be read. Recoverable. Source unchanged.` |
| `retry-import-file-…0102` | `Retry File` | Hint: `Try reading 02-retry-signal.m4a again.` |
| `remove-import-file-…0102` | `Remove 02-retry-signal.m4a` | Hint explains only staged copy is removed |

The composite recoverable-file row custom actions are ordered `Retry File`,
`Remove File`, `Choose Another Selection`. Activating the first two calls the same
closures as their visible buttons. The accepted and duplicate rows use text plus
`checkmark.circle`/`doc.on.doc`; failed rows use text plus
`exclamationmark.circle`. Color is supplementary.

## Metadata repair contract

`metadata-editor-screen` is labeled `Edit Details`. Its sections are headings in
visible order: Cover, Identity, Contributors, Series, Description and
classification, Publication, then the lock explanation.

Each `metadata-field-<field>` is one summary element with:

```text
label: <human field name>
value: <value or Empty>. <source>, <confidence>. <Locked|Unlocked>.
```

For the initial title this is exactly:

```text
label = Title
value = The Brass Lantern. Embedded tag, high confidence. Unlocked.
```

Inputs retain their normal Text Field traits. Lock controls announce `Lock <field>`
or `Unlock <field>` and expose their current state. `metadata-clear-narrators`
announces `Clear narrators`; clear, replace/remove cover, and Save retain 44-point
targets and remain reachable by scrolling. Provenance probes remain E2E-only and
must not duplicate spoken production summaries.

## Review Order and non-drag correction

Every `order-track-<lowercase UUID>` announces:

```text
label: Track <one-based position>, <filename>
value: <ordering evidence>. <Selected|Not selected>.
custom actions: Select/Deselect Track, Move Earlier, Move Later, Move to <book>
```

Unavailable boundary actions are omitted. Custom actions and visible
`order-select-*`, `order-move-up-*`, `order-move-to-*` controls call the same
production methods. A keyboard/switch/VoiceOver user never needs `.onMove`.

The contract selects prelude asset
`30000000-0000-0000-0000-000000000111`, then activates visible Move Earlier.
`order-probe` must change once from revision 0 to:

```text
order|revision|1|a|a1,a2,ap,a10|b|b3,b4,b5,b6
```

The initial prelude summary is `Track 4, Prélude – été.m4a`, and its value includes
`Natural filename order for Prélude – été.m4a` plus its not-selected state.

## Now Playing and adjustable seek

`now-playing-screen` is a named screen container whose children follow: artwork,
title/author, chapter, banners, scrubber, transport controls, settings. Decorative
artwork is hidden from VoiceOver when its information is already present in text.

`player-position-slider` has:

```text
label = Listening position
value = <elapsed time> of <total time>
hint = Swipe up or down to move by 30 seconds.
```

Its adjustable increment/decrement calls the same seek path as touch scrubbing,
clamps to book/chapter bounds according to current production preferences, and
announces the resulting elapsed/total value. In the 120-second bookmark fixture,
adjusting from 60,000 ms to normalized 0.25 resolves to exactly 30,000 ms and the
existing Now Playing probe becomes:

```text
player:paused:53000000-0000-0000-0000-000000000001:0:30000
```

## Bookmark contract

The test adds a bookmark through production `add-bookmark` at the seeded exact
asset/chapter boundary of 60,000 ms, before the adjustable-seek assertion consumes
a deterministic position-event ID. Its ID
is `53000000-0000-0000-0000-000000000101`. The row exposes:

```text
label = The Crossing · 1:00
value = 1:00. The Crossing. No note.
custom actions = Jump, Edit, Delete
```

The visible controls remain available with contextual labels:

```text
Jump to The Crossing · 1:00
Edit The Crossing · 1:00
Delete The Crossing · 1:00
```

Custom actions call these exact production operations. Search and sort announce
their labels, current values, and result counts. After Jump, focus moves to the
durable jump confirmation; after Delete, to Undo; after Undo, to the restored row.

## Screenshot scope

Only after the full programmatic test and manual checklist are green may
TestStepHelper attach and compare:

```text
000-largest-text-import-recovery.png
001-largest-text-now-playing.png
```

The first proves the densest actionable recovery state wraps and scrolls at the
largest size. The second proves the primary playback information and controls
reflow without clipping. Metadata, reorder, bookmark actions, motion, and color
accommodations remain semantic/manual because screenshots would be redundant or
cannot prove their behavior. No baseline is recorded during isolated authoring.
