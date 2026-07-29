#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
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

source core/share.sh

function reset_public_host_lookup() {
    PUBLIC_HOST_LOOKUP_STATE='unattempted'
    PUBLIC_HOST_CACHE=''
}

function initialize_link_components() {
    CLIENT_CONFIG[remote_host]='192.0.2.10'
    CLIENT_CONFIG[port]='443'
    CLIENT_CONFIG[protocol]='vless'
    CLIENT_CONFIG[uuid]='11111111-2222-3333-4444-555555555555'
    CLIENT_CONFIG[password]=''
    CLIENT_CONFIG[seed]=''
    CLIENT_CONFIG[type]='kcp'
    CLIENT_CONFIG[flow]=''
    CLIENT_CONFIG[security]='none'
    CLIENT_CONFIG[server_name]=''
    CLIENT_CONFIG[public_key]=''
    CLIENT_CONFIG[short_id]=''
    CLIENT_CONFIG[path]=''
    CLIENT_CONFIG[mode]=''
    CLIENT_CONFIG[host]=''
    CLIENT_CONFIG[mldsa65_verify]=''
    XHTTP_EXTRA=''
    XHTTP_EXTRA_ENCODED=''
}

SCRIPT_CONFIG="$(jq '.xray.vlessEncEncryption = ""' config.json)"
XRAY_CONFIG='{"inbounds":[{},{"streamSettings":{"xhttpSettings":{}}}]}'
initialize_link_components

CLIENT_CONFIG[seed]='seed@%&#'
get_mkcp_share_link
[[ "${SHARE_LINK}" == \
    'vless://11111111-2222-3333-4444-555555555555@192.0.2.10:443?type=kcp&security=none&seed=seed%40%25%26%23&headerType=none' ]]

CLIENT_CONFIG[protocol]='trojan'
CLIENT_CONFIG[password]='p@ss%&#'
CLIENT_CONFIG[type]='xhttp'
CLIENT_CONFIG[security]='reality'
CLIENT_CONFIG[server_name]='example.com'
CLIENT_CONFIG[public_key]='public-key'
CLIENT_CONFIG[short_id]='abcd'
CLIENT_CONFIG[path]='/path'
get_trojan_share_link
[[ "${SHARE_LINK}" == \
    'trojan://p%40ss%25%26%23@192.0.2.10:443?type=xhttp&security=reality&sni=example.com&pbk=public-key&sid=abcd&spx=%2F&fp=chrome&path=%2Fpath' ]]

for valid_ip in \
    '192.0.2.1' \
    '2001:db8::1' \
    '2001:db8:0:1:2:3:4:5' \
    '::ffff:192.0.2.1'; do
    is_valid_ip_literal "${valid_ip}"
done
for invalid_ip in \
    '' \
    'not-an-ip' \
    '256.0.0.1' \
    '2001:::1' \
    '2001:db8::1::2'; do
    if is_valid_ip_literal "${invalid_ip}"; then
        echo "Invalid IP literal was accepted: ${invalid_ip}" >&2
        exit 1
    fi
done

# main() should stop before constructing or displaying a link when both public
# address services fail or return non-IP content.
function load_i18n() { :; }
function cache_json_data() { :; }
SHOWN_LINK=''
function show_config() {
    SHOWN_LINK="${SHARE_LINK}"
}

SCRIPT_CONFIG="$(jq '
    .xray.tag = "hy2" |
    .xray.port = 24443 |
    .xray.hy2CertDomain = "hy2.example.com"
' config.json)"
XRAY_CONFIG='{
    "inbounds": [
        {},
        {
            "port": 24443,
            "protocol": "hysteria",
            "settings": {"clients": [{"auth": "secret"}]},
            "streamSettings": {"network": "hysteria", "security": "tls"}
        }
    ]
}'

LOOKUP_LOG="${TEST_DIR}/empty-lookups.log"
function curl() {
    printf '%s\n' "$*" >>"${LOOKUP_LOG}"
    return 0
}
if main >"${TEST_DIR}/empty.out" 2>&1; then
    echo "Empty public-address lookup unexpectedly succeeded" >&2
    exit 1
fi
[[ "$(wc -l <"${LOOKUP_LOG}")" -eq 2 ]]
! grep -Eq '(hysteria2|vless|trojan|ss)://' "${TEST_DIR}/empty.out"

LOOKUP_LOG="${TEST_DIR}/invalid-lookups.log"
function curl() {
    printf '%s\n' "$*" >>"${LOOKUP_LOG}"
    printf '%s' 'not-an-ip'
}
if main >"${TEST_DIR}/invalid.out" 2>&1; then
    echo "Invalid public-address lookup unexpectedly succeeded" >&2
    exit 1
fi
[[ "$(wc -l <"${LOOKUP_LOG}")" -eq 2 ]]
! grep -Eq '(hysteria2|vless|trojan|ss)://' "${TEST_DIR}/invalid.out"

# A multi-node share resolves the public address once and reuses it for every
# inbound instead of issuing one external request per node.
SCRIPT_CONFIG="$(jq '
    .xray.tag = "multi" |
    .xray.port = 24443 |
    .xray.hy2CertDomain = "hy2.example.com" |
    .xray.nodes = [
        {tag:"hy2",name:"hy2-node",port:24443,hy2auth:"hy2-secret"},
        {tag:"ss2022",name:"ss-node",port:24444,ss2022Key:"c2VjcmV0"}
    ]
' config.json)"
XRAY_CONFIG='{
    "inbounds": [
        {},
        {
            "port": 24443,
            "protocol": "hysteria",
            "settings": {"clients": [{"auth": "hy2-secret"}]},
            "streamSettings": {"network": "hysteria", "security": "tls"}
        },
        {
            "port": 24444,
            "protocol": "shadowsocks",
            "settings": {"method": "2022-blake3-aes-256-gcm", "password": "c2VjcmV0"},
            "streamSettings": {"network": "tcp"}
        }
    ]
}'
LOOKUP_LOG="${TEST_DIR}/multi-lookups.log"
function curl() {
    printf '%s\n' "$*" >>"${LOOKUP_LOG}"
    printf '%s' '198.51.100.20'
}
reset_public_host_lookup
show_multi_config
[[ "$(wc -l <"${LOOKUP_LOG}")" -eq 1 ]]

# CDN and SNI already have configured connection hosts. Their normal main()
# paths must not call an external public-address service.
LOOKUP_LOG="${TEST_DIR}/configured-host-lookups.log"
function curl() {
    printf '%s\n' "$*" >>"${LOOKUP_LOG}"
    return 1
}

SCRIPT_CONFIG="$(jq '
    .xray.tag = "cdn" |
    .xray.port = 443 |
    .xray.uuid = "11111111-2222-3333-4444-555555555555" |
    .xray.path = "/cdn-path" |
    .xray.xhttpMode = "auto" |
    .xray.vlessEncEncryption = "" |
    .nginx.cdn = "cdn.example.com"
' config.json)"
XRAY_CONFIG='{
    "inbounds": [
        {},
        {
            "protocol": "vless",
            "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555"}]},
            "streamSettings": {
                "network": "xhttp",
                "xhttpSettings": {"path": "/cdn-path", "mode": "auto"}
            }
        }
    ]
}'
SHOWN_LINK=''
main
[[ "${SHOWN_LINK}" == vless://*@cdn.example.com:443\?* ]]
[[ ! -e "${LOOKUP_LOG}" ]]

SCRIPT_CONFIG="$(jq '
    .xray.tag = "sni" |
    .xray.port = 443 |
    .xray.uuid = "11111111-2222-3333-4444-555555555555" |
    .xray.fallback = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" |
    .xray.path = "/sni-path" |
    .xray.publicKey = "public-key" |
    .xray.vlessEncEncryption = "" |
    .nginx.domain = "origin.example.com" |
    .nginx.cdn = "cdn.example.com"
' config.json)"
XRAY_CONFIG='{
    "inbounds": [
        {},
        {
            "port": 443,
            "protocol": "vless",
            "settings": {"clients": [{"id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision"}]},
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {"serverNames": ["target.example.com"], "shortIds": ["abcd"]},
                "xhttpSettings": {}
            }
        },
        {
            "protocol": "vless",
            "settings": {"clients": [{"id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}]},
            "streamSettings": {
                "network": "xhttp",
                "security": "reality",
                "realitySettings": {"serverNames": ["target.example.com"], "shortIds": ["ef01"]},
                "xhttpSettings": {"path": "/sni-path", "mode": "auto"}
            }
        }
    ]
}'
SHOWN_LINK=''
main
[[ -n "${SHOWN_LINK}" ]]
[[ ! -e "${LOOKUP_LOG}" ]]

echo "Share safety tests passed"
