#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

readonly GREEN=''
readonly YELLOW=''
readonly RED=''
readonly NC=''
SCRIPT_CONFIG_DIR="${TEST_DIR}"
CONFIG_DIR="${PROJECT_ROOT}/config"
SCRIPT_CONFIG_PATH="${TEST_DIR}/script.json"
I18N_DATA="$(jq . i18n/en.json)"
SCRIPT_CONFIG="$(jq '
    .xray.lan = {
        enabled: 1,
        role: "hub",
        port: 19443,
        target: "www.example.com",
        serverName: "www.example.com",
        serverAddress: "203.0.113.10",
        privateKey: "test-private-key",
        publicKey: "test-public-key",
        shortId: "0123456789abcdef",
        tunName: "xray0",
        mtu: 1400,
        sites: [
            {
                id: "home",
                name: "Home",
                localCidrs: ["192.168.10.0/24"],
                mode: "gateway",
                lanInterface: "eth1",
                accessUuid: "11111111-1111-1111-1111-111111111111",
                reverseUuid: "11111111-1111-1111-1111-222222222222",
                reverseTag: "lan-reverse-home"
            },
            {
                id: "office",
                name: "Office",
                localCidrs: ["192.168.20.0/24"],
                mode: "host",
                lanInterface: "",
                accessUuid: "22222222-2222-2222-2222-111111111111",
                reverseUuid: "22222222-2222-2222-2222-222222222222",
                reverseTag: "lan-reverse-office"
            }
        ]
    }
' config.json)"
XRAY_CONFIG="$(jq . config/xray/Vision.json)"

source core/lan.sh
handler_apply_lan_config

jq -e '([.inbounds[] | select(.tag == "lan-hub-in")] | length) == 1' <<<"${XRAY_CONFIG}" >/dev/null
jq -e '(.inbounds[] | select(.tag == "lan-hub-in") | .settings.clients | length) == 4' <<<"${XRAY_CONFIG}" >/dev/null
jq -e '
    [.inbounds[] | select(.tag == "lan-hub-in") | .settings.clients[] | select(.reverse) | .reverse.tag] | sort
    == ["lan-reverse-home", "lan-reverse-office"]
' <<<"${XRAY_CONFIG}" >/dev/null
jq -e '
    (.routing.rules | map(.ruleTag) | index("lan-route-office"))
    < (.routing.rules | map(.ruleTag) | index("private-ip"))
' <<<"${XRAY_CONFIG}" >/dev/null
jq -e '(.routing.rules[] | select(.ruleTag == "lan-deny-undeclared") | .user | length) == 4' <<<"${XRAY_CONFIG}" >/dev/null

handler_apply_lan_config
jq -e '([.inbounds[] | select(.tag == "lan-hub-in")] | length) == 1' <<<"${XRAY_CONFIG}" >/dev/null

handler_lan_export_site <<<"home" >/dev/null 2>/dev/null
jq -e '
    .inbounds[0].protocol == "tun" and
    .inbounds[0].settings.name == "xray0" and
    .inbounds[0].settings.MTU == 1400
' "${TEST_DIR}/lan/home/config.json" >/dev/null
jq -e '
    any(.outbounds[];
        .tag == "lan-reverse-to-hub" and
        .settings.reverse.tag == "lan-in-home"
    )
' "${TEST_DIR}/lan/home/config.json" >/dev/null
jq -e '
    .remoteCidrs == ["192.168.20.0/24"] and
    .localCidrs == ["192.168.10.0/24"]
' "${TEST_DIR}/lan/home/site.json" >/dev/null

SCRIPT_CONFIG="$(jq '.xray.lan.enabled = 0' <<<"${SCRIPT_CONFIG}")"
handler_apply_lan_config
jq -e 'all(.inbounds[]; (((.tag // "") | startswith("lan-")) | not))' <<<"${XRAY_CONFIG}" >/dev/null
jq -e 'all(.routing.rules[]; (.ruleTag // "") != "lan-deny-undeclared")' <<<"${XRAY_CONFIG}" >/dev/null
jq -e 'all(.routing.rules[]; (((.ruleTag // "") | startswith("lan-route-")) | not))' <<<"${XRAY_CONFIG}" >/dev/null

test "$(lan_normalize_cidr '192.168.20.42/24')" = "192.168.20.0/24"
! lan_normalize_cidr '8.8.8.0/24' >/dev/null
lan_cidrs_overlap '192.168.10.0/24' '192.168.10.128/25'
! lan_cidrs_overlap '192.168.10.0/24' '192.168.11.0/24'

echo "LAN config tests passed"
