#!/usr/bin/env bash
# =============================================================================
# 注释: 通过 Qwen3-Coder 生成。
# 脚本名称: install.sh
# 脚本仓库: https://github.com/zxcvos/Xray-script
# 功能描述: Xray-script 项目的安装引导脚本。
#           负责检查和安装系统依赖、下载项目文件、处理命令行参数、
#           初始化配置、设置语言以及启动主菜单。
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash, curl, wget, git, jq, sed, awk, grep
# 配置:
#   - 从 GitHub 下载项目文件到指定目录
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取/设置语言和版本信息
# Xray 官方链接:
#   - Xray-core: https://github.com/XTLS/Xray-core
#   - REALITY: https://github.com/XTLS/REALITY
#   - XHTTP: https://github.com/XTLS/Xray-core/discussions/4113
# Xray 配置模板:
#   - Xray 配置示例: https://github.com/chika0801/Xray-examples
#   - 最优组合示例: https://github.com/lxhao61/integrated-examples
#   - xhttp 五合一配置: https://github.com/XTLS/Xray-core/discussions/4118
#
# Copyright (C) 2025 zxcvos
# =============================================================================

# set -Eeuxo pipefail

# --- 环境与常量设置 ---
PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:${HOME}/bin:/snap/bin:${PATH:-}"
export PATH

# 获取当前脚本的目录绝对路径和文件名
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly CUR_FILE="$(basename "${BASH_SOURCE[0]}")"

# 定义配置文件和相关目录的路径
readonly SCRIPT_CONFIG_DIR="${HOME}/.xray-script"
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json"

# GitHub 仓库设置
readonly SCRIPT_REPO_OWNER="haiyan1301"
readonly SCRIPT_REPO_NAME="Xray-script"
readonly SCRIPT_VERSION="v2026.08.17"

# --- 引入公共库 ---
# install.sh 可能在项目下载之前运行，因此需要内联后备函数
if [[ -f "${CUR_DIR}/lib/common.sh" ]]; then
    source "${CUR_DIR}/lib/common.sh"
else
    # 内联最小公共函数集（项目尚未下载时使用）
    readonly GREEN='\033[32m'
    readonly YELLOW='\033[33m'
    readonly RED='\033[31m'
    readonly NC='\033[0m'
    function cmd_exists() { command -v "$1" >/dev/null 2>&1; }
    function _os() {
        local os=""
        if [[ -f "/etc/debian_version" ]]; then
            source /etc/os-release && os="${ID}"
            printf -- "%s" "${os}" && return
        fi
        if [[ -f "/etc/redhat-release" ]]; then
            printf -- "centos" && return
        fi
    }
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
    function _os_ver() {
        local main_ver="$(echo $(_os_full) | grep -oE "[0-9.]+")"
        printf -- "%s" "${main_ver%%.*}"
    }
    function write_config() {
        local content="$1"
        local target="$2"
        local temp_file
        if [[ -z "${content}" ]] || ! printf '%s\n' "${content}" | jq empty 2>/dev/null; then
            echo -e "${RED}[错误]${NC} 拒绝写入空内容到 $2" >&2
            return 1
        fi
        temp_file="$(mktemp "${target}.tmp.XXXXXX")" || return 1
        if ! printf '%s\n' "${content}" >"${temp_file}"; then
            rm -f -- "${temp_file}"
            return 1
        fi
        chmod 600 "${temp_file}" || {
            rm -f -- "${temp_file}"
            return 1
        }
        mv -f -- "${temp_file}" "${target}" || {
            rm -f -- "${temp_file}"
            return 1
        }
        sync
    }
    function backup_config() {
        [[ -f "$1" ]] && cp -f "$1" "$1.bak.$(date +%Y%m%d_%H%M%S)"
    }
fi

# --- 全局变量声明 ---
declare -A I18N_DATA=(
    ['error']='错误'
    ['root']='请使用 root 权限运行该脚本'
    ['supported']='不支持当前系统，请切换到 Ubuntu 16+、Debian 9+、CentOS 7+'
    ['ubuntu']='不支持当前版本，请切换到 Ubuntu 16+ 重试'
    ['debian']='不支持当前版本，请切换到 Debian 9+ 重试'
    ['centos']='不支持当前版本，请切换到 CentOS 7+ 重试'
    ['tip']='更新提示'
    ['new']='发现有新脚本, 是否更新'
    ['now']='是否更新 [Y/n] '
    ['promptly']='请及时更新脚本'
    ['completed']='更新完成'
    ['download']='正在下载'
    ['failed']='下载失败'
    ['downloaded']='文件已下载到'
    ['path_invalid']='安装目录必须是安全的绝对路径，且不能是系统根目录'
    ['path_fallback']='保存的安装目录无效，已回退到 /usr/local/xray-script'
    ['language_invalid']='语言只允许 zh、en 或 auto'
    ['option_invalid']='未知选项'
)
declare PROJECT_ROOT=''
declare I18N_DIR=''
declare CORE_DIR=''
declare SERVICE_DIR=''
declare CONFIG_DIR=''
declare TOOL_DIR=''
declare QUICK_INSTALL=''
declare SCRIPT_CONFIG=''
declare LANG_PARAM=''

# =============================================================================
# 函数名称: show_help
# 功能描述: 显示脚本帮助信息。
# =============================================================================
function show_help() {
    cat <<EOF
用法: bash $0 [选项]

选项:
  --vision       安装 Vision + REALITY
  --xhttp        安装 XHTTP + REALITY
  --trojan       安装 Trojan + XHTTP + REALITY
  --fallback     安装 Vision 回落 XHTTP
  --hy2          安装 Hysteria2
  --ss2022       安装 Shadowsocks 2022
  --mkcp         安装 mKCP
  --cdn          安装 CDN 独立模式
  --sni          安装 SNI 复合模式
  --multi        安装多节点组合配置
  --lan          管理异地组网
  --lang=<code>  设置语言 (zh/en/auto)
  -d <path>      自定义安装目录
  --help         显示此帮助信息
  --version      显示版本号

示例:
  bash $0                    # 启动交互式菜单
  bash $0 --vision           # 安装 Vision
  bash $0 --hy2              # 安装 Hysteria2
  bash $0 --cdn              # 安装纯 CDN 模式
  bash $0 --multi            # 生成多个节点
  bash $0 --lan              # 管理异地组网
  bash $0 --lang=en          # 使用英文界面
  bash $0 -d /opt/xray       # 安装到自定义目录
EOF
    exit 0
}

# =============================================================================
# 函数名称: parse_args
# 功能描述: 解析命令行参数。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (直接修改全局变量 QUICK_INSTALL, PROJECT_ROOT, LANG_PARAM)
# =============================================================================
function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --vision | --xhttp | --trojan | --fallback | --hy2 | --ss2022 | --mkcp | --cdn | --sni | --multi | --lan)
            QUICK_INSTALL="$1"
            ;;
        --lang=*)
            case "${1#*=}" in
            zh | en | auto) LANG_PARAM="${1}" ;;
            *) _error "${I18N_DATA['language_invalid']}: ${1#*=}" ;;
            esac
            ;;
        -d)
            if [[ $# -lt 2 || -z "${2:-}" || "${2}" == -* ]]; then
                _error "${I18N_DATA['path_invalid']}"
            fi
            PROJECT_ROOT="$2"
            shift
            ;;
        --help)
            show_help
            ;;
        --version)
            echo "Xray-script ${SCRIPT_VERSION}"
            exit 0
            ;;
        *)
            _error "${I18N_DATA['option_invalid']}: $1"
            ;;
        esac
        shift
    done
}

# =============================================================================
# 函数名称: load_i18n
# 功能描述: 加载国际化 (i18n) 数据。
# 参数: 无
# 返回值: 无 (直接修改全局变量 I18N_DATA)
# =============================================================================
function load_i18n() {
    local lang="${LANG_PARAM#*=}" # 从 LANG_PARAM 中提取语言代码

    # 如果存在脚本配置文件，则尝试从文件中获取语言代码
    if [[ -z "${lang}" && -f "${SCRIPT_CONFIG_PATH}" ]]; then
        # 尝试从脚本配置文件中获取语言代码
        lang="$(jq -r '.language // ""' "${SCRIPT_CONFIG_PATH}")"
    fi

    # 如果语言设置为 "auto"，则使用系统环境变量 LANG 的第一部分作为语言代码
    if [[ "$lang" == "auto" ]]; then
        lang="${LANG:-}"
        lang="${lang%%.*}"
        lang="${lang%%_*}"
        [[ "${lang,,}" == 'zh' ]] && lang='zh' || lang='en'
    fi

    # 如果语言设置为 "en"，则加载英文提示信息
    if [[ "$lang" == "en" ]]; then
        I18N_DATA=(
            ['error']='Error'
            ['root']='This script must be run as root'
            ['supported']='Not supported OS'
            ['ubuntu']='Not supported OS, please change to Ubuntu 18+ and try again.'
            ['debian']='Not supported OS, please change to Debian 9+ and try again.'
            ['centos']='Not supported OS, please change to CentOS 7+ and try again.'
            ['tip']='Update Notice'
            ['new']='A new version of the script is available. Do you want to update?'
            ['now']='Update now? [Y/n]'
            ['promptly']='Please update the script promptly.'
            ['completed']='Update completed'
            ['download']='Downloading'
            ['failed']='Download failed'
            ['downloaded']='The file has been downloaded to'
            ['path_invalid']='The install directory must be a safe absolute path and not a system root directory'
            ['path_fallback']='The saved install directory is invalid; using /usr/local/xray-script'
            ['language_invalid']='Language must be zh, en, or auto'
            ['option_invalid']='Unknown option'
        )
    fi
}

# =============================================================================
# 函数名称: _error
# 功能描述: 以红色打印错误信息并退出脚本。
# 参数:
#   $@: 错误消息内容
# 返回值: 无 (直接打印到标准错误输出 >&2，然后 exit 1)
# =============================================================================
function _error() {
    # 用红色打印错误标题
    printf "${RED}[${I18N_DATA['error']}] ${NC}"
    # 打印传入的错误消息
    printf -- "%s" "$@"
    # 打印换行符
    printf "\n"
    # 退出脚本，错误码为 1
    exit 1
}

# =============================================================================
# 函数名称: check_os
# 功能描述: 检查操作系统是否受支持。
# 参数: 无
# 返回值: 无 (如果不支持则调用 _error 退出)
# =============================================================================
function check_os() {
    # 检查操作系统类型和版本
    case "$(_os)" in
    # CentOS 系列
    centos)
        # 检查版本号是否大于等于 7
        if [[ "$(_os_ver)" -lt 7 ]]; then
            _error "${I18N_DATA['centos']}"
        fi
        ;;
    # Ubuntu 系列
    ubuntu)
        # 检查版本号是否大于等于 16
        if [[ "$(_os_ver)" -lt 16 ]]; then
            _error "${I18N_DATA['ubuntu']}"
        fi
        ;;
    # Debian 系列
    debian)
        # 检查版本号是否大于等于 9
        if [[ "$(_os_ver)" -lt 9 ]]; then
            _error "${I18N_DATA['debian']}"
        fi
        ;;
    # 其他不支持的操作系统
    *)
        _error "${I18N_DATA['supported']}"
        ;;
    esac
}

# =============================================================================
# 函数名称: check_dependencies
# 功能描述: 检查必要的依赖软件是否已安装。
# 参数: 无
# 返回值: 0-所有依赖都已安装 1-有依赖缺失 (由命令检查结果决定)
# =============================================================================
function check_dependencies() {
    # 定义基础必需的软件包列表
    local packages=("ca-certificates" "openssl" "curl" "wget" "git" "jq" "tzdata" "qrencode" "socat")
    local missing_packages=() # 声明数组存储缺失的包

    # 根据操作系统类型检查特定的软件包
    case "$(_os)" in
    centos)
        # 为 CentOS/RHEL 添加系统管理工具
        packages+=("crontabs" "util-linux" "iproute" "procps-ng" "bind-utils")
        # 遍历包列表，检查是否安装
        for pkg in "${packages[@]}"; do
            if ! rpm -q "$pkg" &>/dev/null; then
                missing_packages+=("$pkg") # 如果未安装，添加到缺失列表
            fi
        done
        ;;
    debian | ubuntu)
        # 为 Debian/Ubuntu 添加系统管理工具
        packages+=("cron" "bsdmainutils" "iproute2" "procps" "dnsutils")
        # 遍历包列表，检查是否安装
        for pkg in "${packages[@]}"; do
            if ! dpkg -s "$pkg" &>/dev/null; then
                missing_packages+=("$pkg") # 如果未安装，添加到缺失列表
            fi
        done
        ;;
    esac

    # 如果缺失包列表为空，则返回 0 (成功)
    [[ ${#missing_packages[@]} -eq 0 ]]
}

# =============================================================================
# 函数名称: install_dependencies
# 功能描述: 根据操作系统类型安装必要的依赖包。
# 参数: 无
# 返回值: 无 (执行包管理器命令安装软件)
# =============================================================================
function install_dependencies() {
    # 定义基础必需的软件包列表
    local packages=("ca-certificates" "openssl" "curl" "wget" "git" "jq" "tzdata" "qrencode" "socat")

    # 根据操作系统类型添加特定的软件包并执行安装
    case "$(_os)" in
    centos)
        # 为 CentOS/RHEL 添加系统管理工具
        packages+=("crontabs" "util-linux" "iproute" "procps-ng" "bind-utils")
        # 检查是否使用 dnf 包管理器 (较新版本)
        if cmd_exists "dnf"; then
            # 使用 dnf 更新系统并安装软件包
            dnf update -y || return 1
            dnf install -y dnf-plugins-core || return 1
            dnf update -y || return 1
            for pkg in "${packages[@]}"; do
                dnf install -y "${pkg}" || return 1
            done
        else
            # 使用 yum 包管理器 (较旧版本)
            yum update -y || return 1
            yum install -y epel-release yum-utils || return 1
            yum update -y || return 1
            for pkg in "${packages[@]}"; do
                yum install -y "${pkg}" || return 1
            done
        fi
        ;;
    ubuntu | debian)
        # 为 Debian/Ubuntu 添加系统管理工具
        packages+=("cron" "bsdmainutils" "iproute2" "procps" "dnsutils")
        # 更新包列表并安装软件包
        apt update -y || return 1
        for pkg in "${packages[@]}"; do
            apt install -y "${pkg}" || return 1
        done
        ;;
    esac
}

# =============================================================================
# 函数名称: download_github_files
# 功能描述: 从 GitHub API 下载指定目录的文件。
# 参数:
#   $1: 本地目标目录
#   $2: GitHub API 项目 URL
# 返回值: 无 (执行文件下载和解压过程)
# =============================================================================
function download_github_files() {
    local target_dir="$1"     # 本地目标目录
    local github_api_url="$2" # GitHub API 项目 URL

    # 创建目标目录
    mkdir -p -- "${target_dir}" ||
        _error "${I18N_DATA['failed']}: ${target_dir}"
    # 切换到目标目录
    cd -- "${target_dir}" ||
        _error "${I18N_DATA['failed']}: ${target_dir}"

    # 打印开始下载的信息
    echo -e "${GREEN}[${I18N_DATA['download']}]${NC} ${github_api_url}"
    # 使用 curl 从 GitHub API 下载 tar.gz 格式的文件，并解压
    if ! curl -sL "${github_api_url}" | tar xz --strip-components=1; then
        # 如果下载失败，则调用 _error 退出
        _error "${I18N_DATA['failed']}: ${github_api_url}"
    fi
}

# =============================================================================
# 函数名称: download_xray_script_files
# 功能描述: 下载 Xray-script 项目的全部文件。
# 参数:
#   $1: 本地目标根目录
# 返回值: 无 (调用 download_github_files 下载项目)
# =============================================================================
function download_xray_script_files() {
    local target_dir="$1" # 本地目标根目录
    # 定义 GitHub API 项目 URL（使用本仓库）
    local script_github_api="https://api.github.com/repos/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}/tarball/main"

    # 调用 download_github_files 下载项目
    download_github_files "${target_dir}" "${script_github_api}"
}

function valid_script_version() {
    [[ "$1" =~ ^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]]
}

function script_version_is_newer() {
    local candidate="$1"
    local current="$2"
    local newest

    valid_script_version "${candidate}" || return 1
    valid_script_version "${current}" || return 1
    [[ "${candidate}" != "${current}" ]] || return 1

    newest="$(printf '%s\n%s\n' "${current#v}" "${candidate#v}" | sort -V | tail -n 1)"
    [[ "${newest}" == "${candidate#v}" ]]
}

function normalize_project_root() {
    local candidate="$1"
    local normalized=''

    [[ -n "${candidate}" && "${candidate}" == /* && "${candidate}" != *$'\n'* ]] || return 1
    normalized="$(realpath -m -- "${candidate}" 2>/dev/null)" || return 1

    case "${normalized}" in
    / | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /media | /mnt | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /usr/local | /var)
        return 1
        ;;
    esac

    # 配置目录中保存着独立于项目代码的持久状态，不能被项目更新覆盖或删除。
    case "${SCRIPT_CONFIG_DIR}/" in
    "${normalized%/}/"*) return 1 ;;
    esac

    printf '%s\n' "${normalized}"
}

function choose_project_root() {
    local requested_path="$1"
    local saved_path="$2"
    local candidate=''

    if [[ -n "${requested_path}" ]]; then
        candidate="${requested_path}"
    elif [[ -n "${saved_path}" && "${saved_path}" != 'null' ]]; then
        candidate="${saved_path}"
    else
        candidate='/usr/local/xray-script'
    fi

    normalize_project_root "${candidate}"
}

function project_installation_complete() {
    local project_root="$1"
    local installed_version=''

    installed_version="$(jq -r '.version // ""' "${project_root}/config.json" 2>/dev/null || true)"
    validate_xray_script_archive "${project_root}" "${installed_version}"
}

function validate_xray_script_archive() {
    local archive_root="$1"
    local expected_version="$2"
    local relative_path=''
    local archive_version=''
    local -a required_files=(
        'install.sh'
        'core/main.sh'
        'core/handler.sh'
        'core/generate.sh'
        'core/share.sh'
        'lib/common.sh'
        'lib/protocols.sh'
        'service/ssl.sh'
        'config.json'
        'i18n/zh.json'
        'i18n/en.json'
    )
    local -a shell_files=(
        'install.sh'
        'core/main.sh'
        'core/handler.sh'
        'core/generate.sh'
        'core/share.sh'
        'lib/common.sh'
        'lib/protocols.sh'
        'service/ssl.sh'
    )
    local -a json_files=(
        'config.json'
        'i18n/zh.json'
        'i18n/en.json'
    )

    valid_script_version "${expected_version}" || return 1
    for relative_path in "${required_files[@]}"; do
        [[ -f "${archive_root}/${relative_path}" &&
            ! -L "${archive_root}/${relative_path}" &&
            -s "${archive_root}/${relative_path}" ]] || return 1
    done
    for relative_path in "${shell_files[@]}"; do
        bash -n "${archive_root}/${relative_path}" >/dev/null 2>&1 || return 1
    done
    for relative_path in "${json_files[@]}"; do
        jq empty "${archive_root}/${relative_path}" >/dev/null 2>&1 || return 1
    done

    archive_version="$(jq -r '.version // ""' "${archive_root}/config.json" 2>/dev/null || true)"
    [[ "${archive_version}" == "${expected_version}" ]]
}

function update_xray_script_transaction() (
    local remote_version="$1"
    local restart_script="$2"
    local safe_project_root=''
    local project_parent=''
    local project_name=''
    local staging_dir=''
    local project_backup=''
    local launcher_temp=''
    local launcher_backup=''
    local launcher_external=0
    local launcher_original_exists=0
    local launcher_touched=0
    local config_snapshot_dir=''
    local config_backup=''
    local config_touched=0
    local committed=0
    local updated_config=''

    function finish_xray_script_update_transaction() {
        local status="$1"
        local rollback_failed=0

        trap - EXIT HUP INT TERM

        if [[ "${committed}" -eq 0 ]]; then
            if [[ "${config_touched}" -eq 1 && -n "${config_backup}" ]]; then
                if [[ -e "${config_backup}" || -L "${config_backup}" ]]; then
                    if mv -fT -- "${config_backup}" "${SCRIPT_CONFIG_PATH}"; then
                        config_backup=''
                    else
                        rollback_failed=1
                    fi
                else
                    rollback_failed=1
                fi
            fi

            if [[ "${launcher_touched}" -eq 1 ]]; then
                if [[ "${launcher_original_exists}" -eq 1 ]]; then
                    if [[ -e "${launcher_backup}" || -L "${launcher_backup}" ]]; then
                        if mv -fT -- "${launcher_backup}" "${restart_script}"; then
                            launcher_backup=''
                        else
                            rollback_failed=1
                        fi
                    else
                        rollback_failed=1
                    fi
                elif ! rm -f -- "${restart_script}"; then
                    rollback_failed=1
                fi
            fi

            if [[ -e "${project_backup}" || -L "${project_backup}" ]]; then
                if [[ -e "${PROJECT_ROOT}" || -L "${PROJECT_ROOT}" ]]; then
                    if [[ ! -e "${staging_dir}" && ! -L "${staging_dir}" ]]; then
                        if ! mv -T -- "${PROJECT_ROOT}" "${staging_dir}"; then
                            rollback_failed=1
                        fi
                    else
                        rollback_failed=1
                    fi
                fi
                if [[ ! -e "${PROJECT_ROOT}" && ! -L "${PROJECT_ROOT}" ]]; then
                    if mv -T -- "${project_backup}" "${PROJECT_ROOT}"; then
                        project_backup=''
                    else
                        rollback_failed=1
                    fi
                else
                    rollback_failed=1
                fi
            fi
        fi

        if [[ "${committed}" -eq 1 || "${rollback_failed}" -eq 0 ]]; then
            [[ -n "${launcher_temp}" ]] && rm -f -- "${launcher_temp}"
            [[ -n "${launcher_backup}" ]] && rm -f -- "${launcher_backup}"
            [[ -n "${config_snapshot_dir}" ]] && rm -rf -- "${config_snapshot_dir}"
            [[ -n "${staging_dir}" ]] && rm -rf -- "${staging_dir}"
            [[ -n "${project_backup}" ]] && rm -rf -- "${project_backup}"
        else
            printf 'Xray-script update rollback failed; transaction artifacts were retained:\n' >&2
            [[ -n "${staging_dir}" ]] && printf '  staging: %s\n' "${staging_dir}" >&2
            [[ -n "${project_backup}" ]] && printf '  project backup: %s\n' "${project_backup}" >&2
            [[ -n "${launcher_backup}" ]] && printf '  launcher backup: %s\n' "${launcher_backup}" >&2
            [[ -n "${config_snapshot_dir}" ]] && printf '  config snapshot: %s\n' "${config_snapshot_dir}" >&2
            status=1
        fi

        exit "${status}"
    }

    trap 'finish_xray_script_update_transaction "$?"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    safe_project_root="$(normalize_project_root "${PROJECT_ROOT}")" || return 1
    PROJECT_ROOT="${safe_project_root}"
    valid_script_version "${remote_version}" || return 1
    [[ "${restart_script}" == /* && "${restart_script}" != *$'\n'* ]] || return 1
    [[ -d "${PROJECT_ROOT}" && ! -L "${PROJECT_ROOT}" ]] || return 1

    case "${restart_script}" in
    "${PROJECT_ROOT}/install.sh")
        ;;
    "${PROJECT_ROOT}/"*)
        return 1
        ;;
    *)
        launcher_external=1
        ;;
    esac

    project_parent="$(dirname -- "${PROJECT_ROOT}")"
    project_name="$(basename -- "${PROJECT_ROOT}")"
    staging_dir="$(mktemp -d -- "${project_parent}/.${project_name}.update.XXXXXXXXXX")" || return 1
    project_backup="${staging_dir}.backup"

    download_xray_script_files "${staging_dir}" || return 1
    if ! validate_xray_script_archive "${staging_dir}" "${remote_version}"; then
        printf '%s\n' "${I18N_DATA['failed']}: invalid Xray-script archive" >&2
        return 1
    fi

    if ! mv -T -- "${PROJECT_ROOT}" "${project_backup}"; then
        return 1
    fi
    if ! mv -T -- "${staging_dir}" "${PROJECT_ROOT}"; then
        return 1
    fi

    if [[ "${launcher_external}" -eq 1 ]]; then
        local launcher_parent=''
        local launcher_name=''
        launcher_parent="$(dirname -- "${restart_script}")"
        launcher_name="$(basename -- "${restart_script}")"
        [[ -d "${launcher_parent}" ]] || return 1

        launcher_temp="$(mktemp -- "${launcher_parent}/.${launcher_name}.update.XXXXXXXXXX")" || return 1
        if ! cp -f -- "${PROJECT_ROOT}/install.sh" "${launcher_temp}"; then
            return 1
        fi
        chmod --reference="${PROJECT_ROOT}/install.sh" "${launcher_temp}" 2>/dev/null ||
            chmod 755 "${launcher_temp}" || return 1

        if [[ -e "${restart_script}" || -L "${restart_script}" ]]; then
            launcher_original_exists=1
            launcher_backup="${launcher_temp}.backup"
            cp -a -- "${restart_script}" "${launcher_backup}" || return 1
        fi
        launcher_touched=1
        if ! mv -fT -- "${launcher_temp}" "${restart_script}"; then
            return 1
        fi
        launcher_temp=''
    fi

    local config_parent=''
    local config_name=''
    config_parent="$(dirname -- "${SCRIPT_CONFIG_PATH}")"
    config_name="$(basename -- "${SCRIPT_CONFIG_PATH}")"
    config_snapshot_dir="$(mktemp -d -- "${config_parent}/.${config_name}.update.XXXXXXXXXX")" || return 1
    config_backup="${config_snapshot_dir}/original"
    cp -a -- "${SCRIPT_CONFIG_PATH}" "${config_backup}" || return 1

    updated_config="$(jq --arg ver "${remote_version}" '.version = $ver' "${SCRIPT_CONFIG_PATH}")" || return 1
    config_touched=1
    write_config "${updated_config}" "${SCRIPT_CONFIG_PATH}" || return 1

    committed=1
)

# =============================================================================
# 函数名称: check_xray_script_version
# 功能描述: 检查本地安装的 Xray-script 版本与 GitHub 上的最新版本是否一致。
#           如果不一致，则提示用户。
# 参数: 无 (直接使用全局变量 PROJECT_ROOT)
# 返回值: 无 (打印版本检查信息到标准输出)
# =============================================================================
function check_xray_script_version() {
    # 定义 GitHub API URL 和本地版本文件路径（使用本仓库）
    local script_config_github_url="https://raw.githubusercontent.com/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}/main/config.json"
    local is_update='n' # 初始化更新标志为 'n' (不更新)
    local remote_config=''
    local installed_config="${PROJECT_ROOT}/config.json"
    local local_version=''
    local remote_version=''
    local state_version=''

    # 以实际安装代码快照的 config.json 为准，而不是可变的用户状态文件。
    local_version="$(jq -r '.version // ""' "${installed_config}" 2>/dev/null || true)"
    if ! valid_script_version "${local_version}"; then
        echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['failed']}: invalid local script version" >&2
        return 0
    fi

    # 菜单从用户状态文件显示版本；发现漂移时同步到实际安装版本。
    state_version="$(jq -r '.version // ""' "${SCRIPT_CONFIG_PATH}" 2>/dev/null || true)"
    if [[ "${state_version}" != "${local_version}" ]]; then
        local synced_config=''
        synced_config="$(jq --arg version "${local_version}" '.version = $version' "${SCRIPT_CONFIG_PATH}")" || return 1
        write_config "${synced_config}" "${SCRIPT_CONFIG_PATH}" || return 1
    fi

    # 从 GitHub API 获取远程版本号
    if ! remote_config="$(curl -fsSL --retry 2 --connect-timeout 15 --max-time 30 "${script_config_github_url}")"; then
        echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['failed']}: ${script_config_github_url}" >&2
        return 0
    fi
    remote_version="$(jq -er '.version | select(type == "string")' <<<"${remote_config}" 2>/dev/null || true)"

    if ! valid_script_version "${remote_version}"; then
        echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['failed']}: invalid script version" >&2
        return 0
    fi

    # 仅当远程版本严格更新时提示，避免网络异常或远端落后导致降级。
    if script_version_is_newer "${remote_version}" "${local_version}"; then
        # 如果不一致，则提示用户有新版本
        echo -e "${GREEN}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['new']}"
        # 询问用户是否更新
        read -rp "${I18N_DATA['now']}" -e -i "Y" is_update

        # 根据用户选择决定是否更新
        case "${is_update,,}" in # ${is_update,,} 转换为小写
        y | yes)
            # 如果用户选择更新
            local safe_project_root=''
            safe_project_root="$(normalize_project_root "${PROJECT_ROOT}")" || _error "${I18N_DATA['path_invalid']}: ${PROJECT_ROOT}"
            PROJECT_ROOT="${safe_project_root}"
            local restart_script="${CUR_DIR}/${CUR_FILE}"
            if [[ "${CUR_DIR}" == "${PROJECT_ROOT}" ]]; then
                restart_script="${PROJECT_ROOT}/install.sh"
            fi
            update_xray_script_transaction "${remote_version}" "${restart_script}" ||
                _error "${I18N_DATA['failed']}: ${PROJECT_ROOT}"
            sleep 1
            # 打印更新完成信息
            echo -e "${GREEN}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['completed']}"
            # 重启脚本
            bash "${restart_script}"
            # 退出脚本，避免重复执行
            exit 0
            ;;
        *)
            # 如果用户选择不更新，则提示及时更新
            echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['promptly']}"
            ;;
        esac
    fi
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 解析命令行参数。
#           2. 加载国际化数据。
#           3. 检查 root 权限。
#           4. 检查操作系统。
#           5. 检查并安装依赖。
#           6. 处理项目目录和配置。
#           7. 启动主脚本。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (协调调用其他函数完成整个安装流程)
# =============================================================================
function main() {
    # 解析命令行参数
    parse_args "$@"
    # 加载国际化数据
    load_i18n

    # 检查是否以 root 权限运行
    [[ $EUID -ne 0 ]] && _error "${I18N_DATA['root']}"

    # 检查操作系统
    check_os

    # 检查依赖，如果缺失则安装
    if ! check_dependencies; then
        install_dependencies ||
            _error "${I18N_DATA['failed']}: dependencies"
        check_dependencies ||
            _error "${I18N_DATA['failed']}: dependencies"
    fi

    # 检查脚本配置目录和配置文件是否存在，如果不存在或损坏则创建并下载默认配置
    if [[ ! -d "${SCRIPT_CONFIG_DIR}" ]]; then
        mkdir -p -- "${SCRIPT_CONFIG_DIR}" ||
            _error "${I18N_DATA['failed']}: ${SCRIPT_CONFIG_DIR}"
    fi
    # 如果配置文件不存在，或内容为空/不是有效 JSON，则重新下载
    if [[ ! -f "${SCRIPT_CONFIG_PATH}" ]] || [[ ! -s "${SCRIPT_CONFIG_PATH}" ]] || ! jq empty "${SCRIPT_CONFIG_PATH}" 2>/dev/null; then
        if ! wget -O "${SCRIPT_CONFIG_PATH}" "https://raw.githubusercontent.com/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}/main/config.json"; then
            _error "${I18N_DATA['failed']}: config.json"
        fi
        chmod 600 "${SCRIPT_CONFIG_PATH}"
        # 校验下载结果非空且为有效 JSON，避免后续流程使用损坏的配置文件
        if ! [[ -s "${SCRIPT_CONFIG_PATH}" ]] || ! jq empty "${SCRIPT_CONFIG_PATH}" 2>/dev/null; then
            _error "${I18N_DATA['failed']}: config.json (invalid)"
        fi
    fi

    # 从脚本配置文件中读取已记录的安装路径
    local script_path="$(jq -r '.path // ""' "${SCRIPT_CONFIG_PATH}")"
    local requested_path="${PROJECT_ROOT}"
    if ! PROJECT_ROOT="$(choose_project_root "${requested_path}" "${script_path}")"; then
        if [[ -n "${requested_path}" ]]; then
            _error "${I18N_DATA['path_invalid']}: ${requested_path}"
        fi
        echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['path_fallback']}" >&2
        PROJECT_ROOT="$(normalize_project_root '/usr/local/xray-script')" ||
            _error "${I18N_DATA['path_invalid']}: /usr/local/xray-script"
    fi

    # 显式 -d 始终优先于历史保存路径；同时把默认值或规范化后的路径写回配置。
    if [[ "${script_path}" != "${PROJECT_ROOT}" ]]; then
        SCRIPT_CONFIG="$(jq --arg path "${PROJECT_ROOT}" '.path = $path' "${SCRIPT_CONFIG_PATH}")" ||
            _error "${I18N_DATA['failed']}: ${SCRIPT_CONFIG_PATH}"
        backup_config "${SCRIPT_CONFIG_PATH}" || _error "${I18N_DATA['failed']}: ${SCRIPT_CONFIG_PATH} backup"
        write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || _error "${I18N_DATA['failed']}: ${SCRIPT_CONFIG_PATH}"
    fi

    # 设置各个子目录的路径
    I18N_DIR="${PROJECT_ROOT}/i18n"
    CORE_DIR="${PROJECT_ROOT}/core"
    SERVICE_DIR="${PROJECT_ROOT}/service"
    CONFIG_DIR="${PROJECT_ROOT}/config"
    TOOL_DIR="${PROJECT_ROOT}/tool"

    # 检查项目根目录是否存在
    if project_installation_complete "${PROJECT_ROOT}"; then
        # 如果存在，则检查版本更新
        check_xray_script_version || _error "${I18N_DATA['failed']}: version state"
    else
        # 目录不存在或安装不完整时重新下载缺失文件。
        download_xray_script_files "${PROJECT_ROOT}"
        project_installation_complete "${PROJECT_ROOT}" || _error "${I18N_DATA['failed']}: invalid Xray-script archive"
    fi

    # 检查配置文件中的语言设置
    local lang="$(jq -r '.language // ""' "${SCRIPT_CONFIG_PATH}")"
    if [[ -z "${lang}" && -z "${LANG_PARAM}" ]]; then
        # 如果语言未设置且未通过命令行指定，则运行菜单脚本选择语言
        bash "${CORE_DIR}/menu.sh" '--language'
        case $? in
        2) LANG_PARAM="en" ;; # 选择英文
        *) LANG_PARAM="zh" ;; # 默认中文
        esac
        SCRIPT_CONFIG="$(jq --arg language "${LANG_PARAM}" '.language = $language' "${SCRIPT_CONFIG_PATH}")" ||
            _error "${I18N_DATA['failed']}: ${SCRIPT_CONFIG_PATH}"
        backup_config "${SCRIPT_CONFIG_PATH}" || _error "${I18N_DATA['failed']}: ${SCRIPT_CONFIG_PATH} backup"
        write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || _error "${I18N_DATA['failed']}: ${SCRIPT_CONFIG_PATH}"
    elif [[ "${LANG_PARAM}" =~ ^--lang= ]]; then
        SCRIPT_CONFIG="$(jq --arg language "${LANG_PARAM#*=}" '.language = $language' "${SCRIPT_CONFIG_PATH}")" ||
            _error "${I18N_DATA['failed']}: ${SCRIPT_CONFIG_PATH}"
        backup_config "${SCRIPT_CONFIG_PATH}" || _error "${I18N_DATA['failed']}: ${SCRIPT_CONFIG_PATH} backup"
        write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}" || _error "${I18N_DATA['failed']}: ${SCRIPT_CONFIG_PATH}"
    fi

    # 启动主脚本，并传递快速安装选项
    bash "${CORE_DIR}/main.sh" "${QUICK_INSTALL}"
}

# --- 脚本执行入口 ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
