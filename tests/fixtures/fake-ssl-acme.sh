#!/usr/bin/env bash
set -u

: "${FAKE_ACME_LOG:?}"

printf '%s\n' "$*" >>"${FAKE_ACME_LOG}"

function argument_value() {
    local wanted="$1"
    shift

    while (($# > 0)); do
        if [[ "$1" == "${wanted}" ]]; then
            (($# > 1)) || return 1
            printf '%s\n' "$2"
            return 0
        fi
        shift
    done
    return 1
}

if [[ " $* " == *" --issue "* ]]; then
    issue_count_file="${FAKE_ACME_LOG}.issue.count"
    issue_count=0
    [[ ! -f "${issue_count_file}" ]] || read -r issue_count <"${issue_count_file}"
    issue_count=$((issue_count + 1))
    printf '%s\n' "${issue_count}" >"${issue_count_file}"

    [[ "${FAKE_ACME_FAIL_ALL_ISSUES:-0}" != "1" ]] || exit 1
    if [[ "${FAKE_ACME_FAIL_FIRST_ISSUE:-0}" == "1" &&
        "${issue_count}" -eq 1 ]]; then
        exit 1
    fi
    exit 0
fi

if [[ " $* " == *" --install-cert "* ]]; then
    key_file="$(argument_value --key-file "$@")" || exit 64
    fullchain_file="$(argument_value --fullchain-file "$@")" || exit 64
    reload_command="$(argument_value --reloadcmd "$@")" || exit 64
    : "${FAKE_ACME_NEW_KEY:?}"
    : "${FAKE_ACME_NEW_FULLCHAIN:?}"
    : "${FAKE_ACME_RELOAD_HOOK_FILE:?}"

    printf '%s\n' "${reload_command}" >"${FAKE_ACME_RELOAD_HOOK_FILE}"
    mkdir -p -- "$(dirname -- "${key_file}")" "$(dirname -- "${fullchain_file}")"

    if [[ "${FAKE_ACME_RUN_RELOAD_BEFORE_COPY:-0}" == "1" ]]; then
        bash -c "${reload_command}" || exit 1
    fi

    cp -- "${FAKE_ACME_NEW_KEY}" "${key_file}" || exit 1
    if [[ -n "${FAKE_ACME_SIGNAL_PARENT:-}" ]]; then
        kill -s "${FAKE_ACME_SIGNAL_PARENT}" "${PPID}" || exit 1
        sleep 0.1
        exit 1
    fi
    if [[ "${FAKE_ACME_PARTIAL_INSTALL_FAIL:-0}" == "1" ]]; then
        exit 1
    fi
    cp -- "${FAKE_ACME_NEW_FULLCHAIN}" "${fullchain_file}" || exit 1

    if [[ "${FAKE_ACME_RUN_RELOAD_BEFORE_COPY:-0}" != "1" ]]; then
        bash -c "${reload_command}" || exit 1
    fi
    exit 0
fi

exit 64
