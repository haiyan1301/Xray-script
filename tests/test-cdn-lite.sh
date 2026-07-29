#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

mkdir -p \
    "${TEST_DIR}/home/.xray-script" \
    "${TEST_DIR}/home/.acme.sh" \
    "${TEST_DIR}/xray-certs/cdn"
cp config.json "${TEST_DIR}/script.json"
cp config.json "${TEST_DIR}/home/.xray-script/config.json"
cp tests/fixtures/fake-acme.sh "${TEST_DIR}/home/.acme.sh/acme.sh"
chmod +x "${TEST_DIR}/home/.acme.sh/acme.sh"

export HOME="${TEST_DIR}/home"
export SCRIPT_CONFIG_PATH_OVERRIDE="${TEST_DIR}/script.json"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/xray.json"
export CDN_XRAY_CERT_DIR_OVERRIDE="${TEST_DIR}/xray-certs/cdn"
export XRAY_CONFIG_VALIDATE=0

openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj '/CN=cdn.example.com' \
    -addext 'subjectAltName=DNS:cdn.example.com' \
    -keyout "${TEST_DIR}/custom.key" \
    -out "${TEST_DIR}/custom.crt" >/dev/null 2>&1

export FAKE_ACME_LOG="${TEST_DIR}/acme.log"
export FAKE_ACME_CERT="${TEST_DIR}/custom.crt"
export FAKE_ACME_KEY="${TEST_DIR}/custom.key"
export FAKE_ACME_DOMAIN="cdn.example.com"
export FAKE_ACME_KEY_LENGTH="ec-256"

source core/handler.sh
I18N_DATA="$(jq . i18n/en.json)"

# A Docker helper failure must return to the caller instead of terminating the
# sourced handler process. This lets recovery code report and handle failures.
EXEC_DOCKER_SURVIVAL_MARKER="${TEST_DIR}/exec-docker-survived"
(
    function bash() {
        return 23
    }
    exec_docker_status=0
    exec_docker '--expected-test-failure' || exec_docker_status=$?
    [[ "${exec_docker_status}" -eq 1 ]]
    printf '%s\n' survived >"${EXEC_DOCKER_SURVIVAL_MARKER}"
)
[[ "$(<"${EXEC_DOCKER_SURVIVAL_MARKER}")" == survived ]]

# ECC-only installs must not mistake an RSA record for an installable
# certificate. This forces callers to issue the missing ECC variant.
export FAKE_ACME_HAS_CERT=1
export FAKE_ACME_KEY_LENGTH="rsa-2048"
if acme_manages_certificate 'cdn.example.com'; then
    echo "RSA-only ACME record was accepted as an ECC certificate" >&2
    exit 1
fi
export FAKE_ACME_KEY_LENGTH="ec-256"
acme_manages_certificate 'cdn.example.com'
export FAKE_ACME_HAS_CERT=0

# Exercise the OpenSSL 1.0.2 CN fallback: an unmatched wildcard must return a
# hard failure instead of falling through with the previous command's status.
(
    function openssl() {
        case "$*" in
        'x509 -help') printf '%s\n' 'legacy x509 help' ;;
        *'-noout -text') printf '%s\n' 'Certificate:' ;;
        *'-noout -subject -nameopt RFC2253') printf '%s\n' 'subject=CN=*.example.com' ;;
        *) return 1 ;;
        esac
    }
    certificate_matches_server_name '/unused/cert.pem' 'one.example.com'
    if certificate_matches_server_name '/unused/cert.pem' 'one.other.example'; then
        echo "Unmatched legacy wildcard CN was accepted" >&2
        exit 1
    fi
)

CDN_CUSTOM_CERT_DIR="$(get_cdn_direct_cert_dir 'cdn.example.com' '2')"
CDN_AUTO_CERT_DIR="$(get_cdn_direct_cert_dir 'cdn.example.com' '1')"
CDN_OTHER_AUTO_CERT_DIR="$(get_cdn_direct_cert_dir 'other.example.com' '1')"
[[ "${CDN_CUSTOM_CERT_DIR}" != "${CDN_AUTO_CERT_DIR}" ]]
[[ "${CDN_AUTO_CERT_DIR}" != "${CDN_OTHER_AUTO_CERT_DIR}" ]]
[[ "${CDN_CUSTOM_CERT_DIR}" != "${CDN_OTHER_AUTO_CERT_DIR}" ]]

SERVICE_LOG="${TEST_DIR}/services.log"
SERVICE_LOG_ENABLED=0
SYSTEMCTL_STRICT=0
SYSTEMCTL_XRAY_ACTIVE=0
SYSTEMCTL_XRAY_ENABLED=1
SYSTEMCTL_XRAY_ACTION_FAIL=0
SYSTEMCTL_NGINX_ACTIVE=0
SYSTEMCTL_NGINX_ENABLED=0
HANDLER_NGINX_STOP_FAIL=0
HANDLER_NGINX_START_FAIL=0
CLEANUP_FAIL=0
CLOUDREVE_V3_FAIL=0
CLOUDREVE_V4_FAIL=0

function record_service_event() {
    if [[ "${SERVICE_LOG_ENABLED}" -eq 1 ]]; then
        printf '%s\n' "$*" >>"${SERVICE_LOG}"
    fi
    return 0
}

function sleep() { :; }
FIREWALL_LOG="${TEST_DIR}/firewall.log"
function open_xray_firewall_port() { printf '%s %s\n' "$1" "$2" >>"${FIREWALL_LOG}"; }
function handler_apply_lan_config() { :; }
function handler_lan_open_firewall() { :; }
function systemctl() {
    local command="$*"
    record_service_event "systemctl ${command}"
    case "${command}" in
    'reset-failed xray') return 0 ;;
    '-q is-active xray') [[ "${SYSTEMCTL_XRAY_ACTIVE}" -eq 1 ]] ;;
    '-q start xray' | '-q restart xray' | '-q reload xray')
        [[ "${SYSTEMCTL_XRAY_ACTION_FAIL}" -eq 0 ]] || return 1
        SYSTEMCTL_XRAY_ACTIVE=1
        return 0
        ;;
    '-q stop xray')
        SYSTEMCTL_XRAY_ACTIVE=0
        return 0
        ;;
    '-q is-enabled xray') [[ "${SYSTEMCTL_XRAY_ENABLED}" -eq 1 ]] ;;
    '-q enable xray')
        SYSTEMCTL_XRAY_ENABLED=1
        return 0
        ;;
    '-q disable xray')
        SYSTEMCTL_XRAY_ENABLED=0
        return 0
        ;;
    '-q is-active nginx') [[ "${SYSTEMCTL_NGINX_ACTIVE}" -eq 1 ]] ;;
    '-q start nginx' | '-q restart nginx' | '-q reload nginx')
        SYSTEMCTL_NGINX_ACTIVE=1
        return 0
        ;;
    '-q stop nginx')
        SYSTEMCTL_NGINX_ACTIVE=0
        return 0
        ;;
    '-q is-enabled nginx') [[ "${SYSTEMCTL_NGINX_ENABLED}" -eq 1 ]] ;;
    '-q enable nginx')
        SYSTEMCTL_NGINX_ENABLED=1
        return 0
        ;;
    '-q disable nginx')
        SYSTEMCTL_NGINX_ENABLED=0
        return 0
        ;;
    '--no-pager --full status xray') return 0 ;;
    *)
        if [[ "${SYSTEMCTL_STRICT}" -eq 1 ]]; then
            echo "Unexpected systemctl call: ${command}" >&2
        fi
        return 1
        ;;
    esac
}
function handler_nginx_stop() {
    record_service_event 'nginx stop'
    [[ "${HANDLER_NGINX_STOP_FAIL}" -eq 0 ]] || return 1
    SYSTEMCTL_NGINX_ACTIVE=0
    SYSTEMCTL_NGINX_ENABLED=0
}
function handler_nginx_start() {
    record_service_event 'nginx start'
    [[ "${HANDLER_NGINX_START_FAIL}" -eq 0 ]] || return 1
    SYSTEMCTL_NGINX_ACTIVE=1
    SYSTEMCTL_NGINX_ENABLED=1
}
function handler_disable_nginx_cron() {
    record_service_event 'nginx-cron disable'
    [[ "${CLEANUP_FAIL}" -eq 0 ]]
}
function handler_cloudreve_v3() {
    record_service_event "v3 $1"
    [[ "${CLOUDREVE_V3_FAIL}" -eq 0 ]]
}
function handler_cloudreve_v4() {
    record_service_event "v4 $1"
    [[ "${CLOUDREVE_V4_FAIL}" -eq 0 ]]
}

SCRIPT_CONFIG="$(jq \
    --arg cert "${TEST_DIR}/custom.crt" \
    --arg key "${TEST_DIR}/custom.key" '
    .xray.tag = "CDN" |
    .xray.cdnBackend = "xray" |
    .xray.cdnCertHostname = "cdn.example.com" |
    .xray.cdnCertSource = "2" |
    .xray.cdnCertFullchain = $cert |
    .xray.cdnCertPrivkey = $key |
    .xray.port = 443 |
    .xray.uuid = "11111111-2222-3333-4444-555555555555" |
    .xray.path = "/lite-path" |
    .xray.xhttpMode = "packet-up" |
    .xray.vlessEncEnable = "n" |
    .xray.rules.reset = 0 |
    .nginx.cdn = "cdn.example.com"
' config.json)"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"

handler_cdn_direct_cert
validate_cdn_direct_certificate \
    "${CDN_CUSTOM_CERT_DIR}/fullchain.pem" \
    "${CDN_CUSTOM_CERT_DIR}/privkey.pem" \
    "cdn.example.com"
CUSTOM_CERT_HASH="$(sha256sum \
    "${CDN_CUSTOM_CERT_DIR}/fullchain.pem" \
    "${CDN_CUSTOM_CERT_DIR}/privkey.pem")"

# The automatic path must use acme.sh standalone directly. It must never call
# the Nginx-bound service/ssl.sh issue flow or overwrite the same-domain custom
# certificate directory.
rm -f -- "${CDN_AUTO_CERT_DIR}/fullchain.pem" "${CDN_AUTO_CERT_DIR}/privkey.pem"
SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '
    .xray.cdnCertHostname = "cdn.example.com" |
    .xray.cdnCertSource = "1" |
    .xray.cdnCertFullchain = "" |
    .xray.cdnCertPrivkey = "" |
    .nginx.ca = "certs@example.com"
')"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
: >"${FAKE_ACME_LOG}"
export FAKE_ACME_HAS_CERT=0
export FAKE_ACME_FAIL_ISSUE=0
handler_cdn_direct_cert
grep -Fq -- '--issue -d cdn.example.com --standalone' "${FAKE_ACME_LOG}"
grep -Fq -- '--install-cert --ecc -d cdn.example.com' "${FAKE_ACME_LOG}"
validate_cdn_direct_certificate \
    "${CDN_AUTO_CERT_DIR}/fullchain.pem" \
    "${CDN_AUTO_CERT_DIR}/privkey.pem" \
    "cdn.example.com"
[[ "$(sha256sum \
    "${CDN_CUSTOM_CERT_DIR}/fullchain.pem" \
    "${CDN_CUSTOM_CERT_DIR}/privkey.pem")" == "${CUSTOM_CERT_HASH}" ]]

: >"${FIREWALL_LOG}"
handler_xray_config 1
jq -e '
    .inbounds[1].protocol == "vless" and
    .inbounds[1].listen == "0.0.0.0" and
    .inbounds[1].port == 443 and
    .inbounds[1].settings.clients[0].id == "11111111-2222-3333-4444-555555555555" and
    .inbounds[1].streamSettings.network == "xhttp" and
    .inbounds[1].streamSettings.security == "tls" and
    .inbounds[1].streamSettings.tlsSettings.minVersion == "1.2" and
    (.inbounds[1].streamSettings.tlsSettings.alpn | index("h2") != null) and
    .inbounds[1].streamSettings.sockopt.trustedXForwardedFor == ["X-Forwarded-For"] and
    .inbounds[1].streamSettings.xhttpSettings.path == "/lite-path" and
    .inbounds[1].streamSettings.xhttpSettings.mode == "packet-up"
' "${XRAY_CONFIG_PATH}" >/dev/null
[[ "$(jq -r '.inbounds[1].streamSettings.tlsSettings.certificates[0].certificateFile' "${XRAY_CONFIG_PATH}")" == \
    "${CDN_AUTO_CERT_DIR}/fullchain.pem" ]]
[[ "$(jq -r '.inbounds[1].streamSettings.tlsSettings.certificates[0].keyFile' "${XRAY_CONFIG_PATH}")" == \
    "${CDN_AUTO_CERT_DIR}/privkey.pem" ]]
[[ "$(cat "${FIREWALL_LOG}")" == "443 tcp" ]]
cp "${XRAY_CONFIG_PATH}" "${TEST_DIR}/direct-runtime.json"

function build_cdn_share_link() {
    bash -c '
        source core/share.sh
        function curl() { printf "192.0.2.10"; }
        load_i18n
        cache_json_data
        get_common_config 1
        get_cdn_share_link
        printf "%s\n" "${SHARE_LINK}"
    '
}

DIRECT_SHARE_LINK="$(build_cdn_share_link)"
[[ "${DIRECT_SHARE_LINK}" == vless://11111111-2222-3333-4444-555555555555@cdn.example.com:443\?* ]]
[[ "${DIRECT_SHARE_LINK}" == *'security=tls'* ]]
[[ "${DIRECT_SHARE_LINK}" == *'sni=cdn.example.com'* ]]
[[ "${DIRECT_SHARE_LINK}" == *'host=cdn.example.com'* ]]
[[ "${DIRECT_SHARE_LINK}" == *'path=%2Flite-path'* ]]
[[ "${DIRECT_SHARE_LINK}" == *'mode=packet-up'* ]]
[[ "${DIRECT_SHARE_LINK}" != *'pbk='* ]]
[[ "${DIRECT_SHARE_LINK}" != *'sid='* ]]

# The original Nginx backend remains a Unix-socket inbound without TLS. Its
# client share link must be identical to the direct-Xray backend.
SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.cdnBackend = "nginx"')"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
: >"${FIREWALL_LOG}"
handler_xray_config 1
jq -e '
    (.inbounds[1].listen | startswith("/dev/shm/nginx/")) and
    (.inbounds[1] | has("port") | not) and
    (.inbounds[1].streamSettings | has("security") | not) and
    (.inbounds[1].streamSettings | has("tlsSettings") | not)
' "${XRAY_CONFIG_PATH}" >/dev/null
[[ ! -s "${FIREWALL_LOG}" ]]
cp "${XRAY_CONFIG_PATH}" "${TEST_DIR}/uds-runtime.json"
NGINX_SHARE_LINK="$(build_cdn_share_link)"
[[ "${NGINX_SHARE_LINK}" == "${DIRECT_SHARE_LINK}" ]]

# Preparing a direct node is non-disruptive. Nginx remains online until the
# certificate and replacement runtime have both passed validation.
SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.cdnBackend = "xray"')"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
cp "${TEST_DIR}/direct-runtime.json" "${XRAY_CONFIG_PATH}"
SERVICE_LOG_ENABLED=1
SYSTEMCTL_STRICT=1
: >"${SERVICE_LOG}"
handler_prepare_protocol_services ''
[[ ! -s "${SERVICE_LOG}" ]]

# The ownership handoff occurs in restart: stop Nginx, restart and verify
# Xray, then disable cron and Cloudreve. Cleanup never runs before Xray is
# confirmed active.
SYSTEMCTL_XRAY_ACTIVE=1
SYSTEMCTL_XRAY_ENABLED=1
SYSTEMCTL_NGINX_ACTIVE=1
SYSTEMCTL_NGINX_ENABLED=1
: >"${SERVICE_LOG}"
handler_restart
diff -u <(printf '%s\n' \
    'systemctl -q is-active nginx' \
    'systemctl -q is-enabled nginx' \
    'nginx stop' \
    'systemctl reset-failed xray' \
    'systemctl -q is-active xray' \
    'systemctl -q restart xray' \
    'systemctl -q is-enabled xray' \
    'systemctl -q is-active xray' \
    'nginx-cron disable' \
    'v3 stop' \
    'v4 stop') "${SERVICE_LOG}"

# A failed Xray handoff restores the exact Nginx active/enabled state and
# leaves Cloudreve untouched, so the old website remains available.
SYSTEMCTL_XRAY_ACTIVE=0
SYSTEMCTL_XRAY_ACTION_FAIL=1
SYSTEMCTL_NGINX_ACTIVE=1
SYSTEMCTL_NGINX_ENABLED=1
: >"${SERVICE_LOG}"
if handler_restart 2>"${TEST_DIR}/handoff-failure.log"; then
    echo "Failed Xray listener handoff was reported as successful" >&2
    exit 1
fi
[[ "${SYSTEMCTL_NGINX_ACTIVE}" -eq 1 ]]
[[ "${SYSTEMCTL_NGINX_ENABLED}" -eq 1 ]]
if grep -Eq '^(v3|v4) stop$' "${SERVICE_LOG}"; then
    echo "Cloudreve was stopped before the replacement Xray runtime was healthy" >&2
    exit 1
fi
grep -Fq 'systemctl -q start nginx' "${SERVICE_LOG}"
grep -Fq 'systemctl -q enable nginx' "${SERVICE_LOG}"
SYSTEMCTL_XRAY_ACTION_FAIL=0

# Resource cleanup failures are warnings after a healthy handoff, not a
# reason to report the node restart as failed.
CLEANUP_FAIL=1
: >"${SERVICE_LOG}"
handler_disable_cdn_web_stack
diff -u <(printf '%s\n' \
    'nginx-cron disable' \
    'v3 stop' \
    'v4 stop') "${SERVICE_LOG}"
CLEANUP_FAIL=0

# Runtime recovery follows the restored script configuration. A direct
# listener keeps the current Xray process alive until Nginx has stopped
# successfully, then reloads the restored runtime.
SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '
    .xray.tag = "CDN" |
    .xray.cdnBackend = "xray"
')"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
cp "${TEST_DIR}/direct-runtime.json" "${XRAY_CONFIG_PATH}"
SYSTEMCTL_XRAY_ACTIVE=1
SYSTEMCTL_XRAY_ENABLED=1
SYSTEMCTL_NGINX_ACTIVE=1
SYSTEMCTL_NGINX_ENABLED=1
: >"${SERVICE_LOG}"
: >"${FAKE_ACME_LOG}"
export FAKE_ACME_HAS_CERT=1
export FAKE_ACME_FAIL_INSTALL=0
handler_recover_runtime_services
diff -u <(printf '%s\n' \
    'nginx stop' \
    'v3 stop' \
    'v4 stop' \
    'systemctl -q is-active xray' \
    'systemctl -q stop xray' \
    'systemctl reset-failed xray' \
    'systemctl -q is-active xray' \
    'systemctl -q start xray' \
    'systemctl -q is-enabled xray' \
    'systemctl -q is-active xray') "${SERVICE_LOG}"
grep -Fq -- "--key-file ${CDN_AUTO_CERT_DIR}/privkey.pem" "${FAKE_ACME_LOG}"
grep -Fq -- "--fullchain-file ${CDN_AUTO_CERT_DIR}/fullchain.pem" "${FAKE_ACME_LOG}"
grep -Fq -- "--reloadcmd : && chmod 750 ${CDN_AUTO_CERT_DIR}" "${FAKE_ACME_LOG}"
grep -Fq -- 'if systemctl -q is-active xray; then systemctl -q reload xray || systemctl -q restart xray; fi' "${FAKE_ACME_LOG}"
export FAKE_ACME_HAS_CERT=0

# A restored Nginx-backed script configuration must release the failed direct
# listener before starting Nginx, and must not issue a duplicate Xray stop.
SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '
    .xray.tag = "CDN" |
    .xray.cdnBackend = "nginx"
')"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
cp "${TEST_DIR}/uds-runtime.json" "${XRAY_CONFIG_PATH}"
SYSTEMCTL_XRAY_ACTIVE=1
SYSTEMCTL_XRAY_ENABLED=1
SYSTEMCTL_NGINX_ACTIVE=0
SYSTEMCTL_NGINX_ENABLED=0
: >"${SERVICE_LOG}"
handler_recover_runtime_services
diff -u <(printf '%s\n' \
    'systemctl -q is-active xray' \
    'systemctl -q stop xray' \
    'v3 stop' \
    'v4 stop' \
    'nginx start' \
    'systemctl -q is-active xray' \
    'systemctl -q is-active nginx' \
    'systemctl reset-failed xray' \
    'systemctl -q is-active xray' \
    'systemctl -q start xray' \
    'systemctl -q is-enabled xray' \
    'systemctl -q is-active xray') "${SERVICE_LOG}"

# Recovery also restores the configured Cloudreve generation, stopping the
# other generation before Nginx is brought back.
for restored_web in v3 v4; do
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq \
        --arg web "${restored_web}" '.nginx.web = $web')"
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
    SYSTEMCTL_XRAY_ACTIVE=1
    SYSTEMCTL_XRAY_ENABLED=1
    SYSTEMCTL_NGINX_ACTIVE=0
    SYSTEMCTL_NGINX_ENABLED=0
    : >"${SERVICE_LOG}"
    handler_recover_runtime_services
    if [[ "${restored_web}" == v3 ]]; then
        expected_web_events=$'v4 stop\nv3 start'
    else
        expected_web_events=$'v3 stop\nv4 start'
    fi
    [[ "$(grep -E '^(v3|v4) ' "${SERVICE_LOG}")" == "${expected_web_events}" ]]
    first_nginx_line="$(grep -nFx 'nginx start' "${SERVICE_LOG}" | cut -d: -f1)"
    last_web_line="$(grep -nE '^(v3|v4) ' "${SERVICE_LOG}" | tail -n 1 | cut -d: -f1)"
    [[ "${last_web_line}" -lt "${first_nginx_line}" ]]
done

# A configured container failure is reported only after the restored Nginx and
# Xray services have both been attempted.
SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.nginx.web = "v3"')"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
SYSTEMCTL_XRAY_ACTIVE=1
SYSTEMCTL_XRAY_ENABLED=1
SYSTEMCTL_NGINX_ACTIVE=0
SYSTEMCTL_NGINX_ENABLED=0
CLOUDREVE_V3_FAIL=1
: >"${SERVICE_LOG}"
if handler_recover_runtime_services; then
    echo "Nginx recovery hid a Cloudreve start failure" >&2
    exit 1
fi
grep -Fxq 'v3 start' "${SERVICE_LOG}"
grep -Fxq 'nginx start' "${SERVICE_LOG}"
grep -Fxq 'systemctl -q start xray' "${SERVICE_LOG}"
CLOUDREVE_V3_FAIL=0

# Restoring a protocol that does not use Nginx must also stop and disable a
# Nginx service left active by the failed target, even when its listener is
# UDP/443 and therefore would not conflict at the socket level.
SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '
    .xray.tag = "hy2" |
    .xray.cdnBackend = "nginx"
')"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
cp config/xray/hy2.json "${XRAY_CONFIG_PATH}"
SYSTEMCTL_XRAY_ACTIVE=1
SYSTEMCTL_XRAY_ENABLED=1
SYSTEMCTL_NGINX_ACTIVE=1
SYSTEMCTL_NGINX_ENABLED=1
: >"${SERVICE_LOG}"
handler_recover_runtime_services
diff -u <(printf '%s\n' \
    'nginx stop' \
    'v3 stop' \
    'v4 stop' \
    'systemctl -q is-active xray' \
    'systemctl -q stop xray' \
    'systemctl reset-failed xray' \
    'systemctl -q is-active xray' \
    'systemctl -q start xray' \
    'systemctl -q is-enabled xray' \
    'systemctl -q is-active xray') "${SERVICE_LOG}"
[[ "${SYSTEMCTL_NGINX_ACTIVE}" -eq 0 ]]
[[ "${SYSTEMCTL_NGINX_ENABLED}" -eq 0 ]]

# Cloudreve cleanup is best effort during a non-Nginx rollback. Both stop
# operations and the core Xray reload are attempted before failure is returned.
SYSTEMCTL_XRAY_ACTIVE=1
SYSTEMCTL_XRAY_ENABLED=1
SYSTEMCTL_NGINX_ACTIVE=0
SYSTEMCTL_NGINX_ENABLED=0
CLOUDREVE_V3_FAIL=1
CLOUDREVE_V4_FAIL=1
: >"${SERVICE_LOG}"
if handler_recover_runtime_services; then
    echo "Direct recovery hid Cloudreve cleanup failures" >&2
    exit 1
fi
grep -Fxq 'v3 stop' "${SERVICE_LOG}"
grep -Fxq 'v4 stop' "${SERVICE_LOG}"
grep -Fxq 'systemctl -q stop xray' "${SERVICE_LOG}"
grep -Fxq 'systemctl -q start xray' "${SERVICE_LOG}"
CLOUDREVE_V3_FAIL=0
CLOUDREVE_V4_FAIL=0

# Selecting Nginx only records the target backend. Listener ownership is
# changed later by the validated prepare/restart transaction.
SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '
    .xray.tag = "CDN" |
    .xray.cdnBackend = "xray"
')"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
: >"${SERVICE_LOG}"
handler_set_cdn_backend nginx
[[ "$(jq -r '.xray.cdnBackend' "${SCRIPT_CONFIG_PATH}")" == 'nginx' ]]
[[ ! -s "${SERVICE_LOG}" ]]
if handler_set_cdn_backend invalid >/dev/null 2>&1; then
    echo "Invalid CDN backend was accepted" >&2
    exit 1
fi

# A successful standalone issue followed by a failed --install-cert is a hard
# stop. The UDS runtime remains untouched, proving config generation did not
# continue after certificate installation failed.
rm -f -- "${CDN_AUTO_CERT_DIR}/fullchain.pem" "${CDN_AUTO_CERT_DIR}/privkey.pem"
export FAKE_ACME_HAS_CERT=0
export FAKE_ACME_FAIL_ISSUE=0
export FAKE_ACME_FAIL_INSTALL=1
SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '
    .xray.cdnBackend = "xray" |
    .xray.cdnCertHostname = "cdn.example.com" |
    .xray.cdnCertSource = "1" |
    .xray.cdnCertFullchain = "" |
    .xray.cdnCertPrivkey = "" |
    .nginx.ca = "certs@example.com"
')"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
: >"${FAKE_ACME_LOG}"
SYSTEMCTL_NGINX_ACTIVE=0
RUNTIME_BEFORE="$(sha256sum "${XRAY_CONFIG_PATH}" | awk '{print $1}')"
if main --xray-config; then
    echo "ACME install-cert failure was ignored" >&2
    exit 1
fi
grep -Fq -- '--issue -d cdn.example.com --standalone' "${FAKE_ACME_LOG}"
grep -Fq -- '--install-cert --ecc -d cdn.example.com' "${FAKE_ACME_LOG}"
[[ "$(sha256sum "${XRAY_CONFIG_PATH}" | awk '{print $1}')" == "${RUNTIME_BEFORE}" ]]

echo "CDN low-resource mode tests passed"
