#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
fixture_dir="${fixture_root}/SyntheticImportChannels"
manifest="${fixture_root}/SyntheticImportChannels.sha256"
mode="${1:-}"
destination="${2:-}"

if [[ "${mode}" != "document" && "${mode}" != "share" ]] \
  || [[ -z "${destination}" ]]; then
  echo "usage: stage-import-channel-fixture.sh <document|share> NEW_DESTINATION" >&2
  exit 2
fi
if [[ -e "${destination}" || -L "${destination}" ]]; then
  echo "destination already exists" >&2
  exit 2
fi
if [[ ! -f "${manifest}" ]] \
  || ! (cd "${fixture_root}" && shasum -a 256 -c "$(basename "${manifest}")" >/dev/null 2>&1); then
  echo "import-channel fixture checksum mismatch" >&2
  exit 2
fi

if [[ "${mode}" == "document" ]]; then
  mkdir -p "$(dirname "${destination}")"
  cp "${fixture_dir}/document-open-interrupted-acquire.m4a" "${destination}"
  if [[ "$(shasum -a 256 "${destination}" | awk '{print $1}')" \
    != "9fe8b420c8d1f64d51f87a98a1465e7dea69082d74c1a014220f6838ba4aa60d" ]]; then
    rm -f "${destination}"
    echo "staged document fixture checksum mismatch" >&2
    exit 2
  fi
  if ! (cd "${fixture_root}" && shasum -a 256 -c "$(basename "${manifest}")" >/dev/null 2>&1); then
    rm -f "${destination}"
    echo "synthetic document source changed while staging" >&2
    exit 2
  fi
  echo "Staged checksum-verified synthetic document-open fixture."
  exit 0
fi

handoff_id="70000000-0000-0000-0000-000000000101"
queue_root="${destination}/ImportHandoffs"
incoming="${queue_root}/Incoming/${handoff_id}"
pending="${queue_root}/Pending/${handoff_id}"
mkdir -p "${incoming}/Items" "${queue_root}/Pending" "${queue_root}/Processing"
cp "${fixture_dir}/share-extension-handoff.m4a" "${incoming}/Items/00000.m4a"
cp "${fixture_dir}/share-extension-envelope.json" "${incoming}/handoff.json"
if [[ "$(shasum -a 256 "${incoming}/Items/00000.m4a" | awk '{print $1}')" \
  != "ec875798951295f4b5fdd1e9349a58fd94fbb7cb78455595345fcb3ca51d3964" ]]; then
  rm -rf "${destination}"
  echo "staged share payload checksum mismatch" >&2
  exit 2
fi
mv "${incoming}" "${pending}"
if ! (cd "${fixture_root}" && shasum -a 256 -c "$(basename "${manifest}")" >/dev/null 2>&1); then
  rm -rf "${destination}"
  echo "synthetic share source changed while staging" >&2
  exit 2
fi
echo "Staged atomic synthetic app-group share handoff."
