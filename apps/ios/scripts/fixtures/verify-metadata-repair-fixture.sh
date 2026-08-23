#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
fixture_dir="${fixture_root}/SyntheticMetadataRepair"
manifest="SyntheticMetadataRepair.sha256"

if [[ ! -f "${fixture_root}/${manifest}" ]] \
  || ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1); then
  echo "metadata-repair fixture checksum mismatch" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-metadata-repair-reproduction.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT
"${script_dir}/generate-metadata-repair-fixture.sh" "${work_dir}" >/dev/null
if ! diff -rq "${fixture_dir}" "${work_dir}/SyntheticMetadataRepair" >/dev/null 2>&1 \
  || ! cmp -s "${fixture_root}/${manifest}" \
    "${work_dir}/${manifest}"; then
  echo "metadata-repair fixture differs from clean reproduction" >&2
  exit 2
fi

if ! afinfo -r "${fixture_dir}/metadata-repair-source.m4b" >/dev/null 2>&1; then
  echo "metadata-repair fixture audio is unreadable" >&2
  exit 2
fi
for cover in metadata-repair-original-cover.png metadata-repair-replacement-cover.png; do
  dimensions="$(sips -g format -g pixelWidth -g pixelHeight "${fixture_dir}/${cover}" 2>/dev/null)"
  if ! grep -q 'format: png' <<<"${dimensions}" \
    || ! grep -q 'pixelWidth: 32' <<<"${dimensions}" \
    || ! grep -q 'pixelHeight: 32' <<<"${dimensions}"; then
    echo "metadata-repair cover is not the expected deterministic PNG" >&2
    exit 2
  fi
done
if cmp -s "${fixture_dir}/metadata-repair-original-cover.png" \
  "${fixture_dir}/metadata-repair-replacement-cover.png"; then
  echo "metadata-repair covers must be visibly distinct" >&2
  exit 2
fi
xcrun swift "${script_dir}/validate-metadata-repair-fixture.swift" \
  "${fixture_dir}/synthetic-metadata-repair-fixture.json"

echo "Metadata-repair fixture is reproducible, readable, and structurally valid."
