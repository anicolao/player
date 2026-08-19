#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/.." && pwd)"
tool_dir="${ios_dir}/.tools/xcodegen-2.46.0"
archive="${ios_dir}/.tools/xcodegen-2.46.0.zip"
xcodegen="${tool_dir}/xcodegen/bin/xcodegen"
expected_sha256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

if [[ ! -x "${xcodegen}" ]]; then
  mkdir -p "${ios_dir}/.tools"
  curl --fail --location --silent --show-error \
    "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip" \
    --output "${archive}"
  actual_sha256="$(shasum -a 256 "${archive}" | awk '{print $1}')"
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    echo "XcodeGen checksum mismatch" >&2
    exit 1
  fi
  mkdir -p "${tool_dir}"
  ditto -x -k "${archive}" "${tool_dir}"
fi

"${xcodegen}" generate --spec "${ios_dir}/project.yml" --project "${ios_dir}"

