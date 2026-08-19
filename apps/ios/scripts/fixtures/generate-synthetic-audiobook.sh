#!/usr/bin/env bash
set -euo pipefail
set +x

export LC_ALL=C
export TZ=UTC

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_root="${1:-}"

if [[ -z "${output_root}" || ! -d "${output_root}" ]]; then
  echo "usage: generate-synthetic-audiobook.sh EXISTING_OUTPUT_DIRECTORY" >&2
  exit 2
fi

output_root="$(cd "${output_root}" && pwd -P)"
fixture_name="SyntheticAudiobook"
fixture_dir="${output_root}/${fixture_name}"
manifest="${output_root}/${fixture_name}.sha256"

if [[ -e "${fixture_dir}" || -L "${fixture_dir}" || -e "${manifest}" || -L "${manifest}" ]]; then
  echo "synthetic fixture output already exists" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-synthetic-audio.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

mkdir "${work_dir}/${fixture_name}"

make_part() {
  local filename="$1"
  local frequency="$2"
  local duration_ms="$3"
  local wave_file="${work_dir}/source.wav"
  local output_file="${work_dir}/${fixture_name}/${filename}"

  xcrun swift "${script_dir}/synthesize-pcm.swift" \
    "${wave_file}" "${frequency}" "${duration_ms}"
  afconvert "${wave_file}" \
    -o "${output_file}" \
    -f m4af \
    -d aac \
    -b 48000 \
    --no-filler
  if [[ ! -s "${output_file}" ]]; then
    echo "could not encode synthetic audio" >&2
    exit 2
  fi
  xcrun swift "${script_dir}/canonicalize-m4a.swift" "${output_file}"
  rm "${wave_file}"
}

make_part "01-opening-tone.m4a" 440 1800
make_part "02-middle-tone.m4a" 554 2200
make_part "03-closing-tone.m4a" 659 2600

(
  cd "${work_dir}"
  shasum -a 256 "${fixture_name}"/*.m4a > "${fixture_name}.sha256"
)

mv "${work_dir}/${fixture_name}" "${fixture_dir}"
mv "${work_dir}/${fixture_name}.sha256" "${manifest}"

echo "Generated deterministic synthetic audiobook fixture."
