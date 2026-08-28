#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/.." && pwd)"
repository_root="$(cd "${ios_dir}/../.." && pwd)"
manifest_name="PlayerE2EBuildProvenance.json"

usage() {
  cat >&2 <<'EOF'
usage: e2e-build-provenance.sh write|verify BUILD_DATA DEVICE_TYPE RUNTIME

Writes or verifies the fail-closed provenance manifest for an E2E
build-for-testing output.
EOF
}

if [[ $# -ne 4 || ( "$1" != "write" && "$1" != "verify" ) ]]; then
  usage
  exit 2
fi

operation="$1"
build_data="$2"
device_type="$3"
runtime="$4"
stored_manifest="${build_data}/${manifest_name}"

source_digest() {
  local digest_input
  digest_input="$(mktemp "${TMPDIR:-/tmp}/player-e2e-source.XXXXXX")"
  trap 'rm -f "${digest_input}"' RETURN
  while IFS= read -r -d '' relative_path; do
    printf '%s\0' "${relative_path}" >> "${digest_input}"
    shasum -a 256 "${repository_root}/${relative_path}" \
      | awk '{print $1}' >> "${digest_input}"
  done < <(
    git -C "${repository_root}" ls-files -z -co --exclude-standard -- \
      apps/ios/Player \
      apps/ios/ShareExtension \
      apps/ios/PlayerTests \
      apps/ios/PlayerUITests \
      apps/ios/Config \
      apps/ios/project.yml \
      apps/ios/Player.xcodeproj/project.pbxproj
  )
  shasum -a 256 "${digest_input}" | awk '{print $1}'
  rm -f "${digest_input}"
  trap - RETURN
}

if [[ ! -d "${build_data}/Build/Products" ]]; then
  echo "E2E build products are unavailable in ${build_data}." >&2
  exit 1
fi

xctestruns=()
while IFS= read -r xctestrun; do xctestruns+=("${xctestrun}"); done < <(
  find "${build_data}/Build/Products" -maxdepth 1 -type f -name '*.xctestrun' | LC_ALL=C sort
)
if [[ ${#xctestruns[@]} -ne 1 ]]; then
  echo "Expected exactly one E2E xctestrun in ${build_data}; found ${#xctestruns[@]}." >&2
  exit 1
fi

xctestrun="${xctestruns[0]}"
xctestrun_relative="${xctestrun#"${build_data}/"}"
head_commit="$(git -C "${repository_root}" rev-parse HEAD)"
source_sha256="$(source_digest)"
project_sha256="$(shasum -a 256 "${ios_dir}/Player.xcodeproj/project.pbxproj" | awk '{print $1}')"
xctestrun_sha256="$(shasum -a 256 "${xctestrun}" | awk '{print $1}')"
xcode_version="$(xcodebuild -version)"
sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
sdk_build="$(xcrun --sdk iphonesimulator --show-sdk-build-version)"
developer_dir="${DEVELOPER_DIR:-}"

candidate="$(mktemp "${TMPDIR:-/tmp}/player-e2e-provenance.XXXXXX")"
trap 'rm -f "${candidate}"' EXIT
jq -n \
  --argjson formatVersion 1 \
  --arg commit "${head_commit}" \
  --arg sourceSHA256 "${source_sha256}" \
  --arg projectSHA256 "${project_sha256}" \
  --arg scheme Player \
  --arg configuration E2E \
  --arg deviceType "${device_type}" \
  --arg runtime "${runtime}" \
  --arg developerDir "${developer_dir}" \
  --arg xcodeVersion "${xcode_version}" \
  --arg simulatorSDKVersion "${sdk_version}" \
  --arg simulatorSDKBuild "${sdk_build}" \
  --arg xctestrun "${xctestrun_relative}" \
  --arg xctestrunSHA256 "${xctestrun_sha256}" \
  '{formatVersion: $formatVersion, commit: $commit,
    sourceSHA256: $sourceSHA256, projectSHA256: $projectSHA256,
    scheme: $scheme, configuration: $configuration,
    destination: {platform: "iOS Simulator", deviceType: $deviceType, runtime: $runtime},
    toolchain: {developerDir: $developerDir, xcodeVersion: $xcodeVersion,
      simulatorSDKVersion: $simulatorSDKVersion, simulatorSDKBuild: $simulatorSDKBuild},
    xctestrun: {path: $xctestrun, sha256: $xctestrunSHA256}}' \
  > "${candidate}"

if [[ "${operation}" == "write" ]]; then
  manifest_temporary="${stored_manifest}.tmp.$$"
  cp "${candidate}" "${manifest_temporary}"
  mv "${manifest_temporary}" "${stored_manifest}"
  exit 0
fi

if [[ ! -f "${stored_manifest}" ]]; then
  echo "The reusable E2E build has no provenance manifest: ${stored_manifest}" >&2
  exit 1
fi
if ! cmp -s "${stored_manifest}" "${candidate}"; then
  echo "The reusable E2E build provenance does not match the current source and toolchain." >&2
  diff -u "${stored_manifest}" "${candidate}" >&2 || true
  exit 1
fi
