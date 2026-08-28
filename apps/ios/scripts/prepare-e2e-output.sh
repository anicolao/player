#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: prepare-e2e-output.sh IOS_DIRECTORY STORY_ID [ABSOLUTE_OUTPUT_DIRECTORY]" >&2
  exit 2
fi

ios_dir="$1"
story_id="$2"
requested_output="${3:-}"

if [[ ! "${story_id}" =~ ^[0-9]{3}-[a-z0-9][a-z0-9-]*$ ]]; then
  echo "Invalid story identifier: ${story_id}" >&2
  exit 2
fi

if [[ -n "${requested_output}" ]]; then
  if [[ "${requested_output}" != /* ]]; then
    echo "An explicit E2E output directory must be absolute." >&2
    exit 2
  fi
  if [[ -e "${requested_output}" || -L "${requested_output}" ]]; then
    echo "An explicit E2E output directory must not already exist: ${requested_output}" >&2
    exit 2
  fi
  output_parent="$(dirname "${requested_output}")"
  if [[ ! -d "${output_parent}" ]]; then
    echo "The E2E output parent does not exist: ${output_parent}" >&2
    exit 2
  fi
  if ! mkdir "${requested_output}"; then
    echo "Could not atomically reserve E2E output: ${requested_output}" >&2
    exit 1
  fi
  printf '%s\n' "${requested_output}"
  exit 0
fi

derived_data_root="${ios_dir}/DerivedData/E2E"
mkdir -p "${derived_data_root}"
mktemp -d "${derived_data_root}/${story_id}.run.XXXXXX"
