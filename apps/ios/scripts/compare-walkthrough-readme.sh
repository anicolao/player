#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <expected-readme> <actual-readme> [diagnostics-directory]" >&2
  exit 2
fi

expected_readme="$1"
actual_readme="$2"
diagnostics_directory="${3:-}"

if [[ ! -f "${expected_readme}" ]]; then
  echo "Expected walkthrough README is missing: ${expected_readme}" >&2
  exit 1
fi

if [[ ! -f "${actual_readme}" ]]; then
  echo "Actual walkthrough README is missing: ${actual_readme}" >&2
  exit 1
fi

if cmp -s "${expected_readme}" "${actual_readme}"; then
  echo "Walkthrough README matches the reviewed baseline exactly."
  exit 0
fi

if [[ -n "${diagnostics_directory}" ]]; then
  mkdir -p "${diagnostics_directory}"
  cp "${expected_readme}" "${diagnostics_directory}/expected-README.md"
  cp "${actual_readme}" "${diagnostics_directory}/actual-README.md"
  diff -u \
    --label expected/README.md \
    --label actual/README.md \
    "${expected_readme}" "${actual_readme}" \
    > "${diagnostics_directory}/README.diff" || true
fi

echo "Walkthrough README differs from the reviewed baseline." >&2
if [[ -n "${diagnostics_directory}" ]]; then
  echo "README diagnostics: ${diagnostics_directory}" >&2
fi
exit 1
