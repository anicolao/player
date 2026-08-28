# Test: ZIP imports reject unsafe entries and keep recovery actionable

> As a listener importing archives, I want Bookshelf to reject unsafe content without touching my source and help me cancel, choose another file, or retry a temporary failure.

## Deterministic preconditions

- Fixture: `safe-zip-import`
- Xcode: 26.6
- Device: iPhone 17 on iOS 26.5, portrait, light appearance, standard Dynamic Type
- Locale and time zone: `en_CA`, `America/Toronto`
- Status bar: fixed at 9:41 AM, full battery, and full network indicators
- Animations: disabled by the E2E build configuration
- Network and clock data: unused by this story
- Every archive and payload is deterministic, synthetic, legal test material
- Archive limits are 32 entries, 131,072 bytes per entry, and a 20:1 expansion ratio
- Central-directory safety validation runs before any archive entry is extracted
- Source checksums and writes outside the isolated extraction root are observed by read-only probes

## An escaping archive path is rejected before extraction with safe next actions

![An escaping archive path is rejected before extraction with safe next actions](./screenshots/ios/000-traversal-rejected.png)

**Verifications:**

- [x] The error identifies an unsafe path without exposing raw archive internals
- [x] No entry was extracted, the source is unchanged, and nothing escaped staging
- [x] The listener can choose a different archive
- [x] The listener can cancel safely
- [x] An unchanged path-traversal archive is not offered a meaningless retry

## Retrying a temporary inspection failure produces one safe reviewable book

![Retrying a temporary inspection failure produces one safe reviewable book](./screenshots/ios/001-retry-ready.png)

**Verifications:**

- [x] Both safe archive tracks form one warning-free proposal
- [x] Retry retains source integrity and never writes outside extraction staging
- [x] The safe proposal can continue

---

# Test: Import recovery keeps every source safe and makes storage actionable

> As a listener importing a messy selection, I want Bookshelf to explain each problem, preserve the usable files, and show exactly what storage I can safely reclaim.

## Deterministic preconditions

- Fixture: `import-recovery-storage`
- Xcode: 26.6
- Device: iPhone 17 on iOS 26.5, portrait, light appearance, standard Dynamic Type
- Locale and time zone: `en_CA`, `America/Toronto`
- Status bar: fixed at 9:41 AM, full battery, and full network indicators
- Animations: disabled by the E2E build configuration
- Network and clock data: unused by this story
- All filenames, checksums, byte counts, and library records are deterministic synthetic fixtures
- The low-space preflight requires 8,700 bytes with 8,192 available until 768 bytes of orphan staging is cleared
- The mixed selection contains valid, transiently corrupt, unsupported, selection-duplicate, and library-duplicate files
- Every source checksum is observed before and after production retry, remove, cancel, and commit boundaries

## Settings shows what Bookshelf uses and what can be reclaimed safely

![Settings shows what Bookshelf uses and what can be reclaimed safely](./screenshots/ios/002-storage-recovery.png)

**Verifications:**

- [x] Managed, staging, trash, database, available, and reclaimable bytes are exact
- [x] Per-book managed usage is visible without exposing private metadata
- [x] Recoverable orphan staging has an explicit cleanup action
- [x] Managed book media cannot be cleared from the recoverable-storage surface
- [x] The library database cannot be cleared from the recoverable-storage surface
