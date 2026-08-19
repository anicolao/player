#!/usr/bin/env bash
set -euo pipefail
set +x

export LC_ALL=C

destination_argument="${1:-}"

fail() {
  echo "$1" >&2
  exit 2
}

if [[ -z "${LOCAL_AUDIOBOOK_FIXTURE:-}" ]]; then
  fail "LOCAL_AUDIOBOOK_FIXTURE is required"
fi
if [[ -z "${destination_argument}" ]]; then
  fail "usage: LOCAL_AUDIOBOOK_FIXTURE=/private/path stage-local-audiobook.sh ABSOLUTE_DESTINATION"
fi
if [[ "${destination_argument}" != /* ]]; then
  fail "destination must be an absolute path"
fi
if [[ ! -d "${LOCAL_AUDIOBOOK_FIXTURE}" ]]; then
  fail "local fixture must be a readable directory"
fi

source_root="$(cd "${LOCAL_AUDIOBOOK_FIXTURE}" 2>/dev/null && pwd -P)" \
  || fail "local fixture must be a readable directory"
destination_parent_argument="$(dirname "${destination_argument}")"
destination_leaf="$(basename "${destination_argument}")"

if [[ "${destination_leaf}" == "." || "${destination_leaf}" == ".." || -z "${destination_leaf}" ]]; then
  fail "destination must identify a new directory"
fi
if [[ ! -d "${destination_parent_argument}" ]]; then
  fail "destination parent must already exist"
fi

destination_parent="$(cd "${destination_parent_argument}" 2>/dev/null && pwd -P)" \
  || fail "destination parent must be readable"
destination="${destination_parent}/${destination_leaf}"
if [[ -e "${destination}" || -L "${destination}" ]]; then
  fail "destination must not already exist"
fi

if find "${source_root}" -type l -print -quit 2>/dev/null | read -r _; then
  fail "local fixture must not contain symbolic links"
fi

audio_count=0
regular_file_count=0
while IFS= read -r -d '' source_file; do
  regular_file_count=$((regular_file_count + 1))
  if [[ ! -s "${source_file}" ]]; then
    fail "local fixture files must be non-empty"
  fi

  extension="${source_file##*.}"
  extension="$(printf '%s' "${extension}" | tr '[:upper:]' '[:lower:]')"
  case "${extension}" in
    aac|caf|m4a|m4b|mp3|wav)
      audio_count=$((audio_count + 1))
      ;;
  esac
done < <(find "${source_root}" -type f -print0 2>/dev/null)

if [[ "${regular_file_count}" -eq 0 || "${audio_count}" -eq 0 ]]; then
  fail "local fixture must contain at least one supported audio file"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-local-audio.XXXXXX")"
created_destination=0
cleanup() {
  rm -rf "${work_dir}"
  if [[ "${created_destination}" -eq 1 ]]; then
    rm -rf "${destination}"
  fi
}
trap cleanup EXIT

snapshot_tree() {
  local root="$1"
  local output="$2"
  : > "${output}"
  while IFS= read -r -d '' file; do
    relative_path="${file#"${root}"/}"
    digest="$(shasum -a 256 "${file}" 2>/dev/null | awk '{print $1}')" \
      || return 1
    printf '%s  %s\n' "${digest}" "${relative_path}" >> "${output}"
  done < <(find "${root}" -type f -print0 2>/dev/null)
  sort -o "${output}" "${output}"
}

snapshot_tree "${source_root}" "${work_dir}/source-before" \
  || fail "could not checksum local fixture"

created_destination=1
if ! ditto "${source_root}" "${destination}" >/dev/null 2>&1; then
  fail "could not stage local fixture"
fi

snapshot_tree "${source_root}" "${work_dir}/source-after" \
  || fail "could not re-checksum local fixture"
if ! cmp -s "${work_dir}/source-before" "${work_dir}/source-after"; then
  fail "local fixture changed while it was being staged"
fi

snapshot_tree "${destination}" "${work_dir}/destination" \
  || fail "could not checksum staged fixture"
if ! cmp -s "${work_dir}/source-before" "${work_dir}/destination"; then
  fail "staged fixture does not match its source"
fi

created_destination=0
echo "Staged local audiobook; source and staged checksums match."
