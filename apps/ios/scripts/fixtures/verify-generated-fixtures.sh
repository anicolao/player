#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"

verify_manifest() {
  local manifest="$1"
  if [[ ! -f "${fixture_root}/${manifest}" ]]; then
    echo "fixture manifest is missing" >&2
    exit 2
  fi
  if ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1); then
    echo "fixture checksum mismatch" >&2
    exit 2
  fi
}

verify_manifest "SyntheticAudiobook.sha256"
verify_manifest "SyntheticFormats.sha256"

if [[ -n "${PLAYER_LAME_BINARY:-}" ]]; then
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-fixture-reproduction.XXXXXX")"
  cleanup() {
    rm -rf "${work_dir}"
  }
  trap cleanup EXIT

  mkdir "${work_dir}/first" "${work_dir}/second"
  PLAYER_LAME_BINARY="${PLAYER_LAME_BINARY}" \
    "${script_dir}/generate-format-fixtures.sh" "${work_dir}/first" >/dev/null
  PLAYER_LAME_BINARY="${PLAYER_LAME_BINARY}" \
    "${script_dir}/generate-format-fixtures.sh" "${work_dir}/second" >/dev/null

  if ! diff -rq "${work_dir}/first" "${work_dir}/second" >/dev/null 2>&1; then
    echo "fixture generation is not byte-for-byte deterministic" >&2
    exit 2
  fi
  if ! diff -rq "${fixture_root}/SyntheticFormats" \
      "${work_dir}/first/SyntheticFormats" >/dev/null 2>&1 \
    || ! cmp -s "${fixture_root}/SyntheticFormats.sha256" \
      "${work_dir}/first/SyntheticFormats.sha256"; then
    echo "checked-in fixtures differ from a clean reproduction" >&2
    exit 2
  fi
fi

echo "Synthetic fixture checksums and format-generation contract are valid."
