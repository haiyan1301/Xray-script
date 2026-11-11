#!/usr/bin/env bash
# WARP 容器健康检查：startup.sh 已写 ready 标记、隧道状态含 Connected、本地 socks 代理可连接。
# 全部通过返回 0，否则返回 1；不向 stdout 输出任何内容（stderr 也尽量保持安静）。
set -uo pipefail

# 与 startup.sh 保持一致的 ready 标记路径（测试可覆盖到可写目录）。
WARP_STATE_DIR="${WARP_STATE_DIR:-/var/lib/cloudflare-warp}"
WARP_READY_FILE="${WARP_STATE_DIR}/ready"
WARP_PROXY_PORT=40000

# 1) startup.sh 只有在连接确认后才写 ready 标记，标记缺失说明容器尚未真正就绪。
if [[ ! -f "${WARP_READY_FILE}" ]]; then
    exit 1
fi

# 2) 隧道必须是 Connected：优先匹配显式状态行，退回整词匹配并排除 Disconnected
#    （Disconnected 包含 connected 子串，不能用简单子串匹配）。
status_output="$(warp-cli --accept-tos status 2>/dev/null || true)"
if [[ -z "${status_output}" ]]; then
    exit 1
fi
if ! grep -qiE 'Status update:[[:space:]]*Connected' <<<"${status_output}"; then
    if ! grep -qiw 'connected' <<<"${status_output}" || grep -qiw 'disconnected' <<<"${status_output}"; then
        exit 1
    fi
fi

# 3) WARP 本地 socks 代理必须接受连接（timeout 缺失时直接探测，保持兼容）。
if command -v timeout >/dev/null 2>&1; then
    timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/${WARP_PROXY_PORT}" 2>/dev/null || exit 1
else
    bash -c "exec 3<>/dev/tcp/127.0.0.1/${WARP_PROXY_PORT}" 2>/dev/null || exit 1
fi

exit 0
