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
| `e2e-remote-skip-forward` | Registered configured 30-second forward handler |
| `e2e-remote-skip-backward` | Registered configured 15-second backward handler |
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
`next-chapter`, `pause`, `play`, `previous-chapter`, `skip-backward`,
`skip-forward`, and `toggle`; ordering is immaterial. The probe
reads the real observable playback state, recovered snapshot, latest
integrity-valid journal event, and production remote-registration state. Reading
it has no side effects. Absolute-position behavior is covered by the same
injected production boundary in the core integration suite.

The fixture starts with journal sequence 1, reason `pause`, at 12,000 ms. Every
remote play/pause/seek completes its production-model operation before the E2E
control action returns. Forward skip reaches 42,000 ms and backward skip reaches
27,000 ms. Each produces one event using the existing `play`, `pause`, or `seek`
reason and advances the journal sequence exactly once.

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
