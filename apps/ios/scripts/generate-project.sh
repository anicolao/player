#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/.." && pwd)"
tool_dir="${ios_dir}/.tools/xcodegen-2.46.0"
archive="${ios_dir}/.tools/xcodegen-2.46.0.zip"
xcodegen="${tool_dir}/xcodegen/bin/xcodegen"
expected_sha256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

"${script_dir}/build-receiver-web.sh"

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

# XcodeGen 2.46 serializes nested target attributes as a quoted Swift
# dictionary description. Rewrite only the exact App Groups capability shape;
# fail when upstream output changes so this workaround cannot silently linger.
project_file="${ios_dir}/Player.xcodeproj/project.pbxproj"
malformed_capability='SystemCapabilities = "[\"com.apple.ApplicationGroups.iOS\": [\"enabled\": 1]]";'
fixed_capability='SystemCapabilities = { com.apple.ApplicationGroups.iOS = { enabled = 1; }; };'
capability_count="$(grep -F -c "${malformed_capability}" "${project_file}" || true)"
if [[ "${capability_count}" != "2" ]]; then
  echo "Expected two malformed App Groups capability attributes; found ${capability_count}." >&2
  exit 1
fi
PLAYER_MALFORMED_CAPABILITY="${malformed_capability}" \
PLAYER_FIXED_CAPABILITY="${fixed_capability}" \
  /usr/bin/perl -0pi -e \
  's/\Q$ENV{PLAYER_MALFORMED_CAPABILITY}\E/$ENV{PLAYER_FIXED_CAPABILITY}/g' \
  "${project_file}"
