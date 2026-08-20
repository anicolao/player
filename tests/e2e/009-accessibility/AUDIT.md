# Current accessibility gap audit

This is a source audit of the pre-Story-009 UI. It records integration work; it
does not mark the current implementation accessible merely because an identifier
or hidden E2E probe exists.

| Journey | Existing strength | Gap to close before Story 009 runs |
| --- | --- | --- |
| Import/recovery | Stable screen, row, and remediation IDs; issue text accompanies color | File rows are `.contain` groups without concise labels or custom actions; Remove lacks filename context; wrapping/hit regions are unproved at AX5 |
| Metadata repair | Inputs, explicit clear/lock/cover controls, and provenance state exist | Field source/value/lock can be spoken as several disconnected elements; fixed 88-point label column is fragile at AX5; small caption controls need 44-point targets |
| Review Order | Visible select and Move Earlier/Move-to controls provide a non-drag path | `.onMove` is still primary; row action menu has generic `Track actions`; rows lack position/evidence values and custom-action parity |
| Now Playing | Transport buttons have descriptive labels and the native slider is adjustable | Slider exposes no explicit elapsed/total accessibility value or 30-second hint; large fixed artwork/spacing risks hiding controls at AX5 |
| Bookmarks | Jump/Edit/Delete have labels and rows expose deterministic E2E values | Edit/Delete labels omit bookmark identity; row value is machine syntax, not spoken prose; no Jump/Edit/Delete custom actions; one-line chapter/undo copy can truncate |
| Assistive display | Warnings generally pair text with SF Symbols | No explicit Reduce Motion, increased-contrast, or Differentiate Without Color environment handling was found; static custom colors do not adapt through a tested contrast policy |

Cross-cutting gaps:

- No current source reads `accessibilityReduceMotion`, `colorSchemeContrast`, or
  `accessibilityDifferentiateWithoutColor`.
- Stable hidden E2E probes are often accessibility elements and can pollute
  VoiceOver order; production builds must hide them and E2E must place them last.
- Identifiers verify automation addressability, not sufficient spoken labels,
  traits, rotor order, focus restoration, or custom actions.
- Current source tests standard Dynamic Type only. Story 009 adds AX5 layout and
  XCTest contrast/Dynamic-Type/element-detection/hit-region/description/clipping/
  trait audits; iOS custom actions require the separate manual VoiceOver pass.
