#!/usr/bin/env bash
# =============================================================================
# 脚本名称: common.sh
# 功能描述: Xray-script 项目的公共函数库。
#           提供颜色常量、操作系统检测、命令检测、i18n 加载等公共功能。
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

# --- 颜色常量 ---
readonly GREEN='\033[32m'  # 绿色
readonly YELLOW='\033[33m' # 黄色
readonly RED='\033[31m'    # 红色
readonly NC='\033[0m'      # 无颜色（重置）

# --- 环境设置 ---
PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:${HOME}/bin:/snap/bin:${PATH:-}"
export PATH

# =============================================================================
# 函数名称: cmd_exists
# 功能描述: 检查指定的命令是否存在于系统中。
# 参数:
#   $1: 要检查的命令名称
# 返回值: 0-命令存在 1-命令不存在
# =============================================================================
function cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

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

declare PARSED_HOST=''
declare PARSED_PORT=''
declare PARSED_HOST_IS_IP=0

function parse_host_port() {
    local value="$1"
    local host='' port=''

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
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    port=$((10#${port}))
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
# 函数名称: _os
# 功能描述: 检测当前操作系统的发行版名称。
# 参数: 无
# 返回值: 操作系统名称 (echo 输出: debian/ubuntu/centos/...)
# =============================================================================
function _os() {
    local os=""
    if [[ -f "/etc/debian_version" ]]; then
        source /etc/os-release && os="${ID}"
        printf -- "%s" "${os}" && return
    fi
    if [[ -f "/etc/redhat-release" ]]; then
        os="centos"
        printf -- "%s" "${os}" && return
    fi
}

# =============================================================================
# 函数名称: _os_full
# 功能描述: 获取当前操作系统的完整发行版信息。
# 参数: 无
# 返回值: 完整的操作系统版本信息 (echo 输出)
# =============================================================================
function _os_full() {
    if [[ -f /etc/redhat-release ]]; then
        awk '{print ($1,$3~/^[0-9]/?$3:$4)}' /etc/redhat-release && return
    fi
    if [[ -f /etc/os-release ]]; then
        awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
    fi
    if [[ -f /etc/lsb-release ]]; then
        awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
    fi
}

# =============================================================================
# 函数名称: _os_ver
# 功能描述: 获取当前操作系统的主版本号。
# 参数: 无
# 返回值: 操作系统的主版本号 (echo 输出)
# =============================================================================
function _os_ver() {
    local main_ver="$(echo $(_os_full) | grep -oE "[0-9.]+")"
    printf -- "%s" "${main_ver%%.*}"
}

# =============================================================================
# 函数名称: load_i18n
# 功能描述: 加载国际化 (i18n) 数据。
#           从 config.json 读取语言设置，加载对应的 JSON i18n 文件。
# 参数: 无（使用全局变量 SCRIPT_CONFIG_PATH 和 I18N_DIR）
# 返回值: 无 (直接修改全局变量 I18N_DATA)
# =============================================================================
function load_i18n() {
    local lang="$(jq -r '.language // ""' "${SCRIPT_CONFIG_PATH}")"
    if [[ "$lang" == "auto" ]]; then
        lang="${LANG:-}"
        lang="${lang%%.*}"
        lang="${lang%%_*}"
        [[ "${lang,,}" == 'zh' ]] && lang='zh' || lang='en'
    fi
    # 如果语言为空或为 "null"，则默认使用中文
    if [[ -z "$lang" || "$lang" == "null" ]]; then
        lang="zh"
    fi
    local i18n_file="${I18N_DIR}/${lang}.json"
    if [[ ! -f "${i18n_file}" ]]; then
        if [[ "$lang" == "zh" ]]; then
            echo -e "${RED}[错误]${NC} 文件不存在: ${i18n_file}" >&2
        else
            echo -e "${RED}[Error]${NC} File Not Found: ${i18n_file}" >&2
        fi
        exit 1
    fi
    I18N_DATA="$(jq '.' "${i18n_file}")"
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
