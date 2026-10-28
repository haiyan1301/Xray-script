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

# 复用统一的子库（i18n 取值 / 日志 / 系统探测）。它们只定义函数，不定义颜色、
# PATH 等常量，因此不与本脚本自己的 readonly 定义冲突。
source "${PROJECT_ROOT}/lib/i18n.sh"
source "${PROJECT_ROOT}/lib/log.sh"
source "${PROJECT_ROOT}/lib/system.sh"
# 事务调度骨架（trap 注册 / 信号码）与 core/main.sh、service/ssl.sh、
# service/nginx.sh 共用，见 lib/transaction.sh。
source "${PROJECT_ROOT}/lib/transaction.sh"

# --- 全局变量声明 ---
# 声明用于存储语言参数和国际化数据的全局变量
declare LANG_PARAM='' # (未在脚本中实际使用，可能是预留)


# print_info / print_warn / print_error 由 lib/log.sh 统一提供。
# _os / _os_full / _os_ver 由 lib/system.sh 统一提供。

# =============================================================================
# 函数名称: install_docker
# 功能描述: 从官方脚本安装 Docker。针对特定系统 (如 CentOS 8) 进行适配。
# 参数: 无
# 返回值: 无 (执行安装过程，失败时会调用 print_error 退出)
# =============================================================================
function install_docker() (
    # 打印开始安装的信息
    print_info "$(t '.docker.install.start')"

    # 下载到临时文件：固定路径的 install-docker.sh 一旦下载失败会残留上次的内容，
    # 之后无检查地执行它等于静默运行旧脚本。
    local installer
    installer="$(mktemp "${TMPDIR:-/tmp}/install-docker.XXXXXX")" || return 1
    trap 'rm -f -- "${installer}"' EXIT

    if ! wget -O "${installer}" https://get.docker.com; then
        print_error "$(t '.docker.install.download_fail')"
    fi

    # 检查是否为 CentOS 8 系统
    if [[ "$(_os)" == "centos" && "$(_os_ver)" -eq 8 ]]; then
        # 打印针对 CentOS 8 的修复信息
        print_info "$(t '.docker.install.centos8_fix')"
        # 修改安装脚本，在安装命令中添加 --allowerasing 选项以解决依赖冲突
        sed -i 's|$sh_c "$pkg_manager install -y -q $pkgs"| $sh_c "$pkg_manager install -y -q $pkgs --allowerasing"|' "${installer}"
    fi

    # 打印运行前检查的信息
    print_info "$(t '.docker.install.dry_run')"
    # 执行安装脚本的 --dry-run 模式进行检查；预检查失败就不要继续安装
    if ! sh "${installer}" --dry-run; then
        print_error "$(t '.docker.install.dry_run_fail')"
    fi

    # 打印正式运行安装的信息
    print_info "$(t '.docker.install.running')"
    # 执行安装脚本进行实际安装
    if ! sh "${installer}"; then
        print_error "$(t '.docker.install.run_fail')"
    fi

    # 安装脚本返回 0 不代表 docker 真的装上了
    cmd_exists docker ||
        print_error "$(t '.docker.install.verify_fail')"
)

# =============================================================================
# 函数名称: list_container_ips
# 功能描述: 按 IPv4、IPv6 顺序列出指定 Docker 容器的唯一 IP 地址。
# 参数:
#   $1: 容器名称或 ID (container_name)
# 返回值: 容器的 IP 地址列表（每行一个）
# =============================================================================
function list_container_ips() {
    local container_name="$1"
    local networks

    networks="$(docker inspect --format='{{json .NetworkSettings.Networks}}' "${container_name}" 2>/dev/null)" || return 1
    printf '%s\n' "${networks}" | jq -er '
        to_entries | sort_by(.key) | map(.value) as $networks |
        (
            [$networks[].IPAddress | select(type == "string" and length > 0)] +
            [$networks[].GlobalIPv6Address | select(type == "string" and length > 0)]
        ) |
        reduce .[] as $address
            ([]; if index($address) == null then . + [$address] else . end) |
        .[]
    '
}

function probe_tcp_port() (
    local address="$1"
    local port="$2"
    local probe_pid='' attempt status

    function cleanup_tcp_probe() {
        local exit_status=$?

        trap - EXIT HUP INT TERM
        if [[ -n "${probe_pid}" ]]; then
            kill -TERM "${probe_pid}" 2>/dev/null || true
            wait "${probe_pid}" >/dev/null 2>&1 || true
        fi
        exit "${exit_status}"
    }

    trap cleanup_tcp_probe EXIT
    trap 'exit 1' HUP INT TERM

    (
        exec 3<>"/dev/tcp/${address}/${port}"
    ) >/dev/null 2>&1 &
    probe_pid=$!

    for ((attempt = 0; attempt < 10; attempt++)); do
        if ! kill -0 "${probe_pid}" 2>/dev/null; then
            if wait "${probe_pid}" >/dev/null 2>&1; then
                status=0
            else
                status=$?
            fi
            probe_pid=''
            return "${status}"
        fi
        sleep 0.1
    done

    kill -TERM "${probe_pid}" 2>/dev/null || true
    wait "${probe_pid}" >/dev/null 2>&1 || true
    probe_pid=''
    return 1
)

function wait_for_warp() {
    local container_name="$1"
    local container_ip='' addresses=''
    local deadline=$((SECONDS + 30))

    while ((SECONDS < deadline)); do
        if [[ "$(docker inspect --format='{{.State.Running}}' "${container_name}" 2>/dev/null)" == 'true' ]]; then
            addresses="$(list_container_ips "${container_name}" 2>/dev/null || true)"
            while IFS= read -r container_ip; do
                [[ -n "${container_ip}" ]] || continue
                if probe_tcp_port "${container_ip}" 40001; then
                    printf '%s\n' "${container_ip}"
                    return 0
                fi
                ((SECONDS < deadline)) || return 1
            done <<<"${addresses}"
        fi
        ((SECONDS < deadline)) && sleep 1
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
        print_info "$(t '.docker.warp.build.start')"
        # 使用 docker build 命令构建镜像，失败则调用 print_error 退出
        docker build -t xray-script-warp "${CONFIG_DIR}/cloudflare-warp" || print_error "$(t '.docker.warp.build.fail')"
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
    print_info "$(t '.docker.warp.enable.start')"
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
        print_error "$(t '.docker.warp.build.fail')"
        return 1
    }
    print_info "$(t ".docker.warp.enable.success" | sed "s/\${container_ip}/${container_ip}/")"
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
        print_warn "$(t '.docker.warp.disable.stop')"
        docker stop xray-script-warp >/dev/null || return 1
    fi
    print_info "$(t '.docker.warp.disable.success')"
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

        txn_finish_enter
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

    # 事务调度骨架在 lib/transaction.sh；回滚体 rollback_warp_reset 留在本函数。
    txn_begin finish_warp_reset_preparation

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

    print_info "$(t '.docker.warp.build.start')"
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
# 函数名称: cloudreve_installed
# 功能描述: 判断 Cloudreve 是否已经装过：容器（含已停止）或 compose 文件存在即算。
#           只看运行态会在 stop（compose down 删掉容器）之后把已有安装误判成未安装，
#           重新安装会覆盖 compose 文件——Aria2 RPC 密钥会被重新随机，已配置的客户端
#           全部失联。
# 参数:
#   $1: 项目目录
#   $2: 主容器名
# 返回值: 0-已安装 1-未安装
# =============================================================================
function cloudreve_installed() {
    local dir="$1"
    local container="$2"
    [[ -f "${dir}/docker-compose.yaml" ]] && return 0
    docker ps -a --format "{{.Names}}" | grep -q "^${container}\$"
}

# =============================================================================
# 函数名称: cloudreve_project_present
# 功能描述: 判断 Cloudreve 项目是否还留有东西：容器（含已停止）或项目目录存在即算。
#           stop 用 compose down 删掉容器后，目录、绑定挂载和 named volume 都还在磁盘
#           上；只看容器会让 purge/update 静默什么都不做，与「彻底卸载」不符。
# 参数:
#   $1: 项目目录
#   $2: 主容器名
# 返回值: 0-存在 1-不存在
# =============================================================================
function cloudreve_project_present() {
    local dir="$1"
    local container="$2"
    [[ -d "${dir}" ]] && return 0
    docker ps -a --format "{{.Names}}" | grep -q "^${container}\$"
}

# =============================================================================
# 函数名称: wait_container_running
# 功能描述: 等待指定容器稳定处于 running 状态。
#           `docker compose up -d` 只要容器被创建并启动就返回 0；容器随后崩溃、
#           反复重启（compose 里写着 restart: unless-stopped）时它照样返回 0。安装流程
#           据此打印「初始管理员账户」并上报成功，用户拿到的却是空的账号密码和一个
#           起不来的服务。
#           所以 up -d 之后必须再看一眼容器的真实状态，而且不能只看一瞬间：
#           崩溃循环里的容器会有短暂的 running 窗口，因此要求**连续 stable 秒**都是
#           running 才算就绪（用 SECONDS 计时，不是数循环次数；同时也替掉了原来盲目
#           的 sleep 5）。
#           容器名找不到时退回按 compose 项目查运行态容器：用户若在 compose 文件里
#           改过 container_name，只认写死的名字会让这里空等 30 秒后误报启动失败。
# 参数:
#   $1: 容器名
#   $2: 超时秒数（默认 30）
#   $3: 需要连续 running 的秒数（默认 5）
# 返回值: 0-已稳定运行 1-超时/容器不存在/一直在重启
# =============================================================================
function wait_container_running() {
    local container="$1"
    local timeout="${2:-30}"
    local stable_need="${3:-5}"
    local deadline=$((SECONDS + timeout))
    local stable_since='' status=''

    while :; do
        status="$(docker inspect --format='{{.State.Status}}' "${container}" 2>/dev/null)" || status=''
        # 容器名对不上（用户改过 container_name）：按当前目录的 compose 项目找运行态容器
        if [[ -z "${status}" ]] && [[ -n "$(docker compose ps --status running --format '{{.Name}}' 2>/dev/null || true)" ]]; then
            status='running'
        fi
        if [[ "${status}" == 'running' ]]; then
            [[ -n "${stable_since}" ]] || stable_since="${SECONDS}"
            if ((SECONDS - stable_since >= stable_need)); then
                return 0
            fi
        else
            stable_since=''
        fi
        ((SECONDS < deadline)) || return 1
        sleep 1
    done
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
    # 已装过就跳过：容器（含已停止）或 compose 文件存在都算已安装。
    if ! cloudreve_installed "${CLOUDREVE_V3_DIR}" 'cloudreve_v3'; then
        # 打印创建目录的信息
        print_info "$(t '.docker.cloudreve_v3.create_dir')"
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
        print_info "$(t '.docker.cloudreve_v3.start')"
        # 切换到 Cloudreve v3 目录并启动服务；启动失败必须中止，否则会继续
        # 打印一份并不存在的「初始管理员账户」。
        cd "${CLOUDREVE_V3_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V3_DIR}"
        docker compose up -d || print_error "$(t '.docker.cloudreve_v3.up_fail')"
        # up -d 返回 0 只说明容器被启动了，不代表服务真的起来；容器崩溃重启时它照样返回 0。
        # 必须等容器稳定运行，否则下面会打印一份空的「初始管理员账户」并把安装当成成功。
        wait_container_running 'cloudreve_v3' || print_error "$(t '.docker.cloudreve_v3.up_fail')"
        # 获取并显示管理员账户信息
        get_cloudreve_v3_admin
        # 获取并显示 Aria2 Token
        get_aria2_token
    else
        # 跳过也要说一声：否则用户选了「安装」却没有任何输出，看起来像菜单项坏了。
        print_info "$(t '.docker.cloudreve_v3.already_installed')"
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
        print_info "$(t ".docker.cloudreve_v3.admin_info" | sed "s/\${username}/${cloudreve_username}/;s/\${password}/${cloudreve_password}/")"
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
    print_info "$(t ".docker.cloudreve_v3.aria2_token" | sed "s/\${token}/${token}/")"
}

# =============================================================================
# 函数名称: reset_cloudreve_v3_admin
# 功能描述: 重置 Cloudreve v3 的管理员账户。
#           通过停止服务、删除数据库文件、重启服务来实现。
# 参数: 无
# 返回值: 无 (执行重置过程)
# =============================================================================
function reset_cloudreve_v3_admin() {
    # 容器存在（含已停止）即可重置：用 docker ps 只看运行态会让「停止后再重置」静默无操作。
    if docker ps -a --format "{{.Names}}" | grep -q "^cloudreve_v3\$"; then
        # Cloudreve v3 没有官方的管理员重置命令，这里只能重建整个数据库：
        # 先把影响范围说清楚，再备份，避免用户以为只是改个密码。
        print_warn "$(t '.docker.cloudreve_v3.reset_scope')"
        # 整库重建不可回滚，必须显式确认。非交互环境直接拒绝——不能把 EOF 当成默认同意
        # （与 handler_purge 的卸载确认同一套约定）。
        local confirm=''
        if [[ ! -t 0 ]]; then
            print_error "$(t '.docker.cloudreve_v3.reset_tty_required')"
            return 1
        fi
        read -r -p "$(t '.docker.cloudreve_v3.reset_confirm'): " confirm
        if [[ "${confirm}" != 'yes' ]]; then
            print_info "$(t '.docker.cloudreve_v3.reset_cancelled')"
            return 0
        fi
        # 打印重置账户的信息
        print_info "$(t '.docker.cloudreve_v3.reset')"
        # 切换到 Cloudreve v3 目录
        cd "${CLOUDREVE_V3_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V3_DIR}"
        # 停止服务；停不下来就不要动数据库
        docker compose down || print_error "$(t '.docker.cloudreve_v3.down_fail')"
        # 删除数据库前先留一份带时间戳的备份
        if [[ -e "${CLOUDREVE_V3_DIR}/cloudreve.db" ]]; then
            cp -a -- "${CLOUDREVE_V3_DIR}/cloudreve.db" \
                "${CLOUDREVE_V3_DIR}/cloudreve.db.bak.$(date +%Y%m%d_%H%M%S)" ||
                print_error "$(t '.docker.cloudreve_v3.reset_backup_fail')"
        fi
        # 删除数据库文件
        rm -rf "${CLOUDREVE_V3_DIR}/cloudreve.db"
        # 重新创建空的数据库文件
        touch "${CLOUDREVE_V3_DIR}/cloudreve.db"
        # 重启服务
        docker compose up -d || print_error "$(t '.docker.cloudreve_v3.up_fail')"
        # 同 install_cloudreve_v3：等容器稳定运行，否则会打印空的账户信息
        wait_container_running 'cloudreve_v3' || print_error "$(t '.docker.cloudreve_v3.up_fail')"
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
    # 项目还在（目录或容器）就卸载：stop 之后容器已被 compose down 删除，只看容器
    # 会让「停止后再卸载」静默什么都不做，目录和数据全部留在磁盘上。
    if cloudreve_project_present "${CLOUDREVE_V3_DIR}" 'cloudreve_v3'; then
        # 打印彻底卸载的警告信息
        print_warn "$(t '.docker.cloudreve_v3.purge')"
        # 只有 compose 文件还在才做 compose 操作：目录或文件被人删掉时 `docker compose
        # down -v` 会直接报错退出，named volume 反而被留在 Docker 里。
        if [[ -f "${CLOUDREVE_V3_DIR}/docker-compose.yaml" ]]; then
            # 切换到 Cloudreve v3 目录
            cd "${CLOUDREVE_V3_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V3_DIR}"
            # 停止服务并删除本项目声明的 named volume（temp_data，bind 到
            # ${CLOUDREVE_V3_DIR}/data）。只删目录的话 Docker 里会留下一个指向已删除路径的
            # 悬空卷，与「彻底卸载」不符；数据本身就在项目目录下，同样会被 rm -rf 清掉。
            docker compose down -v
            # 切换到用户主目录
            cd "${HOME}" || print_error "Failed to enter directory: ${HOME}"
        fi
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
            print_info "$(t '.docker.cloudreve_v3.start_service')"
            # 切换到 Cloudreve v3 目录并启动服务
            cd "${CLOUDREVE_V3_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V3_DIR}"
            docker compose up -d || print_error "$(t '.docker.cloudreve_v3.up_fail')"
            # 等容器稳定运行，别把「启动命令成功」当成「服务已就绪」
            wait_container_running 'cloudreve_v3' || print_error "$(t '.docker.cloudreve_v3.up_fail')"
        else
            # 如果目录不存在，打印回退安装的信息
            print_info "$(t '.docker.cloudreve_v3.install_fallback')"
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
    # 容器存在（含已停止）就执行 compose down：`docker ps` 只看运行态会漏掉两种
    # 需要清理的情况——主容器已停止（容器与网络仍在）和主容器已退出但配套容器还在。
    # compose down 对已停止的项目是幂等的。
    if docker ps -a --format "{{.Names}}" | grep -q "^cloudreve_v3\$"; then
        # 打印停止服务的警告信息
        print_warn "$(t '.docker.cloudreve_v3.stop')"
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
    # 已装过就跳过：容器（含已停止）或 compose 文件存在都算已安装。
    if ! cloudreve_installed "${CLOUDREVE_V4_DIR}" 'cloudreve_v4'; then
        # 打印创建目录的信息
        print_info "$(t '.docker.cloudreve_v4.create_dir')"
        # 创建 Cloudreve v4 目录
        mkdir -vp ${CLOUDREVE_V4_DIR}
        # 将配置文件目录中的 docker-compose.yaml 复制到实际工作目录
        cp "${CLOUDREVE_V4_YAML_DIR}/docker-compose.yaml" "${CLOUDREVE_V4_DIR}/docker-compose.yaml"
        # 修改 docker-compose.yaml 中的服务名称
        sed -i "s|cloudreve:$|cloudreve_v4:|" "${CLOUDREVE_V4_DIR}/docker-compose.yaml"
        # 修改 docker-compose.yaml 中的容器名称
        sed -i "s|container_name: cloudreve-backend|container_name: cloudreve_v4|" "${CLOUDREVE_V4_DIR}/docker-compose.yaml"

        # 打印启动服务的信息
        print_info "$(t '.docker.cloudreve_v4.start')"
        # 切换到 Cloudreve v4 目录并启动服务
        cd "${CLOUDREVE_V4_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V4_DIR}"
        docker compose up -d || print_error "$(t '.docker.cloudreve_v4.up_fail')"
        # 同 install_cloudreve_v3：等容器稳定运行，别把「启动命令成功」当成「服务已就绪」
        wait_container_running 'cloudreve_v4' || print_error "$(t '.docker.cloudreve_v4.up_fail')"
    else
        # 跳过也要说一声，理由同 install_cloudreve_v3。
        print_info "$(t '.docker.cloudreve_v4.already_installed')"
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
    # 项目还在（目录或容器）就更新：拉取新镜像后 up -d 会顺带把服务拉起来。
    if cloudreve_project_present "${CLOUDREVE_V4_DIR}" 'cloudreve_v4'; then
        # 打印更新服务的信息
        print_info "$(t '.docker.cloudreve_v4.update')"
        # 切换到 Cloudreve v4 目录
        cd "${CLOUDREVE_V4_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V4_DIR}"
        # 停止服务
        docker compose down
        # 拉取最新的镜像
        docker compose pull
        # 重启服务
        docker compose up -d || print_error "$(t '.docker.cloudreve_v4.up_fail')"
        # 新镜像起不来（配置不兼容、卷损坏）时 up -d 仍返回 0，这里必须验证容器真的在跑
        wait_container_running 'cloudreve_v4' || print_error "$(t '.docker.cloudreve_v4.up_fail')"
    fi
}

# =============================================================================
# 函数名称: purge_cloudreve_v4
# 功能描述: 彻底卸载 Cloudreve v4 服务，包括停止容器和删除所有相关文件。
# 参数: 无
# 返回值: 无 (执行卸载过程)
# =============================================================================
function purge_cloudreve_v4() {
    # 项目还在（目录或容器）就卸载，理由同 purge_cloudreve_v3。
    if cloudreve_project_present "${CLOUDREVE_V4_DIR}" 'cloudreve_v4'; then
        # 打印彻底卸载的警告信息
        print_warn "$(t '.docker.cloudreve_v4.purge')"
        # 只有 compose 文件还在才做 compose 操作，理由同 purge_cloudreve_v3。
        if [[ -f "${CLOUDREVE_V4_DIR}/docker-compose.yaml" ]]; then
            # 切换到 Cloudreve v4 目录
            cd "${CLOUDREVE_V4_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V4_DIR}"
            # 停止服务并删除本项目的数据卷。`docker compose down` 默认保留 named volume
            # （backend_data / database_postgres / redis_data），只删项目目录的话它们仍留在
            # /var/lib/docker/volumes 下，同项目重装会带回旧账号与数据库——与「彻底卸载」
            # 不符。`-v` 只删除本 compose 项目声明的卷，不会碰其它项目的 Docker 数据。
            docker compose down -v
            # 切换到用户主目录
            cd "${HOME}" || print_error "Failed to enter directory: ${HOME}"
        fi
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
            print_info "$(t '.docker.cloudreve_v4.start_service')"
            # 切换到 Cloudreve v4 目录并启动服务
            cd "${CLOUDREVE_V4_DIR}" || print_error "Failed to enter directory: ${CLOUDREVE_V4_DIR}"
            docker compose up -d || print_error "$(t '.docker.cloudreve_v4.up_fail')"
            # 等容器稳定运行，别把「启动命令成功」当成「服务已就绪」
            wait_container_running 'cloudreve_v4' || print_error "$(t '.docker.cloudreve_v4.up_fail')"
        else
            # 如果目录不存在，打印回退安装的信息
            print_info "$(t '.docker.cloudreve_v4.install_fallback')"
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
    # 容器存在（含已停止）就执行 compose down，理由同 stop_cloudreve_v3。
    if docker ps -a --format "{{.Names}}" | grep -q "^cloudreve_v4\$"; then
        # 打印停止服务的警告信息
        print_warn "$(t '.docker.cloudreve_v4.stop')"
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
# 功能描述: 获取 WARP 容器中当前可连接代理端口的 IP 地址。
# 参数: 
#   $1: 容器名称（默认获取 warp 容器 IP 地址）
# 返回值: 可连接 WARP 代理的容器 IP 地址，或无输出
# =============================================================================
function obtain_container_ip() {
    # 获取容器名称
    local container_name="${1:-xray-script-warp}"
    # 获取容器的 IP 地址
    [[ "$(docker inspect --format='{{.State.Running}}' "${container_name}" 2>/dev/null)" == 'true' ]] || return 1
    local container_ip=''
    container_ip="$(wait_for_warp "${container_name}")" || return 1
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
    --obtain-container-ip) obtain_container_ip "$2" ;;      # 获取可连接的 WARP 容器 IP 地址
    esac
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
