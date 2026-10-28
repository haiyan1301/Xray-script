#!/usr/bin/env bash
set -euo pipefail

readonly CONFIG_DIR="${XRAY_LAN_DIR:-/usr/local/etc/xray-lan}"
readonly META_FILE="${CONFIG_DIR}/site.json"
readonly STATE_FILE="${XRAY_LAN_STATE_FILE:-/run/xray-lan-network.state}"
readonly ROUTE_STATE_FILE="${XRAY_LAN_ROUTE_STATE_FILE:-/run/xray-lan-routes.state}"
# 本次放行的 FORWARD 规则（每行一条 iptables 参数串）。与 STATE_FILE 分开存放，
# 因为 STATE_FILE 会被 source 成 shell 变量，不能混入规则文本。
readonly FORWARD_STATE_FILE="${XRAY_LAN_FORWARD_STATE_FILE:-/run/xray-lan-forward.state}"

[[ -r "${META_FILE}" ]] || { echo "Missing ${META_FILE}" >&2; exit 1; }

TUN_NAME="$(jq -r '.tunName' "${META_FILE}")"
MODE="$(jq -r '.mode' "${META_FILE}")"
LAN_INTERFACE="$(jq -r '.lanInterface // ""' "${META_FILE}")"
mapfile -t REMOTE_CIDRS < <(jq -r '.remoteCidrs[]?' "${META_FILE}")
FORWARD_SPEC_LAN_TO_TUN=()
FORWARD_SPEC_TUN_TO_LAN=()

function wait_for_tun() {
    local attempt
    for ((attempt = 0; attempt < 100; attempt++)); do
        ip link show dev "${TUN_NAME}" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "TUN interface ${TUN_NAME} was not created" >&2
    return 1
}

function forward_rule_specs() {
    FORWARD_SPEC_LAN_TO_TUN=(-i "${LAN_INTERFACE}" -o "${TUN_NAME}" -m comment --comment xray-lan -j ACCEPT)
    # ESTABLISHED,RELATED 是 iptables 的单个参数值，不是数组元素分隔符（shellcheck 误报）
    # shellcheck disable=SC2054
    FORWARD_SPEC_TUN_TO_LAN=(-i "${TUN_NAME}" -o "${LAN_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment xray-lan -j ACCEPT)
}

# 从状态文件中删除一条已记录（或已回收）的规则参数串。
function forward_state_drop() {
    local spec="$1" line
    local -a kept=()

    [[ -r "${FORWARD_STATE_FILE}" ]] || return 0
    while IFS= read -r line; do
        if [[ -n "${line}" && "${line}" != "${spec}" ]]; then
            kept+=("${line}")
        fi
    done <"${FORWARD_STATE_FILE}"
    if ((${#kept[@]})); then
        if printf '%s\n' "${kept[@]}" >"${FORWARD_STATE_FILE}.tmp" &&
            mv -fT -- "${FORWARD_STATE_FILE}.tmp" "${FORWARD_STATE_FILE}"; then
            return 0
        fi
        rm -f -- "${FORWARD_STATE_FILE}.tmp"
    else
        rm -f -- "${FORWARD_STATE_FILE}"
    fi
}

function add_forward_rules() {
    local -a recorded=()

    [[ "${MODE}" == "gateway" ]] || return 0
    [[ -n "${LAN_INTERFACE}" ]] || { echo "Gateway mode requires lanInterface" >&2; return 1; }
    command -v iptables >/dev/null 2>&1 || { echo "Gateway mode requires iptables" >&2; return 1; }

    forward_rule_specs
    if ! iptables -C FORWARD "${FORWARD_SPEC_LAN_TO_TUN[@]}" 2>/dev/null; then
        iptables -I FORWARD 1 "${FORWARD_SPEC_LAN_TO_TUN[@]}"
        forward_lan_to_tun_added=1
        recorded+=("${FORWARD_SPEC_LAN_TO_TUN[*]}")
    fi
    if ! iptables -C FORWARD "${FORWARD_SPEC_TUN_TO_LAN[@]}" 2>/dev/null; then
        iptables -I FORWARD 1 "${FORWARD_SPEC_TUN_TO_LAN[@]}"
        forward_tun_to_lan_added=1
        recorded+=("${FORWARD_SPEC_TUN_TO_LAN[*]}")
    fi
    ((${#recorded[@]})) || return 0
    # 记录本次实际插入的规则，供 stop/回滚按原样精确删除；写失败不影响放行，
    # 回收时退化为下面的注释匹配兜底。
    printf '%s\n' "${recorded[@]}" >>"${FORWARD_STATE_FILE}" 2>/dev/null || true
}

function remove_forward_rules() {
    local line
    local -a spec=()

    [[ "${MODE}" == "gateway" && -n "${LAN_INTERFACE}" ]] || return 0
    command -v iptables >/dev/null 2>&1 || return 0

    # 优先按记录的原样参数删除（即使规则被改写过也能精确回收）。
    if [[ -r "${FORWARD_STATE_FILE}" ]]; then
        while IFS= read -r line; do
            [[ -n "${line}" ]] || continue
            spec=()
            read -r -a spec <<<"${line}"
            iptables -C FORWARD "${spec[@]}" 2>/dev/null &&
                iptables -D FORWARD "${spec[@]}" 2>/dev/null || true
        done <"${FORWARD_STATE_FILE}"
    fi
    rm -f -- "${FORWARD_STATE_FILE}" 2>/dev/null || true

    # 兜底：/run 是 tmpfs，重启后没有记录，按注释匹配回收残留规则。
    while iptables -C FORWARD -i "${LAN_INTERFACE}" -o "${TUN_NAME}" -m comment --comment xray-lan -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -i "${LAN_INTERFACE}" -o "${TUN_NAME}" -m comment --comment xray-lan -j ACCEPT || break
    done
    while iptables -C FORWARD -i "${TUN_NAME}" -o "${LAN_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment xray-lan -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -i "${TUN_NAME}" -o "${LAN_INTERFACE}" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment xray-lan -j ACCEPT || break
    done
}

# Match the complete device token on every route. A substring check for
# " dev xray0" also accepts xray01 and can silently adopt a foreign route.
function route_uses_tun() {
    awk -v tun="${TUN_NAME}" '
        NF {
            seen=1; found=0
            for (i=1; i<NF; i++) {
                if ($i == "dev") {
                    if ($(i+1) == tun) found=1
                    else invalid=1
                }
            }
            if (!found) invalid=1
        }
        END { exit (!seen || invalid) }
    ' <<<"$1"
}

function start_network() (
    local route_state_temp=''
    local network_committed=0
    local rollback_status=0
    local gateway_state_created=0
    local gateway_sysctl_captured=0
    local forward_lan_to_tun_added=0
    local forward_tun_to_lan_added=0
    local old_ip_forward='' old_rp_filter=''
    local -a added_routes=()
    local -a removed_route_specs=()
    route_state_temp="$(mktemp "${ROUTE_STATE_FILE}.tmp.XXXXXX")" || return 1

    function rollback_network_start() {
        local cidr
        local status=0
        local -a route_spec=()

        # Undo only routes created by this attempt and restore routes removed
        # during reconciliation. Existing routes on the interface are left
        # untouched because they were not created by this transaction.
        for cidr in "${added_routes[@]}"; do
            ip -4 route del "${cidr}" dev "${TUN_NAME}" 2>/dev/null || status=1
        done
        # 按删除时记录下来的完整路由属性恢复，不再假定原路由的 metric。
        for cidr in "${removed_route_specs[@]}"; do
            route_spec=()
            read -r -a route_spec <<<"${cidr}"
            ip -4 route replace "${route_spec[@]}" || status=1
        done
        # Remove only rules inserted by this attempt. A matching rule may have
        # existed before start_network and belongs to the running setup.
        forward_rule_specs
        if [[ "${forward_lan_to_tun_added}" -eq 1 ]]; then
            iptables -D FORWARD "${FORWARD_SPEC_LAN_TO_TUN[@]}" || status=1
            forward_state_drop "${FORWARD_SPEC_LAN_TO_TUN[*]}"
        fi
        if [[ "${forward_tun_to_lan_added}" -eq 1 ]]; then
            iptables -D FORWARD "${FORWARD_SPEC_TUN_TO_LAN[@]}" || status=1
            forward_state_drop "${FORWARD_SPEC_TUN_TO_LAN[*]}"
        fi
        if [[ "${gateway_sysctl_captured}" -eq 1 ]]; then
            sysctl -q -w "net.ipv4.ip_forward=${old_ip_forward}" || status=1
            sysctl -q -w "net.ipv4.conf.all.rp_filter=${old_rp_filter}" || status=1
        fi
        if [[ "${gateway_state_created}" -eq 1 ]]; then
            rm -f -- "${STATE_FILE}" || status=1
        fi
        return "${status}"
    }

    function finish_network_start() {
        local status="$1"

        trap - EXIT
        if [[ "${status}" -ne 0 && "${network_committed}" -eq 0 ]]; then
            rollback_network_start || rollback_status=1
        fi
        [[ -z "${route_state_temp}" ]] || rm -f -- "${route_state_temp}"
        [[ "${rollback_status}" -eq 0 ]] || status=1
        exit "${status}"
    }

    trap 'finish_network_start "$?"' EXIT

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
            existing="$(ip -4 route show exact "${cidr}")" || return 1
            # 只回收本脚本建在 TUN 上的路由，并记录完整属性以便回滚时原样恢复；
            # 已被管理员改到其它设备的路由保持不动，也不写入新的状态文件。
            if route_uses_tun "${existing}"; then
                ip -4 route del "${cidr}" dev "${TUN_NAME}" || return 1
                removed_route_specs+=("${existing}")
            fi
        fi
    done
    for cidr in "${REMOTE_CIDRS[@]}"; do
        existing="$(ip -4 route show exact "${cidr}")" || return 1
        if [[ -n "${existing}" ]] && ! route_uses_tun "${existing}"; then
            echo "Refusing to replace existing route: ${existing}" >&2
            return 1
        fi
        if [[ -z "${existing}" ]]; then
            ip -4 route replace "${cidr}" dev "${TUN_NAME}" metric 5
            added_routes+=("${cidr}")
        fi
        printf '%s\n' "${cidr}" >>"${route_state_temp}"
    done
    if [[ "${MODE}" == "gateway" ]]; then
        old_ip_forward="$(sysctl -n net.ipv4.ip_forward)"
        old_rp_filter="$(sysctl -n net.ipv4.conf.all.rp_filter)"
        gateway_sysctl_captured=1
        if [[ ! -f "${STATE_FILE}" ]]; then
            {
                echo "ip_forward=${old_ip_forward}"
                echo "rp_filter=${old_rp_filter}"
            } >"${STATE_FILE}"
            gateway_state_created=1
        fi
        sysctl -q -w net.ipv4.ip_forward=1
        sysctl -q -w net.ipv4.conf.all.rp_filter=0
        add_forward_rules
    fi
    mv -fT -- "${route_state_temp}" "${ROUTE_STATE_FILE}"
    route_state_temp=''
    network_committed=1
)

function stop_network() {
    local cidr existing route_state_temp ip_forward='' rp_filter=''
    local cleanup_status=0
    local -a remaining_routes=()
    remove_forward_rules
    local routes_to_remove=("${REMOTE_CIDRS[@]}")
    if [[ -r "${ROUTE_STATE_FILE}" ]]; then
        mapfile -t routes_to_remove <"${ROUTE_STATE_FILE}"
    fi
    for cidr in "${routes_to_remove[@]}"; do
        [[ -n "${cidr}" ]] || continue
        if ! existing="$(ip -4 route show exact "${cidr}")"; then
            remaining_routes+=("${cidr}")
            cleanup_status=1
        elif route_uses_tun "${existing}" && ! ip -4 route del "${cidr}" dev "${TUN_NAME}"; then
            remaining_routes+=("${cidr}")
            cleanup_status=1
        fi
    done
    if ((${#remaining_routes[@]})); then
        # Keep failed entries for the next stop rather than forgetting routes
        # after a transient netlink failure. Preserve the old ledger on IO error.
        if route_state_temp="$(mktemp "${ROUTE_STATE_FILE}.tmp.XXXXXX")"; then
            if ! { printf '%s\n' "${remaining_routes[@]}" >"${route_state_temp}" &&
                mv -fT -- "${route_state_temp}" "${ROUTE_STATE_FILE}"; }; then
                rm -f -- "${route_state_temp}"
            fi
        fi
        echo "Failed to remove LAN routes; keeping ${ROUTE_STATE_FILE} for retry." >&2
    else
        rm -f -- "${ROUTE_STATE_FILE}" || cleanup_status=1
    fi

    if [[ -f "${STATE_FILE}" ]]; then
        local restore_status=0
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
        if [[ "${ip_forward}" == 0 || "${ip_forward}" == 1 ]]; then
            sysctl -q -w "net.ipv4.ip_forward=${ip_forward}" || restore_status=1
        fi
        # rp_filter 的合法取值是 0/1/2（2=松散反向路径校验），只恢复 0/1 会丢掉 2。
        if [[ "${rp_filter}" =~ ^[0-2]$ ]]; then
            sysctl -q -w "net.ipv4.conf.all.rp_filter=${rp_filter}" || restore_status=1
        fi
        if [[ "${restore_status}" -eq 0 ]]; then
            rm -f "${STATE_FILE}"
        else
            echo "Failed to restore gateway sysctl values; keeping ${STATE_FILE} for retry." >&2
        fi
        [[ "${restore_status}" -eq 0 ]] || cleanup_status=1
    fi
    return "${cleanup_status}"
}

case "${1:-}" in
start) start_network ;;
stop) stop_network ;;
*) echo "Usage: $0 {start|stop}" >&2; exit 2 ;;
esac
