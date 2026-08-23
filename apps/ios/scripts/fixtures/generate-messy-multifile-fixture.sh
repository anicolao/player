#!/usr/bin/env bash
set -euo pipefail
set +x

export LC_ALL=C
export TZ=UTC

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
source_root="${ios_dir}/PlayerUITests/Fixtures"
output_root="${1:-}"

if [[ -z "${output_root}" || ! -d "${output_root}" ]]; then
  echo "usage: generate-messy-multifile-fixture.sh EXISTING_OUTPUT_DIRECTORY" >&2
  exit 2
fi
if ! (cd "${source_root}" && shasum -a 256 -c SyntheticAudiobook.sha256 >/dev/null 2>&1); then
  echo "source synthetic audiobook fixture is unavailable" >&2
  exit 2
fi

output_root="$(cd "${output_root}" && pwd -P)"
fixture_name="SyntheticMessyMultifile"
fixture_dir="${output_root}/${fixture_name}"
manifest="${output_root}/${fixture_name}.sha256"
if [[ -e "${fixture_dir}" || -L "${fixture_dir}" || -e "${manifest}" || -L "${manifest}" ]]; then
  echo "messy multifile fixture output already exists" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-messy-multifile.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

folder_selection="${work_dir}/${fixture_name}/Selections/Signal Δ — Folder"
loose_selection="${work_dir}/${fixture_name}/Selections/Loose Files"
mkdir -p "${folder_selection}" "${loose_selection}"

make_asset() {
  local base_name="$1"
  local destination="$2"
  local token="$3"
  cp "${source_root}/SyntheticAudiobook/${base_name}" "${destination}"
  xcrun swift "${script_dir}/append-mp4-free-box.swift" "${destination}" "${token}"
}

make_asset "01-opening-tone.m4a" \
  "${folder_selection}/Signal Δ — Part 1.m4a" "asset-a1"
make_asset "02-middle-tone.m4a" \
  "${folder_selection}/Signal Δ — Part 2.m4a" "asset-a2"
make_asset "03-closing-tone.m4a" \
  "${folder_selection}/Signal Δ — Part 10.m4a" "asset-a10"
make_asset "01-opening-tone.m4a" \
  "${folder_selection}/Prélude – été.m4a" "asset-prelude"

make_asset "03-closing-tone.m4a" \
  "${loose_selection}/L’Écho — piste 3.m4a" "asset-b3"
make_asset "01-opening-tone.m4a" \
  "${loose_selection}/L’Écho — piste 4 – café.m4a" "asset-b4"
make_asset "02-middle-tone.m4a" \
  "${loose_selection}/L’Écho — piste 5.m4a" "asset-b5"
make_asset "03-closing-tone.m4a" \
  "${loose_selection}/L’Écho — piste 6 – fin.m4a" "asset-b6"

cp "${script_dir}/messy-multifile-fixture.json" \
  "${work_dir}/${fixture_name}/fixture.json"

(
  cd "${work_dir}"
  find "${fixture_name}" -type f -print0 \
    | sort -z \
    | while IFS= read -r -d '' fixture_file; do
        shasum -a 256 "${fixture_file}"
      done > "${fixture_name}.sha256"
)

mv "${work_dir}/${fixture_name}" "${fixture_dir}"
mv "${work_dir}/${fixture_name}.sha256" "${manifest}"
echo "Generated deterministic messy multifile and Unicode fixture."
