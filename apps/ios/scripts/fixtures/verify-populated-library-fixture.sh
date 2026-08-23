#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
fixture_dir="${fixture_root}/SyntheticLibrary"
manifest="SyntheticLibrary.sha256"

if [[ ! -f "${fixture_root}/${manifest}" ]] \
  || ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1); then
  echo "populated-library fixture checksum mismatch" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-library-reproduction.XXXXXX")"
cleanup() { rm -rf "${work_dir}"; }
trap cleanup EXIT
"${script_dir}/generate-populated-library-fixture.sh" "${work_dir}" >/dev/null
if ! diff -rq "${fixture_dir}" "${work_dir}/SyntheticLibrary" >/dev/null 2>&1 \
  || ! cmp -s "${fixture_root}/${manifest}" "${work_dir}/${manifest}"; then
  echo "populated-library fixture differs from clean reproduction" >&2
  exit 2
fi

if ! afinfo -r "${fixture_dir}/library-book-audio.m4b" >/dev/null 2>&1; then
  echo "populated-library fixture audio is unreadable" >&2
  exit 2
fi
encoded_duration="$(afinfo "${fixture_dir}/library-book-audio.m4b" | awk '/estimated duration:/{print $3}')"
if [[ "${encoded_duration}" != "2.100000" ]]; then
  echo "populated-library fixture audio duration changed" >&2
  exit 2
fi
for index in 1 2 3 4 5; do
  cover="${fixture_dir}/library-cover-b${index}.png"
  dimensions="$(sips -g format -g pixelWidth -g pixelHeight "${cover}" 2>/dev/null)"
  if ! grep -q 'format: png' <<<"${dimensions}" \
    || ! grep -q 'pixelWidth: 32' <<<"${dimensions}" \
    || ! grep -q 'pixelHeight: 32' <<<"${dimensions}"; then
    echo "populated-library cover is not the expected deterministic PNG" >&2
    exit 2
  fi
done
cover_hash_count="$(shasum -a 256 "${fixture_dir}"/library-cover-b*.png | awk '{print $1}' | sort -u | wc -l | tr -d ' ')"
if [[ "${cover_hash_count}" -ne 5 ]]; then
  echo "populated-library covers must be distinct" >&2
  exit 2
fi
xcrun swift "${script_dir}/validate-populated-library-fixture.swift" \
  "${fixture_dir}/synthetic-populated-library-fixture.json"
echo "Populated-library fixture is reproducible, readable, and structurally valid."
