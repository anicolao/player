#!/usr/bin/env bash
set -euo pipefail
set +x

export LC_ALL=C
export TZ=UTC

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_root="${1:-}"
lame_binary="${PLAYER_LAME_BINARY:-}"

if [[ -z "${output_root}" || ! -d "${output_root}" ]]; then
  echo "usage: PLAYER_LAME_BINARY=/path/to/lame generate-format-fixtures.sh EXISTING_OUTPUT_DIRECTORY" >&2
  exit 2
fi
if [[ -z "${lame_binary}" || ! -x "${lame_binary}" ]]; then
  echo "PLAYER_LAME_BINARY must identify an executable LAME 3.100 encoder" >&2
  exit 2
fi
if ! "${lame_binary}" --version 2>/dev/null | head -n 1 | rg -q '^LAME .*version 3\.100'; then
  echo "fixture reproduction requires LAME 3.100" >&2
  exit 2
fi

output_root="$(cd "${output_root}" && pwd -P)"
fixture_name="SyntheticFormats"
fixture_dir="${output_root}/${fixture_name}"
manifest="${output_root}/${fixture_name}.sha256"

if [[ -e "${fixture_dir}" || -L "${fixture_dir}" || -e "${manifest}" || -L "${manifest}" ]]; then
  echo "synthetic format fixture output already exists" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-format-audio.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

mkdir -p "${work_dir}/${fixture_name}/MP3" "${work_dir}/${fixture_name}/M4B"

mp3_wave="${work_dir}/mp3-source.wav"
mp3_output="${work_dir}/${fixture_name}/MP3/01-synthetic-chapter.mp3"
xcrun swift "${script_dir}/synthesize-pcm.swift" "${mp3_wave}" 392 1750
"${lame_binary}" \
  --silent \
  --cbr \
  -b 64 \
  -m m \
  --resample 24 \
  --noreplaygain \
  -t \
  --id3v2-only \
  --tt "Synthetic MP3 Chapter" \
  --ta "Player Test Generator" \
  --tl "Synthetic Format Book" \
  --tn "1/1" \
  --tg "Speech" \
  "${mp3_wave}" "${mp3_output}" >/dev/null 2>&1
if [[ ! -s "${mp3_output}" ]]; then
  echo "could not encode synthetic MP3" >&2
  exit 2
fi

m4b_wave="${work_dir}/m4b-source.wav"
m4b_output="${work_dir}/${fixture_name}/M4B/synthetic-single-book.m4b"
xcrun swift "${script_dir}/synthesize-pcm.swift" "${m4b_wave}" 784 2100
afconvert "${m4b_wave}" \
  -o "${m4b_output}" \
  -f m4bf \
  -d aac \
  -b 48000 \
  --no-filler
if [[ ! -s "${m4b_output}" ]]; then
  echo "could not encode synthetic M4B" >&2
  exit 2
fi
xcrun swift "${script_dir}/canonicalize-m4a.swift" "${m4b_output}"

(
  cd "${work_dir}"
  shasum -a 256 "${fixture_name}"/MP3/*.mp3 "${fixture_name}"/M4B/*.m4b \
    > "${fixture_name}.sha256"
)

mv "${work_dir}/${fixture_name}" "${fixture_dir}"
mv "${work_dir}/${fixture_name}.sha256" "${manifest}"

echo "Generated deterministic synthetic MP3 and M4B fixtures."
