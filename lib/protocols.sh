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

function protocol_uses_nginx() {
    case "${1,,}" in
    sni | cdn) return 0 ;;
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
