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


# --- WARP 容器 / 镜像 / 端点常量 ---
# 容器名与镜像名沿用旧版本（升级时可直接接管）；宿主端点固定发布在
# 127.0.0.1:40001，Xray 出站不再依赖会漂移的容器 IP。
readonly WARP_NAME='xray-script-warp'                                  # 容器名
readonly WARP_IMAGE='xray-script-warp:latest'                          # 镜像名
readonly WARP_RESET_IMAGE='xray-script-warp:reset-new'                 # 重置事务的新镜像 tag
readonly WARP_BACKUP_IMAGE='xray-script-warp:reset-backup'             # 重置事务的旧镜像备份 tag
readonly WARP_BACKUP_RUNNING='xray-script-warp-reset-backup-running'   # 重置前运行中容器的备份名
readonly WARP_BACKUP_STOPPED='xray-script-warp-reset-backup-stopped'   # 重置前已停止容器的备份名
readonly WARP_HOST='127.0.0.1'                                         # 宿主回环端点
readonly WARP_PORT='40001'                                             # SOCKS 代理端口
readonly WARP_ASSETS_LABEL='xray-script-warp.assets'                   # 镜像构建源文件指纹 label
readonly WARP_BUILD_CONTEXT="${CONFIG_DIR}/cloudflare-warp"            # 镜像构建上下文
readonly WARP_TRANSACTION_DIR="${DOCKER_DIR}/.warp-reset-transaction"  # 重置事务目录

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
# 函数名称: warp_assets_hash
# 功能描述: 计算 WARP 镜像构建源文件的内容指纹。
#           startup.sh / healthcheck.sh 是构建期 COPY 进镜像的，镜像一旦构建就
#           不会随脚本升级自动更新；用 sha256(Dockerfile+startup.sh+healthcheck.sh)
#           作为镜像 label，build_warp 据此判断是否需要重建（W2）。
# 参数: 无
# 返回值: 0-输出十六进制指纹；1-构建上下文缺少全部源文件
# =============================================================================
function warp_assets_hash() {
    local assets_dir="${WARP_BUILD_CONTEXT}"
    local -a asset_files=()
    local asset_file='' assets_hash=''

    for asset_file in Dockerfile startup.sh healthcheck.sh; do
        [[ -f "${assets_dir}/${asset_file}" ]] && asset_files+=("${assets_dir}/${asset_file}")
    done
    [[ "${#asset_files[@]}" -gt 0 ]] || return 1
    assets_hash="$(cat -- "${asset_files[@]}" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')" || return 1
    [[ -n "${assets_hash}" ]] || return 1
    printf '%s\n' "${assets_hash}"
}

# =============================================================================
# 函数名称: _warp_image_id
# 功能描述: 读取 WARP latest 镜像的镜像 ID。
# 参数: 无
# 返回值: 0-输出镜像 ID；1-镜像不存在
# =============================================================================
function _warp_image_id() {
    local image_id=''

    image_id="$(docker image inspect --format='{{.Id}}' "${WARP_IMAGE}" 2>/dev/null)" || return 1
    [[ -n "${image_id}" ]] || return 1
    printf '%s\n' "${image_id}"
}

# =============================================================================
# 函数名称: _warp_image_assets_label
# 功能描述: 读取 WARP latest 镜像的构建源文件指纹 label。
# 参数: 无
# 返回值: 0-输出指纹；1-镜像不存在/没有该 label
# =============================================================================
function _warp_image_assets_label() {
    local label=''

    label="$(docker image inspect --format="{{index .Config.Labels \"${WARP_ASSETS_LABEL}\"}}" "${WARP_IMAGE}" 2>/dev/null)" || return 1
    case "${label}" in
    '' | '<no value>' | 'null') return 1 ;;
    esac
    printf '%s\n' "${label}"
}

# =============================================================================
# 函数名称: _warp_container_state
# 功能描述: 返回 WARP 容器状态：missing / running / stopped。
#           只凭 docker inspect 判定；docker daemon 是否可用由调用方先用
#           docker_ready / _warp_status 区分，避免把 daemon 故障当成容器不存在。
# 参数:
#   $1: 容器名（默认 WARP_NAME）
# 返回值: 0（状态写到 stdout）
# =============================================================================
# shellcheck disable=SC2120 # 可选参数 $1 仅用于测试/复用，生产调用方不传参
function _warp_container_state() {
    local container_name="${1:-${WARP_NAME}}"
    local container_status=''

    container_status="$(docker inspect --format='{{.State.Status}}' "${container_name}" 2>/dev/null)" || {
        printf 'missing\n'
        return 0
    }
    case "${container_status}" in
    running | restarting | paused) printf 'running\n' ;;
    *) printf 'stopped\n' ;;
    esac
}

# =============================================================================
# 函数名称: _warp_container_matches_image
# 功能描述: 判断容器是否由当前 latest 镜像创建（镜像 ID 一致）。
#           镜像重建后旧容器仍引用旧镜像，仅凭容器名与运行态发现不了（W2）。
# 参数:
#   $1: 容器名（默认 WARP_NAME）
# 返回值: 0-一致；1-不一致/查询失败
# =============================================================================
function _warp_container_matches_image() {
    local container_name="${1:-${WARP_NAME}}"
    local container_image='' image_id=''

    container_image="$(docker inspect --format='{{.Image}}' "${container_name}" 2>/dev/null)" || return 1
    image_id="$(_warp_image_id)" || return 1
    [[ -n "${container_image}" && "${container_image}" == "${image_id}" ]]
}

# =============================================================================
# 函数名称: _warp_container_uses_image
# 功能描述: 判断容器使用的镜像是否与指定镜像引用（tag/ID）一致。
#           回滚时用来区分「事务新建的容器」与「尚未被替换的旧容器」，避免误删。
# 参数:
#   $1: 容器名
#   $2: 镜像引用
# 返回值: 0-一致；1-不一致/查询失败
# =============================================================================
function _warp_container_uses_image() {
    local container_name="$1"
    local image_ref="$2"
    local container_image='' image_id=''

    container_image="$(docker inspect --format='{{.Image}}' "${container_name}" 2>/dev/null)" || return 1
    image_id="$(docker image inspect --format='{{.Id}}' "${image_ref}" 2>/dev/null)" || return 1
    [[ -n "${container_image}" && "${container_image}" == "${image_id}" ]]
}

# =============================================================================
# 函数名称: _warp_container_has_expected_runtime
# 功能描述: 检查容器运行时配置是否符合当前契约：镜像 ID 与 latest 一致、
#           重启策略为 unless-stopped、40001/tcp 只发布在 127.0.0.1:40001。
#           任一项不符都意味着需要「保留 WARP_DIR 重建容器」才能让修复生效。
# 参数:
#   $1: 容器名（默认 WARP_NAME）
# 返回值: 0-符合；1-不符合/查询失败
# =============================================================================
# shellcheck disable=SC2120 # 可选参数 $1 仅用于测试/复用，生产调用方不传参
function _warp_container_has_expected_runtime() {
    local container_name="${1:-${WARP_NAME}}"
    local restart_policy='' port_bindings=''

    _warp_container_matches_image "${container_name}" || return 1
    restart_policy="$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "${container_name}" 2>/dev/null)" || return 1
    [[ "${restart_policy}" == 'unless-stopped' ]] || return 1
    port_bindings="$(docker inspect --format='{{json .HostConfig.PortBindings}}' "${container_name}" 2>/dev/null)" || return 1
    [[ -n "${port_bindings}" && "${port_bindings}" != 'null' ]] || return 1
    printf '%s\n' "${port_bindings}" | jq -er --arg host "${WARP_HOST}" --arg port "${WARP_PORT}" '
        (.[$port + "/tcp"] // []) |
        any((.HostIp // "") == $host and (.HostPort // "") == $port)
    ' >/dev/null 2>&1
}

# =============================================================================
# 函数名称: _warp_run_container
# 功能描述: 用统一参数启动 WARP 容器：回环端口发布、unless-stopped 重启策略、
#           日志轮转、数据目录 bind mount（权限 700，内含注册凭据）。
#           -p 127.0.0.1:40001:40001 让 Xray 固定连回环端点，不再依赖容器 IP。
# 参数:
#   $1: 镜像引用（默认 WARP_IMAGE）
# 返回值: 0-启动成功；1-失败
# =============================================================================
function _warp_run_container() {
    local image="${1:-${WARP_IMAGE}}"

    install -d -m 700 -- "${WARP_DIR}" || return 1
    docker run -d --name="${WARP_NAME}" \
        --restart=unless-stopped \
        --log-driver json-file --log-opt max-size=100m --log-opt max-file=3 \
        -p "${WARP_HOST}:${WARP_PORT}:${WARP_PORT}" \
        -v "${WARP_DIR}":/var/lib/cloudflare-warp:rw \
        "${image}" >/dev/null
}

# =============================================================================
# 函数名称: _warp_container_connected
# 功能描述: 判断容器内 `warp-cli --accept-tos status` 是否含 Connected。
#           就绪判定不再只探 socat 端口 40001（W3）；docker exec 可能卡死，
#           存在 timeout 命令时加 10 秒上限。
# 参数:
#   $1: 容器名（默认 WARP_NAME）
# 返回值: 0-已连接；1-未连接/无法执行
# =============================================================================
function _warp_container_connected() {
    local container_name="${1:-${WARP_NAME}}"

    # 用整词匹配：warp-cli 的未连接状态是 "Disconnected"，子串匹配会把它当成 Connected。
    if cmd_exists timeout; then
        timeout 10 docker exec "${container_name}" warp-cli --accept-tos status 2>/dev/null | grep -qiw 'Connected'
    else
        docker exec "${container_name}" warp-cli --accept-tos status 2>/dev/null | grep -qiw 'Connected'
    fi
}

# =============================================================================
# 函数名称: _warp_container_ready
# 功能描述: 运行容器的实时健康检查（ready + Connected + 两个代理端口），
#           再确认宿主发布端点可连接。避免只凭 Connected 或旧 health 状态放行。
# 参数:
#   $1: 容器名（默认 WARP_NAME）
# 返回值: 0-就绪；1-未就绪/无法执行
# =============================================================================
function _warp_container_ready() {
    local container_name="${1:-${WARP_NAME}}"

    cmd_exists timeout || return 1
    timeout -k 2 10 docker exec "${container_name}" /bin/healthcheck.sh >/dev/null 2>&1 || return 1
    timeout 2 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' bash \
        "${WARP_HOST}" "${WARP_PORT}" >/dev/null 2>&1
}

# =============================================================================
# 函数名称: wait_for_warp
# 功能描述: 等待 WARP 容器进入真正可用状态，并输出宿主端点。
#           判定为「容器实时健康检查 + 宿主端点可连接」，
#           不再只探 40001（socat 活着不代表隧道可用）。超时参数化：enable /
#           prepare 默认 240s，repair / rollback 默认 120s。容器已退出或不存在
#           时快速失败，避免白等到超时。
# 参数:
#   $1: 容器名
#   $2: 超时秒数
# 返回值: 0-就绪（stdout 输出 127.0.0.1）；1-超时/容器已退出/容器不存在
# =============================================================================
function wait_for_warp() {
    local container_name="${1:-${WARP_NAME}}"
    local timeout="${2:-120}"
    local container_status='' deadline=0

    [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=120
    deadline=$((SECONDS + timeout))
    while :; do
        container_status="$(docker inspect --format='{{.State.Status}}' "${container_name}" 2>/dev/null)" || container_status=''
        case "${container_status}" in
        running | restarting | paused | created)
            if _warp_container_ready "${container_name}"; then
                printf '%s\n' "${WARP_HOST}"
                return 0
            fi
            ;;
        '') return 1 ;; # 容器不存在或 daemon 不可达
        *) return 1 ;;  # exited/dead/removing：不会再自行恢复
        esac
        ((SECONDS < deadline)) || return 1
        sleep 1
    done
}

# =============================================================================
# 函数名称: docker_ready
# 功能描述: 判断 Docker daemon 是否可用（`docker` 命令存在不代表 daemon 可连，
#           W8）；不可用时尝试 `systemctl start docker`，再给 dockerd 最多几秒
#           的启动余量。本函数不打印错误，文案由调用方决定。
# 参数: 无
# 返回值: 0-可用；1-不可用
# =============================================================================
function docker_ready() {
    local attempt=0

    docker info >/dev/null 2>&1 && return 0
    if cmd_exists systemctl; then
        systemctl start docker >/dev/null 2>&1 || true
        docker info >/dev/null 2>&1 && return 0
        # systemctl 返回成功不代表 dockerd 已经就绪，最多再等 3 秒。
        for ((attempt = 0; attempt < 3; attempt++)); do
            sleep 1
            docker info >/dev/null 2>&1 && return 0
        done
    fi
    return 1
}

# =============================================================================
# 函数名称: build_warp
# 功能描述: 确保 WARP 镜像存在且与当前构建源文件一致。
#           镜像内固化了 startup.sh / healthcheck.sh，仅凭镜像名存在就跳过构建
#           会让脚本升级后的修复永远到不了存量用户（W2）。镜像缺失或指纹 label
#           变化时重建 latest，并在构建时写入 xray-script-warp.assets 指纹 label。
# 参数: 无
# 返回值: 0-镜像就绪（已构建或已是最新）；1-daemon 不可用/构建失败
# =============================================================================
function build_warp() {
    local assets_hash='' image_assets=''

    docker info >/dev/null 2>&1 || return 1
    assets_hash="$(warp_assets_hash)" || {
        log_error "$(t '.docker.warp.build.fail')"
        return 1
    }
    if docker image inspect "${WARP_IMAGE}" >/dev/null 2>&1; then
        image_assets="$(_warp_image_assets_label)" || image_assets=''
        if [[ -n "${image_assets}" && "${image_assets}" == "${assets_hash}" ]]; then
            log_info "$(t '.docker.warp.build.skip')"
            return 0
        fi
    fi
    print_info "$(t '.docker.warp.build.start')"
    if ! docker build -t "${WARP_IMAGE}" --label "${WARP_ASSETS_LABEL}=${assets_hash}" "${WARP_BUILD_CONTEXT}" >&2; then
        log_error "$(t '.docker.warp.build.fail')"
        return 1
    fi
    return 0
}

# =============================================================================
# 函数名称: enable_warp
# 功能描述: 启动 WARP 容器并等待就绪，stdout 只输出宿主端点 127.0.0.1。
#           流程：daemon 可用 → 镜像最新 → 容器缺失则创建 / 镜像 ID、端口或
#           重启策略不一致则保留 WARP_DIR（注册数据）重建 → wait_for_warp
#           （默认 240s，WARP_READY_TIMEOUT 可覆盖）。等待失败只保留容器
#           （不 stop），避免打断首次注册（W5）。
# 参数: 无
# 返回值: 0-成功（stdout 127.0.0.1）；1-失败
# =============================================================================
function enable_warp() {
    local container_state='' timeout='' container_ip=''

    docker_ready || return 1
    _warp_recover_pending_transaction || return 1
    print_info "$(t '.docker.warp.enable.start')"
    build_warp || return 1

    container_state="$(_warp_container_state)"
    case "${container_state}" in
    missing)
        _warp_run_container "${WARP_IMAGE}" || {
            log_error "$(t '.docker.warp.enable.start_fail')"
            return 1
        }
        ;;
    running | stopped)
        if ! _warp_container_has_expected_runtime; then
            log_info "$(t '.docker.warp.enable.recreate')"
            _warp_migrate_container "${WARP_READY_TIMEOUT:-240}"
            return $?
        else
            if ! docker update --restart=unless-stopped "${WARP_NAME}" >/dev/null 2>&1; then
                log_error "$(t '.docker.warp.enable.start_fail')"
                return 1
            fi
            if [[ "${container_state}" == 'stopped' ]]; then
                docker start "${WARP_NAME}" >/dev/null 2>&1 || {
                    log_error "$(t '.docker.warp.enable.start_fail')"
                    return 1
                }
            fi
        fi
        ;;
    *)
        log_error "$(t '.docker.warp.enable.start_fail')"
        return 1
        ;;
    esac

    timeout="${WARP_READY_TIMEOUT:-240}"
    if ! container_ip="$(wait_for_warp "${WARP_NAME}" "${timeout}")"; then
        log_error "$(t '.docker.warp.enable.fail' | sed "s/\${timeout}/${timeout}/g")"
        log_tip "$(t '.docker.warp.enable.logs_hint')"
        return 1
    fi
    log_info "$(t '.docker.warp.enable.success' | sed "s/\${warp_host}/${container_ip}/g")"
    printf '%s\n' "${container_ip}"
}

# =============================================================================
# 函数名称: disable_warp
# 功能描述: 停止 WARP 容器并持久化「关闭」状态：先把重启策略改为 no 再 stop，
#           否则容器会在 Docker/主机重启后自动复活（W1）。
#           容器不存在→0；daemon 不可用→1（由调用方给出文案，不再假成功）。
# 参数: 无
# 返回值: 0-已停止或本来就不存在；1-操作失败
# =============================================================================
function disable_warp() {
    local container_state=''

    docker info >/dev/null 2>&1 || return 1
    container_state="$(_warp_container_state)"
    [[ "${container_state}" != 'missing' ]] || return 0

    if ! docker update --restart=no "${WARP_NAME}" >/dev/null 2>&1; then
        log_warn "$(t '.docker.warp.disable.restart_warn')"
    fi
    if [[ "${container_state}" == 'running' ]]; then
        print_warn "$(t '.docker.warp.disable.stop')"
        docker stop "${WARP_NAME}" >/dev/null 2>&1 || return 1
    fi
    print_info "$(t '.docker.warp.disable.success')"
    return 0
}

# =============================================================================
# 函数名称: _warp_exec_registration_delete
# 功能描述: 在运行中的容器内尽力执行 `warp-cli --accept-tos registration delete`，
#           释放旧 WARP 设备注册（W9：重置/卸载不能把设备遗留在 Cloudflare）。
# 参数:
#   $1: 容器名（默认 WARP_NAME）
# 返回值: 0-注销成功；1-容器未运行或命令失败（调用方只 warn）
# =============================================================================
function _warp_exec_registration_delete() {
    local container_name="${1:-${WARP_NAME}}"

    [[ "$(docker inspect --format='{{.State.Running}}' "${container_name}" 2>/dev/null)" == 'true' ]] || return 1
    if cmd_exists timeout; then
        timeout 30 docker exec "${container_name}" warp-cli --accept-tos registration delete >/dev/null 2>&1
    else
        docker exec "${container_name}" warp-cli --accept-tos registration delete >/dev/null 2>&1
    fi
}

# =============================================================================
# 函数名称: _warp_tx_cleanup_backup_containers
# 功能描述: 强制删除重置事务的备份容器（收尾阶段使用；docker rm -f 保证备份
#           容器即使被意外启动也能删掉，P3-7）。
# 参数: 无
# 返回值: 0-无残留或全部删除成功；1-有删除失败
# =============================================================================
function _warp_tx_cleanup_backup_containers() {
    local status=0 backup_name=''

    for backup_name in "${WARP_BACKUP_RUNNING}" "${WARP_BACKUP_STOPPED}"; do
        if docker inspect "${backup_name}" >/dev/null 2>&1; then
            docker rm -f "${backup_name}" >/dev/null 2>&1 || status=1
        fi
    done
    return "${status}"
}

# =============================================================================
# 函数名称: _warp_tx_cleanup_images
# 功能描述: 删除重置事务的 reset-new / reset-backup 镜像 tag（latest 不动）。
# 参数: 无
# 返回值: 0-无残留或全部删除成功；1-有删除失败
# =============================================================================
function _warp_tx_cleanup_images() {
    local status=0 image_ref=''

    for image_ref in "${WARP_RESET_IMAGE}" "${WARP_BACKUP_IMAGE}"; do
        if docker image inspect "${image_ref}" >/dev/null 2>&1; then
            docker image rm "${image_ref}" >/dev/null 2>&1 || status=1
        fi
    done
    return "${status}"
}

# =============================================================================
# 函数名称: _warp_tx_cleanup_transaction_dir
# 功能描述: 删除重置事务目录（固定路径）。
# 参数: 无
# 返回值: 0-删除成功/本来就不存在；1-删除失败
# =============================================================================
function _warp_tx_cleanup_transaction_dir() {
    if [[ -e "${WARP_TRANSACTION_DIR}" || -L "${WARP_TRANSACTION_DIR}" ]]; then
        rm -rf -- "${WARP_TRANSACTION_DIR}" || return 1
    fi
    return 0
}

# =============================================================================
# 函数名称: _warp_finish_transaction_cleanup
# 功能描述: 事务收尾：强制删除备份容器 → 删除 reset-* 镜像 → 删除事务目录。
#           任一步失败即停止后续步骤并保留事务目录，保证下次 prepare 仍能识别
#           残留并自动清理。
# 参数: 无
# 返回值: 0-清理完成；1-有残留（可恢复标记保留）
# =============================================================================
function _warp_finish_transaction_cleanup() {
    local status=0

    _warp_tx_cleanup_backup_containers || status=1
    if [[ "${status}" -eq 0 ]]; then
        _warp_tx_cleanup_images || status=1
    fi
    if [[ "${status}" -eq 0 ]]; then
        _warp_tx_cleanup_transaction_dir || status=1
    fi
    return "${status}"
}

# =============================================================================
# 函数名称: _warp_tx_restore_data
# 功能描述: 恢复重置前的 WARP_DIR（注册数据），包括 keep 模式的数据快照。
#           幂等：成功后写 data-restored 标记，重复回滚不再动数据目录；
#           缺少 data 时仅在 no-data 明确记录原目录不存在的情况下删除新目录。
# 参数: 无
# 返回值: 0-已恢复/无需恢复；1-恢复失败
# =============================================================================
function _warp_tx_restore_data() {
    local transaction_dir="${WARP_TRANSACTION_DIR}"

    [[ -f "${transaction_dir}/data-restored" ]] && return 0
    if [[ -d "${transaction_dir}/data" && ! -L "${transaction_dir}/data" ]]; then
        if [[ -e "${WARP_DIR}" || -L "${WARP_DIR}" ]]; then
            rm -rf -- "${WARP_DIR}" || return 1
        fi
        mv -- "${transaction_dir}/data" "${WARP_DIR}" || return 1
    elif [[ -f "${transaction_dir}/no-data" ]]; then
        # There was no registration directory before this transaction.
        if [[ -e "${WARP_DIR}" || -L "${WARP_DIR}" ]]; then
            rm -rf -- "${WARP_DIR}" || return 1
        fi
    elif [[ -f "${transaction_dir}/had-data" && ! -e "${WARP_DIR}" && ! -L "${WARP_DIR}" ]]; then
        # 旧版本事务记录过数据，但事务目录里找不到：无法安全恢复，保留现场。
        return 1
    fi
    : >"${transaction_dir}/data-restored" || return 1
    return 0
}

# =============================================================================
# 函数名称: _warp_recover_pending_transaction
# 功能描述: prepare 开始前的自动恢复：上一次重置被中断（Ctrl-C/断电/commit
#           清理失败）时会残留备份容器、镜像或事务目录，新事务无法再建同名
#           工件。这里先清理「已提交/已回滚完成」的残留，未完成的事务则回滚
#           恢复原状，不再像旧实现那样直接拒绝执行（W11 / P3-6）。
# 参数: 无
# 返回值: 0-无残留或恢复成功；1-恢复/清理失败
# =============================================================================
function _warp_recover_pending_transaction() {
    local transaction_dir="${WARP_TRANSACTION_DIR}"
    local cleanup_status=0 has_pending=0

    [[ -e "${transaction_dir}" || -L "${transaction_dir}" ]] && has_pending=1
    if [[ "${has_pending}" -eq 0 ]]; then
        if docker inspect "${WARP_BACKUP_RUNNING}" >/dev/null 2>&1 ||
            docker inspect "${WARP_BACKUP_STOPPED}" >/dev/null 2>&1 ||
            docker image inspect "${WARP_RESET_IMAGE}" >/dev/null 2>&1 ||
            docker image inspect "${WARP_BACKUP_IMAGE}" >/dev/null 2>&1; then
            has_pending=1
        fi
    fi
    [[ "${has_pending}" -eq 1 ]] || return 0

    log_warn "$(t '.docker.warp.reset.previous_pending')"
    if [[ "${has_pending}" -eq 1 && -e "${transaction_dir}" && ! -L "${transaction_dir}" &&
        ( -f "${transaction_dir}/committed" || -f "${transaction_dir}/rolled-back" ) ]]; then
        _warp_finish_transaction_cleanup || cleanup_status=1
        if [[ "${cleanup_status}" -ne 0 ]]; then
            log_warn "$(t '.docker.warp.reset.cleanup_warn')"
        fi
        return "${cleanup_status}"
    fi
    rollback_warp_reset || return 1
    return 0
}

# =============================================================================
# 函数名称: rollback_warp_reset
# 功能描述: 回滚 WARP 重置事务：删除事务新建的容器、恢复原 WARP_DIR / 数据快照、
#           把备份容器改名回来并恢复原重启策略与运行状态，最后清理
#           事务工件。仅当容器与数据全部恢复成功才把 latest 指回旧镜像（P3-6）；
#           失败时保留工件并 warn，可由下一次 prepare 自动重试。
#           幂等：rolled-back / data-restored 标记保证重复执行不会二次破坏现场。
# 参数: 无
# 返回值: 0-恢复成功或本来就没有事务；1-恢复失败（工件保留）
# =============================================================================
function rollback_warp_reset() {
    local transaction_dir="${WARP_TRANSACTION_DIR}"
    local backup_container='' restored_container=''
    local restore_status=0 cleanup_status=0 backup_image_exists=0
    local transaction_exists=0 keep_mode=0 new_mode=0
    local restart_policy='unless-stopped' current_restart_policy='' current_restart_retries=''

    if [[ -e "${transaction_dir}" && ! -L "${transaction_dir}" ]]; then
        transaction_exists=1
    elif [[ -e "${transaction_dir}" || -L "${transaction_dir}" ]]; then
        log_warn "$(t '.docker.warp.reset.rollback_failed')"
        return 1
    fi

    # 已提交/已回滚完成的事务只清理残留，绝不能再回滚一次。
    if [[ "${transaction_exists}" -eq 1 &&
        ( -f "${transaction_dir}/committed" || -f "${transaction_dir}/rolled-back" ) ]]; then
        _warp_finish_transaction_cleanup
        return $?
    fi

    if [[ "${transaction_exists}" -eq 1 ]]; then
        [[ -f "${transaction_dir}/keep-registration" ]] && keep_mode=1
        [[ -f "${transaction_dir}/new-registration" ]] && new_mode=1
        if [[ "${keep_mode}" -eq 0 && "${new_mode}" -eq 0 ]]; then
            # 兼容没有模式标记的旧版事务：出现数据交换痕迹时按换目录模式处理。
            if [[ -e "${transaction_dir}/data" || -f "${transaction_dir}/had-data" || -f "${transaction_dir}/swapped" ]]; then
                new_mode=1
            fi
        fi
    fi

    if docker inspect "${WARP_BACKUP_RUNNING}" >/dev/null 2>&1; then
        backup_container="${WARP_BACKUP_RUNNING}"
    elif docker inspect "${WARP_BACKUP_STOPPED}" >/dev/null 2>&1; then
        backup_container="${WARP_BACKUP_STOPPED}"
    fi

    # 没有事务目录、也没有备份容器：只可能是准备阶段早退残留的镜像 tag。
    if [[ "${transaction_exists}" -eq 0 && -z "${backup_container}" ]]; then
        _warp_finish_transaction_cleanup
        return $?
    fi

    # 1) 删除事务期间新建的候选容器。备份容器存在时它一定是新的；备份不存在时
    #    只在它确实使用 reset-new 镜像时才删，避免误删尚未被替换的旧容器。
    if docker inspect "${WARP_NAME}" >/dev/null 2>&1; then
        if [[ -n "${backup_container}" ]] ||
            { [[ -f "${transaction_dir}/candidate-started" || -f "${transaction_dir}/created" ]] &&
                _warp_container_uses_image "${WARP_NAME}" "${WARP_RESET_IMAGE}"; }; then
            docker rm -f "${WARP_NAME}" >/dev/null 2>&1 || restore_status=1
        else
            restored_container="${WARP_NAME}"
        fi
    fi

    # Once the candidate is gone, clear its ownership markers before renaming
    # the old container back. A later rollback retry must not mistake the
    # restored container for a same-image candidate and delete it.
    if [[ "${restore_status}" -eq 0 && -n "${backup_container}" ]]; then
        rm -f -- "${transaction_dir}/candidate-started" "${transaction_dir}/created" || restore_status=1
    fi

    # 2) new 模式恢复原目录；keep 模式恢复候选启动前的快照，避免状态迁移
    #    或配置写入使旧容器无法读取原注册身份。
    #    候选容器若仍在运行（删除失败），先不移动数据目录，避免它继续读写被换掉的数据。
    if [[ ! -f "${transaction_dir}/data-restored" &&
        ( ( "${new_mode}" -eq 1 && -d "${transaction_dir}/data" ) ||
            -f "${transaction_dir}/data-snapshot" || -f "${transaction_dir}/no-data" ||
            -f "${transaction_dir}/had-data" ) ]]; then
        if docker inspect "${WARP_NAME}" >/dev/null 2>&1 &&
            [[ "$(docker inspect --format='{{.State.Running}}' "${WARP_NAME}" 2>/dev/null)" == 'true' ]]; then
            restore_status=1
        else
            _warp_tx_restore_data || restore_status=1
        fi
    fi

    # 3) 备份容器改名回来，恢复原重启策略与运行状态。
    if [[ -n "${backup_container}" && "${restore_status}" -eq 0 ]]; then
        if docker rename "${backup_container}" "${WARP_NAME}" >/dev/null 2>&1; then
            restored_container="${WARP_NAME}"
        else
            restore_status=1
        fi
    fi
    if [[ -f "${transaction_dir}/restart-policy" ]]; then
        restart_policy="$(cat "${transaction_dir}/restart-policy")"
        [[ "${restart_policy}" =~ ^(no|always|unless-stopped|on-failure(:[0-9]+)?)$ ]] || restore_status=1
    fi
    if [[ -n "${restored_container}" && "${restore_status}" -eq 0 ]]; then
        current_restart_policy="$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "${restored_container}" 2>/dev/null)" || restore_status=1
        if [[ "${current_restart_policy}" == 'on-failure' ]]; then
            current_restart_retries="$(docker inspect --format='{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "${restored_container}" 2>/dev/null)" || restore_status=1
            current_restart_policy="on-failure:${current_restart_retries}"
        fi
        if [[ "${restore_status}" -eq 0 && "${current_restart_policy}" != "${restart_policy}" ]]; then
            docker update "--restart=${restart_policy}" "${restored_container}" >/dev/null 2>&1 || restore_status=1
        fi
    fi
    if [[ -n "${restored_container}" && "${restore_status}" -eq 0 &&
        -f "${transaction_dir}/backup-running" ]]; then
        if [[ "$(docker inspect --format='{{.State.Running}}' "${restored_container}" 2>/dev/null)" != 'true' ]]; then
            docker start "${restored_container}" >/dev/null 2>&1 || restore_status=1
        fi
    fi

    # 4) 仅当恢复全部成功才把 latest 指回旧镜像（P3-6）。容器缺失场景（重置前本来
    #    没有容器）没有 restored_container，但事务新容器已删除且备份镜像存在时同样
    #    要还原 latest，避免回滚后 latest 停留在事务新建的镜像上。
    if docker image inspect "${WARP_BACKUP_IMAGE}" >/dev/null 2>&1; then
        backup_image_exists=1
    fi
    if [[ "${restore_status}" -eq 0 && "${backup_image_exists}" -eq 1 ]]; then
        if [[ -n "${restored_container}" ]] || ! docker inspect "${WARP_NAME}" >/dev/null 2>&1; then
            docker tag "${WARP_BACKUP_IMAGE}" "${WARP_IMAGE}" >/dev/null 2>&1 || restore_status=1
        fi
    fi

    if [[ "${restore_status}" -ne 0 ]]; then
        log_warn "$(t '.docker.warp.reset.rollback_failed')"
        return 1
    fi

    # 5) 标记回滚完成并清理事务工件；清理失败保留标记，下次 prepare 自动重试。
    if [[ "${transaction_exists}" -eq 1 ]]; then
        : >"${transaction_dir}/rolled-back" 2>/dev/null || true
    fi
    _warp_finish_transaction_cleanup || cleanup_status=1
    if [[ "${cleanup_status}" -ne 0 ]]; then
        log_warn "$(t '.docker.warp.reset.cleanup_warn')"
    fi
    return 0
}

# =============================================================================
# 函数名称: prepare_warp_reset
# 功能描述: 构建新镜像并以事务方式替换 WARP 容器，stdout 只输出 127.0.0.1。
#           keep（默认）：保留 WARP_DIR（注册身份不变），只重建镜像/容器；
#           new：先尽力注销旧注册，再把 WARP_DIR 移入事务目录并新建空目录（700），
#           容器启动后重新注册。
#           成功返回前把 latest 指向新镜像，保证 handler 在 prepare→commit 之间
#           重建配置时 --obtain-container-ip 的镜像一致性门禁可通过。
#           失败由 EXIT/HUP/INT/TERM trap 自动回滚，可中断、可重试。
# 参数:
#   $1: keep|new（默认 keep）
# 返回值: 0-成功（stdout 127.0.0.1）；1-失败（已回滚到原状）
# =============================================================================
function prepare_warp_reset() (
    local mode="${1:-keep}"
    local candidate_image="${2:-}"
    local container_state='' current_image='' backup_container=''
    local container_ip='' timeout='' assets_hash=''
    local restart_policy='' restart_retries=''

    case "${mode,,}" in
    new) mode='new' ;;
    *) mode='keep' ;;
    esac

    # 内部回滚入口：任何失败都先撤销已做的变更，再带着原始退出码退出。
    function finish_warp_reset_preparation() {
        local status="$1"
        local rollback_status=0

        txn_finish_enter ignore
        if [[ "${status}" -ne 0 ]]; then
            rollback_warp_reset || rollback_status=1
            if [[ "${rollback_status}" -ne 0 ]]; then
                log_warn "$(t '.docker.warp.reset.rollback_failed')"
            fi
        fi
        exit "${status}"
    }

    docker_ready || return 1
    _warp_recover_pending_transaction || return 1

    txn_begin finish_warp_reset_preparation

    container_state="$(_warp_container_state)"

    # 备份旧镜像 tag：优先用容器实际使用的镜像 ID，其次用 latest。
    if [[ "${container_state}" != 'missing' ]]; then
        current_image="$(docker inspect --format='{{.Image}}' "${WARP_NAME}" 2>/dev/null)" || return 1
        docker tag "${current_image}" "${WARP_BACKUP_IMAGE}" >/dev/null 2>&1 || return 1
    elif docker image inspect "${WARP_IMAGE}" >/dev/null 2>&1; then
        docker tag "${WARP_IMAGE}" "${WARP_BACKUP_IMAGE}" >/dev/null 2>&1 || return 1
    fi

    # 重置镜像同样要写 assets 指纹 label：commit 会把它 tag 成 latest，缺 label 会让
    # 下一次 build_warp 误判镜像过期而反复全量构建（W2）。
    if [[ -n "${candidate_image}" ]]; then
        # Automatic migration already built the assets-matched image. Use the
        # same rollback transaction without rebuilding it or replacing identity.
        docker tag "${candidate_image}" "${WARP_RESET_IMAGE}" >/dev/null 2>&1 || return 1
    else
        assets_hash="$(warp_assets_hash)" || {
            log_error "$(t '.docker.warp.build.fail')"
            return 1
        }
        print_info "$(t '.docker.warp.build.start')"
        if ! docker build --no-cache --label "${WARP_ASSETS_LABEL}=${assets_hash}" \
            -t "${WARP_RESET_IMAGE}" "${WARP_BUILD_CONTEXT}" >&2; then
            log_error "$(t '.docker.warp.build.fail')"
            return 1
        fi
    fi

    mkdir -p -- "${DOCKER_DIR}" || return 1
    mkdir -- "${WARP_TRANSACTION_DIR}" || return 1
    if [[ "${mode}" == 'new' ]]; then
        : >"${WARP_TRANSACTION_DIR}/new-registration" || return 1
    else
        : >"${WARP_TRANSACTION_DIR}/keep-registration" || return 1
    fi

    if [[ "${container_state}" != 'missing' ]]; then
        restart_policy="$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "${WARP_NAME}")" || return 1
        case "${restart_policy}" in
        no|always|unless-stopped) ;;
        on-failure)
            restart_retries="$(docker inspect --format='{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "${WARP_NAME}")" || return 1
            [[ "${restart_retries}" =~ ^[0-9]+$ ]] || return 1
            restart_policy="on-failure:${restart_retries}"
            ;;
        *) return 1 ;;
        esac
        printf '%s\n' "${restart_policy}" >"${WARP_TRANSACTION_DIR}/restart-policy" || return 1
        # new 模式先尽力注销旧设备；容器不在运行态时无法注销，同样只 warn。
        if [[ "${mode}" == 'new' ]]; then
            _warp_exec_registration_delete "${WARP_NAME}" ||
                log_warn "$(t '.docker.warp.reset.registration_delete_warn')"
        fi
        if [[ "${container_state}" == 'running' ]]; then
            : >"${WARP_TRANSACTION_DIR}/backup-running" || return 1
            backup_container="${WARP_BACKUP_RUNNING}"
        else
            backup_container="${WARP_BACKUP_STOPPED}"
        fi
        docker update --restart=no "${WARP_NAME}" >/dev/null 2>&1 || return 1
        if [[ "${container_state}" == 'running' ]]; then
            docker stop "${WARP_NAME}" >/dev/null 2>&1 || return 1
        fi
        docker rename "${WARP_NAME}" "${backup_container}" >/dev/null 2>&1 || return 1
        : >"${WARP_TRANSACTION_DIR}/swapped" || return 1
    fi

    if [[ "${mode}" == 'new' && ( -e "${WARP_DIR}" || -L "${WARP_DIR}" ) ]]; then
        [[ -d "${WARP_DIR}" && ! -L "${WARP_DIR}" ]] || return 1
        mv -- "${WARP_DIR}" "${WARP_TRANSACTION_DIR}/data" || return 1
    elif [[ "${mode}" == 'keep' && ( -e "${WARP_DIR}" || -L "${WARP_DIR}" ) ]]; then
        [[ -d "${WARP_DIR}" && ! -L "${WARP_DIR}" ]] || return 1
        # A stopped daemon gives a consistent snapshot. Do not mark a partial
        # copy as restorable if copying failed before a candidate was started.
        cp -a -- "${WARP_DIR}" "${WARP_TRANSACTION_DIR}/data" || return 1
        : >"${WARP_TRANSACTION_DIR}/data-snapshot" || return 1
    else
        : >"${WARP_TRANSACTION_DIR}/no-data" || return 1
    fi

    : >"${WARP_TRANSACTION_DIR}/candidate-started" || return 1
    _warp_run_container "${WARP_RESET_IMAGE}" || return 1
    # 记录「新容器已创建」：容器缺失（只有镜像/数据）时不会走 swapped 分支，
    # commit 需要这个标记来区分「事务已建立新容器」与「准备阶段提前失败」。
    : >"${WARP_TRANSACTION_DIR}/created" || return 1

    timeout="${WARP_READY_TIMEOUT:-240}"
    container_ip="$(wait_for_warp "${WARP_NAME}" "${timeout}")" || {
        log_error "$(t '.docker.warp.enable.fail' | sed "s/\${timeout}/${timeout}/g")"
        log_tip "$(t '.docker.warp.enable.logs_hint')"
        return 1
    }
    [[ -n "${container_ip}" ]] || return 1

    # prepare 与 commit 之间 handler 会重建 Xray 配置并调用 --obtain-container-ip；
    # 该门禁要求运行容器的镜像 ID 与 latest 一致。新容器用的是 reset-new 镜像，
    # 这里先把 latest 指向它（commit 会幂等再 tag 一次），否则配置阶段 obtain 必然
    # 失败并触发回滚（WARP 已开启时重置 100% 失败）。
    if ! docker tag "${WARP_RESET_IMAGE}" "${WARP_IMAGE}" >/dev/null 2>&1; then
        log_error "$(t '.docker.warp.enable.start_fail')"
        return 1
    fi

    trap - EXIT HUP INT TERM
    printf '%s\n' "${container_ip}"
)

# Reuse the reset transaction for upgrades; keep the old container, image and
# registration snapshot until readiness and commit have both succeeded.
function _warp_migrate_container() (
    local WARP_READY_TIMEOUT="${1:-240}"
    local endpoint=''

    function finish_warp_migration() {
        local status="$1"
        txn_finish_enter ignore
        if ! txn_is_committed; then
            rollback_warp_reset || log_warn "$(t '.docker.warp.reset.rollback_failed')"
            [[ "${status}" -ne 0 ]] || status=1
        fi
        exit "${status}"
    }

    txn_begin finish_warp_migration
    endpoint="$(prepare_warp_reset keep "${WARP_IMAGE}")" || return 1
    [[ -n "${endpoint}" ]] || return 1
    commit_warp_reset || return 1
    txn_commit
    printf '%s\n' "${endpoint}"
)

# =============================================================================
# 函数名称: commit_warp_reset
# 功能描述: 提交 WARP 重置事务：校验新容器 running+healthy，把 reset-new 镜像
#           tag 成 latest（prepare 已提前 tag 过，这里幂等确认），写 committed 标记
#           后清理备份容器/镜像/事务目录。
#           清理失败只 warn 并返回 0（保留可恢复标记，下次 prepare 自动清理）。
# 参数: 无
# 返回值: 0-提交成功（含清理失败）；1-校验失败/无法提交
# =============================================================================
function commit_warp_reset() {
    local transaction_dir="${WARP_TRANSACTION_DIR}"
    local container_state='' cleanup_status=0

    [[ -d "${transaction_dir}" && ! -L "${transaction_dir}" &&
        ( -f "${transaction_dir}/created" || -f "${transaction_dir}/swapped" ) ]] || return 1
    docker inspect "${WARP_NAME}" >/dev/null 2>&1 || return 1
    container_state="$(_warp_container_state)"
    [[ "${container_state}" == 'running' ]] || return 1
    # 给短暂断连一点恢复窗口（旧实现固定 30s），仍不健康则失败交给上层回滚。
    wait_for_warp "${WARP_NAME}" 30 >/dev/null 2>&1 || return 1
    docker image inspect "${WARP_RESET_IMAGE}" >/dev/null 2>&1 || return 1
    docker tag "${WARP_RESET_IMAGE}" "${WARP_IMAGE}" >/dev/null 2>&1 || return 1
    : >"${transaction_dir}/committed" || return 1

    _warp_finish_transaction_cleanup || cleanup_status=1
    if [[ "${cleanup_status}" -ne 0 ]]; then
        log_warn "$(t '.docker.warp.reset.cleanup_warn')"
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
#           容器名找不到时按同名 compose 服务查容器 ID；不能把仍在运行的
#           PostgreSQL、Redis 或 Aria2 当作 Cloudreve 已就绪。
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
    local stable_since='' status='' service_container=''

    while :; do
        status="$(docker inspect --format='{{.State.Status}}' "${container}" 2>/dev/null)" || status=''
        # 查询指定服务而不是整个项目，否则辅助容器还在运行也会误报成功。
        if [[ -z "${status}" ]]; then
            service_container="$(docker compose ps --all --quiet "${container}" 2>/dev/null)" || service_container=''
            if [[ -n "${service_container}" && "${service_container}" != *$'\n'* ]]; then
                status="$(docker inspect --format='{{.State.Status}}' "${service_container}" 2>/dev/null)" || status=''
            fi
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
            docker compose down -v || print_error 'Failed to remove Cloudreve v3 containers and volumes; project files were retained.'
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
        # 先下载镜像，失败时保留正在运行的服务。up 会替换需要更新的容器，
        # 不需要提前 down；忽略 pull 的失败会把继续运行旧镜像误报为更新成功。
        docker compose pull || print_error 'Failed to pull Cloudreve v4 images; the current service was retained.'
        # 应用已下载的新镜像
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
            docker compose down -v || print_error 'Failed to remove Cloudreve v4 containers and volumes; project files were retained.'
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
# 函数名称: _warp_status
# 功能描述: 计算 WARP 状态 token（供 handler / menu 解析）：
#           enabled / stopped / missing / unhealthy / docker_unavailable。
#           enabled 需容器 running 且容器内 status 含 Connected；running 但未连接
#           为 unhealthy。stdout 只输出 token，总是返回 0。
# 参数: 无
# 返回值: 0（token 写到 stdout）
# =============================================================================
function _warp_status() {
    local container_state=''

    if ! docker info >/dev/null 2>&1; then
        printf 'docker_unavailable\n'
        return 0
    fi
    container_state="$(_warp_container_state)"
    case "${container_state}" in
    missing) printf 'missing\n' ;;
    running)
        if _warp_container_ready "${WARP_NAME}"; then
            printf 'enabled\n'
        else
            printf 'unhealthy\n'
        fi
        ;;
    stopped) printf 'stopped\n' ;;
    *) printf 'missing\n' ;;
    esac
}

# =============================================================================
# 函数名称: warp_health
# 功能描述: WARP 健康检查：状态 token 为 enabled 且容器运行时配置符合当前契约
#           （镜像 ID、回环端口发布、unless-stopped）时返回 0，其余返回 1。
#           升级后未迁移的旧容器虽然 Connected，但没有发布 127.0.0.1:40001，
#           不能算健康；handler_routing 据此自动走 --repair-warp 完成重建迁移。
# 参数: 无
# 返回值: 0-健康；1-不健康/不可用
# =============================================================================
function warp_health() {
    [[ "$(_warp_status)" == 'enabled' ]] &&
        _warp_container_has_expected_runtime "${WARP_NAME}"
}

# =============================================================================
# 函数名称: repair_warp
# 功能描述: 修复「配置已开启但容器未运行 / 未连接 / 仍是旧镜像」的 WARP：
#           容器 missing→1；旧镜像或旧运行参数（无回环端口、无 ready 标记）无法
#           靠 start 修复，先确保镜像最新，再保留 WARP_DIR 重建容器；最后启动并
#           wait_for_warp（默认 120s，WARP_REPAIR_TIMEOUT 可覆盖）。
# 参数: 无
# 返回值: 0-修复后就绪；1-容器不存在/修复失败
# =============================================================================
function repair_warp() {
    local container_state='' timeout=''

    docker_ready || return 1
    _warp_recover_pending_transaction || return 1
    container_state="$(_warp_container_state)"
    [[ "${container_state}" != 'missing' ]] || return 1

    if ! _warp_container_has_expected_runtime; then
        build_warp || return 1
        if ! _warp_container_has_expected_runtime; then
            log_info "$(t '.docker.warp.enable.recreate')"
            _warp_migrate_container "${WARP_REPAIR_TIMEOUT:-120}" >/dev/null
            return $?
        fi
        container_state="$(_warp_container_state)"
    fi

    docker update --restart=unless-stopped "${WARP_NAME}" >/dev/null 2>&1 || return 1
    if [[ "${container_state}" != 'running' ]]; then
        docker start "${WARP_NAME}" >/dev/null 2>&1 || return 1
    fi
    timeout="${WARP_REPAIR_TIMEOUT:-120}"
    if ! wait_for_warp "${WARP_NAME}" "${timeout}" >/dev/null 2>&1; then
        log_error "$(t '.docker.warp.enable.fail' | sed "s/\${timeout}/${timeout}/g")"
        log_tip "$(t '.docker.warp.enable.logs_hint')"
        return 1
    fi
    return 0
}

# =============================================================================
# 函数名称: purge_warp
# 功能描述: 彻底清理 WARP：尽力注销注册 → 强制删除容器（含重置备份容器）→
#           删除 latest / reset-* 镜像 → 删除 WARP_DIR（先校验固定路径前缀）→
#           删除事务目录。逐项尽力执行并记录失败项，关键项有失败即返回 1（W10）。
# 参数: 无
# 返回值: 0-清理完成；1-有未清理项
# =============================================================================
function purge_warp() {
    local status=0 image_ref=''

    if ! docker info >/dev/null 2>&1; then
        log_error "$(t '.docker.warp.purge.fail')"
        return 1
    fi
    print_info "$(t '.docker.warp.purge.start')"

    # 尽力注销 WARP 设备注册，避免卸载后旧设备残留在 Cloudflare（W9）。
    if ! _warp_exec_registration_delete "${WARP_NAME}" &&
        docker inspect "${WARP_NAME}" >/dev/null 2>&1; then
        log_warn "$(t '.docker.warp.reset.registration_delete_warn')"
    fi

    if docker inspect "${WARP_NAME}" >/dev/null 2>&1; then
        if ! docker rm -f "${WARP_NAME}" >/dev/null 2>&1; then
            log_warn "$(t '.docker.warp.purge.fail')"
            status=1
        fi
    fi
    if ! _warp_tx_cleanup_backup_containers; then
        log_warn "$(t '.docker.warp.purge.fail')"
        status=1
    fi

    for image_ref in "${WARP_IMAGE}" "${WARP_RESET_IMAGE}" "${WARP_BACKUP_IMAGE}"; do
        if docker image inspect "${image_ref}" >/dev/null 2>&1; then
            if ! docker image rm -f "${image_ref}" >/dev/null 2>&1; then
                log_warn "$(t '.docker.warp.purge.fail')"
                status=1
            fi
        fi
    done

    if [[ -n "${WARP_DIR}" && "${WARP_DIR}" == "${DOCKER_DIR}/cloudflare-warp" ]]; then
        if [[ -e "${WARP_DIR}" || -L "${WARP_DIR}" ]]; then
            if ! rm -rf -- "${WARP_DIR}"; then
                log_warn "$(t '.docker.warp.purge.fail')"
                status=1
            fi
        fi
    else
        # 路径与预期不符时拒绝删除，避免误删用户目录。
        log_warn "$(t '.docker.warp.purge.fail')"
        status=1
    fi

    if ! _warp_tx_cleanup_transaction_dir; then
        log_warn "$(t '.docker.warp.purge.fail')"
        status=1
    fi

    if [[ "${status}" -eq 0 ]]; then
        log_config "$(t '.docker.warp.purge.success')"
        return 0
    fi
    log_error "$(t '.docker.warp.purge.fail')"
    return 1
}

# =============================================================================
# 函数名称: clean_container_logs
# 功能描述: 清空指定容器日志数据。
#           只有 json-file 驱动才有可直接截断的日志文件；其他驱动（journald
#           等）没有可截断路径，打印 warn 并返回 0，绝不能中断重置流程（P3-5）。
# 参数:
#   $1: 容器名称或 ID（默认清空 WARP 日志）
# 返回值: 0-已清理/无需清理/驱动不支持；1-daemon 不可用或读取失败
# =============================================================================
function clean_container_logs() {
    local container_name_or_id="${1:-${WARP_NAME}}"
    local log_driver='' log_path=''

    docker info >/dev/null 2>&1 || return 1
    if ! docker inspect "${container_name_or_id}" >/dev/null 2>&1; then
        return 0
    fi
    log_driver="$(docker inspect --format='{{.HostConfig.LogConfig.Type}}' "${container_name_or_id}" 2>/dev/null)" || return 1
    if [[ "${log_driver}" != 'json-file' ]]; then
        log_warn "$(t '.docker.warp.log_driver_unsupported')"
        return 0
    fi
    log_path="$(docker inspect --format='{{.LogPath}}' "${container_name_or_id}" 2>/dev/null)" || return 1
    [[ -z "${log_path}" || ! -e "${log_path}" ]] && return 0
    truncate -s 0 -- "${log_path}"
}

# =============================================================================
# 函数名称: obtain_container_ip
# 功能描述: 获取 WARP 容器当前可连接的宿主端点（固定 127.0.0.1）。
#           只做快速健康检查：不 build / 不 start / 不 repair，总等待 ≤10s；
#           容器 running、容器内 status 含 Connected **且运行时配置符合当前契约**
#           （镜像 ID/回环端口发布/unless-stopped）→ 输出地址，否则静默失败。
#           旧容器没有发布 127.0.0.1:40001，若只判 Connected 会让配置生成写出
#           指向未发布端口的 warp 出站（升级迁移期的静默黑洞）；这里返回失败后
#           由 handler 走 `.handler.warp.unavailable` + repair_hint 或 repair 迁移。
# 参数:
#   $1: 容器名称（默认 WARP 容器）
# 返回值: 0-可用（stdout 127.0.0.1）；1-不可用（无输出、无日志）
# =============================================================================
function obtain_container_ip() {
    local container_name="${1:-${WARP_NAME}}"
    local container_status='' deadline=$((SECONDS + 10))

    while :; do
        container_status="$(docker inspect --format='{{.State.Status}}' "${container_name}" 2>/dev/null)" || container_status=''
        case "${container_status}" in
        running)
            if _warp_container_has_expected_runtime "${container_name}" &&
                _warp_container_ready "${container_name}"; then
                printf '%s\n' "${WARP_HOST}"
                return 0
            fi
            ;;
        restarting) ;;
        *) return 1 ;; # 容器不存在/已退出/daemon 不可用：快速失败
        esac
        ((SECONDS < deadline)) || return 1
        sleep 1
    done
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
#           1. 加载国际化数据。
#           2. 根据传入的第一个参数 (option) 调用相应的管理函数。
#           未知选项返回 2，避免调用方把「什么都没做」当成功（P3-10）。
# 参数:
#   $@: 所有命令行参数
# 返回值: 0-成功；1-失败；2-未知选项
# =============================================================================
function main() {
    # 加载国际化数据
    load_i18n

    # 使用 case 语句根据选项调用对应的函数
    case "${1,,}" in                                   # ${1,,} 将第一个参数转换为小写
    --install) install_docker ;;                       # 安装 Docker
    --docker-ready) docker_ready ;;                    # 检查 Docker daemon 是否可用
    --build-warp) build_warp ;;                        # 构建 WARP 镜像
    --enable-warp) enable_warp ;;                      # 启用 WARP 容器
    --disable-warp) disable_warp ;;                    # 禁用 WARP 容器
    --obtain-container-ip) obtain_container_ip "${2:-}" ;; # 获取可连接的 WARP 宿主端点
    --warp-status) _warp_status ;;                     # 输出 WARP 状态 token
    --warp-health) warp_health ;;                      # WARP 健康检查
    --repair-warp) repair_warp ;;                      # 修复 WARP 容器
    --purge-warp) purge_warp ;;                        # 清理 WARP 容器/镜像/数据
    --prepare-reset-warp) prepare_warp_reset "${2:-keep}" ;; # 构建并暂存新的 WARP 容器
    --commit-reset-warp) commit_warp_reset ;;          # 提交 WARP 重建事务
    --rollback-reset-warp) rollback_warp_reset ;;      # 回滚 WARP 重建事务
    --clean-container-logs) clean_container_logs "${2:-}" ;; # 清空容器日志文件
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
    *)
        log_error "$(t '.docker.warp.unknown_option') $1"
        return 2
        ;;
    esac
}

# --- 脚本执行入口 ---
# 将脚本接收到的所有参数传递给 main 函数开始执行
main "$@"
