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
