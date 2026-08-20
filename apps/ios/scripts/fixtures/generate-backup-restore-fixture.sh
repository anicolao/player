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
  echo "usage: generate-backup-restore-fixture.sh EXISTING_OUTPUT_DIRECTORY" >&2
  exit 2
fi
if ! (cd "${fixture_root}" && shasum -a 256 -c SyntheticFormats.sha256 >/dev/null 2>&1); then
  echo "source synthetic format fixture is unavailable" >&2
  exit 2
fi

output_root="$(cd "${output_root}" && pwd -P)"
fixture_name="SyntheticBackupRestore"
fixture_dir="${output_root}/${fixture_name}"
manifest="${output_root}/${fixture_name}.sha256"
if [[ -e "${fixture_dir}" || -L "${fixture_dir}" || -e "${manifest}" || -L "${manifest}" ]]; then
  echo "backup/restore fixture output already exists" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-backup-restore.XXXXXX")"
cleanup() { rm -rf "${work_dir}"; }
trap cleanup EXIT
mkdir -p "${work_dir}/${fixture_name}"

cp "${script_dir}/synthetic-backup-restore-fixture.json" \
  "${work_dir}/${fixture_name}/synthetic-backup-restore-fixture.json"
cp "${fixture_root}/SyntheticFormats/M4B/synthetic-single-book.m4b" \
  "${work_dir}/${fixture_name}/backup-restore-audio.m4b"

generator="${script_dir}/generate-backup-restore-fixtures.swift"
descriptor="${work_dir}/${fixture_name}/synthetic-backup-restore-fixture.json"
audio="${work_dir}/${fixture_name}/backup-restore-audio.m4b"
xcrun swift "${generator}" metadata \
  "${work_dir}/${fixture_name}/known-good-metadata.playerbackup" "${descriptor}" "${audio}"
xcrun swift "${generator}" media \
  "${work_dir}/${fixture_name}/known-good-media.playerbackup" "${descriptor}" "${audio}"
xcrun swift "${generator}" tampered \
  "${work_dir}/${fixture_name}/tampered-media.playerbackup" "${descriptor}" "${audio}"
xcrun swift "${generator}" traversal \
  "${work_dir}/${fixture_name}/path-traversal.playerbackup" "${descriptor}" "${audio}"
xcrun swift "${generator}" too-new \
  "${work_dir}/${fixture_name}/too-new-schema.playerbackup" "${descriptor}" "${audio}"

(
  cd "${work_dir}"
  find "${fixture_name}" -type f -print0 | sort -z \
    | while IFS= read -r -d '' fixture_file; do shasum -a 256 "${fixture_file}"; done \
    > "${fixture_name}.sha256"
)
mv "${work_dir}/${fixture_name}" "${fixture_dir}"
mv "${work_dir}/${fixture_name}.sha256" "${manifest}"
echo "Generated deterministic synthetic backup/restore fixtures."
