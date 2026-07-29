#!/usr/bin/env bash
# =============================================================================
# 注释: 通过 Qwen3-Coder 生成。
# 脚本名称: main.sh
# 脚本仓库: https://github.com/zxcvos/Xray-script
# 功能描述: X-UI 项目的主要管理脚本。
#           提供交互式菜单和命令行接口，用于安装、配置、管理 Xray-core
#           和相关服务（如 Nginx, GeoIP, WARP 等），支持多语言。
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash, jq, cut, sed
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language) 和脚本配置
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
#
# Copyright (C) 2025 zxcvos
# =============================================================================

# set -Eeuxo pipefail

# --- 环境与常量设置 ---
readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
readonly CUR_FILE="$(basename "$0" | sed 's/\..*//')"
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)"

# 引入公共库
source "${PROJECT_ROOT}/lib/common.sh"
source "${PROJECT_ROOT}/lib/protocols.sh"

# 定义配置文件和相关目录/脚本的路径
readonly SCRIPT_CONFIG_DIR="${HOME}/.xray-script"
readonly I18N_DIR="${PROJECT_ROOT}/i18n"
readonly CONFIG_DIR="${PROJECT_ROOT}/config"
readonly MENU_PATH="${CUR_DIR}/menu.sh"
readonly HANDLER_PATH="${CUR_DIR}/handler.sh"
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json"
readonly XRAY_RUNTIME_CONFIG_PATH="${XRAY_CONFIG_PATH_OVERRIDE:-/usr/local/etc/xray/config.json}"
readonly NGINX_CONFIG_DIR="${NGINX_CONFIG_DIR_OVERRIDE:-/usr/local/nginx/conf}"

# --- 全局变量声明 ---
declare LANG_PARAM=''
declare I18N_DATA=''
declare SCRIPT_CONFIG=''


# =============================================================================
# 函数名称: _error
# 功能描述: 打印错误信息到标准错误输出并退出脚本。
# 参数:
#   $@: 要输出的错误信息文本
# 返回值: 无 (直接打印到标准错误输出 >&2 并退出)
# 退出码: 1
# =============================================================================

function _error() {
    # 打印红色的错误标题（从 i18n 数据获取）
    printf "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')] ${NC}"
    # 打印传入的错误信息
    printf -- "%s" "$@"
    # 打印换行符
    printf "\n"
    # 退出脚本，错误码为 1
    exit 1
}

# =============================================================================
# 函数名称: exec_menu
# 功能描述: 执行菜单脚本 (menu.sh)，并将菜单脚本的退出码作为返回值。
# 参数:
#   $@: 传递给 menu.sh 脚本的参数
# 返回值: menu.sh 脚本的退出码 (通过 return ${OPTION} 返回)
# =============================================================================

function exec_menu() {
    local OPTION=0 # 初始化局部变量 OPTION 为 0
    # 执行菜单脚本，并传递所有参数
    bash "${MENU_PATH}" "$@"
    # 获取菜单脚本执行后的退出码 ($?)
    OPTION=$?
    # 返回菜单脚本的退出码
    return ${OPTION}
}

# =============================================================================
# 函数名称: exec_handler
# 功能描述: 执行处理器脚本 (handler.sh)。
# 参数:
#   $@: 传递给 handler.sh 脚本的参数
# 返回值: 无 (handler.sh 的退出码即为当前函数的退出码)
# =============================================================================

function exec_handler() {
    # 执行处理器脚本，并传递所有参数
    bash "${HANDLER_PATH}" "$@"
}

# =============================================================================
# 函数名称: choose_web_backend / install_protocol
# 功能描述: 选择可选的伪装站点，并通过统一顺序完成协议安装。
# =============================================================================

function choose_web_backend() {
    exec_menu '--web'
    local choose=$(echo $?)
    case ${choose} in
    1) echo 'normal' ;;
    2) echo 'v3' ;;
    3) echo 'v4' ;;
    *) return 1 ;;
    esac
}

function choose_cdn_backend() {
    exec_menu '--cdn-backend'
    local choose=$(echo $?)
    case ${choose} in
    1) echo 'nginx' ;;
    2) echo 'xray' ;;
    *) return 1 ;;
    esac
}

function restore_protocol_snapshot() {
    local snapshot="$1"
    local target="$2"
    local restore_file

    [[ -f "${snapshot}" ]] || return 0
    restore_file="$(mktemp "${target}.restore.XXXXXX")" || return 1
    if ! cp -p -- "${snapshot}" "${restore_file}" ||
        ! mv -f -- "${restore_file}" "${target}"; then
        rm -f -- "${restore_file}"
        return 1
    fi
}

function valid_nginx_artifact_domain() {
    local domain="$1"
    local domain_regex='^([a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$'

    # The domain is also a single filename component followed by ".conf".
    ((${#domain} <= 250)) && [[ "${domain}" =~ ${domain_regex} ]]
}

function nginx_artifact_relative_path_is_safe() {
    local relative_path="$1"
    local domain

    case "${relative_path}" in
    modules-enabled/stream.conf)
        return 0
        ;;
    sites-available/*.conf)
        domain="${relative_path#sites-available/}"
        domain="${domain%.conf}"
        [[ "${relative_path}" == "sites-available/${domain}.conf" ]] &&
            valid_nginx_artifact_domain "${domain}"
        ;;
    sites-enabled/*.conf)
        domain="${relative_path#sites-enabled/}"
        domain="${domain%.conf}"
        [[ "${relative_path}" == "sites-enabled/${domain}.conf" ]] &&
            valid_nginx_artifact_domain "${domain}"
        ;;
    *)
        return 1
        ;;
    esac
}

function collect_nginx_artifact_domains() {
    local config_file domain_output domain_json domain existing found
    local domains=()

    for config_file in "$@"; do
        [[ -r "${config_file}" ]] || return 1
        domain_output="$(jq -c '
            [
                (.nginx.domain // ""),
                (.nginx.cdn // "")
            ][]
        ' "${config_file}")" || return 1
        while IFS= read -r domain_json || [[ -n "${domain_json}" ]]; do
            [[ "${domain_json}" == '""' ]] && continue
            # Compact JSON keeps each config value on one manifest-input line.
            # A valid domain needs no JSON escapes and contains only this set.
            [[ "${domain_json}" =~ ^\"[a-zA-Z0-9.-]+\"$ ]] || return 1
            domain="${domain_json:1:${#domain_json}-2}"
            valid_nginx_artifact_domain "${domain}" || return 1
            found=0
            for existing in "${domains[@]}"; do
                if [[ "${existing}" == "${domain}" ]]; then
                    found=1
                    break
                fi
            done
            if [[ "${found}" -eq 0 ]]; then
                domains+=("${domain}")
                printf '%s\n' "${domain}"
            fi
        done <<<"${domain_output}"
    done
}

function snapshot_nginx_artifact_entry() {
    local journal_dir="$1"
    local relative_path="$2"
    local target_path payload_path state

    nginx_artifact_relative_path_is_safe "${relative_path}" || return 1
    target_path="${NGINX_CONFIG_DIR}/${relative_path}"
    payload_path="${journal_dir}/root/${relative_path}"

    if [[ -L "${target_path}" ]]; then
        state='symlink'
    elif [[ -f "${target_path}" ]]; then
        state='file'
    elif [[ -e "${target_path}" ]]; then
        return 1
    else
        state='missing'
    fi

    printf '%s\t%s\n' "${state}" "${relative_path}" \
        >>"${journal_dir}/manifest.tsv" || return 1
    if [[ "${state}" != 'missing' ]]; then
        mkdir -p -- "$(dirname -- "${payload_path}")" || return 1
        cp -a -- "${target_path}" "${payload_path}" || return 1
    fi
}

function restore_nginx_artifact_entry() {
    local journal_dir="$1"
    local state="$2"
    local relative_path="$3"
    local target_path payload_path restore_file

    nginx_artifact_relative_path_is_safe "${relative_path}" || return 1
    case "${state}" in
    missing | file | symlink) ;;
    *) return 1 ;;
    esac

    target_path="${NGINX_CONFIG_DIR}/${relative_path}"
    payload_path="${journal_dir}/root/${relative_path}"
    if [[ -e "${target_path}" || -L "${target_path}" ]]; then
        [[ -f "${target_path}" || -L "${target_path}" ]] || return 1
    fi

    if [[ "${state}" == 'missing' ]]; then
        if [[ -e "${target_path}" || -L "${target_path}" ]]; then
            rm -f -- "${target_path}" || return 1
        fi
        return 0
    fi

    if [[ "${state}" == 'file' ]]; then
        [[ -f "${payload_path}" && ! -L "${payload_path}" ]] || return 1
    else
        [[ -L "${payload_path}" ]] || return 1
    fi

    mkdir -p -- "$(dirname -- "${target_path}")" || return 1
    restore_file="$(mktemp "${target_path}.restore.XXXXXX")" || return 1
    if ! rm -f -- "${restore_file}" ||
        ! cp -a -- "${payload_path}" "${restore_file}"; then
        rm -f -- "${restore_file}"
        return 1
    fi
    if [[ -e "${target_path}" || -L "${target_path}" ]]; then
        rm -f -- "${target_path}" || {
            rm -f -- "${restore_file}"
            return 1
        }
    fi
    if ! mv -- "${restore_file}" "${target_path}"; then
        rm -f -- "${restore_file}"
        return 1
    fi
}

function restore_nginx_artifact_journal() {
    local journal_dir="$1"
    local state relative_path
    local restore_status=0

    [[ -d "${journal_dir}" && ! -L "${journal_dir}" &&
        -f "${journal_dir}/manifest.tsv" &&
        ! -L "${journal_dir}/manifest.tsv" ]] || return 1
    while IFS=$'\t' read -r state relative_path ||
        [[ -n "${state}" || -n "${relative_path}" ]]; do
        if ! restore_nginx_artifact_entry \
            "${journal_dir}" "${state}" "${relative_path}"; then
            restore_status=1
        fi
    done <"${journal_dir}/manifest.tsv"
    return "${restore_status}"
}

function cleanup_nginx_artifact_journal() {
    local journal_dir="$1"
    local state relative_path payload_path directory
    local cleanup_status=0

    [[ -n "${journal_dir}" ]] || return 0
    [[ -d "${journal_dir}" && ! -L "${journal_dir}" &&
        -f "${journal_dir}/manifest.tsv" &&
        ! -L "${journal_dir}/manifest.tsv" ]] || return 1

    while IFS=$'\t' read -r state relative_path ||
        [[ -n "${state}" || -n "${relative_path}" ]]; do
        if ! nginx_artifact_relative_path_is_safe "${relative_path}"; then
            cleanup_status=1
            continue
        fi
        case "${state}" in
        missing | file | symlink) ;;
        *)
            cleanup_status=1
            continue
            ;;
        esac
        payload_path="${journal_dir}/root/${relative_path}"
        if [[ -e "${payload_path}" || -L "${payload_path}" ]]; then
            if [[ -f "${payload_path}" || -L "${payload_path}" ]]; then
                rm -f -- "${payload_path}" || cleanup_status=1
            else
                cleanup_status=1
            fi
        fi
    done <"${journal_dir}/manifest.tsv"

    [[ "${cleanup_status}" -eq 0 ]] || return 1
    for directory in \
        "${journal_dir}/root/sites-available" \
        "${journal_dir}/root/sites-enabled" \
        "${journal_dir}/root/modules-enabled" \
        "${journal_dir}/root"; do
        if [[ -L "${directory}" ]]; then
            return 1
        fi
        if [[ -d "${directory}" ]] && ! rmdir -- "${directory}"; then
            return 1
        fi
    done
    rm -f -- "${journal_dir}/manifest.tsv" || return 1
    rmdir -- "${journal_dir}"
}

function create_nginx_artifact_journal() {
    local old_script_config="$1"
    local new_script_config="$2"
    local journal_dir domain_output domain

    journal_dir="$(mktemp -d "${SCRIPT_CONFIG_PATH}.nginx-journal.XXXXXX")" ||
        return 1
    if ! : >"${journal_dir}/manifest.tsv"; then
        rmdir -- "${journal_dir}" 2>/dev/null || true
        return 1
    fi
    if ! domain_output="$(
        collect_nginx_artifact_domains \
            "${old_script_config}" "${new_script_config}"
    )"; then
        cleanup_nginx_artifact_journal "${journal_dir}" >/dev/null 2>&1 || true
        return 1
    fi

    while IFS= read -r domain || [[ -n "${domain}" ]]; do
        [[ -n "${domain}" ]] || continue
        if ! snapshot_nginx_artifact_entry \
                "${journal_dir}" "sites-available/${domain}.conf" ||
            ! snapshot_nginx_artifact_entry \
                "${journal_dir}" "sites-enabled/${domain}.conf"; then
            cleanup_nginx_artifact_journal "${journal_dir}" >/dev/null 2>&1 || true
            return 1
        fi
    done <<<"${domain_output}"
    if ! snapshot_nginx_artifact_entry \
        "${journal_dir}" 'modules-enabled/stream.conf'; then
        cleanup_nginx_artifact_journal "${journal_dir}" >/dev/null 2>&1 || true
        return 1
    fi
    printf '%s\n' "${journal_dir}"
}

function is_hy2_ip_cron_identifier() {
    local identifier="$1"
    local ipv4_regex='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    local ipv6_regex='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$'

    [[ "${identifier}" =~ ${ipv4_regex} || "${identifier}" =~ ${ipv6_regex} ]]
}

function is_managed_hy2_ip_cron_line() {
    local line="$1"
    local legacy_prefix="17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d "
    local legacy_suffix=" --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1"
    local identifier

    if [[ "${line}" == *'# xray-script-hy2-ip-renew'* ]]; then
        return 0
    fi
    [[ "${line}" == "${legacy_prefix}"*"${legacy_suffix}" ]] || return 1
    identifier="${line#"${legacy_prefix}"}"
    identifier="${identifier%"${legacy_suffix}"}"
    [[ "${line}" == "${legacy_prefix}${identifier}${legacy_suffix}" ]] ||
        return 1
    is_hy2_ip_cron_identifier "${identifier}"
}

function read_protocol_crontab() {
    local target="$1"
    local error_file error_text status
    local no_crontab_regex='^[[:space:]]*(crontab:[[:space:]]*)?no[[:space:]]+crontab([[:space:]]+for[[:space:]]+[^[:space:]]+)?[[:space:]]*$'

    CRONTAB_READ_STATE='error'
    error_file="$(mktemp "${target}.error.XXXXXX")" || return 1
    if crontab -l >"${target}" 2>"${error_file}"; then
        CRONTAB_READ_STATE='present'
        rm -f -- "${error_file}"
        return 0
    else
        status=$?
    fi

    error_text="$(<"${error_file}")"
    if [[ "${status}" -eq 1 && "${error_text}" =~ ${no_crontab_regex} ]]; then
        : >"${target}"
        CRONTAB_READ_STATE='absent'
        rm -f -- "${error_file}"
        return 0
    fi

    cat "${error_file}" >&2
    rm -f -- "${error_file}"
    return 1
}

function protocol_config_file_uses_hy2() {
    local config_file="$1"

    [[ -f "${config_file}" ]] || return 1
    jq -e '
        (.xray.tag // "" | ascii_downcase) as $tag |
        ($tag == "hy2") or
        (
            $tag == "multi" and
            any(.xray.nodes[]?; (.tag // "" | ascii_downcase) == "hy2")
        )
    ' "${config_file}" >/dev/null 2>&1
}

function snapshot_managed_hy2_ip_cron() {
    local current_crontab="$1"
    local snapshot="$2"
    local line

    : >"${snapshot}" || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if is_managed_hy2_ip_cron_line "${line}"; then
            printf '%s\n' "${line}" >>"${snapshot}" || return 1
        fi
    done <"${current_crontab}"
}

function restore_managed_hy2_ip_cron() {
    local snapshot="$1"
    local snapshot_state="$2"
    local current_crontab rendered_crontab current_state line
    local restore_status=0

    [[ -f "${snapshot}" ]] || return 0
    case "${snapshot_state}" in
    present | absent) ;;
    *) return 1 ;;
    esac

    current_crontab="$(mktemp "${SCRIPT_CONFIG_PATH}.cron-current.XXXXXX")" ||
        return 1
    rendered_crontab="$(mktemp "${SCRIPT_CONFIG_PATH}.cron-restore.XXXXXX")" || {
        rm -f -- "${current_crontab}"
        return 1
    }
    if ! read_protocol_crontab "${current_crontab}"; then
        rm -f -- "${current_crontab}" "${rendered_crontab}"
        return 1
    fi
    current_state="${CRONTAB_READ_STATE}"
    : >"${rendered_crontab}"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if ! is_managed_hy2_ip_cron_line "${line}"; then
            printf '%s\n' "${line}" >>"${rendered_crontab}" || {
                restore_status=1
                break
            }
        fi
    done <"${current_crontab}"
    if [[ "${restore_status}" -eq 0 ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            printf '%s\n' "${line}" >>"${rendered_crontab}" || {
                restore_status=1
                break
            }
        done <"${snapshot}"
    fi

    if [[ "${restore_status}" -eq 0 ]]; then
        if [[ "${snapshot_state}" == 'absent' && ! -s "${rendered_crontab}" ]]; then
            if [[ "${current_state}" != 'absent' ]]; then
                crontab -r >/dev/null 2>&1 || restore_status=1
            fi
        else
            crontab "${rendered_crontab}" >/dev/null 2>&1 ||
                restore_status=1
        fi
    fi
    rm -f -- "${current_crontab}" "${rendered_crontab}"
    return "${restore_status}"
}

function rollback_protocol_install() {
    local script_snapshot="$1"
    local runtime_snapshot="${2:-}"
    local cron_snapshot="${3:-}"
    local cron_snapshot_state="${4:-unavailable}"
    local nginx_artifact_journal="${5:-}"
    local rollback_status=0
    local nginx_artifacts_restored=1
    local first_install_runtime_retained=0
    local script_snapshot_restored=1
    local runtime_snapshot_restored=1
    local cron_snapshot_restored=1

    if ! restore_protocol_snapshot "${script_snapshot}" "${SCRIPT_CONFIG_PATH}"; then
        rollback_status=1
        script_snapshot_restored=0
    fi
    if [[ -n "${runtime_snapshot}" ]]; then
        if ! restore_protocol_snapshot "${runtime_snapshot}" "${XRAY_RUNTIME_CONFIG_PATH}"; then
            rollback_status=1
            runtime_snapshot_restored=0
        fi
    fi
    if [[ -n "${nginx_artifact_journal}" ]]; then
        if ! restore_nginx_artifact_journal "${nginx_artifact_journal}"; then
            rollback_status=1
            nginx_artifacts_restored=0
        fi
    fi
    if [[ -n "${runtime_snapshot}" ]]; then
        exec_handler '--recover-runtime' >/dev/null 2>&1 ||
            rollback_status=1
    elif [[ -e "${XRAY_RUNTIME_CONFIG_PATH}" ]]; then
        # A first installation has no runtime snapshot to restore. Stop any
        # process that may have loaded the failed config, then remove only the
        # exact runtime file created by this attempt.
        if ! exec_handler '--stop' >/dev/null 2>&1; then
            rollback_status=1
            first_install_runtime_retained=1
        elif ! rm -f -- "${XRAY_RUNTIME_CONFIG_PATH}"; then
            rollback_status=1
            first_install_runtime_retained=1
        fi
    fi
    if [[ -n "${cron_snapshot}" && "${cron_snapshot_state}" != 'unavailable' ]]; then
        if ! restore_managed_hy2_ip_cron "${cron_snapshot}" "${cron_snapshot_state}"; then
            rollback_status=1
            cron_snapshot_restored=0
        fi
    fi
    if [[ -n "${nginx_artifact_journal}" &&
        "${nginx_artifacts_restored}" -eq 1 ]]; then
        cleanup_nginx_artifact_journal "${nginx_artifact_journal}" ||
            rollback_status=1
    fi
    if [[ "${script_snapshot_restored}" -eq 1 ]]; then
        rm -f -- "${script_snapshot}"
    fi
    if [[ -n "${runtime_snapshot}" && "${runtime_snapshot_restored}" -eq 1 ]]; then
        rm -f -- "${runtime_snapshot}"
    fi
    if [[ -n "${cron_snapshot}" && "${cron_snapshot_restored}" -eq 1 ]]; then
        rm -f -- "${cron_snapshot}"
    fi
    if [[ "${rollback_status}" -ne 0 ]]; then
        echo -e "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')]${NC} $(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.rollback_fail")" >&2
        [[ "${script_snapshot_restored}" -eq 1 ]] ||
            printf 'Script config recovery copy retained at: %s\n' "${script_snapshot}" >&2
        [[ -z "${runtime_snapshot}" || "${runtime_snapshot_restored}" -eq 1 ]] ||
            printf 'Xray runtime recovery copy retained at: %s\n' "${runtime_snapshot}" >&2
        [[ -z "${cron_snapshot}" || "${cron_snapshot_restored}" -eq 1 ]] ||
            printf 'Cron recovery copy retained at: %s\n' "${cron_snapshot}" >&2
        [[ -z "${nginx_artifact_journal}" || "${nginx_artifacts_restored}" -eq 1 ]] ||
            printf 'Nginx recovery journal retained at: %s\n' "${nginx_artifact_journal}" >&2
        [[ "${first_install_runtime_retained}" -eq 0 ]] ||
            printf 'Failed runtime retained because Xray could not be stopped: %s\n' "${XRAY_RUNTIME_CONFIG_PATH}" >&2
    fi
    return "${rollback_status}"
}

function install_protocol() (
    local config_tag script_snapshot='' runtime_snapshot=''
    local cron_snapshot='' cron_snapshot_state='unavailable' cron_current=''
    local nginx_artifact_journal=''
    local install_lock_fd=''
    local mutation_started=0
    local rollback_started=0
    local transaction_committed=0

    function rollback_current_protocol_install() {
        [[ "${rollback_started}" -eq 0 ]] || return 0
        rollback_started=1
        rollback_protocol_install \
            "${script_snapshot}" "${runtime_snapshot}" \
            "${cron_snapshot}" "${cron_snapshot_state}" \
            "${nginx_artifact_journal}"
    }

    function finish_protocol_install_transaction() {
        local status="$1"

        trap - EXIT HUP INT TERM
        if [[ "${transaction_committed}" -eq 0 ]]; then
            if [[ "${mutation_started}" -eq 1 ]]; then
                rollback_current_protocol_install || status=1
            else
                rm -f -- \
                    "${script_snapshot}" "${runtime_snapshot}" \
                    "${cron_snapshot}" "${cron_current}"
                if [[ -n "${nginx_artifact_journal}" ]]; then
                    cleanup_nginx_artifact_journal \
                        "${nginx_artifact_journal}" >/dev/null 2>&1 || true
                fi
            fi
        fi
        exit "${status}"
    }

    trap 'finish_protocol_install_transaction "$?"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    config_tag="$(protocol_template_tag "$1")" || return 1
    command -v flock >/dev/null 2>&1 || return 1
    exec {install_lock_fd}>"${SCRIPT_CONFIG_PATH}.lock" || return 1
    if ! flock -n "${install_lock_fd}"; then
        echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')]${NC} $(echo "$I18N_DATA" | jq -r '.main.install_busy')" >&2
        return 1
    fi

    script_snapshot="$(mktemp "${SCRIPT_CONFIG_PATH}.install.XXXXXX")" || return 1
    if ! cp -p -- "${SCRIPT_CONFIG_PATH}" "${script_snapshot}"; then
        rm -f -- "${script_snapshot}"
        return 1
    fi
    if [[ -f "${XRAY_RUNTIME_CONFIG_PATH}" ]]; then
        runtime_snapshot="$(mktemp "${XRAY_RUNTIME_CONFIG_PATH}.install.XXXXXX")" || {
            rm -f -- "${script_snapshot}"
            return 1
        }
        if ! cp -p -- "${XRAY_RUNTIME_CONFIG_PATH}" "${runtime_snapshot}"; then
            rm -f -- "${script_snapshot}" "${runtime_snapshot}"
            return 1
        fi
    fi
    # The old configuration matters too: changing from HY2/IP to another
    # protocol removes the managed renewal line during restart. Snapshot it so
    # a later service failure can restore the old, still-active deployment.
    if command -v crontab >/dev/null 2>&1 &&
        {
            [[ "${config_tag,,}" =~ ^(hy2|multi)$ ]] ||
                protocol_config_file_uses_hy2 "${script_snapshot}"
        }; then
        cron_snapshot="$(mktemp "${SCRIPT_CONFIG_PATH}.cron.XXXXXX")" || {
            rm -f -- "${script_snapshot}" "${runtime_snapshot}"
            return 1
        }
        cron_current="$(mktemp "${SCRIPT_CONFIG_PATH}.cron-current.XXXXXX")" || {
            rm -f -- "${script_snapshot}" "${runtime_snapshot}" "${cron_snapshot}"
            return 1
        }
        if ! read_protocol_crontab "${cron_current}"; then
            rm -f -- \
                "${script_snapshot}" "${runtime_snapshot}" \
                "${cron_snapshot}" "${cron_current}"
            return 1
        fi
        cron_snapshot_state="${CRONTAB_READ_STATE}"
        if ! snapshot_managed_hy2_ip_cron "${cron_current}" "${cron_snapshot}"; then
            rm -f -- \
                "${script_snapshot}" "${runtime_snapshot}" \
                "${cron_snapshot}" "${cron_current}"
            return 1
        fi
        rm -f -- "${cron_current}"
        cron_current=''
    fi

    mutation_started=1
    if ! exec_handler '--script-config' "${config_tag}"; then
        return 1
    fi

    local cdn_backend=''
    if [[ "${config_tag,,}" == 'cdn' ]]; then
        if ! cdn_backend="$(choose_cdn_backend)"; then
            return 1
        fi
    fi

    if ! nginx_artifact_journal="$(
        create_nginx_artifact_journal \
            "${script_snapshot}" "${SCRIPT_CONFIG_PATH}"
    )"; then
        return 1
    fi

    if ! exec_handler '--install'; then
        return 1
    fi
    if [[ "${config_tag,,}" == 'cdn' ]]; then
        if ! exec_handler '--cdn-backend' "${cdn_backend}"; then
            return 1
        fi
    fi

    local web=''
    if protocol_uses_nginx "${config_tag}" "${cdn_backend}"; then
        if ! web="$(choose_web_backend)"; then
            return 1
        fi
        if ! exec_handler '--nginx-install'; then
            return 1
        fi
    fi

    if ! exec_handler '--xray-config' "${web}"; then
        return 1
    fi
    if ! exec_handler '--restart'; then
        return 1
    fi

    # The new runtime is healthy: from here on, cleanup/share failures are
    # post-commit warnings and must never roll back a working installation.
    transaction_committed=1
    if ! cleanup_nginx_artifact_journal "${nginx_artifact_journal}"; then
        echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')]${NC} $(echo "$I18N_DATA" | jq -r '.main.post_install_cleanup_fail') ${nginx_artifact_journal}" >&2
    else
        nginx_artifact_journal=''
    fi
    rm -f -- "${script_snapshot}" "${runtime_snapshot}" "${cron_snapshot}" ||
        true
    if ! exec_handler '--share'; then
        echo -e "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')]${NC} $(echo "$I18N_DATA" | jq -r '.main.share_after_install_fail')" >&2
    fi
    return 0
)

# =============================================================================
# 函数名称: processes_xray_config
# 功能描述: 处理 Xray 配置相关的流程。
#           1. 显示 Xray 配置菜单。
#           2. 使用集中映射把菜单选项转换为协议标签。
#           3. 所有协议进入同一个安装流程，CDN/SNI 的差异由能力表处理。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_xray_config() {
    # 显示 Xray 配置菜单
    exec_menu '--config'
    # 获取菜单选择的退出码 (代表用户选择)
    local choose=$(echo $?)
    local XTLS_CONFIG
    XTLS_CONFIG="$(protocol_from_menu_choice "${choose}")" || return 0
    install_protocol "${XTLS_CONFIG}"
}

# =============================================================================
# 函数名称: processes_xray
# 功能描述: 处理 Xray 安装相关的流程。
#           1. 显示 Xray 安装菜单。
#           2. 根据用户选择确定 Xray 版本 (release, latest, custom)。
#           3. 根据 is_exec 参数决定是立即安装还是设置版本后进入配置流程。
# 参数:
#   $1: is_exec - 控制流程模式。'y' 表示立即执行安装；
#                 'n' 表示仅设置版本，然后进入 Xray 配置流程。
#                 默认为 'y'。
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_xray() {
    local is_exec="${1:-y}" # 获取 is_exec 参数，默认为 'y'
    local version='release' # 初始化 Xray 版本为 'release'
    # 显示 Xray 安装菜单
    exec_menu '--xray'
    # 获取菜单选择的退出码 (代表用户选择)
    local choose=$(echo $?)
    # 根据用户选择设置具体的 Xray 版本
    case ${choose} in
    0) return 0 ;;          # 显式取消
    1) version='latest' ;;  # 选择 1 对应 latest
    2) version='release' ;; # 选择 2 对应 release
    3) version='custom' ;;  # 选择 3 对应 custom
    *) return 1 ;;
    esac
    # 如果 is_exec 为 'y'，则立即执行安装
    if [[ "${is_exec}" == 'y' ]]; then
        exec_handler '--install' "${version}" 'y' # 安装指定版本的 Xray
    else
        # 如果 is_exec 为 'n'，则仅设置版本，然后进入配置流程
        exec_handler '--version' "${version}" # 设置 Xray 版本
        processes_xray_config                 # 进入 Xray 配置流程
    fi
}

# =============================================================================
# 函数名称: processes_full_installation
# 功能描述: 进入协议选择并执行完整安装，不再增加额外的一键/自定义嵌套菜单。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_full_installation() {
    processes_xray_config
}

# =============================================================================
# 函数名称: processes_routing
# 功能描述: 处理路由规则配置相关的流程。
#           1. 显示路由规则菜单。
#           2. 根据用户选择执行不同的路由配置操作 (WARP, Block IP/Domain, WARP IP/Domain)。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_routing() {
    # 显示路由规则菜单
    exec_menu '--route'
    # 获取菜单选择的退出码 (代表用户选择)
    local choose=$(echo $?)
    # 根据用户选择执行不同的路由配置操作
    case ${choose} in
    1) exec_handler '--warp' ;;                     # 选择 1：配置 WARP
    2) exec_handler '--reset-warp' ;;               # 选择 2：重置 WARP
    3) exec_handler '--routing' 'block' 'ip' ;;     # 选择 3：配置阻止 IP 规则
    4) exec_handler '--routing' 'block' 'domain' ;; # 选择 4：配置阻止 Domain 规则
    5) exec_handler '--routing' 'warp' 'ip' ;;      # 选择 5：配置 WARP IP 规则
    6) exec_handler '--routing' 'warp' 'domain' ;;  # 选择 6：配置 WARP Domain 规则
    *) exit 0 ;;                                    # 其他情况：退出脚本
    esac
    exec_handler '--restart' # 重启 Xray 服务
}

# =============================================================================
# 函数名称: processes_web_mode_config
# 功能描述: 根据当前模式显示互不混用的 CDN 或 SNI 站点管理菜单。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# 退出码: 当前配置不是 CDN/SNI 时调用 _error 退出脚本 (exit 1)
# =============================================================================

function change_web_backend() {
    local web
    web="$(choose_web_backend)" || return 1
    exec_handler '--web' "${web}"
}

function processes_web_mode_config() {
    # 从配置文件中读取当前 Xray 的 tag
    local tag="$(jq -r '.xray.tag' "${SCRIPT_CONFIG_PATH}")"
    local cdn_backend
    cdn_backend="$(normalize_cdn_backend "$(jq -r '.xray.cdnBackend // ""' "${SCRIPT_CONFIG_PATH}")")"
    case "${tag,,}" in
    sni) exec_menu '--sni' ;;
    cdn)
        if [[ "${cdn_backend}" == 'xray' ]]; then
            exec_menu '--cdn-direct-config'
        else
            exec_menu '--cdn-config'
        fi
        ;;
    *) _error "$(echo "$I18N_DATA" | jq -r ".${CUR_FILE}.not_support")" ;;
    esac
    # 获取菜单选择的退出码 (代表用户选择)
    local choose=$(echo $?)
    if [[ "${tag,,}" == 'sni' ]]; then
        case ${choose} in
        1) exec_handler '--change-domain' 'domain' ;;
        2) exec_handler '--change-domain' 'cdn' ;;
        3) exec_handler '--renew-certificate' ;;
        4) exec_handler '--nginx-update' ;;
        5) exec_handler '--nginx-cron' ;;
        6) change_web_backend ;;
        7) exec_handler '--v3-reset' ;;
        *) exit 0 ;;
        esac
    elif [[ "${cdn_backend}" == 'nginx' ]]; then
        case ${choose} in
        1) exec_handler '--change-domain' 'cdn' ;;
        2) exec_handler '--renew-certificate' ;;
        3) exec_handler '--nginx-update' ;;
        4) exec_handler '--nginx-cron' ;;
        5) change_web_backend ;;
        6) exec_handler '--v3-reset' ;;
        *) exit 0 ;;
        esac
    else
        case ${choose} in
        1) install_protocol 'CDN' ;;
        2) exec_handler '--renew-certificate' ;;
        *) exit 0 ;;
        esac
    fi
}

# =============================================================================
# 函数名称: processes_language
# 功能描述: 处理语言设置相关的流程。
#           1. 显示语言设置菜单。
#           2. 根据用户选择设置不同的语言（zh: 中文，en: 英语）。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_language() {
    # 显示语言设置菜单
    exec_menu '--language'
    # 获取菜单选择的退出码 (代表用户选择)
    local choose=$(echo $?)
    # 根据用户选择设置不同的语言
    case ${choose} in
    2) LANG_PARAM="en" ;; # 选择英文
    *) LANG_PARAM="zh" ;; # 默认中文
    esac
    # 更新配置文件中的语言设置
    backup_config "${SCRIPT_CONFIG_PATH}"
    SCRIPT_CONFIG="$(jq --arg language "${LANG_PARAM}" '.language = $language' "${SCRIPT_CONFIG_PATH}")"
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
    bash "${CUR_DIR}/${CUR_FILE}.sh" && exit 0
}

# =============================================================================
# 函数名称: processes_config
# 功能描述: 处理主配置管理相关的流程。
#           1. 显示主配置管理菜单。
#           2. 根据用户选择进入不同的子流程 (Xray 配置, 路由规则, SNI 配置, GeoData Cron)。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

# =============================================================================
# 函数名称: processes_reverse
# 功能描述: 处理反向代理配置流程。
# 参数: 无
# 返回值: 无
# =============================================================================
function processes_reverse() {
    exec_menu '--reverse'
    local choose=$(echo $?)
    case ${choose} in
    1 | 2)
        exec_handler '--reverse'
        exec_handler '--restart'
        ;;
    3)
        exec_handler '--reverse-share'
        ;;
    *) exit 0 ;;
    esac
}

function processes_lan() {
    exec_menu '--lan'
    local choose=$(echo $?)
    case ${choose} in
    1)
        exec_handler '--lan-enable' || return 1
        exec_handler '--restart'
        ;;
    2)
        exec_handler '--lan-add' || return 1
        exec_handler '--restart'
        ;;
    3)
        exec_handler '--lan-remove' || return 1
        exec_handler '--restart'
        ;;
    4) exec_handler '--lan-list' ;;
    5) exec_handler '--lan-export' ;;
    6)
        exec_handler '--lan-disable' || return 1
        exec_handler '--restart'
        ;;
    *) exit 0 ;;
    esac
}

function processes_config() {
    # 显示主配置管理菜单
    exec_menu '--management'
    # 获取菜单选择的退出码 (代表用户选择)
    local choose=$(echo $?)
    # 根据用户选择进入不同的子流程
    case ${choose} in
    1) processes_xray_config ;;         # 选择 1：进入 Xray 配置流程
    2) processes_routing ;;             # 选择 2：进入路由规则配置流程
    3) processes_web_mode_config ;;     # 选择 3：进入 CDN/SNI 配置流程
    4) exec_handler '--change-port' ;;  # 选择 4：修改 Xray 端口
    5) exec_handler '--geodata-cron' ;; # 选择 5：配置 GeoData Cron 任务
    6) processes_language ;;            # 选择 6：设置语言
    7) processes_reverse ;;             # 选择 7：配置反向代理
    8) processes_lan ;;                 # 选择 8：配置异地组网
    *) exit 0 ;;                        # 其他情况：退出脚本
    esac
}

# =============================================================================
# 函数名称: processes_index
# 功能描述: 处理脚本主界面的流程。
#           1. 显示 Banner、状态和主菜单。
#           2. 根据用户选择执行不同的主操作 (一键安装, Xray 安装, 卸载, 启动, 停止, 重启, 分享链接, 流量统计, 配置管理)。
# 参数: 无
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function processes_index() {
    # 显示 Banner
    exec_menu '--banner'
    # 显示状态信息
    exec_menu '--status'
    # 显示主菜单
    exec_menu '--index'
    # 获取菜单选择的退出码 (代表用户选择)
    local choose=$(echo $?)
    # 根据用户选择执行不同的主操作
    case ${choose} in
    1) processes_full_installation ;; # 选择 1：选择协议并执行完整安装
    2) processes_xray ;;              # 选择 2：进入 Xray 安装流程
    3) exec_handler '--purge' ;;      # 选择 3：卸载
    4) exec_handler '--start' ;;      # 选择 4：启动服务
    5) exec_handler '--stop' ;;       # 选择 5：停止服务
    6) exec_handler '--restart' ;;    # 选择 6：重启服务
    7) exec_handler '--share' ;;      # 选择 7：显示分享链接
    8) exec_handler '--traffic' ;;    # 选择 8：显示流量统计
    9) processes_config ;;            # 选择 9：进入配置管理流程
    *) exit 0 ;;                      # 其他情况：退出脚本
    esac
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 检查传入的第一个参数 ($1)。
#           3. 协议快捷参数直接进入同一个完整安装流程。
#           4. 否则，进入主索引流程 (processes_index)。
# 参数:
#   $1: 命令行选项 (例如 --vision, --hy2, --cdn, --sni)
#   $2: 传递给 processes_index 的第二个参数 (如果主流程被调用)
# 返回值: 无 (通过调用其他函数和脚本执行操作)
# =============================================================================

function main() {
    # 加载国际化数据
    load_i18n
    # 将第一个参数转换为小写进行匹配
    case "${1,,}" in
    --vision) install_protocol 'Vision' ;;
    --xhttp) install_protocol 'XHTTP' ;;
    --fallback) install_protocol 'Fallback' ;;
    --hy2) install_protocol 'hy2' ;;
    --cdn) install_protocol 'CDN' ;;
    --sni) install_protocol 'SNI' ;;
    --ss2022) install_protocol 'ss2022' ;;
    --mkcp) install_protocol 'mKCP' ;;
    --trojan) install_protocol 'Trojan' ;;
    --multi) install_protocol 'multi' ;;
    --lan) processes_lan ;;
    # 对于其他参数，进入主索引流程，并将第二个参数传递给它
    *) processes_index "$2" ;;
    esac
}

# --- 脚本执行入口 ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
