#!/usr/bin/env bash
set -euo pipefail

readonly PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_DIR}"' EXIT

cd "${PROJECT_ROOT}"

function fail_test() {
    echo "$1" >&2
    exit 1
}

# Verify the prebuilt update path reloads the newly installed executable.
NGINX_FUNCTIONS="$(sed -n \
    -e '/^function install_nginx_file_atomically()/,/^}/p' \
    -e '/^function install_nginx_binary_atomically()/,/^}/p' \
    -e '/^function install_nginx_modules_atomically()/,/^}/p' \
    -e '/^function reload_nginx_after_binary_update()/,/^}/p' \
    service/nginx.sh)"
eval "${NGINX_FUNCTIONS}"

printf '%s\n' old-binary >"${TEST_DIR}/nginx"
printf '%s\n' new-binary >"${TEST_DIR}/nginx.release"
OLD_NGINX_INODE="$(stat -c %i "${TEST_DIR}/nginx")"
install_nginx_binary_atomically "${TEST_DIR}/nginx.release" "${TEST_DIR}/nginx"
[[ "$(cat "${TEST_DIR}/nginx")" == 'new-binary' ]] ||
    fail_test 'prebuilt Nginx binary was not installed'
[[ "$(stat -c %i "${TEST_DIR}/nginx")" != "${OLD_NGINX_INODE}" ]] ||
    fail_test 'prebuilt Nginx binary was overwritten in place'

mkdir -p "${TEST_DIR}/release-modules" "${TEST_DIR}/installed-modules"
printf '%s\n' old-module >"${TEST_DIR}/installed-modules/ngx_test.so"
printf '%s\n' new-module >"${TEST_DIR}/release-modules/ngx_test.so"
OLD_MODULE_INODE="$(stat -c %i "${TEST_DIR}/installed-modules/ngx_test.so")"
install_nginx_modules_atomically \
    "${TEST_DIR}/release-modules" "${TEST_DIR}/installed-modules"
[[ "$(cat "${TEST_DIR}/installed-modules/ngx_test.so")" == 'new-module' ]] ||
    fail_test 'prebuilt Nginx module was not installed'
[[ "$(stat -c %i "${TEST_DIR}/installed-modules/ngx_test.so")" != "${OLD_MODULE_INODE}" ]] ||
    fail_test 'prebuilt Nginx module was overwritten in place'

SYSTEMCTL_LOG="${TEST_DIR}/nginx-systemctl.log"
NGINX_TESTS=0
NGINX_ACTIVE=1
function systemctl() {
    printf '%s\n' "$*" >>"${SYSTEMCTL_LOG}"
    if [[ "$*" == 'is-active --quiet nginx' ]]; then
        [[ "${NGINX_ACTIVE}" -eq 1 ]]
    fi
}
function nginx() {
    [[ "$*" == '-t' ]] || return 99
    NGINX_TESTS=$((NGINX_TESTS + 1))
}
reload_nginx_after_binary_update
[[ "${NGINX_TESTS}" -eq 1 ]] || fail_test 'updated Nginx config was not validated'
grep -Fxq 'restart nginx' "${SYSTEMCTL_LOG}" ||
    fail_test 'prebuilt Nginx update did not restart the active service'
NGINX_ACTIVE=0
: >"${SYSTEMCTL_LOG}"
reload_nginx_after_binary_update
[[ "${NGINX_TESTS}" -eq 2 ]] ||
    fail_test 'inactive Nginx configuration was not validated after update'
if grep -Fxq 'restart nginx' "${SYSTEMCTL_LOG}"; then
    fail_test 'inactive Nginx service was unexpectedly started after update'
fi
UPDATE_BODY="$(awk '/^[[:space:]]*update\)/,/^[[:space:]]*;;/' service/nginx.sh)"
grep -Fq 'reload_nginx_after_binary_update ||' <<<"${UPDATE_BODY}" ||
    fail_test 'prebuilt Nginx update can hide a validation or restart failure'

# Exercise route-state migration with command fakes. The route from the old
# package must be deleted before the new route set is committed.
LAN_ROOT="${TEST_DIR}/lan"
BIN_DIR="${TEST_DIR}/bin"
mkdir -p "${LAN_ROOT}" "${BIN_DIR}"
printf '%s\n' \
    '{"tunName":"xray0","mode":"host","lanInterface":"","remoteCidrs":["192.168.20.0/24"]}' \
    >"${LAN_ROOT}/site.json"
IP_LOG="${TEST_DIR}/ip.log"
cp tests/fixtures/fake-lan-ip.sh "${BIN_DIR}/ip"
chmod +x "${BIN_DIR}/ip"
printf '%s\n' '192.168.10.0/24' >"${TEST_DIR}/routes.state"
PATH="${BIN_DIR}:${PATH}" \
IP_LOG="${IP_LOG}" \
XRAY_LAN_DIR="${LAN_ROOT}" \
XRAY_LAN_ROUTE_STATE_FILE="${TEST_DIR}/routes.state" \
bash config/lan/xray-lan-net.sh start
grep -Fxq -- '-4 route del 192.168.10.0/24 dev xray0' "${IP_LOG}" ||
    fail_test 'LAN upgrade did not remove the obsolete managed route'
[[ "$(cat "${TEST_DIR}/routes.state")" == '192.168.20.0/24' ]] ||
    fail_test 'LAN route state was not replaced with the new route set'

printf '%s\n' '192.168.10.0/24' >"${TEST_DIR}/routes.state"
if PATH="${BIN_DIR}:${PATH}" \
    IP_LOG="${IP_LOG}" \
    IP_FAIL_MATCH='route replace' \
    XRAY_LAN_DIR="${LAN_ROOT}" \
    XRAY_LAN_ROUTE_STATE_FILE="${TEST_DIR}/routes.state" \
    bash config/lan/xray-lan-net.sh start; then
    fail_test 'LAN route setup hid a route replacement failure'
fi
[[ "$(cat "${TEST_DIR}/routes.state")" == '192.168.10.0/24' ]] ||
    fail_test 'LAN route state changed after route setup failed'
if compgen -G "${TEST_DIR}/routes.state.tmp.*" >/dev/null; then
    fail_test 'LAN route setup left a temporary state file after failure'
fi

echo 'Service update regression tests passed'
