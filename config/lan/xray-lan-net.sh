#!/usr/bin/env bash
set -euo pipefail

readonly CONFIG_DIR="${XRAY_LAN_DIR:-/usr/local/etc/xray-lan}"
readonly META_FILE="${CONFIG_DIR}/site.json"
readonly STATE_FILE="/run/xray-lan-network.state"
readonly ROUTE_STATE_FILE="${XRAY_LAN_ROUTE_STATE_FILE:-/run/xray-lan-routes.state}"

[[ -r "${META_FILE}" ]] || { echo "Missing ${META_FILE}" >&2; exit 1; }

TUN_NAME="$(jq -r '.tunName' "${META_FILE}")"
MODE="$(jq -r '.mode' "${META_FILE}")"
LAN_INTERFACE="$(jq -r '.lanInterface // ""' "${META_FILE}")"
mapfile -t REMOTE_CIDRS < <(jq -r '.remoteCidrs[]?' "${META_FILE}")

function wait_for_tun() {
    local attempt
    for ((attempt = 0; attempt < 100; attempt++)); do
        ip link show dev "${TUN_NAME}" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "TUN interface ${TUN_NAME} was not created" >&2
    return 1
}

function add_forward_rules() {
    [[ "${MODE}" == "gateway" ]] || return 0
    [[ -n "${LAN_INTERFACE}" ]] || { echo "Gateway mode requires lanInterface" >&2; return 1; }
    command -v iptables >/dev/null 2>&1 || { echo "Gateway mode requires iptables" >&2; return 1; }

    if ! iptables -C FORWARD -i "${LAN_INTERFACE}" -o "${TUN_NAME}" -m comment --comment xray-lan -j ACCEPT 2>/dev/null; then
        iptables -I FORWARD 1 -i "${LAN_INTERFACE}" -o "${TUN_NAME}" -m comment --comment xray-lan -j ACCEPT
    fi
    if ! iptables -C FORWARD -i "${TUN_NAME}" -o "${LAN_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment xray-lan -j ACCEPT 2>/dev/null; then
        iptables -I FORWARD 1 -i "${TUN_NAME}" -o "${LAN_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment xray-lan -j ACCEPT
    fi
}

function remove_forward_rules() {
    [[ "${MODE}" == "gateway" && -n "${LAN_INTERFACE}" ]] || return 0
    command -v iptables >/dev/null 2>&1 || return 0
    while iptables -C FORWARD -i "${LAN_INTERFACE}" -o "${TUN_NAME}" -m comment --comment xray-lan -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -i "${LAN_INTERFACE}" -o "${TUN_NAME}" -m comment --comment xray-lan -j ACCEPT || break
    done
    while iptables -C FORWARD -i "${TUN_NAME}" -o "${LAN_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment xray-lan -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -i "${TUN_NAME}" -o "${LAN_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment xray-lan -j ACCEPT || break
    done
}

function start_network() (
    local route_state_temp=''
    route_state_temp="$(mktemp "${ROUTE_STATE_FILE}.tmp.XXXXXX")" || return 1
    trap '[[ -z "${route_state_temp}" ]] || rm -f -- "${route_state_temp}"' EXIT

    wait_for_tun
    ip link set dev "${TUN_NAME}" up

    local cidr existing
    local old_routes=()
    local route_is_current=0
    if [[ -r "${ROUTE_STATE_FILE}" ]]; then
        mapfile -t old_routes <"${ROUTE_STATE_FILE}"
    fi
    for cidr in "${old_routes[@]}"; do
        [[ -n "${cidr}" ]] || continue
        route_is_current=0
        local current_cidr
        for current_cidr in "${REMOTE_CIDRS[@]}"; do
            if [[ "${cidr}" == "${current_cidr}" ]]; then
                route_is_current=1
                break
            fi
        done
        if [[ "${route_is_current}" -eq 0 ]]; then
            ip -4 route del "${cidr}" dev "${TUN_NAME}" 2>/dev/null || true
        fi
    done
    for cidr in "${REMOTE_CIDRS[@]}"; do
        existing="$(ip -4 route show exact "${cidr}" 2>/dev/null || true)"
        if [[ -n "${existing}" && "${existing}" != *" dev ${TUN_NAME}"* ]]; then
            echo "Refusing to replace existing route: ${existing}" >&2
            return 1
        fi
        ip -4 route replace "${cidr}" dev "${TUN_NAME}" metric 5
        printf '%s\n' "${cidr}" >>"${route_state_temp}"
    done
    mv -fT -- "${route_state_temp}" "${ROUTE_STATE_FILE}"
    route_state_temp=''

    if [[ "${MODE}" == "gateway" ]]; then
        if [[ ! -f "${STATE_FILE}" ]]; then
            {
                echo "ip_forward=$(sysctl -n net.ipv4.ip_forward)"
                echo "rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter)"
            } >"${STATE_FILE}"
        fi
        sysctl -q -w net.ipv4.ip_forward=1
        sysctl -q -w net.ipv4.conf.all.rp_filter=0
        add_forward_rules
    fi
)

function stop_network() {
    local cidr
    remove_forward_rules
    local routes_to_remove=("${REMOTE_CIDRS[@]}")
    if [[ -r "${ROUTE_STATE_FILE}" ]]; then
        mapfile -t routes_to_remove <"${ROUTE_STATE_FILE}"
    fi
    for cidr in "${routes_to_remove[@]}"; do
        [[ -n "${cidr}" ]] || continue
        ip -4 route del "${cidr}" dev "${TUN_NAME}" 2>/dev/null || true
    done
    rm -f -- "${ROUTE_STATE_FILE}"

    if [[ -f "${STATE_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
        sysctl -q -w "net.ipv4.ip_forward=${ip_forward}" || true
        sysctl -q -w "net.ipv4.conf.all.rp_filter=${rp_filter}" || true
        rm -f "${STATE_FILE}"
    fi
}

case "${1:-}" in
start) start_network ;;
stop) stop_network ;;
*) echo "Usage: $0 {start|stop}" >&2; exit 2 ;;
esac
