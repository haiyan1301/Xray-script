#!/usr/bin/env bash

[[ -n "${_PROTOCOLS_SH_LOADED:-}" ]] && return 0
readonly _PROTOCOLS_SH_LOADED=1

# Keep protocol names, menu choices and feature checks in one place.  The
# handler and the interactive menu run in separate processes, so both source
# this file instead of maintaining subtly different case lists.
#
# 本文件只定义函数与只读数据表：core/read.sh、core/check.sh、core/generate.sh
# 等独立进程都会 source 它，因此不能出现颜色、PATH 等与调用方冲突的常量。

# --- 协议能力表 ---
# 每个协议的能力、Nginx 归属、防火墙传输层、菜单顺序与显示名只在这里定义一次；
# 下面的判定函数全部是这张表的薄封装，调用方不需要知道表的存在。
# 能力标记（PROTOCOL_CAPS 里空格分隔）：
#   vless_enc   入站使用 VLESS encryption
#   reality     入站使用 REALITY
#   xhttp       入站使用 XHTTP 传输
#   public_port 入站自己监听公网端口（SNI/CDN 由 Nginx 监听 443，不在此列）
#   hy2_cert    使用 HY2 证书（只标 hy2 本身；multi 不算，由节点 tag 逐个判定）
#   reverse     支持反向代理
#   multi_container 该 tag 是 multi 容器本身（.xray.tag == multi）
# 注意：multi 容器与「能作为 multi 节点」是两件事，后者由 PROTOCOL_MULTI_ORDER
# 定义，不要再引入第二个叫 multi 的标记（两者混用会判错）。
declare -A PROTOCOL_CAPS=(
    [vision]='vless_enc reality public_port reverse'
    [xhttp]='vless_enc reality xhttp public_port reverse'
    [trojan]='reality xhttp public_port'
    [fallback]='vless_enc reality xhttp public_port reverse'
    [hy2]='public_port hy2_cert'
    [ss2022]='public_port'
    [mkcp]='vless_enc public_port'
    [sni]='vless_enc reality xhttp reverse'
    [cdn]='vless_enc xhttp'
    [multi]='multi_container'
)

# Nginx 归属：0-不使用；1-总是使用；backend-仅当 CDN 后端为 Nginx 时使用
declare -A PROTOCOL_NGINX=(
    [vision]=0 [xhttp]=0 [trojan]=0 [fallback]=0 [hy2]=0 [ss2022]=0 [mkcp]=0
    [sni]=1 [cdn]=backend [multi]=0
)

# 入站需要放行的防火墙传输层（空格分隔；空表示由 Nginx 监听，无需放行）
declare -A PROTOCOL_TRANSPORTS=(
    [vision]=tcp [xhttp]=tcp [trojan]=tcp [fallback]=tcp
    [mkcp]=udp [hy2]=udp [ss2022]='tcp udp' [sni]='' [cdn]='' [multi]=''
)

# 显示名 = 配置模板文件名 / .xray.tag 的取值。大小写必须与磁盘上的
# config/xray/*.json 一致（mKCP / CDN / SNI / XHTTP），不能随意改动。
declare -A PROTOCOL_DISPLAY=(
    [vision]=Vision [xhttp]=XHTTP [trojan]=Trojan [fallback]=Fallback
    [hy2]=hy2 [ss2022]=ss2022 [mkcp]=mKCP [cdn]=CDN [sni]=SNI [multi]=multi
)

# 历史别名 -> 规范 tag
declare -A PROTOCOL_ALIAS=(
    [hysteria]=hy2 [hysteria2]=hy2 [shadowsocks2022]=ss2022
)

# 主菜单与 multi 子菜单的顺序（元素即 PROTOCOL_DISPLAY 的键）
declare -a PROTOCOL_MENU_ORDER=(vision xhttp trojan fallback hy2 ss2022 mkcp cdn sni multi)
declare -a PROTOCOL_MULTI_ORDER=(vision xhttp trojan fallback hy2 ss2022 mkcp)

# 关联数组的下标一旦为空，bash 会报 "bad array subscript" 并中断展开。
# 所有以协议 tag 为下标的查表都先过这道闸：只有 [A-Za-z0-9_-] 才算已知 tag，
# 其余（空串、含空格/方括号等）一律按「未知协议」处理，与旧 case 的行为一致。
function protocol_tag_key() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]]
}

function protocol_template_tag() {
    local tag="${1:-}"
    local display=''

    protocol_tag_key "${tag}" || return 1
    tag="${tag,,}"
    tag="${PROTOCOL_ALIAS[${tag}]:-${tag}}"
    display="${PROTOCOL_DISPLAY[${tag}]:-}"
    [[ -n "${display}" ]] || return 1
    printf '%s\n' "${display}"
}

# 参数:
#   $1: 1 起的菜单编号（原样字符串，不接受前导零，与旧 case 行为一致）
#   $@: 该菜单的顺序表
# 返回值: 0-输出对应的显示名 1-编号非法（调用方据此重新提问）
function protocol_from_choice_order() {
    local choice="$1"
    shift
    local -a order=("$@")
    local index

    [[ "${choice}" =~ ^[0-9]+$ ]] || return 1
    ((${#choice} <= 3)) || return 1
    for ((index = 1; index <= ${#order[@]}; index++)); do
        [[ "${choice}" == "${index}" ]] || continue
        printf '%s\n' "${PROTOCOL_DISPLAY[${order[index - 1]}]}"
        return 0
    done
    return 1
}

function protocol_from_menu_choice() {
    protocol_from_choice_order "$1" "${PROTOCOL_MENU_ORDER[@]}"
}

function protocol_from_multi_menu_choice() {
    protocol_from_choice_order "$1" "${PROTOCOL_MULTI_ORDER[@]}"
}

# 参数: $1-协议 tag（大小写不敏感） $2-能力标记
function protocol_has_cap() {
    protocol_tag_key "${1:-}" || return 1
    [[ " ${PROTOCOL_CAPS[${1,,}]:-} " == *" $2 "* ]]
}

function protocol_uses_vless_enc() {
    protocol_has_cap "$1" vless_enc
}

function protocol_uses_reality() {
    protocol_has_cap "$1" reality
}

function protocol_uses_xhttp() {
    protocol_has_cap "$1" xhttp
}

function protocol_reads_public_port() {
    protocol_has_cap "$1" public_port
}

function protocol_uses_hy2_certificate() {
    protocol_has_cap "$1" hy2_cert
}

function protocol_supports_reverse() {
    protocol_has_cap "$1" reverse
}

# 该 tag 是否为 multi 容器本身（配置里 .xray.tag == multi）。
# 「能作为 multi 节点」是另一回事，由 PROTOCOL_MULTI_ORDER 描述。
function protocol_is_multi_config() {
    protocol_has_cap "$1" multi_container
}

function normalize_cdn_backend() {
    # Missing and unknown values deliberately fall back to Nginx. This keeps
    # old installations compatible and prevents a corrupted setting from
    # unexpectedly exposing a public Xray TLS listener.
    case "${1,,}" in
    xray) echo 'xray' ;;
    nginx | '') echo 'nginx' ;;
    *) echo 'nginx' ;;
    esac
}

function protocol_uses_nginx() {
    local cdn_backend="${2:-}"

    protocol_tag_key "${1:-}" || return 1
    case "${PROTOCOL_NGINX[${1,,}]:-0}" in
    1) return 0 ;;
    backend) [[ "$(normalize_cdn_backend "${cdn_backend}")" == 'nginx' ]] ;;
    *) return 1 ;;
    esac
}

# --- 节点集合判定 ---
# 「配置里是否存在使用某种协议特征的节点」只在这里判定一次：单协议 tag 直接判定，
# multi 逐个节点判定。调用方只负责把 tag 取出来，不再自己维护 tag 列表。

# 参数:
#   $1: 换行分隔的 tag 列表
#   $2: 协议特征判定函数名（如 protocol_uses_reality）
# 返回值: 0-至少一个 tag 命中 1-没有命中
function protocol_any_tag_uses() {
    local tags="$1"
    local predicate="$2"
    local tag

    while IFS= read -r tag; do
        [[ -n "${tag}" ]] || continue
        "${predicate}" "${tag}" && return 0
    done <<<"${tags}"
    return 1
}

# 参数:
#   $1: 配置的 xray.tag
#   $2: multi 节点的 tag 列表（换行分隔，非 multi 时可为空）
#   $3: 协议特征判定函数名
# 返回值: 0-配置使用该特征 1-不使用
function protocol_config_uses() {
    local config_tag="$1"
    local node_tags="${2:-}"
    local predicate="$3"

    if [[ "${config_tag,,}" != 'multi' ]]; then
        "${predicate}" "${config_tag}"
        return
    fi
    protocol_any_tag_uses "${node_tags}" "${predicate}"
}

# 当前脚本配置（全局 SCRIPT_CONFIG）中所有 multi 节点的 tag，每行一个。
# 只依赖 SCRIPT_CONFIG，因此可以被 core/check.sh 这类不加载 handler 的进程复用。
function current_node_tags() {
    echo "${SCRIPT_CONFIG}" | jq -r '.xray.nodes[]?.tag // empty'
}

# 已知的配置 tag（不读文件）是否使用某协议特征。
# 参数: $1-配置的 xray.tag $2-协议特征判定函数名
function protocol_tag_uses() {
    local config_tag="$1"
    local predicate="$2"
    local node_tags=''

    if [[ "${config_tag,,}" == 'multi' ]]; then
        node_tags="$(current_node_tags)" || return 1
    fi
    protocol_config_uses "${config_tag}" "${node_tags}" "${predicate}"
}

# 当前脚本配置（全局 SCRIPT_CONFIG）是否使用某协议特征。
# 参数: $1-协议特征判定函数名
function protocol_config_uses_current() {
    local config_tag

    config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')" || return 1
    protocol_tag_uses "${config_tag}" "$1"
}

# 磁盘上的某个配置文件是否使用某协议特征（core/main.sh 的安装前快照判定用）。
# 参数: $1-配置文件路径 $2-协议特征判定函数名
function protocol_config_file_uses() {
    local config_file="$1"
    local predicate="$2"
    local config_tag node_tags=''

    [[ -f "${config_file}" ]] || return 1
    config_tag="$(jq -r '.xray.tag // ""' "${config_file}" 2>/dev/null)" || return 1
    if [[ "${config_tag,,}" == 'multi' ]]; then
        node_tags="$(jq -r '.xray.nodes[]?.tag // empty' "${config_file}" 2>/dev/null)" || return 1
    fi
    protocol_config_uses "${config_tag}" "${node_tags}" "${predicate}"
}

# --- 交互式字段表 ---
# 字段身份（选项名 = CONFIG_DATA 的键 = exec_read 的参数）只在这里定义一次：
#   core/read.sh      取提示样式与 i18n 键
#   core/handler.sh   的 exec_read 取校验钩子
#   i18n 的 read.<字段> 与 core/check.sh / core/generate.sh 的选项名由门禁交叉校验
# i18n 键 = 选项名里的 "-" 换成 "_"。
declare -a FIELD_ORDER=(
    version rules block-bt block-cn block-ad auto-geo port uuid fallback seed
    password target only-change-domain domain cdn cdn-down email short path
    xhttp-mode warp-ip warp-domain block-ip block-domain hy2-auth
    hy2-cert-domain ss2022-password reverse-port reverse-target reverse-uuid
)

# 提示样式：config-[配置]（绿） / rule-[路由规则]（黄，可多值）
declare -A FIELD_TYPE=(
    [warp-ip]=rule [warp-domain]=rule [block-ip]=rule [block-domain]=rule
)

# handler 侧的后处理钩子（'' = 原样使用 read.sh 的输出，如 4 个 rule 字段与 auto-geo）。
# 表里只存函数名，钩子本体留在 core/handler.sh，共享库因此不依赖 handler 内部函数。
declare -A FIELD_HOOK=(
    [rules]=field_hook_default_N [block-bt]=field_hook_default_Y
    [block-cn]=field_hook_default_Y [block-ad]=field_hook_default_Y
    [only-change-domain]=field_hook_default_Y
    [version]=field_hook_version [email]=field_hook_email
    [port]=field_hook_port [reverse-port]=field_hook_reverse_port
    [uuid]=field_hook_uuid [fallback]=field_hook_uuid [reverse-uuid]=field_hook_uuid
    [reverse-target]=field_hook_reverse_target
    [seed]=field_hook_password [password]=field_hook_password
    [hy2-auth]=field_hook_password [ss2022-password]=field_hook_ss2022_key
    [target]=field_hook_target [hy2-cert-domain]=field_hook_dns
    [domain]=field_hook_domain [cdn]=field_hook_cdn
    [cdn-down]=field_hook_cdn_down [short]=field_hook_short
    [path]=field_hook_path [xhttp-mode]=field_hook_xhttp_mode
)

# 提问前额外打印的提示（i18n 键去掉 read. 前缀）
declare -A FIELD_TIP=(
    [short]=short_id_tip [xhttp-mode]=xhttp_mode_tip
)

function field_known() {
    local opt
    for opt in "${FIELD_ORDER[@]}"; do
        [[ "${opt}" == "${1:-}" ]] && return 0
    done
    return 1
}

# 字段名同样可能是空串（exec_read 收到空参数），查表前统一挡掉。
function field_type() {
    field_known "${1:-}" || {
        printf 'config'
        return 0
    }
    printf '%s' "${FIELD_TYPE[${1}]:-config}"
}

function field_hook_name() {
    field_known "${1:-}" || return 0
    printf '%s' "${FIELD_HOOK[${1}]:-}"
}

function field_tip_key() {
    field_known "${1:-}" || return 0
    printf '%s' "${FIELD_TIP[${1}]:-}"
}

function field_i18n_key() { printf '%s' "${1//-/_}"; }

# --- 每个协议的交互式字段（顺序即提问顺序）---
# read_multi_node_protocol_fields（multi 节点）与 handler_read_xray_config（单协议）
# 共用这一份，避免两处 tag 列表不同步。
declare -A PROTOCOL_FIELDS=(
    [vision]='uuid target short'
    [xhttp]='uuid target short path xhttp-mode'
    [trojan]='password target short path xhttp-mode'
    [fallback]='uuid fallback target short path xhttp-mode'
    [hy2]='hy2-auth'
    [ss2022]='ss2022-password'
    [mkcp]='uuid seed'
    [sni]='uuid fallback domain cdn short path xhttp-mode'
    [cdn]='uuid cdn cdn-down path xhttp-mode'
)

# 参数: $1-协议 tag
# 输出: 每行一个字段名；未定义的协议返回 1（调用方据此拒绝而不是静默跳过）
function protocol_fields() {
    local fields=''

    protocol_tag_key "${1:-}" || return 1
    fields="${PROTOCOL_FIELDS[${1,,}]:-}"
    [[ -n "${fields}" ]] || return 1
    printf '%s\n' ${fields}
}

# 协议入站需要开放的防火墙传输层，每行一个（tcp / udp）。
# 单协议入站与 multi 节点共用这份映射，避免两处 tag 列表不同步。
# 参数:
#   $1: 协议 tag
# 输出: 传输层名称（无匹配协议时不输出）
function protocol_firewall_transports() {
    local transport
    local transports=''

    protocol_tag_key "${1:-}" || return 0
    transports="${PROTOCOL_TRANSPORTS[${1,,}]:-}"

    for transport in ${transports}; do
        printf '%s\n' "${transport}"
    done
}

function normalize_xhttp_path() {
    local path="${1:-}"

    [[ -z "${path}" ]] && {
        printf '\n'
        return 0
    }

    [[ "${path}" == /* ]] || path="/${path}"
    [[ "${path}" == */ ]] || path="${path}/"
    printf '%s\n' "${path}"
}

# Single source of truth for path rules, shared by core/check.sh (user input)
# and handler_sync_nginx_xhttp_path (config.json / nginx paths).
#
# Args:
#   $1: path
#   $2: allow empty (yes/no, default no)
#   $3: require leading and trailing slash (yes/no, default no)
# Returns 0 when the path is usable. On failure returns 1 and sets _PATH_ERROR to
# the i18n key suffix describing the reason (required|root|slash|space|length|char|double_slash).
_PATH_ERROR=''
function validate_path_rules() {
    local path="${1:-}"
    local allow_empty="${2:-no}"
    local require_slashes="${3:-no}"
    _PATH_ERROR=''

    if [[ -z "${path}" ]]; then
        [[ "${allow_empty}" == 'yes' ]] && return 0
        _PATH_ERROR='required'
        return 1
    fi
    if [[ "${path}" == '/' ]]; then
        _PATH_ERROR='root'
        return 1
    fi
    if [[ "${require_slashes}" == 'yes' && ( "${path}" != /* || "${path}" != */ ) ]]; then
        _PATH_ERROR='slash'
        return 1
    fi
    if [[ "${path}" == *' '* ]]; then
        _PATH_ERROR='space'
        return 1
    fi
    if ((${#path} > 128)); then
        _PATH_ERROR='length'
        return 1
    fi
    if [[ "${path}" =~ [^a-zA-Z0-9_/.\-] ]]; then
        _PATH_ERROR='char'
        return 1
    fi
    if [[ "${path}" =~ // ]]; then
        _PATH_ERROR='double_slash'
        return 1
    fi
    return 0
}

# Map validate_path_rules' _PATH_ERROR reason to its i18n key suffix.
# Kept next to the rule engine so a new reason code cannot silently fall through
# to a generic message in a caller (core/check.sh 的 _path_fail 直接用这个函数)。
#
# Args:
#   $1: reason code set by validate_path_rules
# Output: the i18n key suffix (never empty; unknown codes degrade to char_error)
function path_error_key() {
    case "${1:-}" in
    required) printf 'required_error\n' ;;
    root) printf 'root_error\n' ;;
    slash) printf 'slash_error\n' ;;
    space) printf 'space_error\n' ;;
    length) printf 'length_error\n' ;;
    double_slash) printf 'double_slash_error\n' ;;
    *) printf 'char_error\n' ;;
    esac
}

# Validate an XHTTP path against the rules used by handler_sync_nginx_xhttp_path.
# An empty path is treated as valid: non-xhttp protocols legitimately carry an
# empty .xray.path, and callers that require a non-empty path enforce that
# separately.
function validate_xhttp_path() {
    validate_path_rules "${1:-}" 'yes' 'yes'
}
