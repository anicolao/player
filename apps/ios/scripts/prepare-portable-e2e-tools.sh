#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: prepare-portable-e2e-tools.sh OUTPUT_DIRECTORY" >&2
  exit 2
fi

output_directory="$1"
version="15.2.0"
archive_name="ripgrep-${version}-aarch64-apple-darwin.tar.gz"
archive_url="https://github.com/BurntSushi/ripgrep/releases/download/${version}/${archive_name}"
archive_sha256="3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4"
expected_version="ripgrep 15.2.0 (rev e89fff89ac)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/player-portable-tools.XXXXXX")"

cleanup() {
  find "${temporary_root}" -depth -delete
}
trap cleanup EXIT INT TERM

archive="${temporary_root}/${archive_name}"
curl --fail --location --silent --show-error "${archive_url}" --output "${archive}"
printf '%s  %s\n' "${archive_sha256}" "${archive}" | shasum -a 256 -c -

mkdir -p "${output_directory}"
tar -xzf "${archive}" \
  -C "${output_directory}" \
  --strip-components 1 \
  "ripgrep-${version}-aarch64-apple-darwin/rg"

[[ "$("${output_directory}/rg" --version | head -n 1)" == "${expected_version}" ]] \
  || { echo "Portable ripgrep version verification failed." >&2; exit 1; }
