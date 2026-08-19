# Test: A local audiobook moves from Inbox to playback

> As a listener, I want to review one imported audiobook, add it to my library, and know its managed audio is ready to play.

## Deterministic preconditions

- Fixture: `single-audiobook-ready`
- Xcode: 26.6
- Device: iPhone 17 on iOS 26.5, portrait, light appearance, standard Dynamic Type
- Locale and time zone: `en_CA`, `America/Toronto`
- Status bar: fixed at 9:41 AM, full battery, and full network indicators
- Animations: disabled by the E2E build configuration
- Network and clock data: unused by this story
- Identifiers, metadata, duration, and import timestamps are fixed
- Playback uses the deterministic engine behind the production playback boundary

## The inspected audiobook is ready for review

![The inspected audiobook is ready for review](./screenshots/ios/000-review-import.png)

**Verifications:**

- [x] The Review Import screen is visible
- [x] The inspected title is presented
- [x] The inspected author is presented
- [x] The import can be committed

## The committed audiobook appears in the local library

![The committed audiobook appears in the local library](./screenshots/ios/001-committed-library.png)

**Verifications:**

- [x] The Library reports exactly one committed book
- [x] The committed title is visible
- [x] The committed author is visible

## Book Detail exposes the playable managed audiobook

![Book Detail exposes the playable managed audiobook](./screenshots/ios/002-book-detail.png)

**Verifications:**

- [x] The Book Detail screen is visible
- [x] The audiobook has a Play action
- [x] The inspected asset count and duration are retained

## Now Playing has loaded and paused the managed audio

![Now Playing has loaded and paused the managed audio](./screenshots/ios/003-paused-now-playing.png)

**Verifications:**

- [x] The deterministic engine acknowledges a paused loaded book
- [x] Now Playing retains the book identity
- [x] The transport remains available
