# Accessibility audit

Status: C03 MVP completion evidence

This audit applies the accessibility contract in [MVP_DESIGN.md](MVP_DESIGN.md)
to the iPhone app's core listener journeys. Story 009 is the executable task
audit: it runs on an iPhone 17 simulator at Accessibility XXXL with Increase
Contrast enabled, verifies production accessibility elements, and records the
screens a reviewer needs to inspect.

## Core task matrix

| Task | Large-text result | Semantic and alternate-action evidence |
| --- | --- | --- |
| Review an import | Reflows into a vertical scroll view; Add to Library remains pinned, named, enabled, and reachable | The screen and primary action expose exact ready-state values; completion posts one announcement |
| Repair metadata | Cover and fields stack; the title accepts multiple lines; Save remains in the navigation bar | Fields and explicit Apply/Save actions have unique human-readable labels; save posts one completion announcement |
| Browse Library | Continue Listening becomes a vertical list and All Books becomes one column | Book identity, progress, action, value, and hint are grouped without making a nested trailing action ambiguous |
| Open Book Detail | Identity and primary actions stack instead of compressing | Play remains a separate named action and the screen exposes a stable semantic state |
| Listen in Now Playing | The screen scrolls; the timeline and transport controls remain reachable | The native adjustable slider reports chapter, elapsed, remaining, and percent; Play/Pause and skips are separately named |
| Reorder Up Next | Rows stack at accessibility sizes | Every row has explicit Move Earlier and Move Later buttons naming the affected audiobook, so drag is optional |
| Change display preferences | The Settings form uses native switches and reports active system settings separately | Switches update immediately and a model probe verifies that rapid adjacent changes both persist |
| Receive from a computer | Address, pairing code, instructions, and receiver state remain scrollable | The ready state, address, and pairing code are discoverable as named elements |
| Back up and restore | Settings actions remain reachable and the restored Library remains playable | Story 010 verifies export, empty state, atomic restore, and resumed playback without relying on color |

## System-setting behavior

| Setting | Implemented behavior | Verification |
| --- | --- | --- |
| Larger Text | Grids become lists, horizontal action rows stack, decorative mini-player artwork yields before text, and Now Playing scrolls | Story 009 at Accessibility XXXL plus canonical screenshots |
| Increase Contrast | The system setting is authoritative; the app preference can strengthen borders and separators further | Story 009 runs with Increase Contrast and checks the reported system state |
| Differentiate Without Color | Existing text, icons, checkmarks, state values, and optional card outlines remain available without color | Source audit plus exact state assertions in Stories 002–010 |
| Reduce Motion | Root transactions remove animation and disable animated transitions while preserving state changes | Source audit; no task depends on animation completion |
| Bold Text | Native text reflows rather than clipping fixed-width labels | Dynamic Type layouts avoid fixed form-label widths; status is visible in Accessibility Settings |
| Reduce decorative artwork | Decorative covers are replaced by a book symbol; metadata-editing artwork remains because it is content | Focused preference UI test and persisted preference unit tests |

## VoiceOver task audit

The automated audit follows the same traversal targets used by VoiceOver and
checks labels, identifiers, values, hints, adjustable controls, and non-drag
actions. It covers the complete path from import review through playback, Up
Next, Settings, and direct import. It also checks the completion announcements
for import and metadata repair at their production call sites.

Speech pronunciation and subjective reading-order comfort still require a
human listening pass on a physical device; XCTest cannot evaluate synthesized
speech quality. That pass is non-blocking for functional correctness and should
be repeated before an external TestFlight or App Store release. Any issue found
there is a C06 cleanup defect, not a reason to weaken the semantic assertions.

## Reproduction

Run the exact Story 009 task and pixel audit:

```sh
apps/ios/scripts/run-e2e.sh \
  --story 009-accessible-core-journeys \
  --test PlayerUITests/AccessibilityUITests/testCoreJourneysRemainCompleteAtLargestAccessibilityText
```

The focused preference interaction test is also part of
`AccessibilityUITests`; unit coverage verifies schema-14 migration and
schema-15 persistence. CI runs Story 009 alongside Stories 001–010 at the exact
commit SHA.
