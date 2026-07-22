#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
export TEST_PROJECT_ROOT
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

mkdir -p "${TEST_DIR}/home/.xray-script"
cp config.json "${TEST_DIR}/script.json"
cp config.json "${TEST_DIR}/home/.xray-script/config.json"
export HOME="${TEST_DIR}/home"
export SCRIPT_CONFIG_PATH_OVERRIDE="${TEST_DIR}/script.json"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/xray.json"

source core/handler.sh
I18N_DATA="$(jq . i18n/en.json)"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=hy2.example.com' \
    -addext 'subjectAltName=DNS:hy2.example.com' \
    -keyout "${TEST_DIR}/hy2.key" \
    -out "${TEST_DIR}/hy2.crt" >/dev/null 2>&1

reset_config_data
read_hy2_certificate_config <<EOF
3
${TEST_DIR}/hy2.crt
${TEST_DIR}/hy2.key

EOF

[[ "${CONFIG_DATA['hy2_cert_source']}" == '3' ]]
[[ "${CONFIG_DATA['hy2_cert_domain']}" == 'hy2.example.com' ]]
validate_tls_certificate_pair "${TEST_DIR}/hy2.crt" "${TEST_DIR}/hy2.key"
certificate_matches_server_name "${TEST_DIR}/hy2.crt" 'hy2.example.com'
! certificate_matches_server_name "${TEST_DIR}/hy2.crt" 'wrong.example.com'

SCRIPT_CONFIG="$(jq \
    --arg cert "${TEST_DIR}/hy2.crt" \
    --arg key "${TEST_DIR}/hy2.key" '
    .xray.tag = "hy2" |
    .xray.port = 24443 |
    .xray.hy2auth = "p@ss:/?#" |
    .xray.hy2CertSource = "3" |
    .xray.hy2CertDomain = "hy2.example.com" |
    .xray.hy2CertFullchain = $cert |
    .xray.hy2CertPrivkey = $key |
    .xray.rules = {reset:1,bt:0,cn:0,ad:0} |
    .xray.warp = 0 |
    .rules = []
' config.json)"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"

function open_xray_firewall_port() { :; }
function handler_lan_open_firewall() { :; }
handler_xray_config 1

jq -e '
    .inbounds[1].protocol == "hysteria" and
    .inbounds[1].port == 24443 and
    .inbounds[1].settings.version == 2 and
    .inbounds[1].settings.clients[0].auth == "p@ss:/?#" and
    (.inbounds[1].settings | has("users") | not) and
    .inbounds[1].streamSettings.network == "hysteria" and
    .inbounds[1].streamSettings.security == "tls" and
    .inbounds[1].streamSettings.hysteriaSettings.auth == "p@ss:/?#" and
    .inbounds[1].streamSettings.hysteriaSettings.udpIdleTimeout == 60 and
    .inbounds[1].streamSettings.tlsSettings.alpn == ["h3"] and
    .inbounds[1].streamSettings.tlsSettings.certificates[0].usage == "encipherment" and
    (.inbounds[1].streamSettings.tlsSettings | has("serverName") | not)
' "${XRAY_CONFIG_PATH}" >/dev/null

xray_bin="${XRAY_BIN:-$(command -v xray || true)}"
if [[ -n "${xray_bin}" ]]; then
    jq --arg cert "${TEST_DIR}/hy2.crt" --arg key "${TEST_DIR}/hy2.key" '
        .log.error = "" |
        .log.access = "" |
        .inbounds[1].streamSettings.tlsSettings.certificates[0].certificateFile = $cert |
        .inbounds[1].streamSettings.tlsSettings.certificates[0].keyFile = $key
    ' "${XRAY_CONFIG_PATH}" >"${TEST_DIR}/xray-test.json"
    "${xray_bin}" run -test -c "${TEST_DIR}/xray-test.json"
fi

SHARE_LINK="$(command bash -c '
    set -euo pipefail
    cd "${TEST_PROJECT_ROOT}"
    source core/share.sh
    CLIENT_CONFIG[hy2_auth]="p@ss:/?#"
    CLIENT_CONFIG[remote_host]="2001:db8::1"
    CLIENT_CONFIG[port]="24443"
    CLIENT_CONFIG[hy2_cert_domain]="hy2.example.com"
    get_hy2_share_link
    printf "%s" "${SHARE_LINK}"
')"
[[ "${SHARE_LINK}" == 'hysteria2://p%40ss%3A%2F%3F%23@[2001:db8::1]:24443/?insecure=0&sni=hy2.example.com' ]]

ENCODED_TAG="$(command bash -c '
    set -euo pipefail
    cd "${TEST_PROJECT_ROOT}"
    source core/share.sh
    urlencode "节点"
')"
[[ "${ENCODED_TAG}" == '%E8%8A%82%E7%82%B9' ]]

echo "HY2 config tests passed"
