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

source lib/protocols.sh

expected=(Vision XHTTP Trojan Fallback hy2 ss2022 mKCP CDN SNI multi)
for index in "${!expected[@]}"; do
    choice=$((index + 1))
    [[ "$(protocol_from_menu_choice "${choice}")" == "${expected[${index}]}" ]]
done
! protocol_from_menu_choice 0
! protocol_from_multi_menu_choice 0

protocol_uses_vless_enc CDN
protocol_uses_nginx CDN
protocol_uses_xhttp CDN
! protocol_uses_reality CDN
! protocol_reads_public_port CDN
protocol_uses_reality SNI
protocol_uses_hy2_certificate hy2
! protocol_uses_hy2_certificate Vision

menu_status=0
bash core/menu.sh --config <<<"" >/dev/null 2>&1 || menu_status=$?
[[ "${menu_status}" -eq 1 ]]
menu_status=0
bash core/menu.sh --xray <<<"" >/dev/null 2>&1 || menu_status=$?
[[ "${menu_status}" -eq 2 ]]
menu_status=0
bash core/menu.sh --web <<<"" >/dev/null 2>&1 || menu_status=$?
[[ "${menu_status}" -eq 1 ]]
bash core/menu.sh --config <<<"0" >/dev/null 2>&1

source core/main.sh

FLOW_LOG="${TEST_DIR}/flow.log"
function exec_handler() { printf '%s\n' "$*" >>"${FLOW_LOG}"; }
function choose_web_backend() { printf 'normal\n'; }

: >"${FLOW_LOG}"
install_protocol CDN
cat >"${TEST_DIR}/cdn.expected" <<'EOF'
--script-config CDN
--install
--nginx-install
--xray-config normal
--restart
--share
EOF
diff -u "${TEST_DIR}/cdn.expected" "${FLOW_LOG}"
! grep -qi 'sni' "${FLOW_LOG}"

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

# A failed stage must stop the unified flow before later services are touched.
function exec_handler() {
    printf '%s\n' "$*" >>"${FLOW_LOG}"
    [[ "$1" != '--install' ]]
}
: >"${FLOW_LOG}"
if install_protocol CDN; then
    echo 'install_protocol ignored a failed Xray installation' >&2
    exit 1
fi
cat >"${TEST_DIR}/failed.expected" <<'EOF'
--script-config CDN
--install
EOF
diff -u "${TEST_DIR}/failed.expected" "${FLOW_LOG}"

echo "Protocol flow tests passed"
