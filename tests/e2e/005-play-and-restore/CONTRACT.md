# Position restore E2E contract

This contract is kept separately because the walkthrough `README.md` is
regenerated from XCTest attachments whenever reviewed screenshots are recorded.

## Bootstrap

The first process launches with:

```text
-e2e -e2e-reset -e2e-fixture committed-current-book
```

The second process omits only `-e2e-reset`. Both processes must resolve the same
E2E persistence and managed-media root. Reset clears and seeds that root; fixture
selection alone opens it without replacing durable state.

The seed contains one committed, current 120-second book with stable ID
`20000000-0000-0000-0000-000000000001`, chapter index `0`, and acknowledged
position `12000` milliseconds. It uses the normal position journal and restore
logic. Dependency injection may provide a deterministic clock and playback
engine, but views and persistence must not branch on the fixture name.

## UI semantics

| Element | Identifier | Required value or action |
| --- | --- | --- |
| Library root | `library-screen` | `ready:library-1-books` |
| Mini-player | `mini-player` | Tappable; playback value below |
| Now Playing root | `now-playing-screen` | Playback value below |
| Position | `player-position-slider` | Adjustable; 50% resolves to `60000` ms |
| Transport | `player-play-pause` | Toggles paused and playing |

Both playback surfaces expose exactly:

```text
player:<paused|playing>:<lowercase-book-uuid>:<zero-based-chapter>:<elapsed-ms>
```

The deterministic engine does not advance position with wall-clock time. A seek
is acknowledged before its adjustment completes. An orderly pause durably
journals its exposed position before the button action completes.

On restoration, the reported position must satisfy:

```text
acknowledged_ms - 500 <= restored_ms <= acknowledged_ms
```

Only the restored paused Library and Now Playing states are captured. The
seek/play/pause setup is assertion-only so a moving progress affordance can never
enter a zero-tolerance visual baseline.

## Remote commands and lifecycle events

`RemoteInterruptionUITests` adds `-e2e-event-controls`. In an E2E build only,
this exposes a test control surface with these tappable identifiers:

| Identifier | Production-boundary event |
| --- | --- |
| `e2e-remote-play` | Registered remote play handler |
| `e2e-remote-pause` | Registered remote pause handler |
| `e2e-remote-toggle` | Registered remote toggle handler |
| `e2e-remote-next-track` | Car/headset next-track event mapped to the configured 30-second forward interval |
| `e2e-remote-previous-track` | Car/headset previous-track event mapped to the configured 15-second backward interval |
| `e2e-interruption-began` | Audio-session interruption-began event |
| `e2e-interruption-ended-no-resume` | Interruption-ended event without resume permission |

The buttons must publish through injected event sources consumed by the same
handlers as `MPRemoteCommandCenter` and `AVAudioSession`. They must not call
`PlayerModel` directly. Production adapters and E2E event sources differ only at
the outer event-source boundary.

The app exposes a read-only `e2e-playback-probe` accessibility element whose
value is:

```text
probe|<paused|playing>|<book-uuid>|<chapter-index>|<position-ms>|<journal-sequence>|<last-reason>|<persisted-position-ms>|<registered-command-csv>
```

The registered command CSV contains exactly `change-position`, `change-rate`,
`next-track-skip-forward`, `pause`, `play`,
`previous-track-skip-backward`, `skip-backward`, `skip-forward`, and `toggle`;
ordering is immaterial. The probe
reads the real observable playback state, recovered snapshot, latest
integrity-valid journal event, and production remote-registration state. Reading
it has no side effects. Absolute-position behavior is covered by the same
injected production boundary in the core integration suite.

The fixture starts with journal sequence 1, reason `pause`, at 12,000 ms. Every
remote play/pause/seek completes its production-model operation before the E2E
control action returns. The car/headset next-track event reaches 42,000 ms and
the previous-track event returns to 27,000 ms through the same configured
interval mapping used by the production adapter. Each produces one event using
the existing `play`, `pause`, or `seek` reason and advances the journal sequence
exactly once.

Interruption-began pauses and appends one `interruption` event. Ending without
resume permission stays paused and appends nothing. The test then resumes and
uses the real Home button; entering background appends one `background` event
without stopping permitted background audio. Reactivating the app appends no
synthetic position event. The final remote pause is recovered unchanged after
termination and relaunch without reset.

This extension is intentionally nonvisual. Remote registration, event routing,
and journal durability have no meaningful pixels beyond the paused player already
covered by this story's two baselines. The test must not create screenshot or UI
hierarchy attachments.

## Configurable listening controls

`TransportControlsUITests` launches the durable `metadata-rich-book` fixture,
which contains a 120-second book with three chapter boundaries. Through visible
production UI it changes library defaults, starts chapter 2, verifies previous
and next chapter navigation, and verifies the configured skip intervals. It then
saves a complete per-book override of 1.25× speed, 10-second backward skip,
30-second forward skip, and chapter-relative scrubbing.

The test terminates and relaunches without reset. The restored transport action
must expose exactly:

```text
rate=1.25:back=10:forward=30:seek=chapter:source=book
```

The final configured skip must be durably acknowledged as book position
`55000` milliseconds, with the visible scrubber in chapter-relative mode. Only
the final stable paused state is captured as
`002-transport-controls.png`; all setup and moving states are assertion-only.

## Smart Rewind, durable explanation, and exact Undo

`SmartRewindUITests` launches the `smart-rewind` fixture with an injected fixed
clock and one of these scenario arguments:

```text
-e2e-smart-rewind-scenario <below-threshold|short|medium|long|maximum|chapter-clamp|disabled>
```

Every scenario contains the same synthetic 180-second audiobook with lowercase
book UUID `51000000-0000-0000-0000-000000000001`, four embedded chapters, one
managed synthetic media file, and a latest acknowledged `pause` event. Only the
pause timestamp, saved position, and Smart Rewind preferences vary. The fixed
resume clock makes time-away calculations exact:

| Scenario | Away | Saved position | Expected target | Contract |
| --- | ---: | ---: | ---: | --- |
| `below-threshold` | 29 s | 120000 ms | 120000 ms | No transaction below 30 seconds |
| `short` | 30 s | 120000 ms | 115000 ms | Short 5-second tier |
| `medium` | 600 s | 120000 ms | 105000 ms | Medium 15-second tier |
| `long` | 3601 s | 170000 ms | 140000 ms | Long 30-second tier |
| `maximum` | 3601 s | 170000 ms | 150000 ms | The visible setting caps the 30-second tier at 20 seconds |
| `chapter-clamp` | 600 s | 110000 ms | 100000 ms | The 15-second request clamps to chapter start |
| `disabled` | 3601 s | 120000 ms | 120000 ms | Disabled means no transaction or rewind |

The normal Now Playing `player-play-pause` action drives implicit resume; the
fixture does not call a test-only playback mutation. When a rewind applies, the
visible `smart-rewind-banner` value is:

```text
rewound|<lowercase-book-uuid>|from=<ms>|to=<ms>|by=<ms>|away=<seconds>|clamped=<true|false>|status=applied
```

The banner explains the adjustment and exposes `undo-smart-rewind` with value
`restore=<original-ms>`. The E2E-only read-only `smart-rewind-state-probe`
serializes production snapshot and journal state as pipe-delimited key/value
tokens. It includes enabled, maximum milliseconds, transaction count/status and
IDs, original/target/rewind/away/clamp fields, current persisted position, and a
`journal=<sequence>:<reason>@<position>,...` suffix.

The maximum scenario first navigates through `smart-rewind-settings` to the
production `smart-rewind-settings-screen`. It changes `smart-rewind-maximum`
from 30 to 20 seconds, toggles `smart-rewind-enabled` off, terminates, and
asserts both values after relaunch. It then toggles Smart Rewind on, relaunches
again, and uses that durable 20-second maximum through the normal resume action.
The separate disabled scenario proves that an off preference produces neither
a rewind transaction nor a position adjustment.

For every applied scenario, deterministic IDs are consumed in this order:

1. pre-rewind event `51000000-0000-0000-0000-000000000101`;
2. rewind event `51000000-0000-0000-0000-000000000102`;
3. transaction `51000000-0000-0000-0000-000000000103`;
4. play event `51000000-0000-0000-0000-000000000104`.

The chapter-clamp process terminates after applying the rewind and relaunches
without reset. The transaction must still be `applied`, the restored position
must remain exactly `100000` ms, and relaunch must not apply a second rewind.
One tap on Undo seeks exactly to `110000` ms, appends one
`undoResumeRewind` event with ID
`51000000-0000-0000-0000-000000000105`, marks the transaction `undone`, and removes the Undo
action. No setup, maximum, disabled, or post-Undo state is captured. After the
complete semantic journey is green, the sole new stable baseline is
`003-smart-rewind-applied.png`, showing the explanatory chapter-clamped banner
and Undo action on Now Playing.
