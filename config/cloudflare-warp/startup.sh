#!/usr/bin/env bash
set -euo pipefail

warp_svc_pid=''
forwarding_pid=''

function cleanup() {
    trap - EXIT HUP INT TERM
    for child_pid in "${forwarding_pid}" "${warp_svc_pid}"; do
        [[ -z "${child_pid}" ]] || kill "${child_pid}" 2>/dev/null || true
    done
    # A stuck daemon must not keep Docker's stop/restart waiting indefinitely.
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

function warp_cli() {
    timeout -k 2 10 warp-cli --accept-tos "$@"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Registration files can outlive the daemon's proxy settings. Always start and
# configure the daemon, including when a volume already contains registration.
warp-svc &
warp_svc_pid=$!
ready=0
for ((attempt = 0; attempt < 30; attempt++)); do
    kill -0 "${warp_svc_pid}" 2>/dev/null || { echo "Cloudflare WARP daemon exited during startup" >&2; exit 1; }
    if warp_cli settings >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
[[ "${ready}" -eq 1 ]] || { echo "Cloudflare WARP daemon did not become ready" >&2; exit 1; }

if ! warp_cli registration show >/dev/null 2>&1; then
    echo "Registering Cloudflare WARP"
    warp_cli registration new
    warp_cli registration show >/dev/null
fi
echo "Setting Cloudflare WARP mode to proxy"
warp_cli mode proxy
echo "Connecting Cloudflare WARP"
warp_cli connect

echo "Forwarding 0.0.0.0:40001 to 127.0.0.1:40000"
socat TCP-LISTEN:40001,reuseaddr,fork TCP:127.0.0.1:40000 &
forwarding_pid=$!

# Either process is required for a working proxy. Let Docker restart the whole
# container if the listener or daemon exits, including an unexpected clean exit.
status=0
wait -n "${warp_svc_pid}" "${forwarding_pid}" || status=$?
[[ "${status}" -ne 0 ]] || status=1
exit "${status}"
