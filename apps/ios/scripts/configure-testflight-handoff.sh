#!/usr/bin/env bash
set -euo pipefail
set +x

umask 077

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

prompt_required() {
  local prompt="$1"
  local value
  read -r -p "${prompt}: " value
  [[ -n "${value}" ]] || fail "${prompt} is required"
  printf '%s' "${value}"
}

prompt_default() {
  local prompt="$1"
  local default_value="$2"
  local value
  read -r -p "${prompt} [${default_value}]: " value
  printf '%s' "${value:-${default_value}}"
}

player_team_id="$(prompt_required 'Apple Developer Team ID')"
player_issuer_id="$(prompt_required 'App Store Connect API Issuer ID')"
player_key_id="$(prompt_required 'App Store Connect API Key ID')"

[[ "${player_team_id}" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "Team ID must contain 10 uppercase letters or digits"
[[ "${player_key_id}" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "API Key ID must contain 10 uppercase letters or digits"
[[ "${player_issuer_id}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
  || fail "Issuer ID must be a UUID"

default_key_source="${HOME}/Downloads/AuthKey_${player_key_id}.p8"
read -r -p "Downloaded API private key [${default_key_source}]: " player_key_source
player_key_source="${player_key_source:-${default_key_source}}"
if [[ "${player_key_source}" == '~/'* ]]; then
  player_key_source="${HOME}/${player_key_source#\~/}"
fi

[[ -f "${player_key_source}" ]] || fail "Private key file was not found"
openssl pkey -in "${player_key_source}" -noout >/dev/null 2>&1 \
  || fail "The selected file is not a parseable private key"

player_app_name="$(prompt_default 'Exact App Store Connect app name' 'Player')"
player_app_sku="$(prompt_default 'Exact App Store Connect SKU' 'player-ios')"
player_testflight_group="$(prompt_default 'Internal TestFlight group name' 'Internal')"
player_tester_email="$(prompt_required 'Existing App Store Connect tester email')"
[[ "${player_tester_email}" == *@*.* ]] || fail "Tester email does not look valid"

player_key_directory="${HOME}/.appstoreconnect/private_keys"
player_key_target="${player_key_directory}/AuthKey_${player_key_id}.p8"
player_config_directory="${HOME}/.config/player"
player_config_path="${player_config_directory}/testflight.env"

mkdir -p "${player_key_directory}" "${player_config_directory}"

if [[ "${player_key_source}" != "${player_key_target}" ]]; then
  [[ ! -e "${player_key_target}" ]] \
    || fail "A key already exists at ${player_key_target}; remove or reconcile it first"
  mv "${player_key_source}" "${player_key_target}"
fi
chmod 600 "${player_key_target}"

[[ ! -e "${player_config_path}" ]] \
  || fail "Configuration already exists at ${player_config_path}; remove or reconcile it first"

player_config_temporary="$(mktemp "${player_config_directory}/testflight.env.XXXXXX")"
cleanup() {
  if [[ -n "${player_config_temporary:-}" && -f "${player_config_temporary}" ]]; then
    find "${player_config_temporary}" -delete
  fi
}
trap cleanup EXIT

{
  printf 'PLAYER_APPLE_TEAM_ID=%q\n' "${player_team_id}"
  printf 'PLAYER_ASC_ISSUER_ID=%q\n' "${player_issuer_id}"
  printf 'PLAYER_ASC_KEY_ID=%q\n' "${player_key_id}"
  printf 'PLAYER_ASC_KEY_PATH=%q\n' "${player_key_target}"
  printf 'PLAYER_ASC_APP_BUNDLE_ID=%q\n' 'com.spnss.player'
  printf 'PLAYER_ASC_SHARE_BUNDLE_ID=%q\n' 'com.spnss.player.share'
  printf 'PLAYER_APP_GROUP_ID=%q\n' 'group.com.spnss.player'
  printf 'PLAYER_ASC_APP_NAME=%q\n' "${player_app_name}"
  printf 'PLAYER_ASC_APP_SKU=%q\n' "${player_app_sku}"
  printf 'PLAYER_TESTFLIGHT_GROUP=%q\n' "${player_testflight_group}"
  printf 'PLAYER_TESTFLIGHT_TESTER_EMAIL=%q\n' "${player_tester_email}"
} >"${player_config_temporary}"

chmod 600 "${player_config_temporary}"
mv "${player_config_temporary}" "${player_config_path}"
player_config_temporary=''
trap - EXIT

printf '\nDeveloper handoff installed.\n'
printf 'Private key: %s\n' "${player_key_target}"
printf 'Configuration: %s\n' "${player_config_path}"
printf 'Neither file is inside the repository. Do not paste their contents into chat.\n'
printf 'Reply only: Developer handoff complete.\n'
