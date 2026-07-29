#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

mkdir -p \
    "${TEST_DIR}/home/.xray-script" \
    "${TEST_DIR}/nginx/sites-available" \
    "${TEST_DIR}/nginx/sites-enabled"
cp config.json "${TEST_DIR}/script.json"
cp config.json "${TEST_DIR}/home/.xray-script/config.json"
export HOME="${TEST_DIR}/home"
export SCRIPT_CONFIG_PATH_OVERRIDE="${TEST_DIR}/script.json"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/xray.json"
export NGINX_CONFIG_DIR_OVERRIDE="${TEST_DIR}/nginx"
export NGINX_SERVICE_PATH_OVERRIDE="${TEST_DIR}/nginx.service"

source core/handler.sh
I18N_DATA="$(jq . i18n/en.json)"

function prepare_site() {
    local template="$1"
    local domain="$2"
    local path="$3"
    local target="${NGINX_CONFIG_DIR}/sites-available/${domain}.conf"

    cp "config/nginx/conf/sites-available/${template}.example.com.conf" "${target}"
    sed -i \
        -e "s|example.com|${domain}|g" \
        -e "s|/yourpath|${path}|g" \
        "${target}"
}

prepare_site cdn cdn.example.test /old-path
# Simulate an older installation that copied, rather than linked, the enabled
# site. Updating sites-available alone must not leave this stale active copy.
cp "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf" \
    "${NGINX_CONFIG_DIR}/sites-enabled/cdn.example.test.conf"
SCRIPT_CONFIG="$(jq '
    .xray.tag = "CDN" |
    .xray.path = "/new-path" |
    .nginx.cdn = "cdn.example.test"
' config.json)"

handler_sync_nginx_xhttp_path
[[ "${NGINX_CONFIG_CHANGED}" -eq 1 ]]
grep -Fq 'location /new-path {' "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf"
grep -Fq '/usr/local/nginx/conf/certs/cdn.example.test/fullchain.pem' \
    "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf"
[[ -L "${NGINX_CONFIG_DIR}/sites-enabled/cdn.example.test.conf" ]]
[[ "$(readlink "${NGINX_CONFIG_DIR}/sites-enabled/cdn.example.test.conf")" == \
    "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf" ]]
grep -Fq 'location /new-path {' "${NGINX_CONFIG_DIR}/sites-enabled/cdn.example.test.conf"

handler_sync_nginx_xhttp_path
[[ "${NGINX_CONFIG_CHANGED}" -eq 0 ]]

# SNI has two managed sites and both must track the same XHTTP path.
prepare_site domain origin.example.test /old-sni
sed -i 's|location /new-path {|location /old-sni {|' \
    "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf"
SCRIPT_CONFIG="$(jq '
    .xray.tag = "SNI" |
    .xray.path = "sni-path-without-leading-slash" |
    .nginx.domain = "origin.example.test" |
    .nginx.cdn = "cdn.example.test"
' config.json)"
handler_sync_nginx_xhttp_path
[[ "${NGINX_CONFIG_CHANGED}" -eq 1 ]]
grep -Fq 'location /sni-path-without-leading-slash {' \
    "${NGINX_CONFIG_DIR}/sites-available/origin.example.test.conf"
grep -Fq 'location /sni-path-without-leading-slash {' \
    "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf"

# Rendering is two-phase: one malformed site must prevent every replacement.
sed -i 's|location /sni-path-without-leading-slash {|location /before-atomic-test {|' \
    "${NGINX_CONFIG_DIR}/sites-available/origin.example.test.conf"
printf '%s\n' '# unmanaged config' \
    >"${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf"
SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.path = "/must-not-partially-apply"')"
if handler_sync_nginx_xhttp_path >/dev/null 2>&1; then
    echo "Malformed managed site was accepted" >&2
    exit 1
fi
grep -Fq 'location /before-atomic-test {' \
    "${NGINX_CONFIG_DIR}/sites-available/origin.example.test.conf"

# A commit-time failure is also transactional. Force the second enabled-site
# replacement to fail after the first site and link have changed, then verify
# that both regular enabled copies and both source files are byte-identical.
prepare_site domain origin.example.test /atomic-old
prepare_site cdn cdn.example.test /atomic-old
rm -f -- "${NGINX_CONFIG_DIR}/sites-enabled/origin.example.test.conf"
cp "${NGINX_CONFIG_DIR}/sites-available/origin.example.test.conf" \
    "${NGINX_CONFIG_DIR}/sites-enabled/origin.example.test.conf"
rm -f -- "${NGINX_CONFIG_DIR}/sites-enabled/cdn.example.test.conf"
cp "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf" \
    "${NGINX_CONFIG_DIR}/sites-enabled/cdn.example.test.conf"
ATOMIC_HASH_BEFORE="$(sha256sum \
    "${NGINX_CONFIG_DIR}/sites-available/origin.example.test.conf" \
    "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf" \
    "${NGINX_CONFIG_DIR}/sites-enabled/origin.example.test.conf" \
    "${NGINX_CONFIG_DIR}/sites-enabled/cdn.example.test.conf")"
SCRIPT_CONFIG="$(jq '
    .xray.tag = "SNI" |
    .xray.path = "/atomic-new" |
    .nginx.domain = "origin.example.test" |
    .nginx.cdn = "cdn.example.test"
' config.json)"
LN_UPDATE_CALLS=0
function ln() {
    if [[ "${1:-}" == '-sfn' ]]; then
        LN_UPDATE_CALLS=$((LN_UPDATE_CALLS + 1))
        [[ "${LN_UPDATE_CALLS}" -lt 2 ]] || return 1
    fi
    command ln "$@"
}
if handler_sync_nginx_xhttp_path >/dev/null 2>&1; then
    echo "Commit-time enabled-site failure was accepted" >&2
    exit 1
fi
unset -f ln
[[ "${LN_UPDATE_CALLS}" -eq 2 ]]
[[ ! -L "${NGINX_CONFIG_DIR}/sites-enabled/origin.example.test.conf" ]]
[[ ! -L "${NGINX_CONFIG_DIR}/sites-enabled/cdn.example.test.conf" ]]
[[ "$(sha256sum \
    "${NGINX_CONFIG_DIR}/sites-available/origin.example.test.conf" \
    "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf" \
    "${NGINX_CONFIG_DIR}/sites-enabled/origin.example.test.conf" \
    "${NGINX_CONFIG_DIR}/sites-enabled/cdn.example.test.conf")" == \
    "${ATOMIC_HASH_BEFORE}" ]]

# A regular Xray restart reconciles a drifted CDN path and reloads Nginx once.
prepare_site cdn cdn.example.test /drifted-path
SCRIPT_CONFIG="$(jq '
    .xray.tag = "CDN" |
    .xray.path = "/restart-synced-path" |
    .nginx.cdn = "cdn.example.test"
' config.json)"
NGINX_RESTARTS=0
function handler_nginx_restart() {
    NGINX_RESTARTS=$((NGINX_RESTARTS + 1))
}
function systemctl() {
    case "$*" in
    'reset-failed xray' | '-q restart xray' | '-q enable xray') return 0 ;;
    '-q is-active xray') return 0 ;;
    '-q is-enabled xray') return 0 ;;
    '-q is-active nginx' | '-q is-enabled nginx') return 1 ;;
    *) echo "Unexpected systemctl call: $*" >&2; return 1 ;;
    esac
}

handler_restart
[[ "${NGINX_RESTARTS}" -eq 1 ]]
grep -Fq 'location /restart-synced-path {' \
    "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf"

handler_restart
[[ "${NGINX_RESTARTS}" -eq 1 ]]

# Configurations created before cdnBackend existed must keep Nginx semantics.
prepare_site cdn cdn.example.test /legacy-old-path
SCRIPT_CONFIG="$(jq '
    .xray.tag = "CDN" |
    del(.xray.cdnBackend) |
    .xray.path = "/legacy-new-path" |
    .nginx.cdn = "cdn.example.test"
' config.json)"
handler_sync_nginx_xhttp_path
[[ "${NGINX_CONFIG_CHANGED}" -eq 1 ]]
grep -Fq 'location /legacy-new-path {' \
    "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf"

# Direct Xray CDN has no managed Nginx site. Path reconciliation and a normal
# Xray restart must therefore succeed without touching Nginx.
rm -f -- \
    "${NGINX_CONFIG_DIR}/sites-available/cdn.example.test.conf" \
    "${NGINX_CONFIG_DIR}/sites-enabled/cdn.example.test.conf"
SCRIPT_CONFIG="$(jq '
    .xray.tag = "CDN" |
    .xray.cdnBackend = "xray" |
    .xray.path = "/direct-path" |
    .nginx.cdn = "cdn.example.test"
' config.json)"
NGINX_RESTARTS=0
function handler_disable_nginx_cron() { return 0; }
function handler_cloudreve_v3() { return 0; }
function handler_cloudreve_v4() { return 0; }
handler_sync_nginx_xhttp_path
[[ "${NGINX_CONFIG_CHANGED}" -eq 0 ]]
handler_restart
[[ "${NGINX_RESTARTS}" -eq 0 ]]

echo "Nginx path sync tests passed"
