#!/usr/bin/env bash
set -euo pipefail
set +x

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
fixture_root="${ios_dir}/PlayerUITests/Fixtures"
manifest="SyntheticZIPs.sha256"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required to verify ZIP fixtures" >&2
  exit 2
fi

if [[ ! -f "${fixture_root}/${manifest}" ]] \
  || ! (cd "${fixture_root}" && shasum -a 256 -c "${manifest}" >/dev/null 2>&1); then
  echo "ZIP fixture checksum mismatch" >&2
  exit 2
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/player-zip-reproduction.XXXXXX")"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT
"${script_dir}/generate-zip-fixtures.sh" "${work_dir}" >/dev/null
if ! diff -rq "${fixture_root}/SyntheticZIPs" "${work_dir}/SyntheticZIPs" \
  >/dev/null 2>&1 \
  || ! cmp -s "${fixture_root}/${manifest}" "${work_dir}/${manifest}"; then
  echo "ZIP fixtures differ from clean reproduction" >&2
  exit 2
fi

if ! unzip -t "${fixture_root}/SyntheticZIPs/valid-multifile.zip" >/dev/null 2>&1; then
  echo "valid ZIP fixture failed archive integrity validation" >&2
  exit 2
fi
for hostile in path-traversal symlink-escape ratio-limit count-limit size-limit; do
  if ! unzip -t "${fixture_root}/SyntheticZIPs/${hostile}.zip" >/dev/null 2>&1; then
    echo "hostile ZIP fixture is structurally malformed" >&2
    exit 2
  fi
done
if ! zipinfo -l "${fixture_root}/SyntheticZIPs/symlink-escape.zip" \
  | rg -q '^l'; then
  echo "symlink ZIP fixture lacks a Unix symlink entry" >&2
  exit 2
fi
if [[ "$(zipinfo -1 "${fixture_root}/SyntheticZIPs/count-limit.zip" | wc -l | tr -d ' ')" -ne 33 ]]; then
  echo "entry-count ZIP fixture does not cross its configured limit" >&2
  exit 2
fi
if ! zipinfo -l "${fixture_root}/SyntheticZIPs/size-limit.zip" \
  | awk '/oversized\.bin$/ { valid = ($4 == 131073) } END { exit valid ? 0 : 1 }'; then
  echo "entry-size ZIP fixture does not cross its configured limit" >&2
  exit 2
fi
if ! zipinfo -l "${fixture_root}/SyntheticZIPs/ratio-limit.zip" \
  | awk '/highly-compressible\.bin$/ { valid = ($4 / $6 > 20) } END { exit valid ? 0 : 1 }'; then
  echo "compression-ratio ZIP fixture does not cross its configured limit" >&2
  exit 2
fi
traversal_entries="$(zipinfo -1 "${fixture_root}/SyntheticZIPs/path-traversal.zip")"
if ! printf '%s\n' "${traversal_entries}" | rg -q '^\.\./' \
  || ! printf '%s\n' "${traversal_entries}" | rg -q '^/'; then
  echo "path-traversal ZIP fixture lacks escaping entries" >&2
  exit 2
fi

echo "ZIP fixtures are reproducible and structurally valid."
