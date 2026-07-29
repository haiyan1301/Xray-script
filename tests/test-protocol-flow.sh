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
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/runtime.json"
cat >"${XRAY_CONFIG_PATH_OVERRIDE}" <<'EOF'
{
  "marker": "old-runtime",
  "inbounds": [
    {
      "listen": "/dev/shm/nginx/old.sock"
    }
  ]
}
EOF

source lib/protocols.sh

expected=(Vision XHTTP Trojan Fallback hy2 ss2022 mKCP CDN SNI multi)
for index in "${!expected[@]}"; do
    choice=$((index + 1))
    [[ "$(protocol_from_menu_choice "${choice}")" == "${expected[${index}]}" ]]
done
! protocol_from_menu_choice 0
! protocol_from_multi_menu_choice 0

protocol_uses_vless_enc CDN
protocol_uses_nginx CDN ''
protocol_uses_nginx CDN nginx
! protocol_uses_nginx CDN xray
[[ "$(normalize_cdn_backend '')" == 'nginx' ]]
[[ "$(normalize_cdn_backend 'unexpected')" == 'nginx' ]]
[[ "$(normalize_cdn_backend 'xray')" == 'xray' ]]
protocol_uses_xhttp CDN
! protocol_uses_reality CDN
! protocol_reads_public_port CDN
protocol_uses_reality SNI
protocol_uses_hy2_certificate hy2
! protocol_uses_hy2_certificate Vision
[[ "$(normalize_xhttp_path 'custom-path')" == '/custom-path' ]]
[[ "$(normalize_xhttp_path '/custom-path')" == '/custom-path' ]]
[[ -z "$(normalize_xhttp_path '')" ]]

menu_status=0
bash core/menu.sh --config <<<"" >/dev/null 2>&1 || menu_status=$?
[[ "${menu_status}" -eq 1 ]]
menu_status=0
bash core/menu.sh --xray <<<"" >/dev/null 2>&1 || menu_status=$?
[[ "${menu_status}" -eq 2 ]]
menu_status=0
bash core/menu.sh --web <<<"" >/dev/null 2>&1 || menu_status=$?
[[ "${menu_status}" -eq 1 ]]
menu_status=0
bash core/menu.sh --cdn-backend <<<"" >/dev/null 2>&1 || menu_status=$?
[[ "${menu_status}" -eq 1 ]]
bash core/menu.sh --config <<<"0" >/dev/null 2>&1

source core/main.sh

FLOW_LOG="${TEST_DIR}/flow.log"
SCRIPT_BASELINE="${TEST_DIR}/script.baseline.json"
RUNTIME_BASELINE="${TEST_DIR}/runtime.baseline.json"
cp "${SCRIPT_CONFIG_PATH}" "${SCRIPT_BASELINE}"
cp "${XRAY_RUNTIME_CONFIG_PATH}" "${RUNTIME_BASELINE}"

FAILED_STAGE=''
CDN_BACKEND_CHOICE='nginx'
WEB_BACKEND_FORBIDDEN=0
MUTATE_HANDLER_STATE=0
RECOVERY_BAD_STATE="${TEST_DIR}/recovery-bad-state"
STOP_BAD_RUNTIME="${TEST_DIR}/stop-bad-runtime"
STOP_BAD_SCRIPT="${TEST_DIR}/stop-bad-script"

function log_handler_call() {
    local argument
    local separator=''

    for argument in "$@"; do
        [[ -n "${argument}" ]] || continue
        printf '%s%s' "${separator}" "${argument}" >>"${FLOW_LOG}"
        separator=' '
    done
    printf '\n' >>"${FLOW_LOG}"
}

function exec_handler() {
    log_handler_call "$@"
    if [[ "$1" == '--stop' ]]; then
        [[ -e "${XRAY_RUNTIME_CONFIG_PATH}" ]] ||
            : >"${STOP_BAD_RUNTIME}"
        cmp -s "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}" ||
            : >"${STOP_BAD_SCRIPT}"
        return 0
    fi
    if [[ "$1" == '--recover-runtime' ]]; then
        if ! cmp -s "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}" ||
            ! cmp -s "${RUNTIME_BASELINE}" "${XRAY_RUNTIME_CONFIG_PATH}"; then
            : >"${RECOVERY_BAD_STATE}"
        fi
        return 0
    fi
    if [[ "${MUTATE_HANDLER_STATE}" -eq 1 ]]; then
        printf '{"mutatedBy":"%s"}\n' "$1" >"${SCRIPT_CONFIG_PATH}"
        printf '{"mutatedBy":"%s"}\n' "$1" >"${XRAY_RUNTIME_CONFIG_PATH}"
    fi
    [[ "$1" != "${FAILED_STAGE}" ]]
}

function choose_web_backend() {
    if [[ "${WEB_BACKEND_FORBIDDEN}" -eq 1 ]]; then
        echo "choose_web_backend must not run for this protocol" >&2
        return 1
    fi
    printf 'normal\n'
}

function choose_cdn_backend() {
    printf '%s\n' "${CDN_BACKEND_CHOICE}"
}

function assert_no_install_snapshots() {
    local leftovers=''

    leftovers="$(compgen -G "${SCRIPT_CONFIG_PATH}.install.*" || true)"
    leftovers+="${leftovers:+$'\n'}$(compgen -G "${XRAY_RUNTIME_CONFIG_PATH}.install.*" || true)"
    if [[ -n "${leftovers}" ]]; then
        echo "Install snapshot was not removed:" >&2
        printf '%s\n' "${leftovers}" >&2
        return 1
    fi
}

function restore_flow_baseline() {
    cp "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}"
    cp "${RUNTIME_BASELINE}" "${XRAY_RUNTIME_CONFIG_PATH}"
}

: >"${FLOW_LOG}"
install_protocol CDN
cat >"${TEST_DIR}/cdn.expected" <<'EOF'
--script-config CDN
--install
--cdn-backend nginx
--nginx-install
--xray-config normal
--restart
--share
EOF
diff -u "${TEST_DIR}/cdn.expected" "${FLOW_LOG}"
! grep -qi 'sni' "${FLOW_LOG}"
assert_no_install_snapshots

: >"${FLOW_LOG}"
CDN_BACKEND_CHOICE='xray'
WEB_BACKEND_FORBIDDEN=1
install_protocol CDN
cat >"${TEST_DIR}/cdn-direct.expected" <<'EOF'
--script-config CDN
--install
--cdn-backend xray
--xray-config
--restart
--share
EOF
diff -u "${TEST_DIR}/cdn-direct.expected" "${FLOW_LOG}"
! grep -q -- '--nginx-install' "${FLOW_LOG}"
assert_no_install_snapshots

: >"${FLOW_LOG}"
install_protocol hy2
cat >"${TEST_DIR}/hy2.expected" <<'EOF'
--script-config hy2
--install
--xray-config
--restart
--share
EOF
diff -u "${TEST_DIR}/hy2.expected" "${FLOW_LOG}"
! grep -q -- '--nginx-install' "${FLOW_LOG}"
assert_no_install_snapshots

# Every failed stage restores both snapshots before invoking runtime recovery.
# Recovery must be the immediate next handler action and share must not run.
CDN_BACKEND_CHOICE='nginx'
WEB_BACKEND_FORBIDDEN=0
MUTATE_HANDLER_STATE=1
for FAILED_STAGE in --script-config --install --cdn-backend --nginx-install --xray-config --restart; do
    restore_flow_baseline
    : >"${FLOW_LOG}"
    rm -f -- "${RECOVERY_BAD_STATE}"
    if install_protocol CDN; then
        echo "install_protocol ignored failed stage: ${FAILED_STAGE}" >&2
        exit 1
    fi
    cmp -s "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}"
    cmp -s "${RUNTIME_BASELINE}" "${XRAY_RUNTIME_CONFIG_PATH}"
    [[ ! -e "${RECOVERY_BAD_STATE}" ]]
    [[ "$(tail -n 1 "${FLOW_LOG}")" == '--recover-runtime' ]]
    [[ "$(grep -Fxc -- '--recover-runtime' "${FLOW_LOG}")" -eq 1 ]]
    ! grep -q -- '--share' "${FLOW_LOG}"
    assert_no_install_snapshots
done

# A failed first installation has no runtime snapshot. Stop the process that
# may have loaded the newly generated file, then delete only that new runtime.
cp "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}"
rm -f -- "${XRAY_RUNTIME_CONFIG_PATH}"
FAILED_STAGE='--restart'
STOP_CALLS=0
rm -f -- "${STOP_BAD_RUNTIME}" "${STOP_BAD_SCRIPT}"
: >"${FLOW_LOG}"
if install_protocol CDN; then
    echo 'install_protocol ignored a failed first installation' >&2
    exit 1
fi
cmp -s "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}"
[[ ! -e "${XRAY_RUNTIME_CONFIG_PATH}" ]]
[[ ! -e "${STOP_BAD_RUNTIME}" ]]
[[ ! -e "${STOP_BAD_SCRIPT}" ]]
[[ "$(tail -n 1 "${FLOW_LOG}")" == '--stop' ]]
[[ "$(grep -Fxc -- '--stop' "${FLOW_LOG}")" -eq 1 ]]
! grep -q -- '--recover-runtime' "${FLOW_LOG}"
! grep -q -- '--share' "${FLOW_LOG}"
assert_no_install_snapshots

echo "Protocol flow tests passed"
