#!/usr/bin/env bash
#
# Copyright (C) 2025 zxcvos
#
# Xray-script:
#   https://github.com/zxcvos/Xray-script
# =============================================================================
# 注释: 通过 Qwen3-Coder 生成。
# 脚本名称: share.sh
# 功能描述: 生成 Xray 服务的客户端配置信息和分享链接 (如 VLESS, Trojan)。
#           根据服务端配置 (Xray 和 Script) 自动提取必要参数，
#           构造多种类型的分享链接 (包括 Reality, XHTTP, mKCP, TLS 等)，
#           并可选地生成二维码。支持多语言。
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash, jq, curl, qrencode, sed
# 配置:
#   - ${XRAY_CONFIG_PATH}: Xray 服务端配置文件 (用于读取协议、UUID、密码等)
#   - ${SCRIPT_CONFIG_PATH}: 脚本自身配置文件 (用于读取端口、域名、路径等)
#   - ${I18N_DIR}/${lang}.json: 国际化文件 (用于显示多语言提示)
# =============================================================================

# set -Eeuxo pipefail

# --- 环境与常量设置 ---
# 将常用路径添加到 PATH 环境变量，确保脚本能在不同环境中找到所需命令
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin:/snap/bin
export PATH

# 定义颜色代码，用于在终端输出带颜色的信息
readonly GREEN='\033[32m'  # 绿色
readonly YELLOW='\033[33m' # 黄色
readonly RED='\033[31m'    # 红色
readonly NC='\033[0m'      # 无颜色（重置）

# 获取当前脚本的目录、文件名（不含扩展名）和项目根目录的绝对路径
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" # 当前脚本所在目录
readonly CUR_FILE="$(basename "${BASH_SOURCE[0]}" | sed 's/\..*//')"         # 当前脚本文件名 (不含扩展名)
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# 定义配置文件和相关目录的路径
readonly SCRIPT_CONFIG_DIR="${HOME}/.xray-script"              # 主配置文件目录
readonly I18N_DIR="${PROJECT_ROOT}/i18n"                       # 国际化文件目录
readonly CONFIG_DIR="${PROJECT_ROOT}/config"                   # 脚本配置文件目录
readonly GENERATE_PATH="${CUR_DIR}/generate.sh"                # 项目中的 generate.sh 脚本路径
readonly XRAY_CONFIG_PATH="${XRAY_CONFIG_PATH_OVERRIDE:-/usr/local/etc/xray/config.json}" # Xray 服务端配置文件路径
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_PATH_OVERRIDE:-${SCRIPT_CONFIG_DIR}/config.json}" # 脚本主要配置文件路径

# --- 全局变量声明 ---
# 声明用于存储语言参数、国际化数据和配置信息的全局变量
declare LANG_PARAM=''       # (未在脚本中实际使用，可能是预留)
declare I18N_DATA=''        # 存储从 i18n JSON 文件中读取的全部数据
declare -A CLIENT_CONFIG    # 关联数组，存储当前处理的客户端配置片段
declare XRAY_CONFIG         # 存储 Xray 配置文件的全部 JSON 内容
declare SCRIPT_CONFIG       # 存储脚本配置文件的全部 JSON 内容
declare XHTTP_EXTRA         # 存储额外的 XHTTP 下行设置 JSON 字符串
declare XHTTP_EXTRA_ENCODED # 存储经过 URL 编码的 XHTTP_EXTRA 字符串
declare SHARE_LINK          # 存储最终生成的分享链接
declare PUBLIC_HOST_LOOKUP_STATE='unattempted'
declare PUBLIC_HOST_CACHE=''
# 声明一系列变量用于存储分享链接的各个组成部分，便于拼接不同类型的链接
declare SHARE_LINK_COMPONENT_VLESS   # VLESS 协议的基础部分
declare SHARE_LINK_COMPONENT_TROJAN  # Trojan 协议的基础部分
declare SHARE_LINK_COMPONENT_MKCP    # mKCP 网络传输的参数部分
declare SHARE_LINK_COMPONENT_TLS     # TLS 安全传输的参数部分
declare SHARE_LINK_COMPONENT_REALITY # Reality 安全传输的参数部分
declare SHARE_LINK_COMPONENT_XHTTP   # XHTTP 网络传输的参数部分
declare SHARE_LINK_COMPONENT_FLOW    # Flow 控制参数部分
declare SHARE_LINK_COMPONENT_HOST    # XHTTP Host 参数部分
declare SHARE_LINK_COMPONENT_EXTRA   # 额外参数 (如 downloadSettings) 部分
declare SHARE_LINK_COMPONENT_VLESS_ENC # VLESS enc 的 encryption 参数部分

# =============================================================================
# 函数名称: load_i18n
# 功能描述: 加载国际化 (i18n) 数据。
#           1. 从 config.json 读取语言设置。
#           2. 如果设置为 "auto"，则尝试从系统环境变量 $LANG 推断语言。
#           3. 根据确定的语言，加载对应的 JSON i18n 文件。
#           4. 将文件内容读入全局变量 I18N_DATA。
# 参数: 无
# 返回值: 无 (直接修改全局变量 I18N_DATA)
# 退出码: 如果 i18n 文件不存在，则输出错误信息并退出脚本 (exit 1)
# =============================================================================
function load_i18n() {
    # 从脚本配置文件中读取语言设置
    local lang="$(jq -r '.language' "${SCRIPT_CONFIG_PATH}")"

    # 如果语言设置为 "auto"，则使用系统环境变量 LANG 的第一部分作为语言代码
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

    # 构造 i18n 文件的完整路径
    local i18n_file="${I18N_DIR}/${lang}.json"

    # 检查 i18n 文件是否存在
    if [[ ! -f "${i18n_file}" ]]; then
        # 文件不存在时，根据语言输出不同的错误信息
        if [[ "$lang" == "zh" ]]; then
            echo -e "${RED}[错误]${NC} 文件不存在: ${i18n_file}" >&2
        else
            echo -e "${RED}[Error]${NC} File Not Found: ${i18n_file}" >&2
        fi
        # 退出脚本，错误码为 1
        exit 1
    fi

    # 读取 i18n 文件的全部内容到全局变量 I18N_DATA
    I18N_DATA="$(jq '.' "${i18n_file}")"
}

# =============================================================================
# 函数名称: urlencode
# 功能描述: 对输入字符串进行 URL 编码。
#           将非字母数字、非 .~_- 的字符转换为 %XX 格式。
# 参数:
#   $1 (可选): 待编码的字符串。如果不提供，则从标准输入读取。
# 返回值: URL 编码后的字符串 (echo 输出)
# =============================================================================
function urlencode() {
    local LC_ALL=C
    local input # 声明局部变量存储输入

    # 如果没有传入参数，则从标准输入读取
    if [[ $# -eq 0 ]]; then
        input="$(cat)"
    else
        input="$1" # 否则使用第一个参数作为输入
    fi

    local encoded="" # 声明局部变量存储编码后的结果
    local i c hex    # 声明循环变量和临时变量

    # 遍历输入字符串的每个字符
    for ((i = 0; i < ${#input}; i++)); do
        c="${input:$i:1}" # 获取当前字符

        # 检查字符是否为不需要编码的安全字符
        case $c in
        [a-zA-Z0-9.~_-])
            # 如果是安全字符，则直接追加到结果中
            encoded+="$c"
            ;;
        *)
            # 如果不是安全字符，则进行编码
            # printf -v hex 将字符的 ASCII 码转换为两位十六进制数
            printf -v hex "%02X" "'$c"
            # 将 % 和十六进制数追加到结果中
            encoded+="%$hex"
            ;;
        esac
    done

    # 输出编码后的字符串
    echo "$encoded"
}

function format_uri_host() {
    local host="$1"
    if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
        printf '[%s]' "${host}"
    else
        printf '%s' "${host}"
    fi
}

function is_valid_ipv4_literal() {
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

function is_valid_ipv6_literal() {
    local value="$1"
    local ipv4_tail normalized suffix part
    local has_compression=0
    local group_count=0
    local -a groups=()

    [[ "${value}" == *:* ]] || return 1

    # IPv4-mapped IPv6 addresses use the final IPv4 literal as two hextets.
    if [[ "${value}" == *.* ]]; then
        ipv4_tail="${value##*:}"
        is_valid_ipv4_literal "${ipv4_tail}" || return 1
        value="${value%:*}:0:0"
    fi

    [[ "${value}" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    [[ "${value}" != *:::* ]] || return 1

    if [[ "${value}" == *::* ]]; then
        has_compression=1
        suffix="${value#*::}"
        [[ "${suffix}" != *::* ]] || return 1
        normalized="${value/::/:__compressed__:}"
    else
        [[ "${value}" != :* && "${value}" != *: ]] || return 1
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

function is_valid_ip_literal() {
    is_valid_ipv4_literal "$1" || is_valid_ipv6_literal "$1"
}

function resolve_public_host() {
    local candidate=''

    case "${PUBLIC_HOST_LOOKUP_STATE}" in
    resolved) return 0 ;;
    failed) return 1 ;;
    esac

    # Mark the attempt before making network calls so every later node reuses
    # this result, including a failed lookup.
    PUBLIC_HOST_LOOKUP_STATE='failed'
    PUBLIC_HOST_CACHE=''

    if candidate="$(curl -fsS4 --max-time 10 https://api.ipify.org 2>/dev/null)" &&
        is_valid_ip_literal "${candidate}"; then
        PUBLIC_HOST_CACHE="${candidate}"
        PUBLIC_HOST_LOOKUP_STATE='resolved'
        return 0
    fi

    if candidate="$(curl -fsS6 --max-time 10 https://api64.ipify.org 2>/dev/null)" &&
        is_valid_ip_literal "${candidate}"; then
        PUBLIC_HOST_CACHE="${candidate}"
        PUBLIC_HOST_LOOKUP_STATE='resolved'
        return 0
    fi

    echo -e "${RED}[Error]${NC} Unable to determine a valid public IPv4 or IPv6 address." >&2
    return 1
}

# =============================================================================
# 函数名称: cache_json_data
# 功能描述: 将 Xray 和脚本的配置文件内容读取到全局变量中进行缓存，
#           避免重复读取文件，提高脚本执行效率。
# 参数: 无
# 返回值: 无 (直接修改全局变量 XRAY_CONFIG 和 SCRIPT_CONFIG)
# =============================================================================
function cache_json_data() {
    # 读取 Xray 配置文件的完整 JSON 内容到全局变量 XRAY_CONFIG
    XRAY_CONFIG="$(jq '.' "${XRAY_CONFIG_PATH}")"
    # 读取脚本配置文件的完整 JSON 内容到全局变量 SCRIPT_CONFIG
    SCRIPT_CONFIG="$(jq '.' "${SCRIPT_CONFIG_PATH}")"
}

# =============================================================================
# 函数名称: get_common_config
# 功能描述: 从缓存的 Xray 和脚本配置中提取指定 inbound 索引的通用客户端配置参数，
#           并存储到 CLIENT_CONFIG 关联数组中。
# 参数:
#   $1: Xray 配置中 inbound 数组的索引 (inbound_index)
# 返回值: 无 (直接修改全局变量 CLIENT_CONFIG)
# =============================================================================
function get_common_config() {
    local inbound_index=$1 # 获取 inbound 索引参数
    local remote_host_override="${2:-}"
    local inbound_port

    if [[ -n "${remote_host_override}" ]]; then
        CLIENT_CONFIG[remote_host]="${remote_host_override}"
    else
        resolve_public_host || return 1
        CLIENT_CONFIG[remote_host]="${PUBLIC_HOST_CACHE}"
    fi
    # 优先使用当前 inbound 的真实监听端口；无端口的内部监听回退到脚本主端口
    inbound_port="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].port? // empty')"
    if [[ -n "${inbound_port}" ]]; then
        CLIENT_CONFIG[port]="${inbound_port}"
    else
        CLIENT_CONFIG[port]="$(echo "${SCRIPT_CONFIG}" | jq -r ".xray.port")"
    fi
    # 从脚本配置中获取 Reality 公钥
    CLIENT_CONFIG[public_key]="$(echo "${SCRIPT_CONFIG}" | jq -r ".xray.publicKey")"
    # 从脚本配置中获取配置标签 (tag)
    CLIENT_CONFIG[tag]="$(echo "${SCRIPT_CONFIG}" | jq -r ".xray.tag")"

    # 从 Xray 配置中获取协议类型 (如 vless, trojan)
    CLIENT_CONFIG[protocol]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].protocol? | if . == null then empty else . end')"
    # 从 Xray 配置中获取客户端 UUID (VLESS) 或密码 (Trojan)
    CLIENT_CONFIG[uuid]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].settings.clients[0].id? | if . == null then empty else . end')"
    # 从 Xray 配置中获取客户端密码 (Trojan)
    CLIENT_CONFIG[password]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].settings.clients[0].password? | if . == null then empty else . end')"
    # 从 Xray 配置中获取 mKCP 的种子 (seed)
    CLIENT_CONFIG[seed]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '
        .inbounds[$i].streamSettings as $stream |
        ($stream.finalmask.udp[]? | select(.type == "mkcp-aes128gcm") | .settings.password) //
        $stream.kcpSettings.seed // empty
    ')"
    # 从 Xray 配置中获取网络传输类型 (如 tcp, kcp, xhttp)
    CLIENT_CONFIG[type]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].streamSettings.network? | if . == null then empty else . end')"
    # 从 Xray 配置中获取 Flow 控制参数 (如 xtls-rprx-vision)
    CLIENT_CONFIG[flow]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].settings.clients[0].flow? | if . == null then empty else . end')"
    # 从 Xray 配置中获取安全传输类型 (如 none, tls, reality)
    CLIENT_CONFIG[security]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].streamSettings.security? | if . == null then empty else . end')"
    # 从 Xray 配置中获取 XHTTP 的路径 (path) 和模式 (mode)
    CLIENT_CONFIG[path]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].streamSettings.xhttpSettings.path? | if . == null then empty else . end')"
    CLIENT_CONFIG[mode]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].streamSettings.xhttpSettings.mode? | if . == null then empty else . end')"
    # 从 Xray 配置中随机获取一个 Reality 的服务器名称 (serverNames)
    CLIENT_CONFIG[server_name]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" --argjson random "$(bash "${GENERATE_PATH}" '--random')" '.inbounds[$i].streamSettings.realitySettings.serverNames? | if . == null then empty else .[$random % length] end')"
    # 从 Xray 配置中随机获取一个 Reality 的 Short ID (shortIds)
    CLIENT_CONFIG[short_id]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" --argjson random "$(bash "${GENERATE_PATH}" '--random')" '.inbounds[$i].streamSettings.realitySettings.shortIds? | if . == null then empty else .[$random % length] end')"
    # 从脚本配置中获取 ML-DSA-65 Verify 公钥（后量子签名验证）
    CLIENT_CONFIG[mldsa65_verify]="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.mldsa65Verify // ""')"
    # 只有服务端当前入口实际启用了 VLESS enc，客户端链接才携带
    # encryption。带 fallbacks 的 VLESS 入口与 decryption 不兼容。
    local inbound_decryption
    inbound_decryption="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].settings.decryption? // ""')"
    if [[ -n "${inbound_decryption}" && "${inbound_decryption}" != 'none' ]]; then
        CLIENT_CONFIG[vless_enc_encryption]="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.vlessEncEncryption // ""')"
    else
        CLIENT_CONFIG[vless_enc_encryption]=''
    fi
    # 从 Xray 配置中获取 HY2 auth 密码
    CLIENT_CONFIG[hy2_auth]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].settings.clients[0].auth? | if . == null then empty else . end')"
    # 从脚本配置中获取 HY2 证书域名/IP
    CLIENT_CONFIG[hy2_cert_domain]="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertDomain // ""')"
    # 从 Xray 配置中获取 Shadowsocks 2022 密码与加密方式
    CLIENT_CONFIG[ss2022_password]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].settings.password? | if . == null then empty else . end')"
    CLIENT_CONFIG[ss2022_method]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].settings.method? | if . == null then empty else . end')"
}

# =============================================================================
# 函数名称: build_xhttp_obfs_extra
# 功能描述: 从 Xray 配置中提取 xPadding/session/seq 混淆参数，
#           构造一个 JSON 对象用于分享链接的 extra 字段。
# 参数:
#   $1: inbound 索引 (默认 1)
# 返回值: JSON 字符串 (echo 输出)，如无混淆参数则输出 {}
# =============================================================================
function build_xhttp_obfs_extra() {
    local inbound_index=${1:-1}
    echo "${XRAY_CONFIG}" | jq --argjson i "${inbound_index}" '
        .inbounds[$i].streamSettings.xhttpSettings // {} |
        {xPaddingObfsMode, xPaddingKey, xPaddingHeader, xPaddingPlacement,
         xPaddingMethod, uplinkHTTPMethod, sessionPlacement, sessionKey,
         seqPlacement, seqKey} |
        with_entries(select(.value != null))
    '
}

# =============================================================================
# 函数名称: setup_xhttp_obfs_extra
# 功能描述: 读取指定 inbound 的混淆参数，合并到 XHTTP_EXTRA 全局变量中，
#           并更新 XHTTP_EXTRA_ENCODED。
#           如果 XHTTP_EXTRA 已有内容 (如 downloadSettings)，则合并；
#           否则直接设置。
# 参数:
#   $1: inbound 索引 (默认 1)
# 返回值: 无 (直接修改全局变量 XHTTP_EXTRA 和 XHTTP_EXTRA_ENCODED)
# =============================================================================
function setup_xhttp_obfs_extra() {
    local inbound_index=${1:-1}
    local obfs_json="$(build_xhttp_obfs_extra ${inbound_index})"
    # 如果没有混淆参数则跳过
    if [[ "$(echo "${obfs_json}" | jq 'length')" -eq 0 ]]; then
        return 0
    fi
    if [[ -n "${XHTTP_EXTRA}" ]]; then
        # 合并到已有的 XHTTP_EXTRA (如包含 downloadSettings)
        XHTTP_EXTRA="$(echo "${XHTTP_EXTRA}" | jq --argjson obfs "${obfs_json}" '. + $obfs')"
    else
        XHTTP_EXTRA="${obfs_json}"
    fi
    XHTTP_EXTRA_ENCODED=$(echo "${XHTTP_EXTRA}" | jq -c '.' | urlencode)
}

function reset_share_state() {
    XHTTP_EXTRA=""
    XHTTP_EXTRA_ENCODED=""
    SHARE_LINK=""
    SHARE_LINK_COMPONENT_VLESS=""
    SHARE_LINK_COMPONENT_TROJAN=""
    SHARE_LINK_COMPONENT_MKCP=""
    SHARE_LINK_COMPONENT_TLS=""
    SHARE_LINK_COMPONENT_REALITY=""
    SHARE_LINK_COMPONENT_XHTTP=""
    SHARE_LINK_COMPONENT_FLOW=""
    SHARE_LINK_COMPONENT_HOST=""
    SHARE_LINK_COMPONENT_EXTRA=""
    SHARE_LINK_COMPONENT_VLESS_ENC=""
}

# =============================================================================
# 函数名称: get_tls_down_json
# 功能描述: 生成用于 TLS 下行模式的额外配置 JSON 字符串 (XHTTP_EXTRA)，
#           通常用于 SNI + CDN 的场景。
#           然后对生成的 JSON 进行 URL 编码 (XHTTP_EXTRA_ENCODED)。
# 参数: 无
# 返回值: 无 (直接修改全局变量 XHTTP_EXTRA 和 XHTTP_EXTRA_ENCODED)
# =============================================================================
function get_tls_down_json() {
    # 从脚本配置中获取 CDN 域名作为服务器名称
    local server_name="$(echo "${SCRIPT_CONFIG}" | jq -r ".nginx.cdn")"
    # 从脚本配置中获取 Xray 的路径
    local sni_path="$(echo "${SCRIPT_CONFIG}" | jq -r ".xray.path")"

    # 使用 Here Document 构造 XHTTP 下行设置的 JSON 字符串
    XHTTP_EXTRA=$(
        cat <<EOF
{
    "downloadSettings": {
        "address": "${server_name}",
        "port": 443,
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
            "serverName": "${server_name}",
            "allowInsecure": false,
            "alpn": [
                "h2"
            ],
            "fingerprint": "chrome"
        },
        "xhttpSettings": {
            "host": "${server_name}",
            "path": "${sni_path}",
            "mode": "auto"
        }
    }
}
EOF
    )

    # 将生成的 JSON 字符串通过管道传递给 jq 格式化，再传递给 urlencode 进行编码
    XHTTP_EXTRA_ENCODED=$(echo "${XHTTP_EXTRA}" | jq -r '.' | urlencode)
}

# =============================================================================
# 函数名称: get_reality_down_json
# 功能描述: 生成用于 Reality 下行模式的额外配置 JSON 字符串 (XHTTP_EXTRA)，
#           通常用于 SNI + Reality 的场景。
#           然后对生成的 JSON 进行 URL 编码 (XHTTP_EXTRA_ENCODED)。
# 参数: 无
# 返回值: 无 (直接修改全局变量 XHTTP_EXTRA 和 XHTTP_EXTRA_ENCODED)
# =============================================================================
function get_reality_down_json() {
    local inbound_index=1 # 指定要读取的 inbound 索引 (通常为 fallback inbound)

    # 从脚本配置中获取主域名作为服务器名称
    local server_name="$(echo "${SCRIPT_CONFIG}" | jq -r ".nginx.domain")"
    # 从脚本配置中获取 Reality 公钥
    local public_key="$(echo "${SCRIPT_CONFIG}" | jq -r ".xray.publicKey")"
    # 从脚本配置中获取 Xray 路径
    local sni_path="$(echo "${SCRIPT_CONFIG}" | jq -r ".xray.path")"
    # 从 Xray 配置中随机获取一个 Reality 的 Short ID
    local short_id="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" --argjson random "$(bash "${GENERATE_PATH}" '--random')" '.inbounds[$i].streamSettings.realitySettings.shortIds | .[$random % length?]')"

    # 使用 Here Document 构造 Reality 下行设置的 JSON 字符串
    XHTTP_EXTRA=$(
        cat <<EOF
{
    "downloadSettings": {
        "address": "${server_name}",
        "port": 443,
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
            "show": false,
            "serverName": "${server_name}",
            "fingerprint": "chrome",
            "publicKey": "${public_key}",
            "shortId": "${short_id}",
            "spiderX": "/"
        },
        "xhttpSettings": {
            "host": "",
            "path": "${sni_path}",
            "mode": "auto"
        }
    }
}
EOF
    )

    # 将生成的 JSON 字符串通过管道传递给 jq 格式化，再传递给 urlencode 进行编码
    XHTTP_EXTRA_ENCODED=$(echo "${XHTTP_EXTRA}" | jq -r '.' | urlencode)
}

# =============================================================================
# 函数名称: show_client_config
# 功能描述: 在终端打印格式化的客户端配置信息。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG)
# 返回值: 无 (直接打印到标准输出)
# =============================================================================
function show_client_config() {
    local tag="${CLIENT_CONFIG[tag]}"
    local protocol_tag="${CLIENT_CONFIG[protocol_tag]:-${tag}}"
    # 使用 Here Document 打印客户端配置的标题和各项参数
    echo "------------------ $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.client")(${tag}) ------------------"
    echo "address          : ${CLIENT_CONFIG[remote_host]}"
    echo "port             : ${CLIENT_CONFIG[port]}"
    echo "protocol         : ${CLIENT_CONFIG[protocol]}"
    if [[ "${protocol_tag,,}" == 'hy2' || "${protocol_tag,,}" == 'hysteria2' ]]; then
        echo "auth             : ${CLIENT_CONFIG[hy2_auth]}"
        echo "network          : ${CLIENT_CONFIG[type]}"
        echo "security         : ${CLIENT_CONFIG[security]}"
        [[ -n "${CLIENT_CONFIG[hy2_cert_domain]}" ]] && echo "SNI              : ${CLIENT_CONFIG[hy2_cert_domain]}"
    elif [[ "${protocol_tag,,}" == 'ss2022' ]]; then
        echo "method           : ${CLIENT_CONFIG[ss2022_method]}"
        echo "password (PSK)   : ${CLIENT_CONFIG[ss2022_password]}"
        echo "network          : ${CLIENT_CONFIG[type]}"
    else
        echo "uuid             : ${CLIENT_CONFIG[uuid]}"
        echo "password(trojan) : ${CLIENT_CONFIG[password]}"
        echo "seed(mKCP)       : ${CLIENT_CONFIG[seed]}"
        echo "flow             : ${CLIENT_CONFIG[flow]}"
        echo "network          : ${CLIENT_CONFIG[type]}"
        echo "security         : ${CLIENT_CONFIG[security]}"
        echo "ServerName       : ${CLIENT_CONFIG[server_name]}"
        echo "path             : ${CLIENT_CONFIG[path]}"
        echo "Fingerprint      : chrome"
        echo "PublicKey        : ${CLIENT_CONFIG[public_key]}"
        echo "ShortId          : ${CLIENT_CONFIG[short_id]}"
        echo "SpiderX          : /"
        echo "ML-DSA-65 Verify : ${CLIENT_CONFIG[mldsa65_verify]}"
    fi
}

# =============================================================================
# 函数名称: get_share_link_component
# 功能描述: 根据当前 CLIENT_CONFIG 中的参数，生成分享链接的各个组成部分。
#           这些组件可以被后续的特定链接生成函数组合使用。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG)
# 返回值: 无 (直接修改一系列 SHARE_LINK_COMPONENT_* 全局变量)
# =============================================================================
function get_share_link_component() {
    local uri_host encoded_trojan_password encoded_mkcp_seed
    uri_host="$(format_uri_host "${CLIENT_CONFIG[remote_host]}")"
    encoded_trojan_password="$(urlencode "${CLIENT_CONFIG[password]}")"
    encoded_mkcp_seed="$(urlencode "${CLIENT_CONFIG[seed]}")"
    # 生成 VLESS 协议基础链接部分 (协议://UUID@地址:端口?网络类型=...)
    SHARE_LINK_COMPONENT_VLESS="${CLIENT_CONFIG[protocol]}://${CLIENT_CONFIG[uuid]}@${uri_host}:${CLIENT_CONFIG[port]}?type=${CLIENT_CONFIG[type]}"
    # 生成 Trojan 协议基础链接部分 (协议://密码@地址:端口?网络类型=...)
    SHARE_LINK_COMPONENT_TROJAN="${CLIENT_CONFIG[protocol]}://${encoded_trojan_password}@${uri_host}:${CLIENT_CONFIG[port]}?type=${CLIENT_CONFIG[type]}"
    # 生成 mKCP 网络传输参数部分 (&seed=...&headerType=none)
    SHARE_LINK_COMPONENT_MKCP="&seed=${encoded_mkcp_seed}&headerType=none"
    # 生成 TLS 安全传输参数部分 (&security=tls&sni=...&alpn=h2&fp=chrome)
    SHARE_LINK_COMPONENT_TLS="&security=${CLIENT_CONFIG[security]}&sni=${CLIENT_CONFIG[server_name]}&alpn=h2&fp=chrome"
    # 生成 Reality 安全传输参数部分 (&security=reality&sni=...&pbk=...&sid=...&spx=%2F&fp=chrome)
    SHARE_LINK_COMPONENT_REALITY="&security=${CLIENT_CONFIG[security]}&sni=${CLIENT_CONFIG[server_name]}&pbk=${CLIENT_CONFIG[public_key]}&sid=${CLIENT_CONFIG[short_id]}&spx=%2F&fp=chrome"
    # 如果已配置 ML-DSA-65 Verify，添加到 REALITY 参数中
    if [[ -n "${CLIENT_CONFIG[mldsa65_verify]}" ]]; then
        SHARE_LINK_COMPONENT_REALITY="${SHARE_LINK_COMPONENT_REALITY}&mldsa65Verify=${CLIENT_CONFIG[mldsa65_verify]}"
    fi
    # 生成 XHTTP 网络传输路径参数部分 (&path=...&mode=...), 注意去除路径开头的 '/'
    SHARE_LINK_COMPONENT_XHTTP="&path=%2F${CLIENT_CONFIG[path]#/}"
    if [[ -n "${CLIENT_CONFIG[mode]}" ]]; then
        SHARE_LINK_COMPONENT_XHTTP="${SHARE_LINK_COMPONENT_XHTTP}&mode=${CLIENT_CONFIG[mode]}"
    fi
    # 生成 Flow 控制参数部分 (&flow=...)
    SHARE_LINK_COMPONENT_FLOW="&flow=${CLIENT_CONFIG[flow]}"
    # 生成 XHTTP Host 参数部分 (&host=...), 仅在设置了 host 时输出
    if [[ -n "${CLIENT_CONFIG[host]}" ]]; then
        SHARE_LINK_COMPONENT_HOST="&host=$(echo "${CLIENT_CONFIG[host]}" | urlencode)"
    else
        SHARE_LINK_COMPONENT_HOST=""
    fi
    # 生成额外参数部分 (&extra=...), 仅在有内容时生成
    if [[ -n "${XHTTP_EXTRA_ENCODED}" ]]; then
        SHARE_LINK_COMPONENT_EXTRA="&extra=${XHTTP_EXTRA_ENCODED}"
    else
        SHARE_LINK_COMPONENT_EXTRA=""
    fi
    # 若启用了 VLESS enc，生成 encryption 参数部分
    local vless_enc_encryption="${CLIENT_CONFIG[vless_enc_encryption]:-}"
    if [[ -n "${vless_enc_encryption}" ]]; then
        SHARE_LINK_COMPONENT_VLESS_ENC="&encryption=$(echo "${vless_enc_encryption}" | urlencode)"
    else
        SHARE_LINK_COMPONENT_VLESS_ENC=""
    fi
}

# =============================================================================
# 函数名称: get_mkcp_share_link
# 功能描述: 为 mKCP 网络传输类型生成完整的分享链接。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_mkcp_share_link() {
    # 获取分享链接的各个组件
    get_share_link_component
    # 将 VLESS 基础部分、mKCP 参数部分和可选的 VLESS enc 拼接成完整链接，并显式指定 security=none 确保客户端解析兼容性
    SHARE_LINK="${SHARE_LINK_COMPONENT_VLESS}&security=none${SHARE_LINK_COMPONENT_MKCP}${SHARE_LINK_COMPONENT_VLESS_ENC}"
}

# =============================================================================
# 函数名称: get_vision_share_link
# 功能描述: 为 Vision (XTLS) + Reality 网络传输类型生成完整的分享链接。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_vision_share_link() {
    # 获取分享链接的各个组件
    get_share_link_component
    # 将 VLESS 基础部分、Reality 安全参数、Flow 控制参数和可选的 VLESS enc 拼接成完整链接
    SHARE_LINK="${SHARE_LINK_COMPONENT_VLESS}${SHARE_LINK_COMPONENT_REALITY}${SHARE_LINK_COMPONENT_FLOW}${SHARE_LINK_COMPONENT_VLESS_ENC}"
}

# =============================================================================
# 函数名称: get_xhttp_share_link
# 功能描述: 为 XHTTP + Reality 网络传输类型生成完整的分享链接。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG 和 XHTTP_EXTRA)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_xhttp_share_link() {
    # 获取分享链接的各个组件
    get_share_link_component
    # 将 VLESS 基础部分、Reality 安全参数、XHTTP 路径参数、可选的 VLESS enc 和额外混淆参数拼接成完整链接
    SHARE_LINK="${SHARE_LINK_COMPONENT_VLESS}${SHARE_LINK_COMPONENT_REALITY}${SHARE_LINK_COMPONENT_XHTTP}${SHARE_LINK_COMPONENT_HOST}${SHARE_LINK_COMPONENT_VLESS_ENC}${SHARE_LINK_COMPONENT_EXTRA}"
}

# =============================================================================
# 函数名称: get_cdn_share_link
# 功能描述: 为 CDN 场景的 VLESS + XHTTP + TLS 生成完整的分享链接。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG 和 SCRIPT_CONFIG)
# 返回值: 无 (直接修改全局变量 CLIENT_CONFIG 和 SHARE_LINK)
# =============================================================================
function get_cdn_share_link() {
    CLIENT_CONFIG[security]="tls"
    CLIENT_CONFIG[server_name]="$(echo "${SCRIPT_CONFIG}" | jq -r ".nginx.cdn")"
    CLIENT_CONFIG[remote_host]="$(echo "${SCRIPT_CONFIG}" | jq -r ".nginx.cdn")"
    CLIENT_CONFIG[host]="$(echo "${SCRIPT_CONFIG}" | jq -r ".nginx.cdn")"

    setup_xhttp_obfs_extra 1
    get_share_link_component
    SHARE_LINK="${SHARE_LINK_COMPONENT_VLESS}${SHARE_LINK_COMPONENT_TLS}${SHARE_LINK_COMPONENT_XHTTP}${SHARE_LINK_COMPONENT_HOST}${SHARE_LINK_COMPONENT_VLESS_ENC}${SHARE_LINK_COMPONENT_EXTRA}"
}

# =============================================================================
# 函数名称: get_trojan_share_link
# 功能描述: 为 Trojan + Reality 网络传输类型生成完整的分享链接。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG 和 XHTTP_EXTRA)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_trojan_share_link() {
    local inbound_index="${1:-1}"
    # 设置混淆额外参数
    setup_xhttp_obfs_extra "${inbound_index}"
    # 获取分享链接的各个组件
    get_share_link_component
    # 将 Trojan 基础部分、Reality 安全参数、XHTTP 路径参数和额外混淆参数拼接成完整链接
    SHARE_LINK="${SHARE_LINK_COMPONENT_TROJAN}${SHARE_LINK_COMPONENT_REALITY}${SHARE_LINK_COMPONENT_XHTTP}${SHARE_LINK_COMPONENT_HOST}${SHARE_LINK_COMPONENT_EXTRA}"
}

# =============================================================================
# 函数名称: get_hy2_share_link
# 功能描述: 为 Hysteria2 协议生成标准分享链接。
#           格式: hysteria2://auth@host:port/?insecure=0&sni=xxx#tag
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_hy2_share_link() {
    local auth="${CLIENT_CONFIG[hy2_auth]}"
    local host="${CLIENT_CONFIG[remote_host]}"
    local port="${CLIENT_CONFIG[port]}"
    local sni="${CLIENT_CONFIG[hy2_cert_domain]}"

    local encoded_auth uri_host
    encoded_auth="$(urlencode "${auth}")"
    uri_host="$(format_uri_host "${host}")"

    # 标准 hysteria2 分享链接格式
    SHARE_LINK="hysteria2://${encoded_auth}@${uri_host}:${port}/?insecure=0"
    if [[ -n "${sni}" ]]; then
        SHARE_LINK="${SHARE_LINK}&sni=$(urlencode "${sni}")"
    fi
}

# =============================================================================
# 函数名称: get_ss2022_share_link
# 功能描述: 为 Shadowsocks-2022 生成标准 SIP002 分享链接。
# 参数: 无
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_ss2022_share_link() {
    local method="${CLIENT_CONFIG[ss2022_method]}"
    local password="${CLIENT_CONFIG[ss2022_password]}"
    local host="${CLIENT_CONFIG[remote_host]}"
    local port="${CLIENT_CONFIG[port]}"

    # 对 method:password 进行 URL-safe Base64 编码并移除换行与 Padding (=)
    local userinfo
    userinfo="$(echo -n "${method}:${password}" | openssl base64 -e | tr -d '\n' | tr '+/' '-_' | tr -d '=')"

    SHARE_LINK="ss://${userinfo}@$(format_uri_host "${host}"):${port}"
}

# =============================================================================
# 函数名称: get_fallback_xhttp_share_link
# 功能描述: 为 fallback inbound (通常是 index 1) 生成 XHTTP + Reality 分享链接。
#           这个函数会重新从 Xray 配置中读取 fallback inbound 的安全、服务器名和 Short ID。
# 参数: 无
# 返回值: 无 (直接修改全局变量 CLIENT_CONFIG 和 SHARE_LINK)
# =============================================================================
function get_fallback_xhttp_share_link() {
    local inbound_index="${1:-1}"       # 指定 fallback public inbound 的索引
    local xhttp_inbound_index="${2:-2}" # 指定 fallback XHTTP inbound 的索引

    # 从 Xray 配置中重新读取 fallback inbound 的安全类型
    CLIENT_CONFIG[security]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" '.inbounds[$i].streamSettings.security? | if . == null then empty else . end')"
    # 从 Xray 配置中重新随机读取 fallback inbound 的服务器名称
    CLIENT_CONFIG[server_name]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" --argjson random "$(bash "${GENERATE_PATH}" '--random')" '.inbounds[$i].streamSettings.realitySettings.serverNames | .[$random % length?]')"
    # 从 Xray 配置中重新随机读取 fallback inbound 的 Short ID
    CLIENT_CONFIG[short_id]="$(echo "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" --argjson random "$(bash "${GENERATE_PATH}" '--random')" '.inbounds[$i].streamSettings.realitySettings.shortIds | .[$random % length?]')"

    # 设置 XHTTP 混淆额外参数 (XHTTP inbound 是 index 2)
    setup_xhttp_obfs_extra "${xhttp_inbound_index}"
    # 调用通用的 XHTTP 链接生成函数
    get_xhttp_share_link
}

function build_multi_current_share_link() {
    local node_tag="$1"
    local inbound_index="$2"

    case "${node_tag,,}" in
    mkcp)
        get_mkcp_share_link
        ;;
    xhttp)
        setup_xhttp_obfs_extra "${inbound_index}"
        get_xhttp_share_link
        ;;
    trojan)
        get_trojan_share_link "${inbound_index}"
        ;;
    hy2)
        get_hy2_share_link
        ;;
    ss2022)
        get_ss2022_share_link
        ;;
    *)
        get_vision_share_link
        ;;
    esac
}

function multi_inbound_span() {
    case "${1,,}" in
    vision | fallback) echo 2 ;;
    *) echo 1 ;;
    esac
}

function apply_multi_node_overrides() {
    local node="$1"
    local node_tag_lower="$2"
    local node_name="$3"
    local node_port="$4"

    [[ -n "${node_port}" ]] && CLIENT_CONFIG[port]="${node_port}"
    CLIENT_CONFIG[tag]="${node_name}"
    CLIENT_CONFIG[protocol_tag]="${node_tag_lower}"

    case "${node_tag_lower}" in
    hy2)
        CLIENT_CONFIG[hy2_auth]="$(echo "${node}" | jq -r '.hy2auth // ""')"
        ;;
    ss2022)
        CLIENT_CONFIG[ss2022_password]="$(echo "${node}" | jq -r '.ss2022Key // ""')"
        ;;
    esac
}

function show_multi_config() {
    local nodes="$(echo "${SCRIPT_CONFIG}" | jq -c '.xray.nodes // []')"
    local node_count="$(echo "${nodes}" | jq 'length')"
    local inbound_index=1
    local i

    if [[ "${node_count}" -eq 0 ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r '.handler.multi.no_nodes')"
        return 1
    fi

    for ((i = 0; i < node_count; i++)); do
        local node="$(echo "${nodes}" | jq -c --argjson i "${i}" '.[$i]')"
        local node_tag="$(echo "${node}" | jq -r '.tag')"
        local node_tag_lower="${node_tag,,}"
        local node_name="$(echo "${node}" | jq -r --arg fallback "${node_tag}-$((i + 1))" '.name // $fallback')"
        local node_port="$(echo "${node}" | jq -r '.port // empty')"
        local span
        span="$(multi_inbound_span "${node_tag_lower}")"

        reset_share_state
        get_common_config "${inbound_index}" || return 1
        apply_multi_node_overrides "${node}" "${node_tag_lower}" "${node_name}" "${node_port}"

        if [[ "${node_tag_lower}" == "fallback" ]]; then
            get_vision_share_link
            show_config

            reset_share_state
            get_common_config "$((inbound_index + 1))" || return 1
            apply_multi_node_overrides "${node}" "${node_tag_lower}" "${node_name}-xhttp" "${node_port}"
            get_fallback_xhttp_share_link "${inbound_index}" "$((inbound_index + 1))"
            show_config

            inbound_index=$((inbound_index + span))
            continue
        fi

        build_multi_current_share_link "${node_tag_lower}" "${inbound_index}"
        show_config
        inbound_index=$((inbound_index + span))
    done
}

# =============================================================================
# 函数名称: get_sni_tls_share_link
# 功能描述: 为 SNI + TLS 网络传输类型生成完整的分享链接。
#           通常用于通过 CDN 域名访问的场景。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG 和 SCRIPT_CONFIG)
# 返回值: 无 (直接修改全局变量 CLIENT_CONFIG 和 SHARE_LINK)
# =============================================================================
function get_sni_tls_share_link() {
    # 设置安全类型为 tls
    CLIENT_CONFIG[security]="tls"
    # 从脚本配置中读取 CDN 域名作为服务器名称
    CLIENT_CONFIG[server_name]="$(echo "${SCRIPT_CONFIG}" | jq -r ".nginx.cdn")"
    # 将远程主机地址也设置为 CDN 域名
    CLIENT_CONFIG[remote_host]="$(echo "${SCRIPT_CONFIG}" | jq -r ".nginx.cdn")"

    # 设置 XHTTP 混淆额外参数 (XHTTP inbound 是 index 2)
    setup_xhttp_obfs_extra 2
    # 获取分享链接的各个组件
    get_share_link_component
    # 将 VLESS 基础部分、TLS 安全参数、XHTTP 路径参数、可选的 VLESS enc 和额外混淆参数拼接成完整链接
    SHARE_LINK="${SHARE_LINK_COMPONENT_VLESS}${SHARE_LINK_COMPONENT_TLS}${SHARE_LINK_COMPONENT_XHTTP}${SHARE_LINK_COMPONENT_VLESS_ENC}${SHARE_LINK_COMPONENT_EXTRA}"
}

# =============================================================================
# 函数名称: get_sni_tls_down_share_link
# 功能描述: 为 SNI + TLS + 下行模式 (带 extra 参数) 生成完整的分享链接。
# 参数: 无 (直接使用全局变量 XHTTP_EXTRA)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_sni_tls_down_share_link() {
    # 首先获取 fallback 的 XHTTP 链接 (基础部分，已包含 obfs extra)
    get_fallback_xhttp_share_link
}

# =============================================================================
# 函数名称: get_sni_reality_down_share_link
# 功能描述: 为 SNI + Reality + 下行模式 (带 extra 参数) 生成完整的分享链接。
# 参数: 无 (直接使用全局变量 XHTTP_EXTRA)
# 返回值: 无 (直接修改全局变量 SHARE_LINK)
# =============================================================================
function get_sni_reality_down_share_link() {
    # 首先获取 SNI + TLS 的链接 (基础部分，已包含 obfs extra)
    get_sni_tls_share_link
}

# =============================================================================
# 函数名称: show_config
# 功能描述: 打印完整的客户端配置信息、额外配置 (如果有的话)、
#           最终的分享链接以及对应的二维码。
# 参数: 无 (直接使用全局变量 CLIENT_CONFIG, XHTTP_EXTRA, SHARE_LINK, I18N_DATA)
# 返回值: 无 (直接打印到标准输出)
# =============================================================================
function show_config() {
    # 在分享链接末尾追加标签作为锚点 (例如 #my_tag)
    SHARE_LINK="${SHARE_LINK}#$(urlencode "${CLIENT_CONFIG[tag]}")"

    # 显示客户端配置信息
    show_client_config

    # 如果存在额外配置 (XHTTP_EXTRA)，则显示它
    if [[ "${XHTTP_EXTRA}" ]]; then
        echo -e "------------------ $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.extra") ------------------"
        # 使用 jq 格式化输出额外配置的 JSON
        echo "${XHTTP_EXTRA}" | jq -r '.'
    fi

    # 显示分享链接
    echo -e "------------------ $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.link") ------------------"
    echo -e "${SHARE_LINK}"

    # 显示分享链接的二维码 (需要 qrencode 命令)
    echo -e "------------------ $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.qr") ------------------"
    echo -e "${SHARE_LINK}" | qrencode -t ansiutf8

    # 打印分隔线结束
    echo -e "------------------------------------------------------"
}

# =============================================================================
# 函数名称: show_fallback_config
# 功能描述: 为 "fallback" 配置模式生成并显示多组客户端配置和链接。
#           包括 fallback 的 Vision 链接和 XHTTP 链接。
# 参数: 无
# 返回值: 无 (调用其他函数进行显示)
# =============================================================================
function show_fallback_config() {
    # 设置第一个配置的标签为 'fallbak_vision_reality'
    CLIENT_CONFIG[tag]='fallbak_vision_reality'
    # 生成 Vision 分享链接
    get_vision_share_link
    # 显示第一个配置
    show_config

    # 重新获取第二个 inbound (index 2) 的通用配置
    get_common_config 2 || return 1
    # 设置第二个配置的标签为 'fallbak_xhttp_reality'
    CLIENT_CONFIG[tag]='fallbak_xhttp_reality'
    # 生成 fallback 的 XHTTP 分享链接
    get_fallback_xhttp_share_link
}

# =============================================================================
# 函数名称: show_sni_config
# 功能描述: 为 "sni" 配置模式生成并显示多组客户端配置和链接。
#           包括 SNI Vision, SNI XHTTP, SNI TLS Down, SNI XHTTP CDN, SNI Reality Down。
# 参数: 无
# 返回值: 无 (调用其他函数进行显示)
# =============================================================================
function show_sni_config() {
    local origin_host="${CLIENT_CONFIG[remote_host]}"

    [[ -n "${origin_host}" ]] || return 1
    # 设置第一个配置的标签为 'sni_vision_reality'
    CLIENT_CONFIG[tag]='sni_vision_reality'
    # 生成 Vision 分享链接
    get_vision_share_link
    # 显示第一个配置
    show_config

    # 重新获取第二个 inbound (index 2) 的通用配置
    get_common_config 2 "${origin_host}" || return 1
    # 设置第二个配置的标签为 'sni_xhttp_reality'
    CLIENT_CONFIG[tag]='sni_xhttp_reality'
    # 生成 fallback 的 XHTTP 分享链接
    get_fallback_xhttp_share_link
    # 显示第二个配置
    show_config

    # 重新获取第二个 inbound (index 2) 的通用配置
    get_common_config 2 "${origin_host}" || return 1
    # 设置第三个配置的标签为 'sni_tls_down'
    CLIENT_CONFIG[tag]='sni_tls_down'
    # 生成 TLS 下行的额外配置
    get_tls_down_json
    # 生成 SNI TLS Down 分享链接
    get_sni_tls_down_share_link
    # 显示第三个配置
    show_config

    # 重新获取第二个 inbound (index 2) 的通用配置
    get_common_config 2 "${origin_host}" || return 1
    # 设置第四个配置的标签为 'sni_xhttp_cdn'
    CLIENT_CONFIG[tag]='sni_xhttp_cdn'
    # 清空额外配置
    XHTTP_EXTRA=""
    XHTTP_EXTRA_ENCODED=""
    # 生成 SNI TLS 分享链接
    get_sni_tls_share_link
    # 显示第四个配置
    show_config

    # 重新获取第二个 inbound (index 2) 的通用配置
    get_common_config 2 "${origin_host}" || return 1
    # 设置第五个配置的标签为 'sni_reality_down'
    CLIENT_CONFIG[tag]='sni_reality_down'
    # 生成 Reality 下行的额外配置
    get_reality_down_json
    # 生成 SNI Reality Down 分享链接
    get_sni_reality_down_share_link
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 缓存配置文件数据。
#           3. 获取第一个 inbound (index 1) 的通用配置。
#           4. 根据脚本配置中的 tag 值，选择相应的链接生成函数。
#           5. 调用 show_config 显示最终结果。
# 参数:
#   $@: 所有命令行参数 (此脚本中未使用)
# 返回值: 无 (协调调用其他函数完成整个流程)
# =============================================================================
function main() {
    local config_tag common_host_override=''
    local share_status=0

    PUBLIC_HOST_LOOKUP_STATE='unattempted'
    PUBLIC_HOST_CACHE=''

    # 加载国际化数据
    load_i18n

    # 缓存 Xray 和脚本配置数据
    cache_json_data

    config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag | ascii_downcase')"
    case "${config_tag}" in
    cdn)
        common_host_override="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn // empty')"
        ;;
    sni)
        common_host_override="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.domain // empty')"
        ;;
    esac
    if [[ "${config_tag}" =~ ^(cdn|sni)$ && -z "${common_host_override}" ]]; then
        echo -e "${RED}[Error]${NC} Missing configured host for ${config_tag} share links." >&2
        return 1
    fi

    # 获取第一个 inbound (index 1) 的通用配置
    get_common_config 1 "${common_host_override}" || return 1

    case "${config_tag}" in
    mkcp) get_mkcp_share_link ;;      # mKCP 模式
    xhttp) setup_xhttp_obfs_extra 1; get_xhttp_share_link ;;    # XHTTP 模式
    trojan) get_trojan_share_link ;;  # Trojan 模式
    fallback) show_fallback_config || return 1 ;; # Fallback 模式
    sni) show_sni_config || return 1 ;;           # SNI 模式
    cdn) get_cdn_share_link ;;        # CDN 模式
    hy2) get_hy2_share_link ;;        # Hysteria2 模式
    ss2022) get_ss2022_share_link ;;  # Shadowsocks-2022 模式
    multi) show_multi_config >&2 || return 1; return 0 ;;
    *) get_vision_share_link ;;       # 默认为 Vision 模式
    esac
    share_status=$?
    ((share_status == 0)) || return "${share_status}"

    # 显示最终的配置和链接信息 (重定向到标准错误输出 >&2，虽然不太常见)
    show_config >&2
}

# --- 脚本执行入口 ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
