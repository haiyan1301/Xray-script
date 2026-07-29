#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

mkdir -p "${TEST_DIR}/home/.xray-script"
cp config.json "${TEST_DIR}/home/.xray-script/config.json"
export HOME="${TEST_DIR}/home"

source install.sh

PROJECT_ROOT="${TEST_DIR}/installed-project"
mkdir -p "${PROJECT_ROOT}"
cp config.json "${PROJECT_ROOT}/config.json"

function fail_test() {
    echo "$1" >&2
    exit 1
}

config_version="$(jq -r '.version' config.json)"
[[ "${config_version}" == "${SCRIPT_VERSION}" ]] ||
    fail_test "config.json and install.sh versions differ: ${config_version} != ${SCRIPT_VERSION}"
valid_script_version "${SCRIPT_VERSION}" || fail_test "invalid script version format: ${SCRIPT_VERSION}"
[[ "$(command bash install.sh --version)" == "Xray-script ${SCRIPT_VERSION}" ]] ||
    fail_test 'install.sh --version does not match the release version'

script_version_is_newer 'v2026.07.29' 'v2026.07.28' || fail_test 'newer version was not detected'
if script_version_is_newer 'v2026.07.28' 'v2026.07.28'; then
    fail_test 'equal versions were treated as an update'
fi
if script_version_is_newer 'v2026.07.27' 'v2026.07.28'; then
    fail_test 'older remote version was treated as an update'
fi
if script_version_is_newer 'invalid' 'v2026.07.28'; then
    fail_test 'invalid remote version was treated as an update'
fi

[[ "$(choose_project_root '/opt/xray-custom' '/usr/local/xray-old')" == '/opt/xray-custom' ]] ||
    fail_test 'explicit -d path did not override the saved path'
[[ "$(choose_project_root '' '/usr/local/xray-old')" == '/usr/local/xray-old' ]] ||
    fail_test 'saved install path was not reused'
[[ "$(choose_project_root '' '')" == '/usr/local/xray-script' ]] ||
    fail_test 'default install path was not selected'
[[ "$(normalize_project_root '/opt/xray-script/../xray-script')" == '/opt/xray-script' ]] ||
    fail_test 'install path was not normalized'

for dangerous_path in '/' '/etc' '/usr' '/usr/local' '/opt' 'relative/path'; do
    if normalize_project_root "${dangerous_path}" >/dev/null 2>&1; then
        fail_test "dangerous install path was accepted: ${dangerous_path}"
    fi
done

if (parse_args -d) >"${TEST_DIR}/missing-d.stdout" 2>"${TEST_DIR}/missing-d.stderr"; then
    fail_test 'parse_args accepted -d without a path'
fi
if (parse_args -d --vision) >"${TEST_DIR}/option-as-path.stdout" 2>"${TEST_DIR}/option-as-path.stderr"; then
    fail_test 'parse_args accepted another option as the -d path'
fi

I18N_DATA['tip']='UPDATE_TIP'
I18N_DATA['new']='NEW_VERSION'
I18N_DATA['now']='UPDATE_NOW'
I18N_DATA['promptly']='UPDATE_LATER'
I18N_DATA['failed']='VERSION_FETCH_FAILED'

function set_local_version() {
    local version="$1"
    local target updated
    for target in "${PROJECT_ROOT}/config.json" "${SCRIPT_CONFIG_PATH}"; do
        updated="$(jq --arg version "${version}" '.version = $version' "${target}")"
        printf '%s\n' "${updated}" >"${target}"
    done
}

function download_xray_script_files() {
    fail_test 'version check attempted a download without update confirmation'
}

REMOTE_VERSION_MODE='failure'
function curl() {
    case "${REMOTE_VERSION_MODE}" in
    failure) return 22 ;;
    invalid) printf '%s\n' '{"version":"not-a-version"}' ;;
    older) printf '%s\n' '{"version":"v2026.07.27"}' ;;
    equal) printf '%s\n' '{"version":"v2026.07.28"}' ;;
    newer) printf '%s\n' '{"version":"v2026.07.29"}' ;;
    *) return 99 ;;
    esac
}

set_local_version 'v2026.07.28'
for REMOTE_VERSION_MODE in failure invalid older equal; do
    if ! check_xray_script_version </dev/null >"${TEST_DIR}/${REMOTE_VERSION_MODE}.log" 2>&1; then
        fail_test "version check failed for non-update mode: ${REMOTE_VERSION_MODE}"
    fi
    if grep -Fq 'NEW_VERSION' "${TEST_DIR}/${REMOTE_VERSION_MODE}.log"; then
        fail_test "version check prompted for a non-newer remote version: ${REMOTE_VERSION_MODE}"
    fi
done

REMOTE_VERSION_MODE='newer'
# 用户状态中的版本即使被手工改得更高，也不能掩盖实际安装代码需要更新。
state_config="$(jq '.version = "v2099.12.31"' "${SCRIPT_CONFIG_PATH}")"
printf '%s\n' "${state_config}" >"${SCRIPT_CONFIG_PATH}"
if ! check_xray_script_version <<<'n' >"${TEST_DIR}/newer.log" 2>&1; then
    fail_test 'version check failed while declining a valid newer version'
fi
grep -Fq 'NEW_VERSION' "${TEST_DIR}/newer.log"
grep -Fq 'UPDATE_LATER' "${TEST_DIR}/newer.log"
[[ "$(jq -r '.version' "${SCRIPT_CONFIG_PATH}")" == 'v2026.07.28' ]] ||
    fail_test 'state version was not synchronized to the installed code version'

echo "Installer flow tests passed"
