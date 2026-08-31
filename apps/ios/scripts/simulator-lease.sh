#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: simulator-lease.sh acquire LEASE_FILE NAME DEVICE_TYPE RUNTIME OWNER_PID
       simulator-lease.sh release LEASE_FILE OWNER_PID
       simulator-lease.sh reconcile LEASE_DIRECTORY

Creates and deletes only simulators named by durable, exact-UDID ownership
records. Reconciliation removes records whose owning process no longer exists.
EOF
}

valid_udid() {
  [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

valid_owner_pid() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

process_started_at() {
  local owner_pid="$1"
  ps -p "${owner_pid}" -o lstart= 2>/dev/null \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

validate_lease() {
  local lease_file="$1"
  [[ -f "${lease_file}" && ! -L "${lease_file}" ]] || return 1
  jq -e '
    type == "object"
    and (keys | sort) == ["deviceType", "displayName", "formatVersion", "owner", "runtime", "udid"]
    and .formatVersion == 1
    and (.udid | type == "string"
      and test("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"))
    and (.displayName | type == "string" and length > 0)
    and (.deviceType | type == "string" and length > 0)
    and (.runtime | type == "string" and length > 0)
    and (.owner | type == "object" and (keys | sort) == ["pid", "startedAt"])
    and (.owner.pid | type == "number" and . >= 1 and floor == .)
    and (.owner.startedAt | type == "string" and length > 0)
  ' "${lease_file}" >/dev/null
}

delete_owned_simulator() {
  local simulator_id="$1"
  valid_udid "${simulator_id}" || {
    echo "Refusing to delete a simulator with an invalid UDID: ${simulator_id}" >&2
    return 1
  }
  xcrun simctl shutdown "${simulator_id}" >/dev/null 2>&1 || true
  xcrun simctl delete "${simulator_id}" >/dev/null 2>&1
}

release_lease_record() {
  local lease_file="$1"
  local simulator_id
  simulator_id="$(jq -r '.udid' "${lease_file}")"
  delete_owned_simulator "${simulator_id}" || {
    echo "Could not delete leased simulator ${simulator_id}; retaining ${lease_file}." >&2
    return 1
  }
  rm -f "${lease_file}"
}

reconcile_leases() {
  local lease_directory="$1"
  local lease_file
  local current_start
  local owner_pid
  local owner_start
  local -a leases=()
  local -a stale_leases=()

  [[ "${lease_directory}" == /* ]] || {
    echo "The simulator lease directory must be absolute." >&2
    return 2
  }
  mkdir -p "${lease_directory}"

  shopt -s nullglob
  leases=("${lease_directory}"/*.json)
  shopt -u nullglob

  # Bash 3.2 and some nounset configurations reject expansion of a declared
  # but empty array. An empty directory is already fully reconciled.
  if (( ${#leases[@]} == 0 )); then
    return 0
  fi

  # Validate every record before deleting anything. One malformed record makes
  # ownership uncertain, so reconciliation fails closed without side effects.
  for lease_file in "${leases[@]}"; do
    if ! validate_lease "${lease_file}"; then
      echo "Malformed simulator lease; refusing reconciliation: ${lease_file}" >&2
      return 1
    fi
  done

  for lease_file in "${leases[@]}"; do
    owner_pid="$(jq -r '.owner.pid' "${lease_file}")"
    owner_start="$(jq -r '.owner.startedAt' "${lease_file}")"
    if kill -0 "${owner_pid}" >/dev/null 2>&1; then
      current_start="$(process_started_at "${owner_pid}")"
      if [[ -z "${current_start}" ]]; then
        echo "Could not validate live simulator-lease owner ${owner_pid}." >&2
        return 1
      fi
      if [[ "${current_start}" == "${owner_start}" ]]; then
        continue
      fi
    fi
    stale_leases+=("${lease_file}")
  done

  if (( ${#stale_leases[@]} > 0 )); then
    for lease_file in "${stale_leases[@]}"; do
      release_lease_record "${lease_file}" || return 1
    done
  fi
}

acquire_lease() {
  local lease_file="$1"
  local display_name="$2"
  local device_type="$3"
  local runtime="$4"
  local owner_pid="$5"
  local lease_directory
  local owner_start
  local simulator_id=""
  local candidate=""
  local lease_published=0

  [[ "${lease_file}" == /* && "${lease_file}" == *.json ]] || {
    echo "The simulator lease file must be an absolute .json path." >&2
    return 2
  }
  [[ -n "${display_name}" && -n "${device_type}" && -n "${runtime}" ]] || {
    echo "Simulator lease metadata may not be empty." >&2
    return 2
  }
  valid_owner_pid "${owner_pid}" || {
    echo "Invalid simulator lease owner PID: ${owner_pid}" >&2
    return 2
  }
  kill -0 "${owner_pid}" >/dev/null 2>&1 || {
    echo "Simulator lease owner ${owner_pid} is not running." >&2
    return 1
  }
  owner_start="$(process_started_at "${owner_pid}")"
  [[ -n "${owner_start}" ]] || {
    echo "Could not identify simulator lease owner ${owner_pid}." >&2
    return 1
  }

  lease_directory="$(dirname "${lease_file}")"
  reconcile_leases "${lease_directory}" || return $?
  if [[ -e "${lease_file}" || -L "${lease_file}" ]]; then
    echo "Simulator lease already exists: ${lease_file}" >&2
    return 1
  fi

  cleanup_incomplete_acquisition() {
    local status="$?"
    trap - EXIT INT TERM
    if [[ "${lease_published}" -eq 0 && -n "${simulator_id}" ]] \
      && valid_udid "${simulator_id}"; then
      delete_owned_simulator "${simulator_id}" || true
    fi
    if [[ -n "${candidate}" ]]; then rm -f "${candidate}"; fi
    return "${status}"
  }
  trap cleanup_incomplete_acquisition EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  simulator_id="$(xcrun simctl create "${display_name}" "${device_type}" "${runtime}")"
  if ! valid_udid "${simulator_id}"; then
    echo "simctl create returned an invalid simulator UDID: ${simulator_id}" >&2
    return 1
  fi

  candidate="$(mktemp "${lease_directory}/.simulator-lease.XXXXXX")"
  jq -n \
    --argjson formatVersion 1 \
    --arg udid "${simulator_id}" \
    --arg displayName "${display_name}" \
    --arg deviceType "${device_type}" \
    --arg runtime "${runtime}" \
    --argjson ownerPID "${owner_pid}" \
    --arg ownerStartedAt "${owner_start}" \
    '{formatVersion: $formatVersion, udid: $udid, displayName: $displayName,
      deviceType: $deviceType, runtime: $runtime,
      owner: {pid: $ownerPID, startedAt: $ownerStartedAt}}' > "${candidate}"
  if ! ln "${candidate}" "${lease_file}"; then
    echo "Could not publish simulator lease: ${lease_file}" >&2
    return 1
  fi
  lease_published=1
  rm -f "${candidate}"
  candidate=""
  trap - EXIT INT TERM
  printf '%s\n' "${simulator_id}"
}

release_lease() {
  local lease_file="$1"
  local owner_pid="$2"
  local recorded_pid
  local recorded_start
  local owner_start

  valid_owner_pid "${owner_pid}" || {
    echo "Invalid simulator lease owner PID: ${owner_pid}" >&2
    return 2
  }
  if ! validate_lease "${lease_file}"; then
    echo "Malformed simulator lease; refusing release: ${lease_file}" >&2
    return 1
  fi
  recorded_pid="$(jq -r '.owner.pid' "${lease_file}")"
  recorded_start="$(jq -r '.owner.startedAt' "${lease_file}")"
  owner_start="$(process_started_at "${owner_pid}")"
  if [[ "${recorded_pid}" != "${owner_pid}" || -z "${owner_start}" \
    || "${recorded_start}" != "${owner_start}" ]]; then
    echo "Simulator lease is not owned by process ${owner_pid}: ${lease_file}" >&2
    return 1
  fi
  release_lease_record "${lease_file}"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

operation="$1"
shift
case "${operation}" in
  acquire)
    [[ $# -eq 5 ]] || { usage; exit 2; }
    acquire_lease "$@"
    ;;
  release)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    release_lease "$@"
    ;;
  reconcile)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    reconcile_leases "$@"
    ;;
  *)
    usage
    exit 2
    ;;
esac
