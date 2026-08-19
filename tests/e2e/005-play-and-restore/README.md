# Test: A paused listening position survives app termination

> As a listener, I want Player to return at audio I have already heard after I close and reopen the app.

## Deterministic preconditions

- Fixture: `committed-current-book`
- Xcode: 26.6
- Device: iPhone 17 on iOS 26.5, portrait, light appearance, standard Dynamic Type
- Locale and time zone: `en_CA`, `America/Toronto`
- Status bar: fixed at 9:41 AM, full battery, and full network indicators
- Animations: disabled by the E2E build configuration
- Network and clock data: unused by this story
- The fixture contains one committed 120-second book at chapter 1 and 12 seconds
- The first launch resets the fixture; the restore launch reuses the same durable E2E store
- The deterministic playback engine does not advance with wall-clock time
- A 50 percent slider seek resolves exactly to 60,000 milliseconds
- An orderly pause acknowledges and journals the position before returning

## Library restores the paused current book in its mini-player

![Library restores the paused current book in its mini-player](./screenshots/ios/000-restored-library.png)

**Verifications:**

- [x] The restored Library screen is visible
- [x] The durable library still contains exactly one book
- [x] The current book is available in the mini-player
- [x] The mini-player is paused at most 500 ms behind and never ahead of the acknowledged position

## Now Playing opens paused at the safely restored position

![Now Playing opens paused at the safely restored position](./screenshots/ios/001-restored-now-playing.png)

**Verifications:**

- [x] The restored Now Playing screen is visible
- [x] Now Playing is paused at most 500 ms behind and never ahead of the acknowledged position
- [x] The restored Play control is available
- [x] The restored position remains adjustable

## Nonvisual system-control journey

`RemoteInterruptionUITests` exercises behavior that has no additional useful
pixels beyond the stable paused screens above. It programmatically verifies:

- [x] Lock Screen and accessory play, pause, toggle, skip, and position commands are registered
- [x] Remote commands use the same durable play, pause, and seek paths as the app UI
- [x] Interruption and disconnected-output policies pause and journal acknowledged audio
- [x] Entering the background checkpoints without stopping permitted background playback
- [x] Every event advances the integrity-checked journal exactly once
- [x] The final remotely paused position restores exactly after termination and relaunch
