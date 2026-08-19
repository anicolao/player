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
  echo "usage: generate-zip-fixtures.sh EXISTING_OUTPUT_DIRECTORY" >&2
  exit 2
fi
if ! command -v zip >/dev/null 2>&1; then
  echo "the system zip tool is required" >&2
  exit 2
fi
if ! (cd "${source_root}" && shasum -a 256 -c SyntheticAudiobook.sha256 >/dev/null 2>&1); then
  echo "source synthetic audiobook fixture is unavailable" >&2
  exit 2
fi

output_root="$(cd "${output_root}" && pwd -P)"
fixture_name="SyntheticZIPs"
fixture_dir="${output_root}/${fixture_name}"
manifest="${output_root}/${fixture_name}.sha256"
if [[ -e "${fixture_dir}" || -L "${fixture_dir}" || -e "${manifest}" || -L "${manifest}" ]]; then
  echo "ZIP fixture output already exists" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-zip-fixtures.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT
mkdir "${work_dir}/${fixture_name}"

generator="${script_dir}/generate-zip-fixtures.swift"
xcrun swift "${generator}" valid \
  "${work_dir}/${fixture_name}/valid-multifile.zip" \
  "${source_root}/SyntheticAudiobook/01-opening-tone.m4a" \
  "${source_root}/SyntheticAudiobook/02-middle-tone.m4a"
xcrun swift "${generator}" traversal "${work_dir}/${fixture_name}/path-traversal.zip"
xcrun swift "${generator}" symlink "${work_dir}/${fixture_name}/symlink-escape.zip"
xcrun swift "${generator}" count "${work_dir}/${fixture_name}/count-limit.zip"
xcrun swift "${generator}" size "${work_dir}/${fixture_name}/size-limit.zip"

ratio_source="${work_dir}/ratio-source/Ratio Limit"
mkdir -p "${ratio_source}"
dd if=/dev/zero of="${ratio_source}/highly-compressible.bin" bs=1024 count=64 \
  >/dev/null 2>&1
touch -t 202401010000 "${ratio_source}/highly-compressible.bin"
(
  cd "${work_dir}/ratio-source"
  COPYFILE_DISABLE=1 zip -X -q -9 \
    "${work_dir}/${fixture_name}/ratio-limit.zip" \
    "Ratio Limit/highly-compressible.bin"
)

cp "${script_dir}/synthetic-zips-fixture.json" \
  "${work_dir}/${fixture_name}/synthetic-zips-fixture.json"
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
echo "Generated deterministic valid and hostile ZIP fixtures."
