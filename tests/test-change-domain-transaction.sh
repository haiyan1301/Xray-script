#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(mktemp -d)"
readonly TEST_DIR
TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
readonly TEST_PROJECT_ROOT
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || {
    echo 'jq is required' >&2
    exit 1
}

export HOME="${TEST_DIR}/home"
export SCRIPT_CONFIG_PATH_OVERRIDE="${TEST_DIR}/script.json"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/xray.json"
export NGINX_CONFIG_DIR_OVERRIDE="${TEST_DIR}/nginx"
export NGINX_CONFIG_PATH_OVERRIDE="${TEST_DIR}/nginx"
mkdir -p "${HOME}/.xray-script"
cp config.json "${SCRIPT_CONFIG_PATH_OVERRIDE}"

# shellcheck disable=SC1091
source core/handler.sh
I18N_DATA="$(jq . i18n/en.json)"

readonly OLD_DOMAIN='old.example.test'
readonly NEW_DOMAIN='new.example.test'
readonly CUSTOM_CERT="${TEST_DIR}/custom.crt"
readonly CUSTOM_KEY="${TEST_DIR}/custom.key"
readonly SCRIPT_BASELINE="${TEST_DIR}/script.baseline.json"
readonly SITE_BASELINE="${TEST_DIR}/site.baseline.conf"
readonly STREAM_BASELINE="${TEST_DIR}/stream.baseline.conf"
readonly STOP_LOG="${TEST_DIR}/stop.log"

printf '%s\n' 'custom certificate input' >"${CUSTOM_CERT}"
printf '%s\n' 'custom private key input' >"${CUSTOM_KEY}"

FAIL_STAGE=''
EXPECT_ROLLBACK=0
RESTART_CALLS=0
RECOVERY_SAW_BASELINE=1
ACME_MANAGED=0

function prepare_fixture() {
    rm -rf -- "${NGINX_CONFIG_DIR}"
    mkdir -p \
        "${NGINX_CONFIG_DIR}/sites-available" \
        "${NGINX_CONFIG_DIR}/sites-enabled" \
        "${NGINX_CONFIG_DIR}/modules-enabled" \
        "${NGINX_CONFIG_DIR}/certs/${OLD_DOMAIN}"
    printf '%s\n' 'old active site' \
        >"${NGINX_CONFIG_DIR}/sites-available/${OLD_DOMAIN}.conf"
    ln -s "../sites-available/${OLD_DOMAIN}.conf" \
        "${NGINX_CONFIG_DIR}/sites-enabled/${OLD_DOMAIN}.conf"
    printf '%s\n' 'old stream' \
        >"${NGINX_CONFIG_DIR}/modules-enabled/stream.conf"
    printf '%s\n' 'old certificate' \
        >"${NGINX_CONFIG_DIR}/certs/${OLD_DOMAIN}/fullchain.pem"
    printf '%s\n' 'old private key' \
        >"${NGINX_CONFIG_DIR}/certs/${OLD_DOMAIN}/privkey.pem"
    printf '%s\n' 'unrelated' \
        >"${NGINX_CONFIG_DIR}/sites-available/unrelated.example.test.conf"
    chmod 640 "${NGINX_CONFIG_DIR}/sites-available/${OLD_DOMAIN}.conf"
    chmod 600 "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf"
    touch -t 202001020304.05 \
        "${NGINX_CONFIG_DIR}/sites-available/${OLD_DOMAIN}.conf"
    touch -t 202102030405.06 \
        "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf"

    jq --arg cert "${CUSTOM_CERT}" --arg key "${CUSTOM_KEY}" '
        .xray.tag = "CDN" |
        .xray.path = "/transaction-test" |
        .nginx.cdn = "old.example.test" |
        .nginx.certificates.cdn = {
            hostname:"old.example.test",
            source:"2",
            fullchain:$cert,
            privkey:$key
        }
    ' config.json >"${SCRIPT_CONFIG_PATH}"
    cp -p -- "${SCRIPT_CONFIG_PATH}" "${SCRIPT_BASELINE}"
    cp -p -- \
        "${NGINX_CONFIG_DIR}/sites-available/${OLD_DOMAIN}.conf" \
        "${SITE_BASELINE}"
    cp -p -- \
        "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" \
        "${STREAM_BASELINE}"
    SCRIPT_CONFIG="$(jq . "${SCRIPT_CONFIG_PATH}")"
    : >"${STOP_LOG}"
    FAIL_STAGE=''
    EXPECT_ROLLBACK=0
    RESTART_CALLS=0
    RECOVERY_SAW_BASELINE=1
    ACME_MANAGED=0
    reset_config_data
}

function baseline_is_restored() {
    cmp -s "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}" &&
        cmp -s "${SITE_BASELINE}" \
            "${NGINX_CONFIG_DIR}/sites-available/${OLD_DOMAIN}.conf" &&
        cmp -s "${STREAM_BASELINE}" \
            "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" &&
        [[ -L "${NGINX_CONFIG_DIR}/sites-enabled/${OLD_DOMAIN}.conf" ]] &&
        [[ "$(readlink \
            "${NGINX_CONFIG_DIR}/sites-enabled/${OLD_DOMAIN}.conf")" == \
            "../sites-available/${OLD_DOMAIN}.conf" ]] &&
        [[ ! -e "${NGINX_CONFIG_DIR}/sites-available/${NEW_DOMAIN}.conf" ]] &&
        [[ ! -L "${NGINX_CONFIG_DIR}/sites-enabled/${NEW_DOMAIN}.conf" ]] &&
        [[ ! -e "${NGINX_CONFIG_DIR}/certs/${NEW_DOMAIN}" ]] &&
        grep -Fxq 'unrelated' \
            "${NGINX_CONFIG_DIR}/sites-available/unrelated.example.test.conf" &&
        jq -e --arg domain "${OLD_DOMAIN}" \
            '.nginx.cdn == $domain' <<<"${SCRIPT_CONFIG}" >/dev/null
}

function assert_no_transaction_dir() {
    [[ -z "$(compgen -G "${TEST_DIR}/.change-domain.*" || true)" ]]
}

function exec_read() {
    case "$1" in
    only-change-domain) CONFIG_DATA['only-change-domain']='n' ;;
    cdn) CONFIG_DATA['cdn']="${NEW_DOMAIN}" ;;
    email) CONFIG_DATA['email']='certs@example.test' ;;
    *) return 1 ;;
    esac
}

function install_custom_nginx_certificate_pair() {
    local target_dir="$4"

    mkdir -p -- "${target_dir}"
    printf '%s\n' 'new certificate' >"${target_dir}/fullchain.pem"
    if [[ "${FAIL_STAGE}" == 'cert' ]]; then
        return 1
    fi
    printf '%s\n' 'new private key' >"${target_dir}/privkey.pem"
}

function validate_tls_certificate_pair() { return 0; }
function certificate_matches_server_name() { return 0; }
function set_nginx_certificate_permissions() { return 0; }
function prompt_cert_reuse() { printf '%s\n' "${OLD_DOMAIN}"; }
function install_acme_nginx_certificate() {
    local target_dir="$3"

    mkdir -p -- "${target_dir}"
    printf '%s\n' 'automatic certificate' >"${target_dir}/fullchain.pem"
    printf '%s\n' 'automatic private key' >"${target_dir}/privkey.pem"
}
function handler_ssl_install() { return 0; }
function acme_manages_certificate() {
    [[ "${ACME_MANAGED}" -eq 1 && "$1" == "${OLD_DOMAIN}" ]]
}
function exec_ssl() {
    printf '%s\n' "$*" >>"${STOP_LOG}"
    return 0
}
function write_config() {
    printf '%s\n' "$1" >"$2"
    [[ "${FAIL_STAGE}" != 'write' ]]
}
function handler_nginx_restart() {
    RESTART_CALLS=$((RESTART_CALLS + 1))
    if [[ "${FAIL_STAGE}" == 'restart' && "${RESTART_CALLS}" -eq 1 ]]; then
        return 1
    fi
    if [[ "${EXPECT_ROLLBACK}" -eq 1 ]] && ! baseline_is_restored; then
        RECOVERY_SAW_BASELINE=0
    fi
}

function run_failed_change() {
    local stage="$1"

    prepare_fixture
    FAIL_STAGE="${stage}"
    EXPECT_ROLLBACK=1
    if handler_change_domain 'cdn' 'y' 'y' <<<"2
${CUSTOM_CERT}
${CUSTOM_KEY}" >/dev/null 2>&1; then
        echo "change-domain ignored ${stage} failure" >&2
        exit 1
    fi
    baseline_is_restored
    [[ "${RECOVERY_SAW_BASELINE}" -eq 1 ]]
    assert_no_transaction_dir
}

# Fresh target: even a helper that leaves a partial certificate directory must
# be fully rolled back.
run_failed_change cert

# A writer that mutates config.json and then reports failure is still rolled
# back together with the already installed certificate and rendered sites.
run_failed_change write

# The first restart fails; the recovery restart must observe the old state.
run_failed_change restart
[[ "${RESTART_CALLS}" -eq 2 ]]

# Same-domain automatic -> automatic must never remove its own renewal record.
prepare_fixture
SCRIPT_CONFIG="$(jq '
    .nginx.certificates.cdn.source = "1" |
    .nginx.certificates.cdn.fullchain = "" |
    .nginx.certificates.cdn.privkey = ""
' "${SCRIPT_CONFIG_PATH}")"
printf '%s\n' "${SCRIPT_CONFIG}" >"${SCRIPT_CONFIG_PATH}"
ACME_MANAGED=1
CONFIG_DATA['cdn']="${OLD_DOMAIN}"
CONFIG_DATA['only-change-domain']='n'
handler_change_domain 'cdn' 'y' 'n'
[[ ! -s "${STOP_LOG}" ]]
assert_no_transaction_dir

# Same-domain ACME -> custom stops only renewal management and explicitly
# preserves the just-installed deployment certificate.
prepare_fixture
ACME_MANAGED=1
CONFIG_DATA['cdn']="${OLD_DOMAIN}"
CONFIG_DATA['only-change-domain']='n'
handler_change_domain 'cdn' 'y' 'n'
grep -Fxq -- \
    "--stop-renew --domain=${OLD_DOMAIN} --keep-cert" \
    "${STOP_LOG}"
[[ -f "${NGINX_CONFIG_DIR}/certs/${OLD_DOMAIN}/fullchain.pem" ]]
[[ -f "${NGINX_CONFIG_DIR}/certs/${OLD_DOMAIN}/privkey.pem" ]]
assert_no_transaction_dir

echo 'Change-domain transaction tests passed'
