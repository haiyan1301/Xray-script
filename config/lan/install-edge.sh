#!/usr/bin/env bash
set -euo pipefail

readonly SOURCE_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
readonly INSTALL_DIR="/usr/local/etc/xray-lan"
readonly NET_SCRIPT="/usr/local/libexec/xray-lan-net"
readonly UNIT_FILE="/etc/systemd/system/xray-lan.service"

[[ ${EUID} -eq 0 ]] || { echo "Run this installer as root." >&2; exit 1; }

function uninstall_edge() {
    systemctl disable --now xray-lan.service 2>/dev/null || true
    rm -f "${UNIT_FILE}" "${NET_SCRIPT}"
    rm -rf "${INSTALL_DIR}"
    systemctl daemon-reload
    echo "Xray LAN edge removed."
}

if [[ "${1:-}" == "uninstall" ]]; then
    uninstall_edge
    exit 0
fi

for command_name in xray jq ip systemctl; do
    command -v "${command_name}" >/dev/null 2>&1 || { echo "Missing command: ${command_name}" >&2; exit 1; }
done
[[ -c /dev/net/tun ]] || { echo "/dev/net/tun is unavailable." >&2; exit 1; }

XRAY_BIN="$(command -v xray)"
TEST_CONFIG="$(mktemp)"
trap 'rm -f "${TEST_CONFIG}"' EXIT
jq '(.inbounds[] | select(.protocol == "tun") | .settings.name) = "xraytest0"' "${SOURCE_DIR}/config.json" >"${TEST_CONFIG}"
"${XRAY_BIN}" run -test -config "${TEST_CONFIG}"
rm -f "${TEST_CONFIG}"
trap - EXIT

if [[ -d "${INSTALL_DIR}" ]]; then
    cp -a "${INSTALL_DIR}" "${INSTALL_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
fi
install -d -m 700 "${INSTALL_DIR}" /usr/local/libexec
install -m 600 "${SOURCE_DIR}/config.json" "${INSTALL_DIR}/config.json"
install -m 600 "${SOURCE_DIR}/site.json" "${INSTALL_DIR}/site.json"
install -m 755 "${SOURCE_DIR}/xray-lan-net.sh" "${NET_SCRIPT}"
sed "s|@XRAY_BIN@|${XRAY_BIN}|g" "${SOURCE_DIR}/xray-lan.service" >"${UNIT_FILE}"
chmod 644 "${UNIT_FILE}"

systemctl daemon-reload
systemctl enable xray-lan.service
systemctl restart xray-lan.service
systemctl --no-pager --full status xray-lan.service || true
echo "Xray LAN edge installed."
