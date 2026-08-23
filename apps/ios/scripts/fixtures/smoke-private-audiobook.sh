#!/usr/bin/env bash
set -euo pipefail
set +x

export LC_ALL=C

fail() {
  echo "$1" >&2
  exit 2
}

if [[ -z "${LOCAL_AUDIOBOOK_FIXTURE:-}" || ! -d "${LOCAL_AUDIOBOOK_FIXTURE}" ]]; then
  fail "LOCAL_AUDIOBOOK_FIXTURE must identify the private 30-part sample directory"
fi
if ! command -v afinfo >/dev/null 2>&1; then
  fail "Core Audio inspection is unavailable"
fi

source_root="$(cd "${LOCAL_AUDIOBOOK_FIXTURE}" 2>/dev/null && pwd -P)" \
  || fail "private fixture is unreadable"
if find "${source_root}" -type l -print -quit 2>/dev/null | read -r _; then
  fail "private fixture must not contain symbolic links"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-private-smoke.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT
chmod 700 "${work_dir}"

find "${source_root}" -type f -print0 2>/dev/null \
  | sort -z > "${work_dir}/files"

part_count=0
total_bytes=0
expected_album=""
expected_artist=""
: > "${work_dir}/durations"
: > "${work_dir}/source-before"

while IFS= read -r -d '' source_file; do
  if [[ "$(dirname "${source_file}")" != "${source_root}" ]]; then
    fail "private fixture must be one flat book directory"
  fi
  extension="${source_file##*.}"
  extension="$(printf '%s' "${extension}" | tr '[:upper:]' '[:lower:]')"
  if [[ "${extension}" != "mp3" || ! -s "${source_file}" ]]; then
    fail "private fixture must contain only non-empty MP3 parts"
  fi

  part_count=$((part_count + 1))
  if [[ "${part_count}" -gt 30 ]]; then
    fail "private fixture part count differs from the neutral contract"
  fi

  if ! afinfo -r -i "${source_file}" > "${work_dir}/media-info" 2>/dev/null; then
    fail "a private fixture part is not readable by Core Audio"
  fi
  if ! rg -q 'Data format:[[:space:]]+2 ch,[[:space:]]+44100 Hz,[[:space:]]+\.mp3' \
    "${work_dir}/media-info" \
    || ! rg -q 'bit rate:[[:space:]]+128000 bits per second' "${work_dir}/media-info"; then
    fail "private fixture audio format differs from the neutral contract"
  fi

  track_number="$(
    sed -n 's/^[[:space:]]*track number[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\/[0-9][0-9]*\)"[[:space:]]*$/\1/p' \
      "${work_dir}/media-info" | head -n 1
  )"
  if [[ "${track_number}" != "${part_count}/30" ]]; then
    fail "private fixture ordering differs from the neutral contract"
  fi

  album="$(
    sed -n 's/^[[:space:]]*album[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' \
      "${work_dir}/media-info" | head -n 1
  )"
  artist="$(
    sed -n 's/^[[:space:]]*artist[[:space:]]*:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' \
      "${work_dir}/media-info" | head -n 1
  )"
  if [[ -z "${album}" || -z "${artist}" ]]; then
    fail "private fixture lacks consistent grouping evidence"
  fi
  if [[ "${part_count}" -eq 1 ]]; then
    expected_album="${album}"
    expected_artist="${artist}"
  elif [[ "${album}" != "${expected_album}" || "${artist}" != "${expected_artist}" ]]; then
    fail "private fixture grouping evidence is inconsistent"
  fi

  duration="$(awk '/estimated duration:/ { print $3; exit }' "${work_dir}/media-info")"
  if [[ -z "${duration}" ]]; then
    fail "private fixture duration is unavailable"
  fi
  printf '%s\n' "${duration}" >> "${work_dir}/durations"

  byte_count="$(stat -f '%z' "${source_file}" 2>/dev/null)" \
    || fail "private fixture storage size is unavailable"
  total_bytes=$((total_bytes + byte_count))

  digest="$(shasum -a 256 "${source_file}" 2>/dev/null | awk '{print $1}')" \
    || fail "private fixture checksum is unavailable"
  printf '%s\n' "${digest}" >> "${work_dir}/source-before"
done < "${work_dir}/files"

if [[ "${part_count}" -ne 30 ]]; then
  fail "private fixture part count differs from the neutral contract"
fi
if [[ "${total_bytes}" -ne 933905211 ]]; then
  fail "private fixture storage size differs from the neutral contract"
fi

duration_valid="$(
  awk '{ total += $1 } END { print (total >= 58253.5 && total <= 58254.8) ? "yes" : "no" }' \
    "${work_dir}/durations"
)"
if [[ "${duration_valid}" != "yes" ]]; then
  fail "private fixture duration differs from the neutral contract"
fi

: > "${work_dir}/source-after"
while IFS= read -r -d '' source_file; do
  digest="$(shasum -a 256 "${source_file}" 2>/dev/null | awk '{print $1}')" \
    || fail "private fixture re-checksum is unavailable"
  printf '%s\n' "${digest}" >> "${work_dir}/source-after"
done < "${work_dir}/files"
if ! cmp -s "${work_dir}/source-before" "${work_dir}/source-after"; then
  fail "private fixture changed during read-only smoke validation"
fi

echo "Private fixture smoke contract passed: grouping, order, duration, and storage are valid."
