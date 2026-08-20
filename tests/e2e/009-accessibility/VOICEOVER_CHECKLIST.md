# Manual VoiceOver audit checklist

Use only the Story 009 synthetic fixtures. Reset the fixture before each section.
Never open `books/`, attach a private screenshot, or include device speech logs
that contain private content.

## Setup

- [ ] iPhone 17 / iOS 26.5, portrait, `en_CA`, light appearance.
- [ ] Set text to the largest Accessibility size.
- [ ] Enable VoiceOver and Speech Hints; use touch exploration and left/right swipes.
- [ ] Repeat the display pass with Reduce Motion, Increase Contrast, and
  Differentiate Without Color enabled together.
- [ ] Confirm fixture title/author/filename speech only; stop if any local content appears.

## Import recovery

- [ ] Focus enters on `Review Import`, then summary, Selected files, and file rows.
- [ ] Each file is announced once with filename, disposition, explanation, and source safety.
- [ ] Actions rotor for the corrupt file orders Retry, Remove, Choose Another Selection.
- [ ] Activating Retry updates the row and moves focus to its ready confirmation.
- [ ] Remove explains it affects Player's staged copy, not the source.
- [ ] At AX5 every action remains reachable without overlapping or horizontal scrolling.

## Metadata repair

- [ ] Cover and section headings appear in the Headings rotor in visual order.
- [ ] Each field speaks name, current value, provenance/confidence, and lock once.
- [ ] Text fields remain editable and do not inherit the summary element's traits.
- [ ] Lock/unlock, clear narrators, replace/remove cover, and Save have unambiguous hints.
- [ ] After cover choice or editor dismissal, focus returns to the invoking control.

## Review Order

- [ ] Each row speaks one-based position, full Unicode filename, evidence, selection.
- [ ] Actions rotor omits impossible boundary moves and orders Select, Earlier, Later, Move to.
- [ ] Move Earlier works without drag-and-drop and focus stays on the moved track.
- [ ] Switch Control/full-keyboard traversal can reach visible reorder alternatives.
- [ ] Split/merge/save announcements include the resulting track/book counts.

## Now Playing

- [ ] Decorative artwork is skipped; title, author, chapter, and chapter count are not duplicated.
- [ ] Listening position speaks elapsed and total time.
- [ ] Adjustable swipe changes position by 30 seconds, clamps safely, and announces the result.
- [ ] Previous/next chapter disabled states are announced.
- [ ] Play/Pause, skip, bookmark, sleep timer, and playback settings follow visual order.
- [ ] With Reduce Motion, opening/closing and banners use no spatial/decorative motion.

## Bookmarks

- [ ] Chapters/Bookmarks selected state is announced and rotor order follows the cards.
- [ ] A row speaks label, time, chapter, and note once, including accented text correctly.
- [ ] Actions rotor orders Jump, Edit, Delete; visible buttons have bookmark-specific labels.
- [ ] Jump focuses its confirmation, Delete focuses Undo, and Undo focuses restored row.
- [ ] Search announces query/result count; sort announces selected order.

## Visual accommodations and sign-off

- [ ] Increased contrast keeps normal/secondary/disabled text and focus rings distinguishable.
- [ ] Warning, success, selected, playing, and disabled states retain text plus symbol/shape
  under Differentiate Without Color; cover the screen and confirm color is never required.
- [ ] No essential state is conveyed only by animation; reduced-motion state changes are immediate.
- [ ] Run the automated Story 009 selector and retain only its synthetic named evidence.
- [ ] Record auditor, device/OS, date, failed item IDs, and remediation notes; do not record speech.
