# Direct Import Alternatives

Status: design proposal
Last updated: 2026-08-23

## Decision summary

The architecture considers three complementary direct-import routes, all
feeding the existing durable import pipeline:

1. **Receive from Computer**, a local web uploader hosted by Player while the
   app is open, is the primary global experience for Mac, Windows, and Linux.
2. **Player Import Drop Box**, a deferred Finder/Apple Devices file-sharing
   route for large wired transfers and imports that should be waiting the next
   time Player opens.
3. **Drag directly onto Player through iPhone Mirroring** as an optional shortcut
   advertised on the receiver screen only in regions where Apple makes iPhone
   Mirroring available.

An optional Mac companion can later reduce discovery and pairing to one Finder
action. A hosted encrypted relay is the only route that can reliably begin with
Player closed and the phone away from the computer, but it adds a service,
accounts, privacy obligations, and temporary remote storage. It should not be
the first implementation.

Every direct route should automatically add valid books to the Library. The
Inbox should be used only for unsafe, unreadable, or genuinely ambiguous input,
not as a mandatory second confirmation step.

The exact discovery, screen copy, user actions, and locale-gated Mirroring tip
are specified in [DIRECT_IMPORT_UX.md](DIRECT_IMPORT_UX.md).

## Goal

A listener who has audiobook files on a computer performs one import action --
normally dragging a file or folder -- and the resulting book or books appear in
Player's Library. The listener does not copy the same files again in Files, tap
Add on every valid import, or clean up transport copies afterward.

Supported input shapes are:

- one `.m4b`, `.m4a`, or `.mp3` book;
- one directory containing the tracks for a book;
- a directory tree containing multiple books;
- one ZIP containing one or more books; and
- a flat multi-file selection when the transport supports it.

"No extra copies" means that after a successful import the phone contains one
canonical app-managed copy of each audio asset. The user's source library on the
computer remains untouched. Temporary partial uploads, ZIP archives, extracted
workspaces, Share Extension handoffs, and drop-box items are removed after the
managed copy and library transaction are durable.

## Product constraints

### What is possible

- An active iOS app can accept drag-and-drop item providers, host a local
  `NWListener`, advertise it with Bonjour, and stream uploads directly into its
  sandbox.
- Finder on macOS and Apple Devices on Windows can copy files into an app that
  enables iOS file sharing. Apple documents this as dragging files onto the app
  in the connected device's Files view.
- A user can grant persistent access to a directory selected with the document
  picker. Player can store the security-scoped bookmark and scan new contents on
  later launches.
- A background `URLSession` can continue downloads from an HTTP server even if
  the app is suspended and can relaunch the app after a system termination.
  This makes a hosted pull model possible.

### What is not possible to promise

- Player cannot install a Shortcut or personal automation without the user's
  participation.
- Player cannot register itself as a silent catch-all for every AirDrop. AirDrop
  decides where received items go, and a Share Extension runs only after the
  user chooses it.
- A normal iOS app cannot remain an always-on inbound web server while
  suspended. iOS normally suspends background apps, and the existing audio
  background mode is not permission to run a file server.
- An iPhone app cannot make Safari spontaneously open a page on a Mac. Handoff
  can advertise the receiver page, but the listener still chooses the Handoff
  activity. A Mac companion can make discovery automatic.
- Exposing Player's private `Application Support/Media` directory for direct
  writes would bypass validation and database transactions. Only a dedicated
  ingress drop box should ever be externally writable.

The unavoidable tradeoff is therefore:

- **Local and private:** Player must be active to receive immediately, or it
  processes a system file-sharing drop the next time it launches.
- **Phone may be closed or remote:** use an Internet relay and background pull,
  accepting the service and temporary remote-storage costs.

## Current foundation

Player already has the import core. Build 14 includes the direct transport,
single-storage receiver ingestion, resumable web uploads, and the physically
verified iPhone Mirroring provider path:

- The document picker accepts M4B, M4A, MP3, ZIP, folders, and multiple items.
- registered document types route single audio files and ZIPs through
  `onOpenURL`;
- the Share Extension copies supported attachments into an atomic App Group
  handoff;
- document-open, Files selection, AirDrop-marked requests, and Share Extension
  requests converge on `PlayerModel.enqueueImport`;
- acquisition writes checksummed files to `Staging/<job-id>`;
- commit atomically moves staged audio to immutable
  `Media/<book-id>/<asset-id>.<extension>`; and
- cancellation and Inbox abandonment clean app-owned staging; and
- a paired local web receiver now auto-commits warning-free imports while
  routing ambiguous imports to Inbox; and
- the receiver screen now accepts native Mirroring item providers, recursively
  preserves folder trees, rejects unsafe entries, supports cancellation, and
  cleans its transport session after the real importer adopts the media.

The app currently has `LSSupportsOpeningDocumentsInPlace` set to `false` and
does not enable `UIFileSharingEnabled`, so the wired drop-box alternative is
still future work. The web receiver reuses the analyzer, safe ZIP extractor,
grouping, metadata evidence, and managed media store rather than creating a
second importer.

Build 14 preserves partial files while the receiver session remains active,
reports a durable byte offset for every selected file, and accepts only a retry
that begins at the server-confirmed offset. Temporary connection failures leave
the selection in a retryable browser state; explicit cancellation removes the
partial session. The browser and phone both offer a deliberate “another book”
path after completion, so repeated imports do not require restarting Player.

## Common direct-import contract

All alternatives should produce the same sealed transfer manifest:

```text
DirectImportSession
├── id
├── route                       mirror-drop | web | drop-box | ...
├── createdAt
├── sourceDisplayName
├── entries[]
│   ├── relativePath           path within the selected tree
│   ├── byteCount
│   ├── contentType
│   └── sha256
├── state                      receiving | sealed | importing | complete | failed
└── cleanupOwnership           app-owned | external-read-only
```

The manifest is the boundary between transport and import. An entry is not
visible to the analyzer until all bytes have arrived, its size and checksum
match, and the manifest has been atomically sealed. A crash before sealing
leaves a resumable or disposable transfer, never a half-book proposal.

Directory transports send paths, not a client-created ZIP. That preserves the
tree, avoids compression work, and avoids the archive-plus-extracted peak-space
penalty. ZIPs supplied by the user still pass through the existing safe ZIP
extractor.

### Automatic grouping and commit

Direct import should introduce an `automatic` review policy:

1. Acquire and seal the whole top-level selection.
2. Inspect and group the complete selection.
3. Commit every valid proposal automatically.
4. Show committed books immediately in Library and a nonblocking success
   notification such as `Added 3 books`.
5. Put only blocked items in Inbox.

Warnings must be classified rather than treating every uncertainty as a stop:

| Classification | Examples | Direct-import behavior |
| --- | --- | --- |
| Blocking safety | unsafe ZIP path, symlink, unsupported file, unreadable bytes | Do not commit; retain an actionable failure or discard unsafe extracted bytes |
| Blocking identity | files cannot be divided into books without likely data loss | Keep that group in Inbox; continue committing independent valid groups |
| Nonblocking metadata | missing author, generic cover, weak title provenance | Commit with a Library warning badge; allow later editing |
| Nonblocking order | deterministic natural order but weak track tags | Commit in deterministic order and retain provenance; allow later reordering |

This changes the default from "review, then add" to "add, then optionally
repair" for direct routes. The existing reviewed Files flow can retain its
current behavior if desired, or Settings can expose one global
`Automatically add valid imports` preference, defaulting on.

### Exactly-once behavior

- A sealed manifest has a stable receipt ID and payload fingerprint.
- Replaying the same receipt returns its original result and cleans the replay;
  it does not create another book.
- A different receipt containing media already present in the active Library is
  a successful no-op by default and reports `Already in Library`.
- Trash is not treated as an active duplicate. This preserves the ability to
  trash a book and exercise the complete import path again.
- A directory-tree import commits valid books independently. One bad book does
  not roll back unrelated books, but each individual book remains atomic.

### Cleanup contract

After a successful import:

```text
computer source                         retained, never modified
transport partials                     absent
app-owned drop-box source              absent
Share Extension handoff                absent
ZIP source in app staging              absent
ZIP extraction workspace               absent
Staging/<job-id>                        absent
Media/<book-id>/<asset-id>.<extension>  present exactly once
durable receipt                         present, small metadata only
```

An app-owned source may be deleted only after the media move and persisted
Library record both succeed. External watched folders are read-only by default
and are never cleaned by Player. Failed transfers retain only bytes needed for
Retry and are subject to a visible expiry policy, for example automatic cleanup
after seven days.

## Optional route: drag through iPhone Mirroring

### Experience

1. The listener opens Player in iPhone Mirroring.
2. They drag a book folder, a directory tree, a ZIP, or audio files from Finder
   onto the Player window.
3. Player shows upload/import progress and adds valid books automatically.

After iPhone Mirroring has been configured, the recurring import gesture is one
drag. Apple explicitly supports dragging files from a Mac into supported iPhone
apps through iPhone Mirroring.

### Implementation

- The `Receive from Computer` screen installs a full-window UIKit
  `UIDropInteraction` on the active app window, backed by raw
  `NSItemProvider` objects.
- It accepts audio types, ZIPs, file URLs, and folder representations.
- `MirroringDropAdapter` starts every provider request synchronously inside
  `UIDropInteraction.performDrop`, retains the cross-device drop session while
  Finder materializes it, tries URL/in-place/temporary representations, and
  owns safe recursive traversal, path preservation, cancellation, and cleanup.
- It exposes only a fully materialized selection after every provider has
  completed, then feeds that selection to the same automatic importer as the
  web receiver.

### Advantages

- Best Mac experience: no URL, pairing code, cable view, cloud quota, or server.
- Uses an Apple-owned encrypted device-continuity channel.
- The app is necessarily active, so progress and errors are visible.
- No transport copy remains after staged files become managed media.

### Limitations and validation needed

- Requires a compatible Mac, iOS 18 or later, macOS 15 or later, the same Apple
  Account, proximity, and a region where iPhone Mirroring is available.
- Folder representations and very large directory trees must be proven on real
  hardware; Apple documents file drag broadly but not Player's exact folder
  provider behavior. If a folder is not vended as a readable provider, ZIP
  remains the fallback for this route.
- It is not a Windows or Linux solution.

### Recommendation

Prototype alongside the receiver because the code is small and the resulting
Mac UX is excellent. Present it as a conditional shortcut on `Receive from
Computer`, never as the global primary route. Hide the suggestion in the EU and
when regional eligibility is unknown. Do not make it a release dependency until
real-device tests prove folder and large-file behavior.

## Primary route: local Receive from Computer web page

### Experience

1. In Player, the listener taps `Receive from Computer` and leaves that screen
   open.
2. On the computer, they open the shown local address. Handoff can offer the
   same page on a nearby Mac to avoid typing it.
3. They drag a folder tree, one book, files, or a ZIP onto the page.
4. The web page and phone show the same progress; valid books appear in Library
   without another phone action.

The session setup is one phone action, and every import during that session is
one desktop drag.

### Implementation

- Use `NWListener` to host a small HTTP service and advertise
  `_player-import._tcp` over Bonjour.
- Add `NSLocalNetworkUsageDescription` and the Bonjour service declaration to
  the main app. The first use causes Apple's Local Network permission prompt.
- Serve a bundled, offline HTML/JavaScript application. No CDN or Internet
  connection should be required.
- Use browser directory APIs and drag entries to create a relative-path
  manifest. Do not ZIP a directory in JavaScript.
- Upload bounded chunks with session ID, file ID, offset, size, and checksum so
  an interrupted connection can resume without restarting a multi-gigabyte
  book.
- Write chunks to an app-owned `.partial` area, synchronize them, verify the
  checksum, atomically rename them, and seal the manifest.
- Keep the screen awake while receiving. If the app leaves the foreground,
  pause cleanly and let the browser reconnect when the receiver resumes. Newer
  OS background-processing APIs may extend an already user-started transfer,
  but the product must not promise an always-on listener.

### Discovery

Offer all of the following:

- a stable-looking mDNS host label plus port;
- a copyable numeric-IP fallback;
- a QR code for non-Mac clients; and
- an eligible `NSUserActivity` whose HTTP URL can be continued through Handoff.

Handoff reduces discovery to choosing the Safari activity; it cannot
automatically launch Safari on the Mac.

In regions where iPhone Mirroring is available, the same receiver screen also
shows a concise `Using a Mac?` card explaining that books can be dragged directly
onto the mirrored Player window. Eligibility comes from a remotely maintainable
regional allowlist with a shipped EU denylist; unknown regions fail closed and
hide the card. Player must not request location permission for this tip, and the
web instructions remain visually primary when it is shown.

### Security

- The receiver is off by default and expires after inactivity.
- Bind only to local/peer-to-peer interfaces, not cellular or a public server.
- Generate a high-entropy per-session bearer token and limit concurrent
  connections, request sizes, entry counts, and paths.
- Reject traversal, absolute paths, control characters, symlinks, and duplicate
  relative paths before writing.
- Show the connected sender and provide an immediate Stop action.
- A token protects against unsolicited uploads but plain local HTTP does not
  protect content from passive network observation. Before shipping broadly,
  choose one of:
  - document the trusted-LAN threat model for the first release;
  - add browser-side encryption with a phone-displayed pairing secret; or
  - use a companion client with authenticated TLS for the strongest local mode.

### Advantages

- Works from Mac, Windows, Linux, and Chromebooks without installing software.
- Handles complete directory trees and large files with a purpose-built,
  resumable protocol.
- Streams directly into Player-owned staging and leaves no transport copy.

### Limitations

- Player must be active to advertise and accept the connection reliably.
- The first Local Network permission prompt is unavoidable.
- Browser security and local-address discovery need careful UX and real-network
  testing, including guest Wi-Fi, VPNs, IPv6-only networks, and client isolation.

### Recommendation

This is the primary global route and the first transport implemented after the
common coordinator. All product discovery and onboarding should work without
iPhone Mirroring.

## Route: Finder/Apple Devices Import Drop Box

### Experience

1. During one-time device pairing, the listener opens their iPhone's Files view
   in Finder on Mac or Apple Devices on Windows.
2. They drag a file, ZIP, book folder, or directory tree onto Player's
   `Import Drop Box`.
3. If Player is open, it imports after the copy settles. Otherwise, it imports
   automatically the next time it opens.
4. The drop box becomes empty after successful commit.

The recurring import is one computer-side drag and requires no Files action on
the iPhone. Finder supports transfer over a cable and, when device Wi-Fi syncing
is configured, over Wi-Fi.

### Implementation

- Enable `UIFileSharingEnabled`.
- Consider setting `LSSupportsOpeningDocumentsInPlace` to `true` so the local
  Documents area is also visible through Files. This changes the current value
  and needs regression testing for document-open behavior.
- Create only `Documents/Import Drop Box`; keep Library data and managed media
  in private Application Support.
- Scan the drop box at restore, scene activation, and while Player is active.
- Treat uncontrolled Finder copies as unsealed until two recursive snapshots of
  path, size, and modification date are stable and a coordinated read confirms
  the same snapshot after hashing.
- Claim stable app-owned inputs by atomic rename into Staging where possible,
  avoiding a second full copy on the phone.
- On commit, remove the claimed drop item. On failure, retain it in managed
  staging for Retry rather than copying it back.

### Advantages

- Official system transport with excellent throughput and no local web security
  surface.
- Works with Player closed; processing waits safely for the next launch.
- A cable is dependable for very large libraries and constrained Wi-Fi.
- After claim and commit, only managed media remains on the phone.

### Limitations

- Initial Finder/Apple Devices discovery is less obvious than a web page.
- The system does not launch Player merely because Finder copied a file. The
  result appears when Player next runs unless it was already active.
- Folder-tree behavior should be hardware-tested on both Finder and Apple
  Devices; ZIP is a reliable fallback if a client flattens or rejects folders.
- Exposing Documents means users can see and delete drop-box content. That is
  acceptable because it is ingress, but managed media must never be placed
  there.

### Recommendation

Ship as the reliable large-transfer fallback. It is low complexity and directly
addresses connected-phone workflows.

## Route: AirDrop directly to Player

### Experience

The listener AirDrops a supported file from Finder to the iPhone. When iOS
offers Player as the destination, document-open starts import and auto-commit.
Items sent between devices on the same Apple Account are automatically accepted
by AirDrop, but Apple notes that received files may be saved in Files or another
app depending on type.

### Implementation improvements

- Keep the current document type registration for audio and ZIP.
- Route all document opens through direct-import auto-commit.
- Add explicit logging of whether the item arrived as document-open or through
  the Share Extension.
- Optionally define a custom `.playerimport` package for a future Mac helper so
  iOS has an unambiguous association. The package would be a manifest plus
  files, not a new media format.

### Why it is a fallback

- There is no public API for installing an automation that silently routes all
  AirDropped files to Player.
- A generic audio file or ZIP may land in Files or require choosing an app.
- Directories and large multi-file selections do not have a dependable
  app-targeting contract.
- The Share Extension itself must be selected by the user and has a constrained
  lifetime.

AirDrop should be made as good as the system permits, but it cannot be the only
answer to one-action directory-tree import.

## Route: watched external folder

### Experience

During setup, the listener chooses an `Audiobooks` or `Player Inbox` directory
from Files. It may be in iCloud Drive, Dropbox, another File Provider, or an SMB
server already connected in Files. Player saves the granted directory bookmark.
Thereafter, the listener places books in that directory from the computer and
Player imports unseen content when it can access the directory.

### Implementation

- Select `UTType.folder` with `UIDocumentPickerViewController` and persist the
  security-scoped bookmark.
- Use `NSFileCoordinator` for recursive reads, as Apple requires for content
  that another process or provider may change.
- Store a scan index of relative path, provider item identifier when available,
  size, modification date, and content fingerprint.
- Require stable snapshots before acquisition and rescan on launch/activation.
- Schedule opportunistic background refresh/processing, but never promise an
  immediate wake when the provider changes.
- Default to read-only. An explicit `Consume files from this drop folder`
  option may delete a source only after commit, and only for a folder the user
  designated as disposable ingress.

### Variants

- **iCloud Drive:** easiest Mac integration but consumes iCloud quota and may
  temporarily retain cloud and device-provider copies. It is unsuitable as the
  only route for users with limited iCloud storage.
- **SMB share on the computer/NAS:** Player reads the user's existing library
  without a cloud copy, but availability, credentials, and File Provider
  bookmark restoration vary.
- **Dropbox/OneDrive/etc.:** convenient for existing customers of those
  providers, but storage and download behavior are controlled by a third party.
- **On My iPhone/Player:** useful as a visible drop area, but the computer still
  needs Finder file sharing, iPhone Mirroring, or another transport to reach it.

### Recommendation

Implement after the web receiver and system drop box if users ask for ongoing
library sync.
It is a scan-on-availability feature, not a truly watched background folder on
iOS.

## Route: Mac companion and Finder action

### Experience

After one-time pairing, the listener drags a book onto a small Player Receiver
Mac app or chooses `Send to Player` in Finder. The companion discovers an active
phone over Bonjour and sends the directory manifest and bytes. No browser or
address is involved.

### Implementation

- Build a signed/notarized menu-bar or small windowed macOS app.
- Pair once with a short code and retain cryptographic keys in Keychain.
- Discover active phones with Bonjour and use an authenticated encrypted
  protocol over Network.framework.
- Reuse the local web receiver's sealed-manifest and resumable-chunk semantics.
- When the phone is unavailable, retain a security-scoped bookmark to the
  original Mac source rather than making a queued copy. Clearly report that the
  transfer is waiting for Player to open.
- Optionally add a Finder Quick Action. A Finder Sync extension is unnecessary
  unless deeper Finder integration is justified.

### Advantages

- Best repeat Mac workflow after pairing: one drag or contextual action.
- Strong authenticated encryption without browser certificate compromises.
- Bonjour discovery and retry can be invisible to the listener.
- Can preprocess a tree manifest without modifying or copying the source.

### Limitations

- Adds another shipped product, signing/notarization, update path, support
  matrix, and Windows gap.
- It still cannot wake an ordinary suspended iOS listener for an arbitrary large
  inbound transfer. It waits for Player to become active unless paired with a
  hosted relay.

### Recommendation

Build only after measuring demand for repeated desktop imports. Design the local
web protocol so this client can reuse it.

## Route: hosted encrypted upload relay

### Experience

The listener pairs Player with a web page once. Later they drag a directory onto
that page from any computer, even when the phone is elsewhere or Player is
closed. The service notifies the phone; Player downloads, imports, and deletes
the remote payload after a durable receipt.

### Implementation

- Encrypt files in the browser with a device-held key before upload.
- Store only ciphertext in object storage with a short mandatory TTL.
- Send APNs notification of the sealed remote manifest.
- Have Player schedule all files in one background `URLSession` so the system
  can continue downloads while the app is suspended and relaunch after a
  system termination.
- Verify end-to-end hashes, commit locally, acknowledge the receipt, and delete
  the remote object. A server-side expiry deletes abandoned uploads.
- Provide account recovery semantics that do not silently weaken end-to-end
  encryption.

### Advantages

- Only option that approaches "drag now, phone need not be active or nearby."
- Works across networks and operating systems.
- Background HTTP downloads are a system-supported transfer model.

### Limitations

- Silent push and background scheduling are best effort. If the user force-quits
  Player, iOS may require a later manual launch.
- Adds authentication, APNs, storage, abuse prevention, bandwidth bills,
  privacy disclosures, deletion audits, and operational support.
- Encrypted bytes exist temporarily off-device, which is a larger trust surface
  than local import even when plaintext never reaches the service.

### Recommendation

Defer until local routes are proven and remote import is a validated product
need.

## Route: Shortcuts and App Intents

Player can expose an `Import Audiobooks` App Intent accepting files and folders.
That makes Share Sheet, Siri, and user-created Shortcuts more convenient and can
support a Mac Finder Quick Action when combined with a real transport.

This is a convenience layer, not a transport:

- an iPhone Shortcut still requires the files to be reachable on the iPhone;
- a Mac Shortcut cannot directly write into a suspended iPhone app;
- a personal automation cannot be silently installed by Player; and
- AirDrop does not provide a general "run this intent for every received file"
  trigger that Player can configure.

Implement App Intents after the direct-import coordinator so they become one
more thin ingress adapter.

## Route: mount Player as WebDAV/SMB storage

An active Player could expose a WebDAV-like server that Finder mounts as a
volume. The listener would drag folders to a mounted `Player` drive.

This is technically possible over the same foreground local listener as the web
uploader, but it is not recommended initially:

- mounting and credential prompts are more work than opening a page;
- Finder WebDAV behavior and partial-write semantics require another large
  compatibility surface;
- the mount disappears when iOS suspends Player; and
- exposing filesystem semantics increases the risk of users mutating ingress
  while it is being processed.

The browser uploader gives the same directory-tree result with an explicit
transaction boundary and better progress/recovery.

## Approaches that do not solve the problem alone

### File Provider extension

A File Provider extension can present a Player-backed domain in Files, but it
does not make the phone's local sandbox appear on a Mac by itself. It needs a
sync service or another transport, at which point the hosted relay is the actual
solution. The complexity is not justified for local ingress.

### Writing directly to managed media

Neither Finder nor Files should write into `Media/`. A book is not valid merely
because bytes exist: Player also needs checksums, grouping, metadata, chapters,
and an atomic Library record. Direct writes would make crashes and partial
copies indistinguishable from valid books.

### Private USB device protocols

A custom desktop tool based on private MobileDevice/House Arrest APIs could
write to an app container, but it would be unsupported and fragile. Official
Finder/Apple Devices file sharing provides the supported USB path.

## Comparison

| Route | Recurring action | Tree support | Player active for receipt? | Extra remote copy | Platforms | Priority |
| --- | --- | --- | --- | --- | --- | --- |
| Local web receiver | Start receiver, then drag | Implemented; interruption recovery pending | Yes | No | Any modern desktop | Shipped P0 |
| Finder/Apple Devices drop box | One drag | Deferred; validate clients | No; imports next launch | No after cleanup | Mac/Windows | Post-MVP |
| iPhone Mirroring drop | One drag | Implemented; one Finder folder physically verified | Yes | No | Supported Mac regions | Shipped enhancement |
| AirDrop | Share/AirDrop | Weak for trees | Destination-dependent | No | Apple | Maintain as fallback |
| Watched provider folder | One drag after setup | Yes | Scans when scheduled/active | Provider-dependent | Provider-dependent | P2 |
| Mac companion | One drag after pairing | Yes | Yes unless queued | No | Mac | P2 |
| Hosted encrypted relay | One drag after pairing | Yes | No, best effort | Temporary ciphertext | Any | P3 |
| Shortcuts/App Intent | Share/run shortcut | Input-dependent | Usually | Transport-dependent | Apple | Adapter only |
| Mounted WebDAV | One drag after mount | Yes | Yes | No | Desktop | Do not prioritize |

## Recommended implementation plan

### Phase 0: direct-import semantics

1. Add `DirectImportSession`, sealed manifests, durable receipts, and cleanup
   ownership.
2. Add transport-neutral progress and cancellation.
3. Classify blocking versus nonblocking warnings.
4. Auto-commit valid proposals and surface nonblocking issues on committed
   books.
5. Add exactly-once and cleanup tests before adding a new transport.

### Phase 1: primary local web receiver

1. Implement the receiver state machine and hardened path validator.
2. Implement the offline web UI with directory traversal and resumable chunks.
3. Add Bonjour, Local Network permission UX, Handoff discovery, pairing, and
   session authentication.
4. Test large trees, interruption, app backgrounding, low storage, VPNs, guest
   Wi-Fi, IPv6, and concurrent senders.

### Phase 2: regional Mac shortcut and system drop box

1. **Implemented:** add the iOS drop target and hardened item-provider loader.
2. Add the remotely maintainable regional Mirroring-tip policy, default hidden
   for the EU and unknown eligibility.
3. Test single files, multifile selections, folders, directory trees, and ZIPs
   through iPhone Mirroring on physical devices in a supported region.
4. Enable file sharing and implement `Documents/Import Drop Box` settlement,
   claim, import, and cleanup.
5. Test Finder over USB and Wi-Fi plus Apple Devices on Windows.

### Phase 3: optional automation clients

1. Add App Intents and a documented Shortcut.
2. If usage supports it, build the paired Mac companion on the same protocol.
3. Consider a hosted encrypted relay only if importing while the phone is
   inactive and remote is important enough to justify operating a service.

## Acceptance criteria

Every shipped route must pass the same conformance suite:

- single M4B becomes one playable Library book;
- a flat multifile book retains every file and deterministic order;
- a selected book folder uses the book/album title, not the parent transport
  folder;
- a multi-book directory tree produces the correct number of books;
- a valid ZIP produces the same result as its uncompressed tree;
- unsafe ZIPs write nothing outside their workspace;
- interruption at every transfer and import stage resumes or fails actionably;
- replaying a receipt creates no duplicate;
- low storage is detected before an unrecoverable partial commit;
- valid books in a mixed batch commit even if another book is blocked;
- source files on the computer remain byte-identical;
- a successful import leaves no drop-box, handoff, archive, extraction, partial,
  or staging copy; and
- after relaunch, the Library record and every managed asset agree.

Hardware release gates should cover Finder USB, Finder Wi-Fi, and Apple Devices
for Windows. A route-specific gate covers iPhone Mirroring wherever Player
enables its regional promotion; Mirroring does not block the global web receiver
release. Simulator tests cannot validate Local Network privacy or the real
cross-device item-provider behavior.

## Relevant platform references

- [Apple: iPhone Mirroring and cross-device drag and drop](https://support.apple.com/en-us/120421)
- [Apple: Finder file sharing with iPhone and iPad](https://support.apple.com/en-gb/119585)
- [Apple: `UIFileSharingEnabled`](https://developer.apple.com/documentation/BundleResources/Information-Property-List/UIFileSharingEnabled)
- [Apple: persistent access to user-selected directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)
- [Apple: `LSSupportsOpeningDocumentsInPlace`](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html)
- [Apple: `NWListener` and Bonjour advertising](https://developer.apple.com/documentation/network/nwlistener)
- [Apple TN3179: Local Network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple: configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- [Apple: background URLSession downloads](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [Apple: `NSUserActivity` and Handoff](https://developer.apple.com/documentation/foundation/nsuseractivity)
- [Apple: Share Extension behavior](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html)
- [Apple: AirDrop receiving behavior](https://support.apple.com/en-lamr/guide/iphone/iphcd8b9f0af/ios)
