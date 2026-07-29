#!/usr/bin/env bash
set -euo pipefail

[[ -n "${FAKE_ACME_LOG:-}" ]] && printf '%s\n' "$*" >>"${FAKE_ACME_LOG}"

case "${1:-}" in
--list)
    printf '%s\n' 'Main_Domain KeyLength SAN_Domains CA Created Renew'
    if [[ "${FAKE_ACME_HAS_CERT:-0}" == '1' ]]; then
        printf '%s\n' "${FAKE_ACME_DOMAIN:-cdn.example.com} ${FAKE_ACME_KEY_LENGTH:-ec-256} no zerossl 2026-01-01 2026-02-01"
    fi
    ;;
--issue)
    [[ "${FAKE_ACME_FAIL_ISSUE:-0}" != '1' ]]
    ;;
--renew)
    [[ "${FAKE_ACME_FAIL_RENEW:-0}" != '1' ]]
    ;;
--remove)
    [[ "${FAKE_ACME_FAIL_REMOVE:-0}" != '1' ]]
    ;;
--install-cert)
    if [[ "${FAKE_ACME_FAIL_INSTALL:-0}" == '1' ]]; then
        exit 1
    fi
    key_file=''
    fullchain_file=''
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --key-file)
            key_file="$2"
            shift 2
            ;;
        --fullchain-file)
            fullchain_file="$2"
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done
    [[ -n "${key_file}" && -n "${fullchain_file}" ]]
    cp -f "${FAKE_ACME_KEY:?}" "${key_file}"
    cp -f "${FAKE_ACME_CERT:?}" "${fullchain_file}"
    ;;
*)
    ;;
esac
