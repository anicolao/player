#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
fixture_dir="${fixture_root}/SyntheticAudiobook"
manifest="${fixture_root}/SyntheticAudiobook.sha256"

if [[ ! -d "${fixture_dir}" || ! -f "${manifest}" ]]; then
  echo "synthetic fixture is missing; run generate-synthetic-audiobook.sh" >&2
  exit 2
fi

if ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1); then
  echo "synthetic fixture checksum mismatch" >&2
  exit 2
fi

LOCAL_AUDIOBOOK_FIXTURE="${fixture_dir}" \
  "${script_dir}/stage-local-audiobook.sh" "${1:-}"
