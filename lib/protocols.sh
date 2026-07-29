#!/usr/bin/env bash

[[ -n "${_PROTOCOLS_SH_LOADED:-}" ]] && return 0
readonly _PROTOCOLS_SH_LOADED=1

# Keep protocol names, menu choices and feature checks in one place.  The
# handler and the interactive menu run in separate processes, so both source
# this file instead of maintaining subtly different case lists.
function protocol_template_tag() {
    case "${1,,}" in
    vision) echo 'Vision' ;;
    xhttp) echo 'XHTTP' ;;
    trojan) echo 'Trojan' ;;
    fallback) echo 'Fallback' ;;
    hy2 | hysteria | hysteria2) echo 'hy2' ;;
    ss2022 | shadowsocks2022) echo 'ss2022' ;;
    mkcp) echo 'mKCP' ;;
    cdn) echo 'CDN' ;;
    sni) echo 'SNI' ;;
    multi) echo 'multi' ;;
    *) return 1 ;;
    esac
}

function protocol_from_menu_choice() {
    case "$1" in
    1) echo 'Vision' ;;
    2) echo 'XHTTP' ;;
    3) echo 'Trojan' ;;
    4) echo 'Fallback' ;;
    5) echo 'hy2' ;;
    6) echo 'ss2022' ;;
    7) echo 'mKCP' ;;
    8) echo 'CDN' ;;
    9) echo 'SNI' ;;
    10) echo 'multi' ;;
    *) return 1 ;;
    esac
}

function protocol_from_multi_menu_choice() {
    case "$1" in
    1) echo 'Vision' ;;
    2) echo 'XHTTP' ;;
    3) echo 'Trojan' ;;
    4) echo 'Fallback' ;;
    5) echo 'hy2' ;;
    6) echo 'ss2022' ;;
    7) echo 'mKCP' ;;
    *) return 1 ;;
    esac
}

function protocol_uses_vless_enc() {
    case "${1,,}" in
    mkcp | vision | xhttp | fallback | sni | cdn) return 0 ;;
    *) return 1 ;;
    esac
}

function protocol_uses_reality() {
    case "${1,,}" in
    vision | xhttp | trojan | fallback | sni) return 0 ;;
    *) return 1 ;;
    esac
}

function normalize_cdn_backend() {
    # Missing and unknown values deliberately fall back to Nginx. This keeps
    # old installations compatible and prevents a corrupted setting from
    # unexpectedly exposing a public Xray TLS listener.
    case "${1,,}" in
    xray) echo 'xray' ;;
    nginx | '') echo 'nginx' ;;
    *) echo 'nginx' ;;
    esac
}

function protocol_uses_nginx() {
    local cdn_backend="${2:-}"

    case "${1,,}" in
    sni) return 0 ;;
    cdn)
        [[ "$(normalize_cdn_backend "${cdn_backend}")" == 'nginx' ]]
        ;;
    *) return 1 ;;
    esac
}

function protocol_uses_xhttp() {
    case "${1,,}" in
    xhttp | trojan | fallback | sni | cdn) return 0 ;;
    *) return 1 ;;
    esac
}

function protocol_reads_public_port() {
    case "${1,,}" in
    sni | cdn | multi) return 1 ;;
    *) return 0 ;;
    esac
}

function protocol_uses_hy2_certificate() {
    [[ "${1,,}" == 'hy2' ]]
}

function normalize_xhttp_path() {
    local path="${1:-}"

    if [[ -z "${path}" || "${path}" == /* ]]; then
        printf '%s\n' "${path}"
    else
        printf '/%s\n' "${path}"
    fi
}

# Validate an XHTTP path against the same rules used by handler_sync_nginx_xhttp_path
# (mirroring check_path in core/check.sh). An empty path is treated as valid:
# non-xhttp protocols legitimately carry an empty .xray.path, and callers that
# require a non-empty path enforce that separately. Returns 0 for a usable path,
# 1 for a root path ("/"), disallowed characters, or consecutive slashes ("//").
function validate_xhttp_path() {
    local path="${1:-}"

    [[ -z "${path}" ]] && return 0
    [[ "${path}" == '/' ]] && return 1
    [[ "${path}" =~ [^a-zA-Z0-9_/.\-] ]] && return 1
    [[ "${path}" =~ // ]] && return 1
    return 0
}
