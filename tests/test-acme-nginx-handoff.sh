#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

mkdir -p "${TEST_DIR}/home/.xray-script" "${TEST_DIR}/home/.acme.sh"
cp config.json "${TEST_DIR}/script.json"
cp config.json "${TEST_DIR}/home/.xray-script/config.json"
cp tests/fixtures/fake-acme.sh "${TEST_DIR}/home/.acme.sh/acme.sh"
chmod +x "${TEST_DIR}/home/.acme.sh/acme.sh"

export HOME="${TEST_DIR}/home"
export SCRIPT_CONFIG_PATH_OVERRIDE="${TEST_DIR}/script.json"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/xray.json"
export CDN_XRAY_CERT_DIR_OVERRIDE="${TEST_DIR}/xray-certs/cdn"
export XRAY_CERT_DIR_OVERRIDE="${TEST_DIR}/xray-certs"
export XRAY_CONFIG_VALIDATE=0
export FAKE_ACME_LOG="${TEST_DIR}/acme.log"
export FAKE_ACME_DOMAIN="192.0.2.10"
export FAKE_ACME_KEY_LENGTH="ec-256"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj '/CN=192.0.2.10' \
    -addext 'subjectAltName=IP:192.0.2.10' \
    -keyout "${TEST_DIR}/hy2.key" \
    -out "${TEST_DIR}/hy2.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj '/CN=hy2.example.com' \
    -addext 'subjectAltName=DNS:hy2.example.com' \
    -keyout "${TEST_DIR}/hy2-domain.key" \
    -out "${TEST_DIR}/hy2-domain.crt" >/dev/null 2>&1
export FAKE_ACME_CERT="${TEST_DIR}/hy2.crt"
export FAKE_ACME_KEY="${TEST_DIR}/hy2.key"

source core/handler.sh
I18N_DATA="$(jq . i18n/en.json)"

readonly NGINX_STATE="${TEST_DIR}/nginx.state"
readonly SYSTEMCTL_LOG="${TEST_DIR}/systemctl.log"
printf '%s\n' active >"${NGINX_STATE}"
: >"${SYSTEMCTL_LOG}"
STOP_NGINX_FAIL=0
START_NGINX_FAILURES=0
function systemctl() {
    printf '%s\n' "$*" >>"${SYSTEMCTL_LOG}"
    case "$*" in
    '-q is-active nginx') [[ "$(<"${NGINX_STATE}")" == active ]] ;;
    '-q stop nginx')
        [[ "${STOP_NGINX_FAIL}" -eq 0 ]] || return 1
        printf '%s\n' inactive >"${NGINX_STATE}"
        ;;
    '-q start nginx')
        if [[ "${START_NGINX_FAILURES}" -gt 0 ]]; then
            START_NGINX_FAILURES=$((START_NGINX_FAILURES - 1))
            return 1
        fi
        printf '%s\n' active >"${NGINX_STATE}"
        ;;
    *) return 1 ;;
    esac
}

function prompt_cert_reuse() {
    printf '%s\n' new
}

CRON_CALLS=0
function configure_hy2_ip_renewal_cron() {
    CRON_CALLS=$((CRON_CALLS + 1))
}

SCRIPT_CONFIG="$(jq '
    .xray.tag = "hy2" |
    .xray.hy2CertSource = "2" |
    .xray.hy2CertDomain = "192.0.2.10" |
    .nginx.ca = "certs@example.com"
' config.json)"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"

# An old Nginx site may stay online during preparation, but standalone ACME
# must receive a bounded port-80 window and restore that site before returning.
export FAKE_ACME_HAS_CERT=0
export FAKE_ACME_FAIL_ISSUE=0
handler_hy2_cert
[[ "$(<"${NGINX_STATE}")" == active ]]
[[ "${CRON_CALLS}" -eq 1 ]]
diff -u <(printf '%s\n' \
    '-q is-active nginx' \
    '-q stop nginx' \
    '-q start nginx') "${SYSTEMCTL_LOG}"

# ACME failure is still a hard gate, but it must not leave the old Nginx site
# down while the outer installation transaction restores its configuration.
: >"${SYSTEMCTL_LOG}"
export FAKE_ACME_FAIL_ISSUE=1
if handler_hy2_cert 2>"${TEST_DIR}/issue-failure.log"; then
    echo "Failed HY2 certificate request was accepted" >&2
    exit 1
fi
[[ "$(<"${NGINX_STATE}")" == active ]]
[[ "${CRON_CALLS}" -eq 1 ]]
grep -Fxq -- '-q stop nginx' "${SYSTEMCTL_LOG}"
grep -Fxq -- '-q start nginx' "${SYSTEMCTL_LOG}"

# Domain HY2 issuance uses the same bounded handoff. Certificate installation,
# validation and renewal-hook setup happen only after Nginx is back online.
SCRIPT_CONFIG="$(jq '
    .xray.tag = "hy2" |
    .xray.hy2CertSource = "1" |
    .xray.hy2CertDomain = "hy2.example.com" |
    .nginx.ca = "certs@example.com"
' config.json)"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
export FAKE_ACME_DOMAIN="hy2.example.com"
export FAKE_ACME_CERT="${TEST_DIR}/hy2-domain.crt"
export FAKE_ACME_KEY="${TEST_DIR}/hy2-domain.key"
export FAKE_ACME_FAIL_ISSUE=0
: >"${SYSTEMCTL_LOG}"
handler_hy2_cert
[[ "$(<"${NGINX_STATE}")" == active ]]
[[ "${CRON_CALLS}" -eq 2 ]]
diff -u <(printf '%s\n' \
    '-q is-active nginx' \
    '-q stop nginx' \
    '-q start nginx') "${SYSTEMCTL_LOG}"
grep -Fq -- '--issue -d hy2.example.com --standalone' "${FAKE_ACME_LOG}"

# The helper runs in an isolated subshell with an EXIT trap. A terminating
# signal during acme.sh must therefore restore Nginx without altering callers'
# traps or relying on a normal function return.
function terminate_handoff_subshell() {
    kill -TERM "${BASHPID}"
}
: >"${SYSTEMCTL_LOG}"
printf '%s\n' active >"${NGINX_STATE}"
if run_with_nginx_temporarily_stopped \
    terminate_handoff_subshell 2>"${TEST_DIR}/signal.log"; then
    echo "Terminated ACME handoff returned success" >&2
    exit 1
fi
[[ "$(<"${NGINX_STATE}")" == active ]]
grep -Fxq -- '-q stop nginx' "${SYSTEMCTL_LOG}"
grep -Fxq -- '-q start nginx' "${SYSTEMCTL_LOG}"

# A service-stop failure is distinct from the wrapped command failing. The
# helper reports status 90 and leaves an already-running Nginx untouched.
function successful_handoff_command() {
    return 0
}
: >"${SYSTEMCTL_LOG}"
printf '%s\n' active >"${NGINX_STATE}"
STOP_NGINX_FAIL=1
handoff_status=0
run_with_nginx_temporarily_stopped successful_handoff_command ||
    handoff_status=$?
[[ "${handoff_status}" -eq 90 ]]
[[ "$(<"${NGINX_STATE}")" == active ]]
STOP_NGINX_FAIL=0

# If the normal restart attempt fails, the EXIT trap gets one final restoration
# attempt. The helper still reports status 91 so callers know the handoff was
# not clean, while the old site is brought back when the retry succeeds.
: >"${SYSTEMCTL_LOG}"
printf '%s\n' active >"${NGINX_STATE}"
START_NGINX_FAILURES=1
handoff_status=0
run_with_nginx_temporarily_stopped successful_handoff_command ||
    handoff_status=$?
[[ "${handoff_status}" -eq 91 ]]
[[ "$(<"${NGINX_STATE}")" == active ]]
[[ "$(grep -Fc -- '-q start nginx' "${SYSTEMCTL_LOG}")" -eq 2 ]]

echo "ACME/Nginx handoff tests passed"
