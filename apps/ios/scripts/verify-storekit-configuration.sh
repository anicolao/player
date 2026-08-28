#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/.." && pwd)"
configuration="${ios_dir}/Player/StoreKit/Bookshelf.storekit"
project_spec="${ios_dir}/project.yml"
scheme="${ios_dir}/Player.xcodeproj/xcshareddata/xcschemes/Player.xcscheme"
product_id="com.spnss.player.fullunlock"

jq -e --arg product_id "${product_id}" '
  [
    .products[]
    | select(
        .productID == $product_id
        and .type == "NonConsumable"
        and .displayPrice == "9.99"
        and .familyShareable == true
      )
  ] | length == 1
' "${configuration}" >/dev/null

if [[ "$(jq -r --arg product_id "${product_id}" \
  '[.products[] | select(.productID == $product_id)] | length' \
  "${configuration}")" != "1" ]]; then
  echo "The Full Unlock product identifier must occur exactly once." >&2
  exit 1
fi

rg -q 'static let fullUnlockProductID = "com\.spnss\.player\.fullunlock"' \
  "${ios_dir}/Player/Core/Monetization.swift"
rg -q 'storeKitConfiguration: Player/StoreKit/Bookshelf\.storekit' "${project_spec}"
rg -q 'identifier = "\.\./\.\./Player/StoreKit/Bookshelf\.storekit"' "${scheme}"

if rg -n 'Bookshelf\.storekit in Resources' \
  "${ios_dir}/Player.xcodeproj/project.pbxproj"; then
  echo "The local StoreKit test configuration must not ship in the app bundle." >&2
  exit 1
fi

echo "StoreKit Full Unlock configuration passed."
