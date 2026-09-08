#!/usr/bin/env bash
# =============================================================================
# 脚本名称: common.sh
# 功能描述: Xray-script 项目的公共函数库。
#           提供颜色常量、版本门槛、端口常量等公共定义，并聚合五个可独立复用的
#           子库：lib/i18n.sh（取值层）、lib/log.sh（日志层）、lib/system.sh（探测层）、
#           lib/firewall.sh（防火墙放行与账本层）、lib/cert.sh（证书与 ACME 层）。
#           其他脚本通过 source 引入本文件以避免代码重复。
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
#
# Copyright (C) 2025 zxcvos
# =============================================================================

# 防止重复 source
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
readonly _COMMON_SH_LOADED=1

# --- 子库聚合 ---
# 这六个子库各自只定义一类函数（取值/日志/探测/防火墙/证书/事务调度），不定义颜色与
# PATH，因此不 source 本文件的 core/read.sh 与 service/*.sh 也能按需单独引用。
readonly _COMMON_LIB_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${_COMMON_LIB_DIR}/i18n.sh"
source "${_COMMON_LIB_DIR}/log.sh"
source "${_COMMON_LIB_DIR}/system.sh"
source "${_COMMON_LIB_DIR}/firewall.sh"
source "${_COMMON_LIB_DIR}/cert.sh"
source "${_COMMON_LIB_DIR}/transaction.sh"

# --- 颜色常量 ---
readonly GREEN='\033[32m'  # 绿色
readonly YELLOW='\033[33m' # 黄色
readonly RED='\033[31m'    # 红色
readonly NC='\033[0m'      # 无颜色（重置）

# --- 支持的最低系统版本 ---
# 与 README「已测试系统」一致；service/nginx.sh 编译 Nginx 也要求这一下限。
# 提示文案由这些常量生成，避免多处硬编码出现互相矛盾的版本号。
readonly MIN_UBUNTU=20
readonly MIN_DEBIAN=10
readonly MIN_CENTOS=7

# --- Xray API 端口 ---
# 该端口由 Xray 内置 API 占用，不能分配给入站节点。config/xray/*.json 模板中的
# api 入站同样写死这个值；改动时需同步模板。
readonly XRAY_API_PORT=32768

# --- 环境设置 ---
PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:${HOME}/bin:/snap/bin:${PATH:-}"
export PATH

# cmd_exists / _os / _os_full / _os_ver 由 lib/system.sh 提供（见上方聚合 source）。

function valid_ipv4_literal() {
    local value="$1"
    local octet numeric
    local -a octets=()

    [[ "${value}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    IFS='.' read -r -a octets <<<"${value}"
    [[ "${#octets[@]}" -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "${#octet}" -le 3 ]] || return 1
        numeric=$((10#${octet}))
        ((numeric <= 255)) || return 1
    done
}

function valid_ipv6_literal() {
    local value="$1"
    local ipv4_tail suffix normalized part
    local has_compression=0 group_count=0
    local -a groups=()

    [[ "${value}" == *:* ]] || return 1
    if [[ "${value}" == *.* ]]; then
        ipv4_tail="${value##*:}"
        valid_ipv4_literal "${ipv4_tail}" || return 1
        value="${value%:*}:0:0"
    fi
    [[ "${value}" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    [[ "${value}" != *:::* ]] || return 1
    [[ "${value}" != :* || "${value}" == ::* ]] || return 1
    [[ "${value}" != *: || "${value}" == *:: ]] || return 1

    if [[ "${value}" == *::* ]]; then
        has_compression=1
        suffix="${value#*::}"
        [[ "${suffix}" != *::* ]] || return 1
        normalized="${value/::/:__compressed__:}"
    else
        normalized="${value}"
    fi

    IFS=':' read -r -a groups <<<"${normalized}"
    for part in "${groups[@]}"; do
        [[ -z "${part}" || "${part}" == '__compressed__' ]] && continue
        [[ "${part}" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        group_count=$((group_count + 1))
    done
    if [[ "${has_compression}" -eq 1 ]]; then
        ((group_count < 8))
    else
        ((group_count == 8))
    fi
}

function valid_ip_literal() {
    valid_ipv4_literal "$1" || valid_ipv6_literal "$1"
}

function valid_hostname() {
    local value="$1"
    local label
    local -a labels=()

    ((${#value} >= 1 && ${#value} <= 253)) || return 1
    [[ "${value}" != .* && "${value}" != *. &&
        "${value}" != *[[:space:]]* && "${value}" != *..* ]] || return 1
    IFS='.' read -r -a labels <<<"${value}"
    for label in "${labels[@]}"; do
        ((${#label} >= 1 && ${#label} <= 63)) || return 1
        [[ "${label}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
}

# 域名字面量：RFC 1035 上限 253 字节
readonly DOMAIN_REGEX='^([a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$'
readonly DOMAIN_MAX_LENGTH=253
# 域名会被用作文件名（Nginx 站点配置 <domain>.conf）时的上限，为 ".conf" 预留 5 字节
readonly DOMAIN_FILENAME_MAX_LENGTH=250

# =============================================================================
# 函数名称: valid_domain
# 功能描述: 校验字符串是否为合法域名（253 字节上限）。
# 参数:
#   $1: 待校验的字符串
# 返回值: 0-有效 1-无效
# =============================================================================
function valid_domain() {
    local domain="$1"
    ((${#domain} > 0 && ${#domain} <= DOMAIN_MAX_LENGTH)) && [[ "${domain}" =~ ${DOMAIN_REGEX} ]]
}

# =============================================================================
# 函数名称: valid_domain_filename
# 功能描述: 校验字符串是否为「可安全用作文件名」的合法域名。
#           比 valid_domain 更严格：预留 ".conf" 后缀，避免域名过长导致文件名超限。
# 参数:
#   $1: 待校验的字符串
# 返回值: 0-有效 1-无效
# =============================================================================
function valid_domain_filename() {
    local domain="$1"
    ((${#domain} > 0 && ${#domain} <= DOMAIN_FILENAME_MAX_LENGTH)) && [[ "${domain}" =~ ${DOMAIN_REGEX} ]]
}

declare PARSED_HOST=''
declare PARSED_PORT=''
declare PARSED_HOST_IS_IP=0

function parse_host_port() {
    local value="$1"
    local host='' port='' normalized_port=''

    PARSED_HOST=''
    PARSED_PORT=''
    PARSED_HOST_IS_IP=0
    if [[ "${value}" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        valid_ipv6_literal "${host}" || return 1
        PARSED_HOST_IS_IP=1
    elif [[ "${value}" == *:* && "${value}" != *:*:* ]]; then
        host="${value%:*}"
        port="${value##*:}"
        if valid_ipv4_literal "${host}"; then
            PARSED_HOST_IS_IP=1
        else
            valid_hostname "${host}" || return 1
        fi
    else
        return 1
    fi
    # 与 core/check.sh 的 check_port 同一套字符串层归一化：20 位十进制串进入 Bash
    # 的 64 位算术会回绕（18446744073709551617 → 1），超范围的反代目标端口可能被
    # 静默接受成另一个端口。先去掉前导零并限位，再做算术比较。
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    normalized_port="${port#"${port%%[!0]*}"}"
    normalized_port="${normalized_port:-0}"
    [[ "${#normalized_port}" -le 5 ]] || return 1
    port=$((10#${normalized_port}))
    ((port >= 1 && port <= 65535)) || return 1
    PARSED_HOST="${host}"
    PARSED_PORT="${port}"
}

function format_host_port() {
    local host="$1"
    local port="$2"
    if valid_ipv6_literal "${host}"; then
        printf '[%s]:%s' "${host}" "${port}"
    else
        printf '%s:%s' "${host}" "${port}"
    fi
}

function hy2_ip_cron_identifier() {
    local line="$1"
    local prefix="17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d "
    local suffix=" --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1"
    local marker=' # xray-script-hy2-ip-renew'
    local identifier

    [[ "${line}" == *"${marker}" ]] && line="${line%"${marker}"}"
    [[ "${line}" == "${prefix}"*"${suffix}" ]] || return 1
    identifier="${line#"${prefix}"}"
    identifier="${identifier%"${suffix}"}"
    [[ "${line}" == "${prefix}${identifier}${suffix}" ]] || return 1
    valid_ip_literal "${identifier}" || return 1
    printf '%s\n' "${identifier}"
}

function is_managed_hy2_ip_cron_line() {
    hy2_ip_cron_identifier "$1" >/dev/null
}

# =============================================================================
# 函数名称: probe_public_ip
# 功能描述: 探测本机公网地址（IPv4 / IPv6 各请求一次），同一进程内只探测一次。
#           结果写入 PUBLIC_IPV4 / PUBLIC_IPV6，供 DNS 校验、分享链接等复用。
# 参数: 无
# 返回值: 0-至少探测到一个地址 1-两个地址都没探测到
# =============================================================================
declare PUBLIC_IPV4=''
declare PUBLIC_IPV6=''
declare PUBLIC_IP_PROBED=0

function probe_public_ip() {
    local candidate=''

    if [[ "${PUBLIC_IP_PROBED}" -eq 1 ]]; then
        [[ -n "${PUBLIC_IPV4}" || -n "${PUBLIC_IPV6}" ]]
        return
    fi
    PUBLIC_IP_PROBED=1
    PUBLIC_IPV4=''
    PUBLIC_IPV6=''
    if candidate="$(curl -fsS4L --max-time 10 https://api.ipify.org 2>/dev/null)" &&
        valid_ipv4_literal "${candidate}"; then
        PUBLIC_IPV4="${candidate}"
    fi
    if candidate="$(curl -fsS6L --max-time 10 https://api64.ipify.org 2>/dev/null)" &&
        valid_ipv6_literal "${candidate}"; then
        PUBLIC_IPV6="${candidate}"
    fi
    [[ -n "${PUBLIC_IPV4}" || -n "${PUBLIC_IPV6}" ]]
}

# =============================================================================
# 函数名称: backup_config
# 功能描述: 在修改配置文件前自动创建带时间戳的备份。
# 参数:
#   $1: 要备份的文件路径
# 返回值: 无
# =============================================================================
function backup_config() {
    local file="$1"
    if [[ -f "${file}" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -f "${file}" "${backup}"
    fi
}

# =============================================================================
# 函数名称: write_config
# 功能描述: 安全写入配置文件（设置正确权限 + sync）。
# 参数:
#   $1: 要写入的内容
#   $2: 目标文件路径
# 返回值: 无
# =============================================================================
function write_config() {
    local content="$1"
    local target="$2"
    # 防止写入空内容导致配置文件损坏
    if [[ -z "${content}" ]] || ! echo "${content}" | jq empty 2>/dev/null; then
        echo -e "${RED}[错误]${NC} 拒绝写入空或无效的 JSON 内容到 ${target}" >&2
        return 1
    fi
    local temp_file
    temp_file="$(mktemp "${target}.tmp.XXXXXX")" || return 1
    if ! printf '%s\n' "${content}" >"${temp_file}"; then
        rm -f -- "${temp_file}"
        return 1
    fi
    chmod 600 "${temp_file}"
    if ! mv -f -- "${temp_file}" "${target}"; then
        rm -f -- "${temp_file}"
        return 1
    fi
    sync
}

# =============================================================================
# 函数名称: read_line_or_abort
# 功能描述: 读取一行用户输入，区分「EOF / stdin 关闭」与「用户按回车」。
#           交互循环里的裸 read 在 EOF 下变量保持空、校验必然失败，于是无限重试，
#           非交互调用（stdin 已耗尽）会把脚本挂死；带默认值的裸 read 则把 EOF 当成
#           用户接受了默认项，静默执行签发证书这类不可逆动作。两种都不接受：
#           读取失败时打印中止提示并返回 1，由调用方 return 中止整条操作。
#           用法: value="$(read_line_or_abort)" || return 1
# 参数: 无
# 返回值: 0-读到一行（stdout 输出该行，可为空串）1-EOF / 读取失败
# =============================================================================
function read_line_or_abort() {
    local value=''
    if ! read -r value; then
        printf '\n' >&2
        log_error "$(t '.menu.aborted')" >&2
        return 1
    fi
    printf '%s\n' "${value}"
}
