# Story 007 — Persistent Sleep Timer contract

Story 007 proves that the sleep timer is a durable listening feature, not a view-local countdown. Every timer is started, replaced, or cancelled through production UI. E2E controls may only move the deterministic clock/playback position and ask the production model to evaluate the timer.

## Deterministic fixture

Launch arguments:

- `-e2e -e2e-reset -e2e-fixture sleep-timer -e2e-sleep-timer-namespace <name>` resets an isolated namespace.
- Omitting `-e2e-reset` reopens that namespace's persisted library.
- Locale is `en_CA`, time zone is `America/Toronto`, and the E2E clock is fixed at Unix time `1700020000` until explicitly advanced.

The synthetic fixture is generated in app-owned E2E storage and contains no private or copyrighted media:

- book `52000000-0000-0000-0000-000000000001`, “The Quiet Hours” by Mara Vale;
- two synthetic 90-second M4B asset records with timeline starts at 0 and 90 seconds;
- three chapters: 0–60, 60–120, and 120–180 seconds;
- one acknowledged paused position at 70,000 ms;
- deterministic generated IDs beginning at suffix `101`, with relaunches deriving the next suffix from the durable store.

At 70 seconds, End of Chapter targets 120,000 ms and End of Track targets 90,000 ms. With fade enabled, the End of Track timer enters `fading` at 85,000 ms, writes no stop/history yet, and completes at exactly 90,000 ms.

## Production accessibility contract

Now Playing:

- `open-sleep-timer` opens the production timer sheet. Its value is `inactive` or `active:<timer UUID>:remaining=<seconds|none>:phase=<phase>`.
- `sleep-resume-context` exposes `history=<UUID>:book=<UUID>:stop=<ms>:until=<epoch seconds>`.
- `resume-sleep-context` invokes the production one-time contextual resume.

Timer sheet:

- `sleep-timer-screen`
- `sleep-timer-fade`
- `sleep-timer-preset-10`, `sleep-timer-preset-15`, `sleep-timer-preset-30`, `sleep-timer-preset-45`, `sleep-timer-preset-60`
- `sleep-timer-custom-picker`, options `sleep-timer-custom-<minutes>`, and `start-custom-sleep-timer`
- `sleep-timer-end-chapter`, `sleep-timer-end-track`
- `active-sleep-timer`
- `cancel-sleep-timer`
- `sleep-history-<lowercase history UUID>`

`sleep-timer-screen` values are:

- inactive: `sleep-timer:active=none:fade=<bool>:history=<count>`
- active: `sleep-timer:active=<UUID>:selection=<token>:remaining=<seconds|none>:target=<ms|none>:fade=<bool>:phase=<phase>:history=<count>`

Selection tokens are `preset-10`, `preset-15`, `preset-30`, `preset-45`, `preset-60`, `custom-1500`, `end-chapter`, and `end-track` for this journey.

History rows expose:

`history=<UUID>:timer=<UUID>:selection=<token>:status=<completed|cancelled|replaced>:stop=<ms>:event=<UUID|none>:context-used=<bool>`

While active, the existing `mini-player` value retains its established player prefix and appends:

`|sleep=<timer UUID>,selection=<token>,remaining=<seconds|none>,fade=<bool>,phase=<phase>`

All UUIDs are lowercase production UUIDs; fixture aliases never appear in accessibility values.

## E2E-only evaluation channel

`sleep-timer-state-probe` serializes the production model as pipe-delimited key/value tokens:

`sleep-timer|active=...|selection=...|fade=...|phase=...|remaining=...|target=...|history=...|latest=...|rewinds=...|history-id=...|history-timer=...|history-selection=...|stop=...|event=...|context-used=...|context=...|context-book=...|context-stop=...|context-until=...|position=...|playback=...|journal=...`

History/context detail tokens are present only when applicable. `journal` contains exact `sequence:reason@position` entries.

Two E2E-only buttons are available only while the deterministic End of Track timer is active:

- `e2e-sleep-enter-fade` seeks through the production model to 85 seconds and calls `evaluateSleepTimer()`.
- `e2e-sleep-complete-boundary` seeks through the production model to 90 seconds, calls `evaluateSleepTimer()`, and hides the E2E controls.

They never create timers, history, stop events, or resume transactions directly.

## Required journey

1. In isolated reset namespaces, open the production sheet and start 10, 15, 30, 45, and 60 minute presets, a 25-minute custom timer, End of Chapter, and End of Track. Assert exact selection, remaining/target, fade, position, and empty history from the production probe. Toggle fade off through the native production Toggle for the 45-minute case.
2. Start 10 minutes, replace it with 15 minutes, and cancel through production UI. Assert a replaced history entry for the first timer and a cancelled entry for the second; relaunch and assert both remain while no timer is active.
3. Start End of Track with fade enabled, terminate, and relaunch. Assert the mini-player and sheet restore the same timer with 20 seconds remaining and offer Cancel.
4. Play normally. At 85 seconds assert phase `fading`, five seconds remaining, playback still playing, and no completion history/event. At 90 seconds assert playback paused, active timer cleared, an acknowledged `.sleepTimer` position event at exactly 90,000 ms, completed history, and an unused ten-minute context expiring at `1700020600`.
5. Terminate and relaunch. Assert the paused 90,000 ms stop and Resume-with-context affordance survived.
6. Tap ordinary Play and assert it appends only `.play`, creates no Smart Rewind transaction, and leaves context available. Pause again.
7. Tap Resume with context. Assert the forced five-second contextual rewind reaches 85,000 ms, appends `.preResumeRewind`, `.resumeRewind`, and `.play`, consumes the history context atomically, and cannot be offered a second time.

## Screenshot policy

Record only after the complete semantic journey passes:

1. `000-persisted-active-sleep-timer.png` — stable timer sheet after process relaunch, showing End of Track, 0:20 remaining, fade behavior, and Cancel.
2. `001-sleep-stop-resume-context.png` — stable paused Now Playing after completed-stop relaunch, showing the saved sleep stop and one-tap Resume context.

Preset setup, moving fade/countdown state, replacement/cancellation, and post-Resume playback remain semantic-only. Synthetic fixture data only; never capture private books or metadata.
