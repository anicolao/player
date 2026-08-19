#!/usr/bin/env bash
set -euo pipefail
set +x

export LC_ALL=C
export TZ=UTC

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
output_root="${1:-}"

if [[ -z "${output_root}" || ! -d "${output_root}" ]]; then
  echo "usage: generate-populated-library-fixture.sh EXISTING_OUTPUT_DIRECTORY" >&2
  exit 2
fi
if ! (cd "${fixture_root}" && shasum -a 256 -c SyntheticFormats.sha256 >/dev/null 2>&1); then
  echo "source synthetic format fixture is unavailable" >&2
  exit 2
fi

output_root="$(cd "${output_root}" && pwd -P)"
fixture_name="SyntheticLibrary"
fixture_dir="${output_root}/${fixture_name}"
manifest="${output_root}/${fixture_name}.sha256"
if [[ -e "${fixture_dir}" || -L "${fixture_dir}" || -e "${manifest}" || -L "${manifest}" ]]; then
  echo "populated-library fixture output already exists" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-library.XXXXXX")"
cleanup() { rm -rf "${work_dir}"; }
trap cleanup EXIT
mkdir -p "${work_dir}/${fixture_name}"

cp "${fixture_root}/SyntheticFormats/M4B/synthetic-single-book.m4b" \
  "${work_dir}/${fixture_name}/library-book-audio.m4b"
cp "${script_dir}/synthetic-populated-library-fixture.json" \
  "${work_dir}/${fixture_name}/synthetic-populated-library-fixture.json"
xcrun swift "${script_dir}/generate-populated-library-covers.swift" \
  "${work_dir}/${fixture_name}/library-cover-b1.png" \
  "${work_dir}/${fixture_name}/library-cover-b2.png" \
  "${work_dir}/${fixture_name}/library-cover-b3.png" \
  "${work_dir}/${fixture_name}/library-cover-b4.png" \
  "${work_dir}/${fixture_name}/library-cover-b5.png"

(
  cd "${work_dir}"
  find "${fixture_name}" -type f -print0 | sort -z \
    | while IFS= read -r -d '' fixture_file; do shasum -a 256 "${fixture_file}"; done \
    > "${fixture_name}.sha256"
)
mv "${work_dir}/${fixture_name}" "${fixture_dir}"
mv "${work_dir}/${fixture_name}.sha256" "${manifest}"
echo "Generated deterministic synthetic populated-library fixture."
