#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
readonly JQ_BIN="$(command -v jq || true)"
[[ -n "${JQ_BIN}" ]] || { echo "jq is required" >&2; exit 1; }

mkdir -p \
    "${TEST_DIR}/home/.xray-script" \
    "${TEST_DIR}/home/bin" \
    "${TEST_DIR}/nginx/sites-available" \
    "${TEST_DIR}/nginx/sites-enabled" \
    "${TEST_DIR}/nginx/modules-enabled"
ln -s "${JQ_BIN}" "${TEST_DIR}/home/bin/jq"
cp config.json "${TEST_DIR}/script.json"
cp config.json "${TEST_DIR}/home/.xray-script/config.json"
export HOME="${TEST_DIR}/home"
export SCRIPT_CONFIG_PATH_OVERRIDE="${TEST_DIR}/script.json"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/xray.json"
export NGINX_CONFIG_DIR_OVERRIDE="${TEST_DIR}/nginx"
export NGINX_SERVICE_PATH_OVERRIDE="${TEST_DIR}/nginx.service"

source core/handler.sh
I18N_DATA="$(jq . i18n/en.json)"

command bash core/check.sh --domain-format 'cdn.example.com' >/dev/null 2>&1
for invalid_domain in '' '../../x' 'bad/domain.com' 'bad|domain.com'; do
    if command bash core/check.sh --domain-format "${invalid_domain}" >/dev/null 2>&1; then
        echo "invalid domain was accepted: ${invalid_domain}" >&2
        exit 1
    fi
done

READ_RESULT='cdn.example.com'
CHECK_OPTION=''

function bash() {
    if [[ "$1" == "${READ_PATH}" ]]; then
        printf '%s\n' "${READ_RESULT}"
        return 0
    fi
    command bash "$@"
}

function exec_check() {
    CHECK_OPTION="$1"
    return 0
}

reset_config_data
CONFIG_DATA['tag']='CDN'
CHECK_OPTION=''
exec_read 'cdn'
[[ "${CHECK_OPTION}" == '--domain-format' ]]
[[ "${CONFIG_DATA['cdn']}" == "${READ_RESULT}" ]]

reset_config_data
CONFIG_DATA['tag']='SNI'
CHECK_OPTION=''
exec_read 'cdn'
[[ "${CHECK_OPTION}" == '--dns' ]]

reset_config_data
SCRIPT_CONFIG="$(jq '.xray.tag = "CDN"' <<<"${SCRIPT_CONFIG}")"
CHECK_OPTION=''
exec_read 'cdn'
[[ "${CHECK_OPTION}" == '--domain-format' ]]

reset_config_data
SCRIPT_CONFIG="$(jq '.xray.tag = "SNI"' <<<"${SCRIPT_CONFIG}")"
CHECK_OPTION=''
exec_read 'cdn'
[[ "${CHECK_OPTION}" == '--dns' ]]

reset_config_data
CHECK_OPTION=''
exec_read 'domain'
[[ "${CHECK_OPTION}" == '--dns' ]]
[[ "${CONFIG_DATA['target']}" == "${READ_RESULT}" ]]

GEN_LOG="${TEST_DIR}/generate.log"
: >"${GEN_LOG}"
function exec_generate() {
    local option="$1"
    printf '%s\n' "${option}" >>"${GEN_LOG}"
    case "${option}" in
    --uuid) echo '11111111-1111-1111-1111-111111111111' ;;
    --password) echo 'generated-password' ;;
    --short-ids) echo '["0123456789abcdef"]' ;;
    --path) echo '/generated-path' ;;
    --target) echo 'random-target.example.com' ;;
    --server-names) echo '["random-target.example.com"]' ;;
    *) return 1 ;;
    esac
}

reset_config_data
SCRIPT_CONFIG="$(jq '
    .nginx.domain = "stale-reality.example.com" |
    .nginx.cdn = "" |
    .xray.target = "stale-reality.example.com" |
    .xray.serverNames = ["stale-reality.example.com"]
' config.json)"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
CONFIG_DATA['tag']='CDN'
CONFIG_DATA['rules']='N'
CONFIG_DATA['block-bt']='N'
CONFIG_DATA['block-cn']='N'
CONFIG_DATA['block-ad']='N'
CONFIG_DATA['port']='443'
CONFIG_DATA['uuid']=''
CONFIG_DATA['path']='/cdn-test'
CONFIG_DATA['xhttp-mode']='auto'
CONFIG_DATA['cdn']='hydns.org'
CONFIG_DATA['email']=''
CONFIG_DATA['vless_enc_enable']='n'
handler_script_config

jq -e '
    .xray.tag == "CDN" and
    .nginx.cdn == "hydns.org" and
    .nginx.domain == "stale-reality.example.com" and
    .xray.target == "" and
    .xray.serverNames == []
' <<<"${SCRIPT_CONFIG}" >/dev/null
! grep -Eq '^--(target|server-names|short-ids)$' "${GEN_LOG}"

printf '%s\n' \
    '    ssl_ecdh_curve            x25519:secp521r1:secp384r1:secp256r1;' \
    '    ssl_stapling              on;' \
    '    ssl_stapling_verify       on;' \
    >"${NGINX_CONFIG_DIR}/nginx.conf"
printf '%s\n' 'ExecStartPre=/bin/rm -rf /dev/shm/nginx' >"${NGINX_SERVICE_PATH}"
SERVICE_MIGRATION_LOG="${TEST_DIR}/service-migration.log"
function bash() { printf '%s\n' "$*" >>"${SERVICE_MIGRATION_LOG}"; }
function cmd_exists() { return 1; }
function systemctl() { return 0; }
handler_nginx_restart
grep -Fxq "${NGINX_PATH} --service-config" "${SERVICE_MIGRATION_LOG}"
grep -q 'ssl_ecdh_curve[[:space:]]*X25519:prime256v1:secp384r1;' "${NGINX_CONFIG_DIR}/nginx.conf"
! grep -q 'secp256r1' "${NGINX_CONFIG_DIR}/nginx.conf"
! grep -Eq '^[[:space:]]*ssl_stapling(_verify)?[[:space:]]+on;' "${NGINX_CONFIG_DIR}/nginx.conf"
grep -q 'ssl_ecdh_curve[[:space:]]*X25519:prime256v1:secp384r1;' config/nginx/conf/nginx.conf
! grep -Eq '^[[:space:]]*ssl_stapling(_verify)?[[:space:]]+on;' config/nginx/conf/nginx.conf

for unit_source in config/nginx/nginx.service service/nginx.sh; do
    grep -Fq 'install -d -o nginx -g xray-nginx -m 2770 /dev/shm/nginx' "${unit_source}"
    grep -Fq 'install -d -o nginx -g xray-nginx -m 2770 /dev/shm/nginx/tcmalloc' "${unit_source}"
    grep -Eq '^[[:space:]]*UMask=0007[[:space:]]*$' "${unit_source}"
    ! grep -Eq 'rm[[:space:]]+-rf[[:space:]]+/dev/shm/nginx(/|[[:space:]]|$)' "${unit_source}"
    ! grep -Eq 'ExecStopPost=.*dev/shm/nginx' "${unit_source}"
    ! grep -Eq '(rm|unlink).*(to_xray_xhttp|nginx_to_xray_vision)\.sock' "${unit_source}"
done

SERVICE_CONFIG_BODY="$(sed -n '/^function systemctl_config_nginx()/,/^}/p' service/nginx.sh)"
for expected in \
    '/etc/tmpfiles.d/xray-nginx-shm.conf' \
    'd /dev/shm/nginx 2770 nginx xray-nginx -' \
    'd /dev/shm/nginx/tcmalloc 2770 nginx xray-nginx -' \
    'systemd-tmpfiles --create'; do
    grep -Fq "${expected}" <<<"${SERVICE_CONFIG_BODY}"
done
grep -Eq 'groupadd.*xray-nginx' <<<"${SERVICE_CONFIG_BODY}"
grep -Eq 'usermod.*xray-nginx.*nginx' <<<"${SERVICE_CONFIG_BODY}"
grep -Eq 'usermod.*xray-nginx.*xray' <<<"${SERVICE_CONFIG_BODY}"
grep -Fq 'systemctl restart nginx' <<<"${SERVICE_CONFIG_BODY}"
grep -Fq 'systemctl restart xray' <<<"${SERVICE_CONFIG_BODY}"
grep -Eq -- '--service-config([[:space:]]*\||[[:space:]]*\))' service/nginx.sh
awk '/^[[:space:]]*service-config\)/,/^[[:space:]]*;;/' service/nginx.sh | grep -q 'systemctl_config_nginx'
UPDATE_BODY="$(awk '/^[[:space:]]*update\)/,/^[[:space:]]*;;/' service/nginx.sh)"
grep -q 'migrate_nginx_runtime_config' <<<"${UPDATE_BODY}"
grep -q 'systemctl_config_nginx' <<<"${UPDATE_BODY}"
[[ "$(grep -c 'systemctl reset-failed xray' core/handler.sh)" -ge 2 ]]
grep -q 'systemctl reset-failed nginx' core/handler.sh

cp config/nginx/conf/sites-available/cdn.example.com.conf "${NGINX_CONFIG_DIR}/sites-available/hydns.org.conf"
cp config/nginx/conf/sites-available/domain.example.com.conf "${NGINX_CONFIG_DIR}/sites-available/stale-reality.example.com.conf"
SCRIPT_CONFIG="$(jq '
    .xray.tag = "CDN" |
    .nginx.domain = "stale-reality.example.com" |
    .nginx.cdn = "hydns.org"
' <<<"${SCRIPT_CONFIG}")"
function handler_cloudreve_v3() { :; }
function handler_cloudreve_v4() { :; }
function handler_nginx_restart() { :; }
function handler_restart() { :; }
function write_config() { :; }
handler_web 'v3'
grep -q '^[[:space:]]*include web/cloudreve.conf;' "${NGINX_CONFIG_DIR}/sites-available/hydns.org.conf"
grep -q '# include web/cloudreve.conf;' "${NGINX_CONFIG_DIR}/sites-available/stale-reality.example.com.conf"

SCRIPT_CONFIG="$(jq '.xray.tag = "SNI"' <<<"${SCRIPT_CONFIG}")"
handler_web 'v3'
grep -q '^[[:space:]]*include web/cloudreve.conf;' "${NGINX_CONFIG_DIR}/sites-available/stale-reality.example.com.conf"

# Reinstalling CDN over an old SNI-generated site must rebuild a direct TLS
# listener instead of retaining the SNI Unix Socket listener.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=hydns.org' \
    -addext 'subjectAltName=DNS:hydns.org' \
    -keyout "${TEST_DIR}/hydns.key" \
    -out "${TEST_DIR}/hydns.crt" >/dev/null 2>&1
SCRIPT_CONFIG="$(jq \
    --arg cert "${TEST_DIR}/hydns.crt" \
    --arg key "${TEST_DIR}/hydns.key" '
    .xray.tag = "CDN" |
    .xray.path = "/cdn-test" |
    .nginx.domain = "stale-reality.example.com" |
    .nginx.cdn = "hydns.org" |
    .nginx.certificates.cdn = {
        hostname:"hydns.org", source:"2", fullchain:$cert, privkey:$key
    }
' <<<"${SCRIPT_CONFIG}")"
reset_config_data
CONFIG_DATA['only-change-domain']='n'
handler_change_domain 'cdn' 'n'
grep -q 'listen 443 ssl reuseport;' "${NGINX_CONFIG_DIR}/sites-available/hydns.org.conf"
grep -q 'listen \[::\]:443 ssl reuseport;' "${NGINX_CONFIG_DIR}/sites-available/hydns.org.conf"
grep -q 'server_name[[:space:]]*hydns.org;' "${NGINX_CONFIG_DIR}/sites-available/hydns.org.conf"
! grep -q 'cdn_to_nginx.sock' "${NGINX_CONFIG_DIR}/sites-available/hydns.org.conf"
! grep -q 'proxy_protocol' "${NGINX_CONFIG_DIR}/sites-available/hydns.org.conf"

# A fresh CDN certificate choice must use CDN-specific wording only.
SCRIPT_CONFIG="$(jq 'del(.nginx.certificates.cdn)' <<<"${SCRIPT_CONFIG}")"
reset_config_data
CONFIG_DATA['only-change-domain']='n'
CDN_PROMPT_LOG="${TEST_DIR}/cdn-prompt.log"
handler_change_domain 'cdn' 'n' 'n' 2>"${CDN_PROMPT_LOG}" <<EOF
2
${TEST_DIR}/hydns.crt
${TEST_DIR}/hydns.key
EOF
grep -Fq 'CDN site TLS certificate' "${CDN_PROMPT_LOG}"
! grep -qi 'SNI' "${CDN_PROMPT_LOG}"

# Preparing pure CDN mode disables the stale SNI direct site and never calls
# the direct-domain branch.
touch "${NGINX_CONFIG_DIR}/sites-enabled/stale-reality.example.com.conf"
PREPARE_LOG="${TEST_DIR}/prepare.log"
: >"${PREPARE_LOG}"
function handler_change_domain() { printf 'domain:%s\n' "$*" >>"${PREPARE_LOG}"; }
function handler_web() { printf 'web:%s\n' "$*" >>"${PREPARE_LOG}"; }
handler_prepare_protocol_services 'normal'
[[ "$(head -n 1 "${PREPARE_LOG}")" == 'domain:cdn n n' ]]
grep -Fxq 'web:normal n' "${PREPARE_LOG}"
! grep -Fxq 'domain:domain n n' "${PREPARE_LOG}"
[[ ! -e "${NGINX_CONFIG_DIR}/sites-enabled/stale-reality.example.com.conf" ]]
[[ "$(jq -r '.nginx.domain' <<<"${SCRIPT_CONFIG}")" == '' ]]

# Pure CDN Xray output contains XHTTP only: no REALITY settings or public port.
handler_xray_config
jq -e '
    .inbounds[1].protocol == "vless" and
    .inbounds[1].streamSettings.network == "xhttp" and
    (.inbounds[1].streamSettings | has("realitySettings") | not) and
    (.inbounds[1] | has("port") | not) and
    (.inbounds[1].listen | endswith(",0660"))
' "${XRAY_CONFIG_PATH}" >/dev/null
xray_bin="${XRAY_BIN:-$(command -v xray || true)}"
if [[ -n "${xray_bin}" ]]; then
    # A Windows Xray binary cannot build a Unix-domain listener. Replace only
    # the platform-specific endpoint while validating the CDN protocol config.
    jq '
        .log = {loglevel:"none"} |
        .inbounds[1].listen = "127.0.0.1" |
        .inbounds[1].port = 24444
    ' \
        "${XRAY_CONFIG_PATH}" >"${TEST_DIR}/cdn-xray-test.json"
    "${xray_bin}" run -test -c "${TEST_DIR}/cdn-xray-test.json"
fi

SCRIPT_CONFIG="$(jq '.xray.tag = "CDN"' <<<"${SCRIPT_CONFIG}")"
XRAY_CONFIG_CALLS=0
XRAY_CONFIG_ARG='not-called'
X25519_CALLS=0
MLDSA_CALLS=0
function load_i18n() { :; }
function handler_prepare_protocol_services() { :; }
function handler_xray_config() {
    XRAY_CONFIG_CALLS=$((XRAY_CONFIG_CALLS + 1))
    XRAY_CONFIG_ARG="${1:-}"
    return 0
}
function handler_x25519_config() {
    X25519_CALLS=$((X25519_CALLS + 1))
    return 0
}
function handler_mldsa65_config() {
    MLDSA_CALLS=$((MLDSA_CALLS + 1))
    return 0
}
main '--xray-config' 'normal'
[[ "${XRAY_CONFIG_CALLS}" -eq 1 ]]
[[ -z "${XRAY_CONFIG_ARG}" ]]
[[ "${X25519_CALLS}" -eq 0 ]]
[[ "${MLDSA_CALLS}" -eq 0 ]]

NGINX_CALL_LOG="${TEST_DIR}/nginx-calls.log"
function ensure_service_users() { :; }
function cmd_exists() { [[ "$1" == 'nginx' ]]; }
function bash() { printf '%s\n' "$*" >>"${NGINX_CALL_LOG}"; }

: >"${NGINX_CALL_LOG}"
handler_nginx_install
grep -Fxq "${NGINX_PATH} --service-config" "${NGINX_CALL_LOG}"

: >"${NGINX_CALL_LOG}"
handler_nginx_update
grep -Fxq "${NGINX_PATH} --update --brotli" "${NGINX_CALL_LOG}"

# Stopping an absent Cloudreve service is cleanup, not an installation path.
DOCKER_CALLS=0
function cmd_exists() { return 1; }
function handler_docker() {
    DOCKER_CALLS=$((DOCKER_CALLS + 1))
    return 0
}
function exec_docker() {
    DOCKER_CALLS=$((DOCKER_CALLS + 1))
    return 0
}
handler_cloudreve_v3 'stop'
handler_cloudreve_v4 'stop'
[[ "${DOCKER_CALLS}" -eq 0 ]]

echo "CDN mode tests passed"
