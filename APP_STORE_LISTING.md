# App Store listing

The canonical English (U.S.) metadata, screenshot storyboard, research, and
sync workflow now live in:

- `app-store/listing.json` — machine-readable listing source of truth
- `APP_STORE_LISTING_DESIGN.md` — generated, reviewable listing design
- `scripts/app-store-listing` — fresh screenshot generation and App Store
  Connect preview/apply workflow

The installed app name remains `Bookshelf`. Edit `app-store/listing.json`, then
run `scripts/app-store-listing prepare`; do not maintain a second copy of the
metadata here.
