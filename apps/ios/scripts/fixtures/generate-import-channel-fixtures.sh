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
  echo "usage: generate-import-channel-fixtures.sh EXISTING_OUTPUT_DIRECTORY" >&2
  exit 2
fi
if ! (cd "${fixture_root}" && shasum -a 256 -c SyntheticAudiobook.sha256 >/dev/null 2>&1); then
  echo "source synthetic audiobook fixture is unavailable" >&2
  exit 2
fi

output_root="$(cd "${output_root}" && pwd -P)"
fixture_name="SyntheticImportChannels"
fixture_dir="${output_root}/${fixture_name}"
manifest="${output_root}/${fixture_name}.sha256"
if [[ -e "${fixture_dir}" || -L "${fixture_dir}" || -e "${manifest}" || -L "${manifest}" ]]; then
  echo "import-channel fixture output already exists" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-import-channels.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

mkdir -p "${work_dir}/${fixture_name}"
cp "${fixture_root}/SyntheticAudiobook/01-opening-tone.m4a" \
  "${work_dir}/${fixture_name}/document-open-interrupted-acquire.m4a"
cp "${fixture_root}/SyntheticAudiobook/02-middle-tone.m4a" \
  "${work_dir}/${fixture_name}/share-extension-handoff.m4a"
cp "${script_dir}/synthetic-import-channels-fixture.json" \
  "${work_dir}/${fixture_name}/synthetic-import-channels-fixture.json"
cp "${script_dir}/share-extension-envelope.json" \
  "${work_dir}/${fixture_name}/share-extension-envelope.json"

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
echo "Generated deterministic document-open and share-handoff fixtures."
