#!/usr/bin/env bash

function start_forwarding() {
    echo "Forwarding 0.0.0.0:40001 to 127.0.0.1:40000"
    socat TCP-LISTEN:40001,reuseaddr,fork TCP:127.0.0.1:40000 &
}

if [ -f /var/lib/cloudflare-warp/reg.json ]; then
    start_forwarding

    echo "Starting Cloudflare WARP"
    warp-svc
else
    echo "Cloudflare WARP not registered, try start a daemon and register it."
    warp-svc >&/dev/null &
    warp_svc_pid=$!
    sleep 5
    echo "Registering Cloudflare WARP"
    warp-cli --accept-tos registration new
    echo "Setting Cloudflare WARP mode to proxy"
    warp-cli --accept-tos mode proxy
    echo "Connecting Cloudflare WARP"
    warp-cli --accept-tos connect

    # 注册成功与否决定容器能否工作：显式校验，不再依赖外部重启把失败掩盖过去。
    if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
        echo "Cloudflare WARP registration failed" >&2
        exit 1
    fi

    # 注册已完成，无需重启容器：直接开始转发并等待已在运行的守护进程。
    start_forwarding
    wait "${warp_svc_pid}" || true
    echo "Cloudflare WARP daemon exited, starting it in the foreground" >&2
    warp-svc
fi
