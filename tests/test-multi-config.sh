#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

mkdir -p "${TEST_DIR}/home/.xray-script"
cp config.json "${TEST_DIR}/script.json"
cp config.json "${TEST_DIR}/home/.xray-script/config.json"
export HOME="${TEST_DIR}/home"
export SCRIPT_CONFIG_PATH_OVERRIDE="${TEST_DIR}/script.json"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/xray.json"

source core/handler.sh
I18N_DATA="$(jq . i18n/en.json)"

[[ "$(read_multi_protocol_tag 1 <<<"")" == 'Vision' ]]

declare -A EXPECTED_FIELDS=(
    [mKCP]='uuid seed'
    [Vision]='uuid target short'
    [XHTTP]='uuid target short path xhttp-mode'
    [Trojan]='password target short path xhttp-mode'
    [Fallback]='uuid fallback target short path xhttp-mode'
    [hy2]='hy2-auth'
    [ss2022]='ss2022-password'
)
readonly PROTOCOLS=(mKCP Vision XHTTP Trojan Fallback hy2 ss2022)

READ_LOG=()
PORT_READ_COUNT=0
function exec_read() {
    local field="$1"
    READ_LOG+=("${field}")
    case "${field}" in
    rules) CONFIG_DATA["${field}"]='N' ;;
    port)
        PORT_READ_COUNT=$((PORT_READ_COUNT + 1))
        CONFIG_DATA["${field}"]="$((21000 + PORT_READ_COUNT))"
        ;;
    uuid) CONFIG_DATA["${field}"]='11111111-1111-1111-1111-111111111111' ;;
    fallback) CONFIG_DATA["${field}"]='22222222-2222-2222-2222-222222222222' ;;
    seed) CONFIG_DATA["${field}"]='mkcp-seed-value' ;;
    password) CONFIG_DATA["${field}"]='trojan-password' ;;
    hy2-auth) CONFIG_DATA["${field}"]='hy2-password' ;;
    ss2022-password) CONFIG_DATA["${field}"]='MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=' ;;
    target) CONFIG_DATA["${field}"]='example.com' ;;
    path) CONFIG_DATA["${field}"]='/test-path' ;;
    xhttp-mode) CONFIG_DATA["${field}"]='auto' ;;
    short)
        CONFIG_DATA["${field}"]='0123456789abcdef'
        CONFIG_DATA['short_ids']='0123456789abcdef'
        ;;
    *) CONFIG_DATA["${field}"]="test-${field}" ;;
    esac
    return 0
}

function assert_protocol_fields() {
    local protocol="$1"
    local actual expected
    READ_LOG=()
    reset_config_data
    CONFIG_DATA['tag']="${protocol}"
    read_multi_node_protocol_fields "${protocol}"
    actual="${READ_LOG[*]}"
    expected="${EXPECTED_FIELDS[${protocol}]}"
    [[ "${actual}" == "${expected}" ]] || {
        echo "${protocol}: expected fields '${expected}', got '${actual}'" >&2
        return 1
    }
}

# Every ordered protocol pair exercises the reset boundary used between nodes.
for first in "${PROTOCOLS[@]}"; do
    for second in "${PROTOCOLS[@]}"; do
        assert_protocol_fields "${first}"
        assert_protocol_fields "${second}"
    done
done

function exec_generate() {
    local option="$1"
    shift || true
    case "${option}" in
    --uuid) echo '11111111-1111-1111-1111-111111111111' ;;
    --password) echo 'generated-password' ;;
    --ss2022-key) echo 'MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=' ;;
    --target) echo 'example.com' ;;
    --server-names) printf '["%s"]\n' "$1" ;;
    --short-ids) echo '["0123456789abcdef"]' ;;
    --path) echo '/generated-path' ;;
    --port) echo '40000' ;;
    *) return 1 ;;
    esac
}

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=example.com' \
    -addext 'subjectAltName=DNS:example.com' \
    -keyout "${TEST_DIR}/key.pem" \
    -out "${TEST_DIR}/cert.pem" >/dev/null 2>&1
function run_vlessenc_choice() {
    CONFIG_DATA['vless_enc_enable']='n'
}

READ_LOG=()
PORT_READ_COUNT=0
handler_read_multi_xray_config <<EOF
7
7
1
2
3
4
5
6
3
${TEST_DIR}/cert.pem
${TEST_DIR}/key.pem

EOF

expected_read_order='rules port uuid seed port uuid target short port uuid target short path xhttp-mode port password target short path xhttp-mode port uuid fallback target short path xhttp-mode port hy2-auth port ss2022-password'
[[ "${READ_LOG[*]}" == "${expected_read_order}" ]] || {
    echo "Unexpected integrated read order: ${READ_LOG[*]}" >&2
    exit 1
}
jq -e '
    map(.tag) == ["mKCP","Vision","XHTTP","Trojan","Fallback","hy2","ss2022"] and
    (.[1] | has("hy2auth") | not) and
    (.[5] | keys | sort) == ["hy2auth","name","port","tag"] and
    (.[6] | keys | sort) == ["name","port","ss2022Key","tag"]
' <<<"${CONFIG_DATA['nodes_json']}" >/dev/null

function configure_node_data() {
    local protocol="$1"
    reset_config_data
    CONFIG_DATA['tag']="${protocol}"
    case "${protocol,,}" in
    mkcp)
        CONFIG_DATA['uuid']='11111111-1111-1111-1111-111111111111'
        CONFIG_DATA['seed']='mkcp-seed-value'
        ;;
    vision)
        CONFIG_DATA['uuid']='22222222-2222-2222-2222-222222222222'
        CONFIG_DATA['target']='example.com'
        CONFIG_DATA['short_ids']='0123456789abcdef'
        ;;
    xhttp)
        CONFIG_DATA['uuid']='33333333-3333-3333-3333-333333333333'
        CONFIG_DATA['target']='example.com'
        CONFIG_DATA['short_ids']='0123456789abcdee'
        CONFIG_DATA['path']='/xhttp-test'
        CONFIG_DATA['xhttp-mode']='auto'
        ;;
    trojan)
        CONFIG_DATA['password']='trojan-password'
        CONFIG_DATA['target']='example.com'
        CONFIG_DATA['short_ids']='0123456789abcded'
        CONFIG_DATA['path']='/trojan-test'
        CONFIG_DATA['xhttp-mode']='packet-up'
        ;;
    fallback)
        CONFIG_DATA['uuid']='44444444-4444-4444-4444-444444444444'
        CONFIG_DATA['fallback']='55555555-5555-5555-5555-555555555555'
        CONFIG_DATA['target']='example.com'
        CONFIG_DATA['short_ids']='0123456789abcdec'
        CONFIG_DATA['path']='/fallback-test'
        CONFIG_DATA['xhttp-mode']='stream-up'
        ;;
    hy2)
        CONFIG_DATA['hy2-auth']='hy2-password'
        ;;
    ss2022)
        CONFIG_DATA['ss2022-password']='MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY='
        ;;
    esac
}

declare -A EXPECTED_KEYS=(
    [mKCP]='["kcp","name","port","tag","uuid"]'
    [Vision]='["name","port","serverNames","shortIds","tag","target","uuid"]'
    [XHTTP]='["name","path","port","serverNames","shortIds","tag","target","uuid","xhttpMode"]'
    [Trojan]='["name","path","port","serverNames","shortIds","tag","target","trojan","xhttpMode"]'
    [Fallback]='["fallback","name","path","port","serverNames","shortIds","tag","target","uuid","xhttpMode"]'
    [hy2]='["hy2auth","name","port","tag"]'
    [ss2022]='["name","port","ss2022Key","tag"]'
)

nodes='[]'
port=20000
index=1
for round in 1 2; do
    for protocol in "${PROTOCOLS[@]}"; do
        configure_node_data "${protocol}"
        node="$(build_multi_node_json "${protocol}" "${index}" "${port}")"
        actual_keys="$(jq -cS 'keys' <<<"${node}")"
        [[ "${actual_keys}" == "${EXPECTED_KEYS[${protocol}]}" ]] || {
            echo "${protocol}: unexpected node keys ${actual_keys}" >&2
            exit 1
        }
        nodes="$(jq --argjson node "${node}" '. + [$node]' <<<"${nodes}")"
        port=$((port + 1))
        index=$((index + 1))
    done
done

# Reserved API and duplicate node ports must never survive allocation.
[[ "$(generate_unique_multi_port 32768 Vision)" == '40000' ]]
[[ "$(generate_unique_multi_port 20000 Vision 20000)" == '40000' ]]
[[ "$(generate_unique_multi_port '' Vision)" == '443' ]]

private_key='test-private-key'
xray_bin="${XRAY_BIN:-$(command -v xray || true)}"
if [[ -n "${xray_bin}" ]]; then
    private_key="$(${xray_bin} x25519 | sed -n '1s/.*:[[:space:]]*//p')"
fi

SCRIPT_CONFIG="$(jq \
    --argjson nodes "${nodes}" \
    --arg privateKey "${private_key}" '
    .xray.tag = "multi" |
    .xray.nodes = $nodes |
    .xray.privateKey = $privateKey |
    .xray.mldsa65Seed = "" |
    .xray.vlessEncEnable = "n" |
    .xray.rules = {reset:1,bt:1,cn:1,ad:1} |
    .xray.warp = 0 |
    .xray.reverse = 0 |
    .xray.lan.enabled = 0 |
    .rules = []
' config.json)"

function open_xray_firewall_port() { :; }
function handler_lan_open_firewall() { :; }
handler_multi_xray_config 1

jq -e '
    (.inbounds | length) == 19 and
    ([.inbounds[].tag] | unique | length) == 19 and
    ([.inbounds[] | select(.port? == 32768 and .tag != "api")] | length) == 0 and
    ([.inbounds[] | select(.protocol == "vless")] | length) == 10 and
    ([.inbounds[] | select(.protocol == "trojan")] | length) == 2 and
    ([.inbounds[] | select(.protocol == "hysteria")] | length) == 2 and
    all(.inbounds[] | select(.protocol == "hysteria");
        .settings.clients[0].auth == "hy2-password" and
        .streamSettings.hysteriaSettings.auth == "hy2-password" and
        .streamSettings.hysteriaSettings.udpIdleTimeout == 60 and
        .streamSettings.tlsSettings.certificates[0].usage == "encipherment") and
    ([.inbounds[] | select(.protocol == "shadowsocks")] | length) == 2 and
    all(.inbounds[] | select(.streamSettings.network? == "kcp");
        .streamSettings.finalmask.udp[0].type == "mkcp-aes128gcm" and
        .streamSettings.finalmask.udp[0].settings.password == "mkcp-seed-value") and
    any(.routing.rules[]; .ruleTag == "bt") and
    any(.routing.rules[]; .ruleTag == "cn-ip") and
    any(.routing.rules[]; .ruleTag == "ad-domain")
' "${XRAY_CONFIG_PATH}" >/dev/null

valid_ss2022='MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY='
bash core/check.sh --ss2022-key "${valid_ss2022}" >/dev/null 2>&1
! bash core/check.sh --ss2022-key 'not-a-valid-key' >/dev/null 2>&1
bash core/check.sh --port '00443' >/dev/null 2>&1
! bash core/check.sh --port '32768' >/dev/null 2>&1
! bash core/check.sh --port 'not-a-port' >/dev/null 2>&1
for mode in auto packet-up stream-up stream-one; do
    bash core/check.sh --xhttp-mode "${mode}" >/dev/null 2>&1
done
! bash core/check.sh --xhttp-mode packet >/dev/null 2>&1

if [[ -n "${xray_bin}" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj '/CN=example.com' \
        -keyout "${TEST_DIR}/key.pem" \
        -out "${TEST_DIR}/cert.pem" >/dev/null 2>&1
    jq --arg cert "${TEST_DIR}/cert.pem" --arg key "${TEST_DIR}/key.pem" '
        .log.error = "" |
        .log.access = "" |
        (.inbounds[] | select(.protocol == "hysteria") |
            .streamSettings.tlsSettings.certificates[0].certificateFile) = $cert |
        (.inbounds[] | select(.protocol == "hysteria") |
            .streamSettings.tlsSettings.certificates[0].keyFile) = $key
    ' "${XRAY_CONFIG_PATH}" >"${TEST_DIR}/xray-test.json"
    "${xray_bin}" run -test -c "${TEST_DIR}/xray-test.json"
    jq '(.inbounds[] | select(.streamSettings.network? == "xhttp") |
        .streamSettings.xhttpSettings.mode) = "stream-one"' \
        "${TEST_DIR}/xray-test.json" >"${TEST_DIR}/xray-stream-one.json"
    "${xray_bin}" run -test -c "${TEST_DIR}/xray-stream-one.json" >/dev/null
fi

echo "Multi-protocol config tests passed"
