#!/usr/bin/env bash
set -u

: "${FAKE_SYSTEMCTL_LOG:?}"
: "${FAKE_SYSTEMCTL_STATE:?}"

printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG}"

function next_call_number() {
    local action="$1"
    local count_file="${FAKE_SYSTEMCTL_STATE}.${action}.count"
    local count=0

    [[ ! -f "${count_file}" ]] || read -r count <"${count_file}"
    count=$((count + 1))
    printf '%s\n' "${count}" >"${count_file}"
    printf '%s\n' "${count}"
}

function should_fail_call() {
    local action="$1"
    local count="$2"
    local variable_name="FAKE_SYSTEMCTL_FAIL_${action^^}_CALLS"
    local configured_calls="${!variable_name:-}"

    [[ ",${configured_calls}," == *",${count},"* ]]
}

action="${1:-}"
case "${action}" in
is-active)
    [[ "${2:-}" == "--quiet" && "${3:-}" == "nginx" ]] || exit 64
    [[ -f "${FAKE_SYSTEMCTL_STATE}" ]] &&
        [[ "$(cat "${FAKE_SYSTEMCTL_STATE}")" == "active" ]]
    ;;
start|reload|stop)
    [[ "${2:-}" == "nginx" ]] || exit 64
    call_number="$(next_call_number "${action}")"
    should_fail_call "${action}" "${call_number}" && exit 1
    case "${action}" in
    start)
        printf 'active\n' >"${FAKE_SYSTEMCTL_STATE}"
        ;;
    reload)
        [[ "$(cat "${FAKE_SYSTEMCTL_STATE}" 2>/dev/null)" == "active" ]]
        ;;
    stop)
        printf 'inactive\n' >"${FAKE_SYSTEMCTL_STATE}"
        ;;
    esac
    ;;
*)
    exit 64
    ;;
esac
