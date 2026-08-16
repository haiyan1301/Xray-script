#!/usr/bin/env bash
#
# Copyright (C) 2025 zxcvos
#
# Xray-script:
#   https://github.com/zxcvos/Xray-script
# =============================================================================
# 注释: 通过 Qwen3-Coder 生成。
# 脚本名称: handler.sh
# 功能描述: X-UI 项目的处理器脚本。
#           负责执行具体的操作，如安装/卸载 Xray/Nginx、配置文件生成、
#           启动/停止服务、管理 Docker 容器、处理路由规则等。
#           由 main.sh 调用，根据传入参数执行相应功能。
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash, jq, curl, systemctl, crontab, sed, awk, grep, cut, tr
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 读取和写入脚本配置 (如版本、域名、密钥等)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
#   - ${CONFIG_DIR}/xray/*.json: 读取 Xray 配置模板
#   - ${CONFIG_DIR}/nginx/conf/*: 读取 Nginx 配置模板
#   - /usr/local/etc/xray/config.json: 读取和写入 Xray 最终配置文件
#   - /usr/local/nginx/conf/*: 读取和写入 Nginx 最终配置文件
#   - ${HOME}/.acme.sh/: 读取和写入 SSL 证书相关文件
# =============================================================================


# set -Eeuxo pipefail

# --- 环境与常量设置 ---
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly CUR_FILE="$(basename "${BASH_SOURCE[0]}" | sed 's/\..*//')"
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)"

# 引入公共库
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/protocols.sh"

# 定义项目内相关目录和脚本的路径
readonly SCRIPT_CONFIG_DIR="${HOME}/.xray-script"
readonly I18N_DIR="${PROJECT_ROOT}/i18n"
readonly CONFIG_DIR="${PROJECT_ROOT}/config"
readonly SERVICE_DIR="${PROJECT_ROOT}/service"
readonly TOOL_DIR="${PROJECT_ROOT}/tool"
readonly SCRIPT_XRAY_DIR="${CONFIG_DIR}/xray"
readonly NGINX_CONFIG_DIR="${NGINX_CONFIG_DIR_OVERRIDE:-/usr/local/nginx/conf}"
readonly NGINX_SERVICE_PATH="${NGINX_SERVICE_PATH_OVERRIDE:-/etc/systemd/system/nginx.service}"
readonly GENERATE_PATH="${CUR_DIR}/generate.sh"
readonly CHECK_PATH="${CUR_DIR}/check.sh"
readonly SHARE_PATH="${CUR_DIR}/share.sh"
readonly READ_PATH="${CUR_DIR}/read.sh"
readonly MENU_PATH="${CUR_DIR}/menu.sh"
readonly NGINX_PATH="${SERVICE_DIR}/nginx.sh"
readonly SSL_PATH="${SERVICE_DIR}/ssl.sh"
readonly DOCKER_PATH="${SERVICE_DIR}/docker.sh"
readonly TRAFFIC_PATH="${TOOL_DIR}/traffic.sh"
readonly GEODATA_PATH="${TOOL_DIR}/geodata.sh"
readonly LAN_PATH="${CUR_DIR}/lan.sh"
readonly XRAY_CONFIG_PATH="${XRAY_CONFIG_PATH_OVERRIDE:-/usr/local/etc/xray/config.json}"
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_PATH_OVERRIDE:-${SCRIPT_CONFIG_DIR}/config.json}"
readonly ACME_PATH="${HOME}/.acme.sh/acme.sh"
readonly CDN_XRAY_CERT_ROOT="${CDN_XRAY_CERT_DIR_OVERRIDE:-/usr/local/etc/xray/certs/cdn}"
# Keep the old variable as a root-path compatibility alias for callers that
# source handler.sh. New code must derive an identifier/source-specific target.
readonly CDN_XRAY_CERT_DIR="${CDN_XRAY_CERT_ROOT}"

# --- 全局变量声明 ---
declare SCRIPT_CONFIG="$(jq '.' "${SCRIPT_CONFIG_PATH}")"
declare XRAY_CONFIG=""
declare LANG_PARAM=''
declare I18N_DATA=''
declare -A CONFIG_DATA
declare NGINX_CONFIG_CHANGED=0

source "${LAN_PATH}"

function reset_config_data() {
    unset CONFIG_DATA
    declare -gA CONFIG_DATA
}

function get_cdn_backend() {
    normalize_cdn_backend "$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnBackend // ""')"
}

function validate_cdn_split_domains() {
    local uplink downlink
    uplink="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn // ""')"
    downlink="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')"
    [[ -n "${downlink}" ]] || return 0
    if ! exec_check '--domain-format' "${uplink}" >/dev/null 2>&1 ||
        ! exec_check '--domain-format' "${downlink}" >/dev/null 2>&1; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_split.domain_invalid")" >&2
        return 1
    fi
    if [[ "${uplink,,}" == "${downlink,,}" ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_split.domain_duplicate")" >&2
        return 1
    fi
}

function certificate_path_component() {
    local value="${1,,}"

    [[ -n "${value}" && "${value}" != '.' && "${value}" != '..' ]] || return 1
    value="$(printf '%s' "${value}" | sed 's/[^a-z0-9._-]/_/g')"
    [[ -n "${value}" && "${value}" != '.' && "${value}" != '..' ]] || return 1
    printf '%s' "${value}"
}

function get_cdn_direct_cert_dir() {
    local domain="$1"
    local source="$2"
    local path_component source_dir

    path_component="$(certificate_path_component "${domain}")" || return 1
    case "${source}" in
    1) source_dir='acme' ;;
    2) source_dir='custom' ;;
    *) return 1 ;;
    esac
    printf '%s/%s/%s' "${CDN_XRAY_CERT_ROOT}" "${path_component}" "${source_dir}"
}

function get_hy2_cert_dir() {
    local identifier="$1"
    local source="$2"
    local path_component source_dir

    path_component="$(certificate_path_component "${identifier}")" || return 1
    case "${source}" in
    1|2) source_dir='acme' ;;
    3) source_dir='custom' ;;
    *) return 1 ;;
    esac
    printf '%s/hy2/%s/%s' \
        "${XRAY_CERT_DIR_OVERRIDE:-/usr/local/etc/xray/certs}" \
        "${path_component}" "${source_dir}"
}

function current_protocol_uses_nginx() {
    local config_tag
    config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')"
    protocol_uses_nginx "${config_tag}" "$(get_cdn_backend)"
}

function is_cdn_direct_mode() {
    local config_tag
    config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')"
    [[ "${config_tag,,}" == 'cdn' && "$(get_cdn_backend)" == 'xray' ]]
}

function xray_runtime_owns_tcp_443() {
    [[ -r "${XRAY_CONFIG_PATH}" ]] || return 1
    jq -e '
        any(.inbounds[]?;
            (.port? == 443) and
            ((.streamSettings.network? // "") | IN("hysteria", "kcp") | not)
        )
    ' "${XRAY_CONFIG_PATH}" >/dev/null 2>&1
}

function get_xray_runtime_cert_dir() {
    local pair cert_file key_file

    [[ -r "${XRAY_CONFIG_PATH}" ]] || return 1
    pair="$(jq -r '
        [
            .inbounds[]?.streamSettings.tlsSettings.certificates[]?
            | select(
                (.certificateFile? | type) == "string" and
                (.keyFile? | type) == "string"
            )
        ][0] // empty
        | [.certificateFile, .keyFile]
        | @tsv
    ' "${XRAY_CONFIG_PATH}" 2>/dev/null)" || return 1
    IFS=$'\t' read -r cert_file key_file <<<"${pair}"
    [[ -n "${cert_file}" && -n "${key_file}" &&
        "$(basename "${cert_file}")" == 'fullchain.pem' &&
        "$(basename "${key_file}")" == 'privkey.pem' &&
        "$(dirname "${cert_file}")" == "$(dirname "${key_file}")" ]] ||
        return 1
    dirname "${cert_file}"
}

function handler_recover_runtime_services() {
    local restore_status=0
    local runtime_reload_safe=1
    local xray_ready=0

    if current_protocol_uses_nginx; then
        # The process may still have the failed direct config loaded in memory;
        # stop it before Nginx attempts to reclaim TCP/443.
        if systemctl -q is-active xray && ! systemctl -q stop xray; then
            restore_status=1
        fi
        # Container failures must be reported, but cannot prevent the core
        # Nginx/Xray recovery attempts that follow.
        handler_restore_configured_web_backend || restore_status=1
        handler_nginx_start || restore_status=1
    else
        # Restore the service ownership described by the script snapshot, even
        # for UDP/443 or non-443 protocols that do not conflict with Nginx.
        # This prevents a failed CDN/SNI transition from leaving Nginx enabled.
        # Attempt the listener handoff first; cleanup failures are accumulated
        # so the restored Xray runtime is still reloaded below.
        handler_nginx_stop || restore_status=1
        handler_cloudreve_v3 'stop' || restore_status=1
        handler_cloudreve_v4 'stop' || restore_status=1
    fi

    # Reload the restored file even when Xray was still active. handler_start
    # alone would otherwise leave the failed replacement loaded in memory.
    if systemctl -q is-active xray && ! systemctl -q stop xray; then
        restore_status=1
        runtime_reload_safe=0
    fi
    # A transient first stop failure can make the earlier Nginx start collide
    # with Xray's failed direct listener. Once Xray is safely stopped, retry
    # the restored Nginx service before loading the socket-based Xray config.
    if current_protocol_uses_nginx &&
        [[ "${runtime_reload_safe}" -eq 1 ]] &&
        ! systemctl -q is-active nginx; then
        handler_nginx_start || restore_status=1
    fi
    if handler_start; then
        [[ "${runtime_reload_safe}" -eq 1 ]] && xray_ready=1
    else
        restore_status=1
    fi
    if [[ "${xray_ready}" -eq 1 ]]; then
        handler_restore_certificate_renewal_hooks || restore_status=1
    fi
    return "${restore_status}"
}

function reject_nginx_action_in_cdn_direct_mode() {
    if ! is_cdn_direct_mode; then
        return 0
    fi
    echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.nginx_not_used")" >&2
    return 1
}

function write_xray_runtime_config() {
    local content="$1"
    local target="${XRAY_CONFIG_PATH}"
    local temp_file validation_output

    if [[ -z "${content}" ]] || ! printf '%s\n' "${content}" | jq empty 2>/dev/null; then
        echo -e "${RED}[Error]${NC} Refusing to write an invalid Xray JSON configuration." >&2
        return 1
    fi

    temp_file="$(mktemp "${target}.tmp.XXXXXX.json")" || return 1
    printf '%s\n' "${content}" >"${temp_file}" || {
        rm -f -- "${temp_file}"
        return 1
    }

    if cmd_exists xray && [[ "${XRAY_CONFIG_VALIDATE:-1}" != '0' ]]; then
        if ! validation_output="$(xray run -test -c "${temp_file}" 2>&1)"; then
            echo -e "${RED}[Xray]${NC} Configuration validation failed:" >&2
            printf '%s\n' "${validation_output}" >&2
            rm -f -- "${temp_file}"
            return 1
        fi
    fi

    if [[ -e "${target}" ]]; then
        chmod --reference="${target}" "${temp_file}" 2>/dev/null || chmod 644 "${temp_file}"
        chown --reference="${target}" "${temp_file}" 2>/dev/null || true
    elif id -u xray >/dev/null 2>&1; then
        chown root:xray "${temp_file}" 2>/dev/null || true
        chmod 640 "${temp_file}"
    else
        chmod 644 "${temp_file}"
    fi

    mv -f -- "${temp_file}" "${target}" || {
        rm -f -- "${temp_file}"
        return 1
    }
    sync
}

function commit_xray_and_script_config() {
    local runtime_content="$1"
    local script_content="$2"
    local runtime_temp script_temp runtime_backup='' script_backup=''
    local runtime_existed=0 script_existed=0 validation_output
    local runtime_restore_failed=0

    if [[ -z "${runtime_content}" ]] || ! printf '%s\n' "${runtime_content}" | jq empty 2>/dev/null ||
        [[ -z "${script_content}" ]] || ! printf '%s\n' "${script_content}" | jq empty 2>/dev/null; then
        echo -e "${RED}[Error]${NC} Refusing to commit invalid JSON configuration." >&2
        return 1
    fi

    runtime_temp="$(mktemp "${XRAY_CONFIG_PATH}.tmp.XXXXXX.json")" || return 1
    script_temp="$(mktemp "${SCRIPT_CONFIG_PATH}.tmp.XXXXXX")" || {
        rm -f -- "${runtime_temp}"
        return 1
    }
    if ! printf '%s\n' "${runtime_content}" >"${runtime_temp}" ||
        ! printf '%s\n' "${script_content}" >"${script_temp}"; then
        rm -f -- "${runtime_temp}" "${script_temp}"
        return 1
    fi

    if cmd_exists xray && [[ "${XRAY_CONFIG_VALIDATE:-1}" != '0' ]]; then
        if ! validation_output="$(xray run -test -c "${runtime_temp}" 2>&1)"; then
            echo -e "${RED}[Xray]${NC} Configuration validation failed:" >&2
            printf '%s\n' "${validation_output}" >&2
            rm -f -- "${runtime_temp}" "${script_temp}"
            return 1
        fi
    fi

    if [[ -e "${XRAY_CONFIG_PATH}" ]]; then
        runtime_existed=1
        chmod --reference="${XRAY_CONFIG_PATH}" "${runtime_temp}" 2>/dev/null || chmod 644 "${runtime_temp}"
        chown --reference="${XRAY_CONFIG_PATH}" "${runtime_temp}" 2>/dev/null || true
        runtime_backup="$(mktemp "${XRAY_CONFIG_PATH}.rollback.XXXXXX")" || {
            rm -f -- "${runtime_temp}" "${script_temp}"
            return 1
        }
        cp -p -- "${XRAY_CONFIG_PATH}" "${runtime_backup}" || {
            rm -f -- "${runtime_temp}" "${script_temp}" "${runtime_backup}"
            return 1
        }
    elif id -u xray >/dev/null 2>&1; then
        chown root:xray "${runtime_temp}" 2>/dev/null || true
        chmod 640 "${runtime_temp}"
    else
        chmod 644 "${runtime_temp}"
    fi

    chmod 600 "${script_temp}"
    if [[ -e "${SCRIPT_CONFIG_PATH}" ]]; then
        script_existed=1
        script_backup="$(mktemp "${SCRIPT_CONFIG_PATH}.rollback.XXXXXX")" || {
            rm -f -- "${runtime_temp}" "${script_temp}" "${runtime_backup}"
            return 1
        }
        cp -p -- "${SCRIPT_CONFIG_PATH}" "${script_backup}" || {
            rm -f -- "${runtime_temp}" "${script_temp}" "${runtime_backup}" "${script_backup}"
            return 1
        }
    fi

    if ! mv -f -- "${runtime_temp}" "${XRAY_CONFIG_PATH}"; then
        rm -f -- "${runtime_temp}" "${script_temp}" "${runtime_backup}" "${script_backup}"
        return 1
    fi
    if ! mv -f -- "${script_temp}" "${SCRIPT_CONFIG_PATH}"; then
        if [[ "${runtime_existed}" -eq 1 ]]; then
            if mv -f -- "${runtime_backup}" "${XRAY_CONFIG_PATH}"; then
                runtime_backup=''
            else
                runtime_restore_failed=1
            fi
        else
            rm -f -- "${XRAY_CONFIG_PATH}" || runtime_restore_failed=1
        fi
        if [[ "${script_existed}" -eq 0 ]]; then
            rm -f -- "${SCRIPT_CONFIG_PATH}"
        fi
        rm -f -- "${script_temp}" "${script_backup}"
        if [[ "${runtime_restore_failed}" -ne 0 ]]; then
            echo -e "${RED}[Error]${NC} Failed to restore the previous Xray runtime configuration." >&2
            if [[ -n "${runtime_backup}" ]]; then
                printf 'Xray runtime recovery copy retained at: %s\n' "${runtime_backup}" >&2
            else
                printf 'Uncommitted Xray runtime remains at: %s\n' "${XRAY_CONFIG_PATH}" >&2
            fi
        fi
        return 1
    fi

    rm -f -- "${runtime_backup}" "${script_backup}"
    sync
}

function user_route_rules() {
    jq -c '
        def is_derived_rule:
            ((.ruleTag // "") | tostring) as $tag |
            $tag == "api" or
            $tag == "private-ip" or
            $tag == "reverse-portal" or
            ($tag | startswith("anti-steal-")) or
            ($tag | startswith("lan-"));
        if type == "array" then map(select(is_derived_rule | not)) else [] end
    '
}

function merge_user_route_rules() {
    local rules="$1"

    XRAY_CONFIG="$(printf '%s\n' "${XRAY_CONFIG}" | jq --argjson rules "${rules}" '
        reduce $rules[] as $rule (.;
            ($rule.ruleTag // "") as $tag |
            if any(.routing.rules[]?; (.ruleTag // "") == $tag) then
                .routing.rules |= map(if (.ruleTag // "") == $tag then $rule else . end)
            else
                .routing.rules += [$rule]
            end
        )
    ')" || return 1
}

function normalize_and_validate_xray_state() {
    SCRIPT_CONFIG="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq '
        def state_bit($value):
            if $value == null or $value == "" then 0
            else ($value | tonumber? // -1)
            end;
        .xray.warp = state_bit(.xray.warp) |
        .xray.reverse = state_bit(.xray.reverse) |
        .xray.rules.reset = state_bit(.xray.rules.reset) |
        .xray.rules.bt = state_bit(.xray.rules.bt) |
        .xray.rules.cn = state_bit(.xray.rules.cn) |
        .xray.rules.ad = state_bit(.xray.rules.ad) |
        .xray.serverNames = (.xray.serverNames // []) |
        .xray.shortIds = (.xray.shortIds // []) |
        .xray.nodes = (.xray.nodes // []) |
        .xray.firewallRules = (.xray.firewallRules // []) |
        .rules = (.rules // []) |
        if (.xray.lan // null) == null then
            .xray.lan = {enabled:0,role:"hub",port:9443,target:"",serverName:"",serverAddress:"",privateKey:"",publicKey:"",shortId:"",tunName:"xray0",mtu:1400,sites:[]}
        else
            .xray.lan.enabled = state_bit(.xray.lan.enabled) |
            .xray.lan.sites = (.xray.lan.sites // [])
        end
    ')" || return 1

    if ! printf '%s\n' "${SCRIPT_CONFIG}" | jq -e '
        def bit: type == "number" and (. == 0 or . == 1);
        def port: type == "number" and floor == . and . >= 1 and . <= 65535;
        def string_array: type == "array" and all(.[]; type == "string");
        .xray as $x |
        ($x | type) == "object" and
        ($x.tag | type) == "string" and ($x.tag | length) > 0 and
        ($x.port | port) and
        ($x.warp | bit) and
        ($x.reverse | bit) and
        ($x.rules | type) == "object" and
        ($x.rules.reset | bit) and ($x.rules.bt | bit) and
        ($x.rules.cn | bit) and ($x.rules.ad | bit) and
        ($x.serverNames | string_array) and ($x.shortIds | string_array) and
        (($x.path // "") | type) == "string" and
        (($x.privateKey // "") | type) == "string" and
        (($x.target // "") | type) == "string" and
        ($x.nodes | type) == "array" and
        ($x.firewallRules | type) == "array" and
        all($x.firewallRules[];
            type == "object" and (.feature | type) == "string" and (.feature | length) > 0 and
            (.backend | IN("ufw", "firewalld", "iptables")) and (.port | port) and
            (.protocol | IN("tcp", "udp")) and
            ((.ipv4 | type) == "boolean") and ((.ipv6 | type) == "boolean") and
            (if .backend == "iptables" then (.ipv4 or .ipv6) else true end)
        ) and
        (.rules | type) == "array" and
        all(.rules[]; type == "object" and (.ruleTag | type) == "string" and (.ruleTag | length) > 0) and
        (if $x.reverse == 1 then
            ($x.reversePort | port) and
            ($x.reverseTarget | type) == "string" and ($x.reverseTarget | length) > 0 and
            ($x.reverseUuid | type) == "string" and ($x.reverseUuid | length) > 0
        else true end) and
        ($x.lan | type) == "object" and ($x.lan.enabled | bit) and
        (($x.lan.role // "") | type) == "string" and
        (($x.lan.port // 9443) | port) and
        (($x.lan.target // "") | type) == "string" and
        (($x.lan.serverName // "") | type) == "string" and
        (($x.lan.serverAddress // "") | type) == "string" and
        (($x.lan.privateKey // "") | type) == "string" and
        (($x.lan.publicKey // "") | type) == "string" and
        (($x.lan.shortId // "") | type) == "string" and
        (($x.lan.tunName // "xray0") | type) == "string" and
        (($x.lan.mtu // 1400) | type) == "number" and
        ($x.lan.sites | type) == "array"
    ' >/dev/null; then
        echo -e "${RED}[Error]${NC} Invalid or incomplete Xray script state." >&2
        return 1
    fi

    if [[ "$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.reverse')" -eq 1 ]]; then
        local reverse_target config_tag
        reverse_target="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.reverseTarget')" || return 1
        config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag')" || return 1
        if ! parse_host_port "${reverse_target}"; then
            echo -e "${RED}[Error]${NC} Invalid reverse proxy target: ${reverse_target}" >&2
            return 1
        fi
        if ! protocol_supports_reverse "${config_tag}"; then
            echo -e "${RED}[Error]${NC} Reverse proxy is not supported by ${config_tag}." >&2
            return 1
        fi
    fi
}

function apply_xray_state_transaction() {
    local previous_script_config="$1"
    local previous_xray_config="$2"
    local candidate_script_config new_firewall_rules rule rollback_script_config
    local failed_firewall_rules='[]'

    if handler_xray_config 1 && handler_restart; then
        return 0
    fi

    candidate_script_config="${SCRIPT_CONFIG}"
    new_firewall_rules="$(jq -n \
        --argjson previous "${previous_script_config}" \
        --argjson candidate "${candidate_script_config}" '
        [($candidate.xray.firewallRules // [])[] as $rule |
            select(any(($previous.xray.firewallRules // [])[]?;
                .feature == $rule.feature and .backend == $rule.backend and
                .port == $rule.port and .protocol == $rule.protocol
            ) | not) | $rule]
    ' 2>/dev/null || echo '[]')"
    while IFS= read -r rule; do
        [[ -n "${rule}" ]] || continue
        if ! remove_owned_firewall_rule "${rule}"; then
            restore_owned_firewall_rule "${rule}" || true
            failed_firewall_rules="$(echo "${failed_firewall_rules}" | jq --argjson rule "${rule}" '. + [$rule]')" ||
                failed_firewall_rules='[]'
        fi
    done < <(echo "${new_firewall_rules}" | jq -c '.[]' 2>/dev/null)

    rollback_script_config="$(jq -n \
        --argjson previous "${previous_script_config}" \
        --argjson failed "${failed_firewall_rules}" '
        $previous |
        .xray.firewallRules = (((.xray.firewallRules // []) + $failed) |
            unique_by([.feature,.backend,.port,.protocol]))
    ')" || rollback_script_config="${previous_script_config}"
    if [[ "$(echo "${failed_firewall_rules}" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]]; then
        echo 'Some newly opened firewall rules could not be removed; ownership records were retained.' >&2
    fi
    SCRIPT_CONFIG="${rollback_script_config}"
    XRAY_CONFIG="${previous_xray_config}"
    if ! commit_xray_and_script_config "${previous_xray_config}" "${rollback_script_config}" ||
        ! handler_restart; then
        echo 'Xray state rollback failed.' >&2
    fi
    return 1
}

# =============================================================================
# handler.sh 专用函数
# =============================================================================
function _error() {
    printf "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')] ${NC}" >&2
    printf -- "%s" "$@" >&2
    printf "\n" >&2
    exit 1
}

function exec_generate() {
    bash "${GENERATE_PATH}" "$@"
}

function exec_docker() {
    bash "${DOCKER_PATH}" "$@" || return 1
}

function exec_ssl() {
    bash "${SSL_PATH}" "$@"
}

function exec_check() {
    bash "${CHECK_PATH}" "$@"
}

# =============================================================================
# 函数名称: list_existing_certs
# 功能描述: 扫描系统中已有的 SSL 证书。
#           1. 扫描 Nginx 证书目录 (/usr/local/nginx/conf/certs/)
#           2. 扫描 Xray 证书目录 (/usr/local/etc/xray/certs/)
#           3. 扫描 acme.sh 管理的证书列表
#           4. 去重后输出证书域名列表（一行一个）
# 参数:
#   $1: cert_type - 证书类型 ("nginx"、"xray" 或仅 "acme")，默认为 "nginx"
# 返回值: 证书域名列表 (echo 输出，一行一个)
# =============================================================================
function list_existing_certs() {
    local cert_type="${1:-nginx}"  # "nginx" 或 "xray"(HY2用)
    local target_identifier="${2:-}"
    local cert_source="${3:-}"
    local certs=()
    local d domain cert_domain c found acme_list
    local local_acme_domain='' local_cert_managed=1

    if [[ "${cert_type}" == "nginx" ]]; then
        # 扫描 Nginx 证书目录
        local cert_base="/usr/local/nginx/conf/certs"
        if [[ -d "${cert_base}" ]]; then
            for d in "${cert_base}"/*/; do
                [[ -d "${d}" ]] || continue
                domain="$(basename "$d")"
                if [[ -f "${d}fullchain.pem" && -f "${d}privkey.pem" ]]; then
                    certs+=("${domain}")
                fi
            done
        fi
    elif [[ "${cert_type}" == "xray" ]]; then
        if [[ "${cert_source}" =~ ^[12]$ ]]; then
            local_acme_domain="$(echo "${SCRIPT_CONFIG:-{}}" | jq -r '
                (.xray.hy2CertAcmeDomain // "") as $acme_domain |
                if $acme_domain == "" then (.xray.hy2CertDomain // "") else $acme_domain end
            ' 2>/dev/null || true)"
            [[ -n "${local_acme_domain}" ]] ||
                local_acme_domain="${target_identifier}"
            acme_manages_certificate "${local_acme_domain}" ||
                local_cert_managed=0
        fi
        # 扫描当前 HY2 标识符/来源的隔离目录，并兼容旧版固定路径。
        local cert_dir=''
        if cert_dir="$(get_hy2_cert_dir "${target_identifier}" "${cert_source}" 2>/dev/null)" &&
            [[ "${local_cert_managed}" -eq 1 &&
                -f "${cert_dir}/fullchain.pem" &&
                -f "${cert_dir}/privkey.pem" ]]; then
            certs+=("xray-certs")
        fi
        local legacy_cert_dir="${XRAY_CERT_DIR_OVERRIDE:-/usr/local/etc/xray/certs}"
        if [[ "${local_cert_managed}" -eq 1 &&
            -f "${legacy_cert_dir}/fullchain.pem" &&
            -f "${legacy_cert_dir}/privkey.pem" ]]; then
            certs+=("legacy-xray-certs")
        fi
    fi

    # 同时扫描 acme.sh 管理的证书
    if [[ -e "${HOME}/.acme.sh/acme.sh" ]]; then
        # Every install path below uses acme.sh --ecc. Do not offer an
        # RSA-only record that --install-cert --ecc cannot actually install.
        acme_list=$("${HOME}/.acme.sh/acme.sh" --list --home "${HOME}/.acme.sh" 2>/dev/null |
            awk 'NR > 1 {
                key_length = tolower($2)
                gsub(/"/, "", key_length)
                if (key_length ~ /^ec-/) print $1
            }')
        for cert_domain in ${acme_list}; do
            # 去重：检查是否已存在于 certs 数组中
            found=false
            for c in "${certs[@]}"; do
                [[ "${c}" == "${cert_domain}" ]] && found=true && break
            done
            [[ "${found}" == false ]] && certs+=("${cert_domain}")
        done
    fi

    # 输出证书列表（一行一个）
    printf '%s\n' "${certs[@]}"
}

# =============================================================================
# 函数名称: prompt_cert_reuse
# 功能描述: 在非首次安装时询问用户是否复用已有证书。
#           1. 调用 list_existing_certs 获取已有证书列表。
#           2. 如果没有已有证书，返回 "new" 表示需要新申请。
#           3. 如果有已有证书，显示列表（含过期时间）供用户选择。
#           4. 返回用户选择的证书域名或 "new"。
# 参数:
#   $1: target_domain - 当前要配置的域名
#   $2: cert_type - 证书类型 ("nginx"、"xray" 或仅 "acme")，默认为 "nginx"
# 返回值: 选择的证书域名或 "new" (echo 输出)
# =============================================================================
function prompt_cert_reuse() {
    local target_domain="$1"       # 当前要配置的域名
    local cert_type="${2:-nginx}" # 证书类型
    local cert_source="${3:-}"
    local line cert_domain

    # 获取已有证书列表
    local -a cert_list=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] && cert_list+=("${line}")
    done < <(list_existing_certs "${cert_type}" "${target_domain}" "${cert_source}")

    # 如果没有已有证书，直接返回 "new" 表示需要新申请
    if [[ ${#cert_list[@]} -eq 0 ]]; then
        echo "new"
        return
    fi

    # 显示选择提示
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_reuse.prompt")" >&2
    echo -e "  ${GREEN}1)${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_reuse.option_new")" >&2

    local idx=2
    for cert_domain in "${cert_list[@]}"; do
        # 获取证书过期时间（如果能获取到）
        local expiry_info=""
        local cert_file=""
        if [[ "${cert_type}" == "nginx" ]]; then
            cert_file="/usr/local/nginx/conf/certs/${cert_domain}/fullchain.pem"
        elif [[ "${cert_type}" == "xray" && "${cert_domain}" == "xray-certs" ]]; then
            local current_xray_cert_dir=''
            current_xray_cert_dir="$(get_hy2_cert_dir "${target_domain}" "${cert_source}" 2>/dev/null || true)"
            cert_file="${current_xray_cert_dir}/fullchain.pem"
        elif [[ "${cert_type}" == "xray" && "${cert_domain}" == "legacy-xray-certs" ]]; then
            cert_file="${XRAY_CERT_DIR_OVERRIDE:-/usr/local/etc/xray/certs}/fullchain.pem"
        fi
        if [[ -n "${cert_file}" && -f "${cert_file}" ]]; then
            expiry_info=$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d= -f2)
            [[ -n "${expiry_info}" ]] && expiry_info=" ($(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_reuse.expires"): ${expiry_info})"
        fi
        echo -e "  ${GREEN}${idx})${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_reuse.option_existing") ${cert_domain}${expiry_info}" >&2
        ((idx++))
    done

    local cert_choice
    read -r cert_choice
    cert_choice="${cert_choice:-1}"

    if [[ "${cert_choice}" == "1" ]]; then
        echo "new"
    else
        local selected_idx=$((cert_choice - 2))
        if [[ ${selected_idx} -ge 0 && ${selected_idx} -lt ${#cert_list[@]} ]]; then
            echo "${cert_list[${selected_idx}]}"
        else
            echo "new"
        fi
    fi
}

# =============================================================================
# 函数名称: ensure_service_users
# 功能描述: 确保 nginx 和 xray 服务用户及共享组存在。
#           - 创建系统用户 nginx 和 xray（不可登录）
#           - 创建共享组 xray-nginx 用于 Unix Socket 互通
#           - 将 nginx 和 xray 都加入 xray-nginx 组
# 参数: 无
# 返回值: 无
# =============================================================================
function ensure_service_users() {
    # 创建共享组 xray-nginx（如不存在）
    if ! getent group xray-nginx >/dev/null 2>&1; then
        groupadd -r xray-nginx
    fi
    # 创建 nginx 系统用户（如不存在）
    if ! id -u nginx >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -d /var/cache/nginx -M nginx
    fi
    # 创建 xray 系统用户（如不存在）
    if ! id -u xray >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -d /var/lib/xray -M xray
    fi
    # 将 nginx 和 xray 加入 xray-nginx 共享组
    usermod -aG xray-nginx nginx 2>/dev/null || true
    usermod -aG xray-nginx xray 2>/dev/null || true
}


# =============================================================================
# 函数名称: exec_read
# 功能描述: 执行 read.sh 脚本读取用户输入，并进行验证。
#           1. 调用 read.sh 获取用户输入。
#           2. 根据输入类型，调用 check.sh 进行验证。
#           3. 对于特定输入（如 short），进行特殊处理和验证。
#           4. 将验证通过的输入存储到 CONFIG_DATA 关联数组中。
# 参数:
#   $1: 配置项名称 (对应 read.sh 的参数，如 port, uuid, domain 等)
# 返回值: 无 (直接修改全局变量 CONFIG_DATA)
# =============================================================================
function exec_read() {
    local opt="$1"  # 获取配置项名称
    local flag=true # 初始化循环标志为 true
    local result    # 声明用于存储 read.sh 输出的局部变量
    # 循环直到输入有效 (flag 为 false)
    while ${flag}; do
        # 调用 read.sh 脚本获取用户输入
        result="$(bash "${READ_PATH}" "--${opt}")" || return 1
        # 根据配置项名称进行特定验证
        case "${opt}" in
        version)
            # 验证 Xray 版本
            exec_check '--xray' "${result}" || continue
            ;;
        email)
            # 验证邮箱地址
            exec_check '--email' "${result}" || continue
            ;;
        block-bt | block-cn | block-ad)
            # 为阻止选项设置默认值 'Y'
            result="${result:-Y}"
            ;;
        rules)
            # 为规则选项设置默认值 'N'
            result="${result:-N}"
            ;;
        port)
            # 验证端口号
            exec_check '--port' "${result}" || continue
            [[ -n "${result}" ]] && result="$((10#${result}))"
            ;;
        reverse-port)
            result="${result:-8443}"
            exec_check '--port' "${result}" || continue
            result="$((10#${result}))"
            ;;
        reverse-target)
            exec_check '--reverse-target' "${result}" || continue
            ;;
        reverse-uuid)
            exec_check '--uuid' "${result}" || continue
            ;;
        uuid | fallback)
            # 验证 UUID (fallback 也使用 uuid 验证)
            exec_check '--uuid' "${result}" || continue
            ;;
        seed | password | hy2-auth)
            # 验证密码、种子或 HY2 auth
            exec_check '--password' "${result}" || continue
            ;;
        ss2022-password)
            exec_check '--ss2022-key' "${result}" || continue
            ;;
        target)
            # 验证目标域名
            exec_check '--domain' "${result}" || continue
            ;;
        hy2-cert-domain)
            exec_check '--dns' "${result}" || continue
            ;;
        only-change-domain)
            # 为仅更新域名选项设置默认值 'Y'
            result="${result:-Y}"
            ;;
        domain)
            # Reality/SNI 域名仍需解析到当前服务器
            exec_check '--dns' "${result}" || continue
            CONFIG_DATA['target']="${result}"
            ;;
        cdn)
            local config_tag="${CONFIG_DATA['tag']:-}"
            [[ -z "${config_tag}" ]] && config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')"
            if [[ "${config_tag,,}" == 'cdn' || "${config_tag,,}" == 'sni' ]]; then
                # CDN 域名应解析到 CDN 节点，仅校验格式以避免暴露源站 IP
                exec_check '--domain-format' "${result}" || continue
                if [[ -z "${CONFIG_DATA['tag']+set}" ]]; then
                    local configured_down="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')"
                    if [[ -n "${configured_down}" && "${result,,}" == "${configured_down,,}" ]]; then
                        echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_split.domain_duplicate")" >&2
                        continue
                    fi
                fi
            else
                exec_check '--dns' "${result}" || continue
            fi
            ;;
        cdn-down)
            # 下行 CDN 可留空；非空时仅校验格式，避免要求 CDN 域名直解析到源站。
            if [[ -n "${result}" ]]; then
                exec_check '--domain-format' "${result}" || continue
                local uplink_domain="${CONFIG_DATA['cdn']:-}"
                [[ -n "${uplink_domain}" ]] || uplink_domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn // ""')"
                if [[ "${result,,}" == "${uplink_domain,,}" ]]; then
                    echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_split.domain_duplicate")" >&2
                    continue
                fi
            fi
            ;;
        short)
            # 特殊处理 Short IDs
            # 如果输入为空，进行验证 (可能是检查默认值)
            [[ -z "${result}" ]] && exec_check '--short' "${result}" && break
            # 将逗号分隔的输入分割成数组
            IFS=',' read -r -a values <<<"${result}"
            local parsed_short_ids=''
            local short_ids_valid=true
            # 遍历每个 Short ID 进行验证
            for value in "${values[@]}"; do
                if exec_check '--short' "${value}"; then
                    parsed_short_ids+=" ${value}"
                else
                    short_ids_valid=false
                    break
                fi
            done
            ${short_ids_valid} || continue
            CONFIG_DATA['short_ids']="${parsed_short_ids# }"
            ;;
        path)
            # 验证路径
            local config_tag="${CONFIG_DATA['tag']}"
            if protocol_uses_xhttp "${config_tag}"; then
                exec_check '--path-required' "${result}" || continue
            else
                exec_check '--path' "${result}" || continue
            fi
            result="$(normalize_xhttp_path "${result}")"
            ;;
        xhttp-mode)
            result="${result:-auto}"
            exec_check '--xhttp-mode' "${result}" || continue
            result="${result,,}"
            ;;
        esac
        # 输入验证通过，设置 flag 为 false 退出循环
        flag=false
    done
    # 将最终的用户输入结果存储到 CONFIG_DATA 关联数组中
    CONFIG_DATA["$1"]="${result}"
}

# =============================================================================
# 函数名称: map_protocol_choice_to_tag
# 功能描述: 将用户的菜单选择编号映射为对应的协议配置标签。
# 参数:
#   $1: 用户选择的菜单编号 (1-7)
# 返回值: 对应的协议标签名称 (echo 输出，如 'mKCP', 'Vision', 'XHTTP' 等)
# =============================================================================
function map_protocol_choice_to_tag() {
    protocol_from_multi_menu_choice "$1"
}

function print_multi_protocol_menu() {
    echo -e "------------------ $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.protocol_title") ------------------" >&2
    echo -e "${GREEN}1.${NC} $(echo "$I18N_DATA" | jq -r '.menu.protocol_config.option1') (${GREEN}$(echo "$I18N_DATA" | jq -r '.menu.status.default')${NC})" >&2
    echo -e "${GREEN}2.${NC} $(echo "$I18N_DATA" | jq -r '.menu.protocol_config.option2')" >&2
    echo -e "${GREEN}3.${NC} $(echo "$I18N_DATA" | jq -r '.menu.protocol_config.option3')" >&2
    echo -e "${GREEN}4.${NC} $(echo "$I18N_DATA" | jq -r '.menu.protocol_config.option4')" >&2
    echo -e "${GREEN}5.${NC} $(echo "$I18N_DATA" | jq -r '.menu.protocol_config.option5')" >&2
    echo -e "${GREEN}6.${NC} $(echo "$I18N_DATA" | jq -r '.menu.protocol_config.option6')" >&2
    echo -e "${GREEN}7.${NC} $(echo "$I18N_DATA" | jq -r '.menu.protocol_config.option7')" >&2
    echo -e "----------------------------------------------------------" >&2
}

function read_multi_protocol_tag() {
    local node_index="$1"
    local choose config_tag
    local multi_label="$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.label")"

    while true; do
        echo -e "${GREEN}[${multi_label}]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.select_protocol") ${node_index}" >&2
        print_multi_protocol_menu
        printf "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')] ${NC} $(echo "$I18N_DATA" | jq -r ".menu.choose"): " >&2
        read -r choose
        choose="${choose:-1}"

        if [[ "${choose}" =~ ^[0-9]+$ ]]; then
            choose="$(echo "${choose}" | sed 's/^0*//')"
            choose="${choose:-0}"
        else
            choose=''
        fi

        if config_tag="$(map_protocol_choice_to_tag "${choose}")" && [[ -n "${config_tag}" ]]; then
            echo "${config_tag}"
            return 0
        fi

        echo -e "${YELLOW}[${multi_label}]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.unsupported")" >&2
    done
}

function port_in_list() {
    local needle="$1"
    shift
    local value
    for value in "$@"; do
        [[ "${value}" == "${needle}" ]] && return 0
    done
    return 1
}

function generate_unique_multi_port() {
    local requested="$1"
    local config_tag="$2"
    shift 2
    local used_ports=("$@")
    local port="${requested}"
    local multi_label="$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.label")"

    if [[ -z "${port}" ]]; then
        if [[ "${config_tag,,}" == 'mkcp' || ${#used_ports[@]} -gt 0 ]]; then
            port="$(exec_generate '--port')"
        else
            port=443
        fi
    fi

    while [[ "${port}" == '32768' ]] || port_in_list "${port}" "${used_ports[@]}"; do
        echo -e "${YELLOW}[${multi_label}]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.port_conflict" | sed "s/{port}/${port}/g")" >&2
        port="$(exec_generate '--port')"
    done

    echo "${port}"
}

function build_multi_node_json() {
    local config_tag="$1"
    local node_index="$2"
    local xray_port="$3"
    local node

    node="$(jq -n \
        --arg tag "${config_tag}" \
        --arg name "${config_tag}-${node_index}" \
        --argjson port "${xray_port}" \
        '{tag:$tag,name:$name,port:$port}')"

    case "${config_tag,,}" in
    trojan)
        local trojan_password="${CONFIG_DATA['password']:-$(exec_generate '--password')}"
        node="$(echo "${node}" | jq --arg password "${trojan_password}" '.trojan = $password')"
        ;;
    hy2)
        local hy2_auth="${CONFIG_DATA['hy2-auth']:-$(exec_generate '--hy2-auth')}"
        node="$(echo "${node}" | jq --arg auth "${hy2_auth}" '.hy2auth = $auth')"
        ;;
    ss2022)
        local ss2022_key="${CONFIG_DATA['ss2022-password']:-$(exec_generate '--ss2022-key')}"
        node="$(echo "${node}" | jq --arg key "${ss2022_key}" '.ss2022Key = $key')"
        ;;
    mkcp | vision | xhttp | fallback)
        local xray_uuid="$(exec_generate '--uuid' "${CONFIG_DATA['uuid']}")"
        node="$(echo "${node}" | jq --arg uuid "${xray_uuid}" '.uuid = $uuid')"
        ;;
    esac

    case "${config_tag,,}" in
    fallback)
        local fallback_uuid="$(exec_generate '--uuid' "${CONFIG_DATA['fallback']:-}")"
        node="$(echo "${node}" | jq --arg uuid "${fallback_uuid}" '.fallback = $uuid')"
        ;;
    mkcp)
        local kcp_seed="${CONFIG_DATA['seed']:-$(exec_generate '--password')}"
        node="$(echo "${node}" | jq --arg seed "${kcp_seed}" '.kcp = $seed')"
        ;;
    esac

    case "${config_tag,,}" in
    vision | xhttp | trojan | fallback)
        local target_domain="${CONFIG_DATA['target']:-$(exec_generate '--target')}"
        local server_names="$(exec_generate '--server-names' "${target_domain}")"
        local short_ids="$(exec_generate '--short-ids' ${CONFIG_DATA['short_ids']:-${CONFIG_DATA['short']:-'8 8'}})"
        node="$(echo "${node}" | jq \
            --arg target "${target_domain}" \
            --argjson serverNames "${server_names}" \
            --argjson shortIds "${short_ids}" \
            '.target = $target | .serverNames = $serverNames | .shortIds = $shortIds')"
        ;;
    esac

    case "${config_tag,,}" in
    xhttp | trojan | fallback)
        local xhttp_path="${CONFIG_DATA['path']:-$(exec_generate '--path')}"
        local xhttp_mode="${CONFIG_DATA['xhttp-mode']:-auto}"
        node="$(echo "${node}" | jq --arg path "${xhttp_path}" --arg mode "${xhttp_mode}" '.path = $path | .xhttpMode = $mode')"
        ;;
    esac

    echo "${node}"
}

function read_multi_node_protocol_fields() {
    local config_tag="$1"

    case "${config_tag,,}" in
    trojan)
        exec_read 'password' || return 1
        exec_read 'target' || return 1
        exec_read 'short' || return 1
        exec_read 'path' || return 1
        exec_read 'xhttp-mode' || return 1
        ;;
    hy2)
        exec_read 'hy2-auth' || return 1
        ;;
    ss2022)
        exec_read 'ss2022-password' || return 1
        ;;
    mkcp)
        exec_read 'uuid' || return 1
        exec_read 'seed' || return 1
        ;;
    vision)
        exec_read 'uuid' || return 1
        exec_read 'target' || return 1
        exec_read 'short' || return 1
        ;;
    xhttp)
        exec_read 'uuid' || return 1
        exec_read 'target' || return 1
        exec_read 'short' || return 1
        exec_read 'path' || return 1
        exec_read 'xhttp-mode' || return 1
        ;;
    fallback)
        exec_read 'uuid' || return 1
        exec_read 'fallback' || return 1
        exec_read 'target' || return 1
        exec_read 'short' || return 1
        exec_read 'path' || return 1
        exec_read 'xhttp-mode' || return 1
        ;;
    *)
        return 1
        ;;
    esac
}

function read_hy2_certificate_config() {
    local cert_source server_ip fullchain privkey cert_server_name suggested_name

    while true; do
        echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.prompt")" >&2
        read -r cert_source
        cert_source="${cert_source:-1}"
        case "${cert_source}" in
        1 | 2 | 3) break ;;
        *) echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.source_invalid")" >&2 ;;
        esac
    done

    CONFIG_DATA['hy2_cert_source']="${cert_source}"
    case "${cert_source}" in
    1)
        exec_read 'hy2-cert-domain' || return 1
        CONFIG_DATA['hy2_cert_domain']="${CONFIG_DATA['hy2-cert-domain']}"
        exec_read 'email' || return 1
        CONFIG_DATA['hy2_cert_email']="${CONFIG_DATA['email']}"
        ;;
    2)
        echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.ip_prompt")" >&2
        server_ip="$(curl -fsS4 --max-time 10 https://api.ipify.org 2>/dev/null || curl -fsS6 --max-time 10 https://api64.ipify.org 2>/dev/null)"
        if [[ -z "${server_ip}" ]] || ! exec_check '--ip' "${server_ip}"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.ip_fetch_fail")" >&2
            return 1
        fi
        echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.detected_ip") ${server_ip}" >&2
        CONFIG_DATA['hy2_cert_domain']="${server_ip}"
        exec_read 'email' || return 1
        CONFIG_DATA['hy2_cert_email']="${CONFIG_DATA['email']}"
        ;;
    3)
        while true; do
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.fullchain")" >&2
            read -r fullchain
            fullchain="$(echo "${fullchain}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -f "${fullchain}" && -r "${fullchain}" ]] && break
            echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.path_invalid")" >&2
        done
        while true; do
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.privkey")" >&2
            read -r privkey
            privkey="$(echo "${privkey}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -f "${privkey}" && -r "${privkey}" ]] && break
            echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.path_invalid")" >&2
        done
        if ! validate_tls_certificate_pair "${fullchain}" "${privkey}"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.pair_invalid")" >&2
            return 1
        fi

        suggested_name="$(extract_certificate_server_name "${fullchain}")"
        while true; do
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.server_name")${suggested_name:+ [${suggested_name}]}: " >&2
            read -r cert_server_name
            cert_server_name="${cert_server_name:-${suggested_name}}"
            if [[ -z "${cert_server_name}" ]] ||
                { ! exec_check '--ip' "${cert_server_name}" >/dev/null 2>&1 && ! exec_check '--domain-format' "${cert_server_name}" >/dev/null 2>&1; }; then
                echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.name_invalid")" >&2
                continue
            fi
            if ! certificate_matches_server_name "${fullchain}" "${cert_server_name}"; then
                echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.name_mismatch")" >&2
                continue
            fi
            break
        done
        CONFIG_DATA['hy2_cert_fullchain']="${fullchain}"
        CONFIG_DATA['hy2_cert_privkey']="${privkey}"
        CONFIG_DATA['hy2_cert_domain']="${cert_server_name}"
        ;;
    esac
}

function validate_tls_certificate_pair() {
    local fullchain="$1"
    local privkey="$2"
    local cert_public_key key_public_key

    cert_public_key="$(openssl x509 -in "${fullchain}" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform PEM 2>/dev/null)" || return 1
    key_public_key="$(openssl pkey -in "${privkey}" -pubout -outform PEM 2>/dev/null)" || return 1
    [[ -n "${cert_public_key}" && "${cert_public_key}" == "${key_public_key}" ]]
}

function extract_certificate_server_name() {
    local fullchain="$1"
    local san_output server_name

    san_output="$(openssl x509 -in "${fullchain}" -noout -ext subjectAltName 2>/dev/null || true)"
    if [[ -z "${san_output}" ]]; then
        san_output="$(openssl x509 -in "${fullchain}" -noout -text 2>/dev/null | awk '
            /X509v3 Subject Alternative Name/ { capture = 1; next }
            capture && /^[[:space:]]*X509v3 / { exit }
            capture && /^[[:space:]]*Signature Algorithm:/ { exit }
            capture { print }
        ')"
    fi
    server_name="$(printf '%s\n' "${san_output}" | tr ',' '\n' | sed -nE 's/^[[:space:]]*DNS:([^[:space:]]+).*/\1/p' | head -n 1)"
    if [[ -z "${server_name}" ]]; then
        server_name="$(printf '%s\n' "${san_output}" | tr ',' '\n' | sed -nE 's/^[[:space:]]*IP Address:([^[:space:]]+).*/\1/p' | head -n 1)"
    fi
    if [[ -z "${server_name}" ]]; then
        server_name="$(openssl x509 -in "${fullchain}" -noout -subject -nameopt RFC2253 2>/dev/null | sed -nE 's/^subject=.*CN=([^,]+).*$/\1/p' | head -n 1)"
    fi
    printf '%s\n' "${server_name}"
}

function certificate_sha256_fingerprint() {
    local certificate="$1"

    openssl x509 -in "${certificate}" -noout -fingerprint -sha256 2>/dev/null |
        sed 's/^[^=]*=//'
}

function certificate_matches_server_name() {
    local fullchain="$1"
    local server_name="$2"
    local san_output candidate pattern suffix prefix subject common_name

    # OpenSSL 1.1.1+ performs RFC-compliant hostname/IP checks itself.
    if openssl x509 -help 2>&1 | grep -q -- '-checkhost'; then
        if [[ "${server_name}" == *:* || "${server_name}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            openssl x509 -in "${fullchain}" -noout -checkip "${server_name}" >/dev/null 2>&1
        else
            openssl x509 -in "${fullchain}" -noout -checkhost "${server_name}" >/dev/null 2>&1
        fi
        return $?
    fi

    # CentOS 7 ships OpenSSL 1.0.2, whose x509 command has no -checkhost or
    # -checkip. Parse SANs as a compatibility fallback instead of rejecting
    # every otherwise valid certificate on a supported distribution.
    san_output="$(openssl x509 -in "${fullchain}" -noout -text 2>/dev/null | awk '
        /X509v3 Subject Alternative Name/ { capture = 1; next }
        capture && /^[[:space:]]*X509v3 / { exit }
        capture && /^[[:space:]]*Signature Algorithm:/ { exit }
        capture { print }
    ')"
    if [[ "${server_name}" == *:* || "${server_name}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        while IFS= read -r candidate; do
            [[ "${candidate,,}" == "${server_name,,}" ]] && return 0
        done < <(printf '%s\n' "${san_output}" | tr ',' '\n' |
            sed -nE 's/^[[:space:]]*IP Address:([^[:space:]]+).*/\1/p')
        return 1
    fi

    while IFS= read -r pattern; do
        pattern="${pattern,,}"
        server_name="${server_name,,}"
        if [[ "${pattern}" == "${server_name}" ]]; then
            return 0
        fi
        if [[ "${pattern}" == \*.* ]]; then
            suffix="${pattern#*.}"
            if [[ "${server_name}" == *".${suffix}" ]]; then
                prefix="${server_name%".${suffix}"}"
                [[ -n "${prefix}" && "${prefix}" != *.* ]] && return 0
            fi
        fi
    done < <(printf '%s\n' "${san_output}" | tr ',' '\n' |
        sed -nE 's/^[[:space:]]*DNS:([^[:space:]]+).*/\1/p')

    # Legacy certificates without a dNSName SAN may still use their CN.
    if printf '%s\n' "${san_output}" | grep -q 'DNS:'; then
        return 1
    fi
    subject="$(openssl x509 -in "${fullchain}" -noout -subject -nameopt RFC2253 2>/dev/null ||
        openssl x509 -in "${fullchain}" -noout -subject 2>/dev/null)" || return 1
    common_name="$(printf '%s\n' "${subject}" |
        sed -nE 's/^subject[[:space:]]*=[[:space:]]*.*CN[[:space:]]*=[[:space:]]*([^,\/]+).*$/\1/p' |
        head -n 1)"
    common_name="${common_name,,}"
    if [[ "${common_name}" == "${server_name}" ]]; then
        return 0
    fi
    if [[ "${common_name}" == \*.* ]]; then
        suffix="${common_name#*.}"
        if [[ "${server_name}" == *".${suffix}" ]]; then
            prefix="${server_name%".${suffix}"}"
            [[ -n "${prefix}" && "${prefix}" != *.* ]]
            return $?
        fi
    fi
    return 1
}

function handler_read_multi_xray_config() {
    local nodes='[]'
    local used_ports=()
    local node_count
    local has_hy2='n'
    local vless_enc_prompted='n'
    local mldsa65_prompted='n'
    local multi_vless_enc_enable=''
    local multi_mldsa65_enable=''
    local multi_github_proxy=''
    local multi_label="$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.label")"

    reset_config_data
    CONFIG_DATA['tag']='multi'

    exec_read 'rules' || return 1
    if [[ "${CONFIG_DATA['rules'],,}" != 'n' ]]; then
        exec_read 'block-bt' || return 1
        exec_read 'block-cn' || return 1
        exec_read 'block-ad' || return 1
    fi
    local multi_rules="${CONFIG_DATA['rules']:-N}"
    local multi_block_bt="${CONFIG_DATA['block-bt']:-N}"
    local multi_block_cn="${CONFIG_DATA['block-cn']:-N}"
    local multi_block_ad="${CONFIG_DATA['block-ad']:-N}"

    while true; do
        echo -e "${GREEN}[${multi_label}]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.node_count_prompt")" >&2
        read -r node_count || return 1
        node_count="${node_count:-2}"
        if [[ "${node_count}" =~ ^[0-9]{1,3}$ ]]; then
            node_count="$((10#${node_count}))"
            [[ "${node_count}" -ge 2 && "${node_count}" -le 100 ]] && break
        fi
        echo -e "${YELLOW}[${multi_label}]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.node_count_invalid")" >&2
    done

    local i
    for ((i = 1; i <= node_count; i++)); do
        local config_tag
        config_tag="$(read_multi_protocol_tag "${i}")"

        reset_config_data
        CONFIG_DATA['tag']="${config_tag}"

        echo -e "${GREEN}[${multi_label}]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.port_prompt")" >&2
        exec_read 'port' || return 1
        local xray_port
        xray_port="$(generate_unique_multi_port "${CONFIG_DATA['port']}" "${config_tag}" "${used_ports[@]}")"
        used_ports+=("${xray_port}")
        echo -e "${GREEN}[${multi_label}]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.port_assigned" | sed "s/{port}/${xray_port}/g")" >&2

        read_multi_node_protocol_fields "${config_tag}" || return 1

        protocol_uses_hy2_certificate "${config_tag}" && has_hy2='y'
        if [[ "${vless_enc_prompted}" == 'n' ]] && protocol_uses_vless_enc "${config_tag}"; then
            # VLESS enc is a shared setting for VLESS nodes. Ask while an
            # applicable node is being configured so a trailing HY2 node does
            # not appear to own this option.
            run_vlessenc_choice || return 1
            multi_vless_enc_enable="${CONFIG_DATA['vless_enc_enable']:-n}"
            vless_enc_prompted='y'
        fi
        if [[ "${mldsa65_prompted}" == 'n' ]] && protocol_uses_reality "${config_tag}"; then
            run_mldsa65_choice || return 1
            multi_mldsa65_enable="${CONFIG_DATA['mldsa65_enable']:-n}"
            mldsa65_prompted='y'
        fi

        local node
        node="$(build_multi_node_json "${config_tag}" "${i}" "${xray_port}")"
        nodes="$(echo "${nodes}" | jq --argjson node "${node}" '. + [$node]')"
    done

    if ! cmd_exists 'xray'; then
        run_github_proxy_choice || return 1
        multi_github_proxy="${CONFIG_DATA['github_proxy']:-n}"
    fi

    if [[ "${has_hy2}" == 'y' ]]; then
        echo -e "${YELLOW}[${multi_label}]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.hy2_shared_cert")" >&2
        read_hy2_certificate_config || return 1
    fi

    local multi_hy2_cert_source="${CONFIG_DATA['hy2_cert_source']:-}"
    local multi_hy2_cert_domain="${CONFIG_DATA['hy2_cert_domain']:-}"
    local multi_hy2_cert_email="${CONFIG_DATA['hy2_cert_email']:-}"
    local multi_hy2_cert_fullchain="${CONFIG_DATA['hy2_cert_fullchain']:-}"
    local multi_hy2_cert_privkey="${CONFIG_DATA['hy2_cert_privkey']:-}"

    reset_config_data
    CONFIG_DATA['tag']='multi'
    CONFIG_DATA['rules']="${multi_rules}"
    CONFIG_DATA['block-bt']="${multi_block_bt}"
    CONFIG_DATA['block-cn']="${multi_block_cn}"
    CONFIG_DATA['block-ad']="${multi_block_ad}"
    CONFIG_DATA['nodes_json']="${nodes}"
    CONFIG_DATA['vless_enc_enable']="${multi_vless_enc_enable}"
    CONFIG_DATA['mldsa65_enable']="${multi_mldsa65_enable}"
    CONFIG_DATA['github_proxy']="${multi_github_proxy}"
    CONFIG_DATA['hy2_cert_source']="${multi_hy2_cert_source}"
    CONFIG_DATA['hy2_cert_domain']="${multi_hy2_cert_domain}"
    CONFIG_DATA['hy2_cert_email']="${multi_hy2_cert_email}"
    CONFIG_DATA['hy2_cert_fullchain']="${multi_hy2_cert_fullchain}"
    CONFIG_DATA['hy2_cert_privkey']="${multi_hy2_cert_privkey}"
}

function reset_json_fields() {
    local raw_json="$1"   # 获取原始 JSON 字符串
    local target_key="$2" # 获取目标键名
    # 移除前两个参数，剩下的就是需要保留的字段名
    shift 2
    local keep_fields=("$@") # 获取需要保留的字段名数组
    # 将保留字段名数组转换为 jq 可用的 JSON 数组
    local jq_keep=$(printf '%s\n' "${keep_fields[@]}" | jq -R . | jq -s .)
    # 使用 jq 脚本进行重置操作
    raw_json=$(echo "${raw_json}" | jq --arg key "${target_key}" --argjson keep "$jq_keep" '
        # 定义递归函数 clear_recursive，用于清空值
        def clear_recursive:
            if type == "object" then with_entries(.value |= clear_recursive)
            elif type == "array" then map(clear_recursive) | unique
            elif type == "number" then 0
            elif type == "boolean" then false
            else ""
            end;
        # 定义函数 exec_clear，用于判断字段是否需要保留
        def exec_clear:
            if .key | IN($keep[]) then .
            else .value |= clear_recursive
            end;
        # 根据是否指定了目标键来决定重置范围
        if $key != "null" then .[$key] |= with_entries(exec_clear)
        else . |= with_entries(exec_clear)
        end
    ')
    # 输出重置后的 JSON 字符串
    echo "${raw_json}"
}

# =============================================================================
# 函数名称: add_rule
# 功能描述: 在 Xray 配置的 routing.rules 中添加或更新路由规则。
#           1. 检查是否存在具有相同 ruleTag 的规则。
#           2. 如果存在且是 domain 或 ip 规则，则追加新值。
#           3. 如果不存在，则创建新规则。
#           4. 新规则可以插入到指定位置或相对于其他规则的位置。
#           5. 更新后的配置写入 XRAY_CONFIG_PATH 文件。
# 参数:
#   $1: rule_tag - 规则标签 (ruleTag)，用于唯一标识规则
#   $2: domain_or_ip - 规则类型 ("domain" 或 "ip")
#   $3: value - 要添加的值 (可以是逗号分隔的多个值)
#   $4: outboundTag - 出站标签 (例如 "block", "warp")
#   $5: position - (可选) 插入位置或相对于 target_tag 的位置 ("before", "after", 数字索引)
#   $6: target_tag - (可选) 用于定位插入位置的参考规则标签
# 返回值: 无 (仅更新内存中的 XRAY_CONFIG)
# =============================================================================
function add_rule() {
    local rule_tag="$1"
    local rule_field="$2"
    local raw_value="$3"
    local outbound_tag="$4"
    local position="${5:-}"
    local target_tag="${6:-}"
    local values new_rule

    case "${rule_field}" in
    domain | ip | protocol) ;;
    *) return 1 ;;
    esac
    XRAY_CONFIG="${XRAY_CONFIG:-$(jq '.' "${XRAY_CONFIG_PATH}")}" || return 1
    values="$(printf '%s\n' "${raw_value}" | tr ',' '\n' | jq -R 'select(length > 0)' | jq -s 'unique')" || return 1
    [[ "$(printf '%s\n' "${values}" | jq 'length')" -gt 0 ]] || return 1
    new_rule="$(jq -n \
        --arg ruleTag "${rule_tag}" \
        --arg field "${rule_field}" \
        --argjson values "${values}" \
        --arg outboundTag "${outbound_tag}" \
        '{ruleTag:$ruleTag,($field):$values,outboundTag:$outboundTag}')" || return 1

    if printf '%s\n' "${XRAY_CONFIG}" | jq -e --arg tag "${rule_tag}" 'any(.routing.rules[]?; (.ruleTag // "") == $tag)' >/dev/null; then
        XRAY_CONFIG="$(printf '%s\n' "${XRAY_CONFIG}" | jq \
            --arg tag "${rule_tag}" \
            --arg field "${rule_field}" \
            --argjson values "${values}" '
            .routing.rules |= map(
                if (.ruleTag // "") == $tag then
                    .[$field] = (((.[$field] // []) + $values) | unique)
                else . end
            )
        ')" || return 1
        return 0
    fi

    if [[ -n "${target_tag}" ]]; then
        XRAY_CONFIG="$(printf '%s\n' "${XRAY_CONFIG}" | jq \
            --arg target "${target_tag}" \
            --arg position "${position}" \
            --argjson rule "${new_rule}" '
            (.routing.rules | map(.ruleTag // "") | index($target)) as $index |
            if $index == null then .routing.rules += [$rule]
            elif $position == "before" then .routing.rules = (.routing.rules[:$index] + [$rule] + .routing.rules[$index:])
            elif $position == "after" then ($index + 1) as $next | .routing.rules = (.routing.rules[:$next] + [$rule] + .routing.rules[$next:])
            else .routing.rules += [$rule]
            end
        ')" || return 1
    elif [[ "${position}" =~ ^[0-9]+$ ]]; then
        XRAY_CONFIG="$(printf '%s\n' "${XRAY_CONFIG}" | jq \
            --argjson position "${position}" \
            --argjson rule "${new_rule}" \
            '.routing.rules = (.routing.rules[:$position] + [$rule] + .routing.rules[$position:])')" || return 1
    else
        XRAY_CONFIG="$(printf '%s\n' "${XRAY_CONFIG}" | jq --argjson rule "${new_rule}" '.routing.rules += [$rule]')" || return 1
    fi
}

# =============================================================================
# 函数名称: handler_routing
# 功能描述: 处理路由规则配置的处理器。
#           1. 检查 WARP 状态是否满足配置要求。
#           2. 调用 exec_read 读取用户输入的规则值。
#           3. 调用 add_rule 将规则添加到 Xray 配置中。
# 参数:
#   $1: rule_type - 规则类型 ("block" 或 "warp")
#   $2: rule_target - 规则目标 ("ip" 或 "domain")
# 返回值: 无 (通过调用其他函数执行操作)
# 退出码: 如果 WARP 状态不满足要求，则调用 _error 退出脚本 (exit 1)
# =============================================================================
function handler_routing() {
    # 从脚本配置中读取 WARP 状态
    local WARP_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '(.xray.warp // 0) | tonumber? // 0')"
    local rule_type="$1"                         # 获取规则类型 (block/warp)
    local rule_target="$2"                       # 获取规则目标 (ip/domain)
    local rule_tag="${rule_type}-${rule_target}" # 构造规则标签
    local previous_script_config="${SCRIPT_CONFIG}" previous_xray_config
    # 检查 WARP 状态是否满足配置要求
    # 如果是 warp 规则但 WARP 未启用，则报错
    if [[ "${rule_type}" == 'warp' && ${WARP_STATUS} -ne 1 ]]; then
        _error "$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.warp.status")"
    fi
    # 调用 exec_read 读取用户输入的规则值
    exec_read "${rule_tag}" || return 1
    # 调用 add_rule 将规则添加到 Xray 配置中
    previous_xray_config="$(jq '.' "${XRAY_CONFIG_PATH}")" || return 1
    XRAY_CONFIG="${previous_xray_config}"
    add_rule "${rule_tag}" "${rule_target}" "${CONFIG_DATA[${rule_tag}]}" "${rule_type}" || return 1
    local persisted_rules
    persisted_rules="$(printf '%s\n' "${XRAY_CONFIG}" | jq '.routing.rules' | user_route_rules)" || return 1
    SCRIPT_CONFIG="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq --argjson rules "${persisted_rules}" '.rules = $rules')" || return 1
    apply_xray_state_transaction "${previous_script_config}" "${previous_xray_config}"
}

# =============================================================================
# 函数名称: handler_reset_script_config
# 功能描述: 重置脚本配置文件 (config.json) 中指定部分的字段。
#           1. 根据目标配置部分 (xray/nginx) 调用 reset_json_fields。
#           2. 保留特定字段不变，其他字段清空。
#           3. 将重置后的配置写回 SCRIPT_CONFIG_PATH 文件。
# 参数:
#   $1: TARGET_CONFIG - 目标配置部分 ("xray" 或 "nginx")，默认为 "xray"
# 返回值: 无 (直接修改 SCRIPT_CONFIG 全局变量和 SCRIPT_CONFIG_PATH 文件)
# =============================================================================
function handler_reset_script_config() {
    local TARGET_CONFIG="${1:-xray}" # 获取目标配置部分，默认为 xray
    # 根据目标配置部分调用 reset_json_fields 进行重置
    case "${TARGET_CONFIG,,}" in
    xray)
        # 保留 CDN 后端和证书来源，才能在重配过程中安全判断 443
        # 当前由 Nginx 还是 Xray 占用，并复用已验证的证书。
        SCRIPT_CONFIG=$(reset_json_fields "${SCRIPT_CONFIG}" 'xray' \
            'version' 'githubProxy' 'warp' 'rules' 'lan' 'firewallRules' \
            'reverse' 'reverseUuid' 'reversePort' 'reverseTarget' 'reverseMode' \
            'cdnBackend' 'cdnCertHostname' 'cdnCertSource' \
            'cdnCertFullchain' 'cdnCertPrivkey' \
            'cdnDownCertHostname' 'cdnDownCertSource' \
            'cdnDownCertFullchain' 'cdnDownCertPrivkey' \
            'hy2CertAcmeDomain')
        ;;
    nginx)
        # 重置 nginx 部分，保留 version, ca 字段
        SCRIPT_CONFIG=$(reset_json_fields "${SCRIPT_CONFIG}" 'nginx' 'version' 'ca')
        ;;
    esac
    # 将重置后的脚本配置写入文件
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
}

function handler_set_cdn_backend() {
    local requested_backend="${1,,}"

    case "${requested_backend}" in
    nginx | xray) ;;
    *)
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.backend_invalid")" >&2
        return 1
        ;;
    esac

    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq \
        --arg backend "${requested_backend}" '
        .xray.cdnBackend = $backend |
        if $backend == "xray" then .xray.port = 443 else . end
    ')"
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
}

# =============================================================================
# 函数名称: handler_script_config
# 功能描述: 处理并更新脚本配置文件 (config.json)。
#           1. 打印配置更新提示。
#           2. 调用 handler_reset_script_config 重置配置。
#           3. 从 CONFIG_DATA 中获取或生成配置值。
#           4. 根据配置标签 (tag) 更新不同的字段。
#           5. 将更新后的配置写回 SCRIPT_CONFIG_PATH 文件。
# 参数:
#   $1: CONFIG_TAG - 配置标签 (例如 Vision, XHTTP, SNI 等)，默认从 CONFIG_DATA 获取
# 返回值: 无 (直接修改 SCRIPT_CONFIG 全局变量和 SCRIPT_CONFIG_PATH 文件)
# =============================================================================
function handler_script_config() {
    # 打印绿色的配置更新提示
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.script.config_update")" >&2
    # 重置脚本配置 (默认重置 xray 部分)
    handler_reset_script_config
    # 从 CONFIG_DATA 或生成器获取配置值
    # 获取配置标签
    local CONFIG_TAG="${1:-${CONFIG_DATA['tag']}}"
    # 获取规则状态
    local XRAY_RULES_STATUS="${CONFIG_DATA['rules']}"
    # 获取 block bt 状态
    local XRAY_RULES_BT="${CONFIG_DATA['block-bt']}"
    # 获取 block cn 状态
    local XRAY_RULES_CN="${CONFIG_DATA['block-cn']}"
    # 获取 block ad 状态
    local XRAY_RULES_AD="${CONFIG_DATA['block-ad']}"
    if [[ "${CONFIG_TAG,,}" == 'multi' ]]; then
        local MULTI_NODES="${CONFIG_DATA['nodes_json']:-[]}"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg reset "${XRAY_RULES_STATUS,,}" ' if $reset != "n" then .xray.rules.reset = 1 else .xray.rules.reset = 0 end ')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg bt "${XRAY_RULES_BT,,}" ' if $bt != "n" then .xray.rules.bt = 1 else .xray.rules.bt = 0 end ')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg cn "${XRAY_RULES_CN,,}" ' if $cn != "n" then .xray.rules.cn = 1 else .xray.rules.cn = 0 end ')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ad "${XRAY_RULES_AD,,}" ' if $ad != "n" then .xray.rules.ad = 1 else .xray.rules.ad = 0 end ')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg tag "${CONFIG_TAG}" '.xray.tag = $tag')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson nodes "${MULTI_NODES}" '.xray.nodes = $nodes')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.port = ((.xray.nodes[0].port // 443) | tonumber)')"
        if [[ -n "${CONFIG_DATA['vless_enc_enable']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg vlessEncEnable "${CONFIG_DATA['vless_enc_enable']}" '.xray.vlessEncEnable = $vlessEncEnable')"
        fi
        if [[ -n "${CONFIG_DATA['mldsa65_enable']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg mldsa65Enable "${CONFIG_DATA['mldsa65_enable']}" '.xray.mldsa65Enable = $mldsa65Enable')"
        fi
        if [[ -n "${CONFIG_DATA['github_proxy']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg githubProxy "${CONFIG_DATA['github_proxy']}" '.xray.githubProxy = $githubProxy')"
        fi
        if [[ -n "${CONFIG_DATA['vless_enc_decryption']:-}" && -n "${CONFIG_DATA['vless_enc_encryption']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg dec "${CONFIG_DATA['vless_enc_decryption']}" '.xray.vlessEncDecryption = $dec')"
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg enc "${CONFIG_DATA['vless_enc_encryption']}" '.xray.vlessEncEncryption = $enc')"
        fi
        if [[ -n "${CONFIG_DATA['hy2_cert_source']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg cs "${CONFIG_DATA['hy2_cert_source']}" '.xray.hy2CertSource = $cs')"
        fi
        if [[ -n "${CONFIG_DATA['hy2_cert_domain']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg cd "${CONFIG_DATA['hy2_cert_domain']}" '.xray.hy2CertDomain = $cd')"
        fi
        if [[ -n "${CONFIG_DATA['hy2_cert_email']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ce "${CONFIG_DATA['hy2_cert_email']}" '.nginx.ca = $ce')"
        fi
        if [[ -n "${CONFIG_DATA['hy2_cert_fullchain']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg cf "${CONFIG_DATA['hy2_cert_fullchain']}" '.xray.hy2CertFullchain = $cf')"
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ck "${CONFIG_DATA['hy2_cert_privkey']}" '.xray.hy2CertPrivkey = $ck')"
        fi
        write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
        return 0
    fi
    # 获取端口，默认 443
    local XRAY_PORT="${CONFIG_DATA['port']:-443}"
    local XRAY_UUID=''
    local FALLBACK_UUID=''
    local TROJAN_PASSWORD=''
    local KCP_SEED=''
    local XHTTP_PATH=''
    local XHTTP_MODE="${CONFIG_DATA['xhttp-mode']:-auto}"

    protocol_uses_vless_enc "${CONFIG_TAG}" && XRAY_UUID="$(exec_generate '--uuid' "${CONFIG_DATA['uuid']}")"
    [[ "${CONFIG_TAG,,}" == 'fallback' || "${CONFIG_TAG,,}" == 'sni' ]] && FALLBACK_UUID="$(exec_generate '--uuid' "${CONFIG_DATA['fallback']:-}")"
    [[ "${CONFIG_TAG,,}" == 'trojan' ]] && TROJAN_PASSWORD="${CONFIG_DATA['password']:-$(exec_generate '--password')}"
    [[ "${CONFIG_TAG,,}" == 'mkcp' ]] && KCP_SEED="${CONFIG_DATA['seed']:-$(exec_generate '--password')}"
    protocol_uses_xhttp "${CONFIG_TAG}" && XHTTP_PATH="${CONFIG_DATA['path']:-$(exec_generate '--path')}"

    local TARGET_DOMAIN=''
    local NGINX_DOMAIN=''
    local SERVER_NAMES='[]'
    local SHORT_IDS='[]'
    if protocol_uses_reality "${CONFIG_TAG}"; then
        TARGET_DOMAIN="${CONFIG_DATA['target']:-$(exec_generate '--target')}"
        NGINX_DOMAIN="${CONFIG_DATA['domain']:-${TARGET_DOMAIN}}"
        SERVER_NAMES="$(exec_generate '--server-names' "${TARGET_DOMAIN}")"
        SHORT_IDS="$(exec_generate '--short-ids' ${CONFIG_DATA['short_ids']:-'8 8'})"
    fi

    local CDN_DOMAIN="${CONFIG_DATA['cdn']:-}"
    local CDN_DOWN_DOMAIN="${CONFIG_DATA['cdn-down']:-}"
    local CA_EMAIL="${CONFIG_DATA['email']}"
    # 更新脚本配置中的规则状态
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg reset "${XRAY_RULES_STATUS,,}" ' if $reset != "n" then .xray.rules.reset = 1 else .xray.rules.reset = 0 end ')"
    # 更新脚本配置中的 block bt 状态
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg bt "${XRAY_RULES_BT,,}" ' if $bt != "n" then .xray.rules.bt = 1 else .xray.rules.bt = 0 end ')"
    # 更新脚本配置中的 block cn 状态
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg cn "${XRAY_RULES_CN,,}" ' if $cn != "n" then .xray.rules.cn = 1 else .xray.rules.cn = 0 end ')"
    # 更新脚本配置中的 block ad 状态
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ad "${XRAY_RULES_AD,,}" ' if $ad != "n" then .xray.rules.ad = 1 else .xray.rules.ad = 0 end ')"
    # 根据配置标签更新特定字段
    case "${CONFIG_TAG,,}" in
    trojan)
        # 更新 Trojan 密码
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg password "${TROJAN_PASSWORD}" '.xray.trojan = $password')"
        ;;
    hy2)
        # 获取或生成 HY2 auth 密码
        local HY2_AUTH="${CONFIG_DATA['hy2-auth']:-$(exec_generate '--hy2-auth')}"
        # 更新 HY2 auth 密码
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg auth "${HY2_AUTH}" '.xray.hy2auth = $auth')"
        ;;
    ss2022)
        # 获取或生成 SS2022 pre-shared key (32字节Base64格式)
        local SS2022_KEY="${CONFIG_DATA['ss2022-password']:-$(exec_generate '--ss2022-key')}"
        # 更新 SS2022 pre-shared key
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${SS2022_KEY}" '.xray.ss2022Key = $key')"
        ;;
    mkcp | vision | xhttp | fallback | sni | cdn)
        # 更新 UUID
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg uuid "${XRAY_UUID}" '.xray.uuid = $uuid')"
        ;;
    esac
    # 根据配置标签更新特定字段 (第二部分)
    case "${CONFIG_TAG,,}" in
    fallback)
        # 更新 Fallback UUID
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg uuid "${FALLBACK_UUID}" '.xray.fallback = $uuid')"
        ;;
    mkcp)
        # 为 mKCP 生成随机端口并更新 Seed，若用户指定了端口则使用指定的
        if [[ -z "${CONFIG_DATA['port']}" ]]; then
            XRAY_PORT="$(exec_generate '--port')"
        else
            XRAY_PORT="${CONFIG_DATA['port']}"
        fi
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg seed "${KCP_SEED}" '.xray.kcp = $seed')"
        ;;
    hy2)
        # HY2 保存证书来源和证书路径到配置
        if [[ -n "${CONFIG_DATA['hy2_cert_source']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg cs "${CONFIG_DATA['hy2_cert_source']}" '.xray.hy2CertSource = $cs')"
        fi
        if [[ -n "${CONFIG_DATA['hy2_cert_domain']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg cd "${CONFIG_DATA['hy2_cert_domain']}" '.xray.hy2CertDomain = $cd')"
        fi
        if [[ -n "${CONFIG_DATA['hy2_cert_email']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ce "${CONFIG_DATA['hy2_cert_email']}" '.nginx.ca = $ce')"
        fi
        if [[ -n "${CONFIG_DATA['hy2_cert_fullchain']:-}" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg cf "${CONFIG_DATA['hy2_cert_fullchain']}" '.xray.hy2CertFullchain = $cf')"
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ck "${CONFIG_DATA['hy2_cert_privkey']}" '.xray.hy2CertPrivkey = $ck')"
        fi
        ;;
    sni)
        # 更新 Fallback UUID
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg uuid "${FALLBACK_UUID}" '.xray.fallback = $uuid')"
        # 为 SNI 更新 CA 邮箱、域名和 CDN
        [[ -n "${CA_EMAIL}" ]] && SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ca "${CA_EMAIL}" '.nginx.ca = $ca')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg domain "${NGINX_DOMAIN}" '.nginx.domain = $domain')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg cdn "${CDN_DOMAIN}" '.nginx.cdn = $cdn')"
        ;;
    cdn)
        [[ -n "${CA_EMAIL}" ]] && SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ca "${CA_EMAIL}" '.nginx.ca = $ca')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq \
            --arg cdn "${CDN_DOMAIN}" \
            --arg cdnDown "${CDN_DOWN_DOMAIN}" '
            .nginx.cdn = $cdn |
            .nginx.cdnDown = $cdnDown |
            .nginx.certificates //= {} |
            if $cdnDown == "" or ((.nginx.certificates.cdnDown.hostname // "") != $cdnDown) then
                .nginx.certificates.cdnDown = {hostname:"",source:"",fullchain:"",privkey:""}
            else . end |
            if $cdnDown == "" or ((.xray.cdnDownCertHostname // "") != $cdnDown) then
                .xray.cdnDownCertHostname = "" |
                .xray.cdnDownCertSource = "" |
                .xray.cdnDownCertFullchain = "" |
                .xray.cdnDownCertPrivkey = ""
            else . end
        ')"
        # 清理从 Reality/SNI 模式遗留的源站目标，CDN 配置不会使用这些字段。
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '
            .xray.target = "" |
            .xray.serverNames = []
        ')"
        ;;
    esac
    # 根据配置标签更新特定字段 (第三部分)
    case "${CONFIG_TAG,,}" in
    xhttp | trojan | fallback | sni | cdn)
        # 更新路径
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg path "${XHTTP_PATH}" '.xray.path = $path')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg mode "${XHTTP_MODE}" '.xray.xhttpMode = $mode')"
        ;;
    esac
    # 根据配置标签更新特定字段 (第四部分)
    case "${CONFIG_TAG,,}" in
    vision | xhttp | trojan | fallback | sni)
        # 更新目标域名、服务器名称和 Short IDs
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg target "${TARGET_DOMAIN}" '.xray.target = $target')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson serverNames "${SERVER_NAMES}" '.xray.serverNames = $serverNames')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson shortIds "${SHORT_IDS}" '.xray.shortIds = $shortIds')"
        ;;
    esac
    # 更新配置标签和端口
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg tag "${CONFIG_TAG}" '.xray.tag = $tag')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson port "${XRAY_PORT}" '.xray.port = $port')"
    if [[ -n "${CONFIG_DATA['vless_enc_enable']:-}" ]]; then
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg vlessEncEnable "${CONFIG_DATA['vless_enc_enable']}" '.xray.vlessEncEnable = $vlessEncEnable')"
    fi
    if [[ -n "${CONFIG_DATA['mldsa65_enable']:-}" ]]; then
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg mldsa65Enable "${CONFIG_DATA['mldsa65_enable']}" '.xray.mldsa65Enable = $mldsa65Enable')"
    fi
    if [[ -n "${CONFIG_DATA['github_proxy']:-}" ]]; then
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg githubProxy "${CONFIG_DATA['github_proxy']}" '.xray.githubProxy = $githubProxy')"
    fi
    # 若启用了 VLESS enc，写入 decryption/encryption 到脚本配置
    if [[ -n "${CONFIG_DATA['vless_enc_decryption']:-}" && -n "${CONFIG_DATA['vless_enc_encryption']:-}" ]]; then
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg dec "${CONFIG_DATA['vless_enc_decryption']}" '.xray.vlessEncDecryption = $dec')"
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg enc "${CONFIG_DATA['vless_enc_encryption']}" '.xray.vlessEncEncryption = $enc')"
    fi
    # 将更新后的脚本配置写入文件
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
}

# =============================================================================
# 函数名称: handler_x25519_config
# 功能描述: 处理并更新脚本配置文件 (config.json)。
#           1. 获取 X25519 密钥对。
#           2. 将 X25519 密钥对写入 SCRIPT_CONFIG_PATH 文件。
# 参数: 无
# 返回值: 无 (直接修改 SCRIPT_CONFIG 全局变量和 SCRIPT_CONFIG_PATH 文件)
# =============================================================================
function handler_x25519_config() {
    # 打印绿色的配置更新提示
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.script.config_update")" >&2
    # 生成 X25519 密钥对
    local X25519
    if ! X25519="$(exec_generate '--x25519')"; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.x25519.generate_fail")" >&2
        return 1
    fi

    local PRIVATE_KEY PUBLIC_KEY HASH32
    IFS=',' read -r PRIVATE_KEY PUBLIC_KEY HASH32 <<<"${X25519}"
    if [[ -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.x25519.generate_fail")" >&2
        return 1
    fi

    # 更新脚本配置中的私钥和公钥，以及哈希值
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg privateKey "${PRIVATE_KEY}" '.xray.privateKey = $privateKey')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg publicKey "${PUBLIC_KEY}" '.xray.publicKey = $publicKey')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg hash32 "${HASH32}" '.xray.hash32 = $hash32')"
    # 将更新后的脚本配置写入文件
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
    # 私钥只写入受限配置文件，不打印到安装日志。
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.x25519.generated")" >&2
}

# =============================================================================
# 函数名称: handler_mldsa65_config
# 功能描述: 处理并更新脚本配置文件中的 ML-DSA-65 后量子密钥。
#           1. 生成 ML-DSA-65 密钥对（Seed 和 Verify）。
#           2. 将 ML-DSA-65 密钥对写入 SCRIPT_CONFIG_PATH 文件。
# 参数: 无
# 返回值: 无 (直接修改 SCRIPT_CONFIG 全局变量和 SCRIPT_CONFIG_PATH 文件)
# =============================================================================
function handler_mldsa65_config() {
    local enable="${1:-n}"
    local existing_seed="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.mldsa65Seed // ""')"
    local existing_verify="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.mldsa65Verify // ""')"

    if [[ "${enable,,}" != "y" ]]; then
        # 禁用 ML-DSA-65，清除已有密钥
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.mldsa65Enable = "n" | .xray.mldsa65Seed = "" | .xray.mldsa65Verify = ""')"
        write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
        return 0
    fi
    if [[ -n "${existing_seed}" && -n "${existing_verify}" ]]; then
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.mldsa65Enable = "y"')"
        write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
        return 0
    fi
    # 打印绿色的配置更新提示
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.mldsa.generating")" >&2
    # 生成 ML-DSA-65 密钥对
    local MLDSA65
    if ! MLDSA65="$(exec_generate '--mldsa65')"; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.mldsa.generate_fail")" >&2
        return 1
    fi

    local MLDSA65_SEED MLDSA65_VERIFY
    IFS=',' read -r MLDSA65_SEED MLDSA65_VERIFY <<<"${MLDSA65}"
    if [[ -z "${MLDSA65_SEED}" || -z "${MLDSA65_VERIFY}" ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.mldsa.generate_fail")" >&2
        return 1
    fi

    # 更新脚本配置中的 ML-DSA-65 密钥
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq \
        --arg seed "${MLDSA65_SEED}" \
        --arg verify "${MLDSA65_VERIFY}" '
        .xray.mldsa65Enable = "y" |
        .xray.mldsa65Seed = $seed |
        .xray.mldsa65Verify = $verify
    ')"
    # 将更新后的脚本配置写入文件
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
    # Seed 是服务端私密材料，不打印到终端。
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.mldsa.generated")" >&2
}

function configured_mldsa65_enable() {
    local configured="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.mldsa65Enable // ""')"
    local existing_seed="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.mldsa65Seed // ""')"
    local existing_verify="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.mldsa65Verify // ""')"

    case "${configured,,}" in
    y | n)
        echo "${configured,,}"
        ;;
    *)
        if [[ -n "${existing_seed}" && -n "${existing_verify}" ]]; then
            echo 'y'
        else
            echo 'n'
        fi
        ;;
    esac
}

function handler_reality_key_config() {
    handler_x25519_config || return 1
    handler_mldsa65_config "$(configured_mldsa65_enable)" || return 1
}

# =============================================================================
# 函数名称: handler_xray_config
# 功能描述: 处理并更新 Xray 核心配置文件 (/usr/local/etc/xray/config.json)。
#           1. 打印配置更新提示。
#           2. 从脚本配置中读取各项参数。
#           3. 加载对应配置标签的模板文件。
#           4. 根据配置标签和参数替换模板中的占位符。
#           5. 处理路由规则 (保留当前规则或重置并添加默认规则)。
#           6. 将更新后的配置写回 XRAY_CONFIG_PATH 和 SCRIPT_CONFIG_PATH 文件。
# 参数: 无
# 返回值: 无 (直接修改 XRAY_CONFIG 全局变量和 XRAY_CONFIG_PATH/SCRIPT_CONFIG_PATH 文件)
# =============================================================================
function open_xray_firewall_port() {
    local port="$1"
    local protocol="$2"
    local firewall_ok=0
    local ufw_available=0
    local firewalld_available=0
    local firewalld_rule_preexisting=0
    local firewalld_query_status=0
    local ufw_status=''
    local firewalld_status=''

    [[ -z "${port}" || -z "${protocol}" ]] && return 0

    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.firewall_open") ${port}/${protocol}" >&2
    if command -v ufw &>/dev/null; then
        ufw_available=1
        ufw_status="$(ufw status 2>/dev/null || true)"
    fi
    if command -v firewall-cmd &>/dev/null; then
        firewalld_available=1
        firewalld_status="$(firewall-cmd --state 2>/dev/null || true)"
    fi

    if [[ "${ufw_available}" -eq 1 ]] && grep -Eiq '^Status:[[:space:]]+active([[:space:]]|$)' <<<"${ufw_status}"; then
        ufw allow "${port}"/"${protocol}" >/dev/null 2>&1 && firewall_ok=1
    elif [[ "${firewalld_available}" -eq 1 && "${firewalld_status,,}" == 'running' ]]; then
        firewall-cmd --permanent --query-port="${port}"/"${protocol}" >/dev/null 2>&1
        firewalld_query_status=$?
        case "${firewalld_query_status}" in
        0) firewalld_rule_preexisting=1 ;;
        1) firewalld_rule_preexisting=0 ;;
        *) return 1 ;;
        esac
        if firewall-cmd --permanent --add-port="${port}"/"${protocol}" >/dev/null 2>&1; then
            if firewall-cmd --reload >/dev/null 2>&1; then
                firewall_ok=1
            elif [[ "${firewalld_rule_preexisting}" -eq 0 ]]; then
                firewall-cmd --permanent --remove-port="${port}"/"${protocol}" >/dev/null 2>&1 || true
                firewall-cmd --reload >/dev/null 2>&1 || true
            fi
        fi
    elif [[ "${ufw_available}" -eq 1 || "${firewalld_available}" -eq 1 ]]; then
        echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.firewall_inactive")" >&2
        return 0
    elif command -v iptables &>/dev/null; then
        if iptables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null ||
            iptables -I INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
            firewall_ok=1
        fi
        if command -v ip6tables &>/dev/null; then
            ip6tables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null ||
                ip6tables -I INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null || true
        fi
    else
        echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.firewall_skip")" >&2
        return 0
    fi

    if [[ "${firewall_ok}" -ne 1 ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.firewall_fail") ${port}/${protocol}" >&2
        return 1
    fi

    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.firewall_ok")" >&2
}

function owned_firewall_rule_exists() {
    local rule="$1"
    local backend port protocol ipv4 ipv6 status
    backend="$(echo "${rule}" | jq -er '.backend')" || return 2
    port="$(echo "${rule}" | jq -er '.port')" || return 2
    protocol="$(echo "${rule}" | jq -er '.protocol')" || return 2
    ipv4="$(echo "${rule}" | jq -er '.ipv4')" || return 2
    ipv6="$(echo "${rule}" | jq -er '.ipv6')" || return 2

    case "${backend}" in
    ufw)
        command -v ufw &>/dev/null || return 2
        status="$(ufw show added 2>/dev/null)" || return 2
        grep -Eq "^ufw allow ${port}/${protocol}([[:space:]]|$)" <<<"${status}"
        ;;
    firewalld)
        command -v firewall-cmd &>/dev/null || return 2
        [[ "$(firewall-cmd --state 2>/dev/null)" == 'running' ]] || return 2
        firewall-cmd --permanent --query-port="${port}"/"${protocol}" >/dev/null 2>&1
        ;;
    iptables)
        local present=1
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

function remove_owned_firewall_rule_fields() {
    local backend="$1"
    local port="$2"
    local protocol="$3"
    local ipv4="$4"
    local ipv6="$5"
    case "${backend}" in
    ufw)
        command -v ufw &>/dev/null || return 1
        if ufw show added 2>/dev/null |
            grep -Eq "^ufw allow ${port}/${protocol}([[:space:]]|$)"; then
            ufw delete allow "${port}"/"${protocol}" >/dev/null 2>&1
        fi
        ;;
    firewalld)
        command -v firewall-cmd &>/dev/null || return 1
        [[ "$(firewall-cmd --state 2>/dev/null)" == 'running' ]] || return 1
        if firewall-cmd --permanent --query-port="${port}"/"${protocol}" >/dev/null 2>&1; then
            firewall-cmd --permanent --remove-port="${port}"/"${protocol}" >/dev/null 2>&1 &&
                firewall-cmd --reload >/dev/null 2>&1
        fi
        ;;
    iptables)
        if [[ "${ipv4}" == 'true' ]]; then
            command -v iptables &>/dev/null || return 1
            if iptables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
                iptables -D INPUT -p "${protocol}" --dport "${port}" -j ACCEPT >/dev/null 2>&1 || return 1
            fi
        fi
        if [[ "${ipv6}" == 'true' ]]; then
            command -v ip6tables &>/dev/null || return 1
            if ip6tables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
                ip6tables -D INPUT -p "${protocol}" --dport "${port}" -j ACCEPT >/dev/null 2>&1 || return 1
            fi
        fi
        ;;
    *) return 1 ;;
    esac
}

function remove_owned_firewall_rule() {
    local rule="$1"
    local backend port protocol ipv4 ipv6
    backend="$(echo "${rule}" | jq -er '.backend')" || return 1
    port="$(echo "${rule}" | jq -er '.port')" || return 1
    protocol="$(echo "${rule}" | jq -er '.protocol')" || return 1
    ipv4="$(echo "${rule}" | jq -er '.ipv4')" || return 1
    ipv6="$(echo "${rule}" | jq -er '.ipv6')" || return 1
    remove_owned_firewall_rule_fields \
        "${backend}" "${port}" "${protocol}" "${ipv4}" "${ipv6}"
}

function restore_owned_firewall_rule() {
    local rule="$1"
    local backend port protocol ipv4 ipv6 status
    backend="$(echo "${rule}" | jq -er '.backend')" || return 1
    port="$(echo "${rule}" | jq -er '.port')" || return 1
    protocol="$(echo "${rule}" | jq -er '.protocol')" || return 1
    ipv4="$(echo "${rule}" | jq -er '.ipv4')" || return 1
    ipv6="$(echo "${rule}" | jq -er '.ipv6')" || return 1

    case "${backend}" in
    ufw)
        command -v ufw &>/dev/null || return 1
        status="$(ufw show added 2>/dev/null)" || return 1
        grep -Eq "^ufw allow ${port}/${protocol}([[:space:]]|$)" <<<"${status}" ||
            ufw allow "${port}"/"${protocol}" >/dev/null 2>&1
        ;;
    firewalld)
        command -v firewall-cmd &>/dev/null || return 1
        [[ "$(firewall-cmd --state 2>/dev/null)" == 'running' ]] || return 1
        if ! firewall-cmd --permanent --query-port="${port}"/"${protocol}" >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port="${port}"/"${protocol}" >/dev/null 2>&1 &&
                firewall-cmd --reload >/dev/null 2>&1
        fi
        ;;
    iptables)
        if [[ "${ipv4}" == 'true' ]]; then
            command -v iptables &>/dev/null || return 1
            iptables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null ||
                iptables -I INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null || return 1
        fi
        if [[ "${ipv6}" == 'true' ]]; then
            command -v ip6tables &>/dev/null || return 1
            ip6tables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null ||
                ip6tables -I INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null || return 1
        fi
        ;;
    *) return 1 ;;
    esac
}

function restore_owned_firewall_rules() {
    local rule restore_status=0
    for rule in "$@"; do
        restore_owned_firewall_rule "${rule}" || restore_status=1
    done
    return "${restore_status}"
}

function open_owned_firewall_port() {
    local feature="$1"
    local port="$2"
    local protocol="$3"
    local backend='' ipv4=false ipv6=false rule existing_rule
    local ufw_status firewalld_status previous_script_config updated_script_config

    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    port=$((10#${port}))
    ((port >= 1 && port <= 65535)) || return 1
    [[ "${protocol}" =~ ^(tcp|udp)$ ]] || return 1
    existing_rule="$(echo "${SCRIPT_CONFIG}" | jq -cr \
        --arg feature "${feature}" --argjson port "${port}" --arg protocol "${protocol}" \
        '[.xray.firewallRules[]? | select(.feature == $feature and .port == $port and .protocol == $protocol)][0] // empty')" ||
        return 1
    if [[ -n "${existing_rule}" ]]; then
        restore_owned_firewall_rule "${existing_rule}"
        return $?
    fi

    if command -v ufw &>/dev/null; then
        ufw_status="$(ufw status 2>/dev/null || true)"
        if grep -Eiq '^Status:[[:space:]]+active([[:space:]]|$)' <<<"${ufw_status}"; then
            if grep -Eq "^${port}/${protocol}[[:space:]]+ALLOW([[:space:]]|$)" <<<"${ufw_status}"; then
                return 0
            fi
            ufw allow "${port}"/"${protocol}" >/dev/null 2>&1 || return 1
            backend='ufw'
        else
            return 0
        fi
    elif command -v firewall-cmd &>/dev/null; then
        firewalld_status="$(firewall-cmd --state 2>/dev/null || true)"
        [[ "${firewalld_status,,}" == 'running' ]] || return 0
        if firewall-cmd --permanent --query-port="${port}"/"${protocol}" >/dev/null 2>&1; then
            return 0
        fi
        firewall-cmd --permanent --add-port="${port}"/"${protocol}" >/dev/null 2>&1 || return 1
        if ! firewall-cmd --reload >/dev/null 2>&1; then
            firewall-cmd --permanent --remove-port="${port}"/"${protocol}" >/dev/null 2>&1 || true
            return 1
        fi
        backend='firewalld'
    elif command -v iptables &>/dev/null; then
        if ! iptables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null || return 1
            ipv4=true
        fi
        if command -v ip6tables &>/dev/null &&
            ! ip6tables -C INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
            if ip6tables -I INPUT -p "${protocol}" --dport "${port}" -j ACCEPT 2>/dev/null; then
                ipv6=true
            fi
        fi
        [[ "${ipv4}" == 'true' || "${ipv6}" == 'true' ]] || return 0
        backend='iptables'
    else
        return 0
    fi

    rule="$(jq -n \
        --arg feature "${feature}" --arg backend "${backend}" \
        --argjson port "${port}" --arg protocol "${protocol}" \
        --argjson ipv4 "${ipv4}" --argjson ipv6 "${ipv6}" \
        '{feature:$feature,backend:$backend,port:$port,protocol:$protocol,ipv4:$ipv4,ipv6:$ipv6}')" || {
        remove_owned_firewall_rule_fields \
            "${backend}" "${port}" "${protocol}" "${ipv4}" "${ipv6}" || true
        return 1
    }
    previous_script_config="${SCRIPT_CONFIG}"
    updated_script_config="$(echo "${SCRIPT_CONFIG}" | jq --argjson rule "${rule}" '
        .xray.firewallRules = ((.xray.firewallRules // []) + [$rule] | unique_by([.feature,.port,.protocol]))
    ')" || {
        remove_owned_firewall_rule "${rule}" || true
        SCRIPT_CONFIG="${previous_script_config}"
        return 1
    }
    SCRIPT_CONFIG="${updated_script_config}"
    if ! write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"; then
        if remove_owned_firewall_rule "${rule}"; then
            SCRIPT_CONFIG="${previous_script_config}"
        else
            # Keep the ownership record in memory so the outer state
            # transaction can retry removal or persist the unresolved rule.
            SCRIPT_CONFIG="${updated_script_config}"
        fi
        return 1
    fi
}

function close_owned_firewall_ports() {
    local feature="$1"
    local port="${2:-}"
    local defer_write="${3:-0}"
    local records rule existence_status updated_script_config
    local previous_script_config="${SCRIPT_CONFIG}"
    local -a removed_rules=()
    records="$(echo "${SCRIPT_CONFIG}" | jq -c \
        --arg feature "${feature}" --arg port "${port}" '
        [.xray.firewallRules[]? | select(.feature == $feature and ($port == "" or (.port | tostring) == $port))]
    ')" || return 1

    while IFS= read -r rule; do
        [[ -n "${rule}" ]] || continue
        if owned_firewall_rule_exists "${rule}"; then
            remove_owned_firewall_rule "${rule}" || {
                restore_owned_firewall_rule "${rule}" ||
                    echo 'Firewall rollback failed for the current owned port.' >&2
                restore_owned_firewall_rules "${removed_rules[@]}" ||
                    echo 'Firewall rollback failed while closing owned ports.' >&2
                return 1
            }
            removed_rules+=("${rule}")
        else
            existence_status=$?
            if [[ "${existence_status}" -eq 2 ]]; then
                restore_owned_firewall_rules "${removed_rules[@]}" ||
                    echo 'Firewall rollback failed while closing owned ports.' >&2
                return 1
            fi
        fi
    done < <(echo "${records}" | jq -c '.[]')
    updated_script_config="$(echo "${SCRIPT_CONFIG}" | jq \
        --arg feature "${feature}" --arg port "${port}" '
        .xray.firewallRules = [
            .xray.firewallRules[]? |
            select(.feature != $feature or ($port != "" and (.port | tostring) != $port))
        ]
    ')" || {
        restore_owned_firewall_rules "${removed_rules[@]}" ||
            echo 'Firewall rollback failed after state update failure.' >&2
        return 1
    }
    SCRIPT_CONFIG="${updated_script_config}"
    if [[ "${defer_write}" -eq 1 ]]; then
        return 0
    fi
    if ! write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"; then
        SCRIPT_CONFIG="${previous_script_config}"
        restore_owned_firewall_rules "${removed_rules[@]}" ||
            echo 'Firewall rollback failed after configuration write failure.' >&2
        return 1
    fi
}

function restore_owned_firewall_feature_state() {
    local previous_script_config="$1"
    local feature="$2"
    local port="$3"
    local protocol="$4"
    local restore_status=0

    SCRIPT_CONFIG="${previous_script_config}"
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || restore_status=1
    open_owned_firewall_port "${feature}" "${port}" "${protocol}" || restore_status=1
    if [[ "${restore_status}" -ne 0 ]]; then
        echo "Failed to restore ${feature} firewall ownership state." >&2
    fi
    return "${restore_status}"
}

function multi_upsert_route_rule() {
    local rule="$1"

    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson new_rule "${rule}" '
        if any(.routing.rules[]?; .ruleTag == $new_rule.ruleTag) then
            .routing.rules |= map(if .ruleTag == $new_rule.ruleTag then $new_rule else . end)
        else
            (.routing.rules | map(.ruleTag) | index("private-ip")) as $private_index |
            if $private_index == null then
                .routing.rules += [$new_rule]
            else
                .routing.rules = (.routing.rules[:$private_index] + [$new_rule] + .routing.rules[$private_index:])
            end
        end
    ')" || return 1
}

function multi_add_optional_block_rules() {
    local XRAY_RULES_BT="$1"
    local XRAY_RULES_CN="$2"
    local XRAY_RULES_AD="$3"
    local new_rule

    if [[ "${XRAY_RULES_BT}" -eq 1 ]]; then
        new_rule="$(jq -n '{ruleTag:"bt",protocol:["bittorrent"],outboundTag:"block"}')" || return 1
        multi_upsert_route_rule "${new_rule}" || return 1
    fi
    if [[ "${XRAY_RULES_CN}" -eq 1 ]]; then
        new_rule="$(jq -n '{ruleTag:"cn-ip",ip:["geoip:cn"],outboundTag:"block"}')" || return 1
        multi_upsert_route_rule "${new_rule}" || return 1
    fi
    if [[ "${XRAY_RULES_AD}" -eq 1 ]]; then
        new_rule="$(jq -n '{ruleTag:"ad-domain",domain:["geosite:category-ads-all"],outboundTag:"block"}')" || return 1
        multi_upsert_route_rule "${new_rule}" || return 1
    fi
}

function handler_multi_firewall_ports() {
    local nodes="$(echo "${SCRIPT_CONFIG}" | jq -c '.xray.nodes // []')"
    local node_count="$(echo "${nodes}" | jq 'length')"
    local i

    for ((i = 0; i < node_count; i++)); do
        local node="$(echo "${nodes}" | jq -c --argjson i "${i}" '.[$i]')"
        local node_tag="$(echo "${node}" | jq -r '.tag | ascii_downcase')"
        local node_port="$(echo "${node}" | jq -r '.port')"

        case "${node_tag}" in
        vision | xhttp | trojan | fallback)
            open_xray_firewall_port "${node_port}" tcp || return 1
            ;;
        mkcp | hy2)
            open_xray_firewall_port "${node_port}" udp || return 1
            ;;
        ss2022)
            open_xray_firewall_port "${node_port}" tcp || return 1
            open_xray_firewall_port "${node_port}" udp || return 1
            ;;
        esac
    done
}

function handler_multi_xray_config() {
    local skip_vlessenc="${1:-0}"
    local nodes="$(echo "${SCRIPT_CONFIG}" | jq -c '.xray.nodes // []')"
    local node_count="$(echo "${nodes}" | jq 'length')"
    local PRIVATE_KEY="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.privateKey // ""')"
    local MLDSA65_SEED="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.mldsa65Seed // ""')"
    local XRAY_RULES_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.reset')"
    local XRAY_RULES_BT="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.bt')"
    local XRAY_RULES_CN="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.cn')"
    local XRAY_RULES_AD="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.ad')"
    local XRAY_RULES
    XRAY_RULES="$(echo "${SCRIPT_CONFIG}" | jq '.rules // []' | user_route_rules)" || return 1
    local WARP_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.warp')"
    local VLESS_ENC_DECRYPTION="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.vlessEncDecryption // ""')"
    local VLESS_ENC_ENCRYPTION="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.vlessEncEncryption // ""')"
    local VLESS_ENC_ENABLE="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.vlessEncEnable // ""')"

    if [[ "${node_count}" -eq 0 ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.multi.no_nodes")" >&2
        return 1
    fi

    if [[ "${skip_vlessenc}" != "1" ]]; then
        if [[ "${VLESS_ENC_ENABLE}" == "y" ]]; then
            if [[ -z "${VLESS_ENC_DECRYPTION}" || -z "${VLESS_ENC_ENCRYPTION}" ]]; then
                run_vlessenc_prompt 1
                if [[ -n "${CONFIG_DATA['vless_enc_decryption']:-}" && -n "${CONFIG_DATA['vless_enc_encryption']:-}" ]]; then
                    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq \
                        --arg dec "${CONFIG_DATA['vless_enc_decryption']}" \
                        --arg enc "${CONFIG_DATA['vless_enc_encryption']}" '
                        .xray.vlessEncDecryption = $dec |
                        .xray.vlessEncEncryption = $enc
                    ')"
                    VLESS_ENC_DECRYPTION="${CONFIG_DATA['vless_enc_decryption']}"
                else
                    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.vlessEncDecryption = "" | .xray.vlessEncEncryption = ""')"
                    VLESS_ENC_DECRYPTION=""
                fi
            fi
        elif [[ "${VLESS_ENC_ENABLE}" == "n" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.vlessEncDecryption = "" | .xray.vlessEncEncryption = ""')"
            VLESS_ENC_DECRYPTION=""
        fi
    fi

    XRAY_CONFIG="$(jq '.inbounds = [.inbounds[0]]' "${SCRIPT_XRAY_DIR}/XHTTP.json")" || return 1
    if [[ "${XRAY_RULES_STATUS}" -eq 0 ]]; then
        merge_user_route_rules "${XRAY_RULES}" || return 1
    fi

    local used_listen_ports=("32768")
    local i
    for ((i = 0; i < node_count; i++)); do
        local configured_port
        configured_port="$(echo "${nodes}" | jq -r --argjson i "${i}" '.[$i].port // empty')"
        [[ -n "${configured_port}" ]] && used_listen_ports+=("${configured_port}")
    done

    for ((i = 0; i < node_count; i++)); do
        local suffix="$((i + 1))"
        local node="$(echo "${nodes}" | jq -c --argjson i "${i}" '.[$i]')"
        local node_tag="$(echo "${node}" | jq -r '.tag')"
        local node_tag_lower="${node_tag,,}"
        local node_port="$(echo "${node}" | jq -r '.port')"
        local node_inbounds

        node_inbounds="$(jq '.inbounds[1:]' "${SCRIPT_XRAY_DIR}/${node_tag}.json")"
        node_inbounds="$(echo "${node_inbounds}" | jq --arg suffix "${suffix}" --argjson port "${node_port}" '
            map(.tag = (.tag + "-" + $suffix)) | .[0].port = $port
        ')"

        if [[ -n "${VLESS_ENC_DECRYPTION}" ]]; then
            node_inbounds="$(echo "${node_inbounds}" | jq --arg dec "${VLESS_ENC_DECRYPTION}" '
                map(
                    if .protocol? == "vless" and
                        (.settings.decryption? != null) and
                        ((.settings | has("fallbacks")) | not)
                    then .settings.decryption = $dec
                    else .
                    end
                )
            ')"
        fi

        case "${node_tag_lower}" in
        mkcp)
            local node_uuid="$(echo "${node}" | jq -r '.uuid')"
            local kcp_seed="$(echo "${node}" | jq -r '.kcp')"
            node_inbounds="$(echo "${node_inbounds}" | jq --arg uuid "${node_uuid}" --arg seed "${kcp_seed}" '
                .[0].settings.clients[0].id = $uuid |
                .[0].streamSettings.finalmask.udp[0].settings.password = $seed
            ')"
            ;;
        vision)
            local node_uuid="$(echo "${node}" | jq -r '.uuid')"
            local node_target="$(echo "${node}" | jq -r '.target')"
            local server_names="$(echo "${node}" | jq -c '.serverNames // []')"
            local short_ids="$(echo "${node}" | jq -c '.shortIds // [""]')"
            local anti_port=$((32768 + suffix))
            while port_in_list "${anti_port}" "${used_listen_ports[@]}"; do
                anti_port=$((anti_port + 1))
            done
            used_listen_ports+=("${anti_port}")
            node_inbounds="$(echo "${node_inbounds}" | jq \
                --arg uuid "${node_uuid}" \
                --arg target "${node_target}" \
                --argjson serverNames "${server_names}" \
                --arg privateKey "${PRIVATE_KEY}" \
                --argjson shortIds "${short_ids}" \
                --arg seed "${MLDSA65_SEED}" \
                --argjson antiPort "${anti_port}" '
                .[0].settings.clients[0].id = $uuid |
                .[0].streamSettings.realitySettings.dest = ("127.0.0.1:" + ($antiPort | tostring)) |
                .[0].streamSettings.realitySettings.serverNames = $serverNames |
                .[0].streamSettings.realitySettings.privateKey = $privateKey |
                .[0].streamSettings.realitySettings.shortIds = $shortIds |
                (if $seed != "" then .[0].streamSettings.realitySettings.mldsa65Seed = $seed else . end) |
                .[1].port = $antiPort |
                .[1].settings.address = $target
            ')"

            local anti_in_tag="$(echo "${node_inbounds}" | jq -r '.[1].tag')"
            local allow_rule block_rule
            allow_rule="$(jq -n --arg ruleTag "anti-steal-allow-${suffix}" --arg inboundTag "${anti_in_tag}" --argjson domains "${server_names}" '{ruleTag:$ruleTag,inboundTag:[$inboundTag],domain:$domains,outboundTag:"direct"}')" || return 1
            block_rule="$(jq -n --arg ruleTag "anti-steal-block-${suffix}" --arg inboundTag "${anti_in_tag}" '{ruleTag:$ruleTag,inboundTag:[$inboundTag],outboundTag:"block"}')" || return 1
            multi_upsert_route_rule "${allow_rule}" || return 1
            multi_upsert_route_rule "${block_rule}" || return 1
            ;;
        xhttp)
            local node_uuid="$(echo "${node}" | jq -r '.uuid')"
            local node_target="$(echo "${node}" | jq -r '.target')"
            local server_names="$(echo "${node}" | jq -c '.serverNames // []')"
            local short_ids="$(echo "${node}" | jq -c '.shortIds // [""]')"
            local xhttp_path="$(echo "${node}" | jq -r '.path')"
            local xhttp_mode="$(echo "${node}" | jq -r '.xhttpMode // "auto"')"
            node_inbounds="$(echo "${node_inbounds}" | jq \
                --arg uuid "${node_uuid}" \
                --arg target "${node_target}:443" \
                --argjson serverNames "${server_names}" \
                --arg privateKey "${PRIVATE_KEY}" \
                --argjson shortIds "${short_ids}" \
                --arg seed "${MLDSA65_SEED}" \
                --arg path "${xhttp_path}" \
                --arg mode "${xhttp_mode}" '
                .[0].settings.clients[0].id = $uuid |
                .[0].streamSettings.realitySettings.target = $target |
                .[0].streamSettings.realitySettings.serverNames = $serverNames |
                .[0].streamSettings.realitySettings.privateKey = $privateKey |
                .[0].streamSettings.realitySettings.shortIds = $shortIds |
                (if $seed != "" then .[0].streamSettings.realitySettings.mldsa65Seed = $seed else . end) |
                .[0].streamSettings.xhttpSettings.path = $path |
                .[0].streamSettings.xhttpSettings.mode = $mode
            ')"
            ;;
        trojan)
            local trojan_password="$(echo "${node}" | jq -r '.trojan')"
            local node_target="$(echo "${node}" | jq -r '.target')"
            local server_names="$(echo "${node}" | jq -c '.serverNames // []')"
            local short_ids="$(echo "${node}" | jq -c '.shortIds // [""]')"
            local xhttp_path="$(echo "${node}" | jq -r '.path')"
            local xhttp_mode="$(echo "${node}" | jq -r '.xhttpMode // "auto"')"
            node_inbounds="$(echo "${node_inbounds}" | jq \
                --arg password "${trojan_password}" \
                --arg target "${node_target}:443" \
                --argjson serverNames "${server_names}" \
                --arg privateKey "${PRIVATE_KEY}" \
                --argjson shortIds "${short_ids}" \
                --arg seed "${MLDSA65_SEED}" \
                --arg path "${xhttp_path}" \
                --arg mode "${xhttp_mode}" '
                .[0].settings.clients[0].password = $password |
                .[0].streamSettings.realitySettings.target = $target |
                .[0].streamSettings.realitySettings.serverNames = $serverNames |
                .[0].streamSettings.realitySettings.privateKey = $privateKey |
                .[0].streamSettings.realitySettings.shortIds = $shortIds |
                (if $seed != "" then .[0].streamSettings.realitySettings.mldsa65Seed = $seed else . end) |
                .[0].streamSettings.xhttpSettings.path = $path |
                .[0].streamSettings.xhttpSettings.mode = $mode
            ')"
            ;;
        fallback)
            local node_uuid="$(echo "${node}" | jq -r '.uuid')"
            local fallback_uuid="$(echo "${node}" | jq -r '.fallback')"
            local node_target="$(echo "${node}" | jq -r '.target')"
            local server_names="$(echo "${node}" | jq -c '.serverNames // []')"
            local short_ids="$(echo "${node}" | jq -c '.shortIds // [""]')"
            local xhttp_path="$(echo "${node}" | jq -r '.path')"
            local xhttp_mode="$(echo "${node}" | jq -r '.xhttpMode // "auto"')"
            local uds_name="@uds2xhttp-${suffix}.sock"
            node_inbounds="$(echo "${node_inbounds}" | jq \
                --arg uuid "${node_uuid}" \
                --arg fallback "${fallback_uuid}" \
                --arg target "${node_target}:443" \
                --argjson serverNames "${server_names}" \
                --arg privateKey "${PRIVATE_KEY}" \
                --argjson shortIds "${short_ids}" \
                --arg seed "${MLDSA65_SEED}" \
                --arg path "${xhttp_path}" \
                --arg mode "${xhttp_mode}" \
                --arg uds "${uds_name}" '
                .[0].settings.clients[0].id = $uuid |
                .[0].settings.fallbacks[0].dest = $uds |
                .[0].streamSettings.realitySettings.target = $target |
                .[0].streamSettings.realitySettings.serverNames = $serverNames |
                .[0].streamSettings.realitySettings.privateKey = $privateKey |
                .[0].streamSettings.realitySettings.shortIds = $shortIds |
                (if $seed != "" then .[0].streamSettings.realitySettings.mldsa65Seed = $seed else . end) |
                .[1].settings.clients[0].id = $fallback |
                .[1].listen = $uds |
                .[1].streamSettings.xhttpSettings.path = $path |
                .[1].streamSettings.xhttpSettings.mode = $mode
            ')"
            ;;
        hy2)
            local hy2_auth="$(echo "${node}" | jq -r '.hy2auth')"
            local hy2_cert_dir=''
            hy2_cert_dir="$(get_hy2_cert_dir \
                "$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertDomain // ""')" \
                "$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertSource // ""')")" ||
                return 1
            local HY2_FULLCHAIN="${hy2_cert_dir}/fullchain.pem"
            local HY2_PRIVKEY="${hy2_cert_dir}/privkey.pem"
            node_inbounds="$(echo "${node_inbounds}" | jq --arg auth "${hy2_auth}" --arg cert "${HY2_FULLCHAIN}" --arg key "${HY2_PRIVKEY}" '
                if (.[0].settings.clients? | type) == "array" then .[0].settings.clients[0].auth = $auth
                elif (.[0].settings.users? | type) == "array" then .[0].settings.users[0].auth = $auth
                else .[0].settings.clients = [{auth:$auth,level:0,email:"hy2@xray.hysteria"}] end |
                .[0].streamSettings.hysteriaSettings.auth = $auth |
                .[0].streamSettings.tlsSettings.certificates[0].certificateFile = $cert |
                .[0].streamSettings.tlsSettings.certificates[0].keyFile = $key
            ')"
            ;;
        ss2022)
            local ss2022_key="$(echo "${node}" | jq -r '.ss2022Key')"
            node_inbounds="$(echo "${node_inbounds}" | jq --arg key "${ss2022_key}" '.[0].settings.password = $key')"
            ;;
        esac

        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson node_inbounds "${node_inbounds}" '.inbounds += $node_inbounds')"
    done

    if [[ "${XRAY_RULES_STATUS}" -eq 1 ]]; then
        multi_add_optional_block_rules "${XRAY_RULES_BT}" "${XRAY_RULES_CN}" "${XRAY_RULES_AD}" || return 1
    fi

    if [[ "${WARP_STATUS:-0}" -eq 1 ]]; then
        local container_ip=''
        container_ip="$(exec_docker '--obtain-container-ip')" || return 1
        [[ -n "${container_ip}" ]] || return 1
        local socks_config
        socks_config="$(jq -n --arg address "${container_ip}" '[{tag:"warp",protocol:"socks",settings:{servers:[{address:$address,port:40001}]}}]')" || return 1
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson socks_config "${socks_config}" '.outbounds += $socks_config')"
    fi

    local reverse_status=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.reverse // 0')
    if [[ "${reverse_status}" -eq 1 ]]; then
        handler_reverse_config || return 1
    fi
    handler_apply_lan_config || return 1

    XRAY_RULES="$(echo "${XRAY_CONFIG}" | jq '.routing.rules' | user_route_rules)" || return 1
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson rules "${XRAY_RULES}" '.rules = $rules')" || return 1
    commit_xray_and_script_config "${XRAY_CONFIG}" "${SCRIPT_CONFIG}" || return 1
    handler_multi_firewall_ports || return 1

    handler_lan_open_firewall || return 1
    if [[ "${reverse_status}" -eq 1 ]]; then
        local reverse_port=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.reversePort // 8443')
        open_owned_firewall_port 'reverse' "${reverse_port}" tcp || return 1
    fi
}

function handler_xray_config() {
    local skip_vlessenc="${1:-0}"
    # 打印绿色的 Xray 配置更新提示
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.xray.config_update")" >&2
    normalize_and_validate_xray_state || return 1
    # 从脚本配置中读取各项参数
    local CONFIG_TAG="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag')"                # 获取配置标签
    local XRAY_PORT="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.port')"                 # 获取端口
    local XRAY_UUID="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.uuid // ""')"          # 获取 UUID
    local HY2_AUTH="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2auth // ""')"        # 获取 HY2 auth
    local FALLBACK_UUID="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.fallback // ""')"  # 获取 Fallback UUID
    local TROJAN_PASSWORD="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.trojan // ""')" # 获取 Trojan 密码
    local KCP_SEED="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.kcp // ""')"            # 获取 mKCP Seed
    local TARGET_DOMAIN="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.target // ""')"    # 获取目标域名
    local SERVER_NAMES="$(echo "${SCRIPT_CONFIG}" | jq -c '.xray.serverNames // []')" # 获取服务器名称
    local PRIVATE_KEY="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.privateKey // ""')"  # 获取私钥
    local SHORT_IDS="$(echo "${SCRIPT_CONFIG}" | jq -c '.xray.shortIds // []')"       # 获取 Short IDs
    local MLDSA65_SEED="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.mldsa65Seed // ""')" # 获取 ML-DSA-65 Seed
    local XHTTP_PATH="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.path // ""')"         # 获取路径
    local XHTTP_MODE="$(echo "${SCRIPT_CONFIG}" | jq -r '(.xray.xhttpMode // "") | if . == "" then "auto" else . end')"
    local XRAY_RULES_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.reset')" # 获取规则状态
    local XRAY_RULES_BT="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.bt')"        # 获取 bt 规则状态
    local XRAY_RULES_CN="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.cn')"        # 获取 cn 规则状态
    local XRAY_RULES_AD="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.rules.ad')"        # 获取 ad 规则状态
    local XRAY_RULES
    XRAY_RULES="$(echo "${SCRIPT_CONFIG}" | jq '.rules // []' | user_route_rules)" || return 1
    local WARP_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.warp')"              # 获取 WARP 状态
    local VLESS_ENC_DECRYPTION="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.vlessEncDecryption // ""')"
    local VLESS_ENC_ENCRYPTION="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.vlessEncEncryption // ""')"
    local VLESS_ENC_ENABLE="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.vlessEncEnable // ""')"
    local CDN_BACKEND="$(get_cdn_backend)"
    if [[ "${CONFIG_TAG,,}" == 'cdn' ]]; then
        validate_cdn_split_domains || return 1
    fi
    if [[ "${CONFIG_TAG,,}" == 'multi' ]]; then
        handler_multi_xray_config "${skip_vlessenc}"
        return $?
    fi
    if protocol_uses_xhttp "${CONFIG_TAG}"; then
        XHTTP_PATH="$(normalize_xhttp_path "${XHTTP_PATH}")"
        if [[ -z "${XHTTP_PATH}" ]] || ! validate_xhttp_path "${XHTTP_PATH}"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.path_invalid")" >&2
            return 1
        fi
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg path "${XHTTP_PATH}" '.xray.path = $path')"
    fi
    if protocol_uses_vless_enc "${CONFIG_TAG}" && [[ "${skip_vlessenc}" != "1" ]]; then
        if [[ "${VLESS_ENC_ENABLE}" == "y" ]]; then
            if [[ -z "${VLESS_ENC_DECRYPTION}" || -z "${VLESS_ENC_ENCRYPTION}" ]]; then
                run_vlessenc_prompt 1
                if [[ -n "${CONFIG_DATA['vless_enc_decryption']:-}" && -n "${CONFIG_DATA['vless_enc_encryption']:-}" ]]; then
                    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq \
                        --arg dec "${CONFIG_DATA['vless_enc_decryption']}" \
                        --arg enc "${CONFIG_DATA['vless_enc_encryption']}" '
                        .xray.vlessEncDecryption = $dec |
                        .xray.vlessEncEncryption = $enc
                    ')"
                    VLESS_ENC_DECRYPTION="${CONFIG_DATA['vless_enc_decryption']}"
                else
                    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.vlessEncDecryption = "" | .xray.vlessEncEncryption = ""')"
                    VLESS_ENC_DECRYPTION=""
                fi
            fi
        elif [[ "${VLESS_ENC_ENABLE}" == "n" ]]; then
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.vlessEncDecryption = "" | .xray.vlessEncEncryption = ""')"
            VLESS_ENC_DECRYPTION=""
        fi
    fi
    # 加载对应配置标签的 Xray 配置模板
    XRAY_CONFIG="$(jq '.' "${SCRIPT_XRAY_DIR}/${CONFIG_TAG}.json")" || return 1
    if [[ "${XRAY_RULES_STATUS}" -eq 0 ]]; then
        merge_user_route_rules "${XRAY_RULES}" || return 1
    fi
    if [[ "${CONFIG_TAG,,}" == 'cdn' && "${CDN_BACKEND}" == 'xray' ]]; then
        local CDN_DOMAIN="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn // ""')"
        local CDN_DOWN_DOMAIN="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')"
        local CDN_CERT_SOURCE="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnCertSource // ""')"
        local cdn_cert_dir=''
        cdn_cert_dir="$(get_cdn_direct_cert_dir "${CDN_DOMAIN}" "${CDN_CERT_SOURCE}")" ||
            return 1
        local CDN_FULLCHAIN="${cdn_cert_dir}/fullchain.pem"
        local CDN_PRIVKEY="${cdn_cert_dir}/privkey.pem"

        if ! validate_cdn_direct_certificate "${CDN_FULLCHAIN}" "${CDN_PRIVKEY}" "${CDN_DOMAIN}"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.cert_invalid")" >&2
            return 1
        fi

        XRAY_PORT=443
        local certificates_json="$(jq -n \
            --arg cert "${CDN_FULLCHAIN}" \
            --arg key "${CDN_PRIVKEY}" \
            '[{certificateFile: $cert, keyFile: $key}]')" || return 1
        if [[ -n "${CDN_DOWN_DOMAIN}" ]]; then
            local CDN_DOWN_SOURCE="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnDownCertSource // ""')"
            local cdn_down_cert_dir="$(get_cdn_direct_cert_dir "${CDN_DOWN_DOMAIN}" "${CDN_DOWN_SOURCE}")" || return 1
            local CDN_DOWN_FULLCHAIN="${cdn_down_cert_dir}/fullchain.pem"
            local CDN_DOWN_PRIVKEY="${cdn_down_cert_dir}/privkey.pem"
            if ! validate_cdn_direct_certificate "${CDN_DOWN_FULLCHAIN}" "${CDN_DOWN_PRIVKEY}" "${CDN_DOWN_DOMAIN}"; then
                echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_split.cert_invalid")" >&2
                return 1
            fi
            certificates_json="$(echo "${certificates_json}" | jq \
                --arg cert "${CDN_DOWN_FULLCHAIN}" \
                --arg key "${CDN_DOWN_PRIVKEY}" \
                '. + [{certificateFile: $cert, keyFile: $key}]')" || return 1
        fi
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq \
            --argjson certificates "${certificates_json}" '
            .inbounds[1].listen = "0.0.0.0" |
            .inbounds[1].port = 443 |
            .inbounds[1].streamSettings.security = "tls" |
            .inbounds[1].streamSettings.sockopt = (
                (.inbounds[1].streamSettings.sockopt // {}) +
                {trustedXForwardedFor: ["X-Forwarded-For"]}
            ) |
            .inbounds[1].streamSettings.tlsSettings = {
                minVersion: "1.2",
                alpn: ["h2", "http/1.1"],
                certificates: $certificates
            }
        ')"
    fi
    if protocol_reads_public_port "${CONFIG_TAG}"; then
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson port "${XRAY_PORT}" '.inbounds[1].port = $port')"
    fi
    # 若启用了 VLESS enc，将 decryption 写入 VLESS inbounds
    if [[ -n "${VLESS_ENC_DECRYPTION}" ]]; then
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg dec "${VLESS_ENC_DECRYPTION}" '
            .inbounds |= map(
                if .protocol? == "vless" and
                    (.settings.decryption? != null) and
                    ((.settings | has("fallbacks")) | not)
                then .settings.decryption = $dec
                else . end
            )
        ')"
    fi
    # 根据配置标签更新特定字段 (第一部分)
    case "${CONFIG_TAG,,}" in
    mkcp | vision | xhttp | fallback | sni | cdn)
        # 更新客户端 UUID
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg uuid "${XRAY_UUID}" '.inbounds[1].settings.clients[0].id = $uuid')"
        ;;
    trojan)
        # 更新 Trojan 客户端密码
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg password "${TROJAN_PASSWORD}" '.inbounds[1].settings.clients[0].password = $password')"
        ;;
    ss2022)
        # 更新 SS2022 pre-shared key (从 SCRIPT_CONFIG 中获取)
        local SS2022_KEY="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.ss2022Key')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg key "${SS2022_KEY}" '.inbounds[1].settings.password = $key')"
        ;;
    hy2)
        # Xray 同时兼容 users/clients；模板按随附文档使用 clients。
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg auth "${HY2_AUTH}" '
            if (.inbounds[1].settings.clients? | type) == "array" then
                .inbounds[1].settings.clients[0].auth = $auth
            elif (.inbounds[1].settings.users? | type) == "array" then
                .inbounds[1].settings.users[0].auth = $auth
            else
                .inbounds[1].settings.clients = [{auth:$auth,level:0,email:"hy2@xray.hysteria"}]
            end |
            .inbounds[1].streamSettings.hysteriaSettings.auth = $auth
        ')"
        # 始终使用安全、拥有正确权限的证书路径进行配置，避免权限问题
        local hy2_cert_dir=''
        hy2_cert_dir="$(get_hy2_cert_dir \
            "$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertDomain // ""')" \
            "$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertSource // ""')")" ||
            return 1
        local HY2_FULLCHAIN="${hy2_cert_dir}/fullchain.pem"
        local HY2_PRIVKEY="${hy2_cert_dir}/privkey.pem"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq \
            --arg cert "${HY2_FULLCHAIN}" \
            --arg key "${HY2_PRIVKEY}" '
            .inbounds[1].streamSettings.tlsSettings.certificates[0].certificateFile = $cert |
            .inbounds[1].streamSettings.tlsSettings.certificates[0].keyFile = $key
        ')"
        ;;
    esac
    # 根据配置标签更新特定字段 (第二部分)
    case "${CONFIG_TAG,,}" in
    mkcp)
        # 更新 mKCP Seed
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg seed "${KCP_SEED}" '.inbounds[1].streamSettings.finalmask.udp[0].settings.password = $seed')"
        ;;
    vision)
        # 更新 Reality 服务器名称、私钥和 Short IDs
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson serverNames "${SERVER_NAMES}" '.inbounds[1].streamSettings.realitySettings.serverNames = $serverNames')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg privateKey "${PRIVATE_KEY}" '.inbounds[1].streamSettings.realitySettings.privateKey = $privateKey')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson shortIds "${SHORT_IDS}" '.inbounds[1].streamSettings.realitySettings.shortIds = $shortIds')"
        # 写入 ML-DSA-65 Seed（如果已生成）
        if [[ -n "${MLDSA65_SEED}" ]]; then
            XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg seed "${MLDSA65_SEED}" '.inbounds[1].streamSettings.realitySettings.mldsa65Seed = $seed')"
        fi
        ;;
    xhttp | trojan | fallback | sni)
        # 如果不是 sni 配置，更新 Reality 目标
        if [[ "${CONFIG_TAG,,}" != 'sni' ]]; then
            XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg target "${TARGET_DOMAIN}:443" '.inbounds[1].streamSettings.realitySettings.target = $target')"
        fi
        # 更新 Reality 服务器名称、私钥和 Short IDs
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson serverNames "${SERVER_NAMES}" '.inbounds[1].streamSettings.realitySettings.serverNames = $serverNames')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg privateKey "${PRIVATE_KEY}" '.inbounds[1].streamSettings.realitySettings.privateKey = $privateKey')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson shortIds "${SHORT_IDS}" '.inbounds[1].streamSettings.realitySettings.shortIds = $shortIds')"
        # 写入 ML-DSA-65 Seed（如果已生成）
        if [[ -n "${MLDSA65_SEED}" ]]; then
            XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg seed "${MLDSA65_SEED}" '.inbounds[1].streamSettings.realitySettings.mldsa65Seed = $seed')"
        fi
        ;;
    esac
    # 根据配置标签更新特定字段 (第三部分)
    case "${CONFIG_TAG,,}" in
    xhttp | trojan | cdn)
        # 更新 XHTTP 路径
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg path "${XHTTP_PATH}" '.inbounds[1].streamSettings.xhttpSettings.path = $path')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg mode "${XHTTP_MODE}" '.inbounds[1].streamSettings.xhttpSettings.mode = $mode')"
        ;;
    fallback | sni)
        # 更新 Fallback 客户端 UUID 和 XHTTP 路径
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg uuid "${FALLBACK_UUID}" '.inbounds[2].settings.clients[0].id = $uuid')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg path "${XHTTP_PATH}" '.inbounds[2].streamSettings.xhttpSettings.path = $path')"
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg mode "${XHTTP_MODE}" '.inbounds[2].streamSettings.xhttpSettings.mode = $mode')"
        ;;
    esac
    # 处理可选默认规则；保留模式已在模板规则之上合并用户规则。
    case "${XRAY_RULES_STATUS}" in
    1)
        # 重置并添加默认路由规则
        if [[ "${XRAY_RULES_BT}" -eq 1 ]]; then
            add_rule "bt" "protocol" "bittorrent" "block" 1 || return 1
        fi
        if [[ "${XRAY_RULES_CN}" -eq 1 ]]; then
            add_rule "cn-ip" "ip" "geoip:cn" "block" "after" "private-ip" || return 1
        fi
        if [[ "${XRAY_RULES_AD}" -eq 1 ]]; then
            add_rule "ad-domain" "domain" "geosite:category-ads-all" "block" || return 1
        fi
        ;;
    esac
    # Vision 防偷模式：在路由规则替换之后更新 anti-steal 相关配置
    # 确保 anti-steal-allow 的域名始终与当前 target/serverNames 一致
    if [[ "${CONFIG_TAG,,}" == 'vision' ]]; then
        # 更新 anti-steal-in dokodemo-door 的目标地址
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg addr "${TARGET_DOMAIN}" '
            (.inbounds[] | select(.tag == "anti-steal-in")).settings.address = $addr
        ')"
        # 更新 anti-steal-allow 路由规则的域名列表（与 serverNames 保持一致）
        XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson domains "${SERVER_NAMES}" '
            (.routing.rules[] | select(.ruleTag == "anti-steal-allow")).domain = $domains
        ')"
    fi
    # 处理 WARP 状态
    if [[ ${WARP_STATUS} -eq 1 ]]; then
        # 获取 WARP 容器 IP
        local container_ip=''
        container_ip="$(exec_docker '--obtain-container-ip')" || return 1
        [[ -n "${container_ip}" ]] || return 1
        # 构造 WARP Socks 出站配置 JSON
        local socks_config
        socks_config="$(jq -n --arg address "${container_ip}" '[{tag:"warp",protocol:"socks",settings:{servers:[{address:$address,port:40001}]}}]')" || return 1
        # 将 WARP 出站配置添加到 Xray 配置中
        XRAY_CONFIG=$(echo "${XRAY_CONFIG}" | jq --argjson socks_config "${socks_config}" '.outbounds += $socks_config')
    fi
    # 应用反向代理配置
    local reverse_status=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.reverse // 0')
    if [[ "${reverse_status}" -eq 1 ]]; then
        handler_reverse_config || return 1
    fi
    handler_apply_lan_config || return 1

    # 只持久化用户管理的规则，模板和功能派生规则在每次构建时重建。
    XRAY_RULES="$(echo "${XRAY_CONFIG}" | jq '.routing.rules' | user_route_rules)" || return 1
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson rules "${XRAY_RULES}" '.rules = $rules')" || return 1
    commit_xray_and_script_config "${XRAY_CONFIG}" "${SCRIPT_CONFIG}" || return 1

    # 仅在配置已通过 xray 校验并成功落盘后修改防火墙。
    case "${CONFIG_TAG,,}" in
    vision | xhttp | trojan | fallback)
        open_xray_firewall_port "${XRAY_PORT}" tcp || return 1
        ;;
    cdn)
        if [[ "${CDN_BACKEND}" == 'xray' ]]; then
            open_xray_firewall_port 443 tcp || return 1
        fi
        ;;
    mkcp | hy2)
        open_xray_firewall_port "${XRAY_PORT}" udp || return 1
        ;;
    ss2022)
        open_xray_firewall_port "${XRAY_PORT}" tcp || return 1
        open_xray_firewall_port "${XRAY_PORT}" udp || return 1
        ;;
    esac

    handler_lan_open_firewall || return 1

    # 反向代理端口放在最后处理，确保其成功后没有其他可失败的防火墙步骤。
    if [[ "${reverse_status}" -eq 1 ]]; then
        local reverse_port=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.reversePort // 8443')
        open_owned_firewall_port 'reverse' "${reverse_port}" tcp || return 1
    fi
}

# =============================================================================
# 函数名称: run_vlessenc_prompt
# 功能描述: 询问是否启用 VLESS enc，若选是则执行 xray vlessenc（选择 ML-KEM-768），
#           解析 decryption/encryption 并写入 CONFIG_DATA。
# 参数: 无
# 返回值: 无 (直接修改 CONFIG_DATA 全局关联数组)
# =============================================================================
function run_vlessenc_choice() {
    local eof_default="${1:-}"
    local vless_enc_reply
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.vless_enc.prompt")" >&2
    if ! read -r vless_enc_reply && [[ -z "${vless_enc_reply}" ]]; then
        [[ -n "${eof_default}" ]] || return 1
        vless_enc_reply="${eof_default}"
    fi
    vless_enc_reply="${vless_enc_reply:-n}"
    if [[ "${vless_enc_reply,,}" == "y" ]]; then
        CONFIG_DATA['vless_enc_enable']="y"
    else
        CONFIG_DATA['vless_enc_enable']="n"
    fi
}

function run_mldsa65_choice() {
    local eof_default="${1:-}"
    local mldsa65_reply
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.mldsa.prompt")" >&2
    if ! read -r mldsa65_reply && [[ -z "${mldsa65_reply}" ]]; then
        [[ -n "${eof_default}" ]] || return 1
        mldsa65_reply="${eof_default}"
    fi
    mldsa65_reply="${mldsa65_reply:-n}"
    if [[ "${mldsa65_reply,,}" == 'y' ]]; then
        CONFIG_DATA['mldsa65_enable']='y'
    else
        CONFIG_DATA['mldsa65_enable']='n'
    fi
}

function run_github_proxy_choice() {
    local eof_default="${1:-}"
    local github_proxy_reply
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.gh_proxy.prompt")" >&2
    if ! read -r github_proxy_reply && [[ -z "${github_proxy_reply}" ]]; then
        [[ -n "${eof_default}" ]] || return 1
        github_proxy_reply="${eof_default}"
    fi
    github_proxy_reply="${github_proxy_reply:-n}"
    if [[ "${github_proxy_reply,,}" == 'y' ]]; then
        CONFIG_DATA['github_proxy']='y'
    else
        CONFIG_DATA['github_proxy']='n'
    fi
}

function run_vlessenc_prompt() {
    local auto="${1:-0}"
    local vless_enc_reply
    if [[ "${auto}" != "1" ]]; then
        echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.vless_enc.prompt")" >&2
        read -r vless_enc_reply
    else
        vless_enc_reply="y"
    fi
    if [[ "${vless_enc_reply,,}" != "y" ]]; then
        return 0
    fi
    if ! cmd_exists 'xray'; then
        echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.vless_enc.fail")" >&2
        return 0
    fi
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.vless_enc.running")" >&2
    local vlessenc_output
    vlessenc_output="$(printf '2\n' | xray vlessenc 2>&1)" || true
    local decryption encryption
    decryption="$(echo "${vlessenc_output}" | grep '"decryption"' | tail -1 | sed 's/.*"decryption": *"\([^"]*\)".*/\1/')"
    encryption="$(echo "${vlessenc_output}" | grep '"encryption"' | tail -1 | sed 's/.*"encryption": *"\([^"]*\)".*/\1/')"
    if [[ -z "${decryption}" || -z "${encryption}" ]]; then
        echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.vless_enc.parse_fail")" >&2
        return 0
    fi
    CONFIG_DATA['vless_enc_decryption']="${decryption}"
    CONFIG_DATA['vless_enc_encryption']="${encryption}"
}

# =============================================================================
# 函数名称: handler_read_xray_config
# 功能描述: 读取 Xray 配置所需的用户输入。
#           1. 验证配置标签的有效性。
#           2. 根据脚本配置决定是否需要读取规则相关输入。
#           3. 根据配置标签读取对应的各项配置参数。
#           4. 在同一输入阶段收集 VLESS enc 与 ML-DSA-65 启用选项。
# 参数:
#   $1: CONFIG_TAG - 配置标签 (例如 Vision, XHTTP, SNI 等)
# 返回值: 无 (直接修改 CONFIG_DATA 全局关联数组)
# 退出码: 如果配置标签无效，则退出脚本 (exit 1)
# =============================================================================
function handler_read_xray_config() {
    local CONFIG_TAG="${1}" # 获取配置标签
    # 验证配置标签的有效性，无效则退出
    if ! exec_check '--tag' "${CONFIG_TAG}"; then
        exit 1
    fi
    # 将配置标签存储到 CONFIG_DATA
    CONFIG_DATA['tag']="${CONFIG_TAG}"
    exec_read 'rules' || return 1
    # 如果规则状态不是 'n'，则读取阻止选项
    if [[ "${CONFIG_DATA['rules'],,}" != 'n' ]]; then
        exec_read 'block-bt' || return 1
        exec_read 'block-cn' || return 1
        exec_read 'block-ad' || return 1
    fi
    # SNI/CDN 对外固定由 Nginx 监听 443，询问端口只会产生一个不会生效的值。
    if protocol_reads_public_port "${CONFIG_TAG}"; then
        exec_read 'port' || return 1
    fi
    # 根据配置标签读取特定参数 (第一部分)
    case "${CONFIG_TAG,,}" in
    trojan) exec_read 'password' || return 1 ;;                             # 读取 Trojan 密码
    hy2) exec_read 'hy2-auth' || return 1 ;;                                # 读取 HY2 auth 密码
    ss2022) exec_read 'ss2022-password' || return 1 ;;                      # 读取 SS2022 PSK
    mkcp | vision | xhttp | fallback | sni | cdn) exec_read 'uuid' || return 1 ;; # 读取 UUID
    esac
    # 根据配置标签读取特定参数 (第二部分)
    case "${CONFIG_TAG,,}" in
    fallback | sni) exec_read 'fallback' || return 1 ;; # 读取 Fallback UUID
    mkcp) exec_read 'seed' || return 1 ;;               # 读取 mKCP Seed
    esac
    # 根据配置标签读取特定参数 (第三部分)
    case "${CONFIG_TAG,,}" in
    vision | xhttp | trojan | fallback) exec_read 'target' || return 1 ;; # 读取目标域名
    sni)
        # 为 SNI 配置读取域名和 CDN
        exec_read 'domain' || return 1 # 读取域名
        exec_read 'cdn' || return 1    # 读取 CDN
        ;;
    cdn)
        exec_read 'cdn' || return 1      # 读取 CDN
        exec_read 'cdn-down' || return 1 # 读取可选的下行 CDN
        ;;
    esac
    # 根据配置标签读取特定参数 (第四部分)
    case "${CONFIG_TAG,,}" in
    vision | xhttp | trojan | fallback | sni) exec_read 'short' || return 1 ;; # 读取 Short IDs
    esac
    # 根据配置标签读取特定参数 (第五部分)
    case "${CONFIG_TAG,,}" in
    xhttp | trojan | fallback | sni | cdn)
        exec_read 'path' || return 1
        exec_read 'xhttp-mode' || return 1
        ;;
    esac
    if protocol_uses_vless_enc "${CONFIG_TAG}"; then
        run_vlessenc_choice || return 1
    fi
    if protocol_uses_reality "${CONFIG_TAG}"; then
        run_mldsa65_choice || return 1
    fi
    if ! cmd_exists 'xray'; then
        run_github_proxy_choice || return 1
    fi
    # Web 模式的证书在创建各自站点时处理，避免 CDN 和 SNI 共用一组提示与路径。
    case "${CONFIG_TAG,,}" in
    hy2)
        read_hy2_certificate_config || return 1
        ;;
    esac
}

function set_xray_certificate_permissions() {
    local cert_dir="$1"

    if getent group xray-nginx >/dev/null 2>&1; then
        chown xray:xray-nginx \
            "${cert_dir}" "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem" \
            2>/dev/null || return 1
    elif id -u xray >/dev/null 2>&1; then
        chown xray:xray \
            "${cert_dir}" "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem" \
            2>/dev/null || return 1
    fi
    chmod 750 "${cert_dir}" 2>/dev/null || return 1
    chmod 640 "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem" 2>/dev/null || return 1
}

function validate_cdn_direct_certificate() {
    local fullchain="$1"
    local privkey="$2"
    local domain="$3"

    [[ -n "${domain}" ]] &&
        validate_tls_certificate_pair "${fullchain}" "${privkey}" &&
        openssl x509 -in "${fullchain}" -noout -checkend 0 >/dev/null 2>&1 &&
        certificate_matches_server_name "${fullchain}" "${domain}"
}

function install_custom_xray_certificate_pair() {
    local source_fullchain="$1"
    local source_privkey="$2"
    local domain="$3"
    local target_dir="$4"
    local cert_parent stage_dir backup_dir=''

    validate_cdn_direct_certificate "${source_fullchain}" "${source_privkey}" "${domain}" || return 1
    [[ ! -L "${target_dir}" &&
        ! -L "${target_dir}/fullchain.pem" &&
        ! -L "${target_dir}/privkey.pem" ]] || return 1
    if [[ -d "${target_dir}" ]] &&
        find "${target_dir}" -mindepth 1 -maxdepth 1 \
            ! -name fullchain.pem ! -name privkey.pem -print -quit |
            grep -q .; then
        install_custom_xray_certificate_pair_in_place \
            "${source_fullchain}" "${source_privkey}" "${domain}" "${target_dir}"
        return $?
    fi

    cert_parent="$(dirname "${target_dir}")"
    mkdir -p "${cert_parent}" || return 1
    stage_dir="$(mktemp -d "${cert_parent}/.cdn-cert.XXXXXX")" || return 1
    if ! cp -f "${source_fullchain}" "${stage_dir}/fullchain.pem" ||
        ! cp -f "${source_privkey}" "${stage_dir}/privkey.pem" ||
        ! validate_cdn_direct_certificate "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem" "${domain}"; then
        rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
        rmdir -- "${stage_dir}" 2>/dev/null || true
        return 1
    fi

    if ! set_xray_certificate_permissions "${stage_dir}"; then
        rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
        rmdir -- "${stage_dir}" 2>/dev/null || true
        return 1
    fi
    if [[ -d "${target_dir}" ]]; then
        if ! backup_dir="$(mktemp -d "${cert_parent}/.cdn-cert-old.XXXXXX")"; then
            rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
            rmdir -- "${stage_dir}" 2>/dev/null || true
            return 1
        fi
        if ! rmdir -- "${backup_dir}"; then
            rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
            rmdir -- "${stage_dir}" 2>/dev/null || true
            return 1
        fi
        if ! mv -- "${target_dir}" "${backup_dir}"; then
            rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
            rmdir -- "${stage_dir}" 2>/dev/null || true
            return 1
        fi
    fi
    if ! mv -- "${stage_dir}" "${target_dir}"; then
        [[ -n "${backup_dir}" && -d "${backup_dir}" ]] &&
            mv -- "${backup_dir}" "${target_dir}" 2>/dev/null || true
        rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
        rmdir -- "${stage_dir}" 2>/dev/null || true
        return 1
    fi
    if [[ -n "${backup_dir}" && -d "${backup_dir}" ]]; then
        rm -f -- "${backup_dir}/fullchain.pem" "${backup_dir}/privkey.pem"
        rmdir -- "${backup_dir}" 2>/dev/null || true
    fi
}

function install_custom_xray_certificate_pair_in_place() {
    local source_fullchain="$1"
    local source_privkey="$2"
    local domain="$3"
    local target_dir="$4"
    local cert_parent stage_dir backup_dir
    local had_fullchain=0 had_privkey=0

    validate_cdn_direct_certificate "${source_fullchain}" "${source_privkey}" "${domain}" || return 1
    [[ ! -L "${target_dir}" &&
        ! -L "${target_dir}/fullchain.pem" &&
        ! -L "${target_dir}/privkey.pem" ]] || return 1
    cert_parent="$(dirname "${target_dir}")"
    mkdir -p "${target_dir}" || return 1
    stage_dir="$(mktemp -d "${cert_parent}/.xray-cert-stage.XXXXXX")" || return 1
    if ! cp -f -- "${source_fullchain}" "${stage_dir}/fullchain.pem" ||
        ! cp -f -- "${source_privkey}" "${stage_dir}/privkey.pem" ||
        ! validate_cdn_direct_certificate \
            "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem" "${domain}" ||
        ! set_xray_certificate_permissions "${stage_dir}"; then
        rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
        rmdir -- "${stage_dir}" 2>/dev/null || true
        return 1
    fi
    if ! backup_dir="$(mktemp -d "${cert_parent}/.xray-cert-backup.XXXXXX")"; then
        rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
        rmdir -- "${stage_dir}" 2>/dev/null || true
        return 1
    fi

    if [[ -e "${target_dir}/fullchain.pem" ]]; then
        cp -p -- "${target_dir}/fullchain.pem" "${backup_dir}/fullchain.pem" || {
            rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
            rmdir -- "${stage_dir}" 2>/dev/null || true
            rmdir -- "${backup_dir}" 2>/dev/null || true
            return 1
        }
        had_fullchain=1
    fi
    if [[ -e "${target_dir}/privkey.pem" ]]; then
        cp -p -- "${target_dir}/privkey.pem" "${backup_dir}/privkey.pem" || {
            rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
            rmdir -- "${stage_dir}" 2>/dev/null || true
            rm -f -- "${backup_dir}/fullchain.pem"
            rmdir -- "${backup_dir}" 2>/dev/null || true
            return 1
        }
        had_privkey=1
    fi

    if ! cp -f -- "${stage_dir}/fullchain.pem" "${target_dir}/fullchain.pem" ||
        ! cp -f -- "${stage_dir}/privkey.pem" "${target_dir}/privkey.pem" ||
        ! validate_cdn_direct_certificate \
            "${target_dir}/fullchain.pem" "${target_dir}/privkey.pem" "${domain}" ||
        ! set_xray_certificate_permissions "${target_dir}"; then
        if [[ "${had_fullchain}" -eq 1 ]]; then
            cp -p -- "${backup_dir}/fullchain.pem" "${target_dir}/fullchain.pem" 2>/dev/null || true
        else
            rm -f -- "${target_dir}/fullchain.pem"
        fi
        if [[ "${had_privkey}" -eq 1 ]]; then
            cp -p -- "${backup_dir}/privkey.pem" "${target_dir}/privkey.pem" 2>/dev/null || true
        else
            rm -f -- "${target_dir}/privkey.pem"
        fi
        if [[ "${had_fullchain}" -eq 1 && "${had_privkey}" -eq 1 ]]; then
            set_xray_certificate_permissions "${target_dir}" || true
        fi
        rm -f -- "${backup_dir}/fullchain.pem" "${backup_dir}/privkey.pem"
        rmdir -- "${backup_dir}" 2>/dev/null || true
        rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
        rmdir -- "${stage_dir}" 2>/dev/null || true
        return 1
    fi

    rm -f -- "${backup_dir}/fullchain.pem" "${backup_dir}/privkey.pem"
    rmdir -- "${backup_dir}" 2>/dev/null || true
    rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
    rmdir -- "${stage_dir}" 2>/dev/null || true
}

function set_nginx_certificate_permissions() {
    local cert_dir="$1"

    if getent group xray-nginx >/dev/null 2>&1; then
        chown nginx:xray-nginx \
            "${cert_dir}" "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem" \
            2>/dev/null || return 1
    elif id -u nginx >/dev/null 2>&1; then
        chown nginx:nginx \
            "${cert_dir}" "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem" \
            2>/dev/null || return 1
    fi
    chmod 750 "${cert_dir}" 2>/dev/null || return 1
    chmod 640 "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem" 2>/dev/null || return 1
}

function install_custom_nginx_certificate_pair() {
    local source_fullchain="$1"
    local source_privkey="$2"
    local domain="$3"
    local target_dir="$4"
    local cert_parent stage_dir backup_dir
    local had_fullchain=0 had_privkey=0 target_dir_created=0
    local old_dir_mode='' old_dir_uid='' old_dir_gid=''
    local restore_status=0

    validate_cdn_direct_certificate \
        "${source_fullchain}" "${source_privkey}" "${domain}" || return 1
    [[ ! -L "${target_dir}" &&
        ! -L "${target_dir}/fullchain.pem" &&
        ! -L "${target_dir}/privkey.pem" ]] || return 1

    cert_parent="$(dirname "${target_dir}")"
    mkdir -p "${cert_parent}" || return 1
    if [[ -e "${target_dir}" && ! -d "${target_dir}" ]]; then
        return 1
    fi
    if [[ ! -d "${target_dir}" ]]; then
        mkdir "${target_dir}" || return 1
        target_dir_created=1
    else
        old_dir_mode="$(stat -c '%a' "${target_dir}")" || return 1
        old_dir_uid="$(stat -c '%u' "${target_dir}")" || return 1
        old_dir_gid="$(stat -c '%g' "${target_dir}")" || return 1
    fi

    stage_dir="$(mktemp -d "${cert_parent}/.nginx-cert-stage.XXXXXX")" || {
        [[ "${target_dir_created}" -eq 0 ]] ||
            rmdir -- "${target_dir}" 2>/dev/null || true
        return 1
    }
    backup_dir="$(mktemp -d "${cert_parent}/.nginx-cert-backup.XXXXXX")" || {
        rmdir -- "${stage_dir}" 2>/dev/null || true
        [[ "${target_dir_created}" -eq 0 ]] ||
            rmdir -- "${target_dir}" 2>/dev/null || true
        return 1
    }

    if ! cp -f -- "${source_fullchain}" "${stage_dir}/fullchain.pem" ||
        ! cp -f -- "${source_privkey}" "${stage_dir}/privkey.pem" ||
        ! validate_cdn_direct_certificate \
            "${stage_dir}/fullchain.pem" \
            "${stage_dir}/privkey.pem" \
            "${domain}"; then
        rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
        rmdir -- "${stage_dir}" 2>/dev/null || true
        rmdir -- "${backup_dir}" 2>/dev/null || true
        [[ "${target_dir_created}" -eq 0 ]] ||
            rmdir -- "${target_dir}" 2>/dev/null || true
        return 1
    fi

    if [[ -e "${target_dir}/fullchain.pem" ]]; then
        [[ -f "${target_dir}/fullchain.pem" &&
            ! -L "${target_dir}/fullchain.pem" ]] &&
            cp -p -- \
                "${target_dir}/fullchain.pem" \
                "${backup_dir}/fullchain.pem" || {
            rm -f -- "${stage_dir}/fullchain.pem" "${stage_dir}/privkey.pem"
            rmdir -- "${stage_dir}" 2>/dev/null || true
            rmdir -- "${backup_dir}" 2>/dev/null || true
            return 1
        }
        had_fullchain=1
    fi
    if [[ -e "${target_dir}/privkey.pem" ]]; then
        [[ -f "${target_dir}/privkey.pem" &&
            ! -L "${target_dir}/privkey.pem" ]] &&
            cp -p -- \
                "${target_dir}/privkey.pem" \
                "${backup_dir}/privkey.pem" || {
            rm -f -- \
                "${stage_dir}/fullchain.pem" \
                "${stage_dir}/privkey.pem" \
                "${backup_dir}/fullchain.pem"
            rmdir -- "${stage_dir}" 2>/dev/null || true
            rmdir -- "${backup_dir}" 2>/dev/null || true
            return 1
        }
        had_privkey=1
    fi

    if ! cp -f -- "${stage_dir}/fullchain.pem" "${target_dir}/fullchain.pem" ||
        ! cp -f -- "${stage_dir}/privkey.pem" "${target_dir}/privkey.pem" ||
        ! validate_cdn_direct_certificate \
            "${target_dir}/fullchain.pem" \
            "${target_dir}/privkey.pem" \
            "${domain}" ||
        ! set_nginx_certificate_permissions "${target_dir}"; then
        if [[ "${had_fullchain}" -eq 1 ]]; then
            cp -p -- \
                "${backup_dir}/fullchain.pem" \
                "${target_dir}/fullchain.pem" 2>/dev/null ||
                restore_status=1
        else
            rm -f -- "${target_dir}/fullchain.pem" || restore_status=1
        fi
        if [[ "${had_privkey}" -eq 1 ]]; then
            cp -p -- \
                "${backup_dir}/privkey.pem" \
                "${target_dir}/privkey.pem" 2>/dev/null ||
                restore_status=1
        else
            rm -f -- "${target_dir}/privkey.pem" || restore_status=1
        fi
        if [[ "${target_dir_created}" -eq 0 ]]; then
            chown "${old_dir_uid}:${old_dir_gid}" "${target_dir}" 2>/dev/null ||
                restore_status=1
            chmod "${old_dir_mode}" "${target_dir}" 2>/dev/null ||
                restore_status=1
        else
            rmdir -- "${target_dir}" 2>/dev/null || restore_status=1
        fi
        rm -f -- \
            "${stage_dir}/fullchain.pem" \
            "${stage_dir}/privkey.pem" \
            "${backup_dir}/fullchain.pem" \
            "${backup_dir}/privkey.pem"
        rmdir -- "${stage_dir}" 2>/dev/null || true
        rmdir -- "${backup_dir}" 2>/dev/null || true
        if [[ "${restore_status}" -ne 0 ]]; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.cert_restore_fail") ${target_dir}" >&2
        fi
        return 1
    fi

    rm -f -- \
        "${stage_dir}/fullchain.pem" \
        "${stage_dir}/privkey.pem" \
        "${backup_dir}/fullchain.pem" \
        "${backup_dir}/privkey.pem"
    rmdir -- "${stage_dir}" 2>/dev/null || true
    rmdir -- "${backup_dir}" 2>/dev/null || true
}

function reload_certificate_consumer() {
    local consumer="$1"

    case "${consumer}" in
    xray)
        if systemctl -q is-active xray; then
            systemctl -q restart xray
        fi
        ;;
    nginx)
        if systemctl -q is-active nginx; then
            nginx -t >/dev/null 2>&1 && systemctl -q reload nginx
        fi
        ;;
    *) return 1 ;;
    esac
}

function build_certificate_reload_command() {
    local consumer="$1"
    local target_dir="$2"
    local acme_domain="$3"
    local handler_q acme_domain_q target_dir_q

    case "${consumer}" in
    xray|nginx) ;;
    *) return 1 ;;
    esac

    printf -v handler_q '%q' "${CUR_DIR}/handler.sh"
    [[ -n "${acme_domain}" && "${acme_domain}" != *$'\n'* ]] || return 1
    printf -v acme_domain_q '%q' "${acme_domain}"
    printf -v target_dir_q '%q' "${target_dir}"
    printf 'bash %s --deploy-acme-certificate %s %s' \
        "${handler_q}" "${acme_domain_q}" "${target_dir_q}"
}

function install_acme_managed_certificate() {
    local acme_domain="$1"
    local server_name="$2"
    local target_dir="$3"
    local consumer="$4"
    local cert_parent backup_dir had_previous=0
    local restore_status=0
    local reload_command=''

    case "${consumer}" in
    xray|nginx) ;;
    *) return 1 ;;
    esac
    reload_command="$(build_certificate_reload_command \
        "${consumer}" "${target_dir}" "${acme_domain}")" ||
        return 1

    [[ ! -L "${target_dir}" &&
        ! -L "${target_dir}/fullchain.pem" &&
        ! -L "${target_dir}/privkey.pem" ]] || return 1
    cert_parent="$(dirname "${target_dir}")"
    mkdir -p "${cert_parent}" "${target_dir}" || return 1
    backup_dir="$(mktemp -d "${cert_parent}/.xray-cert-backup.XXXXXX")" || return 1
    if [[ -r "${target_dir}/fullchain.pem" && -r "${target_dir}/privkey.pem" ]]; then
        if ! cp -f "${target_dir}/fullchain.pem" "${backup_dir}/fullchain.pem" ||
            ! cp -f "${target_dir}/privkey.pem" "${backup_dir}/privkey.pem"; then
            rm -f -- "${backup_dir}/fullchain.pem" "${backup_dir}/privkey.pem"
            rmdir -- "${backup_dir}" 2>/dev/null || true
            return 1
        fi
        had_previous=1
    fi

    if ! "${ACME_PATH}" --install-cert --ecc -d "${acme_domain}" \
            --key-file "${target_dir}/privkey.pem" \
            --fullchain-file "${target_dir}/fullchain.pem" \
            --reloadcmd "${reload_command}" ||
        ! validate_cdn_direct_certificate \
            "${target_dir}/fullchain.pem" \
            "${target_dir}/privkey.pem" \
            "${server_name}" ||
        { [[ "${consumer}" == 'xray' ]] &&
            ! set_xray_certificate_permissions "${target_dir}"; } ||
        { [[ "${consumer}" == 'nginx' ]] &&
            ! set_nginx_certificate_permissions "${target_dir}"; }; then
        if [[ "${had_previous}" -eq 1 ]]; then
            cp -f "${backup_dir}/fullchain.pem" "${target_dir}/fullchain.pem" 2>/dev/null ||
                restore_status=1
            cp -f "${backup_dir}/privkey.pem" "${target_dir}/privkey.pem" 2>/dev/null ||
                restore_status=1
            if [[ "${restore_status}" -eq 0 ]]; then
                if [[ "${consumer}" == 'xray' ]]; then
                    set_xray_certificate_permissions "${target_dir}" ||
                        restore_status=1
                else
                    set_nginx_certificate_permissions "${target_dir}" ||
                        restore_status=1
                fi
            fi
            if [[ "${restore_status}" -eq 0 ]]; then
                reload_certificate_consumer "${consumer}" ||
                    restore_status=1
            fi
        else
            rm -f -- "${target_dir}/fullchain.pem" "${target_dir}/privkey.pem" ||
                restore_status=1
        fi
        rm -f -- "${backup_dir}/fullchain.pem" "${backup_dir}/privkey.pem"
        rmdir -- "${backup_dir}" 2>/dev/null || true
        if [[ "${restore_status}" -ne 0 ]]; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.cert_restore_fail") ${target_dir}" >&2
        fi
        return 1
    fi

    rm -f -- "${backup_dir}/fullchain.pem" "${backup_dir}/privkey.pem"
    rmdir -- "${backup_dir}" 2>/dev/null || true
}

function install_acme_xray_certificate() {
    install_acme_managed_certificate "$1" "$2" "$3" 'xray'
}

function install_acme_nginx_certificate() {
    install_acme_managed_certificate "$1" "$2" "$3" 'nginx'
}

function acme_main_domain_for_name() {
    local domain="$1"

    [[ -x "${ACME_PATH}" ]] || return 1
    "${ACME_PATH}" --list --home "${HOME}/.acme.sh" 2>/dev/null |
        awk -v domain="${domain,,}" '
            NR > 1 {
                key_length = tolower($2)
                gsub(/"/, "", key_length)
                if (key_length !~ /^ec-/) next
                if (tolower($1) == domain) { print $1; exit }
                sans = $3
                gsub(/[,;]/, " ", sans)
                count = split(sans, values, /[[:space:]]+/)
                for (i = 1; i <= count; i++) {
                    if (tolower(values[i]) == domain) { print $1; exit }
                }
            }
        '
}

function emit_active_acme_certificate_consumer() {
    local requested_main_domain="${1,,}"
    local lookup_name="$2"
    local server_name="$3"
    local consumer="$4"
    local target_dir="$5"
    local managed_domain=''

    case "${consumer}" in
    xray|nginx) ;;
    *) return 1 ;;
    esac
    [[ -n "${lookup_name}" && -n "${server_name}" && -n "${target_dir}" &&
        "${lookup_name}" != *$'\n'* && "${server_name}" != *$'\n'* &&
        "${target_dir}" == /* && "${target_dir}" != '/' &&
        "${target_dir}" != *$'\n'* && "${target_dir}" != *$'\t'* ]] || return 1

    managed_domain="$(acme_main_domain_for_name "${lookup_name}" 2>/dev/null || true)"
    if [[ -z "${managed_domain}" ]]; then
        [[ -n "${requested_main_domain}" ]] && return 0
        return 1
    fi
    if [[ -n "${requested_main_domain}" &&
        "${managed_domain,,}" != "${requested_main_domain}" ]]; then
        return 0
    fi
    printf '%s\t%s\t%s\t%s\n' \
        "${managed_domain}" "${consumer}" "${server_name}" "${target_dir}"
}

function list_active_acme_certificate_consumers() {
    local requested_main_domain="${1:-}"
    local config_tag backend role domain source target_dir
    local acme_domain multi_has_hy2
    local -a roles=()

    config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')" || return 1
    case "${config_tag,,}" in
    cdn)
        backend="$(get_cdn_backend)" || return 1
        roles=(cdn cdnDown)
        for role in "${roles[@]}"; do
            domain="$(echo "${SCRIPT_CONFIG}" | jq -r \
                --arg role "${role}" '.nginx[$role] // ""')" || return 1
            [[ -n "${domain}" ]] || continue
            if [[ "${backend}" == 'xray' ]]; then
                if [[ "${role}" == 'cdn' ]]; then
                    source="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnCertSource // ""')" || return 1
                else
                    source="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnDownCertSource // ""')" || return 1
                fi
                [[ "${source}" == '1' ]] || continue
                target_dir="$(get_cdn_direct_cert_dir "${domain}" "${source}")" || return 1
                emit_active_acme_certificate_consumer \
                    "${requested_main_domain}" "${domain}" "${domain}" \
                    'xray' "${target_dir}" || return 1
            else
                source="$(echo "${SCRIPT_CONFIG}" | jq -r \
                    --arg role "${role}" '.nginx.certificates[$role].source // ""')" || return 1
                [[ "${source}" == '1' ]] || continue
                emit_active_acme_certificate_consumer \
                    "${requested_main_domain}" "${domain}" "${domain}" \
                    'nginx' "${NGINX_CONFIG_DIR}/certs/${domain}" || return 1
            fi
        done
        ;;
    sni)
        roles=(domain cdn)
        for role in "${roles[@]}"; do
            domain="$(echo "${SCRIPT_CONFIG}" | jq -r \
                --arg role "${role}" '.nginx[$role] // ""')" || return 1
            [[ -n "${domain}" ]] || continue
            source="$(echo "${SCRIPT_CONFIG}" | jq -r \
                --arg role "${role}" '.nginx.certificates[$role].source // ""')" || return 1
            [[ "${source}" == '1' ]] || continue
            emit_active_acme_certificate_consumer \
                "${requested_main_domain}" "${domain}" "${domain}" \
                'nginx' "${NGINX_CONFIG_DIR}/certs/${domain}" || return 1
        done
        ;;
    hy2|multi)
        if [[ "${config_tag,,}" == 'multi' ]]; then
            multi_has_hy2="$(echo "${SCRIPT_CONFIG}" |
                jq -r 'any(.xray.nodes[]?; (.tag | ascii_downcase) == "hy2")')" || return 1
            [[ "${multi_has_hy2}" == 'true' ]] || return 0
        fi
        source="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertSource // ""')" || return 1
        [[ "${source}" =~ ^[12]$ ]] || return 0
        domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertDomain // ""')" || return 1
        acme_domain="$(echo "${SCRIPT_CONFIG}" | jq -r '
            (.xray.hy2CertAcmeDomain // "") as $acme_domain |
            if $acme_domain == "" then (.xray.hy2CertDomain // "") else $acme_domain end
        ')" || return 1
        if ! target_dir="$(get_xray_runtime_cert_dir 2>/dev/null)"; then
            target_dir="$(get_hy2_cert_dir "${domain}" "${source}")" || return 1
        fi
        emit_active_acme_certificate_consumer \
            "${requested_main_domain}" "${acme_domain}" "${domain}" \
            'xray' "${target_dir}" || return 1
        ;;
    esac
}

function handler_deploy_acme_certificate() {
    local acme_domain="$1"
    local source_dir="$2"
    local managed_domain consumer_lines consumer server_name target_dir target_key
    local reload_xray=0 reload_nginx=0 reload_status=0
    local index consumer_count=0
    local -a consumers=() server_names=() target_dirs=()
    local -A target_consumers=()

    [[ -n "${acme_domain}" && "${acme_domain}" != *$'\n'* &&
        "${source_dir}" == /* && "${source_dir}" != '/' &&
        "${source_dir}" != *$'\n'* && ! -L "${source_dir}" &&
        -d "${source_dir}" &&
        -f "${source_dir}/fullchain.pem" && ! -L "${source_dir}/fullchain.pem" &&
        -f "${source_dir}/privkey.pem" && ! -L "${source_dir}/privkey.pem" ]] || return 1
    managed_domain="$(acme_main_domain_for_name "${acme_domain}" 2>/dev/null || true)"
    [[ -n "${managed_domain}" && "${managed_domain,,}" == "${acme_domain,,}" ]] || return 1
    validate_tls_certificate_pair \
        "${source_dir}/fullchain.pem" "${source_dir}/privkey.pem" || return 1

    consumer_lines="$(list_active_acme_certificate_consumers "${managed_domain}")" || return 1
    while IFS=$'\t' read -r managed_domain consumer server_name target_dir; do
        [[ -n "${managed_domain}" ]] || continue
        validate_cdn_direct_certificate \
            "${source_dir}/fullchain.pem" "${source_dir}/privkey.pem" \
            "${server_name}" || return 1
        target_key="${target_dir}"
        if [[ -n "${target_consumers[${target_key}]:-}" ]]; then
            [[ "${target_consumers[${target_key}]}" == "${consumer}" ]] || return 1
            continue
        fi
        target_consumers["${target_key}"]="${consumer}"
        consumers+=("${consumer}")
        server_names+=("${server_name}")
        target_dirs+=("${target_dir}")
        consumer_count=$((consumer_count + 1))
    done <<<"${consumer_lines}"

    for ((index = 0; index < consumer_count; index++)); do
        consumer="${consumers[${index}]}"
        server_name="${server_names[${index}]}"
        target_dir="${target_dirs[${index}]}"
        if [[ "${target_dir}" == "${source_dir}" ]]; then
            if [[ "${consumer}" == 'xray' ]]; then
                set_xray_certificate_permissions "${target_dir}" || return 1
            else
                set_nginx_certificate_permissions "${target_dir}" || return 1
            fi
        elif [[ "${consumer}" == 'xray' ]]; then
            install_custom_xray_certificate_pair \
                "${source_dir}/fullchain.pem" "${source_dir}/privkey.pem" \
                "${server_name}" "${target_dir}" || return 1
        else
            install_custom_nginx_certificate_pair \
                "${source_dir}/fullchain.pem" "${source_dir}/privkey.pem" \
                "${server_name}" "${target_dir}" || return 1
        fi
        if [[ "${consumer}" == 'xray' ]]; then
            reload_xray=1
        else
            reload_nginx=1
        fi
    done

    if [[ "${reload_nginx}" -eq 1 ]]; then
        reload_certificate_consumer nginx || reload_status=1
    fi
    if [[ "${reload_xray}" -eq 1 ]]; then
        reload_certificate_consumer xray || reload_status=1
    fi
    return "${reload_status}"
}

function acme_manages_certificate() {
    [[ -n "$(acme_main_domain_for_name "$1")" ]]
}

function current_config_uses_acme_main_domain() {
    local target_main_domain="${1,,}"
    local requested_domain="${2,,}"
    local config_tag candidate managed_domain candidate_lines=''
    local hy2_source='' multi_has_hy2='false'
    local usage_status=1
    local -a candidates=()

    ACME_CONFIG_USES_REQUESTED_DOMAIN=0

    config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')" || return 2
    case "${config_tag,,}" in
    sni)
        candidate_lines="$(echo "${SCRIPT_CONFIG}" | jq -r '
            [.nginx.certificates.domain, .nginx.certificates.cdn][]? |
            select((.source // "" | tostring) == "1") |
            .hostname // empty
        ')" || return 2
        ;;
    cdn)
        if [[ "$(get_cdn_backend)" == 'xray' ]]; then
            candidate_lines="$(echo "${SCRIPT_CONFIG}" | jq -r '
                if (.xray.cdnCertSource // "" | tostring) == "1" then
                    .xray.cdnCertHostname // empty
                else empty end,
                if (.xray.cdnDownCertSource // "" | tostring) == "1" then
                    .xray.cdnDownCertHostname // empty
                else empty end
            ')" || return 2
        else
            candidate_lines="$(echo "${SCRIPT_CONFIG}" | jq -r '
                [.nginx.certificates.cdn, .nginx.certificates.cdnDown][]? |
                select((.source // "" | tostring) == "1") |
                .hostname // empty
            ')" || return 2
        fi
        ;;
    esac
    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] && candidates+=("${candidate}")
    done <<<"${candidate_lines}"

    if [[ "${config_tag,,}" == 'multi' ]]; then
        multi_has_hy2="$(echo "${SCRIPT_CONFIG}" |
            jq -r 'any(.xray.nodes[]?; (.tag | ascii_downcase) == "hy2")')" || return 2
    fi
    hy2_source="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertSource // ""')" || return 2
    if { [[ "${config_tag,,}" == 'hy2' ]] || [[ "${multi_has_hy2}" == 'true' ]]; } &&
        [[ "${hy2_source}" =~ ^[12]$ ]]; then
        candidate_lines="$(echo "${SCRIPT_CONFIG}" | jq -r '
            .xray.hy2CertDomain // empty,
            .xray.hy2CertAcmeDomain // empty
        ')" || return 2
        while IFS= read -r candidate; do
            [[ -n "${candidate}" ]] && candidates+=("${candidate}")
        done <<<"${candidate_lines}"
    fi

    for candidate in "${candidates[@]}"; do
        if [[ -n "${requested_domain}" && "${candidate,,}" == "${requested_domain}" ]]; then
            ACME_CONFIG_USES_REQUESTED_DOMAIN=1
        fi
        managed_domain="$(acme_main_domain_for_name "${candidate}" 2>/dev/null || true)"
        if [[ -n "${managed_domain}" && "${managed_domain,,}" == "${target_main_domain}" ]]; then
            usage_status=0
        fi
    done
    return "${usage_status}"
}

function cleanup_acme_certificate_if_unused() {
    local domain="$1"
    local delete_deployed="${2:-y}"
    local deployed_dir="${3:-${NGINX_CONFIG_DIR}/certs/${domain}}"
    local managed_domain='' usage_status=1

    ACME_CONFIG_USES_REQUESTED_DOMAIN=0
    managed_domain="$(acme_main_domain_for_name "${domain}" 2>/dev/null || true)"
    if [[ -n "${managed_domain}" ]]; then
        current_config_uses_acme_main_domain "${managed_domain}" "${domain}"
        usage_status=$?
        case "${usage_status}" in
        0) ;;
        1) exec_ssl '--stop-renew' "--domain=${domain}" '--keep-cert' || return 1 ;;
        *) return 1 ;;
        esac
    fi
    if [[ "${delete_deployed}" == 'y' && "${ACME_CONFIG_USES_REQUESTED_DOMAIN:-0}" -eq 0 ]]; then
        [[ -n "${deployed_dir}" && "${deployed_dir}" != '/' ]] || return 1
        rm -rf -- "${deployed_dir}" || return 1
    fi
}

function run_with_nginx_temporarily_stopped() (
    local nginx_was_active=0
    local command_status=0

    function restore_temporary_nginx_state() {
        if [[ "${nginx_was_active}" -eq 1 ]] &&
            ! systemctl -q is-active nginx; then
            systemctl -q start nginx
        fi
    }

    # The subshell keeps this EXIT trap isolated from callers. It also restores
    # Nginx when acme.sh is interrupted instead of only covering normal returns.
    trap 'restore_temporary_nginx_state >/dev/null 2>&1 || true' EXIT
    if systemctl -q is-active nginx; then
        nginx_was_active=1
        systemctl -q stop nginx || return 90
    fi

    "$@" || command_status=$?

    if [[ "${nginx_was_active}" -eq 1 ]]; then
        if ! systemctl -q start nginx; then
            return 91
        fi
        nginx_was_active=0
    fi
    trap - EXIT
    [[ "${command_status}" -eq 0 ]] || return 1
)

function handler_restore_certificate_renewal_hooks() {
    local consumer_lines managed_domain consumer server_name target_dir domain_key
    local -A restored_domains=()

    consumer_lines="$(list_active_acme_certificate_consumers)" || return 1
    while IFS=$'\t' read -r managed_domain consumer server_name target_dir; do
        [[ -n "${managed_domain}" ]] || continue
        domain_key="${managed_domain,,}"
        if [[ -n "${restored_domains[${domain_key}]:-}" ]]; then
            continue
        fi
        if [[ "${consumer}" == 'xray' ]]; then
            install_acme_xray_certificate \
                "${managed_domain}" "${server_name}" "${target_dir}" || return 1
        else
            install_acme_nginx_certificate \
                "${managed_domain}" "${server_name}" "${target_dir}" || return 1
        fi
        restored_domains["${domain_key}"]=1
    done <<<"${consumer_lines}"
}

function read_current_crontab() {
    local error_file output

    command -v crontab >/dev/null 2>&1 || return 1
    error_file="$(mktemp)" || return 1
    if output="$(crontab -l 2>"${error_file}")"; then
        rm -f -- "${error_file}"
        printf '%s' "${output}"
        return 0
    fi
    if grep -Eqi 'no crontab([[:space:]]|$)' "${error_file}"; then
        rm -f -- "${error_file}"
        return 0
    fi
    rm -f -- "${error_file}"
    return 1
}

function configure_hy2_ip_renewal_cron() {
    local cert_source="$1"
    local cert_domain="$2"
    local existing_cron='' rendered_cron='' line
    local removed_managed_line=0

    if ! command -v crontab >/dev/null 2>&1; then
        [[ "${cert_source}" != '2' ]]
        return $?
    fi
    existing_cron="$(read_current_crontab)" || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if is_managed_hy2_ip_cron_line "${line}"; then
            removed_managed_line=1
            continue
        fi
        [[ -n "${line}" ]] && rendered_cron+="${line}"$'\n'
    done <<<"${existing_cron}"

    if [[ "${cert_source}" == '2' ]]; then
        rendered_cron+="17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d ${cert_domain} --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1 # xray-script-hy2-ip-renew"$'\n'
    elif [[ "${removed_managed_line}" -eq 0 ]]; then
        return 0
    fi
    printf '%s' "${rendered_cron}" | crontab -
}

function current_config_uses_hy2() {
    local config_tag

    config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')"
    if [[ "${config_tag,,}" == 'hy2' ]]; then
        return 0
    fi
    [[ "${config_tag,,}" == 'multi' ]] &&
        echo "${SCRIPT_CONFIG}" |
            jq -e 'any(.xray.nodes[]?; (.tag | ascii_downcase) == "hy2")' >/dev/null
}

function handler_cdn_direct_cert_role() {
    local action="${1:-prepare}"
    local role="${2:-cdn}"
    local domain source cached_hostname custom_fullchain custom_privkey account_email
    local cert_dir=''
    local acme_exists=0 managed_acme_domain=''
    local acme_action='' acme_status=0 cert_reuse_choice='new'
    local reused_acme_certificate=0

    if [[ "${role}" == 'cdn' ]]; then
        domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn // ""')"
        source="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnCertSource // ""')"
        cached_hostname="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnCertHostname // ""')"
        custom_fullchain="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnCertFullchain // ""')"
        custom_privkey="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnCertPrivkey // ""')"
    else
        domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')"
        source="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnDownCertSource // ""')"
        cached_hostname="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnDownCertHostname // ""')"
        custom_fullchain="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnDownCertFullchain // ""')"
        custom_privkey="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnDownCertPrivkey // ""')"
    fi

    if [[ -z "${domain}" ]] || ! exec_check '--domain-format' "${domain}" >/dev/null 2>&1; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.domain_invalid")" >&2
        return 1
    fi
    if [[ "${cached_hostname}" != "${domain}" ]]; then
        source=''
        custom_fullchain=''
        custom_privkey=''
    fi
    if [[ "${role}" == 'cdnDown' && -z "${source}" ]]; then
        local uplink_source uplink_fullchain uplink_privkey
        uplink_source="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnCertSource // ""')"
        uplink_fullchain="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnCertFullchain // ""')"
        uplink_privkey="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnCertPrivkey // ""')"
        if [[ "${uplink_source}" == '2' ]] &&
            validate_cdn_direct_certificate "${uplink_fullchain}" "${uplink_privkey}" "${domain}"; then
            source='2'
            custom_fullchain="${uplink_fullchain}"
            custom_privkey="${uplink_privkey}"
        fi
    fi

    while [[ ! "${source}" =~ ^[12]$ ]]; do
        local cert_prompt='prompt_cdn_direct'
        [[ "${role}" == 'cdnDown' ]] && cert_prompt='prompt_cdn_down_direct'
        echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.${cert_prompt}")" >&2
        read -r source
        source="${source:-1}"
        if [[ ! "${source}" =~ ^[12]$ ]]; then
            echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.source_invalid")" >&2
        fi
    done
    cert_dir="$(get_cdn_direct_cert_dir "${domain}" "${source}")" || return 1

    if [[ "${source}" == '2' ]]; then
        while [[ -z "${custom_fullchain}" || ! -r "${custom_fullchain}" ]]; do
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.fullchain")" >&2
            read -r custom_fullchain
            custom_fullchain="$(echo "${custom_fullchain}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -r "${custom_fullchain}" ]] ||
                echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.path_invalid")" >&2
        done
        while [[ -z "${custom_privkey}" || ! -r "${custom_privkey}" ]]; do
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.privkey")" >&2
            read -r custom_privkey
            custom_privkey="$(echo "${custom_privkey}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -r "${custom_privkey}" ]] ||
                echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.path_invalid")" >&2
        done
        if ! install_custom_xray_certificate_pair \
                "${custom_fullchain}" "${custom_privkey}" "${domain}" \
                "${cert_dir}"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.cert_invalid")" >&2
            return 1
        fi
    else
        if [[ "${action}" == 'renew' ]]; then
            managed_acme_domain="$(acme_main_domain_for_name "${domain}" 2>/dev/null || true)"
            if [[ -n "${managed_acme_domain}" ]]; then
                acme_exists=1
                acme_action='renew'
            else
                acme_action='issue'
            fi
        elif [[ "${action}" == 'install' ]]; then
            managed_acme_domain="$(acme_main_domain_for_name "${domain}" 2>/dev/null || true)"
            [[ -n "${managed_acme_domain}" ]] || return 1
            acme_exists=1
        else
            cert_reuse_choice="$(prompt_cert_reuse "${domain}" 'acme')"
            if [[ "${cert_reuse_choice}" == 'new' ]]; then
                acme_action='issue'
            else
                echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_reuse.reusing") ${cert_reuse_choice}" >&2
                managed_acme_domain="$(acme_main_domain_for_name "${cert_reuse_choice}" 2>/dev/null || true)"
                if [[ -z "${managed_acme_domain}" ]]; then
                    echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.apply_fail")" >&2
                    return 1
                fi
                acme_exists=1
                reused_acme_certificate=1
            fi
        fi

        if [[ "${acme_action}" == 'issue' ]]; then
            account_email="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.ca // ""')"
            if ! exec_check '--email' "${account_email}" >/dev/null 2>&1; then
                exec_read 'email' || return 1
                account_email="${CONFIG_DATA['email']:-}"
                if ! exec_check '--email' "${account_email}" >/dev/null 2>&1; then
                    echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.email_invalid")" >&2
                    return 1
                fi
                SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg email "${account_email}" '.nginx.ca = $email')"
                write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
            fi
        fi

        if [[ -n "${acme_action}" ]]; then
            handler_ssl_install || return 1
            if [[ "${acme_action}" == 'renew' ]]; then
                if run_with_nginx_temporarily_stopped \
                    "${ACME_PATH}" --renew -d "${managed_acme_domain}" --ecc --force \
                    --home "${HOME}/.acme.sh"; then
                    acme_status=0
                else
                    acme_status=$?
                fi
            else
                echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.applying")" >&2
                if run_with_nginx_temporarily_stopped \
                    "${ACME_PATH}" --issue -d "${domain}" \
                    --standalone \
                    --keylength ec-256 \
                    --accountkeylength ec-256 \
                    --accountemail "${account_email}" \
                    --server zerossl \
                    --ocsp \
                    --force; then
                    acme_status=0
                else
                    acme_status=$?
                fi
            fi

            if [[ "${acme_status}" -eq 90 ]]; then
                echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.nginx_stop_fail")" >&2
                return 1
            fi
            if [[ "${acme_status}" -eq 91 ]]; then
                echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.nginx_restore_fail")" >&2
                return 1
            fi
            if [[ "${acme_status}" -ne 0 ]]; then
                if [[ "${acme_action}" == 'renew' ]]; then
                    echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.renew_fail")" >&2
                else
                    echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.apply_fail")" >&2
                fi
                return 1
            fi
            acme_exists=1
            managed_acme_domain="$(acme_main_domain_for_name "${domain}" 2>/dev/null || true)"
            [[ -n "${managed_acme_domain}" ]] || return 1
        fi

        # Reinstall on every prepare, even when the current files are valid.
        # Nginx and Xray use the same ACME domain record, so this rebinds the
        # renewal target and reload command to the selected backend.
        if [[ "${acme_exists}" -ne 1 ]] ||
            ! install_acme_xray_certificate \
                "${managed_acme_domain}" "${domain}" "${cert_dir}"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.apply_fail")" >&2
            return 1
        fi
        if [[ "${reused_acme_certificate}" -eq 1 ]]; then
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_reuse.reuse_ok")" >&2
        fi
    fi

    validate_cdn_direct_certificate \
        "${cert_dir}/fullchain.pem" \
        "${cert_dir}/privkey.pem" \
        "${domain}" || return 1
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq \
        --arg role "${role}" \
        --arg hostname "${domain}" \
        --arg source "${source}" \
        --arg fullchain "${custom_fullchain}" \
        --arg privkey "${custom_privkey}" '
        if $role == "cdn" then
            .xray.cdnCertHostname = $hostname |
            .xray.cdnCertSource = $source |
            .xray.cdnCertFullchain = $fullchain |
            .xray.cdnCertPrivkey = $privkey
        else
            .xray.cdnDownCertHostname = $hostname |
            .xray.cdnDownCertSource = $source |
            .xray.cdnDownCertFullchain = $fullchain |
            .xray.cdnDownCertPrivkey = $privkey
        end |
        .xray.port = 443
    ')"
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.ready")" >&2
}

function handler_cdn_direct_cert() {
    local action="${1:-prepare}"
    local role role_action domain source managed_domain domain_key cdn_down
    local -a roles=(cdn)
    local -A renewed_domains=()

    cdn_down="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')" || return 1
    if [[ -n "${cdn_down}" ]]; then
        roles+=(cdnDown)
    fi
    for role in "${roles[@]}"; do
        role_action="${action}"
        if [[ "${action}" == 'renew' ]]; then
            domain="$(echo "${SCRIPT_CONFIG}" | jq -r \
                --arg role "${role}" '.nginx[$role] // ""')" || return 1
            if [[ "${role}" == 'cdn' ]]; then
                source="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnCertSource // ""')" || return 1
            else
                source="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnDownCertSource // ""')" || return 1
            fi
            if [[ "${source}" == '1' ]]; then
                managed_domain="$(acme_main_domain_for_name "${domain}" 2>/dev/null || true)"
                [[ -n "${managed_domain}" ]] || return 1
                domain_key="${managed_domain,,}"
                if [[ -n "${renewed_domains[${domain_key}]:-}" ]]; then
                    role_action='install'
                fi
            fi
        fi
        handler_cdn_direct_cert_role "${role_action}" "${role}" || return 1
        if [[ "${action}" == 'renew' && "${source:-}" == '1' ]]; then
            renewed_domains["${domain_key}"]=1
        fi
    done
}

function handler_change_cdn_down_direct() {
    local old_config="${SCRIPT_CONFIG}"
    local old_domain old_source new_domain runtime_snapshot=''
    local new_acme_preexisting=0 new_acme_created=0
    local acme_cert_dir custom_cert_dir acme_cert_dir_preexisting=0 custom_cert_dir_preexisting=0
    local runtime_state='missing' operation_status=0

    old_domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')"
    old_source="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.cdnDownCertSource // ""')"
    exec_read 'cdn-down' || return 1
    new_domain="${CONFIG_DATA['cdn-down']:-}"
    [[ "${new_domain}" != "${old_domain}" ]] || return 0

    if [[ -n "${new_domain}" ]]; then
        acme_manages_certificate "${new_domain}" && new_acme_preexisting=1
        acme_cert_dir="$(get_cdn_direct_cert_dir "${new_domain}" '1')" || return 1
        custom_cert_dir="$(get_cdn_direct_cert_dir "${new_domain}" '2')" || return 1
        [[ -e "${acme_cert_dir}" ]] && acme_cert_dir_preexisting=1
        [[ -e "${custom_cert_dir}" ]] && custom_cert_dir_preexisting=1
    fi

    if [[ -L "${XRAY_CONFIG_PATH}" ]]; then
        return 1
    elif [[ -f "${XRAY_CONFIG_PATH}" ]]; then
        runtime_state='file'
        runtime_snapshot="$(mktemp "${XRAY_CONFIG_PATH}.cdn-down.XXXXXX")" || return 1
        cp -p -- "${XRAY_CONFIG_PATH}" "${runtime_snapshot}" || {
            rm -f -- "${runtime_snapshot}"
            return 1
        }
    elif [[ -e "${XRAY_CONFIG_PATH}" ]]; then
        return 1
    fi

    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg domain "${new_domain}" '
        .nginx.certificates //= {} |
        .nginx.cdnDown = $domain |
        .nginx.certificates.cdnDown = {hostname:"",source:"",fullchain:"",privkey:""} |
        .xray.cdnDownCertHostname = "" |
        .xray.cdnDownCertSource = "" |
        .xray.cdnDownCertFullchain = "" |
        .xray.cdnDownCertPrivkey = ""
    ')" || operation_status=1
    if [[ "${operation_status}" -eq 0 ]]; then
        write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || operation_status=1
    fi
    if [[ "${operation_status}" -eq 0 && -n "${new_domain}" ]]; then
        handler_cdn_direct_cert_role 'prepare' 'cdnDown' || operation_status=1
        if [[ "${new_acme_preexisting}" -eq 0 ]] && acme_manages_certificate "${new_domain}"; then
            new_acme_created=1
        fi
    fi
    if [[ "${operation_status}" -eq 0 ]]; then
        handler_xray_config 1 || operation_status=1
    fi
    if [[ "${operation_status}" -eq 0 ]]; then
        handler_restart || operation_status=1
    fi

    if [[ "${operation_status}" -ne 0 ]]; then
        SCRIPT_CONFIG="${old_config}"
        write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || true
        if [[ "${runtime_state}" == 'file' ]]; then
            cp -p -- "${runtime_snapshot}" "${XRAY_CONFIG_PATH}" || true
        else
            rm -f -- "${XRAY_CONFIG_PATH}" || true
        fi
        handler_restart >/dev/null 2>&1 || true
        if [[ "${new_acme_created}" -eq 1 ]]; then
            cleanup_acme_certificate_if_unused \
                "${new_domain}" 'y' "${acme_cert_dir}" >/dev/null 2>&1 || true
        fi
        if [[ "${acme_cert_dir_preexisting}" -eq 0 && -n "${acme_cert_dir}" ]]; then
            rm -rf -- "${acme_cert_dir}"
        fi
        if [[ "${custom_cert_dir_preexisting}" -eq 0 && -n "${custom_cert_dir}" ]]; then
            rm -rf -- "${custom_cert_dir}"
        fi
        [[ -z "${runtime_snapshot}" ]] || rm -f -- "${runtime_snapshot}"
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_split.config_fail")" >&2
        return 1
    fi

    [[ -z "${runtime_snapshot}" ]] || rm -f -- "${runtime_snapshot}"
    if [[ -n "${old_domain}" && "${old_domain}" != "${new_domain}" && "${old_source}" == '1' ]] &&
        acme_manages_certificate "${old_domain}"; then
        local old_acme_cert_dir=''
        old_acme_cert_dir="$(get_cdn_direct_cert_dir "${old_domain}" '1')" || true
        [[ -z "${old_acme_cert_dir}" ]] ||
            cleanup_acme_certificate_if_unused \
                "${old_domain}" 'y' "${old_acme_cert_dir}" || true
    fi
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_split.updated")" >&2
}

function handler_change_cdn_down_nginx() {
    local old_config="${SCRIPT_CONFIG}"
    local old_domain new_domain transaction_dir='' runtime_snapshot=''
    local operation_status=0

    old_domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')"
    exec_read 'cdn-down' || return 1
    new_domain="${CONFIG_DATA['cdn-down']:-}"
    [[ "${new_domain}" != "${old_domain}" ]] || return 0
    transaction_dir="$(create_change_domain_transaction "${old_domain}" "${new_domain}")" || return 1
    if [[ -L "${XRAY_CONFIG_PATH}" || ( -e "${XRAY_CONFIG_PATH}" && ! -f "${XRAY_CONFIG_PATH}" ) ]]; then
        cleanup_change_domain_transaction "${transaction_dir}" || true
        return 1
    elif [[ -f "${XRAY_CONFIG_PATH}" ]]; then
        runtime_snapshot="$(mktemp "${XRAY_CONFIG_PATH}.cdn-down.XXXXXX")" || {
            cleanup_change_domain_transaction "${transaction_dir}" || true
            return 1
        }
        cp -p -- "${XRAY_CONFIG_PATH}" "${runtime_snapshot}" || {
            rm -f -- "${runtime_snapshot}"
            cleanup_change_domain_transaction "${transaction_dir}" || true
            return 1
        }
    fi

    # Defer deletion of the old renewal target until Xray has accepted the
    # updated runtime; the outer transaction can then restore it intact.
    handler_change_domain 'cdnDown' 'n' 'y' || operation_status=1
    if [[ "${operation_status}" -eq 0 ]]; then
        handler_web "$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.web // "normal"')" 'n' || operation_status=1
    fi
    if [[ "${operation_status}" -eq 0 ]]; then
        handler_xray_config 1 || operation_status=1
    fi
    if [[ "${operation_status}" -eq 0 ]]; then
        handler_restart || operation_status=1
    fi
    if [[ "${operation_status}" -ne 0 ]]; then
        SCRIPT_CONFIG="${old_config}"
        write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || true
        if [[ -n "${runtime_snapshot}" ]]; then
            cp -p -- "${runtime_snapshot}" "${XRAY_CONFIG_PATH}" || true
        else
            rm -f -- "${XRAY_CONFIG_PATH}" || true
        fi
        rollback_change_domain_transaction "${transaction_dir}" 'y' || true
        handler_restore_certificate_renewal_hooks >/dev/null 2>&1 || true
        handler_restart >/dev/null 2>&1 || true
        [[ -z "${runtime_snapshot}" ]] || rm -f -- "${runtime_snapshot}"
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_split.config_fail")" >&2
        return 1
    fi
    cleanup_change_domain_transaction "${transaction_dir}" || return 1
    [[ -z "${runtime_snapshot}" ]] || rm -f -- "${runtime_snapshot}"
    if [[ -n "${old_domain}" && "${old_domain}" != "${new_domain}" ]] &&
        acme_manages_certificate "${old_domain}"; then
        cleanup_acme_certificate_if_unused "${old_domain}" 'y' || true
    fi
    echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_split.updated")" >&2
}

function handler_cleanup_stale_cdn_down() {
    local stale_domain="$1"
    local cleanup_mode="${2:-all}"
    local nginx_cert_dir direct_acme_dir direct_custom_dir

    [[ -n "${stale_domain}" ]] || return 0
    exec_check '--domain-format' "${stale_domain}" >/dev/null 2>&1 || return 1
    if [[ "${stale_domain}" == "$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.domain // ""')" ||
        "${stale_domain}" == "$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn // ""')" ||
        "${stale_domain}" == "$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')" ]]; then
        return 0
    fi
    nginx_cert_dir="${NGINX_CONFIG_DIR}/certs/${stale_domain}"
    direct_acme_dir="$(get_cdn_direct_cert_dir "${stale_domain}" '1')" || return 1
    direct_custom_dir="$(get_cdn_direct_cert_dir "${stale_domain}" '2')" || return 1
    if [[ "${cleanup_mode}" != 'renew-only' ]]; then
        rm -f -- \
            "${NGINX_CONFIG_DIR}/sites-available/${stale_domain}.conf" \
            "${NGINX_CONFIG_DIR}/sites-enabled/${stale_domain}.conf" || return 1
    fi
    if acme_manages_certificate "${stale_domain}"; then
        cleanup_acme_certificate_if_unused \
            "${stale_domain}" 'y' "${nginx_cert_dir}" || return 1
    else
        rm -rf -- "${nginx_cert_dir}" || return 1
    fi
    rm -rf -- "${direct_acme_dir}" "${direct_custom_dir}" || return 1
}

# =============================================================================
# 函数名称: handler_hy2_cert
# 功能描述: 处理 HY2 协议的证书申请与安装。
#           1. 根据证书来源 (acme域名/acme IP/自定义路径) 申请或安装证书。
#           2. 使用 acme.sh standalone 模式 (临时监听80端口) 申请证书。
#           3. 配置证书自动续签 (域名90天/IP 5天)。
# 参数: 无
# 返回值: 0-成功 1-失败
# =============================================================================
function handler_hy2_cert() {
    local CERT_SOURCE="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertSource // ""')"
    local CERT_DOMAIN="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertDomain // ""')"
    local ACCOUNT_EMAIL="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.ca // ""')"
    local CERT_ACME_DOMAIN="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertAcmeDomain // ""')"
    local CERT_DIR=''
    local certificate_ready=0
    local acme_status=0

    case "${CERT_SOURCE}" in
    1)
        exec_check '--domain-format' "${CERT_DOMAIN}" >/dev/null 2>&1 || return 1
        ;;
    2)
        exec_check '--ip' "${CERT_DOMAIN}" >/dev/null 2>&1 || return 1
        ;;
    3)
        [[ -n "${CERT_DOMAIN}" && "${CERT_DOMAIN}" != *$'\n'* ]] || return 1
        ;;
    *)
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.source_invalid")" >&2
        return 1
        ;;
    esac
    CERT_DIR="$(get_hy2_cert_dir "${CERT_DOMAIN}" "${CERT_SOURCE}")" || return 1

    # 证书成功后由 Xray 配置阶段统一开放端口，避免失败时残留规则或重复添加。
    case "${CERT_SOURCE}" in
    1|2)
        # acme.sh 申请证书 (standalone 模式)
        # 非首次安装时，检测已有证书并询问用户
        local cert_reuse_choice
        cert_reuse_choice="$(prompt_cert_reuse "${CERT_DOMAIN}" "xray" "${CERT_SOURCE}")"

        if [[ "${cert_reuse_choice}" != "new" ]]; then
            # 用户选择复用已有证书
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_reuse.reusing")" >&2
            mkdir -p "${CERT_DIR}"
            local reuse_acme_domain="${cert_reuse_choice}"
            local managed_reuse_acme_domain=''
            if [[ "${cert_reuse_choice}" == "xray-certs" ||
                "${cert_reuse_choice}" == "legacy-xray-certs" ]]; then
                reuse_acme_domain="${CERT_ACME_DOMAIN:-${CERT_DOMAIN}}"
            fi
            # Automatic certificate sources may only reuse a certificate that
            # still has a matching ECC record in acme.sh. Reinstalling it here
            # also rebinds the renewal target and reload hook to this isolated
            # HY2 directory instead of leaving an old fixed-path hook behind.
            managed_reuse_acme_domain="$(acme_main_domain_for_name "${reuse_acme_domain}" 2>/dev/null || true)"
            if [[ -z "${managed_reuse_acme_domain}" ]] ||
                ! install_acme_xray_certificate \
                    "${managed_reuse_acme_domain}" "${CERT_DOMAIN}" "${CERT_DIR}"; then
                echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.apply_fail")" >&2
                return 1
            fi
            CERT_ACME_DOMAIN="${managed_reuse_acme_domain}"
            if [[ ! -r "${CERT_DIR}/fullchain.pem" || ! -r "${CERT_DIR}/privkey.pem" ]]; then
                echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.apply_fail")" >&2
                return 1
            fi
            if ! validate_cdn_direct_certificate \
                    "${CERT_DIR}/fullchain.pem" \
                    "${CERT_DIR}/privkey.pem" \
                    "${CERT_DOMAIN}"; then
                echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.name_mismatch")" >&2
                return 1
            fi
            set_xray_certificate_permissions "${CERT_DIR}" || return 1
            certificate_ready=1
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_reuse.reuse_ok")" >&2
        else
            # 用户选择重新申请证书
            local previous_cert_fingerprint=''
            local installed_cert_fingerprint=''
            if [[ -r "${CERT_DIR}/fullchain.pem" ]]; then
                previous_cert_fingerprint="$(certificate_sha256_fingerprint "${CERT_DIR}/fullchain.pem" || true)"
            fi
            if ! exec_check '--email' "${ACCOUNT_EMAIL}"; then
                echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.email_invalid")" >&2
                return 1
            fi
            # 确保 acme.sh 已安装
            if [[ ! -e "${HOME}/.acme.sh/acme.sh" ]]; then
                echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} Installing acme.sh..." >&2
                curl https://get.acme.sh | sh -s email="${ACCOUNT_EMAIL}" || {
                    echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.apply_fail")" >&2
                    return 1
                }
                "${HOME}/.acme.sh/acme.sh" --upgrade --auto-upgrade || return 1
                "${HOME}/.acme.sh/acme.sh" --set-default-ca --server zerossl || return 1
            fi

            # 创建证书存储目录
            mkdir -p "${CERT_DIR}" || return 1

            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.applying")" >&2

            if [[ "${CERT_SOURCE}" == "1" ]]; then
                # 域名证书: 使用 standalone 模式 (临时监听80端口), ZeroSSL
                if run_with_nginx_temporarily_stopped \
                    "${HOME}/.acme.sh/acme.sh" --issue -d "${CERT_DOMAIN}" \
                    --standalone \
                    --keylength ec-256 \
                    --accountkeylength ec-256 \
                    --accountemail "${ACCOUNT_EMAIL}" \
                    --server zerossl \
                    --ocsp \
                    --force; then
                    acme_status=0
                else
                    acme_status=$?
                fi
                if [[ "${acme_status}" -ne 0 ]]; then
                    if [[ "${acme_status}" -eq 90 ]]; then
                        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.nginx_stop_fail")" >&2
                    elif [[ "${acme_status}" -eq 91 ]]; then
                        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.nginx_restore_fail")" >&2
                    fi
                    echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.apply_fail")" >&2
                    return 1
                fi
            else
                # IP 证书: Let's Encrypt + shortlived profile (仅此 profile 支持 IP 标识符)
                # 证书有效期短 (约一周)，--days 3 设置每 3 天检查续签
                if run_with_nginx_temporarily_stopped \
                    "${HOME}/.acme.sh/acme.sh" --issue -d "${CERT_DOMAIN}" \
                    --standalone \
                    --keylength ec-256 \
                    --accountemail "${ACCOUNT_EMAIL}" \
                    --server letsencrypt \
                    --certificate-profile shortlived \
                    --days 3 \
                    --force; then
                    acme_status=0
                else
                    acme_status=$?
                fi
                if [[ "${acme_status}" -ne 0 ]]; then
                    if [[ "${acme_status}" -eq 90 ]]; then
                        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.nginx_stop_fail")" >&2
                    elif [[ "${acme_status}" -eq 91 ]]; then
                        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.nginx_restore_fail")" >&2
                    fi
                    echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.apply_fail")" >&2
                    return 1
                fi
            fi

            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.apply_ok")" >&2

            # 安装证书到 Xray 目录
            CERT_ACME_DOMAIN="$(acme_main_domain_for_name "${CERT_DOMAIN}" 2>/dev/null || true)"
            [[ -n "${CERT_ACME_DOMAIN}" ]] || return 1
            install_acme_xray_certificate \
                "${CERT_ACME_DOMAIN}" "${CERT_DOMAIN}" "${CERT_DIR}" || {
                echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.apply_fail")" >&2
                return 1
            }

            if ! validate_cdn_direct_certificate \
                    "${CERT_DIR}/fullchain.pem" \
                    "${CERT_DIR}/privkey.pem" \
                    "${CERT_DOMAIN}"; then
                echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.apply_fail")" >&2
                return 1
            fi
            installed_cert_fingerprint="$(certificate_sha256_fingerprint "${CERT_DIR}/fullchain.pem" || true)"
            if [[ -z "${installed_cert_fingerprint}" ||
                ( -n "${previous_cert_fingerprint}" &&
                    "${installed_cert_fingerprint}" == "${previous_cert_fingerprint}" ) ]]; then
                # A "new" request must actually install the newly issued
                # certificate. Otherwise an old valid pair can hide an ACME
                # client that printed an error but returned success.
                echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.apply_fail")" >&2
                return 1
            fi

            set_xray_certificate_permissions "${CERT_DIR}" || return 1
            certificate_ready=1

            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.install_ok")" >&2

        fi # 结束 cert_reuse_choice 判断
        ;;
    3)
        # 自定义证书: 不需要 acme.sh
        local CUSTOM_FULLCHAIN="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertFullchain')"
        local CUSTOM_PRIVKEY="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.hy2CertPrivkey')"

        if ! validate_cdn_direct_certificate \
                "${CUSTOM_FULLCHAIN}" "${CUSTOM_PRIVKEY}" "${CERT_DOMAIN}"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.pair_invalid")" >&2
            return 1
        fi

        # 证书与私钥作为一对原子替换，避免第二个复制失败后留下不匹配文件。
        if ! install_custom_xray_certificate_pair_in_place \
                "${CUSTOM_FULLCHAIN}" "${CUSTOM_PRIVKEY}" "${CERT_DOMAIN}" \
                "${CERT_DIR}"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.path_invalid")" >&2
            return 1
        fi

        certificate_ready=1

        echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.install_ok")" >&2
        ;;
    *)
        return 1
        ;;
    esac

    # Only an installed and validated certificate may unlock Xray config
    # generation. This explicit gate prevents an unexpected ACME fallthrough
    # from being treated as success by any caller.
    [[ "${certificate_ready}" -eq 1 ]] || return 1
    if [[ "${CERT_SOURCE}" =~ ^[12]$ ]]; then
        echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.cron_setup")" >&2
    fi
    if ! configure_hy2_ip_renewal_cron "${CERT_SOURCE}" "${CERT_DOMAIN}"; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.cron_fail")" >&2
        return 1
    fi
    if [[ "${CERT_SOURCE}" =~ ^[12]$ ]]; then
        # Domain certificates use acme.sh's normal renewal job. IP
        # certificates additionally use the script-owned short-lived job.
        echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.cron_ok")" >&2
    fi
    if [[ "${CERT_SOURCE}" =~ ^[12]$ ]]; then
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq \
            --arg acme_domain "${CERT_ACME_DOMAIN}" \
            '.xray.hy2CertAcmeDomain = $acme_domain')"
    else
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.hy2CertAcmeDomain = ""')"
    fi
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
}

# =============================================================================
# 函数名称: handler_prepare_protocol_services
# 功能描述: 按协议准备 Nginx/Web 服务，SNI 与 CDN 使用独立分支。
# 参数:
#   $1: web - Web 服务类型 (normal, v3, v4)
# 返回值: 无 (通过调用其他函数执行操作)
# =============================================================================
function handler_prepare_protocol_services() {
    # 从脚本配置中读取当前配置标签
    local CONFIG_TAG="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag')"
    local web="${1}" # 获取 Web 服务类型参数
    if [[ "${CONFIG_TAG,,}" == 'cdn' ]]; then
        validate_cdn_split_domains || return 1
    fi
    if ! current_protocol_uses_nginx; then
        # Keep the old Nginx/Cloudreve stack online until the replacement
        # runtime JSON has passed validation. handler_restart performs the
        # listener handoff and only stops Cloudreve after Xray is healthy.
        return 0
    fi

    if xray_runtime_owns_tcp_443 && systemctl -q is-active xray; then
        if ! systemctl -q stop xray; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.release_port_fail")" >&2
            return 1
        fi
    fi

    case "${CONFIG_TAG,,}" in
    sni)
        handler_change_domain 'domain' 'n' 'n' || return 1
        handler_change_domain 'cdn' 'n' 'n' || return 1
        handler_web "${web}" 'n' || return 1
        ;;
    cdn)
        # 从 SNI 切换到纯 CDN 时，旧直连站点不能继续被 Nginx 加载。
        local stale_domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.domain // ""')"
        if [[ -n "${stale_domain}" ]]; then
            rm -f "${NGINX_CONFIG_DIR}/sites-enabled/${stale_domain}.conf"
        fi
        handler_change_domain 'cdn' 'n' 'n' || return 1
        local cdn_down_domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')"
        if [[ -n "${cdn_down_domain}" ]]; then
            handler_change_domain 'cdnDown' 'n' 'n' || return 1
        fi
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.nginx.domain = ""')"
        write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
        handler_web "${web}" 'n' || return 1
        ;;
    esac
}

# =============================================================================
# 函数名称: handler_xray_version
# 功能描述: 处理 Xray 版本配置。
#           1. 根据输入参数确定 Xray 版本。
#           2. 从 GitHub API 获取最新版本或自定义版本。
#           3. 将版本信息更新到脚本配置中。
# 参数:
#   $1: xray_version - 版本指定 ("latest", "custom", 或具体版本号)，默认为 release
# 返回值: 无 (直接修改 CONFIG_DATA 和 SCRIPT_CONFIG 全局变量)
# =============================================================================
function handler_xray_version() {
    local xray_version="$1" # 获取版本指定参数
    # 根据版本指定参数确定具体版本
    case "${xray_version,,}" in
    latest)
        # 获取最新的 Xray 版本
        CONFIG_DATA['version']="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases | jq -r '.[0].tag_name')"
        ;;
    custom)
        # 读取用户自定义的版本
        exec_read 'version' || return 1
        ;;
    *)
        # 获取最新的 release 版本
        CONFIG_DATA['version']="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')"
        ;;
    esac
    if [[ -z "${CONFIG_DATA['version']:-}" || "${CONFIG_DATA['version']}" == 'null' ]]; then
        _error "$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.xray_version.fetch_fail")"
    fi
    # 更新脚本配置中的 Xray 版本
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg xray "${CONFIG_DATA['version']}" '.xray.version = $xray')"
    # 将更新后的脚本配置写入文件
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
}

# =============================================================================
# 函数名称: handler_change_xray_port
# 功能描述: 修改 Xray 端口配置。
# 参数: 无
# 返回值: 无 (直接修改 SCRIPT_CONFIG 全局变量)
# =============================================================================
function handler_change_xray_port() {
    # 默认端口
    local XRAY_PORT="443"
    # 获取配置标签
    local CONFIG_TAG="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag')"
    local previous_script_config="${SCRIPT_CONFIG}" previous_xray_config

    if ! protocol_reads_public_port "${CONFIG_TAG}"; then
        echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.port.fixed")" >&2
        return 1
    fi

    # 读取端口
    exec_read 'port' || return 1

    # 根据配置标签处理端口
    case "${CONFIG_TAG,,}" in
    mkcp)
        # 输入为空，则默认为 mKCP 生成随机端口
        XRAY_PORT="${CONFIG_DATA['port']:-$(exec_generate '--port')}"
        ;;
    *)
        # 输入为空，则使用默认端口
        XRAY_PORT="${CONFIG_DATA['port']:-${XRAY_PORT}}"
        ;;
    esac

    # 更新脚本配置中的 Xray 端口
    previous_xray_config="$(jq '.' "${XRAY_CONFIG_PATH}")" || return 1
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson port "${XRAY_PORT}" '.xray.port = $port')" || return 1
    apply_xray_state_transaction "${previous_script_config}" "${previous_xray_config}"
}

# =============================================================================
# 函数名称: handler_install
# 功能描述: 安装 Xray 核心。
#           1. 确定要安装的 Xray 版本。
#           2. 检查系统中是否已安装 Xray。
#           3. 如果未安装或强制安装，则从 Xray-install 脚本安装。
# 参数:
#   $1: xray_version - (可选) 要安装的 Xray 版本
#   $2: force_install - (可选) 是否强制安装 ('y' 表示强制)，默认为 'n'
# 返回值: 无 (通过调用外部脚本执行安装)
# =============================================================================
function handler_install() {
    # 确保服务用户和共享组存在（Xray-install 的 -u xray 依赖用户已创建）
    ensure_service_users || return 1
    local xray_version="${1:-}"   # 获取版本参数
    local force_install="${2:-n}" # 获取强制安装参数，默认为 'n'
    # 如果提供了版本参数，则处理版本配置
    if [[ -n "${xray_version}" ]]; then
        handler_xray_version "${xray_version}" || return 1
    else
        # 否则从脚本配置中读取版本
        CONFIG_DATA['version']="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.version')"
        if [[ -z "${CONFIG_DATA['version']}" || "${CONFIG_DATA['version']}" == 'null' ]]; then
            handler_xray_version 'release' || return 1
        fi
    fi
    # 检查 Xray 命令是否存在，或是否强制安装
    if ! cmd_exists 'xray' || [[ "${force_install}" != n ]]; then
        local use_gh_proxy_reply
        use_gh_proxy_reply="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.githubProxy // ""')"
        case "${use_gh_proxy_reply,,}" in
        y | n)
            use_gh_proxy_reply="${use_gh_proxy_reply,,}"
            ;;
        *)
            # 独立运行安装命令时，配置问卷可能没有先执行，保留交互兜底。
            run_github_proxy_choice 'n' || return 1
            use_gh_proxy_reply="${CONFIG_DATA['github_proxy']}"
            SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg githubProxy "${use_gh_proxy_reply}" '.xray.githubProxy = $githubProxy')"
            write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
            ;;
        esac
        local install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
        local script_content
        if [[ "${use_gh_proxy_reply,,}" == "y" ]]; then
            # 使用 gh-proxy.com：格式为 https://gh-proxy.com/ + 完整 GitHub 原始链接(含 https://)
            local gh_proxy_prefix="https://gh-proxy.com/"
            install_script_url="${gh_proxy_prefix}${install_script_url}"
        fi

        if ! script_content="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 "${install_script_url}")"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.gh_proxy.fetch_fail")" >&2
            return 1
        fi
        if [[ "${use_gh_proxy_reply,,}" == "y" ]]; then
            # 将脚本内 GitHub 地址改为经 gh-proxy 加速
            script_content="$(printf '%s\n' "${script_content}" | sed 's|https://api\.github\.com|https://gh-proxy.com/https://api.github.com|g; s|https://github\.com|https://gh-proxy.com/https://github.com|g')"
        fi
        if [[ -z "${script_content}" ]] || ! bash -n <<<"${script_content}"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.gh_proxy.invalid_script")" >&2
            return 1
        fi
        if ! printf '%s\n' "${script_content}" | bash -s -- install -u xray --version "${CONFIG_DATA['version']}"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.gh_proxy.install_fail")" >&2
            return 1
        fi
        if ! cmd_exists 'xray'; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.gh_proxy.xray_missing")" >&2
            return 1
        fi
    fi
}

# =============================================================================
# 函数名称: handler_purge
# 功能描述: 卸载 Xray 核心及其配置。
# 参数: 无
# 返回值: 无 (通过调用外部脚本执行卸载)
# =============================================================================
function handler_purge() {
    local install_script_url='https://github.com/XTLS/Xray-install/raw/main/install-release.sh'
    local script_content=''
    local updated_config=''
    local staged_config=''

    if ! script_content="$(curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 "${install_script_url}")"; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} Failed to download the Xray uninstall script." >&2
        return 1
    fi
    if [[ -z "${script_content}" ]] || ! bash -n <<<"${script_content}"; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} Refusing to run an invalid Xray uninstall script." >&2
        return 1
    fi

    updated_config="$(reset_json_fields "${SCRIPT_CONFIG}" 'xray')" || return 1
    staged_config="$(mktemp "${SCRIPT_CONFIG_PATH}.purge.XXXXXX")" || return 1
    if ! write_config "${updated_config}" "${staged_config}"; then
        rm -f -- "${staged_config}"
        return 1
    fi

    if ! bash -s -- remove --purge <<<"${script_content}"; then
        rm -f -- "${staged_config}"
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} Xray uninstall failed; local state was preserved." >&2
        return 1
    fi

    if ! mv -fT -- "${staged_config}" "${SCRIPT_CONFIG_PATH}"; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} Xray was removed, but the prepared local state could not be committed. Recovery file: ${staged_config}" >&2
        return 1
    fi
    sync
    SCRIPT_CONFIG="${updated_config}"
}

# =============================================================================
# 函数名称: handler_start
# 功能描述: 启动 Xray 服务。
#           1. 检查 Xray 服务是否已在运行。
#           2. 如果未运行则启动服务。
#           3. 检查 Xray 服务是否已设置开机自启。
#           4. 如果未设置则启用开机自启。
# 参数: 无
# 返回值: 无 (通过 systemctl 命令执行操作)
# =============================================================================
function report_xray_service_failure() {
    local action="$1"
    local message
    case "${action}" in
    start) message="$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.xray_service.start_fail")" ;;
    restart) message="$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.xray_service.restart_fail")" ;;
    enable) message="$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.xray_service.enable_fail")" ;;
    *) message="$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.xray_service.active_fail")" ;;
    esac
    echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} ${message}" >&2
    systemctl --no-pager --full status xray >&2 || true
}

function handler_start() {
    # 清除此前因 Socket 目录缺失等原因触发的 systemd 启动频率限制。
    systemctl reset-failed xray 2>/dev/null || true
    # 检查 Xray 服务是否活跃，如果不活跃则启动
    if ! systemctl -q is-active xray && ! systemctl -q start xray; then
        report_xray_service_failure start
        return 1
    fi
    # 检查 Xray 服务是否已启用，如果未启用则启用
    if ! systemctl -q is-enabled xray && ! systemctl -q enable xray; then
        report_xray_service_failure enable
        return 1
    fi
    if ! systemctl -q is-active xray; then
        report_xray_service_failure active
        return 1
    fi
}

# =============================================================================
# 函数名称: handler_stop
# 功能描述: 停止 Xray 服务。
#           1. 检查 Xray 服务是否正在运行。
#           2. 如果正在运行则停止服务。
#           3. 检查 Xray 服务是否已设置开机自启。
#           4. 如果已设置则禁用开机自启。
# 参数: 无
# 返回值: 无 (通过 systemctl 命令执行操作)
# =============================================================================
function handler_stop() {
    # 检查 Xray 服务是否活跃，如果活跃则停止
    if systemctl -q is-active xray && ! systemctl -q stop xray; then
        return 1
    fi
    # 检查 Xray 服务是否已启用，如果启用则禁用
    if systemctl -q is-enabled xray && ! systemctl -q disable xray; then
        return 1
    fi
    return 0
}

function restore_nginx_service_state() {
    local should_be_active="$1"
    local should_be_enabled="$2"
    local restore_status=0

    if [[ "${should_be_active}" -eq 1 ]]; then
        # A failed direct-Xray listener may still own TCP/443.
        if systemctl -q is-active xray && ! systemctl -q stop xray; then
            restore_status=1
        fi
        if ! systemctl -q is-active nginx && ! systemctl -q start nginx; then
            restore_status=1
        fi
    elif systemctl -q is-active nginx && ! systemctl -q stop nginx; then
        restore_status=1
    fi

    if [[ "${should_be_enabled}" -eq 1 ]]; then
        if ! systemctl -q is-enabled nginx && ! systemctl -q enable nginx; then
            restore_status=1
        fi
    elif systemctl -q is-enabled nginx && ! systemctl -q disable nginx; then
        restore_status=1
    fi
    return "${restore_status}"
}

# =============================================================================
# 函数名称: handler_restart
# 功能描述: 重启 Xray 服务。
#           1. 检查 Xray 服务是否正在运行。
#           2. 如果正在运行则重启服务，否则启动服务。
#           3. 检查 Xray 服务是否已设置开机自启。
#           4. 如果未设置则启用开机自启。
# 参数: 无
# 返回值: 无 (通过 systemctl 命令执行操作)
# =============================================================================
function handler_restart() {
    local finalize_non_nginx=0
    local nginx_was_active=0 nginx_was_enabled=0
    # Remove a script-owned short-lived IP renewal job before changing any
    # service state. A crontab read/write error must abort safely while the old
    # runtime is still serving traffic.
    if ! current_config_uses_hy2 &&
        ! configure_hy2_ip_renewal_cron 'cleanup' ''; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.cron_fail")" >&2
        return 1
    fi
    if ! current_protocol_uses_nginx; then
        # Certificate and runtime JSON validation have completed by this point.
        # Only now hand any conflicting listener from the old Nginx stack to
        # Xray. Cloudreve remains available until Xray is confirmed healthy.
        systemctl -q is-active nginx && nginx_was_active=1
        systemctl -q is-enabled nginx && nginx_was_enabled=1
        if ! handler_nginx_stop; then
            restore_nginx_service_state \
                "${nginx_was_active}" "${nginx_was_enabled}" || true
            return 1
        fi
        finalize_non_nginx=1
    elif current_protocol_uses_nginx; then
        handler_sync_nginx_xhttp_path || return 1
        if [[ "${NGINX_CONFIG_CHANGED}" -eq 1 ]] ||
            ! systemctl -q is-active nginx ||
            ! systemctl -q is-enabled nginx; then
            handler_nginx_restart || return 1
        fi
    fi

    # 允许已经进入 start-limit-hit/failed 状态的服务在修复后立即恢复。
    systemctl reset-failed xray 2>/dev/null || true
    # 检查 Xray 服务是否活跃，如果活跃则重启，否则启动
    if systemctl -q is-active xray; then
        if ! systemctl -q restart xray; then
            report_xray_service_failure restart
            if [[ "${finalize_non_nginx}" -eq 1 ]]; then
                restore_nginx_service_state \
                    "${nginx_was_active}" "${nginx_was_enabled}" || true
            fi
            return 1
        fi
    elif ! systemctl -q start xray; then
        report_xray_service_failure start
        if [[ "${finalize_non_nginx}" -eq 1 ]]; then
            restore_nginx_service_state \
                "${nginx_was_active}" "${nginx_was_enabled}" || true
        fi
        return 1
    fi
    # 检查 Xray 服务是否已启用，如果未启用则启用
    if ! systemctl -q is-enabled xray && ! systemctl -q enable xray; then
        report_xray_service_failure enable
        if [[ "${finalize_non_nginx}" -eq 1 ]]; then
            restore_nginx_service_state \
                "${nginx_was_active}" "${nginx_was_enabled}" || true
        fi
        return 1
    fi
    if ! systemctl -q is-active xray; then
        report_xray_service_failure active
        if [[ "${finalize_non_nginx}" -eq 1 ]]; then
            restore_nginx_service_state \
                "${nginx_was_active}" "${nginx_was_enabled}" || true
        fi
        return 1
    fi
    if [[ "${finalize_non_nginx}" -eq 1 ]]; then
        handler_disable_cdn_web_stack
    fi
}

# =============================================================================
# 函数名称: handler_share
# 功能描述: 调用 share.sh 脚本显示分享链接。
# 参数: 无
# 返回值: share.sh 脚本的输出
# =============================================================================
function handler_share() {
    # 执行 share.sh 脚本
    bash "${SHARE_PATH}"
}

# =============================================================================
# 函数名称: handler_traffic
# 功能描述: 调用 traffic.sh 脚本显示流量统计。
# 参数: 无
# 返回值: traffic.sh 脚本的输出
# =============================================================================
function handler_traffic() {
    # 执行 traffic.sh 脚本
    bash "${TRAFFIC_PATH}"
}

# =============================================================================
# 函数名称: handler_geodata_cron
# 功能描述: 管理 GeoData 更新的 Cron 任务。
#           1. 检查 Xray 是否已安装。
#           2. 如果是快速模式 (IS_QUICK=1)，则直接更新 GeoData。
#           3. 否则，检查 Cron 任务是否存在。
#           4. 如果存在则移除，如果不存在则添加，并立即执行一次更新。
# 参数:
#   $1: IS_QUICK - 是否为快速模式 (1 表示是, 0 表示否)，默认为 0
# 返回值: 无 (通过 crontab 命令管理任务，调用 geodata.sh 执行更新)
# =============================================================================
function handler_geodata_cron() {
    local IS_QUICK="${1:-0}" # 获取快速模式参数，默认为 0
    local XRAY_STATUS=''
    local current_crontab='' filtered_crontab=''

    # 从脚本配置中检查 Xray 状态 (版本)
    XRAY_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.version // ""')" || return 1
    # 如果 Xray 已安装
    if [[ -n "${XRAY_STATUS}" ]]; then
        current_crontab="$(read_current_crontab)" || return 1
        # 如果非快速模式且 cron 已存在，则移除
        if [[ "${IS_QUICK}" == "0" ]] &&
            printf '%s\n' "${current_crontab}" | grep -Fq -- "${GEODATA_PATH}"; then
            # 移除现有的 GeoData Cron 任务
            filtered_crontab="$(printf '%s\n' "${current_crontab}" |
                grep -Fv -- "${GEODATA_PATH}" || true)"
            printf '%s\n' "${filtered_crontab}" | sed '/^$/d' | crontab - || return 1
            # 打印关闭 Cron 任务的提示
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.tip')] ${NC}$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.geodata.close_cron")" >&2
        else
            # 设置 geodata.sh 脚本为可执行
            chmod a+x "${GEODATA_PATH}" || return 1
            # 先更新 GeoData，失败时保持原有 Cron 状态不变。
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.tip')] ${NC}$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.geodata.update")" >&2
            "${GEODATA_PATH}" || return 1
            # 添加新的 GeoData Cron 任务 (每天 6:30 执行)
            {
                [[ -n "${current_crontab}" ]] && printf '%s\n' "${current_crontab}"
                printf '%s\n' "30 6 * * * ${GEODATA_PATH} >/dev/null 2>&1"
            } | awk 'NF && !seen[$0]++' | crontab - || return 1
            # 打印已开启 Cron 任务的提示
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.tip')] ${NC}$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.geodata.open_cron")" >&2
        fi
    fi
}

# =============================================================================
# 函数名称: handler_docker
# 功能描述: 确保 Docker 已安装。
#           1. 检查系统中是否存在 docker 命令。
#           2. 如果不存在，则调用 exec_docker 安装 Docker。
# 参数: 无
# 返回值: 无 (通过调用其他函数执行操作)
# =============================================================================
function handler_docker() {
    # 检查 docker 命令是否存在
    if ! cmd_exists 'docker'; then
        # 如果不存在，则调用 docker.sh 安装 Docker
        exec_docker '--install' || return 1
    fi
}

# =============================================================================
# 函数名称: handler_warp
# 功能描述: 管理 WARP (WireGuard) 配置。
#           1. 确保 Docker 已安装。
#           2. 检查当前 WARP 状态。
#           3. 如果已启用，则禁用并从 Xray 配置中移除相关规则。
#           4. 如果未启用，则启用并添加 WARP 出站和路由规则到 Xray 配置。
#           5. 更新脚本配置中的 WARP 状态。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作，修改配置文件)
# =============================================================================
function handler_warp() {
    handler_docker || return 1
    local warp_status previous_script_config previous_xray_config
    local container_was_running=0
    warp_status="$(echo "${SCRIPT_CONFIG}" | jq -r '(.xray.warp // 0) | tonumber? // 0')" || return 1
    previous_script_config="${SCRIPT_CONFIG}"
    previous_xray_config="$(jq '.' "${XRAY_CONFIG_PATH}")" || return 1
    if docker inspect xray-script-warp >/dev/null 2>&1 &&
        [[ "$(docker inspect --format='{{.State.Running}}' xray-script-warp 2>/dev/null)" == 'true' ]]; then
        container_was_running=1
    fi

    if [[ "${warp_status}" -eq 1 ]]; then
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '
            .xray.warp = 0 |
            .rules = [(.rules // [])[] | select((.outboundTag // "") != "warp")]
        ')" || return 1
        apply_xray_state_transaction "${previous_script_config}" "${previous_xray_config}" || return 1
        if ! exec_docker '--disable-warp'; then
            exec_docker '--enable-warp' >/dev/null 2>&1 || true
            local disabled_script_config="${SCRIPT_CONFIG}"
            local disabled_xray_config
            disabled_xray_config="$(jq '.' "${XRAY_CONFIG_PATH}" 2>/dev/null || echo "${previous_xray_config}")"
            SCRIPT_CONFIG="${previous_script_config}"
            if ! apply_xray_state_transaction "${disabled_script_config}" "${disabled_xray_config}"; then
                # The state transaction restores the disabled files on failure;
                # keep the container aligned with that recovered runtime.
                exec_docker '--disable-warp' >/dev/null 2>&1 || true
            fi
            return 1
        fi
    else
        exec_docker '--build-warp' || return 1
        local container_ip=''
        if ! container_ip="$(exec_docker '--enable-warp')" || [[ -z "${container_ip}" ]]; then
            if [[ "${container_was_running}" -eq 0 ]]; then
                exec_docker '--disable-warp' >/dev/null 2>&1 || true
            fi
            return 1
        fi
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.warp = 1')" || {
            if [[ "${container_was_running}" -eq 0 ]]; then
                exec_docker '--disable-warp' >/dev/null 2>&1 || true
            fi
            return 1
        }
        if ! apply_xray_state_transaction "${previous_script_config}" "${previous_xray_config}"; then
            if [[ "${container_was_running}" -eq 0 ]]; then
                exec_docker '--disable-warp' || true
            fi
            return 1
        fi
    fi
}

# =============================================================================
# 函数名称: handler_reset_warp
# 功能描述: 重新构建并启动 WARP 容器。
#           1. 确保 Docker 已安装。
#           2. 检查当前 WARP 状态。
#           3. 如果已启用，则执行清空容器日志，并重置 WARP 容器。
#           4. 如果未启用，则跳过。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================
function handler_reset_warp() {
    handler_docker || return 1
    local warp_status previous_script_config previous_xray_config container_ip
    local rollback_status=0
    warp_status="$(echo "${SCRIPT_CONFIG}" | jq -r '(.xray.warp // 0) | tonumber? // 0')" || return 1
    [[ "${warp_status}" -eq 1 ]] || return 0
    previous_script_config="${SCRIPT_CONFIG}"
    previous_xray_config="$(jq '.' "${XRAY_CONFIG_PATH}")" || return 1

    exec_docker '--clean-container-logs' || return 1
    if ! container_ip="$(exec_docker '--prepare-reset-warp')"; then
        exec_docker '--rollback-reset-warp' >/dev/null 2>&1 || true
        return 1
    fi
    if [[ -z "${container_ip}" ]]; then
        exec_docker '--rollback-reset-warp' >/dev/null 2>&1 || true
        return 1
    fi

    if ! apply_xray_state_transaction "${previous_script_config}" "${previous_xray_config}"; then
        exec_docker '--rollback-reset-warp' >/dev/null 2>&1 || rollback_status=1
        SCRIPT_CONFIG="${previous_script_config}"
        if [[ "${rollback_status}" -eq 0 ]] &&
            { ! handler_xray_config 1 || ! handler_restart; }; then
            rollback_status=1
        fi
        if [[ "${rollback_status}" -ne 0 ]]; then
            echo 'WARP reset rollback failed.' >&2
        fi
        return 1
    fi

    if ! exec_docker '--commit-reset-warp'; then
        exec_docker '--rollback-reset-warp' >/dev/null 2>&1 || rollback_status=1
        SCRIPT_CONFIG="${previous_script_config}"
        if [[ "${rollback_status}" -eq 0 ]] &&
            { ! handler_xray_config 1 || ! handler_restart; }; then
            rollback_status=1
        fi
        if [[ "${rollback_status}" -ne 0 ]]; then
            echo 'WARP reset rollback failed.' >&2
        fi
        return 1
    fi
}

# =============================================================================
# 函数名称: handler_nginx_install
# 功能描述: 安装 Nginx。
#           1. 检查系统中是否已安装 nginx 命令。
#           2. 如果未安装，则调用 nginx.sh 脚本安装 (带 --brotli 参数)。
#           3. 安装 SSL 证书管理工具。
#           4. 配置 Nginx。
#           5. 获取并保存 Nginx 版本到脚本配置。
# 参数: 无
# 返回值: 无 (通过调用其他脚本执行操作)
# =============================================================================
function handler_nginx_install() {
    # 确保服务用户和共享组存在
    ensure_service_users || return 1
    # 检查 nginx 命令是否存在
    if ! cmd_exists 'nginx'; then
        local install_mode_reply
        while true; do
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.install_mode_prompt")" >&2
            echo -e "  ${GREEN}1)${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.install_mode_prebuilt")" >&2
            echo -e "  ${GREEN}2)${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.install_mode_compile")" >&2
            read -r install_mode_reply
            install_mode_reply="${install_mode_reply:-1}"
            [[ "${install_mode_reply}" =~ ^[12]$ ]] && break
            echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.install_mode_invalid")" >&2
        done

        if [[ "${install_mode_reply}" == "1" ]]; then
            # 使用预编译二进制
            bash "${NGINX_PATH}" --install --prebuilt || return 1
        else
            # 自行编译（带 Brotli 支持）
            bash "${NGINX_PATH}" --install --brotli || return 1
        fi
        # 配置 Nginx
        handler_nginx_config || return 1
        # 获取 Nginx 版本
        local NGINX_VERSION
        NGINX_VERSION="$(nginx -V 2>&1 | awk -F/ '/^nginx version:/ { print $2; exit }')" || return 1
        [[ -n "${NGINX_VERSION}" ]] || return 1
        # 更新脚本配置中的 Nginx 版本
        SCRIPT_CONFIG=$(echo "${SCRIPT_CONFIG}" | jq --arg version "${NGINX_VERSION}" '.nginx.version = $version')
        # 将更新后的脚本配置写入文件
        write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || return 1
    else
        # 已安装的 Nginx 也要迁移 systemd unit 和共享 Socket 目录权限。
        bash "${NGINX_PATH}" --service-config || return 1
        # 系统中存在 nginx 命令并不代表脚本的受管配置已经安装。
        if [[ ! -f "${NGINX_CONFIG_DIR}/nginx.conf" ||
            ! -d "${NGINX_CONFIG_DIR}/sites-available" ]]; then
            handler_nginx_config || return 1
        fi
    fi
}

# =============================================================================
# 函数名称: handler_nginx_update
# 功能描述: 更新 Nginx。
# 参数: 无
# 返回值: 无 (通过调用 nginx.sh 脚本执行更新)
# =============================================================================
function handler_nginx_update() {
    # 调用 nginx.sh 更新 Nginx；其 update 分支会同时刷新 systemd 服务配置。
    bash "${NGINX_PATH}" --update --brotli
}

# =============================================================================
# 函数名称: handler_nginx_purge
# 功能描述: 卸载 Nginx，并重置脚步配置。
# 参数: 无
# 返回值: 无 (通过调用 nginx.sh 脚本执行卸载)
# =============================================================================
function handler_nginx_purge() {
    # 调用 nginx.sh 脚本卸载 Nginx
    bash "${NGINX_PATH}" --purge
    # 重置 nginx 字段
    SCRIPT_CONFIG=$(reset_json_fields "${SCRIPT_CONFIG}" 'nginx')
    # 将重置后的脚本配置写入文件
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
}

# =============================================================================
# 函数名称: handler_nginx_cron
# 功能描述: 管理 Nginx 更新的 Cron 任务。
#           1. 检查 Nginx 是否已安装。
#           2. 检查 Cron 任务是否存在。
#           3. 如果存在则移除。
#           4. 如果不存在则添加 (每天 3:00 执行更新)。
# 参数: 无
# 返回值: 无 (通过 crontab 命令管理任务)
# =============================================================================
function handler_nginx_cron() {
    # 从脚本配置中检查 Nginx 状态 (版本)
    local NGINX_STATUS="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.version')"
    # 如果 Nginx 已安装
    if [[ -n "${NGINX_STATUS}" ]]; then
        local current_crontab filtered_crontab
        current_crontab="$(read_current_crontab)" || return 1
        # 检查是否存在 Nginx 更新的 Cron 任务
        if printf '%s\n' "${current_crontab}" | grep -Fq -- "${NGINX_PATH}"; then
            # 移除现有的 Nginx Cron 任务
            filtered_crontab="$(printf '%s\n' "${current_crontab}" |
                grep -Fv -- "${NGINX_PATH}" || true)"
            printf '%s\n' "${filtered_crontab}" | sed '/^$/d' | crontab - ||
                return 1
            # 打印关闭 Cron 任务的提示
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.tip')] ${NC}$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.close_cron")" >&2
        else
            # 设置 nginx.sh 脚本为可执行
            chmod a+x "${NGINX_PATH}" || return 1
            # 添加新的 Nginx 更新 Cron 任务 (每天 3:00 执行)
            {
                [[ -n "${current_crontab}" ]] && printf '%s\n' "${current_crontab}"
                printf '%s\n' "0 3 * * * ${NGINX_PATH} --update --brotli >/dev/null 2>&1"
            } | awk 'NF && !seen[$0]++' | crontab - || return 1
            # 打印开启 Cron 任务的提示
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.tip')] ${NC}$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.open_cron")" >&2
        fi
    fi
}

function handler_disable_nginx_cron() {
    local current_crontab filtered_crontab

    cmd_exists crontab || return 0
    current_crontab="$(read_current_crontab)" || return 1
    printf '%s\n' "${current_crontab}" | grep -Fq -- "${NGINX_PATH}" || return 0

    filtered_crontab="$(printf '%s\n' "${current_crontab}" |
        grep -Fv -- "${NGINX_PATH}" || true)"
    if [[ -n "${filtered_crontab}" ]]; then
        printf '%s\n' "${filtered_crontab}" | crontab - || return 1
    else
        printf '' | crontab - || return 1
    fi
}

function render_nginx_site_xhttp_path() {
    local source_file="$1"
    local output_file="$2"
    local xhttp_path="$3"

    [[ -f "${source_file}" && ! -L "${source_file}" ]] || return 1
    [[ "$(head -n 1 "${source_file}" | tr -d '\r')" == '# xray_script' ]] || return 1

    awk -v xhttp_path="${xhttp_path}" '
        {
            comparable_line = $0
            sub(/\r$/, "", comparable_line)
        }
        comparable_line ~ /^[[:space:]]*#[[:space:]]*xhttp path[[:space:]]*$/ {
            print
            if ((getline next_line) <= 0) {
                exit 42
            }
            has_cr = (next_line ~ /\r$/)
            sub(/\r$/, "", next_line)
            if (next_line !~ /^[[:space:]]*location[[:space:]]+[^[:space:]{]+[[:space:]]*\{[[:space:]]*$/) {
                exit 42
            }
            sub(/location[[:space:]]+[^[:space:]{]+[[:space:]]*\{/, "location " xhttp_path " {", next_line)
            print next_line (has_cr ? "\r" : "")
            updated = 1
            next
        }
        { print }
        END {
            if (!updated) {
                exit 42
            }
        }
    ' "${source_file}" >"${output_file}"
}

function handler_sync_nginx_xhttp_path() {
    local config_tag
    local xhttp_path
    local domain
    local site_conf
    local enabled_conf
    local temp_file
    local index
    local domains=()
    local site_files=()
    local temp_files=()
    local site_backup_files=()
    local enabled_files=()
    local enabled_states=()
    local enabled_backup_files=()
    local enabled_link_targets=()
    local transaction_changed=0
    local rollback_status=0
    local -A seen_domains=()

    NGINX_CONFIG_CHANGED=0
    config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')"
    protocol_uses_nginx "${config_tag}" "$(get_cdn_backend)" || return 0

    xhttp_path="$(normalize_xhttp_path "$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.path // ""')")"
    if [[ -z "${xhttp_path}" ]] || ! validate_xhttp_path "${xhttp_path}"; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.path_invalid")" >&2
        return 1
    fi

    case "${config_tag,,}" in
    cdn)
        domains+=(
            "$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn // ""')"
            "$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')"
        )
        ;;
    sni)
        domains+=(
            "$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.domain // ""')"
            "$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn // ""')"
        )
        ;;
    esac

    # Render every managed site first. If any site is missing or malformed,
    # leave all existing files untouched instead of creating a partial sync.
    for domain in "${domains[@]}"; do
        if [[ -z "${domain}" ]]; then
            continue
        fi
        if [[ -n "${seen_domains[${domain}]:-}" ]]; then
            continue
        fi
        seen_domains["${domain}"]=1
        site_conf="${NGINX_CONFIG_DIR}/sites-available/${domain}.conf"
        temp_file="$(mktemp "${site_conf}.tmp.XXXXXX")" || {
            rm -f -- "${temp_files[@]}"
            return 1
        }
        if ! render_nginx_site_xhttp_path "${site_conf}" "${temp_file}" "${xhttp_path}"; then
            rm -f -- "${temp_file}" "${temp_files[@]}"
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.path_sync_fail") ${site_conf}" >&2
            return 1
        fi
        site_files+=("${site_conf}")
        temp_files+=("${temp_file}")
    done

    if [[ "${#site_files[@]}" -eq 0 ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.path_sync_fail")" >&2
        return 1
    fi

    # Snapshot every file and symlink before committing any rendered site.
    # This keeps a late mv/ln failure from leaving only part of an SNI pair on
    # the new path.
    mkdir -p "${NGINX_CONFIG_DIR}/sites-enabled" || {
        rm -f -- "${temp_files[@]}"
        return 1
    }
    for index in "${!site_files[@]}"; do
        site_conf="${site_files[${index}]}"
        temp_file="${temp_files[${index}]}"
        if cmp -s "${site_conf}" "${temp_file}"; then
            rm -f -- "${temp_file}"
            temp_files["${index}"]=''
            site_backup_files["${index}"]=''
        else
            local site_backup=''
            site_backup="$(mktemp "${site_conf}.backup.XXXXXX")" || {
                rollback_status=1
                break
            }
            if ! cp -p -- "${site_conf}" "${site_backup}"; then
                rm -f -- "${site_backup}"
                rollback_status=1
                break
            fi
            site_backup_files["${index}"]="${site_backup}"
        fi

        enabled_conf="${NGINX_CONFIG_DIR}/sites-enabled/$(basename "${site_conf}")"
        enabled_files["${index}"]="${enabled_conf}"
        enabled_backup_files["${index}"]=''
        enabled_link_targets["${index}"]=''
        if [[ -L "${enabled_conf}" ]]; then
            enabled_states["${index}"]='symlink'
            enabled_link_targets["${index}"]="$(readlink "${enabled_conf}")"
        elif [[ -f "${enabled_conf}" ]]; then
            local enabled_backup=''
            enabled_backup="$(mktemp "${enabled_conf}.backup.XXXXXX")" || {
                rollback_status=1
                break
            }
            if ! cp -p -- "${enabled_conf}" "${enabled_backup}"; then
                rm -f -- "${enabled_backup}"
                rollback_status=1
                break
            fi
            enabled_states["${index}"]='file'
            enabled_backup_files["${index}"]="${enabled_backup}"
        elif [[ -e "${enabled_conf}" ]]; then
            rollback_status=1
            break
        else
            enabled_states["${index}"]='missing'
        fi
    done

    if [[ "${rollback_status}" -ne 0 ]]; then
        rm -f -- \
            "${temp_files[@]}" \
            "${site_backup_files[@]}" \
            "${enabled_backup_files[@]}"
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.path_sync_fail")" >&2
        return 1
    fi

    for index in "${!site_files[@]}"; do
        site_conf="${site_files[${index}]}"
        temp_file="${temp_files[${index}]:-}"
        [[ -n "${temp_file}" ]] || continue
        chmod --reference="${site_conf}" "${temp_file}" 2>/dev/null || true
        chown --reference="${site_conf}" "${temp_file}" 2>/dev/null || true
        if ! mv -f -- "${temp_file}" "${site_conf}"; then
            rollback_status=1
            break
        fi
        temp_files["${index}"]=''
        transaction_changed=1
    done

    # nginx.conf loads sites-enabled/*. Keep it linked to the managed
    # sites-available file; a stale regular copy would otherwise continue to
    # serve the old XHTTP path after the source file was updated.
    if [[ "${rollback_status}" -eq 0 ]]; then
        for index in "${!site_files[@]}"; do
            site_conf="${site_files[${index}]}"
            enabled_conf="${enabled_files[${index}]}"
            if [[ -L "${enabled_conf}" &&
                "$(readlink "${enabled_conf}")" == "${site_conf}" ]]; then
                continue
            fi
            if ! ln -sfn "${site_conf}" "${enabled_conf}"; then
                rollback_status=1
                break
            fi
            transaction_changed=1
        done
    fi

    if [[ "${rollback_status}" -ne 0 ]]; then
        for index in "${!site_files[@]}"; do
            site_conf="${site_files[${index}]}"
            if [[ -n "${site_backup_files[${index}]:-}" ]] &&
                ! cp -p -- "${site_backup_files[${index}]}" "${site_conf}"; then
                rollback_status=2
            fi

            enabled_conf="${enabled_files[${index}]:-}"
            [[ -n "${enabled_conf}" ]] || continue
            if ! rm -f -- "${enabled_conf}"; then
                rollback_status=2
                continue
            fi
            case "${enabled_states[${index}]:-missing}" in
            symlink)
                ln -s -- "${enabled_link_targets[${index}]}" "${enabled_conf}" ||
                    rollback_status=2
                ;;
            file)
                cp -p -- "${enabled_backup_files[${index}]}" "${enabled_conf}" ||
                    rollback_status=2
                ;;
            missing) ;;
            *) rollback_status=2 ;;
            esac
        done
        rm -f -- \
            "${temp_files[@]}" \
            "${site_backup_files[@]}" \
            "${enabled_backup_files[@]}"
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.path_sync_fail")" >&2
        return 1
    fi

    rm -f -- \
        "${temp_files[@]}" \
        "${site_backup_files[@]}" \
        "${enabled_backup_files[@]}"
    if [[ "${transaction_changed}" -eq 1 ]]; then
        NGINX_CONFIG_CHANGED=1
    fi
}

# =============================================================================
# 函数名称: handler_nginx_start
# 功能描述: 启动 nginx 服务。
#           1. 检查 nginx 服务是否已在运行。
#           2. 如果未运行则启动服务。
#           3. 检查 nginx 服务是否已设置开机自启。
#           4. 如果未设置则启用开机自启。
# 参数: 无
# 返回值: 无 (通过 systemctl 命令执行操作)
# =============================================================================
function handler_nginx_start() {
    handler_sync_nginx_xhttp_path || return 1
    if cmd_exists nginx && ! nginx -t; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.config_invalid")" >&2
        return 1
    fi
    if ! systemctl -q is-active nginx && ! systemctl -q start nginx; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.start_fail")" >&2
        return 1
    fi
    if ! systemctl -q is-enabled nginx && ! systemctl -q enable nginx; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.enable_fail")" >&2
        return 1
    fi
    systemctl -q is-active nginx
}

# =============================================================================
# 函数名称: handler_nginx_stop
# 功能描述: 停止 nginx 服务。
#           1. 检查 nginx 服务是否正在运行。
#           2. 如果正在运行则停止服务。
#           3. 检查 nginx 服务是否已设置开机自启。
#           4. 如果已设置则禁用开机自启。
# 参数: 无
# 返回值: 无 (通过 systemctl 命令执行操作)
# =============================================================================
function handler_nginx_stop() {
    if systemctl -q is-active nginx && ! systemctl -q stop nginx; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.nginx_stop_fail")" >&2
        return 1
    fi
    if systemctl -q is-enabled nginx && ! systemctl -q disable nginx; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.nginx_disable_fail")" >&2
        return 1
    fi
    return 0
}

function handler_disable_cdn_web_stack() {
    local cleanup_failed=0

    # These are resource cleanups, not listener ownership changes. A Docker or
    # crontab problem must be reported, but must not roll back an already
    # healthy direct-Xray listener and take the node offline.
    handler_disable_nginx_cron || cleanup_failed=1
    (handler_cloudreve_v3 'stop') || cleanup_failed=1
    (handler_cloudreve_v4 'stop') || cleanup_failed=1
    if [[ "${cleanup_failed}" -ne 0 ]]; then
        echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.cleanup_incomplete")" >&2
    fi
    return 0
}

# =============================================================================
# 函数名称: handler_nginx_restart
# 功能描述: 重启 nginx 服务。
#           1. 检查 nginx 服务是否正在运行。
#           2. 如果正在运行则重启服务，否则启动服务。
#           3. 检查 nginx 服务是否已设置开机自启。
#           4. 如果未设置则启用开机自启。
# 参数: 无
# 返回值: 无 (通过 systemctl 命令执行操作)
# =============================================================================
function handler_nginx_restart() {
    local nginx_conf="${NGINX_CONFIG_DIR}/nginx.conf"
    if [[ -f "${nginx_conf}" ]]; then
        sed -i \
            -e 's#^\([[:space:]]*\)ssl_ecdh_curve[[:space:]].*secp256r1.*;#\1ssl_ecdh_curve            X25519:prime256v1:secp384r1;#' \
            -e 's|^\([[:space:]]*\)\(ssl_stapling[[:space:]][^;]*;\)|\1# \2|' \
            -e 's|^\([[:space:]]*\)\(ssl_stapling_verify[[:space:]][^;]*;\)|\1# \2|' \
            "${nginx_conf}"
    fi

    # 常用的改域名/切换 Web 流程也会直接走 restart；发现旧的破坏性 unit 时
    # 立即迁移，避免它再次删除 Xray 正在使用的共享 Socket 目录。
    if [[ -f "${NGINX_SERVICE_PATH}" ]]; then
        if grep -Eq 'rm[[:space:]]+-rf[[:space:]]+/dev/shm/nginx(/|[[:space:]]|$)|ExecStopPost=.*dev/shm/nginx' "${NGINX_SERVICE_PATH}" ||
            ! grep -Eq '^UMask=0007[[:space:]]*$' "${NGINX_SERVICE_PATH}" ||
            ! grep -Fq -- '-m 2770 /dev/shm/nginx' "${NGINX_SERVICE_PATH}" ||
            ! grep -Fq 'xray-nginx' "${NGINX_SERVICE_PATH}"; then
            bash "${NGINX_PATH}" --service-config || return 1
        fi
    fi
    # 动态检测 nginx 二进制是否包含 brotli 压缩模块，如果不包含，则自动注释 general.conf 中的 brotli 配置，以防 Nginx 启动/重载报错
    if cmd_exists 'nginx' && ! nginx -V 2>&1 | grep -qi 'brotli'; then
        if [[ -f "${NGINX_CONFIG_DIR}/nginxconfig.io/general.conf" ]]; then
            sed -i 's|^\([[:space:]]*\)brotli|\1#brotli|g' "${NGINX_CONFIG_DIR}/nginxconfig.io/general.conf"
        fi
    fi

    handler_sync_nginx_xhttp_path || return 1
    if cmd_exists nginx && ! nginx -t; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.config_invalid")" >&2
        return 1
    fi

    systemctl reset-failed nginx 2>/dev/null || true
    if systemctl -q is-active nginx; then
        if ! systemctl -q restart nginx; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.restart_fail")" >&2
            return 1
        fi
    elif ! systemctl -q start nginx; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.start_fail")" >&2
        return 1
    fi

    if ! systemctl -q is-enabled nginx && ! systemctl -q enable nginx; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.enable_fail")" >&2
        return 1
    fi
    if ! systemctl -q is-active nginx; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.active_fail")" >&2
        return 1
    fi
}

# =============================================================================
# 函数名称: handler_ssl_install
# 功能描述: 安装 SSL 证书管理工具 (acme.sh)。
#           1. 检查 acme.sh 是否已安装。
#           2. 如果未安装，则从脚本配置中读取 CA 邮箱。
#           3. 调用 ssl.sh 脚本安装 acme.sh。
# 参数: 无
# 返回值: 无 (通过调用 ssl.sh 脚本执行安装)
# =============================================================================
function handler_ssl_install() {
    # 检查 acme.sh 脚本是否存在
    if [[ ! -e "${ACME_PATH}" ]]; then
        # 从脚本配置中读取 CA 邮箱
        local CA_EMAIL="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.ca')"
        # 调用 ssl.sh 脚本安装 acme.sh
        exec_ssl '--install' "--email=${CA_EMAIL}" || return 1
    fi
}

function valid_change_domain_transaction_domain() {
    local domain="$1"
    local domain_regex='^([a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$'

    ((${#domain} <= 250)) && [[ "${domain}" =~ ${domain_regex} ]]
}

function render_managed_site_domain() {
    local source_file="$1"
    local output_file="$2"
    local domain="$3"
    local cert_root="${NGINX_CONFIG_DIR}/certs/${domain}"

    [[ -f "${source_file}" && ! -L "${source_file}" ]] || return 1
    [[ "$(head -n 1 "${source_file}" | tr -d '\r')" == '# xray_script' ]] || return 1
    awk -v domain="${domain}" -v cert_root="${cert_root}" '
        /^[[:space:]]*ssl_certificate[[:space:]]+/ {
            sub(/ssl_certificate[[:space:]]+[^;]+;/, "ssl_certificate              " cert_root "/fullchain.pem;")
        }
        /^[[:space:]]*ssl_certificate_key[[:space:]]+/ {
            sub(/ssl_certificate_key[[:space:]]+[^;]+;/, "ssl_certificate_key          " cert_root "/privkey.pem;")
        }
        /^[[:space:]]*server_name[[:space:]]+/ {
            sub(/server_name[[:space:]]+[^;]+;/, "server_name               " domain ";")
        }
        { print }
    ' "${source_file}" >"${output_file}"
}

function render_nginx_stream_config() {
    local output_file="$1"
    local domain cdn
    domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.domain // ""')"
    cdn="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn // ""')"
    [[ -n "${domain}" && -n "${cdn}" ]] || return 1

    awk -v domain="${domain}" -v cdn="${cdn}" '
        $2 == "nginx_to_xray_vision;" { sub(/[^[:space:]]+/, domain) }
        $2 == "cdn_to_nginx;" { sub(/[^[:space:]]+/, cdn) }
        { print }
    ' "${CONFIG_DIR}/nginx/conf/modules-enabled/stream.conf" >"${output_file}"
}

function change_domain_transaction_relative_path_is_safe() {
    local relative_path="$1"
    local domain

    case "${relative_path}" in
    modules-enabled/stream.conf)
        return 0
        ;;
    sites-available/*.conf | sites-enabled/*.conf)
        domain="${relative_path#*/}"
        domain="${domain%.conf}"
        [[ "${relative_path}" == "sites-available/${domain}.conf" ||
            "${relative_path}" == "sites-enabled/${domain}.conf" ]] &&
            valid_change_domain_transaction_domain "${domain}"
        ;;
    certs/*)
        domain="${relative_path#certs/}"
        [[ "${relative_path}" == "certs/${domain}" ]] &&
            valid_change_domain_transaction_domain "${domain}"
        ;;
    *)
        return 1
        ;;
    esac
}

function change_domain_transaction_dir_is_safe() {
    local transaction_dir="$1"
    local transaction_parent config_parent

    [[ -d "${transaction_dir}" && ! -L "${transaction_dir}" ]] || return 1
    transaction_parent="$(cd -P -- "$(dirname -- "${transaction_dir}")" && pwd -P)" ||
        return 1
    config_parent="$(cd -P -- "$(dirname -- "${SCRIPT_CONFIG_PATH}")" && pwd -P)" ||
        return 1
    [[ "${transaction_parent}" == "${config_parent}" &&
        "$(basename -- "${transaction_dir}")" == .change-domain.* ]]
}

function snapshot_change_domain_transaction_path() {
    local transaction_dir="$1"
    local relative_path="$2"
    local target_path payload_path state

    change_domain_transaction_dir_is_safe "${transaction_dir}" || return 1
    change_domain_transaction_relative_path_is_safe "${relative_path}" || return 1
    target_path="${NGINX_CONFIG_DIR}/${relative_path}"
    payload_path="${transaction_dir}/root/${relative_path}"

    if [[ -L "${target_path}" ]]; then
        state='symlink'
    elif [[ -f "${target_path}" ]]; then
        state='file'
    elif [[ -d "${target_path}" ]]; then
        [[ "${relative_path}" == certs/* ]] || return 1
        state='directory'
    elif [[ -e "${target_path}" ]]; then
        return 1
    else
        state='missing'
    fi

    printf '%s\t%s\n' "${state}" "${relative_path}" \
        >>"${transaction_dir}/manifest.tsv" || return 1
    if [[ "${state}" != 'missing' ]]; then
        mkdir -p -- "$(dirname -- "${payload_path}")" || return 1
        cp -a -- "${target_path}" "${payload_path}" || return 1
    fi
}

function snapshot_change_domain_script_config() {
    local transaction_dir="$1"
    local state

    if [[ -L "${SCRIPT_CONFIG_PATH}" ]]; then
        state='symlink'
    elif [[ -f "${SCRIPT_CONFIG_PATH}" ]]; then
        state='file'
    elif [[ -e "${SCRIPT_CONFIG_PATH}" ]]; then
        return 1
    else
        state='missing'
    fi
    printf '%s\n' "${state}" >"${transaction_dir}/script-config.state" ||
        return 1
    if [[ "${state}" != 'missing' ]]; then
        cp -a -- \
            "${SCRIPT_CONFIG_PATH}" "${transaction_dir}/script-config.payload" ||
            return 1
    fi
}

function remove_change_domain_transaction_target() {
    local target_path="$1"
    local allow_directory="$2"

    if [[ -L "${target_path}" || -f "${target_path}" ]]; then
        rm -f -- "${target_path}"
    elif [[ -d "${target_path}" ]]; then
        [[ "${allow_directory}" == 'y' ]] || return 1
        rm -rf -- "${target_path}"
    elif [[ -e "${target_path}" ]]; then
        return 1
    fi
}

function restore_change_domain_transaction_target() {
    local target_path="$1"
    local state="$2"
    local payload_path="$3"
    local allow_directory="${4:-n}"

    case "${state}" in
    missing | file | symlink) ;;
    directory)
        [[ "${allow_directory}" == 'y' ]] || return 1
        ;;
    *)
        return 1
        ;;
    esac
    if [[ "${state}" != 'missing' ]]; then
        case "${state}" in
        file) [[ -f "${payload_path}" && ! -L "${payload_path}" ]] || return 1 ;;
        symlink) [[ -L "${payload_path}" ]] || return 1 ;;
        directory)
            [[ -d "${payload_path}" && ! -L "${payload_path}" ]] || return 1
            ;;
        esac
    fi

    remove_change_domain_transaction_target \
        "${target_path}" "${allow_directory}" || return 1
    [[ "${state}" != 'missing' ]] || return 0
    mkdir -p -- "$(dirname -- "${target_path}")" || return 1
    cp -a -- "${payload_path}" "${target_path}"
}

function restore_change_domain_transaction() {
    local transaction_dir="$1"
    local state relative_path target_path payload_path script_state=''
    local restore_status=0

    change_domain_transaction_dir_is_safe "${transaction_dir}" || return 1
    [[ -f "${transaction_dir}/manifest.tsv" &&
        ! -L "${transaction_dir}/manifest.tsv" ]] || return 1
    while IFS=$'\t' read -r state relative_path ||
        [[ -n "${state}" || -n "${relative_path}" ]]; do
        if ! change_domain_transaction_relative_path_is_safe "${relative_path}"; then
            restore_status=1
            continue
        fi
        target_path="${NGINX_CONFIG_DIR}/${relative_path}"
        payload_path="${transaction_dir}/root/${relative_path}"
        restore_change_domain_transaction_target \
            "${target_path}" "${state}" "${payload_path}" \
            "$([[ "${relative_path}" == certs/* ]] && printf 'y' || printf 'n')" ||
            restore_status=1
    done <"${transaction_dir}/manifest.tsv"

    if [[ -f "${transaction_dir}/script-config.state" &&
        ! -L "${transaction_dir}/script-config.state" ]] &&
        script_state="$(<"${transaction_dir}/script-config.state")"; then
        restore_change_domain_transaction_target \
            "${SCRIPT_CONFIG_PATH}" "${script_state}" \
            "${transaction_dir}/script-config.payload" 'n' ||
            restore_status=1
    else
        restore_status=1
    fi
    if [[ "${restore_status}" -eq 0 ]]; then
        SCRIPT_CONFIG="$(jq '.' "${SCRIPT_CONFIG_PATH}")" || restore_status=1
    fi
    return "${restore_status}"
}

function cleanup_change_domain_transaction() {
    local transaction_dir="$1"

    change_domain_transaction_dir_is_safe "${transaction_dir}" || return 1
    rm -rf -- "${transaction_dir}"
}

function create_change_domain_transaction() {
    local old_domain="$1"
    local new_domain="$2"
    local transaction_parent transaction_dir domain
    local domains=()

    [[ -z "${old_domain}" ]] ||
        valid_change_domain_transaction_domain "${old_domain}" || return 1
    [[ -z "${new_domain}" ]] || valid_change_domain_transaction_domain "${new_domain}" || return 1
    transaction_parent="$(cd -P -- "$(dirname -- "${SCRIPT_CONFIG_PATH}")" && pwd -P)" ||
        return 1
    transaction_dir="$(
        mktemp -d "${transaction_parent}/.change-domain.XXXXXX"
    )" || return 1
    if ! : >"${transaction_dir}/manifest.tsv" ||
        ! snapshot_change_domain_script_config "${transaction_dir}"; then
        cleanup_change_domain_transaction "${transaction_dir}" 2>/dev/null || true
        return 1
    fi

    [[ -z "${old_domain}" ]] || domains+=("${old_domain}")
    if [[ -n "${new_domain}" && "${new_domain}" != "${old_domain}" ]]; then
        domains+=("${new_domain}")
    fi
    for domain in "${domains[@]}"; do
        if ! snapshot_change_domain_transaction_path \
                "${transaction_dir}" "sites-available/${domain}.conf" ||
            ! snapshot_change_domain_transaction_path \
                "${transaction_dir}" "sites-enabled/${domain}.conf"; then
            cleanup_change_domain_transaction "${transaction_dir}" 2>/dev/null || true
            return 1
        fi
    done
    if ! snapshot_change_domain_transaction_path \
            "${transaction_dir}" 'modules-enabled/stream.conf' ||
        { [[ -n "${new_domain}" ]] && ! snapshot_change_domain_transaction_path \
            "${transaction_dir}" "certs/${new_domain}"; }; then
        cleanup_change_domain_transaction "${transaction_dir}" 2>/dev/null || true
        return 1
    fi
    printf '%s\n' "${transaction_dir}"
}

function rollback_change_domain_transaction() {
    local transaction_dir="$1"
    local restart_nginx="$2"
    local rollback_status=0

    restore_change_domain_transaction "${transaction_dir}" ||
        rollback_status=1
    if [[ "${restart_nginx}" != 'n' ]] &&
        ! handler_nginx_restart; then
        rollback_status=1
    fi
    # Restart reconciliation may normalize enabled-site links. Reapply the
    # journal once more so rollback still returns the exact pre-call types,
    # targets and metadata after the old runtime has been recovered.
    if [[ "${restart_nginx}" != 'n' ]] &&
        ! restore_change_domain_transaction "${transaction_dir}"; then
        rollback_status=1
    fi
    if [[ "${rollback_status}" -eq 0 ]]; then
        cleanup_change_domain_transaction "${transaction_dir}" ||
            rollback_status=1
    fi
    if [[ "${rollback_status}" -ne 0 ]]; then
        echo "Change-domain rollback failed; transaction retained at: ${transaction_dir}" >&2
    fi
    return "${rollback_status}"
}

# =============================================================================
# 函数名称: handler_change_domain
# 功能描述: 更改 Nginx 配置中的域名 (包括 SSL 证书)。
#           1. 获取旧域名。
#           2. 读取新域名 (如果未提供)。
#           3. 如果旧域名存在，则停止其证书续签并删除配置文件。
#           4. 复制并修改新的站点配置模板。
#           5. 申请新的 SSL 证书。
#           6. 更新脚本配置中的域名。
#           7. 调用 handler_nginx_restart 重启 Nginx 服务。
# 参数:
#   $1: target_domain - 目标域名类型 ("domain" 或 "cdn")
#   $2: stop_cert_service - 管理停止证书签发服务类型 ("n", 或默认的 "y")
# 返回值: 无 (通过文件操作和调用其他脚本执行)
# =============================================================================
function handler_change_domain() {
    # 获取 XHTTP PATH
    local XHTTP_PATH CONFIG_TAG
    XHTTP_PATH="$(normalize_xhttp_path "$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.path // ""')")"
    CONFIG_TAG="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')"
    if { protocol_uses_xhttp "${CONFIG_TAG}" && [[ -z "${XHTTP_PATH}" ]]; } ||
        ! validate_xhttp_path "${XHTTP_PATH}"; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.path_invalid")" >&2
        return 1
    fi
    # 获取目标域名类型参数
    local target_domain="$1"
    # 获取管理停止证书签发服务参数
    local stop_cert_service="${2:-y}"
    local restart_nginx="${3:-y}"
    case "${target_domain}" in
    domain | cdn | cdnDown) ;;
    *) return 1 ;;
    esac
    # 从脚本配置中获取旧域名
    local old_domain="$(echo "${SCRIPT_CONFIG}" | jq -r --arg key "${target_domain}" '.nginx[$key] // ""')"
    # 如果 CONFIG_DATA 中没有新域名，且 stop_cert_service 为 "y"，则读取用户输入
    local input_domain_key="${target_domain}"
    [[ "${target_domain}" == 'cdnDown' ]] && input_domain_key='cdn-down'
    if [[ -z "${CONFIG_DATA["${input_domain_key}"]+set}" && "${stop_cert_service}" == "y" ]]; then
        if [[ -n "${old_domain}" ]]; then
            exec_read 'only-change-domain' || return 1
        fi
        exec_read "${input_domain_key}" || return 1
    elif [[ -z "${CONFIG_DATA["${input_domain_key}"]+set}" ]]; then
        CONFIG_DATA["${input_domain_key}"]="${old_domain}"
    fi
    local new_domain="${CONFIG_DATA["${input_domain_key}"]:-}"
    if [[ "${target_domain}" == 'cdnDown' ]]; then
        local uplink_domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn // ""')"
        if [[ -n "${new_domain}" && "${new_domain,,}" == "${uplink_domain,,}" ]]; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_split.domain_duplicate")" >&2
            return 1
        fi
    elif [[ "${target_domain}" == 'cdn' ]]; then
        local downlink_domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')"
        if [[ -n "${downlink_domain}" && "${new_domain,,}" == "${downlink_domain,,}" ]]; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_split.domain_duplicate")" >&2
            return 1
        fi
    fi
    local transaction_dir
    if ! transaction_dir="$(
        create_change_domain_transaction "${old_domain}" "${new_domain}"
    )"; then
        return 1
    fi
    if [[ "${target_domain}" == 'cdnDown' && -z "${new_domain}" ]]; then
        if [[ -n "${old_domain}" ]] && {
            ! remove_change_domain_transaction_target "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" 'n' ||
            ! remove_change_domain_transaction_target "${NGINX_CONFIG_DIR}/sites-enabled/${old_domain}.conf" 'n';
        }; then
            rollback_change_domain_transaction "${transaction_dir}" "${restart_nginx}" || true
            return 1
        fi
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '
            .nginx.certificates //= {} |
            .nginx.cdnDown = "" |
            .nginx.certificates.cdnDown = {hostname:"",source:"",fullchain:"",privkey:""} |
            .xray.cdnDownCertHostname = "" |
            .xray.cdnDownCertSource = "" |
            .xray.cdnDownCertFullchain = "" |
            .xray.cdnDownCertPrivkey = ""
        ')"
        if ! write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"; then
            rollback_change_domain_transaction "${transaction_dir}" "${restart_nginx}" || true
            return 1
        fi
        if [[ "${restart_nginx}" != 'n' ]] && ! handler_nginx_restart; then
            rollback_change_domain_transaction "${transaction_dir}" "${restart_nginx}" || true
            return 1
        fi
        if [[ -n "${old_domain}" && "${stop_cert_service}" == 'y' ]] && acme_manages_certificate "${old_domain}"; then
            cleanup_acme_certificate_if_unused "${old_domain}" 'y' || true
        fi
        cleanup_change_domain_transaction "${transaction_dir}" || return 1
        return 0
    fi
    local site_conf="${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf"
    local template_domain="${target_domain}"
    [[ "${target_domain}" == 'cdnDown' ]] && template_domain='cdn'
    local manage_site_conf="y"
    # 完整安装必须按当前模式重建站点。否则从 SNI 切换到 CDN 时会继续使用
    # Unix Socket 监听配置，看起来仍像 SNI 模式。
    if [[ -e "${site_conf}" && "${stop_cert_service}" != "n" ]]; then
        manage_site_conf="n"
    fi
    if [[ "${manage_site_conf}" == "y" ]]; then
        if [[ -n "${old_domain}" ]]; then
            if ! remove_change_domain_transaction_target \
                    "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" 'n' ||
                ! remove_change_domain_transaction_target \
                    "${NGINX_CONFIG_DIR}/sites-enabled/${old_domain}.conf" 'n'; then
                rollback_change_domain_transaction \
                    "${transaction_dir}" "${restart_nginx}" || true
                return 1
            fi
        fi
        if [[ "${new_domain}" != "${old_domain}" ]]; then
            if ! remove_change_domain_transaction_target \
                    "${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf" 'n' ||
                ! remove_change_domain_transaction_target \
                    "${NGINX_CONFIG_DIR}/sites-enabled/${new_domain}.conf" 'n'; then
                rollback_change_domain_transaction \
                    "${transaction_dir}" "${restart_nginx}" || true
                return 1
            fi
        fi
        # 复制站点配置模板到 available 目录
        if ! cp -f \
                "${CONFIG_DIR}/nginx/conf/sites-available/${template_domain}.example.com.conf" \
                "${site_conf}" ||
        # 替换配置文件中的 example.com 为实际域名
            ! sed -i "s|example.com|${new_domain}|g" "${site_conf}" ||
        # 替换配置文件中的 /yourpath 为 xhttp path
            ! sed -i "s|/yourpath|${XHTTP_PATH}|g" "${site_conf}"; then
            rollback_change_domain_transaction \
                "${transaction_dir}" "${restart_nginx}" || true
            return 1
        fi
        if [[ "${CONFIG_TAG,,}" == "cdn" && ( "${target_domain}" == "cdn" || "${target_domain}" == "cdnDown" ) ]]; then
            if ! sed -i $'s|listen .*cdn_to_nginx.sock.*|listen 443 ssl reuseport;\\\n    listen [::]:443 ssl reuseport;|g' "${site_conf}" ||
                ! sed -i '/set_real_ip_from[[:space:]]\+unix:;/d' "${site_conf}" ||
                ! sed -i '/real_ip_header[[:space:]]\+proxy_protocol;/d' "${site_conf}"; then
                rollback_change_domain_transaction \
                    "${transaction_dir}" "${restart_nginx}" || true
                return 1
            fi
            if ! grep -q "server_name" "${site_conf}"; then
                if ! sed -i "/listen \\[::\\]:443 ssl reuseport;/a\\    server_name               ${new_domain};" "${site_conf}"; then
                    rollback_change_domain_transaction \
                        "${transaction_dir}" "${restart_nginx}" || true
                    return 1
                fi
            fi
        fi
    fi
    # 创建从 available 到 enabled 的软链接
    local cert_source_reply="$(echo "${SCRIPT_CONFIG}" | jq -r --arg key "${target_domain}" '.nginx.certificates[$key].source // ""')"
    local cached_hostname="$(echo "${SCRIPT_CONFIG}" | jq -r --arg key "${target_domain}" '.nginx.certificates[$key].hostname // ""')"
    local cached_fullchain="$(echo "${SCRIPT_CONFIG}" | jq -r --arg key "${target_domain}" '.nginx.certificates[$key].fullchain // ""')"
    local cached_privkey="$(echo "${SCRIPT_CONFIG}" | jq -r --arg key "${target_domain}" '.nginx.certificates[$key].privkey // ""')"

    # 证书缓存只属于它签发时使用的主机名，不能按 SNI/CDN 角色盲目复用。
    if [[ "${cached_hostname}" != "${new_domain}" ]]; then
        cert_source_reply=''
        cached_fullchain=''
        cached_privkey=''
    fi
    if [[ "${target_domain}" == 'cdnDown' && -z "${cert_source_reply}" ]]; then
        local uplink_cert_source uplink_fullchain uplink_privkey
        uplink_cert_source="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.certificates.cdn.source // ""')"
        uplink_fullchain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.certificates.cdn.fullchain // ""')"
        uplink_privkey="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.certificates.cdn.privkey // ""')"
        if [[ "${uplink_cert_source}" == '2' ]] &&
            validate_cdn_direct_certificate "${uplink_fullchain}" "${uplink_privkey}" "${new_domain}"; then
            cert_source_reply='2'
            cached_fullchain="${uplink_fullchain}"
            cached_privkey="${uplink_privkey}"
        fi
    fi

    while [[ ! "${cert_source_reply}" =~ ^[12]$ ]]; do
        if [[ -n "${cert_source_reply}" ]]; then
            echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.tip')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.source_invalid")" >&2
        fi
        local cert_prompt_key='prompt_cdn'
        if [[ "${CONFIG_TAG,,}" == 'sni' && "${target_domain}" == 'domain' ]]; then
            cert_prompt_key='prompt_sni_domain'
        elif [[ "${CONFIG_TAG,,}" == 'sni' ]]; then
            cert_prompt_key='prompt_sni_cdn'
        elif [[ "${target_domain}" == 'cdnDown' ]]; then
            cert_prompt_key='prompt_cdn_down'
        fi
        echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.${cert_prompt_key}")" >&2
        read -r cert_source_reply
        cert_source_reply="${cert_source_reply:-1}"
    done
    local cert_ok=false
    if [[ "${cert_source_reply}" == "2" ]]; then
        local cert_dir="${NGINX_CONFIG_DIR}/certs/${new_domain}"
        local user_fullchain="${cached_fullchain}"
        local user_privkey="${cached_privkey}"
        if [[ -z "${user_fullchain}" || -z "${user_privkey}" || ! -r "${user_fullchain}" || ! -r "${user_privkey}" ]]; then
            while true; do
                echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.fullchain")" >&2
                read -r user_fullchain
                user_fullchain="$(echo "${user_fullchain}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                [[ -z "${user_fullchain}" ]] && continue
                if [[ ! -r "${user_fullchain}" ]]; then
                    echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.path_invalid")" >&2
                    continue
                fi
                break
            done
            while true; do
                echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.privkey")" >&2
                read -r user_privkey
                user_privkey="$(echo "${user_privkey}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                [[ -z "${user_privkey}" ]] && continue
                if [[ ! -r "${user_privkey}" ]]; then
                    echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.path_invalid")" >&2
                    continue
                fi
                break
            done
        fi
        cached_fullchain="${user_fullchain}"
        cached_privkey="${user_privkey}"
        if install_custom_nginx_certificate_pair \
            "${user_fullchain}" "${user_privkey}" \
            "${new_domain}" "${cert_dir}"; then
            cert_ok=true
        else
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.cert_invalid")" >&2
        fi
        if [[ "${cert_ok}" == true ]]; then
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.install_ok")" >&2
        fi
    fi
    if [[ "${cert_source_reply}" == "2" && "${cert_ok}" != true ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.path_invalid")" >&2
    fi
    if [[ "${cert_source_reply}" != "2" && "${cert_ok}" != true ]]; then
        local CA_EMAIL="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.ca')"
        # 非首次安装时，检测已有证书并询问用户
        local cert_reuse_choice
        cert_reuse_choice="$(prompt_cert_reuse "${new_domain}" "nginx")"

        if [[ "${cert_reuse_choice}" != "new" ]]; then
            # 用户选择复用已有证书
            echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_reuse.reusing") ${cert_reuse_choice}" >&2
            local src_cert_dir="${NGINX_CONFIG_DIR}/certs/${cert_reuse_choice}"
            local dst_cert_dir="${NGINX_CONFIG_DIR}/certs/${new_domain}"
            local managed_reuse_domain=''
            managed_reuse_domain="$(acme_main_domain_for_name "${cert_reuse_choice}" 2>/dev/null || true)"
            if [[ -n "${managed_reuse_domain}" ]]; then
                if install_acme_nginx_certificate \
                    "${managed_reuse_domain}" "${new_domain}" "${dst_cert_dir}"; then
                    cert_ok=true
                fi
            elif [[ "${cert_reuse_choice}" == "${new_domain}" &&
                -f "${dst_cert_dir}/fullchain.pem" &&
                -f "${dst_cert_dir}/privkey.pem" ]]; then
                cert_ok=true
            elif [[ "${cert_reuse_choice}" != "${new_domain}" ]]; then
                if install_custom_nginx_certificate_pair \
                    "${src_cert_dir}/fullchain.pem" \
                    "${src_cert_dir}/privkey.pem" \
                    "${new_domain}" "${dst_cert_dir}"; then
                    cert_ok=true
                fi
            fi
            if [[ "${cert_ok}" != true ]]; then
                echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.hy2_cert.apply_fail")" >&2
            fi
            if [[ "${cert_ok}" == true ]]; then
                echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_reuse.reuse_ok")" >&2
            fi
        else
            # 用户选择重新申请证书
            # 如果 CA 邮箱为空，则读取邮箱
            if [[ -z "${CA_EMAIL}" ]]; then
                exec_read 'email' || {
                    rollback_change_domain_transaction \
                        "${transaction_dir}" "${restart_nginx}" || true
                    return 1
                }
                CA_EMAIL="${CONFIG_DATA['email']}"
                SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg ca "${CA_EMAIL}" '.nginx.ca = $ca')"
                if ! write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"; then
                    rollback_change_domain_transaction \
                        "${transaction_dir}" "${restart_nginx}" || true
                    return 1
                fi
            fi
            # 自动申请 SSL 证书。安装或签发任一步失败都进入下方统一
            # 回滚分支，恢复旧站点配置。
            if handler_ssl_install &&
                exec_ssl '--issue' "--domain=${new_domain}"; then
                cert_ok=true
            fi
        fi
    fi
    if [[ "${cert_ok}" == true ]]; then
        # 设置证书目录权限，确保 nginx worker 可读
        local cert_dir="${NGINX_CONFIG_DIR}/certs/${new_domain}"
        if ! validate_tls_certificate_pair "${cert_dir}/fullchain.pem" "${cert_dir}/privkey.pem" ||
            ! certificate_matches_server_name "${cert_dir}/fullchain.pem" "${new_domain}"; then
            cert_ok=false
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.cert_invalid")" >&2
        elif ! set_nginx_certificate_permissions "${cert_dir}"; then
            cert_ok=false
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cert_source.path_invalid")" >&2
        elif ! ln -sfn \
            "${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf" \
            "${NGINX_CONFIG_DIR}/sites-enabled/${new_domain}.conf"; then
            cert_ok=false
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.nginx.path_sync_fail")" >&2
        fi
    fi
    if [[ "${cert_ok}" != true ]]; then
        rollback_change_domain_transaction \
            "${transaction_dir}" "${restart_nginx}" || true
        return 1
    fi
    # 更新脚本配置中的域名和该站点独立的证书来源。
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${new_domain}" '.nginx[$key] = $domain')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq \
        --arg key "${target_domain}" \
        --arg hostname "${new_domain}" \
        --arg source "${cert_source_reply}" \
        --arg fullchain "${cached_fullchain}" \
        --arg privkey "${cached_privkey}" '
        .nginx.certificates //= {} |
        .nginx.certificates[$key] = {hostname:$hostname,source:$source,fullchain:$fullchain,privkey:$privkey} |
        del(.nginx.certSource,.nginx.certFullchain,.nginx.certPrivkey)
    ')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${old_domain}" 'if $key == "domain" then del(.target[$key]) else . end')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${new_domain}" 'if $key == "domain" then .xray.target = $domain else . end')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg key "${target_domain}" --arg domain "${new_domain}" 'if $key == "domain" then .xray.serverNames = [$domain] else . end')"
    if [[ "${CONFIG_TAG,,}" == "sni" ]]; then
        local stream_temp
        stream_temp="$(mktemp "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf.tmp.XXXXXX")" || {
            rollback_change_domain_transaction \
                "${transaction_dir}" "${restart_nginx}" || true
            return 1
        }
        if ! remove_change_domain_transaction_target \
                "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" 'n' ||
            ! render_nginx_stream_config "${stream_temp}" ||
            ! mv -f -- "${stream_temp}" \
                "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf"; then
            rm -f -- "${stream_temp}"
            rollback_change_domain_transaction \
                "${transaction_dir}" "${restart_nginx}" || true
            return 1
        fi
    else
        if ! remove_change_domain_transaction_target \
            "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" 'n'; then
            rollback_change_domain_transaction \
                "${transaction_dir}" "${restart_nginx}" || true
            return 1
        fi
    fi
    # 将更新后的脚本配置写入文件
    if ! write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"; then
        rollback_change_domain_transaction \
            "${transaction_dir}" "${restart_nginx}" || true
        return 1
    fi
    # 如果仅更新域名
    if [[ "${CONFIG_DATA['only-change-domain']:-n}" =~ ^[Yy]$ ]]; then
        local old_site_snapshot="${transaction_dir}/root/sites-available/${old_domain}.conf"
        if [[ -z "${old_domain}" ||
            ! -f "${old_site_snapshot}" ||
            -L "${old_site_snapshot}" ]] ||
            ! remove_change_domain_transaction_target \
                "${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf" 'n' ||
            ! cp -a -- "${old_site_snapshot}" \
                "${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf"; then
            rollback_change_domain_transaction \
                "${transaction_dir}" "${restart_nginx}" || true
            return 1
        fi
        local site_temp
        site_temp="$(mktemp "${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf.tmp.XXXXXX")" || {
            rollback_change_domain_transaction \
                "${transaction_dir}" "${restart_nginx}" || true
            return 1
        }
        if ! render_managed_site_domain \
            "${old_site_snapshot}" "${site_temp}" "${new_domain}" ||
            ! mv -f -- "${site_temp}" \
                "${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf"; then
            rm -f -- "${site_temp}"
            rollback_change_domain_transaction \
                "${transaction_dir}" "${restart_nginx}" || true
            return 1
        fi
        # 创建从 available 到 enabled 的软链接
        if ! ln -sfn \
            "${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf" \
            "${NGINX_CONFIG_DIR}/sites-enabled/${new_domain}.conf"; then
            rollback_change_domain_transaction \
                "${transaction_dir}" "${restart_nginx}" || true
            return 1
        fi
    fi
    if [[ "${restart_nginx}" != 'n' ]]; then
        if ! handler_nginx_restart; then
            rollback_change_domain_transaction \
                "${transaction_dir}" "${restart_nginx}" || true
            return 1
        fi
    fi

    if [[ -n "${old_domain}" && "${stop_cert_service}" == 'y' ]] &&
        acme_manages_certificate "${old_domain}"; then
        if [[ "${old_domain}" != "${new_domain}" ]]; then
            cleanup_acme_certificate_if_unused "${old_domain}" 'y' ||
                true
        elif [[ "${cert_source_reply}" == '2' ]]; then
            cleanup_acme_certificate_if_unused "${old_domain}" 'n' ||
                true
        fi
    fi
    if ! cleanup_change_domain_transaction "${transaction_dir}"; then
        echo "Change-domain transaction cleanup failed; retained at: ${transaction_dir}" >&2
        return 1
    fi
}

# =============================================================================
# 函数名称: handler_renew_ssl
# 功能描述: 强制续期所有由 acme.sh 管理的 SSL 证书。
# 参数: 无
# 返回值: 无 (通过文件操作和调用其他脚本执行)
# =============================================================================
function handler_renew_ssl() {
    local config_tag
    config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')"
    if [[ "${config_tag,,}" == 'cdn' && "$(get_cdn_backend)" == 'xray' ]]; then
        handler_restore_certificate_renewal_hooks || return 1
        handler_cdn_direct_cert 'renew' || return 1
        handler_restart
        return $?
    fi

    # 任何续签或服务重载失败都必须反馈给调用者，不能让 if 的空分支
    # 把失败状态吞掉。
    handler_restore_certificate_renewal_hooks || return 1
    exec_ssl '--renew' || return 1
    if current_protocol_uses_nginx; then
        handler_nginx_restart || return 1
    fi
    handler_restart || return 1
}

# =============================================================================
# 函数名称: handler_nginx_config
# 功能描述: 配置 Nginx。
#           1. 创建 sites-enabled 目录。
#           2. 备份并复制 Nginx 主配置文件和站点配置模板。
#           3. 从脚本配置中读取域名和 CDN。
#           4. 调用 handler_change_domain 为域名和 CDN 配置 SSL。
# 参数: 无
# 返回值: 无 (通过文件操作执行)
# =============================================================================
function handler_nginx_config() {
    # 创建 Nginx sites-enabled 目录 (如果不存在)
    mkdir -vp \
        "${NGINX_CONFIG_DIR}" \
        "${NGINX_CONFIG_DIR}/sites-available" \
        "${NGINX_CONFIG_DIR}/sites-enabled" || return 1
    # 只保留第一次接管前的原始配置，重复执行不能覆盖这份备份。
    if [[ -f "${NGINX_CONFIG_DIR}/nginx.conf" &&
        ! -f "${NGINX_CONFIG_DIR}/default.conf.bak" ]]; then
        cp -p "${NGINX_CONFIG_DIR}/nginx.conf" "${NGINX_CONFIG_DIR}/default.conf.bak" || return 1
    fi
    # 复制项目中的 Nginx 配置文件到目标目录
    cp -af "${CONFIG_DIR}/nginx/conf/." "${NGINX_CONFIG_DIR}/" || return 1

    # 动态检测 nginx 二进制是否包含 brotli 压缩模块，如果不包含，则自动注释 general.conf 中的 brotli 配置，以防 Nginx 启动/重载报错
    if cmd_exists 'nginx' && ! nginx -V 2>&1 | grep -qi 'brotli'; then
        if [[ -f "${NGINX_CONFIG_DIR}/nginxconfig.io/general.conf" ]]; then
            sed -i 's|^\([[:space:]]*\)brotli|\1#brotli|g' "${NGINX_CONFIG_DIR}/nginxconfig.io/general.conf"
        fi
    fi
}

# =============================================================================
# 函数名称: handler_cloudreve_v3
# 功能描述: 管理 Cloudreve v3 Docker 容器。
#           1. 确保 Docker 已安装。
#           2. 根据传入参数调用 docker.sh 执行对应操作。
# 参数:
#   $1: action - 要执行的操作 (install, get, token, reset, purge, start, stop)
# 返回值: 无 (通过调用 docker.sh 脚本执行操作)
# =============================================================================
function handler_cloudreve_v3() {
    # 停止或清理一个从未安装过的容器时，不应反过来安装 Docker。
    if [[ "${1}" == 'stop' || "${1}" == 'purge' ]]; then
        cmd_exists 'docker' || return 0
    else
        handler_docker || return 1
    fi
    # 根据传入的操作参数执行对应动作
    case "${1}" in
    install) exec_docker '--install-cloudreve-v3' ;;   # 安装 Cloudreve v3
    get) exec_docker '--get-cloudreve-v3-admin' ;;     # 获取 Cloudreve v3 管理员信息
    token) exec_docker '--get-aria2-token' ;;          # 获取 Aria2 Token
    reset) exec_docker '--reset-cloudreve-v3-admin' ;; # 重置 Cloudreve v3 管理员
    purge) exec_docker '--purge-cloudreve-v3' ;;       # 卸载 Cloudreve v3
    start) exec_docker '--start-cloudreve-v3' ;;       # 启动 Cloudreve v3
    stop) exec_docker '--stop-cloudreve-v3' ;;         # 停止 Cloudreve v3
    esac
}

# =============================================================================
# 函数名称: handler_cloudreve_v4
# 功能描述: 管理 Cloudreve v4 Docker 容器。
#           1. 确保 Docker 已安装。
#           2. 根据传入参数调用 docker.sh 执行对应操作。
# 参数:
#   $1: action - 要执行的操作 (install, update, purge, start, stop)
# 返回值: 无 (通过调用 docker.sh 脚本执行操作)
# =============================================================================
function handler_cloudreve_v4() {
    if [[ "${1}" == 'stop' || "${1}" == 'purge' ]]; then
        cmd_exists 'docker' || return 0
    else
        handler_docker || return 1
    fi
    # 根据传入的操作参数执行对应动作
    case "${1}" in
    install) exec_docker '--install-cloudreve-v4' ;; # 安装 Cloudreve v4
    update) exec_docker '--update-cloudreve-v4' ;;   # 更新 Cloudreve v4
    purge) exec_docker '--purge-cloudreve-v4' ;;     # 卸载 Cloudreve v4
    start) exec_docker '--start-cloudreve-v4' ;;     # 启动 Cloudreve v4
    stop) exec_docker '--stop-cloudreve-v4' ;;       # 停止 Cloudreve v4
    esac
}

function handler_restore_configured_web_backend() {
    local web restore_status=0

    web="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.web // "normal"')"
    case "${web}" in
    v3)
        handler_cloudreve_v4 'stop' || restore_status=1
        handler_cloudreve_v3 'start' || restore_status=1
        ;;
    v4)
        handler_cloudreve_v3 'stop' || restore_status=1
        handler_cloudreve_v4 'start' || restore_status=1
        ;;
    *)
        handler_cloudreve_v3 'stop' || restore_status=1
        handler_cloudreve_v4 'stop' || restore_status=1
        ;;
    esac
    return "${restore_status}"
}

# =============================================================================
# 函数名称: handler_web
# 功能描述: 配置和管理 Web 服务 (Cloudreve) 与 Nginx 的集成。
#           1. 根据 Web 类型启动/停止对应的 Cloudreve 容器。
#           2. 修改 Nginx 配置文件以包含或排除 Cloudreve 配置片段。
#           3. 调用 handler_nginx_restart 重启 Nginx 服务。
#           4. 调用 handler_restart 重启 Xray 服务。
#           5. 更新脚本配置中的 Web 类型。
# 参数:
#   $1: web - Web 服务类型 ("v3", "v4", 或默认的 "normal")
# 返回值: 无 (通过调用其他函数执行操作)
# =============================================================================
function handler_web() {
    reject_nginx_action_in_cdn_direct_mode || return 1

    local web="${1:-normal}"
    local restart_xray="${2:-y}"
    local previous_script_config="${SCRIPT_CONFIG}"
    local transaction_dir=''
    # 从脚本配置中读取域名和 CDN
    local config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')"
    local domain="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.domain // ""')"
    local cdn="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdn // ""')"
    local cdn_down="$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.cdnDown // ""')"
    local site_domains=()
    case "${config_tag,,}" in
    cdn)
        [[ -n "${cdn}" ]] && site_domains+=("${cdn}")
        [[ -n "${cdn_down}" ]] && site_domains+=("${cdn_down}")
        ;;
    sni)
        [[ -n "${domain}" ]] && site_domains+=("${domain}")
        [[ -n "${cdn}" ]] && site_domains+=("${cdn}")
        ;;
    esac
    case "${web}" in
    normal | v3 | v4) ;;
    *) return 1 ;;
    esac
    if [[ "${web}" != 'normal' && "${#site_domains[@]}" -eq 0 ]]; then
        return 1
    fi

    transaction_dir="$(mktemp -d "${SCRIPT_CONFIG_DIR}/web-change.XXXXXX")" || return 1
    local -a site_files=() backup_files=()
    local site_domain site_file backup_file
    for site_domain in "${site_domains[@]}"; do
        site_file="${NGINX_CONFIG_DIR}/sites-available/${site_domain}.conf"
        [[ -f "${site_file}" ]] || {
            rm -rf -- "${transaction_dir}"
            return 1
        }
        backup_file="${transaction_dir}/${#backup_files[@]}.conf"
        cp -p -- "${site_file}" "${backup_file}" || {
            rm -rf -- "${transaction_dir}"
            return 1
        }
        site_files+=("${site_file}")
        backup_files+=("${backup_file}")
    done

    function rollback_web_change() {
        local index rollback_status=0
        SCRIPT_CONFIG="${previous_script_config}"
        for ((index = 0; index < ${#site_files[@]}; index++)); do
            cp -p -- "${backup_files[index]}" "${site_files[index]}" || rollback_status=1
        done
        handler_restore_configured_web_backend || rollback_status=1
        handler_nginx_restart || rollback_status=1
        if [[ "${restart_xray}" != 'n' ]]; then
            handler_restart || rollback_status=1
        fi
        if [[ "${rollback_status}" -eq 0 ]]; then
            rm -rf -- "${transaction_dir}"
        else
            echo "Web change rollback failed; recovery files retained at: ${transaction_dir}" >&2
        fi
        return "${rollback_status}"
    }

    case "${web}" in
    v3)
        handler_cloudreve_v4 'stop' && handler_cloudreve_v3 'start' || {
            rollback_web_change || true
            return 1
        }
        ;;
    v4)
        handler_cloudreve_v3 'stop' && handler_cloudreve_v4 'start' || {
            rollback_web_change || true
            return 1
        }
        ;;
    *)
        handler_cloudreve_v3 'stop' && handler_cloudreve_v4 'stop' || {
            rollback_web_change || true
            return 1
        }
        ;;
    esac

    case "${web}" in
    v3 | v4)
        for site_domain in "${site_domains[@]}"; do
            site_file="${NGINX_CONFIG_DIR}/sites-available/${site_domain}.conf"
            if ! sed -i 's|^[[:space:]]*#[[:space:]]*include web/cloudreve\.conf;|  include web/cloudreve.conf;|' \
                    "${site_file}" ||
                [[ "$(grep -Ec '^[[:space:]]*include[[:space:]]+web/cloudreve\.conf;[[:space:]]*$' "${site_file}")" -ne 1 ]] ||
                grep -Eq '^[[:space:]]*#[[:space:]]*include[[:space:]]+web/cloudreve\.conf;' "${site_file}"; then
                rollback_web_change || true
                return 1
            fi
        done
        ;;
    *)
        for site_domain in "${site_domains[@]}"; do
            site_file="${NGINX_CONFIG_DIR}/sites-available/${site_domain}.conf"
            if ! sed -i 's|^[[:space:]]*include web/cloudreve\.conf;|  # include web/cloudreve.conf;|' \
                    "${site_file}" ||
                [[ "$(grep -Ec '^[[:space:]]*#[[:space:]]*include[[:space:]]+web/cloudreve\.conf;[[:space:]]*$' "${site_file}")" -ne 1 ]] ||
                grep -Eq '^[[:space:]]*include[[:space:]]+web/cloudreve\.conf;' "${site_file}"; then
                rollback_web_change || true
                return 1
            fi
        done
        ;;
    esac
    if ! handler_nginx_restart; then
        rollback_web_change || true
        return 1
    fi
    if [[ "${restart_xray}" != 'n' ]]; then
        if ! handler_restart; then
            rollback_web_change || true
            return 1
        fi
    fi
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg web "${web}" '.nginx.web = $web')" || {
        rollback_web_change || true
        return 1
    }
    if ! write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"; then
        rollback_web_change || true
        return 1
    fi
    rm -rf -- "${transaction_dir}"
}

# =============================================================================
# 函数名称: handler_reverse_config
# 功能描述: 将反向代理配置追加到 Xray 配置中 (在保存到文件前调用)。
# 参数: 无
# 返回值: 无 (修改全局变量 XRAY_CONFIG)
# =============================================================================
function handler_reverse_config() {
    local reverse_uuid reverse_port config_tag reverse_network
    reverse_uuid="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.reverseUuid // ""')"
    reverse_port="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.reversePort // 8443')"
    config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')"
    protocol_supports_reverse "${config_tag}" || {
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} Reverse proxy is not supported by ${config_tag}." >&2
        return 1
    }
    [[ -n "${reverse_uuid}" ]] || return 1
    [[ "${config_tag,,}" == 'xhttp' ]] && reverse_network='xhttp' || reverse_network='raw'

    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --arg uuid "${reverse_uuid}" --arg network "${reverse_network}" '
        .inbounds |= map(
            if .protocol? == "vless" and (.streamSettings.network? // "raw") == $network then
                ({
                    "email": "reverse@xtls.reality",
                    "id": $uuid,
                    "flow": (.settings.clients[0].flow // "xtls-rprx-vision"),
                    "reverse": {"tag": "reverse-out"}
                }) as $client |
                if any(.settings.clients[]?; .email == "reverse@xtls.reality") then
                    .settings.clients |= map(if .email == "reverse@xtls.reality" then $client else . end)
                else
                    .settings.clients += [$client]
                end
            else . end
        )
    ')" || return 1
    if ! echo "${XRAY_CONFIG}" | jq -e 'any(.inbounds[]?; any(.settings.clients[]?; .email == "reverse@xtls.reality"))' >/dev/null; then
        return 1
    fi

    # 2. 追加 tunnel 协议的 inbound
    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson port "${reverse_port}" '
        if any(.inbounds[]?; .tag == "reverse-portal") then
            .inbounds |= map(if .tag == "reverse-portal" then .port = $port else . end)
        else
            .inbounds += [{
                "tag": "reverse-portal",
                "listen": "0.0.0.0",
                "port": $port,
                "protocol": "tunnel"
            }]
        end
    ')" || return 1

    # 3. 追加对应的路由规则
    local route_rule='{"ruleTag":"reverse-portal","inboundTag":["reverse-portal"],"outboundTag":"reverse-out"}'
    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq --argjson new_rule "${route_rule}" '
        if any(.routing.rules[]?; .ruleTag == "reverse-portal") then
            .routing.rules |= map(if .ruleTag == "reverse-portal" then $new_rule else . end)
        else
            (.routing.rules | map(.ruleTag) | index("private-ip")) as $private_index |
            if $private_index == null then
                .routing.rules += [$new_rule]
            else
                .routing.rules = (.routing.rules[:$private_index] + [$new_rule] + .routing.rules[$private_index:])
            end
        end
    ')" || return 1
}

# =============================================================================
# 函数名称: handler_reverse_toggle
# 功能描述: 开启或关闭反向代理功能。
# 参数: 无
# 返回值: 无
# =============================================================================
function handler_reverse_toggle() {
    local requested_state="${1,,}"
    local original_script_config="${SCRIPT_CONFIG}"
    local original_xray_config=''
    local reverse_status=''
    local reverse_port=''
    local reverse_target=''
    local reverse_uuid=''
    local xray_ver=''

    case "${requested_state}" in
    enable | disable) ;;
    *) return 1 ;;
    esac
    reverse_status="$(echo "${SCRIPT_CONFIG}" | jq -r '(.xray.reverse // 0) | tonumber? // 0')" || return 1
    if [[ "${requested_state}" == 'enable' && "${reverse_status}" -eq 1 ]] ||
        [[ "${requested_state}" == 'disable' && "${reverse_status}" -eq 0 ]]; then
        return 0
    fi
    original_xray_config="$(jq '.' "${XRAY_CONFIG_PATH}")" || return 1

    if [[ "${requested_state}" == 'enable' ]]; then
        xray_ver="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.version // ""')" || return 1
        if [[ -z "${xray_ver}" ]]; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.reverse.not_installed")" >&2
            return 1
        fi
        local config_tag
        config_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')" || return 1
        if ! protocol_supports_reverse "${config_tag}"; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} Reverse proxy is not supported by ${config_tag}." >&2
            return 1
        fi

        exec_read 'reverse-port' || return 1
        exec_read 'reverse-target' || return 1
        exec_read 'reverse-uuid' || return 1

        reverse_port="${CONFIG_DATA['reverse-port']:-8443}"
        reverse_target="${CONFIG_DATA['reverse-target']}"
        reverse_uuid="${CONFIG_DATA['reverse-uuid']}"
        reverse_uuid="$(exec_generate '--uuid' "${reverse_uuid}")" || return 1
        [[ -n "${reverse_uuid}" ]] || return 1
    fi

    if [[ "${requested_state}" == 'disable' ]]; then
        local previous_reverse_port
        previous_reverse_port="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.reversePort // 8443')"
        close_owned_firewall_ports 'reverse' "${previous_reverse_port}" 1 || return 1
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '
            .xray.reverse = 0 |
            .xray.reverseUuid = "" |
            .xray.reverseTarget = "" |
            .xray.reverseMode = "" |
            del(.xray.reversePort)
        ')" || {
            restore_owned_firewall_feature_state \
                "${original_script_config}" 'reverse' "${previous_reverse_port}" tcp || true
            return 1
        }
        if ! apply_xray_state_transaction "${original_script_config}" "${original_xray_config}"; then
            restore_owned_firewall_feature_state \
                "${original_script_config}" 'reverse' "${previous_reverse_port}" tcp || true
            return 1
        fi
        echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.reverse.disabled")" >&2
    else
        SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq \
            --argjson port "${reverse_port}" --arg target "${reverse_target}" --arg uuid "${reverse_uuid}" '
            .xray.reverse = 1 |
            .xray.reversePort = $port |
            .xray.reverseTarget = $target |
            .xray.reverseUuid = $uuid |
            .xray.reverseMode = "forward"
        ')" || return 1
        apply_xray_state_transaction "${original_script_config}" "${original_xray_config}" || return 1
        echo -e "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.config')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.reverse.enabled")" >&2
    fi
}

# =============================================================================
# 函数名称: handler_reverse_share
# 功能描述: 生成并打印内网端(Bridge)的配置模板供复制使用。
# 参数: 无
# 返回值: 无
# =============================================================================
function handler_reverse_share() {
    local reverse_status=$(echo "${SCRIPT_CONFIG}" | jq -r '(.xray.reverse // 0) | tonumber? // 0')
    if [[ "${reverse_status}" -ne 1 ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.reverse.no_reverse")" >&2
        return 1
    fi

    local reverse_uuid=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.reverseUuid // ""')
    local reverse_target=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.reverseTarget // ""')
    local current_tag=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')
    local xray_port=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.port // 443')
    local server_name=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.serverNames[0] // ""')
    local public_key=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.publicKey // ""')
    local short_id=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.shortIds[0] // ""')
    local xhttp_path=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.path // ""')
    local xhttp_mode=$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.xhttpMode // "auto"')

    if ! protocol_supports_reverse "${current_tag}"; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} Reverse proxy sharing is not supported by ${current_tag}." >&2
        return 1
    fi
    if [[ -z "${reverse_uuid}" || -z "${reverse_target}" || -z "${server_name}" || -z "${public_key}" ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} Reverse proxy state is incomplete." >&2
        return 1
    fi
    if [[ "${current_tag,,}" == 'xhttp' && -z "${xhttp_path}" ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} Reverse proxy XHTTP path is missing." >&2
        return 1
    fi
    parse_host_port "${reverse_target}" || return 1
    local target_host="${PARSED_HOST}"
    local target_port="${PARSED_PORT}"
    local target_is_ip=false
    [[ "${PARSED_HOST_IS_IP}" -eq 1 ]] && target_is_ip=true
    reverse_target="$(format_host_port "${target_host}" "${target_port}")" || return 1

    local server_ip
    server_ip="$(curl -fsS4 --max-time 10 https://api.ipify.org 2>/dev/null || curl -fsS6 --max-time 10 https://api64.ipify.org 2>/dev/null)"
    if [[ -z "${server_ip}" ]] || ! valid_ip_literal "${server_ip}"; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.reverse.ip_fetch_fail")" >&2
        return 1
    fi

    # 构造 VLESS outbound settings
    local vless_settings
    if [[ "${current_tag,,}" == "xhttp" ]]; then
        vless_settings=$(jq -n \
            --arg addr "${server_ip}" \
            --argjson port "${xray_port}" \
            --arg uuid "${reverse_uuid}" \
            '{
                "address": $addr,
                "port": $port,
                "id": $uuid,
                "encryption": "none",
                "reverse": {
                    "tag": "reverse-in"
                }
            }')
    else
        vless_settings=$(jq -n \
            --arg addr "${server_ip}" \
            --argjson port "${xray_port}" \
            --arg uuid "${reverse_uuid}" \
            --arg flow "xtls-rprx-vision" \
            '{
                "address": $addr,
                "port": $port,
                "id": $uuid,
                "flow": $flow,
                "encryption": "none",
                "reverse": {
                    "tag": "reverse-in"
                }
            }')
    fi

    # 构造 streamSettings
    local stream_settings
    if [[ "${current_tag,,}" == "xhttp" ]]; then
        stream_settings=$(jq -n \
            --arg sn "${server_name}" \
            --arg pbk "${public_key}" \
            --arg sid "${short_id}" \
            --arg path "${xhttp_path}" \
            --arg mode "${xhttp_mode}" \
            '{
                "network": "xhttp",
                "security": "reality",
                "realitySettings": {
                    "serverName": $sn,
                    "publicKey": $pbk,
                    "shortId": $sid,
                    "fingerprint": "chrome",
                    "spiderX": "/"
                },
                "xhttpSettings": {
                    "path": $path,
                    "mode": $mode
                }
            }')
    else
        stream_settings=$(jq -n \
            --arg sn "${server_name}" \
            --arg pbk "${public_key}" \
            --arg sid "${short_id}" \
            '{
                "network": "raw",
                "security": "reality",
                "realitySettings": {
                    "serverName": $sn,
                    "publicKey": $pbk,
                    "shortId": $sid,
                    "fingerprint": "chrome",
                    "spiderX": "/"
                }
            }')
    fi

    # 构造完整配置
    local config
    config=$(jq -n \
        --argjson vless_s "${vless_settings}" \
        --argjson stream_s "${stream_settings}" \
        --arg target_host "${target_host}" \
        --argjson target_port "${target_port}" \
        --argjson target_is_ip "${target_is_ip}" \
        --arg redirect_str "${reverse_target}" \
        '{
            "log": {
                "loglevel": "warning"
            },
            "routing": {
                "rules": [
                    {
                        "inboundTag": ["reverse-in"],
                        "outboundTag": "reverse-direct"
                    }
                ]
            },
            "outbounds": [
                {
                    "protocol": "freedom"
                },
                {
                    "protocol": "freedom",
                    "tag": "reverse-direct",
                    "settings": {
                        "redirect": $redirect_str,
                        "finalRules": [(
                            {
                                "action": "allow",
                                "network": "tcp",
                                "port": $target_port
                            } + (if $target_is_ip then {ip: $target_host} else {} end)
                        )]
                    }
                },
                {
                    "protocol": "vless",
                    "settings": $vless_s,
                    "streamSettings": $stream_s
                }
            ]
        }')

    echo -e "${GREEN}$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.reverse.bridge_title")${NC}"
    echo -e "$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.reverse.bridge_hint")"
    echo "--------------------------------------------------"
    echo "${config}" | jq '.'
    echo "--------------------------------------------------"
    echo -e "$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.reverse.bridge_info")"
}

# =============================================================================
# 函数名称: handler_quick_install
# 功能描述: 执行一键快速安装流程。
#           1. 调用 handler_script_config 配置脚本。
#           2. 调用 handler_install 安装 Xray。
#           3. 调用 handler_geodata_cron 更新 GeoData 并设置 Cron。
#           4. 调用 handler_xray_config 配置 Xray 并持久化默认阻止规则。
#           5. 调用 handler_restart 重启 Xray 服务。
#           6. 调用 handler_share 显示分享链接。
# 参数:
#   $1: quick_install_type - 速安装类型 (例如 Vision, XHTTP, Fallback)，默认为 Vision
# 返回值: 无 (通过调用一系列处理器函数执行完整安装流程)
# =============================================================================
function handler_quick_install() {
    local quick_install_type="${1:-Vision}" # 获取快速安装类型参数，默认为 Vision
    # Legacy quick installs still collect both post-quantum choices together,
    # before any package installation output begins.
    if protocol_uses_vless_enc "${quick_install_type}"; then
        # Preserve the legacy non-interactive quick-install default on EOF.
        run_vlessenc_choice 'y' || return 1
    fi
    if protocol_uses_reality "${quick_install_type}"; then
        run_mldsa65_choice 'n' || return 1
    fi
    if ! cmd_exists 'xray'; then
        run_github_proxy_choice 'n' || return 1
    fi
    # 快速安装固定启用默认规则，并由 handler_xray_config 一次性提交。
    CONFIG_DATA['rules']='Y'
    CONFIG_DATA['block-bt']='Y'
    CONFIG_DATA['block-cn']='Y'
    CONFIG_DATA['block-ad']='Y'
    # 配置脚本 (设置各种参数)
    handler_script_config "${quick_install_type}" || return 1
    # 安装 Xray (使用 release 版本)
    handler_install 'release' || return 1
    # HY2 cannot generate a runnable configuration before its certificate is
    # successfully installed and validated.
    if protocol_uses_hy2_certificate "${quick_install_type}"; then
        handler_hy2_cert || return 1
    fi
    if protocol_uses_reality "${quick_install_type}"; then
        handler_reality_key_config || return 1
    fi
    # 先完成 GeoData 更新，避免其失败发生在新运行配置提交之后。
    handler_geodata_cron 1 || return 1
    # 配置 Xray (生成并写入 config.json)
    if protocol_uses_vless_enc "${quick_install_type}"; then
        handler_xray_config || return 1
    else
        handler_xray_config 1 || return 1
    fi
    # 重启 Xray 服务
    handler_restart || return 1
    handler_restore_certificate_renewal_hooks || return 1
    # 显示分享链接
    handler_share || return 1
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 根据传入的第一个参数 ($1) 调用对应的处理器函数。
#           3. 将剩余参数传递给处理器函数。
# 参数:
#   $@: 命令行参数，第一个参数决定要调用的处理器函数
# 返回值: 无 (通过调用其他函数执行具体操作)
# =============================================================================
function main() {
    # 加载国际化数据
    load_i18n

    local option="$1" # 获取第一个参数作为操作选项
    shift             # 移除第一个参数，剩下的参数留给具体函数处理

    # 根据第一个参数调用对应的处理器函数
    case "${option}" in
    --quick) handler_quick_install "$1" ;;    # 一键快速安装
    --install) handler_install "$@" ;;        # 安装 Xray
    --version) handler_xray_version "$1" ;;   # 设置 Xray 版本
    --purge) handler_purge ;;                 # 卸载 Xray
    --nginx-install)
        reject_nginx_action_in_cdn_direct_mode || return 1
        handler_nginx_install
        ;; # 安装 Nginx
    --nginx-update)
        reject_nginx_action_in_cdn_direct_mode || return 1
        handler_nginx_update
        ;; # 更新 Nginx
    --nginx-purge) handler_nginx_purge ;;     # 卸载 Nginx
    --cdn-backend) handler_set_cdn_backend "$1" ;; # 设置 CDN 回源后端
    --change-cdn-down)
        if [[ "$(get_cdn_backend)" == 'xray' ]]; then
            handler_change_cdn_down_direct
        else
            handler_change_cdn_down_nginx
        fi
        ;;
    --cleanup-cdn-down) handler_cleanup_stale_cdn_down "$@" ;;
    --recover-runtime) handler_recover_runtime_services ;; # 按当前运行配置恢复服务
    --deploy-acme-certificate) handler_deploy_acme_certificate "$@" ;;
    --restore-certificate-hooks) handler_restore_certificate_renewal_hooks ;;
    --script-config)
        if [[ "${1,,}" == 'multi' ]]; then
            handler_read_multi_xray_config || return 1
        else
            handler_read_xray_config "$1" || return 1 # 读取 Xray 配置输入
        fi
        handler_script_config || return 1 # 更新脚本配置
        ;;
    --xray-config)
        local current_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag')"
        handler_prepare_protocol_services "${1:-}" || return 1
        if [[ "${current_tag,,}" == 'cdn' && "$(get_cdn_backend)" == 'xray' ]]; then
            handler_cdn_direct_cert || return 1
        fi

        if [[ "${current_tag,,}" == 'multi' ]]; then
            local has_hy2="$(echo "${SCRIPT_CONFIG}" | jq -r 'any(.xray.nodes[]?; (.tag | ascii_downcase) == "hy2")')"
            local has_vless="$(echo "${SCRIPT_CONFIG}" | jq -r 'any(.xray.nodes[]?; ((.tag | ascii_downcase) == "mkcp") or ((.tag | ascii_downcase) == "vision") or ((.tag | ascii_downcase) == "xhttp") or ((.tag | ascii_downcase) == "fallback"))')"
            local has_reality="$(echo "${SCRIPT_CONFIG}" | jq -r 'any(.xray.nodes[]?; ((.tag | ascii_downcase) == "vision") or ((.tag | ascii_downcase) == "xhttp") or ((.tag | ascii_downcase) == "trojan") or ((.tag | ascii_downcase) == "fallback"))')"
            if [[ "${has_hy2}" == 'true' ]]; then
                handler_hy2_cert || return 1
            fi
            if [[ "${has_reality}" == 'true' ]]; then
                handler_reality_key_config || return 1
            fi

            if [[ "${has_vless}" == 'true' ]]; then
                handler_xray_config || return 1
            else
                handler_xray_config 1 || return 1
            fi
        elif protocol_uses_hy2_certificate "${current_tag}"; then
            handler_hy2_cert || return 1
            handler_xray_config 1 || return 1
        else
            if protocol_uses_reality "${current_tag}"; then
                handler_reality_key_config || return 1
            fi

            if protocol_uses_vless_enc "${current_tag}"; then
                handler_xray_config || return 1
            else
                handler_xray_config 1 || return 1
            fi
        fi
        ;;
    --routing) handler_routing "$@" ;; # 处理路由规则
    --change-domain)
        local change_tag="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.tag // ""')"
        if [[ "${change_tag,,}" == 'cdn' && "$(get_cdn_backend)" == 'xray' ]]; then
            echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.cdn_direct.use_reconfigure")" >&2
            return 1
        fi
        handler_change_domain "$1" || return 1 # 处理域名配置
        handler_xray_config || return 1         # 更新 Xray 配置
        handler_restart || return 1             # 重启 Xray
        handler_restore_certificate_renewal_hooks || return 1
        if ! [[ "${CONFIG_DATA['only-change-domain'],,}" == "y" ]]; then
            # 还原 Web 服务
            handler_web "$(echo "${SCRIPT_CONFIG}" | jq -r '.nginx.web')" || return 1
        fi
        ;;                                      # 更改域名
    --renew-certificate) handler_renew_ssl ;;   # 强制证书续签
    --web) handler_web "$1" ;;                  # 配置 Web 服务
    --v3-reset) handler_cloudreve_v3 'reset' ;; # 重置 Cloudreve v3
    --share) handler_share ;;                   # 显示分享链接
    --nginx-cron)
        reject_nginx_action_in_cdn_direct_mode || return 1
        handler_nginx_cron
        ;; # 管理 Nginx Cron
    --geodata-cron) handler_geodata_cron ;;     # 管理 GeoData Cron
    --warp) handler_warp ;;                     # 管理 WARP
    --reset-warp) handler_reset_warp ;;         # 重置 WARP
    --traffic) handler_traffic ;;               # 显示流量统计
    --reverse) handler_reverse_toggle "$1" ;;    # 开启/关闭反向代理
    --reverse-share) handler_reverse_share ;;   # 查看内网端配置模板
    --lan-enable) handler_lan_enable ;;          # 启用异地组网 Hub
    --lan-disable) handler_lan_disable ;;        # 禁用异地组网 Hub
    --lan-add) handler_lan_add_site ;;           # 添加组网站点
    --lan-remove) handler_lan_remove_site ;;     # 删除组网站点
    --lan-list) handler_lan_list ;;              # 查看组网站点
    --lan-export) handler_lan_export_site ;;     # 导出站点端配置包
    --change-port)
        handler_change_xray_port || return 1 # 处理 Xray 端口配置
        handler_share                        # 显示分享链接
        ;;                        # 修改 Xray 端口
    --start) handler_start ;;     # 启动 Xray
    --stop) handler_stop ;;       # 停止 Xray
    --restart) handler_restart ;; # 重启 Xray
    esac
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
