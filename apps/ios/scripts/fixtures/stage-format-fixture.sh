#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
manifest="${fixture_root}/SyntheticFormats.sha256"

case "${1:-}" in
  mp3) fixture_dir="${fixture_root}/SyntheticFormats/MP3" ;;
  m4b) fixture_dir="${fixture_root}/SyntheticFormats/M4B" ;;
  *)
    echo "usage: stage-format-fixture.sh <mp3|m4b> ABSOLUTE_DESTINATION" >&2
    exit 2
    ;;
esac

if [[ ! -d "${fixture_dir}" || ! -f "${manifest}" ]]; then
  echo "synthetic format fixture is missing" >&2
  exit 2
fi
if ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1); then
  echo "synthetic format fixture checksum mismatch" >&2
  exit 2
fi

LOCAL_AUDIOBOOK_FIXTURE="${fixture_dir}" \
  "${script_dir}/stage-local-audiobook.sh" "${2:-}"
