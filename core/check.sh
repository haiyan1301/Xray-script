#!/usr/bin/env bash
#
# Copyright (C) 2025 zxcvos
#
# Xray-script:
#   https://github.com/zxcvos/Xray-script
# =============================================================================
# 注释: 通过 Qwen3-Coder 生成。
# 脚本名称: check.sh
# 功能描述: 提供一系列验证函数，用于检查 IP、端口、UUID、密码、路径、Short ID、
#           域名安全性、DNS 解析、Xray 配置/版本以及邮箱地址的有效性。
#           主要用于在配置过程中验证用户输入或系统状态。
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash, jq, dig, curl, openssl, stdbuf
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
#
# 退出码契约（调用方只依赖退出码，不解析输出）:
#   0 - 校验通过
#   1 - 校验失败（输入不合法）
#   2 - 用法错误（未知选项；绝不可当成「校验通过」放行）
# 所有提示信息一律写 stderr（main 里各分支显式 >&2），stdout 留给调用方。
# 规则单一来源：IP/域名/主机端口在 lib/common.sh，路径规则在 lib/protocols.sh，
# 本脚本只负责「取值 + 打印 + 返回码」，不再自带第二套正则。
# =============================================================================

# set -Eeuxo pipefail

# --- 环境与常量设置 ---
# 将常用路径添加到 PATH 环境变量，确保脚本能在不同环境中找到所需命令
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin
export PATH

# 获取当前脚本的目录、文件名（不含扩展名）和项目根目录的绝对路径
readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)" # 当前脚本所在目录
readonly CUR_FILE="$(basename "$0" | sed 's/\..*//')"         # 当前脚本文件名 (不含扩展名)
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# 复用公共的 IPv4/IPv6 语法校验器；本脚本仍保持可独立执行。
source "${PROJECT_ROOT}/lib/common.sh"
# 复用 lib/protocols.sh 里的路径规则（validate_path_rules），避免与 handler 各自维护一套。
source "${PROJECT_ROOT}/lib/protocols.sh"

# 定义配置文件和相关目录的路径
readonly SCRIPT_CONFIG_DIR="${HOME}/.xray-script"              # 主配置文件目录
readonly I18N_DIR="${PROJECT_ROOT}/i18n"                       # 国际化文件目录
readonly CONFIG_DIR="${PROJECT_ROOT}/config"                   # 配置文件目录
readonly CONFIG_XRAY_DIR="${CONFIG_DIR}/xray"                  # Xray 配置文件目录
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json" # 脚本主配置文件路径

# --- 退出码契约常量 ---
# 见文件头「退出码契约」。调用方（core/handler.sh 的 exec_check）只依赖这三个码。
readonly CHECK_OK=0      # 校验通过
readonly CHECK_INVALID=1 # 校验失败（输入不合法）
readonly CHECK_USAGE=2   # 用法错误（未知选项）

# --- 正则表达式常量 ---
# 定义各种数据格式的正则表达式，用于验证输入
# DOMAIN_REGEX 由 lib/common.sh 提供（与 valid_domain / valid_domain_filename 同源）
readonly HEX_REGEX='^[0-9a-fA-F]+$'                                                                         # 十六进制字符串
readonly UUID_REGEX='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' # UUID
readonly EMAIL_LOCAL_REGEX='^[a-zA-Z0-9_%+-]+(\.[a-zA-Z0-9_%+-]+)*$'                                       # 邮箱本地部分（点分原子）

# --- 全局变量声明 ---
# 声明用于存储语言参数和国际化数据的全局变量
declare LANG_PARAM='' # (未在脚本中实际使用，可能是预留)


# _info / _pass / _fail / _test 由 lib/log.sh 统一提供（经第 35 行的 lib/common.sh）。
# 统一后 .title.info 与全仓其它位置一致使用绿色（原先此处是黄色）。

# =============================================================================
# 域名校验由 lib/common.sh 的 valid_domain 统一提供（本脚本第 35 行已 source）。
# =============================================================================

# =============================================================================
# 函数名称: resolve_domain
# 功能描述: 使用 dig 命令尝试解析域名，检查是否有有效的 IP 地址记录。
# 参数:
#   $1: 待解析的域名 (domain)
# 返回值: 0-解析成功 1-解析失败或无记录
# =============================================================================
function resolve_domain() {
    # 使用 dig +short 命令解析域名，并将输出通过管道传递给 grep
    # 如果 grep 能在输出中找到至少一个 '.' 字符（通常是 IP 地址的一部分），则返回 0
    # 否则返回 1
    if dig +short "$1" | grep -q '.'; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# 函数名称: dns_resolution
# 功能描述: 检查给定域名是否解析为当前服务器的 IP 地址。
#           分别检查 IPv4 和 IPv6 地址。
# 参数:
#   $1: 待检查的域名 (domain)
# 返回值: 0-至少有一个 IP 匹配 1-都不匹配
# =============================================================================
function dns_resolution() {
    local domain=$1 # 获取域名参数
    local expected_ipv4 expected_ipv6

    # 父进程已探测过公网地址时直接复用，避免每个域名都重新请求一次。
    if [[ "${CHECK_DNS_IP_PROBED:-0}" -eq 1 ]]; then
        expected_ipv4="${CHECK_DNS_EXPECTED_IPV4:-}"
        expected_ipv6="${CHECK_DNS_EXPECTED_IPV6:-}"
    else
        probe_public_ip || true
        expected_ipv4="${PUBLIC_IPV4}"
        expected_ipv6="${PUBLIC_IPV6}"
    fi

    local resolved=0 # 初始化标志变量，表示是否匹配

    # 解析域名的 IPv4 和 IPv6 记录
    local actual_ipv4="$(dig +short "${domain}")"
    local actual_ipv6="$(dig +short AAAA "${domain}")"

    # 检查解析到的 IPv4 是否包含服务器的 IPv4
    if [[ -n "${expected_ipv4}" ]] && grep -Fxq "${expected_ipv4}" <<<"${actual_ipv4}"; then resolved=1; fi
    # 检查解析到的 IPv6 是否包含服务器的 IPv6
    if [[ -n "${expected_ipv6}" ]] && grep -Fxq "${expected_ipv6}" <<<"${actual_ipv6}"; then resolved=1; fi

    # 根据 resolved 标志返回结果
    [[ ${resolved} -eq 1 ]]
}

# =============================================================================
# 函数名称: test_tcp_connection
# 功能描述: 测试到指定主机和端口的 TCP 连接是否可达。
#           利用 bash 内建的 /dev/tcp 特性。
# 参数:
#   $1: 主机名或 IP 地址 (host)
#   $2: 端口号 (port)
# 返回值: 0-连接成功 1-连接失败 (由 /dev/tcp 操作的退出码决定)
# =============================================================================
function test_tcp_connection() {
    # 尝试打开到 host:port 的 TCP 连接，将输出重定向到 /dev/null
    # 成功则返回 0，失败（如连接被拒绝、超时）则返回非 0
    # 让 /dev/tcp 操作直接成为函数的最终状态，避免额外读取和转发 `$?`。
    echo >/dev/tcp/"$1"/"$2" 2>/dev/null
}

# =============================================================================
# 函数名称: get_tls_info
# 功能描述: 使用 openssl s_client 命令获取指定域名的 TLS 信息。
# 参数:
#   $1: 域名 (domain)
# 返回值: TLS 连接的详细信息 (echo 输出)
# 注意: 会过滤掉空字节 (\0)
# =============================================================================
function get_tls_info() {
    # 向域名的 443 端口发起 TLS 1.3 连接请求，并指定 ALPN 为 h2
    # 使用 echo QUIT 发送退出命令，stdbuf -oL 确保输出行缓冲
    # 2>&1 将错误输出合并到标准输出，tr -d '\0' 过滤掉空字节
    echo QUIT | stdbuf -oL openssl s_client -connect "${1}:443" -tls1_3 -alpn h2 2>&1 | tr -d '\0'
}

# =============================================================================
# 函数名称: check_ip
# 功能描述: 验证 IP 地址是否符合 IPv4 或 IPv6 格式。
# 参数:
#   $1: 待检查的 IP 地址 (ip)
# 返回值: 0-有效 1-无效 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_ip() {
    local ip="$1" # 获取 IP 地址参数

    # 打印正在检查的信息
    _info "$(t ".${CUR_FILE}.ip.check")${ip}"

    # 使用正则表达式检查 IPv4 格式
    if valid_ipv4_literal "$ip"; then
        _pass "$(t ".${CUR_FILE}.ip.ipv4_valid")$ip"
        return 0
    # 使用正则表达式检查 IPv6 格式
    elif valid_ipv6_literal "$ip"; then
        _pass "$(t ".${CUR_FILE}.ip.ipv6_valid")$ip"
        return 0
    else
        # 如果都不匹配，则为无效 IP
        _fail "$(t ".${CUR_FILE}.ip.invalid")$ip"
        return 1
    fi
}

# =============================================================================
# 函数名称: check_port
# 功能描述: 验证端口号是否在有效范围内 (1-65535)。
#           先在字符串层归一化再算术比较，避免超长数字在 Bash 算术中回绕。
# 参数:
#   $1: 待检查的端口号 (port)
# 返回值: 0-有效或为空 1-无效 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_port() {
    local port="$1" # 获取端口号参数
    local normalized=''

    # 打印正在检查的信息
    _info "$(t ".${CUR_FILE}.port.check")${port}"

    # 如果端口为空，则认为是有效的（可能表示使用默认值）
    if [[ -z "${port}" ]]; then
        _pass "$(t ".${CUR_FILE}.port.empty")"
        return 0
    fi

    # 先在字符串层归一化（纯数字 + 去前导零 + 限位），再做算术比较。
    # 20 位十进制串进入 Bash 的 64 位算术会回绕：18446744073709551617 会变成 1，
    # 18446744073709584384 会变成 32768，超范围输入因此被静默接受成另一个端口。
    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        _fail "$(t ".${CUR_FILE}.port.range_error")$port"
        return 1
    fi
    normalized="${port#"${port%%[!0]*}"}"
    normalized="${normalized:-0}"

    # 检查归一化后的端口号是否在 1-65535 范围内
    if [[ "${#normalized}" -gt 5 ]] || ((10#${normalized} < 1 || 10#${normalized} > 65535)); then
        _fail "$(t ".${CUR_FILE}.port.range_error")$port"
        return 1
    fi

    # 保留端口在归一化之后比较，避免 "032768" 之类绕过检查。
    if [[ -n "${XRAY_API_PORT:-}" ]] && ((10#${normalized} == XRAY_API_PORT)); then
        _fail "$(t ".${CUR_FILE}.port.reserved_error" | sed "s/32768/${XRAY_API_PORT}/g")"
        return 1
    fi

    _pass "$(t ".${CUR_FILE}.port.valid")$port"
    return 0
}

# =============================================================================
# 函数名称: check_uuid
# 功能描述: 验证 UUID 输入。空值与普通字符串按设计放行（前者自动生成，后者由 Xray 映射成
#           UUID），但含空白或控制字符的值无法安全写入配置，判为无效。
# 参数:
#   $1: 待检查的 UUID 字符串 (uuid)
# 返回值: 0-有效 1-无效 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_uuid() {
    local uuid="$1" # 获取 UUID 参数

    # 打印正在检查的信息
    _info "$(t ".${CUR_FILE}.uuid.check")${uuid}"

    # 如果 UUID 为空，则认为是有效的（可能表示使用默认值或自动生成）
    if [[ -z "${uuid}" ]]; then
        _pass "$(t ".${CUR_FILE}.uuid.empty")"
        return 0
    fi

    # 含空白或控制字符的输入既无法安全落盘，也无法作为参数传递
    if [[ "${uuid}" =~ [[:space:][:cntrl:]] ]]; then
        _fail "$(t ".${CUR_FILE}.uuid.unsafe")${uuid}"
        return 1
    fi

    # 如果 UUID 不符合标准格式，则认为是有效的字符串（可能表示使用普通字符串）
    if ! [[ "${uuid}" =~ $UUID_REGEX ]]; then
        _pass "$(t ".${CUR_FILE}.uuid.string")${uuid}"
        return 0
    fi

    # 如果符合标准格式，则为有效 UUID
    _pass "$(t ".${CUR_FILE}.uuid.valid")${uuid}"
    return 0
}

# =============================================================================
# 函数名称: check_password
# 功能描述: 验证密码是否符合基本安全要求（非空、无空格、长度>=8）。
# 参数:
#   $1: 待检查的密码 (password)
# 返回值: 0-有效 1-无效 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_password() {
    local password="$1" # 获取密码参数

    # 打印正在检查的信息
    _info "$(t ".${CUR_FILE}.password.check")${password}"

    # 如果密码为空，则认为无效
    if [[ -z "${password}" ]]; then
        _pass "$(t ".${CUR_FILE}.password.empty")"
        return 0
    fi

    # 检查密码中是否包含空格
    if [[ "${password}" == *" "* ]]; then
        _fail "$(t ".${CUR_FILE}.password.space_error")$password"
        return 1
    fi

    # 检查密码长度是否小于 8
    if ((${#password} < 8)); then
        _fail "$(t ".${CUR_FILE}.password.length_error")$password"
        return 1
    fi

    # 如果所有检查都通过，则密码有效
    _pass "$(t ".${CUR_FILE}.password.valid")$password"
    return 0
}

function check_ss2022_key() {
    local key="$1"
    local decoded_size

    _info "$(t ".${CUR_FILE}.ss2022_key.check")"
    if [[ -z "${key}" ]]; then
        _pass "$(t ".${CUR_FILE}.ss2022_key.empty")"
        return 0
    fi

    if [[ ! "${key}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
        _fail "$(t ".${CUR_FILE}.ss2022_key.invalid")"
        return 1
    fi

    decoded_size="$(printf '%s' "${key}" | base64 --decode 2>/dev/null | wc -c | tr -d '[:space:]')"
    if [[ "${decoded_size}" != '32' ]]; then
        _fail "$(t ".${CUR_FILE}.ss2022_key.invalid")"
        return 1
    fi

    _pass "$(t ".${CUR_FILE}.ss2022_key.valid")"
    return "${CHECK_OK}"
}

function check_xhttp_mode() {
    local mode="${1,,}"

    case "${mode}" in
    auto | packet-up | stream-up | stream-one)
        return 0
        ;;
    *)
        _fail "$(t ".${CUR_FILE}.xhttp_mode.invalid")${1}"
        return 1
        ;;
    esac
}

# =============================================================================
# 函数名称: _path_fail
# 功能描述: 根据 validate_path_rules 返回的原因打印对应的 i18n 失败信息。
# 参数:
#   $1: 失败原因 (validate_path_rules 设置的 _PATH_ERROR)
#   $2: 待检查的路径字符串
# 返回值: 无 (打印到 >&2)
# =============================================================================
function _path_fail() {
    local reason="$1" path="$2"
    # 失败原因 -> i18n 键后缀的映射由 lib/protocols.sh 的 path_error_key 统一提供，
    # 本脚本不再自己维护一份（否则 protocols.sh 新增原因时会静默落到 char_error）。
    _fail "$(t ".${CUR_FILE}.path.$(path_error_key "${reason}")")${path}"
}

# =============================================================================
# 函数名称: check_path_ex
# 功能描述: 路径校验的共用实现。check_path 与 check_path_required 只差两组参数，
#           规则本身来自 lib/protocols.sh 的 validate_path_rules。
# 参数:
#   $1: 待检查的路径字符串 (path)
#   $2: 是否允许为空 (yes/no)
#   $3: 是否要求首尾斜杠 (yes/no)
# 返回值: 0-有效 1-无效 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_path_ex() {
    local path="$1"
    local allow_empty="${2:-no}"
    local require_slashes="${3:-no}"

    # 打印正在检查的信息
    _info "$(t ".${CUR_FILE}.path.check")${path}"

    # 允许为空且确实为空：放行并给出「将使用默认值」的提示。
    # 不能省掉这一步只靠 validate_path_rules 的 allow_empty——那样会走到 .path.valid
    # 分支，少一条 .path.empty 提示。
    if [[ -z "${path}" && "${allow_empty}" == 'yes' ]]; then
        _pass "$(t ".${CUR_FILE}.path.empty")"
        return "${CHECK_OK}"
    fi

    if ! validate_path_rules "${path}" "${allow_empty}" "${require_slashes}"; then
        _path_fail "${_PATH_ERROR}" "${path}"
        return "${CHECK_INVALID}"
    fi

    # 如果所有检查都通过，则路径有效
    _pass "$(t ".${CUR_FILE}.path.valid")${path}"
    return "${CHECK_OK}"
}

# 允许为空，不要求首尾斜杠（非 xhttp 协议的路径）
function check_path() { check_path_ex "${1:-}" 'yes' 'no'; }

# 不允许为空，且要求首尾斜杠（xhttp 协议的路径）
function check_path_required() { check_path_ex "${1:-}" 'no' 'yes'; }

# =============================================================================
# 函数名称: check_short_id
# 功能描述: 验证 Short ID 是否符合要求（空、单数字、或有效的十六进制字符串）。
# 参数:
#   $1: 待检查的 Short ID (short_id)
# 返回值: 0-有效 1-无效 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_short_id() {
    local short_id="$1" # 获取 Short ID 参数

    # 打印正在检查的信息
    _info "$(t ".${CUR_FILE}.short.check")${short_id}"

    # 如果 Short ID 为空，则认为是有效的
    if [[ -z "${short_id}" ]]; then
        _pass "$(t ".${CUR_FILE}.short.empty")"
        return 0
    fi

    # 如果 Short ID 是 0-8 的单个数字，则认为是有效的（表示生成指定长度的 ID）
    if [[ ${short_id} =~ ^[0-8]$ ]]; then
        _pass "$(t ".${CUR_FILE}.short.digit")$short_id"
        return 0
    fi

    # 检查 Short ID 的长度是否为奇数或超过 16
    if ((${#short_id} % 2 != 0 || ${#short_id} > 16)); then
        _fail "$(t ".${CUR_FILE}.short.length_error")$short_id"
        return 1
    fi

    # 检查 Short ID 是否为有效的十六进制字符串
    if ! [[ "${short_id}" =~ $HEX_REGEX ]]; then
        _fail "$(t ".${CUR_FILE}.short.hex_error")$short_id"
        return 1
    fi

    # 如果所有检查都通过，则 Short ID 有效
    _pass "$(t ".${CUR_FILE}.short.valid")$short_id"
    return 0
}

# =============================================================================
# 函数名称: check_domain_security
# 功能描述: 全面检查域名的安全性，包括格式、解析、TCP 连接和 TLS 信息。
# 参数:
#   $1: 待检查的域名 (domain)
# 返回值: 0-安全检查通过 1-安全检查失败 (并打印详细的检查过程和结果到 >&2)
# =============================================================================
function check_domain_security() {
    local domain="$1" # 获取域名参数

    # 打印正在检查的信息
    _info "$(t ".${CUR_FILE}.domain.security_check")${domain}"

    # 如果域名为空，则认为是有效的（可能表示不使用域名）
    if [[ -z "${domain}" ]]; then
        _pass "$(t ".${CUR_FILE}.domain.empty")"
        return 0
    fi

    # 检查域名格式是否有效
    if ! valid_domain "$domain"; then
        _fail "$(t ".${CUR_FILE}.domain.format_error")$domain"
        return 1
    fi

    # 测试域名解析
    _test "$(t ".${CUR_FILE}.domain.resolve")${domain}"
    if ! resolve_domain "$domain"; then
        _fail "$(t ".${CUR_FILE}.domain.resolve_fail")$domain"
        return 1
    fi

    # 测试到域名 443 端口的 TCP 连接
    _test "$(t ".${CUR_FILE}.tcp.connect_check"): ${domain}:443"
    if ! test_tcp_connection "$domain" 443; then
        _fail "$(t ".${CUR_FILE}.tcp.connect_fail" | sed "s/\${domain}/${domain}/")"
        return 1
    fi

    # 获取域名的 TLS 信息
    _test "$(t ".${CUR_FILE}.tls.info"): ${domain}"
    local tls_info
    tls_info=$(get_tls_info "$domain")

    # 检查是否支持 TLS 1.3
    if ! echo "$tls_info" | grep -q "TLSv1.3"; then
        _fail "$(t ".${CUR_FILE}.tls.error")"
        return 1
    else
        _pass "$(t ".${CUR_FILE}.tls.pass")"
    fi

    # 检查是否使用 X25519 密钥交换算法
    if echo "$tls_info" | grep -q "X25519"; then
        _pass "$(t ".${CUR_FILE}.tls.key_exchange_pass")"
    else
        _fail "$(t ".${CUR_FILE}.tls.key_exchange_warn")$domain"
        return 1
    fi

    # 如果所有检查都通过，则域名安全检查通过
    _pass "$(t ".${CUR_FILE}.domain.security_pass" | sed "s/\${domain}/${domain}/")"
    return 0
}

# =============================================================================
# 函数名称: check_dns_resolution
# 功能描述: 检查域名是否解析为当前服务器的 IP 地址。
# 参数:
#   $1: 待检查的域名 (domain)
# 返回值: 0-DNS 解析正确 1-DNS 解析错误 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_dns_resolution() {
    local domain="$1" # 获取域名参数

    # 打印正在检查的信息
    _info "$(t ".${CUR_FILE}.dns.check_start")${domain}"

    # 检查域名格式是否有效
    if ! valid_domain "$domain"; then
        _fail "$(t ".${CUR_FILE}.domain.format_error")$domain"
        return 1
    fi

    # 测试域名解析
    _test "$(t ".${CUR_FILE}.domain.resolve"): ${domain}"
    if ! dns_resolution "$domain"; then
        _fail "$(t ".${CUR_FILE}.dns.resolution_fail")$domain"
        return 1
    fi

    # 如果解析正确，则检查通过
    _pass "$(t ".${CUR_FILE}.dns.check_pass" | sed "s/\${domain}/${domain}/")"
    return 0
}

# =============================================================================
# 函数名称: check_domain_format
# 功能描述: 仅检查域名格式，不执行 DNS 解析或源站 IP 匹配。
# 参数:
#   $1: 待检查的域名 (domain)
# 返回值: 0-格式正确 1-格式错误
# =============================================================================
function check_domain_format() {
    local domain="$1"

    if ! valid_domain "$domain"; then
        _fail "$(t ".${CUR_FILE}.domain.format_error")$domain"
        return 1
    fi

    return 0
}

# =============================================================================
# 函数名称: check_xray_config_exists
# 功能描述: 检查指定名称的 Xray 配置文件是否存在。
# 参数:
#   $1: 配置文件名（不含扩展名）(SCRIPT_FILE)
# 返回值: 0-文件存在 1-文件不存在 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_xray_config_exists() {
    local SCRIPT_FILE="$1" # 获取配置文件名参数
    # 构造完整的配置文件路径
    local CONFIG_FILE="${CONFIG_XRAY_DIR}/${SCRIPT_FILE}.json"

    # 打印正在检查的信息
    _info "$(t ".${CUR_FILE}.config.check")${CONFIG_FILE}"

    # 检查文件是否存在
    if [[ -f "${CONFIG_FILE}" ]]; then
        _pass "$(t ".${CUR_FILE}.config.exist")${CONFIG_FILE}"
        return 0
    else
        _fail "$(t ".${CUR_FILE}.config.not_exist")${CONFIG_FILE}"
        return 1
    fi
}

# =============================================================================
# 函数名称: check_xray_version_exists
# 功能描述: 通过访问 GitHub Releases 页面检查指定的 Xray 版本是否存在。
# 参数:
#   $1: Xray 版本号 (version)
# 返回值: 0-版本存在 1-版本不存在 (并打印相应的提示信息到 >&2)
# =============================================================================
function check_xray_version_exists() {
    local version="$1" # 获取版本号参数

    # 打印正在检查的信息
    _info "$(t ".${CUR_FILE}.version.check")v${version}"

    # 构造 GitHub Releases 页面的 URL
    local version_url="https://github.com/XTLS/Xray-core/releases/tag/v${version#*v}"

    # 使用 curl 获取页面的 HTTP 状态码
    local status_code=$(curl -L -o /dev/null -s -w '%{http_code}\n' "$version_url")

    # 检查状态码是否为 200 (OK)
    if [[ "$status_code" == "200" ]]; then
        _pass "$(t ".${CUR_FILE}.version.exist")${version}"
        return 0
    else
        _fail "$(t ".${CUR_FILE}.version.not_exist")${version}"
        return 1
    fi
}

# =============================================================================
# 函数名称: validate_email
# 功能描述: 验证邮箱地址格式是否正确。
# 参数:
#   $1: 待验证的邮箱地址 (email)
# 返回值: 0-格式正确 1-格式错误或为空 (并打印相应的提示信息到 >&2)
# =============================================================================
function validate_email() {
    local email="$1" # 获取邮箱地址参数
    local local_part domain_part

    # 打印正在检查的信息
    _info "$(t ".${CUR_FILE}.email.check")${email}"

    # 如果邮箱地址为空，则认为无效
    if [[ -z "${email}" ]]; then
        _fail "$(t ".${CUR_FILE}.email.empty")"
        return 1
    fi

    # ACME 服务不接受本地部分以点开头/结尾或包含连续点的地址；
    # 域名部分复用严格的域名标签校验，避免首尾连字符等无效格式。
    local_part="${email%@*}"
    domain_part="${email#*@}"
    if ((${#email} > 254 || ${#local_part} > 64)) ||
        [[ "${email}" != *@* || "${domain_part}" == *"@"* ]] ||
        [[ ! "${local_part}" =~ ${EMAIL_LOCAL_REGEX} ]] ||
        ! valid_domain "${domain_part}"; then
        _fail "$(t ".${CUR_FILE}.email.format_error")$email"
        return 1
    fi

    _pass "$(t ".${CUR_FILE}.email.valid")$email"
    return 0
}

# =============================================================================
# 函数名称: check_reverse_target
# 功能描述: 检查内网服务目标地址的合法性。
#           格式要求: IP:PORT 或 hostname:PORT
# 参数:
#   $1: target - 待检查的目标地址
# 返回值: 0 (通过), 1 (失败)
# =============================================================================
function check_reverse_target() {
    local target="$1"

    _info "$(t ".${CUR_FILE}.reverse_target.check")${target}"

    # 检查是否为空
    if [[ -z "${target}" ]]; then
        _fail "$(t ".${CUR_FILE}.reverse_target.empty")"
        return 1
    fi

    if ! parse_host_port "${target}"; then
        _fail "$(t ".${CUR_FILE}.reverse_target.format_error")${target}"
        return 1
    fi

    _pass "$(t ".${CUR_FILE}.reverse_target.valid")${target}"
    return 0
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。根据传入的第一个参数 (option)
#           调用相应的检查函数并输出结果。
# 参数:
#   $1: 操作选项 (e.g., --ip, --port, --uuid 等)
#   $@: 剩余参数，传递给被调用的具体函数
# 返回值: 无 (调用具体函数并输出其结果到 >&2)
# 退出码: 0-通过 / 1-校验失败 / 2-未知选项（见文件头「退出码契约」）。
#         case 各分支的最后一条命令就是具体校验函数，其退出码即 main 的返回值。
# =============================================================================
function main() {
    # 加载国际化数据
    load_i18n

    local option="$1" # 获取第一个参数作为操作选项
    shift             # 移除第一个参数，剩下的参数留给具体函数处理

    # 使用 case 语句根据选项调用对应的函数
    # 所有函数的输出都重定向到标准错误输出 >&2，这样标准输出可以用于返回结果
    case "${option}" in
    --ip) check_ip "$@" >&2 ;;                    # 检查 IP 地址
    --port) check_port "$@" >&2 ;;                # 检查端口
    --uuid) check_uuid "$@" >&2 ;;                # 检查 UUID
    --password) check_password "$@" >&2 ;;        # 检查密码
    --ss2022-key) check_ss2022_key "$@" >&2 ;;
    --xhttp-mode) check_xhttp_mode "$@" >&2 ;;
    --path) check_path "$@" >&2 ;;                # 检查路径
    --path-required) check_path_required "$@" >&2 ;;
    --short) check_short_id "$@" >&2 ;;           # 检查 Short ID
    --domain) check_domain_security "$@" >&2 ;;   # 检查域名安全性
    --domain-format) check_domain_format "$@" >&2 ;; # 仅检查域名格式
    --dns) check_dns_resolution "$@" >&2 ;;       # 检查 DNS 解析
    --tag) check_xray_config_exists "$@" >&2 ;;   # 检查 Xray 配置文件
    --xray) check_xray_version_exists "$@" >&2 ;; # 检查 Xray 版本
    --email) validate_email "$@" >&2 ;;           # 验证邮箱
    --reverse-target) check_reverse_target "$@" >&2 ;; # 检查反向代理目标地址
    *)
        # 未知选项不能静默返回 0：调用方会把 0 当作「校验通过」而放行未校验的值
        _fail "$(t ".${CUR_FILE}.usage.invalid_option")${option}"
        return "${CHECK_USAGE}"
        ;;
    esac
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
