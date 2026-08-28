#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
cd "${repo_root}"

branding_matches="$({
  rg -n \
    --glob '*.swift' \
    --glob '*.plist' \
    --glob '*.html' \
    --glob '*.svelte' \
    --glob '*.js' \
    --glob '!Player/ReceiverWeb/assets/**' \
    '\bPlayer\b|Player’s|Player\.' \
    apps/ios/Player apps/ios/ShareExtension apps/ios/ReceiverWeb || true
})"

unexpected_matches="$(printf '%s\n' "${branding_matches}" | grep -Ev \
  'appending\(path: "Player"|X-Player-|authors: \["Player Test Lab"\]|outDir: '\''\.\./Player/ReceiverWeb'\''' || true)"

if [[ -n "${unexpected_matches}" ]]; then
  echo "User-facing Player branding remains in product source:" >&2
  printf '%s\n' "${unexpected_matches}" >&2
  exit 1
fi

if rg -n \
  'Connect to Player|Send audiobooks to Player|Sent to Player|>Player<|Player could|Player is checking|ready in Player|shown in Player' \
  apps/ios/Player/ReceiverWeb; then
  echo "The committed receiver web build contains stale Player branding." >&2
  exit 1
fi

rg -q 'Send audiobooks to Bookshelf' apps/ios/Player/ReceiverWeb/index.html
rg -q 'Connect to Bookshelf' apps/ios/Player/ReceiverWeb/assets/*.js
rg -q 'Sent to Bookshelf' apps/ios/Player/ReceiverWeb/assets/*.js

echo "Bookshelf branding inventory passed."
