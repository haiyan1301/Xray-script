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
export XRAY_CERT_DIR_OVERRIDE="${TEST_DIR}/xray-certs"

source core/handler.sh
I18N_DATA="$(jq . i18n/en.json)"

[[ "$(read_multi_protocol_tag 1 <<<"")" == 'Vision' ]]

# The legacy quick entry point supports closed stdin. Its historical defaults
# remain VLESS enc enabled and ML-DSA-65 disabled, while normal questionnaires
# still fail on an unanswered EOF.
reset_config_data
# Sourced from handler.sh; later definitions in this file are test doubles.
# shellcheck disable=SC2218
run_vlessenc_choice 'y' </dev/null 2>/dev/null
[[ "${CONFIG_DATA['vless_enc_enable']}" == 'y' ]]
reset_config_data
# shellcheck disable=SC2218
run_mldsa65_choice 'n' </dev/null 2>/dev/null
[[ "${CONFIG_DATA['mldsa65_enable']}" == 'n' ]]
reset_config_data
if run_vlessenc_choice </dev/null 2>/dev/null; then
    echo 'Normal VLESS enc questionnaire accepted an unanswered EOF' >&2
    exit 1
fi
if run_mldsa65_choice </dev/null 2>/dev/null; then
    echo 'Normal ML-DSA-65 questionnaire accepted an unanswered EOF' >&2
    exit 1
fi

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
RULES_REPLY='N'
CAPTURE_INPUT_FLOW=0
INPUT_FLOW=()
function exec_read() {
    local field="$1"
    READ_LOG+=("${field}")
    if [[ "${CAPTURE_INPUT_FLOW}" -eq 1 ]]; then
        INPUT_FLOW+=("${field}")
    fi
    case "${field}" in
    rules) CONFIG_DATA["${field}"]="${RULES_REPLY}" ;;
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
    --mldsa65) echo 'generated-mldsa-seed,generated-mldsa-verify' ;;
    *) return 1 ;;
    esac
}

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=example.com' \
    -addext 'subjectAltName=DNS:example.com' \
    -keyout "${TEST_DIR}/key.pem" \
    -out "${TEST_DIR}/cert.pem" >/dev/null 2>&1
MULTI_HY2_CERT_DIR="$(get_hy2_cert_dir 'example.com' '3')"
install_custom_xray_certificate_pair_in_place \
    "${TEST_DIR}/cert.pem" \
    "${TEST_DIR}/key.pem" \
    'example.com' \
    "${MULTI_HY2_CERT_DIR}"
VLESS_PROMPT_TAGS=()
MLDSA_PROMPT_TAGS=()
VLESS_CHOICE_REPLY='n'
MLDSA_CHOICE_REPLY='n'
function run_vlessenc_choice() {
    VLESS_PROMPT_TAGS+=("${CONFIG_DATA['tag']:-}")
    if [[ "${CAPTURE_INPUT_FLOW}" -eq 1 ]]; then
        INPUT_FLOW+=('vless-enc')
    fi
    CONFIG_DATA['vless_enc_enable']="${VLESS_CHOICE_REPLY}"
}
function run_mldsa65_choice() {
    MLDSA_PROMPT_TAGS+=("${CONFIG_DATA['tag']:-}")
    if [[ "${CAPTURE_INPUT_FLOW}" -eq 1 ]]; then
        INPUT_FLOW+=('mldsa65')
    fi
    CONFIG_DATA['mldsa65_enable']="${MLDSA_CHOICE_REPLY}"
}

# Vision collects all user choices in one configuration questionnaire, before
# Xray installation and key generation begin.
reset_config_data
READ_LOG=()
INPUT_FLOW=()
VLESS_PROMPT_TAGS=()
MLDSA_PROMPT_TAGS=()
RULES_REPLY='y'
VLESS_CHOICE_REPLY='y'
MLDSA_CHOICE_REPLY='y'
CAPTURE_INPUT_FLOW=1
handler_read_xray_config 'Vision'
[[ "${INPUT_FLOW[*]}" == 'rules block-bt block-cn block-ad port uuid target short vless-enc mldsa65' ]] || {
    echo "Unexpected Vision input order: ${INPUT_FLOW[*]}" >&2
    exit 1
}
[[ "${CONFIG_DATA['vless_enc_enable']}" == 'y' ]]
[[ "${CONFIG_DATA['mldsa65_enable']}" == 'y' ]]
CONFIG_DATA['cdn']=''
CONFIG_DATA['email']=''
handler_script_config
jq -e '
    .xray.tag == "Vision" and
    .xray.vlessEncEnable == "y" and
    .xray.mldsa65Enable == "y" and
    .xray.mldsa65Seed == "" and
    .xray.mldsa65Verify == ""
' "${SCRIPT_CONFIG_PATH}" >/dev/null
RULES_REPLY='N'
VLESS_CHOICE_REPLY='n'
MLDSA_CHOICE_REPLY='n'
CAPTURE_INPUT_FLOW=0

# A pure HY2 multi-node config must never ask about VLESS encryption.
READ_LOG=()
PORT_READ_COUNT=0
VLESS_PROMPT_TAGS=()
MLDSA_PROMPT_TAGS=()
handler_read_multi_xray_config <<EOF
2
5
5
3
${TEST_DIR}/cert.pem
${TEST_DIR}/key.pem

EOF
[[ "${#VLESS_PROMPT_TAGS[@]}" -eq 0 ]] || {
    echo "Pure HY2 config unexpectedly prompted for VLESS enc" >&2
    exit 1
}
[[ "${#MLDSA_PROMPT_TAGS[@]}" -eq 0 ]] || {
    echo "Pure HY2 config unexpectedly prompted for ML-DSA-65" >&2
    exit 1
}
jq -e 'map(.tag) == ["hy2","hy2"]' <<<"${CONFIG_DATA['nodes_json']}" >/dev/null

READ_LOG=()
PORT_READ_COUNT=0
VLESS_PROMPT_TAGS=()
MLDSA_PROMPT_TAGS=()
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
[[ "${#VLESS_PROMPT_TAGS[@]}" -eq 1 && "${VLESS_PROMPT_TAGS[0]}" == 'mKCP' ]] || {
    echo "VLESS enc prompt was not scoped to the first applicable node: ${VLESS_PROMPT_TAGS[*]}" >&2
    exit 1
}
[[ "${#MLDSA_PROMPT_TAGS[@]}" -eq 1 && "${MLDSA_PROMPT_TAGS[0]}" == 'Vision' ]] || {
    echo "ML-DSA-65 prompt was not scoped to the first Reality node: ${MLDSA_PROMPT_TAGS[*]}" >&2
    exit 1
}
[[ "${CONFIG_DATA['vless_enc_enable']}" == 'n' ]]
[[ "${CONFIG_DATA['mldsa65_enable']}" == 'n' ]]
jq -e '
    map(.tag) == ["mKCP","Vision","XHTTP","Trojan","Fallback","hy2","ss2022"] and
    (.[1] | has("hy2auth") | not) and
    (.[5] | keys | sort) == ["hy2auth","name","port","tag"] and
    (.[6] | keys | sort) == ["name","port","ss2022Key","tag"]
' <<<"${CONFIG_DATA['nodes_json']}" >/dev/null

function capture_multi_ui() {
    local language="$1"
    I18N_DATA="$(jq . "i18n/${language}.json")"
    handler_read_multi_xray_config <<EOF 2>&1
1
2
6
6
EOF
}

diff -u \
    <(jq -r '.handler.multi | keys[]' i18n/en.json) \
    <(jq -r '.handler.multi | keys[]' i18n/zh.json)

english_multi_ui="$(capture_multi_ui en)"
grep -Fq 'How many nodes do you want to create?' <<<"${english_multi_ui}"
grep -Fq 'Enter an integer from 2 to 100.' <<<"${english_multi_ui}"
grep -Fq 'Select protocol for node:' <<<"${english_multi_ui}"

chinese_multi_ui="$(capture_multi_ui zh)"
grep -Fq '要创建多少个节点？' <<<"${chinese_multi_ui}"
grep -Fq '请输入 2 到 100 之间的整数。' <<<"${chinese_multi_ui}"
grep -Fq '请选择节点协议' <<<"${chinese_multi_ui}"
! grep -Fq 'How many nodes do you want to create?' <<<"${chinese_multi_ui}"
! grep -Fq '[Multi]' <<<"${chinese_multi_ui}"

I18N_DATA="$(jq . i18n/en.json)"
english_port_warning="$(generate_unique_multi_port 32768 Vision 2>&1 >/dev/null)"
grep -Fq 'Port 32768 is reserved or already assigned to another node' <<<"${english_port_warning}"
I18N_DATA="$(jq . i18n/zh.json)"
chinese_port_warning="$(generate_unique_multi_port 32768 Vision 2>&1 >/dev/null)"
grep -Fq '端口 32768 为保留端口或已分配给其他节点' <<<"${chinese_port_warning}"

SCRIPT_CONFIG="$(jq '.xray.tag = "multi" | .xray.nodes = []' config.json)"
chinese_no_nodes="$(handler_multi_xray_config 1 2>&1 || true)"
grep -Fq '多节点配置中没有节点。' <<<"${chinese_no_nodes}"
I18N_DATA="$(jq . i18n/en.json)"

# Existing ML-DSA material from an older config implies enabled and must be
# reused instead of being rotated during a config rebuild.
SCRIPT_CONFIG="$(jq '
    .xray.mldsa65Seed = "existing-mldsa-seed" |
    .xray.mldsa65Verify = "existing-mldsa-verify" |
    del(.xray.mldsa65Enable)
' config.json)"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
[[ "$(configured_mldsa65_enable)" == 'y' ]]
handler_mldsa65_config "$(configured_mldsa65_enable)"
jq -e '
    .xray.mldsa65Enable == "y" and
    .xray.mldsa65Seed == "existing-mldsa-seed" and
    .xray.mldsa65Verify == "existing-mldsa-verify"
' "${SCRIPT_CONFIG_PATH}" >/dev/null

SCRIPT_CONFIG="$(jq '
    .xray.mldsa65Enable = "y" |
    .xray.mldsa65Seed = "" |
    .xray.mldsa65Verify = ""
' config.json)"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
handler_mldsa65_config 'y'
jq -e '
    .xray.mldsa65Enable == "y" and
    .xray.mldsa65Seed == "generated-mldsa-seed" and
    .xray.mldsa65Verify == "generated-mldsa-verify"
' "${SCRIPT_CONFIG_PATH}" >/dev/null

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
vless_decryption='existing-vless-decryption'
vless_encryption='existing-vless-encryption'
mldsa_seed='existing-mldsa-seed'
mldsa_verify='existing-mldsa-verify'
if [[ -n "${xray_bin}" ]]; then
    private_key="$(${xray_bin} x25519 | sed -n '1s/.*:[[:space:]]*//p')"
    vlessenc_output="$(printf '2\n' | "${xray_bin}" vlessenc 2>&1)"
    vless_decryption="$(grep '"decryption"' <<<"${vlessenc_output}" | tail -1 | sed 's/.*"decryption": *"\([^"]*\)".*/\1/')"
    vless_encryption="$(grep '"encryption"' <<<"${vlessenc_output}" | tail -1 | sed 's/.*"encryption": *"\([^"]*\)".*/\1/')"
    mldsa_output="$("${xray_bin}" mldsa65)"
    mldsa_seed="$(sed -n '1s/.*:[[:space:]]*//p' <<<"${mldsa_output}")"
    mldsa_verify="$(sed -n '2s/.*:[[:space:]]*//p' <<<"${mldsa_output}")"
fi

SCRIPT_CONFIG="$(jq \
    --argjson nodes "${nodes}" \
    --arg privateKey "${private_key}" \
    --arg hy2Cert "${TEST_DIR}/cert.pem" \
    --arg hy2Key "${TEST_DIR}/key.pem" \
    --arg vlessDec "${vless_decryption}" \
    --arg vlessEnc "${vless_encryption}" \
    --arg mldsaSeed "${mldsa_seed}" \
    --arg mldsaVerify "${mldsa_verify}" '
    .xray.tag = "multi" |
    .xray.nodes = $nodes |
    .xray.privateKey = $privateKey |
    .xray.mldsa65Enable = "y" |
    .xray.mldsa65Seed = $mldsaSeed |
    .xray.mldsa65Verify = $mldsaVerify |
    .xray.vlessEncEnable = "y" |
    .xray.vlessEncDecryption = $vlessDec |
    .xray.vlessEncEncryption = $vlessEnc |
    .xray.hy2CertSource = "3" |
    .xray.hy2CertDomain = "example.com" |
    .xray.hy2CertFullchain = $hy2Cert |
    .xray.hy2CertPrivkey = $hy2Key |
    .xray.rules = {reset:1,bt:1,cn:1,ad:1} |
    .xray.warp = 0 |
    .xray.reverse = 0 |
    .xray.lan.enabled = 0 |
    .rules = []
' config.json)"

function open_xray_firewall_port() { :; }
function handler_lan_open_firewall() { :; }
VLESS_GENERATION_CALLS=0
function run_vlessenc_prompt() {
    VLESS_GENERATION_CALLS=$((VLESS_GENERATION_CALLS + 1))
    return 1
}
handler_multi_xray_config
[[ "${VLESS_GENERATION_CALLS}" -eq 0 ]] || {
    echo 'Persisted VLESS enc material was unexpectedly regenerated' >&2
    exit 1
}

jq -e \
    --arg cert "${MULTI_HY2_CERT_DIR}/fullchain.pem" \
    --arg key "${MULTI_HY2_CERT_DIR}/privkey.pem" \
    --arg vlessDec "${vless_decryption}" \
    --arg mldsaSeed "${mldsa_seed}" '
    (.inbounds | length) == 19 and
    ([.inbounds[].tag] | unique | length) == 19 and
    ([.inbounds[] | select(.port? == 32768 and .tag != "api")] | length) == 0 and
    ([.inbounds[] | select(.protocol == "vless")] | length) == 10 and
    all(.inbounds[] | select(.protocol == "vless" and (.settings | has("fallbacks") | not));
        .settings.decryption == $vlessDec) and
    all(.inbounds[] | select(.protocol == "vless" and (.settings | has("fallbacks")));
        .settings.decryption == "none") and
    all(.inbounds[] | select(.streamSettings.realitySettings?);
        .streamSettings.realitySettings.mldsa65Seed == $mldsaSeed) and
    ([.inbounds[] | select(.protocol == "trojan")] | length) == 2 and
    ([.inbounds[] | select(.protocol == "hysteria")] | length) == 2 and
    all(.inbounds[] | select(.protocol == "hysteria");
        .settings.clients[0].auth == "hy2-password" and
        .streamSettings.hysteriaSettings.auth == "hy2-password" and
        .streamSettings.hysteriaSettings.udpIdleTimeout == 60 and
        .streamSettings.tlsSettings.certificates[0].usage == "encipherment" and
        .streamSettings.tlsSettings.certificates[0].certificateFile == $cert and
        .streamSettings.tlsSettings.certificates[0].keyFile == $key) and
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

# The post-install stage consumes persisted choices and must not read another
# answer after package installation output has started.
(
    SCRIPT_CONFIG="$(jq '
        .xray.tag = "Vision" |
        .xray.vlessEncEnable = "y" |
        .xray.mldsa65Enable = "y"
    ' config.json)"
    LATE_READ_LOG="${TEST_DIR}/late-read.log"
    REALITY_PREP_LOG="${TEST_DIR}/reality-prep.log"
    RUNTIME_BUILD_LOG="${TEST_DIR}/runtime-build.log"
    POISON_INPUT="${TEST_DIR}/poison-input"
    printf 'POISON\n' >"${POISON_INPUT}"

    function load_i18n() { :; }
    function handler_prepare_protocol_services() { :; }
    function read() {
        printf 'read called\n' >>"${LATE_READ_LOG}"
        return 1
    }
    function handler_reality_key_config() {
        [[ "$(configured_mldsa65_enable)" == 'y' ]]
        printf 'prepared\n' >>"${REALITY_PREP_LOG}"
    }
    function handler_xray_config() {
        printf 'built\n' >>"${RUNTIME_BUILD_LOG}"
    }

    exec 9<"${POISON_INPUT}"
    main '--xray-config' <&9
    [[ ! -e "${LATE_READ_LOG}" ]]
    builtin read -r remaining_input <&9
    [[ "${remaining_input}" == 'POISON' ]]
    [[ "$(wc -l <"${REALITY_PREP_LOG}")" -eq 1 ]]
    [[ "$(wc -l <"${RUNTIME_BUILD_LOG}")" -eq 1 ]]
)

# Quick Vision passes explicit EOF defaults into the two pre-install choices,
# so automation with closed stdin does not regress while both choices stay in
# the same pre-install phase.
(
    QUICK_CHOICE_LOG="${TEST_DIR}/quick-choice.log"
    function run_vlessenc_choice() {
        [[ "${1:-}" == 'y' ]]
        CONFIG_DATA['vless_enc_enable']='y'
        printf 'vless:%s\n' "$1" >>"${QUICK_CHOICE_LOG}"
    }
    function run_mldsa65_choice() {
        [[ "${1:-}" == 'n' ]]
        CONFIG_DATA['mldsa65_enable']='n'
        printf 'mldsa:%s\n' "$1" >>"${QUICK_CHOICE_LOG}"
    }
    function handler_script_config() { :; }
    function handler_install() { :; }
    function handler_reality_key_config() { :; }
    function handler_xray_config() { :; }
    function add_rule() { :; }
    function handler_geodata_cron() { :; }
    function handler_restart() { :; }
    function handler_share() { :; }

    handler_quick_install 'Vision' </dev/null
    [[ "$(tr '\n' ' ' <"${QUICK_CHOICE_LOG}")" == 'vless:y mldsa:n ' ]]
)

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
