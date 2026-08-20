# Test: Backup and restore preserves a complete listening library safely

> As a listener, I want a portable backup and a trustworthy recovery path so my books, listening context, organization, and preferences survive a reset or damaged database.

## Deterministic preconditions

- Fixture: `synthetic-backup-restore`
- Xcode: 26.6
- Device: iPhone 17 on iOS 26.5, portrait, light appearance, standard Dynamic Type
- Locale and time zone: `en_CA`, `America/Toronto`
- Status bar: fixed at 9:41 AM, full battery, and full network indicators
- Animations: disabled by the E2E build configuration
- Network and wall-clock data: unused by this story
- Two books, two generated managed M4Bs, progress, one bookmark, one collection, and listening preferences are deterministic invented data
- Metadata-only, media-inclusive, tampered, traversal, and too-new packages are legal generated format-1/library-schema-14 fixtures covered by one SHA-256 manifest
- Package and managed-media checksums are verified programmatically without showing filesystem paths or hash values in screenshots

## Restore review explains exactly what will replace the empty library

Screenshot pending semantic-green guarded recording: `000-restore-review.png`.

**Verifications:**

- [ ] The review identifies an including-media format-1, reader-1, library-schema-14 package
- [ ] Exact book, asset, bookmark, collection, media-file, and byte counts are visible
- [ ] Replace Library is explicit and requires confirmation
- [ ] The package is validated before any current library record or managed file changes

## Programmatic-only recovery evidence

- [ ] Metadata-only export contains no media while its manifest and library payload validate
- [ ] Media-inclusive export contains both managed files and exact source checksums
- [ ] Clearing the fixture library leaves no book, asset, bookmark, collection, or managed-media record
- [ ] Restore returns exact IDs, metadata, progress, finished state, bookmark note, collection order, Up Next order, current book, and preferences
- [ ] Restored managed-media checksums match the pre-export source checksums
- [ ] Tampered, path-traversal, and too-new-schema packages are rejected without changing the restored library or their source bytes
- [ ] A damaged primary database is recovered from one production-created automatic backup
- [ ] Erase resets automatic backups to generation 0; successful restore creates generation 1, and hostile attempts, relaunch, and recovery do not rotate it
