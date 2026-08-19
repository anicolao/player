# Test: Player launches into an empty local library

> As a new listener, I want Player to open into a ready and understandable library so I can add my first audiobook.

## Deterministic preconditions

- Fixture: `empty-library`
- Xcode: 26.6
- Device: iPhone 17 on iOS 26.5, portrait, light appearance, standard Dynamic Type
- Locale and time zone: `en_CA`, `America/Toronto`
- Status bar: fixed at 9:41 AM, full battery, and full network indicators
- Animations: disabled by the E2E build configuration
- Network and clock data: unused by this story

## Player launches into the ready empty-library state

![Player launches into the ready empty-library state](./screenshots/ios/000-empty-library.png)

**Verifications:**

- [x] The Library screen is visible
- [x] The application reports the ready empty-library state
- [x] The empty state explains the next action
- [x] The Add Audiobook action is available
- [x] The Library tab is selected and available
- [x] The Inbox tab is available
- [x] The Settings tab is available
- [x] No mini-player appears without a book
