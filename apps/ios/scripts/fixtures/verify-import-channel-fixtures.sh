#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
manifest="SyntheticImportChannels.sha256"

if [[ ! -f "${fixture_root}/${manifest}" ]] \
  || ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1); then
  echo "import-channel fixture checksum mismatch" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-import-channel-reproduction.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT
"${script_dir}/generate-import-channel-fixtures.sh" "${work_dir}" >/dev/null
if ! diff -rq "${fixture_root}/SyntheticImportChannels" \
  "${work_dir}/SyntheticImportChannels" >/dev/null 2>&1 \
  || ! cmp -s "${fixture_root}/${manifest}" \
    "${work_dir}/${manifest}"; then
  echo "import-channel fixtures differ from clean reproduction" >&2
  exit 2
fi

for audio_file in \
  document-open-interrupted-acquire.m4a \
  share-extension-handoff.m4a; do
  if ! afinfo -r "${fixture_root}/SyntheticImportChannels/${audio_file}" >/dev/null 2>&1; then
    echo "import-channel fixture contains unreadable audio" >&2
    exit 2
  fi
done

xcrun swift "${script_dir}/validate-import-channel-fixtures.swift" \
  "${fixture_root}/SyntheticImportChannels/synthetic-import-channels-fixture.json" \
  "${fixture_root}/SyntheticImportChannels/share-extension-envelope.json"
if ! grep -q '"byteCount": 9350' \
  "${fixture_root}/SyntheticImportChannels/synthetic-import-channels-fixture.json" \
  || ! grep -q '"byteCount": 9183' \
    "${fixture_root}/SyntheticImportChannels/share-extension-envelope.json" \
  || ! grep -q '"relativePath": "Items/00000.m4a"' \
    "${fixture_root}/SyntheticImportChannels/share-extension-envelope.json" \
  || ! grep -q '"checksumSHA256": "ec875798951295f4b5fdd1e9349a58fd94fbb7cb78455595345fcb3ca51d3964"' \
    "${fixture_root}/SyntheticImportChannels/share-extension-envelope.json"; then
  echo "import-channel neutral byte-count contract differs" >&2
  exit 2
fi

echo "Import-channel fixtures are reproducible, readable, and structurally valid."
