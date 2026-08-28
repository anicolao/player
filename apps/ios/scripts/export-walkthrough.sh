#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <xcresult-attachments-directory> <story-output-directory>" >&2
  exit 2
fi

attachments_directory="$1"
story_directory="$2"
manifest="${attachments_directory}/manifest.json"
screenshot_directory="${story_directory}/screenshots/ios"

if [[ ! -f "${manifest}" ]]; then
  echo "XCTest attachment manifest is missing: ${manifest}" >&2
  exit 1
fi

mkdir -p "${screenshot_directory}"

attachment_rows="$(
  jq -r '
    .[]? as $test
    | $test.attachments[]?
    | [
        ($test.testIdentifier // "unknown-test"),
        (.suggestedHumanReadableName // ""),
        (.exportedFileName // "")
      ]
    | @tsv
  ' "${manifest}"
)"

screenshot_count=0
readme_count=0
readme_directory="$(mktemp -d "${TMPDIR:-/tmp}/player-e2e-readmes.XXXXXX")"
trap 'rm -rf "${readme_directory}"' EXIT
readme_order="${readme_directory}/order.tsv"
: > "${readme_order}"

while IFS=$'\t' read -r test_identifier suggested_name exported_name; do
  [[ -n "${suggested_name}" && -n "${exported_name}" ]] || continue

  source_path="${attachments_directory}/${exported_name}"
  if [[ ! -f "${source_path}" ]]; then
    echo "Exported XCTest attachment is missing: ${exported_name}" >&2
    exit 1
  fi

  if [[ "${suggested_name}" =~ ^([0-9]{3}-.+)_([0-9]+)_([0-9A-Fa-f-]+)\.png$ ]]; then
    screenshot_name="${BASH_REMATCH[1]}.png"
  elif [[ "${suggested_name}" =~ ^[0-9]{3}-.+\.png$ ]]; then
    screenshot_name="${suggested_name}"
  else
    screenshot_name=""
  fi

  if [[ -n "${screenshot_name}" ]]; then
    destination="${screenshot_directory}/${screenshot_name}"
    if [[ -e "${destination}" ]]; then
      echo "Screenshot attachment collision for ${screenshot_name} (${test_identifier})" >&2
      exit 1
    fi
    cp "${source_path}" "${destination}"
    screenshot_count=$((screenshot_count + 1))
    continue
  fi

  if [[ "${suggested_name}" =~ ^README(_[0-9]+_[0-9A-Fa-f-]+)?\.md$ ]]; then
    readme_count=$((readme_count + 1))
    readme_path="${readme_directory}/$(printf '%03d' "${readme_count}").md"
    cp "${source_path}" "${readme_path}"

    screenshot_references="$(
      grep -Eo '\./screenshots/ios/[0-9]{3}-[A-Za-z0-9._-]+\.png' "${readme_path}" \
        || true
    )"
    if [[ -z "${screenshot_references}" ]]; then
      echo "Generated walkthrough README has no numbered screenshot: ${test_identifier}" >&2
      exit 1
    fi
    first_screenshot="$(printf '%s\n' "${screenshot_references}" | LC_ALL=C sort | head -n 1)"
    screenshot_basename="${first_screenshot##*/}"
    first_screenshot_index="${screenshot_basename%%-*}"
    printf '%s\t%s\t%s\n' \
      "${first_screenshot_index}" "${test_identifier}" "${readme_path}" \
      >> "${readme_order}"
  fi
done <<< "${attachment_rows}"

if [[ ${screenshot_count} -eq 0 ]]; then
  echo "No numbered walkthrough screenshot attachments were exported." >&2
  exit 1
fi

if [[ ${readme_count} -eq 0 ]]; then
  echo "No generated walkthrough README attachment was exported." >&2
  exit 1
fi

: > "${story_directory}/README.md"
while IFS=$'\t' read -r _ test_identifier readme; do
  if [[ -s "${story_directory}/README.md" ]]; then
    printf '\n---\n\n' >> "${story_directory}/README.md"
  fi
  sed '1{/^# Test: /!s/^/# Test: /;}' "${readme}" >> "${story_directory}/README.md"
done < <(LC_ALL=C sort -t $'\t' -k1,1n -k2,2 -k3,3 "${readme_order}")

printf 'Materialized %d screenshot(s) and %d README fragment(s) for the walkthrough.\n' \
  "${screenshot_count}" "${readme_count}"
