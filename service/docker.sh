#!/usr/bin/env bash
#
# Copyright (C) 2025 zxcvos
#
# Xray-script:
#   https://github.com/zxcvos/Xray-script
#
# docker-install:
#   https://github.com/docker/docker-install
#
# Cloudflare WARP:
#   https://github.com/haoel/haoel.github.io?tab=readme-ov-file#1043-docker-%E4%BB%A3%E7%90%86
#   https://github.com/e7h4n/cloudflare-warp
#
# Cloudreve:
#   https://cloudreve.org
# =============================================================================
# 注释: 通过 Qwen3-Coder 生成。
# 脚本名称: docker.sh
# 功能描述: 提供 Docker 环境管理功能，包括安装 Docker、管理 Cloudflare WARP 容器、
#           以及管理 Cloudreve (v3 和 v4) 容器服务。
#           支持多语言提示信息。
# 作者: zxcvos
# 时间: 2025-07-25
# 版本: 1.0.0
# 依赖: bash, jq, wget, sed, awk, grep, curl, openssl, docker, docker-compose
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
#   - ${CONFIG_DIR}/cloudflare-warp/Dockerfile: WARP 容器的构建文件
#   - ${CLOUDREVE_V*_YAML_DIR}/docker-compose.yaml: Cloudreve 服务的编排文件
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
readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)" # 当前脚本所在目录
readonly CUR_FILE="$(basename "$0" | sed 's/\..*//')"         # 当前脚本文件名 (不含扩展名)
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# 定义项目中各个重要目录与配置文件的路径
readonly SCRIPT_CONFIG_DIR="${HOME}/.xray-script"              # 主配置文件目录
readonly I18N_DIR="${PROJECT_ROOT}/i18n"                       # 国际化文件目录
readonly CONFIG_DIR="${PROJECT_ROOT}/config"                   # 配置文件目录
readonly TOOL_DIR="${PROJECT_ROOT}/tool"                       # 工具脚本目录
readonly DOCKER_DIR="${SCRIPT_CONFIG_DIR}/docker"              # Docker 相关文件目录
readonly WARP_DIR="${DOCKER_DIR}/cloudflare-warp"              # WARP Docker 目录
readonly CLOUDREVE_V3_DIR="${DOCKER_DIR}/cloudreve/v3"         # Cloudreve v3 Docker 目录
readonly CLOUDREVE_V3_YAML_DIR="${CONFIG_DIR}/cloudreve/v3"    # Cloudreve v3 配置文件目录
readonly CLOUDREVE_V4_DIR="${DOCKER_DIR}/cloudreve/v4"         # Cloudreve v4 Docker 目录
readonly CLOUDREVE_V4_YAML_DIR="${CONFIG_DIR}/cloudreve/v4"    # Cloudreve v4 配置文件目录
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json" # 脚本主要配置文件路径

# --- 全局变量声明 ---
# 声明用于存储语言参数和国际化数据的全局变量
declare LANG_PARAM='' # (未在脚本中实际使用，可能是预留)
declare I18N_DATA=''  # 存储从 i18n JSON 文件中读取的全部数据

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
    # 从配置文件中读取语言设置
    local lang="$(jq -r '.language // ""' "${SCRIPT_CONFIG_PATH}")"

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
# 函数名称: print_info
# 功能描述: 以绿色打印信息级别的提示消息。
# 参数:
#   $@: 消息内容 (msg)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function print_info() {
    # 从 i18n 数据中读取 "信息" 标题，然后用绿色打印消息
    printf "${GREEN}[$(echo "$I18N_DATA" | jq -r '.title.info')] ${NC}%s\n" "$*" >&2
}

# =============================================================================
# 函数名称: print_warn
# 功能描述: 以黄色打印警告级别的提示消息。
# 参数:
#   $@: 消息内容 (msg)
# 返回值: 无 (直接打印到标准错误输出 >&2)
# =============================================================================
function print_warn() {
    # 从 i18n 数据中读取 "警告" 标题，然后用黄色打印消息
    printf "${YELLOW}[$(echo "$I18N_DATA" | jq -r '.title.warn')] ${NC}%s\n" "$*" >&2
}

# =============================================================================
# 函数名称: print_error
# 功能描述: 以红色打印错误级别的提示消息，并退出脚本。
# 参数:
#   $@: 消息内容 (msg)
# 返回值: 无 (直接打印到标准错误输出 >&2，然后 exit 1)
# =============================================================================
function print_error() {
    # 从 i18n 数据中读取 "错误" 标题，然后用红色打印消息
    printf "${RED}[$(echo "$I18N_DATA" | jq -r '.title.error')] ${NC}%s\n" "$*" >&2
    # 打印错误信息后退出脚本，错误码为 1
    exit 1
}

# =============================================================================
# 函数名称: _os
# 功能描述: 检测当前操作系统的发行版名称。
# 参数: 无
# 返回值: 操作系统名称 (echo 输出: debian/ubuntu/centos/amazon/...)
# =============================================================================
function _os() {
    local os="" # 声明局部变量存储操作系统名称

    # 检查 Debian/Ubuntu 系列
    if [[ -f "/etc/debian_version" ]]; then
        # 读取 /etc/os-release 文件并提取 ID 字段
        source /etc/os-release && os="${ID}"
        # 输出检测到的操作系统名称
        printf -- "%s" "${os}" && return
    fi

    # 检查 Red Hat/CentOS 系列
    if [[ -f "/etc/redhat-release" ]]; then
        os="centos"
        # 输出检测到的操作系统名称
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
    # 检查 Red Hat/CentOS 系列
    if [[ -f /etc/redhat-release ]]; then
        # 从 /etc/redhat-release 文件中提取发行版名称和版本号
        awk '{print ($1,$3~/^[0-9]/?$3:$4)}' /etc/redhat-release && return
    fi

    # 检查通用的 os-release 文件
    if [[ -f /etc/os-release ]]; then
        # 从 /etc/os-release 文件中提取 PRETTY_NAME 字段
        awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
    fi

    # 检查 LSB (Linux Standard Base) 发布文件
    if [[ -f /etc/lsb-release ]]; then
        # 从 /etc/lsb-release 文件中提取 DESCRIPTION 字段
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
    # 调用 _os_full 函数获取完整版本信息，然后提取其中的数字和点
    local main_ver="$(echo $(_os_full) | grep -oE "[0-9.]+")"
    # 输出主版本号 (第一个点号前的部分)
    printf -- "%s" "${main_ver%%.*}"
}

# =============================================================================
# 函数名称: install_docker
# 功能描述: 从官方脚本安装 Docker。针对特定系统 (如 CentOS 8) 进行适配。
# 参数: 无
# 返回值: 无 (执行安装过程，失败时会调用 print_error 退出)
# =============================================================================
function install_docker() {
    # 打印开始安装的信息
    print_info "$(echo "$I18N_DATA" | jq -r '.docker.install.start')"

    # 下载 Docker 官方安装脚本到工具目录
    wget -O "${TOOL_DIR}/install-docker.sh" https://get.docker.com

    # 检查是否为 CentOS 8 系统
    if [[ "$(_os)" == "centos" && "$(_os_ver)" -eq 8 ]]; then
        # 打印针对 CentOS 8 的修复信息
        print_info "$(echo "$I18N_DATA" | jq -r '.docker.install.centos8_fix')"
        # 修改安装脚本，在安装命令中添加 --allowerasing 选项以解决依赖冲突
        sed -i 's|$sh_c "$pkg_manager install -y -q $pkgs"| $sh_c "$pkg_manager install -y -q $pkgs --allowerasing"|' "${TOOL_DIR}/install-docker.sh"
    fi

    # 打印运行前检查的信息
    print_info "$(echo "$I18N_DATA" | jq -r '.docker.install.dry_run')"
    # 执行安装脚本的 --dry-run 模式进行检查
    sh "${TOOL_DIR}/install-docker.sh" --dry-run

    # 打印正式运行安装的信息
    print_info "$(echo "$I18N_DATA" | jq -r '.docker.install.running')"
    # 执行安装脚本进行实际安装
    sh "${TOOL_DIR}/install-docker.sh"
}

# =============================================================================
# 函数名称: get_container_ip
# 功能描述: 获取指定 Docker 容器的 IP 地址。
# 参数:
#   $1: 容器名称或 ID (container_name)
# 返回值: 容器的 IP 地址 (echo 输出)
# =============================================================================
function get_container_ip() {
    local container_name="$1"
    local addresses

    addresses="$(docker inspect --format='{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{println .GlobalIPv6Address}}{{end}}' "${container_name}" 2>/dev/null)" || return 1
    addresses="$(printf '%s\n' "${addresses}" | awk 'NF && !seen[$0]++')"
    [[ "$(printf '%s\n' "${addresses}" | awk 'NF {count++} END {print count + 0}')" -eq 1 ]] || return 1
    printf '%s\n' "${addresses}"
}

function wait_for_warp() {
    local container_name="$1"
    local container_ip=''
    local attempt

    for ((attempt = 0; attempt < 30; attempt++)); do
        if [[ "$(docker inspect --format='{{.State.Running}}' "${container_name}" 2>/dev/null)" == 'true' ]]; then
            container_ip="$(get_container_ip "${container_name}" 2>/dev/null || true)"
            if [[ -n "${container_ip}" ]] &&
                timeout 1 bash -c 'exec 3<>"/dev/tcp/$1/40001"' bash "${container_ip}" 2>/dev/null; then
                printf '%s\n' "${container_ip}"
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

# =============================================================================
# 函数名称: build_warp
# 功能描述: 构建 Cloudflare WARP 的 Docker 镜像。
#           如果镜像已存在，则跳过构建。
# 参数: 无
# 返回值: 无 (执行构建过程，失败时会调用 print_error 退出)
# =============================================================================
function build_warp() {
    # 检查名为 xray-script-warp 的镜像是否已存在
    if ! docker images --format "{{.Repository}}" | grep -q xray-script-warp; then
        # 打印开始构建的信息
        print_info "$(echo "$I18N_DATA" | jq -r '.docker.warp.build.start')"
        # 使用 docker build 命令构建镜像，失败则调用 print_error 退出
        docker build -t xray-script-warp "${CONFIG_DIR}/cloudflare-warp" || print_error "$(echo "$I18N_DATA" | jq -r '.docker.warp.build.fail')"
    fi
}

# =============================================================================
# 函数名称: enable_warp
# 功能描述: 启动 Cloudflare WARP 容器。
#           如果容器已运行，则跳过启动。
# 参数: 无
# 返回值: 容器的 IP 地址 (echo 输出)，或无输出
# =============================================================================
function enable_warp() {
    local container_ip=''
    local container_state='missing'

    if docker inspect xray-script-warp >/dev/null 2>&1; then
        container_state="$(docker inspect --format='{{if .State.Running}}running{{else}}stopped{{end}}' xray-script-warp 2>/dev/null)" || return 1
    fi
    print_info "$(echo "$I18N_DATA" | jq -r '.docker.warp.enable.start')"
    case "${container_state}" in
    running) ;;
    stopped)
        docker start xray-script-warp >&2 || return 1
        ;;
    missing)
        mkdir -vp "${WARP_DIR}" >&2 || return 1
        docker run -d --restart=always --name=xray-script-warp \
            --log-driver json-file --log-opt max-size=100m --log-opt max-file=3 \
            -v "${WARP_DIR}":/var/lib/cloudflare-warp:rw xray-script-warp >&2 || return 1
        ;;
    *) return 1 ;;
    esac

    container_ip="$(wait_for_warp xray-script-warp)" || {
        if [[ "${container_state}" != 'running' ]]; then
            docker stop xray-script-warp >/dev/null 2>&1 || true
        fi
        print_error "$(echo "$I18N_DATA" | jq -r '.docker.warp.build.fail')"
        return 1
    }
    print_info "$(echo "$I18N_DATA" | jq -r ".docker.warp.enable.success" | sed "s/\${container_ip}/${container_ip}/")"
    printf '%s\n' "${container_ip}"
}

# =============================================================================
# 函数名称: disable_warp
# 功能描述: 停止 Cloudflare WARP 容器，并保留容器与注册数据供下次启用。
# 参数: 无
# 返回值: 无 (执行停止和清理过程)
# =============================================================================
function disable_warp() {
    local state
    docker inspect xray-script-warp >/dev/null 2>&1 || return 0
    state="$(docker inspect --format='{{.State.Running}}' xray-script-warp 2>/dev/null)" || return 1
    if [[ "${state}" == 'true' ]]; then
        print_warn "$(echo "$I18N_DATA" | jq -r '.docker.warp.disable.stop')"
        docker stop xray-script-warp >/dev/null || return 1
    fi
    print_info "$(echo "$I18N_DATA" | jq -r '.docker.warp.disable.success')"
}

function rollback_warp_reset() {
    local running_backup='xray-script-warp-reset-backup-running'
    local stopped_backup='xray-script-warp-reset-backup-stopped'
    local data_transaction="${DOCKER_DIR}/.warp-reset-transaction"
    local backup_container='' restore_running=0 restore_status=0
    local current_image='' reset_image='' remove_current=0
    local data_transaction_exists=0 data_swapped=0 data_was_present=0

    if [[ -d "${data_transaction}" && ! -L "${data_transaction}" ]]; then
        data_transaction_exists=1
        if [[ -e "${data_transaction}/data" ||
            -e "${data_transaction}/swapped" ||
            -e "${data_transaction}/had-data" ]]; then
            data_swapped=1
        fi
    elif [[ -e "${data_transaction}" || -L "${data_transaction}" ]]; then
        return 1
    fi

    if [[ "${data_transaction_exists}" -eq 1 &&
        -f "${data_transaction}/committed" ]]; then
        if docker inspect "${running_backup}" >/dev/null 2>&1; then
            docker rm -f "${running_backup}" >/dev/null 2>&1 || restore_status=1
        fi
        if docker inspect "${stopped_backup}" >/dev/null 2>&1; then
            docker rm -f "${stopped_backup}" >/dev/null 2>&1 || restore_status=1
        fi
        if [[ "${restore_status}" -eq 0 ]]; then
            if docker image inspect xray-script-warp:reset-new >/dev/null 2>&1; then
                docker image rm xray-script-warp:reset-new >/dev/null 2>&1 || restore_status=1
            fi
            if docker image inspect xray-script-warp:reset-backup >/dev/null 2>&1; then
                docker image rm xray-script-warp:reset-backup >/dev/null 2>&1 || restore_status=1
            fi
        fi
        if [[ "${restore_status}" -eq 0 ]]; then
            rm -rf -- "${data_transaction}" || restore_status=1
        fi
        return "${restore_status}"
    fi

    if docker inspect "${running_backup}" >/dev/null 2>&1; then
        backup_container="${running_backup}"
        restore_running=1
    elif docker inspect "${stopped_backup}" >/dev/null 2>&1; then
        backup_container="${stopped_backup}"
    fi

    if [[ -n "${backup_container}" ]]; then
        remove_current=1
    elif docker inspect xray-script-warp >/dev/null 2>&1 &&
        docker image inspect xray-script-warp:reset-new >/dev/null 2>&1 &&
        [[ "${data_transaction_exists}" -eq 1 &&
            "${data_swapped}" -eq 1 ]]; then
        current_image="$(docker inspect --format='{{.Image}}' xray-script-warp 2>/dev/null)" ||
            restore_status=1
        reset_image="$(docker image inspect --format='{{.Id}}' xray-script-warp:reset-new 2>/dev/null)" ||
            restore_status=1
        if [[ "${restore_status}" -eq 0 && "${current_image}" == "${reset_image}" ]]; then
            remove_current=1
        fi
    fi
    if [[ "${remove_current}" -eq 1 ]] && docker inspect xray-script-warp >/dev/null 2>&1; then
        docker rm -f xray-script-warp >/dev/null 2>&1 || restore_status=1
    fi
    if [[ "${data_transaction_exists}" -eq 1 && "${restore_status}" -eq 0 ]]; then
        if [[ "${data_swapped}" -eq 1 ]]; then
            if docker inspect xray-script-warp >/dev/null 2>&1; then
                restore_status=1
            else
                if [[ -e "${data_transaction}/data" ||
                    -L "${data_transaction}/data" ||
                    -f "${data_transaction}/had-data" ]]; then
                    data_was_present=1
                fi
                if [[ -e "${data_transaction}/data" ||
                    -L "${data_transaction}/data" ]]; then
                    if [[ -e "${WARP_DIR}" || -L "${WARP_DIR}" ]]; then
                        rm -rf -- "${WARP_DIR}" || restore_status=1
                    fi
                    if [[ -d "${data_transaction}/data" &&
                        ! -L "${data_transaction}/data" &&
                        "${restore_status}" -eq 0 ]]; then
                        mv -- "${data_transaction}/data" "${WARP_DIR}" ||
                            restore_status=1
                    else
                        restore_status=1
                    fi
                elif [[ "${data_was_present}" -eq 0 &&
                    ( -e "${WARP_DIR}" || -L "${WARP_DIR}" ) ]]; then
                    rm -rf -- "${WARP_DIR}" || restore_status=1
                fi
                if [[ "${restore_status}" -eq 0 ]]; then
                    rm -f -- "${data_transaction}/swapped" || restore_status=1
                fi
                if [[ "${restore_status}" -eq 0 ]]; then
                    rm -f -- "${data_transaction}/had-data" || restore_status=1
                fi
                if [[ "${restore_status}" -eq 0 ]]; then
                    rmdir -- "${data_transaction}" 2>/dev/null || restore_status=1
                fi
            fi
        else
            rmdir -- "${data_transaction}" 2>/dev/null || restore_status=1
        fi
    fi
    if [[ -n "${backup_container}" && "${restore_status}" -eq 0 ]]; then
        docker rename "${backup_container}" xray-script-warp >/dev/null 2>&1 || restore_status=1
        if [[ "${restore_status}" -eq 0 && "${restore_running}" -eq 1 ]]; then
            docker start xray-script-warp >/dev/null 2>&1 || restore_status=1
            if [[ "${restore_status}" -eq 0 ]]; then
                wait_for_warp xray-script-warp >/dev/null 2>&1 || restore_status=1
            fi
        fi
    fi
    if docker image inspect xray-script-warp:reset-backup >/dev/null 2>&1; then
        docker tag xray-script-warp:reset-backup xray-script-warp:latest >/dev/null 2>&1 ||
            restore_status=1
    fi
    if [[ "${restore_status}" -eq 0 ]]; then
        docker image rm xray-script-warp:reset-new >/dev/null 2>&1 || true
        docker image rm xray-script-warp:reset-backup >/dev/null 2>&1 || true
    fi
    return "${restore_status}"
}

function prepare_warp_reset() (
    local running_backup='xray-script-warp-reset-backup-running'
    local stopped_backup='xray-script-warp-reset-backup-stopped'
    local data_transaction="${DOCKER_DIR}/.warp-reset-transaction"
    local container_state='missing' backup_container='' container_ip=''
    local old_container_stopped=0

    function finish_warp_reset_preparation() {
        local status="$1"
        local restore_status=0

        trap - EXIT HUP INT TERM
        if [[ "${status}" -ne 0 ]]; then
            if docker inspect "${running_backup}" >/dev/null 2>&1 ||
                docker inspect "${stopped_backup}" >/dev/null 2>&1 ||
                [[ -e "${data_transaction}" || -L "${data_transaction}" ]] ||
                { [[ "${container_state}" == 'missing' ]] &&
                    docker inspect xray-script-warp >/dev/null 2>&1; }; then
                rollback_warp_reset || restore_status=1
            else
                if [[ "${old_container_stopped}" -eq 1 ]]; then
                    docker start xray-script-warp >/dev/null 2>&1 || restore_status=1
                    if [[ "${restore_status}" -eq 0 ]]; then
                        wait_for_warp xray-script-warp >/dev/null 2>&1 || restore_status=1
                    fi
                fi
                docker image rm xray-script-warp:reset-new >/dev/null 2>&1 || true
                if [[ "${restore_status}" -eq 0 ]]; then
                    docker image rm xray-script-warp:reset-backup >/dev/null 2>&1 || true
                fi
            fi
            if [[ "${restore_status}" -ne 0 ]]; then
                print_warn 'WARP reset preparation rollback failed; reset artifacts were retained.'
            fi
        fi
        exit "${status}"
    }

    trap 'finish_warp_reset_preparation "$?"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if docker inspect "${running_backup}" >/dev/null 2>&1 ||
        docker inspect "${stopped_backup}" >/dev/null 2>&1 ||
        docker image inspect xray-script-warp:reset-backup >/dev/null 2>&1 ||
        docker image inspect xray-script-warp:reset-new >/dev/null 2>&1 ||
        [[ -e "${data_transaction}" || -L "${data_transaction}" ]]; then
        print_warn 'A previous WARP reset transaction still needs recovery.'
        return 1
    fi
    if docker inspect xray-script-warp >/dev/null 2>&1; then
        container_state="$(docker inspect --format='{{if .State.Running}}running{{else}}stopped{{end}}' xray-script-warp 2>/dev/null)" || return 1
    fi
    if [[ "${container_state}" != 'missing' ]]; then
        local current_image
        current_image="$(docker inspect --format='{{.Image}}' xray-script-warp 2>/dev/null)" || return 1
        docker tag "${current_image}" xray-script-warp:reset-backup >/dev/null 2>&1 || return 1
    elif docker image inspect xray-script-warp:latest >/dev/null 2>&1; then
        docker tag xray-script-warp:latest xray-script-warp:reset-backup >/dev/null 2>&1 || return 1
    fi

    print_info "$(echo "$I18N_DATA" | jq -r '.docker.warp.build.start')"
    if ! docker build --no-cache -t xray-script-warp:reset-new "${CONFIG_DIR}/cloudflare-warp" >&2; then
        return 1
    fi

    case "${container_state}" in
    running)
        backup_container="${running_backup}"
        docker stop xray-script-warp >/dev/null 2>&1 || return 1
        old_container_stopped=1
        ;;
    stopped) backup_container="${stopped_backup}" ;;
    missing) ;;
    *) return 1 ;;
    esac
    if [[ -n "${backup_container}" ]]; then
        docker rename xray-script-warp "${backup_container}" >/dev/null 2>&1 || return 1
    fi

    mkdir -p -- "${DOCKER_DIR}" || return 1
    mkdir -- "${data_transaction}" || return 1
    if [[ -e "${WARP_DIR}" || -L "${WARP_DIR}" ]]; then
        [[ -d "${WARP_DIR}" && ! -L "${WARP_DIR}" ]] || return 1
        mv -- "${WARP_DIR}" "${data_transaction}/data" || return 1
        touch -- "${data_transaction}/had-data" || return 1
    fi
    touch -- "${data_transaction}/swapped" || return 1
    mkdir -- "${WARP_DIR}" || return 1
    if ! docker run -d --restart=always --name=xray-script-warp \
        --log-driver json-file --log-opt max-size=100m --log-opt max-file=3 \
        -v "${WARP_DIR}":/var/lib/cloudflare-warp:rw \
        xray-script-warp:reset-new >&2; then
        return 1
    fi
    container_ip="$(wait_for_warp xray-script-warp)" || return 1
    trap - EXIT HUP INT TERM
    printf '%s\n' "${container_ip}"
)

function commit_warp_reset() {
    local running_backup='xray-script-warp-reset-backup-running'
    local stopped_backup='xray-script-warp-reset-backup-stopped'
    local data_transaction="${DOCKER_DIR}/.warp-reset-transaction"
    local backup_container='' cleanup_status=0

    [[ -d "${data_transaction}" && ! -L "${data_transaction}" &&
        -f "${data_transaction}/swapped" ]] || return 1
    docker inspect xray-script-warp >/dev/null 2>&1 || return 1
    [[ "$(docker inspect --format='{{.State.Running}}' xray-script-warp 2>/dev/null)" == 'true' ]] || return 1
    wait_for_warp xray-script-warp >/dev/null 2>&1 || return 1
    docker tag xray-script-warp:reset-new xray-script-warp:latest >/dev/null 2>&1 || return 1
    mv -- "${data_transaction}/swapped" \
        "${data_transaction}/committed" || return 1

    if docker inspect "${running_backup}" >/dev/null 2>&1; then
        backup_container="${running_backup}"
    elif docker inspect "${stopped_backup}" >/dev/null 2>&1; then
        backup_container="${stopped_backup}"
    fi
    if [[ -n "${backup_container}" ]]; then
        docker rm "${backup_container}" >/dev/null 2>&1 || cleanup_status=1
    fi
    if [[ "${cleanup_status}" -eq 0 ]]; then
        if docker image inspect xray-script-warp:reset-new >/dev/null 2>&1; then
            docker image rm xray-script-warp:reset-new >/dev/null 2>&1 || cleanup_status=1
        fi
        if docker image inspect xray-script-warp:reset-backup >/dev/null 2>&1; then
            docker image rm xray-script-warp:reset-backup >/dev/null 2>&1 || cleanup_status=1
        fi
    fi
    if [[ "${cleanup_status}" -eq 0 ]]; then
        rm -rf -- "${data_transaction}" || cleanup_status=1
    fi
    if [[ "${cleanup_status}" -ne 0 ]]; then
        print_warn "WARP reset committed, but old transaction artifacts were retained at: ${data_transaction}"
    fi
    return 0
}

# =============================================================================
# 函数名称: install_cloudreve_v3
# 功能描述: 安装并启动 Cloudreve v3 服务。
#           创建必要的目录和文件，配置 docker-compose.yaml，
#           启动服务，并获取管理员账户信息和 Aria2 Token。
# 参数: 无
# 返回值: 无 (执行安装和启动过程)
# =============================================================================
function install_cloudreve_v3() {
    # 检查名为 cloudreve_v3 的容器是否已在运行
    if ! docker ps --format "{{.Names}}" | grep -q "^cloudreve_v3\$"; then
        # 打印创建目录的信息
        print_info "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v3.create_dir')"
        # 创建 Cloudreve v3 所需的目录结构和文件
        mkdir -vp ${CLOUDREVE_V3_DIR} &&
            mkdir -vp ${CLOUDREVE_V3_DIR}/{uploads,avatar} &&
            touch "${CLOUDREVE_V3_DIR}/conf.ini" &&
            touch "${CLOUDREVE_V3_DIR}/cloudreve.db" &&
            mkdir -vp ${CLOUDREVE_V3_DIR}/aria2/config &&
            mkdir -vp ${CLOUDREVE_V3_DIR}/data/aria2 &&
            chmod -R 777 "${CLOUDREVE_V3_DIR}/data/aria2"

        # 将配置文件目录中的 docker-compose.yaml 复制到实际工作目录
        cp "${CLOUDREVE_V3_YAML_DIR}/docker-compose.yaml" "${CLOUDREVE_V3_DIR}/docker-compose.yaml"
        # 修改 docker-compose.yaml 中的服务名称
        sed -i "s|cloudreve:$|cloudreve_v3:|" "${CLOUDREVE_V3_DIR}/docker-compose.yaml"
        # 修改 docker-compose.yaml 中的容器名称
        sed -i "s|container_name: cloudreve|container_name: cloudreve_v3|" "${CLOUDREVE_V3_DIR}/docker-compose.yaml"
        # 修改 docker-compose.yaml 中的挂载路径
        sed -i "s|/usr/local/cloudreve|${CLOUDREVE_V3_DIR}|" "${CLOUDREVE_V3_DIR}/docker-compose.yaml"
        # 生成并替换 Aria2 的 RPC 密钥
        sed -i "s|your_aria_rpc_token|$(openssl rand -hex 32)|" "${CLOUDREVE_V3_DIR}/docker-compose.yaml"

        # 打印启动服务的信息
        print_info "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v3.start')"
        # 切换到 Cloudreve v3 目录并启动服务
        cd "${CLOUDREVE_V3_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V3_DIR}"
        docker compose up -d
        # 等待服务启动
        sleep 5
        # 获取并显示管理员账户信息
        get_cloudreve_v3_admin
        # 获取并显示 Aria2 Token
        get_aria2_token
    fi
}

# =============================================================================
# 函数名称: get_cloudreve_v3_admin
# 功能描述: 从 Cloudreve v3 容器日志中提取初始管理员账户信息。
# 参数: 无
# 返回值: 无 (打印管理员账户信息到 >&2)
# =============================================================================
function get_cloudreve_v3_admin() {
    # 检查名为 cloudreve_v3 的容器是否在运行
    if docker ps --format "{{.Names}}" | grep -q "^cloudreve_v3\$"; then
        # 获取容器启动日志的前 20 行
        local cloudreve_info="$(docker logs cloudreve_v3 | head -n 20)"
        # 从日志中提取用户名 (通常是第一行包含 Admin 的最后一列)
        local cloudreve_username="$(echo "${cloudreve_info}" | grep Admin | awk '{print $NF}' | head -1)"
        # 从日志中提取密码 (通常是第二行包含 Admin 的最后一列)
        local cloudreve_password="$(echo "${cloudreve_info}" | grep Admin | awk '{print $NF}' | tail -1)"
        # 打印管理员账户信息
        print_info "$(echo "$I18N_DATA" | jq -r ".docker.cloudreve_v3.admin_info" | sed "s/\${username}/${cloudreve_username}/;s/\${password}/${cloudreve_password}/")"
    fi
}

# =============================================================================
# 函数名称: get_aria2_token
# 功能描述: 从 Cloudreve v3 的 docker-compose.yaml 文件中提取 Aria2 RPC Token。
# 参数: 无
# 返回值: 无 (打印 Aria2 Token 到 >&2)
# =============================================================================
function get_aria2_token() {
    # 从 docker-compose.yaml 文件中提取 RPC_SECRET 的值
    local token="$(sed -n 's/.*RPC_SECRET=//p' "${CLOUDREVE_V3_DIR}/docker-compose.yaml")"
    # 打印 Aria2 Token 信息
    print_info "$(echo "$I18N_DATA" | jq -r ".docker.cloudreve_v3.aria2_token" | sed "s/\${token}/${token}/")"
}

# =============================================================================
# 函数名称: reset_cloudreve_v3_admin
# 功能描述: 重置 Cloudreve v3 的管理员账户。
#           通过停止服务、删除数据库文件、重启服务来实现。
# 参数: 无
# 返回值: 无 (执行重置过程)
# =============================================================================
function reset_cloudreve_v3_admin() {
    # 检查名为 cloudreve_v3 的容器是否在运行
    if docker ps --format "{{.Names}}" | grep -q "^cloudreve_v3\$"; then
        # 打印重置账户的信息
        print_info "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v3.reset')"
        # 切换到 Cloudreve v3 目录
        cd "${CLOUDREVE_V3_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V3_DIR}"
        # 停止服务
        docker compose down
        # 删除数据库文件
        rm -rf "${CLOUDREVE_V3_DIR}/cloudreve.db"
        # 重新创建空的数据库文件
        touch "${CLOUDREVE_V3_DIR}/cloudreve.db"
        # 重启服务
        docker compose up -d
        # 等待服务启动
        sleep 5
        # 获取并显示新的管理员账户信息
        get_cloudreve_v3_admin
    fi
}

# =============================================================================
# 函数名称: purge_cloudreve_v3
# 功能描述: 彻底卸载 Cloudreve v3 服务，包括停止容器和删除所有相关文件。
# 参数: 无
# 返回值: 无 (执行卸载过程)
# =============================================================================
function purge_cloudreve_v3() {
    # 检查名为 cloudreve_v3 的容器是否在运行
    if docker ps --format "{{.Names}}" | grep -q "^cloudreve_v3\$"; then
        # 打印彻底卸载的警告信息
        print_warn "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v3.purge')"
        # 切换到 Cloudreve v3 目录
        cd "${CLOUDREVE_V3_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V3_DIR}"
        # 停止服务
        docker compose down
        # 切换到用户主目录
        cd "${HOME}" || print_error "Failed to enter directory: ${HOME}"
        # 删除整个 Cloudreve v3 目录
        rm -rf "${CLOUDREVE_V3_DIR}"
    fi
}

# =============================================================================
# 函数名称: start_cloudreve_v3
# 功能描述: 启动 Cloudreve v3 服务。
#           如果服务已在运行则跳过；如果目录不存在则尝试安装。
# 参数: 无
# 返回值: 无 (执行启动过程)
# =============================================================================
function start_cloudreve_v3() {
    # 检查名为 cloudreve_v3 的容器是否未在运行
    if ! docker ps --format "{{.Names}}" | grep -q "^cloudreve_v3\$"; then
        # 检查 Cloudreve v3 目录是否存在
        if [[ -d "${CLOUDREVE_V3_DIR}" ]]; then
            # 打印启动服务的信息
            print_info "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v3.start_service')"
            # 切换到 Cloudreve v3 目录并启动服务
            cd "${CLOUDREVE_V3_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V3_DIR}"
            docker compose up -d
        else
            # 如果目录不存在，打印回退安装的信息
            print_info "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v3.install_fallback')"
            # 调用安装函数
            install_cloudreve_v3
        fi
    fi
}

# =============================================================================
# 函数名称: stop_cloudreve_v3
# 功能描述: 停止 Cloudreve v3 服务。
# 参数: 无
# 返回值: 无 (执行停止过程)
# =============================================================================
function stop_cloudreve_v3() {
    # 检查名为 cloudreve_v3 的容器是否在运行
    if docker ps --format "{{.Names}}" | grep -q "^cloudreve_v3\$"; then
        # 打印停止服务的警告信息
        print_warn "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v3.stop')"
        # 切换到 Cloudreve v3 目录
        cd "${CLOUDREVE_V3_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V3_DIR}"
        # 停止服务
        docker compose down
    fi
}

# =============================================================================
# 函数名称: install_cloudreve_v4
# 功能描述: 安装并启动 Cloudreve v4 服务。
#           创建必要的目录，配置 docker-compose.yaml，并启动服务。
# 参数: 无
# 返回值: 无 (执行安装和启动过程)
# =============================================================================
function install_cloudreve_v4() {
    # 检查名为 cloudreve_v4 的容器是否已在运行
    if ! docker ps --format "{{.Names}}" | grep -q "^cloudreve_v4\$"; then
        # 打印创建目录的信息
        print_info "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v4.create_dir')"
        # 创建 Cloudreve v4 目录
        mkdir -vp ${CLOUDREVE_V4_DIR}
        # 将配置文件目录中的 docker-compose.yaml 复制到实际工作目录
        cp "${CLOUDREVE_V4_YAML_DIR}/docker-compose.yaml" "${CLOUDREVE_V4_DIR}/docker-compose.yaml"
        # 修改 docker-compose.yaml 中的服务名称
        sed -i "s|cloudreve:$|cloudreve_v4:|" "${CLOUDREVE_V4_DIR}/docker-compose.yaml"
        # 修改 docker-compose.yaml 中的容器名称
        sed -i "s|container_name: cloudreve-backend|container_name: cloudreve_v4|" "${CLOUDREVE_V4_DIR}/docker-compose.yaml"

        # 打印启动服务的信息
        print_info "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v4.start')"
        # 切换到 Cloudreve v4 目录并启动服务
        cd "${CLOUDREVE_V4_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V4_DIR}"
        docker compose up -d
    fi
}

# =============================================================================
# 函数名称: update_cloudreve_v4
# 功能描述: 更新 Cloudreve v4 服务。
#           通过停止服务、拉取最新镜像、重启服务来实现。
# 参数: 无
# 返回值: 无 (执行更新过程)
# =============================================================================
function update_cloudreve_v4() {
    # 检查名为 cloudreve_v4 的容器是否在运行
    if docker ps --format "{{.Names}}" | grep -q "^cloudreve_v4\$"; then
        # 打印更新服务的信息
        print_info "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v4.update')"
        # 切换到 Cloudreve v4 目录
        cd "${CLOUDREVE_V4_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V4_DIR}"
        # 停止服务
        docker compose down
        # 拉取最新的镜像
        docker compose pull
        # 重启服务
        docker compose up -d
    fi
}

# =============================================================================
# 函数名称: purge_cloudreve_v4
# 功能描述: 彻底卸载 Cloudreve v4 服务，包括停止容器和删除所有相关文件。
# 参数: 无
# 返回值: 无 (执行卸载过程)
# =============================================================================
function purge_cloudreve_v4() {
    # 检查名为 cloudreve_v4 的容器是否在运行
    if docker ps --format "{{.Names}}" | grep -q "^cloudreve_v4\$"; then
        # 打印彻底卸载的警告信息
        print_warn "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v4.purge')"
        # 切换到 Cloudreve v4 目录
        cd "${CLOUDREVE_V4_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V4_DIR}"
        # 停止服务
        docker compose down
        # 切换到用户主目录
        cd "${HOME}" || print_error "Failed to enter directory: ${HOME}"
        # 删除整个 Cloudreve v4 目录
        rm -rf "${CLOUDREVE_V4_DIR}"
    fi
}

# =============================================================================
# 函数名称: start_cloudreve_v4
# 功能描述: 启动 Cloudreve v4 服务。
#           如果服务已在运行则跳过；如果目录不存在则尝试安装。
# 参数: 无
# 返回值: 无 (执行启动过程)
# =============================================================================
function start_cloudreve_v4() {
    # 检查名为 cloudreve_v4 的容器是否未在运行
    if ! docker ps --format "{{.Names}}" | grep -q "^cloudreve_v4\$"; then
        # 检查 Cloudreve v4 目录是否存在
        if [[ -d "${CLOUDREVE_V4_DIR}" ]]; then
            # 打印启动服务的信息
            print_info "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v4.start_service')"
            # 切换到 Cloudreve v4 目录并启动服务
            cd "${CLOUDREVE_V4_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V4_DIR}"
            docker compose up -d
        else
            # 如果目录不存在，打印回退安装的信息
            print_info "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v4.install_fallback')"
            # 调用安装函数
            install_cloudreve_v4
        fi
    fi
}

# =============================================================================
# 函数名称: stop_cloudreve_v4
# 功能描述: 停止 Cloudreve v4 服务。
# 参数: 无
# 返回值: 无 (执行停止过程)
# =============================================================================
function stop_cloudreve_v4() {
    # 检查名为 cloudreve_v4 的容器是否在运行
    if docker ps --format "{{.Names}}" | grep -q "^cloudreve_v4\$"; then
        # 打印停止服务的警告信息
        print_warn "$(echo "$I18N_DATA" | jq -r '.docker.cloudreve_v4.stop')"
        # 切换到 Cloudreve v4 目录
        cd "${CLOUDREVE_V4_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V4_DIR}"
        # 停止服务
        docker compose down
    fi
}

# =============================================================================
# 函数名称: clean_container_logs
# 功能描述: 清空指定容器日志数据。
# 参数:
#   $1: 容器名称或 ID（默认清空 warp 日志记录）
# 返回值: 无 (执行清理过程)
# =============================================================================
function clean_container_logs() {
    # 获取容器名称或 ID
    local container_name_or_id="${1:-xray-script-warp}"
    local log_path=''
    if ! docker inspect "${container_name_or_id}" >/dev/null 2>&1; then
        return 0
    fi
    log_path="$(docker inspect --format='{{.LogPath}}' "${container_name_or_id}" 2>/dev/null)" || return 1
    [[ -z "${log_path}" || ! -e "${log_path}" ]] && return 0
    truncate -s 0 -- "${log_path}"
}

# =============================================================================
# 函数名称: obtain_container_ip
# 功能描述: 获取容器 IP 地址。
# 参数: 
#   $1: 容器名称（默认获取 warp 容器 IP 地址）
# 返回值: 容器的 IP 地址 (echo 输出)，或无输出
# =============================================================================
function obtain_container_ip() {
    # 获取容器名称
    local container_name="${1:-xray-script-warp}"
    # 获取容器的 IP 地址
    [[ "$(docker inspect --format='{{.State.Running}}' "${container_name}" 2>/dev/null)" == 'true' ]] || return 1
    local container_ip=''
    container_ip="$(get_container_ip "${container_name}")" || return 1
    [[ -n "${container_ip}" ]] || return 1
    printf '%s\n' "${container_ip}"
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 根据传入的第一个参数 (option) 调用相应的管理函数。
# 参数:
#   $@: 所有命令行参数
# 返回值: 无 (调用具体函数执行相应操作)
# =============================================================================
function main() {
    # 加载国际化数据
    load_i18n

    # 使用 case 语句根据选项调用对应的函数
    case "${1,,}" in                                        # ${1,,} 将第一个参数转换为小写
    --install) install_docker ;;                            # 安装 Docker
    --build-warp) build_warp ;;                             # 构建 WARP 镜像
    --enable-warp) enable_warp ;;                           # 启用 WARP 容器
    --disable-warp) disable_warp ;;                         # 禁用 WARP 容器
    --prepare-reset-warp) prepare_warp_reset ;;             # 构建并暂存新的 WARP 容器
    --commit-reset-warp) commit_warp_reset ;;               # 提交 WARP 重建事务
    --rollback-reset-warp) rollback_warp_reset ;;           # 回滚 WARP 重建事务
    --install-cloudreve-v3) install_cloudreve_v3 ;;         # 安装 Cloudreve v3
    --get-cloudreve-v3-admin) get_cloudreve_v3_admin ;;     # 获取 Cloudreve v3 管理员信息
    --get-aria2-token) get_aria2_token ;;                   # 获取 Cloudreve v3 Aria2 Token
    --reset-cloudreve-v3-admin) reset_cloudreve_v3_admin ;; # 重置 Cloudreve v3 管理员
    --purge-cloudreve-v3) purge_cloudreve_v3 ;;             # 彻底卸载 Cloudreve v3
    --start-cloudreve-v3) start_cloudreve_v3 ;;             # 启动 Cloudreve v3
    --stop-cloudreve-v3) stop_cloudreve_v3 ;;               # 停止 Cloudreve v3
    --install-cloudreve-v4) install_cloudreve_v4 ;;         # 安装 Cloudreve v4
    --update-cloudreve-v4) update_cloudreve_v4 ;;           # 更新 Cloudreve v4
    --purge-cloudreve-v4) purge_cloudreve_v4 ;;             # 彻底卸载 Cloudreve v4
    --start-cloudreve-v4) start_cloudreve_v4 ;;             # 启动 Cloudreve v4
    --stop-cloudreve-v4) stop_cloudreve_v4 ;;               # 停止 Cloudreve v4
    --clean-container-logs) clean_container_logs $2 ;;      # 清空容器日志文件
    --obtain-container-ip) obtain_container_ip $2 ;;        # 获取容器 IP 地址
    esac
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
