#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
fixture_dir="${fixture_root}/SyntheticLibrary"
manifest="SyntheticLibrary.sha256"
destination="${1:-}"

if [[ -z "${destination}" ]]; then
  echo "usage: stage-populated-library-fixture.sh NEW_DESTINATION_DIRECTORY" >&2
  exit 2
fi
if [[ -e "${destination}" || -L "${destination}" ]]; then
  echo "destination already exists" >&2
  exit 2
fi
if ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1); then
  echo "populated-library fixture checksum mismatch" >&2
  exit 2
fi
mkdir -p "$(dirname "${destination}")"
cp -R "${fixture_dir}" "${destination}"
if ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1) \
  || ! diff -rq "${fixture_dir}" "${destination}" >/dev/null 2>&1; then
  rm -rf "${destination}"
  echo "populated-library staging integrity check failed" >&2
  exit 2
fi
echo "Staged checksum-verified synthetic populated-library fixture."
