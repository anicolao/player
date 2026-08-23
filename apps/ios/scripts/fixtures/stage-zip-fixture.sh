#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
manifest="${fixture_root}/SyntheticZIPs.sha256"

case "${1:-}" in
  valid) filename="valid-multifile.zip" ;;
  traversal) filename="path-traversal.zip" ;;
  symlink) filename="symlink-escape.zip" ;;
  ratio) filename="ratio-limit.zip" ;;
  count) filename="count-limit.zip" ;;
  size) filename="size-limit.zip" ;;
  *)
    echo "usage: stage-zip-fixture.sh <valid|traversal|symlink|ratio|count|size> NEW_DESTINATION.zip" >&2
    exit 2
    ;;
esac

destination="${2:-}"
if [[ -z "${destination}" || "${destination}" != /* ]]; then
  echo "destination must be a new absolute path" >&2
  exit 2
fi
destination_parent="$(dirname "${destination}")"
if [[ ! -d "${destination_parent}" || -e "${destination}" || -L "${destination}" ]]; then
  echo "destination parent must exist and destination must be new" >&2
  exit 2
fi
if ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1); then
  echo "ZIP fixture checksum mismatch" >&2
  exit 2
fi

source_file="${fixture_root}/SyntheticZIPs/${filename}"
cp "${source_file}" "${destination}"
source_digest="$(shasum -a 256 "${source_file}" | awk '{print $1}')"
destination_digest="$(shasum -a 256 "${destination}" | awk '{print $1}')"
if [[ "${source_digest}" != "${destination_digest}" ]]; then
  echo "staged ZIP fixture checksum mismatch" >&2
  exit 2
fi
echo "Staged checksum-verified synthetic ZIP fixture."
