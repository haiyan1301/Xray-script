#!/usr/bin/env bash
# =============================================================================
# 脚本名称: firewall.sh
# 功能描述: 防火墙放行规则的唯一实现层（只定义函数）。
#           1) 账本访问器：读写 SCRIPT_CONFIG.xray.firewallRules[]；
#           2) 后端规则操作：存在性查询 / 删除 / 恢复（ufw、firewalld、iptables）；
#           3) 以 feature 为单位的高层 API：放行、回收、回滚。
#           所有放行都必须经由本文件的 firewall_owned_open 记录账本，否则卸载时
#           无法回收（旧版 open_xray_firewall_port 只改防火墙不记账本，已删除）。
#
# 账本条目结构（core/handler.sh 的 normalize_and_validate_xray_state 校验）:
#   {feature, backend, port, protocol, ipv4, ipv6}
#   - feature: 稳定标识（'xray' / 'node:<tag>' / 'lan' / 'reverse'），卸载与回滚按它精确匹配
#   - backend: ufw | firewalld | iptables
#   - ipv4/ipv6: 仅 iptables 后端有意义，记录本次实际插入的地址族，回滚时只删自己插的
#
# 约定:
#   - 只操作 INPUT 链：账本 schema 不含 chain/table/host，边缘网关的 FORWARD 规则
#     由 config/lan/xray-lan-net.sh 自行管理，不走本账本。
#   - 只定义函数：颜色 / PATH 由调用方提供（lib/common.sh），因此本文件不会与
#     service/*.sh、core/read.sh 等独立进程的 readonly 定义冲突。
#
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
#
# Copyright (C) 2025 zxcvos
# =============================================================================

# 防止重复 source
[[ -n "${_FIREWALL_SH_LOADED:-}" ]] && return 0
readonly _FIREWALL_SH_LOADED=1

# =============================================================================
# 内部工具
# =============================================================================

# 规则字段回传（避免在每个调用点重复 5 次 jq 取值）：
# firewall_rule_fields 成功后读取 _FW_BACKEND / _FW_PORT / _FW_PROTOCOL /
# _FW_IPV4 / _FW_IPV6。与 lib/protocols.sh 的 _PATH_ERROR 同一约定。
_FW_BACKEND=''
_FW_PORT=''
_FW_PROTOCOL=''
_FW_IPV4=''
_FW_IPV6=''

# =============================================================================
# 函数名称: firewall_rule_fields
# 功能描述: 从账本条目 JSON 中解出 5 个后端字段，写入 _FW_* 回传变量。
# 参数:
#   $1: 账本条目 JSON
# 返回值: 0-解析成功 1-字段缺失或不是合法 JSON
# =============================================================================
function firewall_rule_fields() {
    local parsed

    parsed="$(echo "$1" | jq -er '[.backend, .port, .protocol, .ipv4, .ipv6] | @tsv')" || return 1
    IFS=$'\t' read -r _FW_BACKEND _FW_PORT _FW_PROTOCOL _FW_IPV4 _FW_IPV6 <<<"${parsed}"
}

# =============================================================================
# 函数名称: firewall_rule_json
# 功能描述: 构造一条账本条目 JSON（单行紧凑格式）。
# 参数:
#   $1: feature  $2: backend  $3: port  $4: protocol  $5: ipv4  $6: ipv6
# 输出: 单行 JSON
# 返回值: 0-成功 1-参数不合法
# =============================================================================
function firewall_rule_json() {
    jq -n \
        --arg feature "$1" --arg backend "$2" \
        --argjson port "$3" --arg protocol "$4" \
        --argjson ipv4 "$5" --argjson ipv6 "$6" \
        '{feature:$feature,backend:$backend,port:$port,protocol:$protocol,ipv4:$ipv4,ipv6:$ipv6}'
}

# =============================================================================
# 函数名称: firewall_detect_backend
# 功能描述: 探测当前生效的防火墙后端，分支顺序与 firewall_owned_open 一致。
# 参数: 无
# 输出: ufw | firewalld | iptables | none
# 返回值: 总是 0
# =============================================================================
function firewall_detect_backend() {
    if command -v ufw &>/dev/null; then
        if grep -Eiq '^Status:[[:space:]]+active([[:space:]]|$)' <<<"$(ufw status 2>/dev/null || true)"; then
            printf 'ufw\n'
            return 0
        fi
        printf 'none\n'
        return 0
    fi
    if command -v firewall-cmd &>/dev/null; then
        if [[ "$(firewall-cmd --state 2>/dev/null || true)" == 'running' ]]; then
            printf 'firewalld\n'
            return 0
        fi
        printf 'none\n'
        return 0
    fi
    if command -v iptables &>/dev/null; then
        printf 'iptables\n'
        return 0
    fi
    printf 'none\n'
}

# =============================================================================
# 函数名称: firewall_ledger_features
# 功能描述: 列出账本中出现过的 feature（去重，每行一个）。
# 参数: 无
# 返回值: 0-成功 1-jq 失败
# =============================================================================
function firewall_ledger_features() {
    echo "${SCRIPT_CONFIG}" | jq -r '[.xray.firewallRules[]?.feature // empty] | unique[]'
}

# =============================================================================
# 函数名称: firewall_ledger_rules
# 功能描述: 取出某个 feature 的账本条目（可按端口再过滤）。
# 参数:
#   $1: feature
#   $2: port（可选；空串表示该 feature 的全部端口）
# 输出: 单行 JSON 数组
# 返回值: 0-成功 1-jq 失败
# =============================================================================
function firewall_ledger_rules() {
    local feature="$1"
    local port="${2:-}"

    echo "${SCRIPT_CONFIG}" | jq -c \
        --arg feature "${feature}" --arg port "${port}" '
        [.xray.firewallRules[]? | select(.feature == $feature and ($port == "" or (.port | tostring) == $port))]
    '
}

# =============================================================================
# 函数名称: firewall_ledger_port_owned
# 功能描述: 判断某个端口/协议是否已被账本中任意 feature 接管。
#           历史遗留回收用它跳过已记账的端口，避免与账本重复回收。
# 参数:
#   $1: port  $2: protocol
# 返回值: 0-已被接管 1-未被接管
# =============================================================================
function firewall_ledger_port_owned() {
    local found

    found="$(echo "${SCRIPT_CONFIG}" | jq -r \
        --argjson port "$1" --arg protocol "$2" \
        '[.xray.firewallRules[]? | select(.port == $port and .protocol == $protocol)][0] // empty')" || return 1
    [[ -n "${found}" ]]
}

# =============================================================================
# 函数名称: firewall_ledger_add
# 功能描述: 把一条规则并入账本（同 feature/port/protocol 去重），并更新 SCRIPT_CONFIG。
#           不落盘：由调用方决定何时写配置。
# 参数:
#   $1: 规则 JSON
# 返回值: 0-成功 1-失败（SCRIPT_CONFIG 保持不变）
# =============================================================================
function firewall_ledger_add() {
    local rule="$1"
    local updated

    updated="$(echo "${SCRIPT_CONFIG}" | jq --argjson rule "${rule}" '
        .xray.firewallRules = ((.xray.firewallRules // []) + [$rule] | unique_by([.feature,.port,.protocol]))
    ')" || return 1
    SCRIPT_CONFIG="${updated}"
}

# =============================================================================
# 函数名称: firewall_ledger_drop
# 功能描述: 从账本中移除某个 feature（可按端口再过滤）的条目，并更新 SCRIPT_CONFIG。
#           不落盘：由调用方决定何时写配置。
# 参数:
#   $1: feature
#   $2: port（可选；空串表示该 feature 的全部端口）
# 返回值: 0-成功 1-失败（SCRIPT_CONFIG 保持不变）
# =============================================================================
function firewall_ledger_drop() {
    local feature="$1"
    local port="${2:-}"
    local updated

    updated="$(echo "${SCRIPT_CONFIG}" | jq \
        --arg feature "${feature}" --arg port "${port}" '
        .xray.firewallRules = [
            .xray.firewallRules[]? |
            select(.feature != $feature or ($port != "" and (.port | tostring) != $port))
        ]
    ')" || return 1
    SCRIPT_CONFIG="${updated}"
}

# =============================================================================
# 函数名称: firewall_ledger_delta
# 功能描述: 计算 candidate 相对 previous 新增的账本条目（回滚时需要撤销的集合）。
# 参数:
#   $1: previous 配置 JSON
#   $2: candidate 配置 JSON
# 输出: 单行 JSON 数组（解析失败时输出 []）
# 返回值: 总是 0
# =============================================================================
function firewall_ledger_delta() {
    jq -n \
        --argjson previous "$1" \
        --argjson candidate "$2" '
        [($candidate.xray.firewallRules // [])[] as $rule |
            select(any(($previous.xray.firewallRules // [])[]?;
                .feature == $rule.feature and .backend == $rule.backend and
                .port == $rule.port and .protocol == $rule.protocol
            ) | not) | $rule]
    ' 2>/dev/null || echo '[]'
}

# =============================================================================
# 后端规则操作
# =============================================================================

# =============================================================================
# 函数名称: firewall_rule_exists
# 功能描述: 查询一条账本条目对应的后端规则是否存在。
# 参数:
#   $1: 规则 JSON
# 返回值: 0-存在 1-不存在 2-后端不可用（无法判断）
# =============================================================================
function firewall_rule_exists() {
    local backend port protocol ipv4 ipv6 present=1 status

    firewall_rule_fields "$1" || return 2
    backend="${_FW_BACKEND}"
    port="${_FW_PORT}"
    protocol="${_FW_PROTOCOL}"
    ipv4="${_FW_IPV4}"
    ipv6="${_FW_IPV6}"

    case "${backend}" in
    ufw)
        command -v ufw &>/dev/null || return 2
        status="$(ufw show added 2>/dev/null)" || return 2
        grep -Eq "^ufw allow ${port}/${protocol}([[:space:]]|$)" <<<"${status}"
        ;;
    firewalld)
        command -v firewall-cmd &>/dev/null || return 2
        [[ "$(firewall-cmd --state 2>/dev/null)" == 'running' ]] || return 2
        if firewall-cmd --permanent --query-port="${port}"/"${protocol}" >/dev/null 2>&1; then
            return 0
        else
            status=$?
            [[ "${status}" -eq 1 ]] && return 1
            return 2
        fi
        ;;
    iptables)
        if [[ "${ipv4}" == 'true' ]]; then
            command -v iptables &>/dev/null || return 2
            if iptables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
                present=0
            else
                iptables -S INPUT >/dev/null 2>&1 || return 2
            fi
        fi
        if [[ "${ipv6}" == 'true' ]]; then
            command -v ip6tables &>/dev/null || return 2
            if ip6tables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
                present=0
            else
                ip6tables -S INPUT >/dev/null 2>&1 || return 2
            fi
        fi
        return "${present}"
        ;;
    *) return 2 ;;
    esac
}

# =============================================================================
# 函数名称: firewall_rule_remove_fields
# 功能描述: 按字段删除一条后端规则（规则不存在时视为成功）。
# 参数:
#   $1: backend  $2: port  $3: protocol  $4: ipv4  $5: ipv6
# 返回值: 0-成功 1-失败
# =============================================================================
function firewall_rule_remove_fields() {
    local backend="$1"
    local port="$2"
    local protocol="$3"
    local ipv4="$4"
    local ipv6="$5"
    local status='' query_status=0

    case "${backend}" in
    ufw)
        command -v ufw &>/dev/null || return 1
        status="$(ufw show added 2>/dev/null)" || return 1
        if grep -Eq "^ufw allow ${port}/${protocol}([[:space:]]|$)" <<<"${status}"; then
            ufw delete allow "${port}"/"${protocol}" >/dev/null 2>&1
        fi
        ;;
    firewalld)
        command -v firewall-cmd &>/dev/null || return 1
        [[ "$(firewall-cmd --state 2>/dev/null)" == 'running' ]] || return 1
        if firewall-cmd --permanent --query-port="${port}"/"${protocol}" >/dev/null 2>&1; then
            firewall-cmd --permanent --remove-port="${port}"/"${protocol}" >/dev/null 2>&1 &&
                firewall-cmd --reload >/dev/null 2>&1
        else
            query_status=$?
            [[ "${query_status}" -eq 1 ]] || return 1
        fi
        ;;
    iptables)
        if [[ "${ipv4}" == 'true' ]]; then
            command -v iptables &>/dev/null || return 1
            if iptables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
                iptables -D INPUT -p "${protocol}" --dport "${port}" -j ACCEPT >/dev/null 2>&1 || return 1
            else
                iptables -S INPUT >/dev/null 2>&1 || return 1
            fi
        fi
        if [[ "${ipv6}" == 'true' ]]; then
            command -v ip6tables &>/dev/null || return 1
            if ip6tables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
                ip6tables -D INPUT -p "${protocol}" --dport "${port}" -j ACCEPT >/dev/null 2>&1 || return 1
            else
                ip6tables -S INPUT >/dev/null 2>&1 || return 1
            fi
        fi
        ;;
    *) return 1 ;;
    esac
}

# =============================================================================
# 函数名称: firewall_rule_remove
# 功能描述: 删除一条账本条目对应的后端规则。
# 参数:
#   $1: 规则 JSON
# 返回值: 0-成功 1-失败
# =============================================================================
function firewall_rule_remove() {
    firewall_rule_fields "$1" || return 1
    firewall_rule_remove_fields \
        "${_FW_BACKEND}" "${_FW_PORT}" "${_FW_PROTOCOL}" "${_FW_IPV4}" "${_FW_IPV6}"
}

# =============================================================================
# 函数名称: firewall_rule_restore
# 功能描述: 恢复一条账本条目对应的后端规则（回滚时的补偿动作，已存在则跳过）。
# 参数:
#   $1: 规则 JSON
# 返回值: 0-成功 1-失败
# =============================================================================
function firewall_rule_restore() {
    local status

    firewall_rule_fields "$1" || return 1

    case "${_FW_BACKEND}" in
    ufw)
        command -v ufw &>/dev/null || return 1
        status="$(ufw show added 2>/dev/null)" || return 1
        grep -Eq "^ufw allow ${_FW_PORT}/${_FW_PROTOCOL}([[:space:]]|$)" <<<"${status}" ||
            ufw allow "${_FW_PORT}"/"${_FW_PROTOCOL}" >/dev/null 2>&1
        ;;
    firewalld)
        command -v firewall-cmd &>/dev/null || return 1
        [[ "$(firewall-cmd --state 2>/dev/null)" == 'running' ]] || return 1
        if ! firewall-cmd --permanent --query-port="${_FW_PORT}"/"${_FW_PROTOCOL}" >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port="${_FW_PORT}"/"${_FW_PROTOCOL}" >/dev/null 2>&1 &&
                firewall-cmd --reload >/dev/null 2>&1
        fi
        ;;
    iptables)
        if [[ "${_FW_IPV4}" == 'true' ]]; then
            command -v iptables &>/dev/null || return 1
            iptables -C INPUT -p "${_FW_PROTOCOL}" --dport "${_FW_PORT}" -j ACCEPT 2>/dev/null ||
                iptables -I INPUT -p "${_FW_PROTOCOL}" --dport "${_FW_PORT}" -j ACCEPT 2>/dev/null || return 1
        fi
        if [[ "${_FW_IPV6}" == 'true' ]]; then
            command -v ip6tables &>/dev/null || return 1
            ip6tables -C INPUT -p "${_FW_PROTOCOL}" --dport "${_FW_PORT}" -j ACCEPT 2>/dev/null ||
                ip6tables -I INPUT -p "${_FW_PROTOCOL}" --dport "${_FW_PORT}" -j ACCEPT 2>/dev/null || return 1
        fi
        ;;
    *) return 1 ;;
    esac
}

# =============================================================================
# 函数名称: firewall_rules_restore
# 功能描述: 批量恢复账本条目（任一条失败都继续，最终返回 1）。
# 参数:
#   $@: 规则 JSON 列表
# 返回值: 0-全部成功 1-至少一条失败
# =============================================================================
function firewall_rules_restore() {
    local rule restore_status=0

    for rule in "$@"; do
        firewall_rule_restore "${rule}" || restore_status=1
    done
    return "${restore_status}"
}

# =============================================================================
# 高层 API（调用方只应使用这一层）
# =============================================================================

# =============================================================================
# 函数名称: firewall_owned_open
# 功能描述: 放行一个端口并记账本。
#           - 账本里已有同 feature/port/protocol 的记录：只做幂等补偿；
#           - 后端里规则已存在（先于本脚本存在）：视为已放行，但不记账本，
#             因为无权在卸载时删除别人的规则；
#           - 后端未启用 / 没有后端：告警后返回 0（不视为失败）；
#           - 记账本失败：回滚刚插入的规则，保证账本与后端一致。
# 参数:
#   $1: feature  $2: port  $3: protocol(tcp|udp)
# 返回值: 0-已放行（含无需放行） 1-放行或记账失败
# =============================================================================
function firewall_owned_open() {
    local feature="$1"
    local port="$2"
    local protocol="$3"
    local backend='' ipv4=false ipv6=false rule existing_rule
    local ufw_status firewalld_status previous_script_config

    [[ -n "${feature}" ]] || return 1
    # 字符串层先归一化再算术，理由同 core/check.sh 的 check_port：20 位十进制串在
    # Bash 的 64 位算术里会回绕（18446744073709551617 → 1），不做限位就可能给一个
    # 完全不同的端口放行。这里是与 core/check.sh 同源的守卫，调用方漏校验也兜得住。
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    port="${port#"${port%%[!0]*}"}"
    port="${port:-0}"
    [[ "${#port}" -le 5 ]] || return 1
    port=$((10#${port}))
    ((port >= 1 && port <= 65535)) || return 1
    [[ "${protocol}" =~ ^(tcp|udp)$ ]] || return 1
    existing_rule="$(echo "${SCRIPT_CONFIG}" | jq -cr \
        --arg feature "${feature}" --argjson port "${port}" --arg protocol "${protocol}" \
        '[.xray.firewallRules[]? | select(.feature == $feature and .port == $port and .protocol == $protocol)][0] // empty')" ||
        return 1
    if [[ -n "${existing_rule}" ]]; then
        firewall_rule_restore "${existing_rule}"
        return $?
    fi

    log_config "$(t '.firewall.open') ${feature} ${port}/${protocol}" >&2
    if command -v ufw &>/dev/null; then
        ufw_status="$(ufw status 2>/dev/null || true)"
        if grep -Eiq '^Status:[[:space:]]+active([[:space:]]|$)' <<<"${ufw_status}"; then
            if grep -Eq "^${port}/${protocol}[[:space:]]+ALLOW([[:space:]]|$)" <<<"${ufw_status}"; then
                # 规则先于本脚本存在：不记入账本，卸载时也不会删除它。
                log_info "$(t '.firewall.ok') ${port}/${protocol}" >&2
                return 0
            fi
            if ! ufw allow "${port}"/"${protocol}" >/dev/null 2>&1; then
                _firewall_fail "${port}" "${protocol}"
                return 1
            fi
            backend='ufw'
        else
            log_warn "$(t '.firewall.inactive')" >&2
            return 0
        fi
    elif command -v firewall-cmd &>/dev/null; then
        firewalld_status="$(firewall-cmd --state 2>/dev/null || true)"
        [[ "${firewalld_status,,}" == 'running' ]] || {
            log_warn "$(t '.firewall.inactive')" >&2
            return 0
        }
        if firewall-cmd --permanent --query-port="${port}"/"${protocol}" >/dev/null 2>&1; then
            log_info "$(t '.firewall.ok') ${port}/${protocol}" >&2
            return 0
        fi
        if ! firewall-cmd --permanent --add-port="${port}"/"${protocol}" >/dev/null 2>&1; then
            _firewall_fail "${port}" "${protocol}"
            return 1
        fi
        if ! firewall-cmd --reload >/dev/null 2>&1; then
            firewall-cmd --permanent --remove-port="${port}"/"${protocol}" >/dev/null 2>&1 || true
            _firewall_fail "${port}" "${protocol}"
            return 1
        fi
        backend='firewalld'
    elif command -v iptables &>/dev/null; then
        if ! iptables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
            if ! iptables -I INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
                _firewall_fail "${port}" "${protocol}"
                return 1
            fi
            ipv4=true
        fi
        if command -v ip6tables &>/dev/null &&
            ! ip6tables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
            if ip6tables -I INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
                ipv6=true
            fi
        fi
        if [[ "${ipv4}" != 'true' && "${ipv6}" != 'true' ]]; then
            log_info "$(t '.firewall.ok') ${port}/${protocol}" >&2
            return 0
        fi
        backend='iptables'
    else
        log_warn "$(t '.firewall.skip')" >&2
        return 0
    fi

    rule="$(firewall_rule_json "${feature}" "${backend}" "${port}" "${protocol}" "${ipv4}" "${ipv6}")" || {
        firewall_rule_remove_fields \
            "${backend}" "${port}" "${protocol}" "${ipv4}" "${ipv6}" || true
        return 1
    }
    previous_script_config="${SCRIPT_CONFIG}"
    if ! firewall_ledger_add "${rule}"; then
        firewall_rule_remove "${rule}" || true
        SCRIPT_CONFIG="${previous_script_config}"
        return 1
    fi
    if ! write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"; then
        if firewall_rule_remove "${rule}"; then
            SCRIPT_CONFIG="${previous_script_config}"
        fi
        # 删除失败时保留内存中的归属记录，交给外层状态事务重试或落盘。
        return 1
    fi
    log_info "$(t '.firewall.ok') ${port}/${protocol}" >&2
}

# =============================================================================
# 函数名称: firewall_owned_close
# 功能描述: 回收某个 feature（可按端口过滤）的账本规则，并从账本中删除条目。
#           任一步失败都会做补偿回滚，保证「后端规则」与「账本」不会半途失配。
# 参数:
#   $1: feature
#   $2: port（可选；空串表示该 feature 的全部端口）
#   $3: defer_write（可选，1 = 只改内存不落盘，由外层事务统一写）
# 返回值: 0-成功 1-失败
# =============================================================================
function firewall_owned_close() {
    local feature="$1"
    local port="${2:-}"
    local defer_write="${3:-0}"
    local records rule existence_status
    local previous_script_config="${SCRIPT_CONFIG}"
    local -a removed_rules=()

    records="$(firewall_ledger_rules "${feature}" "${port}")" || return 1

    while IFS= read -r rule; do
        [[ -n "${rule}" ]] || continue
        if firewall_rule_exists "${rule}"; then
            if ! firewall_rule_remove "${rule}"; then
                firewall_rule_restore "${rule}" ||
                    echo 'Firewall rollback failed for the current owned port.' >&2
                firewall_rules_restore "${removed_rules[@]}" ||
                    echo 'Firewall rollback failed while closing owned ports.' >&2
                return 1
            fi
            removed_rules+=("${rule}")
        else
            existence_status=$?
            if [[ "${existence_status}" -eq 2 ]]; then
                firewall_rules_restore "${removed_rules[@]}" ||
                    echo 'Firewall rollback failed while closing owned ports.' >&2
                return 1
            fi
        fi
    done < <(echo "${records}" | jq -c '.[]')

    if ! firewall_ledger_drop "${feature}" "${port}"; then
        firewall_rules_restore "${removed_rules[@]}" ||
            echo 'Firewall rollback failed after state update failure.' >&2
        return 1
    fi
    if [[ "${defer_write}" -eq 1 ]]; then
        return 0
    fi
    if ! write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"; then
        SCRIPT_CONFIG="${previous_script_config}"
        firewall_rules_restore "${removed_rules[@]}" ||
            echo 'Firewall rollback failed after configuration write failure.' >&2
        return 1
    fi
}

# =============================================================================
# 函数名称: firewall_owned_restore_feature
# 功能描述: 回滚一个 feature 的放行状态：先恢复上一次的配置内容，再重新放行端口。
# 参数:
#   $1: 上一次的配置 JSON  $2: feature  $3: port  $4: protocol
# 返回值: 0-成功 1-失败
# =============================================================================
function firewall_owned_restore_feature() {
    local previous_script_config="$1"
    local feature="$2"
    local port="$3"
    local protocol="$4"
    local restore_status=0

    SCRIPT_CONFIG="${previous_script_config}"
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || restore_status=1
    firewall_owned_open "${feature}" "${port}" "${protocol}" || restore_status=1
    if [[ "${restore_status}" -ne 0 ]]; then
        echo "Failed to restore ${feature} firewall ownership state." >&2
    fi
    return "${restore_status}"
}

# =============================================================================
# 内部函数: _firewall_fail
# 功能描述: 打印放行失败日志（i18n 文案 + 端口/协议）。
# 参数: $1 port  $2 protocol
# 返回值: 总是 1
# =============================================================================
function _firewall_fail() {
    log_error "$(t '.firewall.fail') $1/$2" >&2
    return 1
}
