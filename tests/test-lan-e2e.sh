#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
readonly TEST_DIR="$(mktemp -d)"
readonly HOME_NS="xray-lan-home"
readonly OFFICE_NS="xray-lan-office"
readonly TEST_BRIDGE="xray-lan-br0"
readonly HUB_PORT=39443
readonly TARGET_PORT=39444
PIDS=''

function cleanup() {
    local status=$?
    set +e
    local pid
    for pid in ${PIDS}; do
        kill "${pid}" 2>/dev/null
    done
    ip netns del "${HOME_NS}" 2>/dev/null
    ip netns del "${OFFICE_NS}" 2>/dev/null
    ip link del "${TEST_BRIDGE}" 2>/dev/null
    rm -rf "${TEST_DIR}"
    exit "${status}"
}
trap cleanup EXIT

[[ ${EUID} -eq 0 ]] || { echo "This test requires root." >&2; exit 1; }
for command_name in xray jq ip openssl perl; do
    command -v "${command_name}" >/dev/null 2>&1 || { echo "Missing command: ${command_name}" >&2; exit 1; }
done

cd "${PROJECT_ROOT}"
ip netns del "${HOME_NS}" 2>/dev/null || true
ip netns del "${OFFICE_NS}" 2>/dev/null || true
ip link del "${TEST_BRIDGE}" 2>/dev/null || true

openssl req -x509 -newkey rsa:2048 -nodes -subj '/CN=lan.test' \
    -keyout "${TEST_DIR}/target.key" -out "${TEST_DIR}/target.crt" -days 1 >/dev/null 2>&1
openssl s_server -accept "${TARGET_PORT}" -cert "${TEST_DIR}/target.crt" \
    -key "${TEST_DIR}/target.key" -www -tls1_3 >"${TEST_DIR}/tls.log" 2>&1 &
PIDS+=" $!"

KEYS="$(xray x25519)"
PRIVATE_KEY="$(sed -n '1s/.*: *//p' <<<"${KEYS}")"
PUBLIC_KEY="$(sed -n '2s/.*: *//p' <<<"${KEYS}")"
readonly GREEN=''
readonly YELLOW=''
readonly RED=''
readonly NC=''
SCRIPT_CONFIG_DIR="${TEST_DIR}"
CONFIG_DIR="${PROJECT_ROOT}/config"
SCRIPT_CONFIG_PATH="${TEST_DIR}/script.json"
I18N_DATA="$(jq . i18n/en.json)"
SCRIPT_CONFIG="$(jq --arg privateKey "${PRIVATE_KEY}" --arg publicKey "${PUBLIC_KEY}" --argjson port "${HUB_PORT}" '
    .xray.lan = {
        enabled: 1,
        role: "hub",
        port: $port,
        target: "lan.test",
        serverName: "lan.test",
        serverAddress: "10.253.77.1",
        privateKey: $privateKey,
        publicKey: $publicKey,
        shortId: "0123456789abcdef",
        tunName: "xray0",
        mtu: 1400,
        sites: [
            {
                id: "home", name: "Home", localCidrs: ["192.168.221.0/24"],
                mode: "host", lanInterface: "",
                accessUuid: "11111111-1111-1111-1111-111111111111",
                reverseUuid: "11111111-1111-1111-1111-222222222222",
                reverseTag: "lan-reverse-home"
            },
            {
                id: "office", name: "Office", localCidrs: ["192.168.222.0/24"],
                mode: "host", lanInterface: "",
                accessUuid: "22222222-2222-2222-2222-111111111111",
                reverseUuid: "22222222-2222-2222-2222-222222222222",
                reverseTag: "lan-reverse-office"
            }
        ]
    }
' config.json)"
XRAY_CONFIG='{
    "log":{"loglevel":"warning"},
    "routing":{"rules":[{"ruleTag":"private-ip","ip":["geoip:private"],"outboundTag":"block"}]},
    "inbounds":[],
    "outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}]
}'
source core/lan.sh
handler_apply_lan_config
XRAY_CONFIG="$(jq --arg target "127.0.0.1:${TARGET_PORT}" '
    (.inbounds[] | select(.tag == "lan-hub-in") | .streamSettings.realitySettings.dest) = $target
' <<<"${XRAY_CONFIG}")"
printf '%s\n' "${XRAY_CONFIG}" >"${TEST_DIR}/hub.json"
handler_lan_export_site <<<"home" >/dev/null 2>/dev/null
handler_lan_export_site <<<"office" >/dev/null 2>/dev/null

ip link add "${TEST_BRIDGE}" type bridge
ip addr add 10.253.77.1/24 dev "${TEST_BRIDGE}"
ip link set "${TEST_BRIDGE}" up
ip netns add "${HOME_NS}"
ip netns add "${OFFICE_NS}"
ip link add xlh-root type veth peer name eth0 netns "${HOME_NS}"
ip link add xlo-root type veth peer name eth0 netns "${OFFICE_NS}"
ip link set xlh-root master "${TEST_BRIDGE}"
ip link set xlo-root master "${TEST_BRIDGE}"
ip link set xlh-root up
ip link set xlo-root up
ip -n "${HOME_NS}" link set lo up
ip -n "${HOME_NS}" link set eth0 up
ip -n "${HOME_NS}" addr add 10.253.77.2/24 dev eth0
ip -n "${OFFICE_NS}" link set lo up
ip -n "${OFFICE_NS}" link set eth0 up
ip -n "${OFFICE_NS}" addr add 10.253.77.3/24 dev eth0
ip -n "${OFFICE_NS}" addr add 192.168.222.10/32 dev lo

xray run -config "${TEST_DIR}/hub.json" >"${TEST_DIR}/hub.log" 2>&1 &
PIDS+=" $!"
ip netns exec "${OFFICE_NS}" xray run -config "${TEST_DIR}/lan/office/config.json" >"${TEST_DIR}/office.log" 2>&1 &
PIDS+=" $!"
ip netns exec "${HOME_NS}" xray run -config "${TEST_DIR}/lan/home/config.json" >"${TEST_DIR}/home.log" 2>&1 &
PIDS+=" $!"

for _ in $(seq 1 100); do
    if ip -n "${HOME_NS}" link show xray0 >/dev/null 2>&1 && ip -n "${OFFICE_NS}" link show xray0 >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
ip -n "${HOME_NS}" link show xray0 >/dev/null
ip -n "${OFFICE_NS}" link show xray0 >/dev/null
ip -n "${HOME_NS}" route add 192.168.222.0/24 dev xray0 metric 5
ip -n "${OFFICE_NS}" route add 192.168.221.0/24 dev xray0 metric 5

ip netns exec "${OFFICE_NS}" perl -MIO::Socket::INET -e '
    $s=IO::Socket::INET->new(LocalAddr=>"192.168.222.10",LocalPort=>18080,Listen=>5,Reuse=>1) or die $!;
    while($c=$s->accept){print $c "XRAY_LAN_OK\n"; close $c}
' >"${TEST_DIR}/server.log" 2>&1 &
PIDS+=" $!"
sleep 3

RESULT="$(ip netns exec "${HOME_NS}" perl -MIO::Socket::INET -e '
    $s=IO::Socket::INET->new(PeerAddr=>"192.168.222.10",PeerPort=>18080,Timeout=>10) or die $!;
    print scalar(<$s>)
')"
if [[ "${RESULT}" != "XRAY_LAN_OK" ]]; then
    cat "${TEST_DIR}/hub.log" "${TEST_DIR}/home.log" "${TEST_DIR}/office.log" >&2
    exit 1
fi

echo "Xray LAN end-to-end test passed: ${RESULT}"
