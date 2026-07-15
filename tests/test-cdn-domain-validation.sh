#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
readonly JQ_BIN="$(command -v jq || true)"
[[ -n "${JQ_BIN}" ]] || { echo "jq is required" >&2; exit 1; }

mkdir -p "${TEST_DIR}/home/.xray-script" "${TEST_DIR}/home/bin"
ln -s "${JQ_BIN}" "${TEST_DIR}/home/bin/jq"
cp config.json "${TEST_DIR}/script.json"
cp config.json "${TEST_DIR}/home/.xray-script/config.json"
export HOME="${TEST_DIR}/home"
export SCRIPT_CONFIG_PATH_OVERRIDE="${TEST_DIR}/script.json"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/xray.json"

source core/handler.sh
I18N_DATA="$(jq . i18n/en.json)"

command bash core/check.sh --domain-format 'cdn.example.com' >/dev/null 2>&1
for invalid_domain in '' '../../x' 'bad/domain.com' 'bad|domain.com'; do
    if command bash core/check.sh --domain-format "${invalid_domain}" >/dev/null 2>&1; then
        echo "invalid domain was accepted: ${invalid_domain}" >&2
        exit 1
    fi
done

READ_RESULT='cdn.example.com'
CHECK_OPTION=''

function bash() {
    if [[ "$1" == "${READ_PATH}" ]]; then
        printf '%s\n' "${READ_RESULT}"
        return 0
    fi
    command bash "$@"
}

function exec_check() {
    CHECK_OPTION="$1"
    return 0
}

reset_config_data
CONFIG_DATA['tag']='CDN'
CHECK_OPTION=''
exec_read 'cdn'
[[ "${CHECK_OPTION}" == '--domain-format' ]]
[[ "${CONFIG_DATA['cdn']}" == "${READ_RESULT}" ]]

reset_config_data
CONFIG_DATA['tag']='SNI'
CHECK_OPTION=''
exec_read 'cdn'
[[ "${CHECK_OPTION}" == '--dns' ]]

reset_config_data
SCRIPT_CONFIG="$(jq '.xray.tag = "CDN"' <<<"${SCRIPT_CONFIG}")"
CHECK_OPTION=''
exec_read 'cdn'
[[ "${CHECK_OPTION}" == '--domain-format' ]]

reset_config_data
SCRIPT_CONFIG="$(jq '.xray.tag = "SNI"' <<<"${SCRIPT_CONFIG}")"
CHECK_OPTION=''
exec_read 'cdn'
[[ "${CHECK_OPTION}" == '--dns' ]]

reset_config_data
CHECK_OPTION=''
exec_read 'domain'
[[ "${CHECK_OPTION}" == '--dns' ]]
[[ "${CONFIG_DATA['target']}" == "${READ_RESULT}" ]]

echo "CDN domain validation tests passed"
