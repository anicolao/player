#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
manifest="SyntheticMessyMultifile.sha256"

if [[ ! -f "${fixture_root}/${manifest}" ]] \
  || ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1); then
  echo "messy multifile fixture checksum mismatch" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-messy-reproduction.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT
"${script_dir}/generate-messy-multifile-fixture.sh" "${work_dir}" >/dev/null

if ! diff -rq "${fixture_root}/SyntheticMessyMultifile" \
  "${work_dir}/SyntheticMessyMultifile" >/dev/null 2>&1 \
  || ! cmp -s "${fixture_root}/${manifest}" "${work_dir}/${manifest}"; then
  echo "messy multifile fixture differs from clean reproduction" >&2
  exit 2
fi

audio_count="$(find "${fixture_root}/SyntheticMessyMultifile" -type f -name '*.m4a' | wc -l | tr -d ' ')"
if [[ "${audio_count}" -ne 8 ]]; then
  echo "messy multifile fixture must contain eight audio assets" >&2
  exit 2
fi
while IFS= read -r -d '' audio_file; do
  if ! afinfo -r "${audio_file}" >/dev/null 2>&1; then
    echo "messy multifile fixture contains unreadable audio" >&2
    exit 2
  fi
done < <(find "${fixture_root}/SyntheticMessyMultifile" -type f -name '*.m4a' -print0)

echo "Messy multifile fixture is reproducible and Core Audio-readable."
