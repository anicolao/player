#!/usr/bin/env bash
set -euo pipefail
set +x

export LC_ALL=C
export TZ=UTC

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
fixture_dir="${fixture_root}/SyntheticBackupRestore"
manifest="SyntheticBackupRestore.sha256"

for tool in jq unzip shasum afinfo; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "${tool} is required to verify backup/restore fixtures" >&2
    exit 2
  fi
done
if [[ ! -f "${fixture_root}/${manifest}" ]] \
  || ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1); then
  echo "backup/restore fixture checksum mismatch" >&2
  exit 2
fi

before_hash="$(shasum -a 256 "${fixture_root}/${manifest}" | awk '{print $1}')"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-backup-restore-reproduction.XXXXXX")"
cleanup() { rm -rf "${work_dir}"; }
trap cleanup EXIT
"${script_dir}/generate-backup-restore-fixture.sh" "${work_dir}" >/dev/null
if ! diff -rq "${fixture_dir}" "${work_dir}/SyntheticBackupRestore" >/dev/null 2>&1 \
  || ! cmp -s "${fixture_root}/${manifest}" "${work_dir}/${manifest}"; then
  echo "backup/restore fixture differs from clean reproduction" >&2
  exit 2
fi

descriptor="${fixture_dir}/synthetic-backup-restore-fixture.json"
audio="${fixture_dir}/backup-restore-audio.m4b"
xcrun swift "${script_dir}/validate-backup-restore-fixture.swift" "${descriptor}"
if ! afinfo -r "${audio}" >/dev/null 2>&1; then
  echo "backup/restore fixture audio is unreadable" >&2
  exit 2
fi
audio_hash="$(shasum -a 256 "${audio}" | awk '{print $1}')"
descriptor_hash="$(shasum -a 256 "${descriptor}" | awk '{print $1}')"
if [[ "${audio_hash}" != "6c5a700ee340ace483b4cd45188403ca9a77fd60d94ba248063ee2c7fc6366f7" ]]; then
  echo "backup/restore fixture audio changed" >&2
  exit 2
fi

metadata_package="${fixture_dir}/known-good-metadata.playerbackup"
media_package="${fixture_dir}/known-good-media.playerbackup"
tampered_package="${fixture_dir}/tampered-media.playerbackup"
traversal_package="${fixture_dir}/path-traversal.playerbackup"
too_new_package="${fixture_dir}/too-new-schema.playerbackup"

metadata_entries="$(unzip -Z1 "${metadata_package}" | LC_ALL=C sort)"
if [[ "${metadata_entries}" != $'Library/Library.json\nmanifest.json' ]]; then
  echo "metadata-only package entries changed" >&2
  exit 2
fi
if [[ "$(unzip -p "${metadata_package}" manifest.json | jq -r '.identifier,.formatVersion,.minimumReaderVersion,.librarySchemaVersion,.policy.mode,.policy.includesArtwork,(.entries | length),([.entries[] | select(.kind == "media")] | length)')" \
  != $'com.spnss.player.portable-backup\n1\n1\n14\nmetadata-only\nfalse\n1\n0' ]]; then
  echo "metadata-only package contract changed" >&2
  exit 2
fi
for package in "${metadata_package}" "${media_package}"; do
  archived_library_hash="$(unzip -p "${package}" Library/Library.json | shasum -a 256 | awk '{print $1}')"
  declared_library_hash="$(unzip -p "${package}" manifest.json \
    | jq -r '.entries[] | select(.kind == "library-database") | .checksumSHA256')"
  if [[ "${archived_library_hash}" != "${descriptor_hash}" \
    || "${declared_library_hash}" != "${descriptor_hash}" ]]; then
    echo "portable backup library payload checksum contract changed" >&2
    exit 2
  fi
done

media_entries="$(unzip -Z1 "${media_package}" | LC_ALL=C sort)"
expected_media_entries=$'Library/Library.json\nMedia/a1000000-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000101.m4b\nMedia/a1000000-0000-0000-0000-000000000002/a1000000-0000-0000-0000-000000000102.m4b\nmanifest.json'
if [[ "${media_entries}" != "${expected_media_entries}" ]]; then
  echo "media-inclusive package entries changed" >&2
  exit 2
fi
if [[ "$(unzip -p "${media_package}" manifest.json | jq -r '.formatVersion,.librarySchemaVersion,.policy.mode,.policy.includesArtwork,(.entries | length),([.entries[] | select(.kind == "media")] | length),([.entries[] | select(.kind == "media") | .byteCount] | add),([.entries[] | select(.kind == "media") | .bookID + "@" + .assetID] | join(","))')" \
  != $'1\n14\nincluding-media\nfalse\n3\n2\n16922\na1000000-0000-0000-0000-000000000001@a1000000-0000-0000-0000-000000000101,a1000000-0000-0000-0000-000000000002@a1000000-0000-0000-0000-000000000102' ]]; then
  echo "media-inclusive package contract changed" >&2
  exit 2
fi
for asset_suffix in 101 102; do
  book_suffix=$((asset_suffix - 100))
  entry="Media/a1000000-0000-0000-0000-$(printf '%012d' "${book_suffix}")/a1000000-0000-0000-0000-$(printf '%012d' "${asset_suffix}").m4b"
  archived_hash="$(unzip -p "${media_package}" "${entry}" | shasum -a 256 | awk '{print $1}')"
  declared_hash="$(unzip -p "${media_package}" manifest.json \
    | jq -r --arg entry "${entry}" '.entries[] | select(.relativePath == $entry) | .checksumSHA256')"
  if [[ "${archived_hash}" != "${audio_hash}" || "${declared_hash}" != "${audio_hash}" ]]; then
    echo "media-inclusive package checksum contract changed" >&2
    exit 2
  fi
done

tampered_entry="Media/a1000000-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000101.m4b"
tampered_actual="$(unzip -p "${tampered_package}" "${tampered_entry}" | shasum -a 256 | awk '{print $1}')"
tampered_declared="$(unzip -p "${tampered_package}" manifest.json \
  | jq -r --arg entry "${tampered_entry}" '.entries[] | select(.relativePath == $entry) | .checksumSHA256')"
if [[ "${tampered_actual}" == "${tampered_declared}" || "${tampered_declared}" != "${audio_hash}" ]]; then
  echo "tampered package no longer contains one deliberate checksum mismatch" >&2
  exit 2
fi
if ! unzip -Z1 "${traversal_package}" | grep -Fxq '../Library.json'; then
  echo "path-traversal package no longer contains its hostile entry" >&2
  exit 2
fi
if [[ "$(unzip -p "${too_new_package}" manifest.json | jq -r '.librarySchemaVersion')" != "999" ]]; then
  echo "too-new schema package changed" >&2
  exit 2
fi

after_hash="$(shasum -a 256 "${fixture_root}/${manifest}" | awk '{print $1}')"
if [[ "${before_hash}" != "${after_hash}" ]]; then
  echo "verification modified the checked-in fixture manifest" >&2
  exit 2
fi
echo "Backup/restore fixtures are reproducible, readable, hostile as declared, and unchanged."
