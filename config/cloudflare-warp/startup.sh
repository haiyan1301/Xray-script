#!/usr/bin/env bash
# Cloudflare WARP 容器入口：启动守护进程、确保注册、切到 proxy 模式并连接，
# 连接确认后写 ready 标记并启动 40001 -> 40000 转发，运行期持续监督隧道状态。
# 任何致命故障都以非 0 退出，交给容器的 restart 策略；状态日志一律写 stderr。
set -euo pipefail

# 状态目录：宿主 wait_for_warp 校验的 ready 标记所在目录（测试可覆盖到可写目录）。
WARP_STATE_DIR="${WARP_STATE_DIR:-/var/lib/cloudflare-warp}"
WARP_READY_FILE="${WARP_STATE_DIR}/ready"

# 可测试性/可调参数：Connected 状态最长等待秒数、监督循环间隔秒数。
WARP_CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-90}"
WARP_MONITOR_INTERVAL="${WARP_MONITOR_INTERVAL:-15}"

# 固定端口：40000 是 WARP 守护进程的本地 socks 代理，40001 暴露给宿主的 Xray。
WARP_PROXY_PORT=40000
WARP_FORWARD_PORT=40001

# 重试与监督参数。
DAEMON_READY_ATTEMPTS=30
REGISTRATION_ATTEMPTS=3
CONFIG_ATTEMPTS=3
RETRY_INTERVAL=2
DISCONNECTED_LIMIT=3

warp_svc_pid=''
forwarding_pid=''

# 统一日志入口：容器内没有 lib/log.sh，直接写 stderr 供 docker logs 查看。
function log_info() {
    printf '[warp] %s\n' "$*" >&2
}

function log_warn() {
    printf '[warp] WARNING: %s\n' "$*" >&2
}

function log_error() {
    printf '[warp] ERROR: %s\n' "$*" >&2
}

# 统一 warp-cli 调用入口：带 --accept-tos，并给 CLI 调用加 10 秒硬超时。
function warp_cli() {
    timeout -k 2 10 warp-cli --accept-tos "$@"
}

# 退出清理：先 TERM，最多等 2 秒，再 KILL，最后回收子进程。
# 有界清理保证 docker stop/restart 不会被卡死的守护进程无限拖住。
function cleanup() {
    local child_pid
    trap - EXIT HUP INT TERM
    for child_pid in "${forwarding_pid}" "${warp_svc_pid}"; do
        [[ -z "${child_pid}" ]] || kill "${child_pid}" 2>/dev/null || true
    done
    for ((cleanup_attempt = 0; cleanup_attempt < 20; cleanup_attempt++)); do
        live_child=0
        for child_pid in "${forwarding_pid}" "${warp_svc_pid}"; do
            if [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" 2>/dev/null; then
                live_child=1
            fi
        done
        [[ "${live_child}" -eq 1 ]] || break
        sleep 0.1
    done
    for child_pid in "${forwarding_pid}" "${warp_svc_pid}"; do
        [[ -z "${child_pid}" ]] || kill -KILL "${child_pid}" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# 准备状态目录，并清除上次运行遗留的 ready 标记，避免宿主把旧标记当成已就绪。
function prepare_state_dir() {
    if ! mkdir -p -- "${WARP_STATE_DIR}"; then
        log_error "cannot create WARP state directory '${WARP_STATE_DIR}' (stage=state-dir); set WARP_STATE_DIR to a writable path"
        exit 1
    fi
    rm -f -- "${WARP_READY_FILE}" 2>/dev/null || true
}

# 写入 ready 标记（先写临时文件再原子替换）；宿主 wait_for_warp 以该标记 + status 判定就绪。
function mark_ready() {
    local marker_tmp="${WARP_READY_FILE}.tmp"
    if ! printf 'connected %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${marker_tmp}" 2>/dev/null; then
        log_error "cannot write WARP ready marker '${WARP_READY_FILE}' (stage=ready-marker)"
        exit 1
    fi
    if ! mv -f -- "${marker_tmp}" "${WARP_READY_FILE}" 2>/dev/null; then
        rm -f -- "${marker_tmp}" 2>/dev/null || true
        log_error "cannot replace WARP ready marker '${WARP_READY_FILE}' (stage=ready-marker)"
        exit 1
    fi
}

# 删除 ready 标记：隧道断开时不让宿主继续认为容器就绪。
function remove_ready() {
    rm -f -- "${WARP_READY_FILE}" 2>/dev/null || true
}

# status 输出判定：优先匹配显式状态行 "Status update: Connected"（忽略大小写）；
# 输出格式变化时退回整词匹配，并用整词排除 Disconnected，避免子串误判。
function status_connected() {
    local status_output
    status_output="$(warp_cli status 2>/dev/null)" || return 1
    [[ -n "${status_output}" ]] || return 1
    if grep -qiE 'Status update:[[:space:]]*Connected' <<<"${status_output}"; then
        return 0
    fi
    grep -qiw 'connected' <<<"${status_output}" && ! grep -qiw 'disconnected' <<<"${status_output}"
}

# 有界等待隧道进入 Connected（默认 90s），期间守护进程退出立即失败。
function wait_for_connected() {
    local deadline=$((SECONDS + WARP_CONNECT_TIMEOUT))
    while :; do
        kill -0 "${warp_svc_pid}" 2>/dev/null ||
            { log_error "Cloudflare WARP daemon exited while waiting for connection (stage=connect-check)"; exit 1; }
        if status_connected; then
            return 0
        fi
        (( SECONDS < deadline )) || break
        sleep 1
    done
    return 1
}

# 确保存在可用注册：registration show 失败时 registration new 重试（最多 3 次，间隔 2s），
# 成功后再次 registration show 校验；返回非 0 表示注册失败。
function ensure_registration() {
    local attempt=1
    if warp_cli registration show >/dev/null 2>&1; then
        return 0
    fi
    log_info "Registering a new Cloudflare WARP device"
    while (( attempt <= REGISTRATION_ATTEMPTS )); do
        if warp_cli registration new >/dev/null 2>&1 && warp_cli registration show >/dev/null 2>&1; then
            return 0
        fi
        log_warn "warp-cli registration new failed (attempt ${attempt}/${REGISTRATION_ATTEMPTS})"
        if (( attempt < REGISTRATION_ATTEMPTS )); then
            sleep "${RETRY_INTERVAL}"
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# 坏注册自愈：删除现有注册并重新注册一次（有上限），成功后由调用方重试失败的配置动作。
function repair_registration() {
    local stage="$1"
    local attempt=1
    log_warn "WARP '${stage}' failed with the current registration; resetting registration (stage=${stage})"
    if ! warp_cli registration delete >/dev/null 2>&1; then
        log_warn "warp-cli registration delete failed; continuing with re-registration (stage=${stage})"
    fi
    while (( attempt <= REGISTRATION_ATTEMPTS )); do
        if warp_cli registration new >/dev/null 2>&1 && warp_cli registration show >/dev/null 2>&1; then
            return 0
        fi
        log_warn "warp-cli registration new failed after reset (attempt ${attempt}/${REGISTRATION_ATTEMPTS})"
        if (( attempt < REGISTRATION_ATTEMPTS )); then
            sleep "${RETRY_INTERVAL}"
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# 带退避重试执行一条 warp-cli 命令；返回非 0 表示尝试次数已用尽。
function warp_cli_retry() {
    local attempts="$1"
    local delay="$2"
    local attempt=1
    shift 2
    while (( attempt <= attempts )); do
        if warp_cli "$@"; then
            return 0
        fi
        log_warn "warp-cli $* failed (attempt ${attempt}/${attempts})"
        if (( attempt < attempts )); then
            sleep "${delay}"
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# 配置 proxy 模式并连接：每步最多 3 次重试；仍失败时做一次坏注册自愈再重试，仍失败返回 1。
function configure_warp() {
    log_info "Setting Cloudflare WARP mode to proxy"
    if ! warp_cli_retry "${CONFIG_ATTEMPTS}" "${RETRY_INTERVAL}" mode proxy; then
        repair_registration 'mode proxy' ||
            { log_error "Cloudflare WARP proxy mode could not be enabled (stage=mode-proxy)"; return 1; }
        if ! warp_cli_retry "${CONFIG_ATTEMPTS}" "${RETRY_INTERVAL}" mode proxy; then
            log_error "Cloudflare WARP proxy mode could not be enabled after registration reset (stage=mode-proxy)"
            return 1
        fi
    fi
    log_info "Connecting Cloudflare WARP"
    if ! warp_cli_retry "${CONFIG_ATTEMPTS}" "${RETRY_INTERVAL}" connect; then
        repair_registration 'connect' ||
            { log_error "Cloudflare WARP connect failed (stage=connect)"; return 1; }
        if ! warp_cli_retry "${CONFIG_ATTEMPTS}" "${RETRY_INTERVAL}" connect; then
            log_error "Cloudflare WARP connect failed after registration reset (stage=connect)"
            return 1
        fi
    fi
}

# 尽力探测容器内 40000（WARP 本地 socks 代理）；失败只告警，不阻塞启动。
function probe_proxy_port() {
    if ! command -v timeout >/dev/null 2>&1; then
        log_warn "timeout command is not available; skipping 127.0.0.1:${WARP_PROXY_PORT} probe"
        return 0
    fi
    if timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/${WARP_PROXY_PORT}" 2>/dev/null; then
        log_info "Cloudflare WARP proxy is accepting connections on 127.0.0.1:${WARP_PROXY_PORT}"
    else
        log_warn "Cloudflare WARP proxy 127.0.0.1:${WARP_PROXY_PORT} is not accepting connections yet; continuing because status is Connected"
    fi
    return 0
}

# 子进程存活检查：socat 退出时取其退出码退出容器（兼容 rc=9 语义），
# warp-svc 退出时以非 0 退出（意外 0 退出也归一为 1）。
function check_children() {
    local child_status=0
    if ! kill -0 "${forwarding_pid}" 2>/dev/null; then
        wait "${forwarding_pid}" 2>/dev/null || child_status=$?
        log_error "socat exited with status ${child_status}; exiting container so Docker can restart it"
        (( child_status != 0 )) || child_status=1
        exit "${child_status}"
    fi
    if ! kill -0 "${warp_svc_pid}" 2>/dev/null; then
        wait "${warp_svc_pid}" 2>/dev/null || child_status=$?
        log_error "Cloudflare WARP daemon exited with status ${child_status}; exiting container so Docker can restart it"
        (( child_status != 0 )) || child_status=1
        exit "${child_status}"
    fi
}

# 监督循环：socat 退出时取其退出码退出容器，warp-svc 退出时以非 0 退出；
# 每次循环复查 Connected，连续 3 次非 Connected 时删除 ready 标记并退出交给 restart 策略。
function supervise() {
    local disconnected_count=0
    # 启动后先给监听进程 1 秒观察窗：socat 立刻退出（端口被占/二进制损坏）可快速失败，
    # 不必等到第一个巡检周期（默认 15s）才退出。
    sleep 1
    check_children
    while :; do
        sleep "${WARP_MONITOR_INTERVAL}"
        check_children
        if status_connected; then
            if (( disconnected_count > 0 )); then
                log_info "Cloudflare WARP tunnel is connected again"
                disconnected_count=0
                mark_ready
            fi
        else
            disconnected_count=$((disconnected_count + 1))
            remove_ready
            log_warn "Cloudflare WARP is not Connected (${disconnected_count}/${DISCONNECTED_LIMIT})"
            if (( disconnected_count >= DISCONNECTED_LIMIT )); then
                log_error "Cloudflare WARP stayed disconnected for ${DISCONNECTED_LIMIT} checks; exiting container so Docker can restart it"
                exit 1
            fi
        fi
    done
}

prepare_state_dir

log_info "Starting Cloudflare WARP daemon"
warp-svc &
warp_svc_pid=$!

daemon_ready=0
for ((attempt = 0; attempt < DAEMON_READY_ATTEMPTS; attempt++)); do
    kill -0 "${warp_svc_pid}" 2>/dev/null ||
        { log_error "Cloudflare WARP daemon exited during startup (stage=daemon-ready)"; exit 1; }
    if warp_cli settings >/dev/null 2>&1; then
        daemon_ready=1
        break
    fi
    sleep 1
done
if [[ "${daemon_ready}" -ne 1 ]]; then
    log_error "Cloudflare WARP daemon did not become ready within ${DAEMON_READY_ATTEMPTS}s (stage=daemon-ready)"
    exit 1
fi

if ! ensure_registration; then
    log_error "Cloudflare WARP device registration failed (stage=registration)"
    exit 1
fi

if ! configure_warp; then
    exit 1
fi

if ! wait_for_connected; then
    log_error "Cloudflare WARP did not reach the Connected state within ${WARP_CONNECT_TIMEOUT}s (stage=connect-check)"
    exit 1
fi
log_info "Cloudflare WARP tunnel is connected"

probe_proxy_port
mark_ready
log_info "Cloudflare WARP is ready (${WARP_READY_FILE})"

log_info "Forwarding 0.0.0.0:${WARP_FORWARD_PORT} to 127.0.0.1:${WARP_PROXY_PORT}"
socat "TCP-LISTEN:${WARP_FORWARD_PORT},reuseaddr,fork" "TCP:127.0.0.1:${WARP_PROXY_PORT}" &
forwarding_pid=$!

supervise
