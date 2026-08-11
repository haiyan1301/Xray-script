#!/usr/bin/env bash

set -Eeuo pipefail

XRAY_DIR="${XRAY_DIR_OVERRIDE:-/usr/local/share/xray}"

GEOIP_URL="${GEOIP_URL_OVERRIDE:-https://github.com/Loyalsoldier/v2ray-rules-dat/raw/release/geoip.dat}"
GEOSITE_URL="${GEOSITE_URL_OVERRIDE:-https://github.com/Loyalsoldier/v2ray-rules-dat/raw/release/geosite.dat}"

mkdir -p -- "${XRAY_DIR}"
temp_dir="$(mktemp -d "${XRAY_DIR}/.geodata.XXXXXX")"
geoip_existed=0
geosite_existed=0
replacement_started=0
commit_complete=0
xray_was_active=0

function restore_geodata() {
    local restore_status=0
    if [[ "${geoip_existed}" -eq 1 ]]; then
        cp -p -- "${temp_dir}/geoip.dat.old" "${XRAY_DIR}/geoip.dat" || restore_status=1
    else
        rm -f -- "${XRAY_DIR}/geoip.dat" || restore_status=1
    fi
    if [[ "${geosite_existed}" -eq 1 ]]; then
        cp -p -- "${temp_dir}/geosite.dat.old" "${XRAY_DIR}/geosite.dat" || restore_status=1
    else
        rm -f -- "${XRAY_DIR}/geosite.dat" || restore_status=1
    fi
    if [[ "${xray_was_active}" -eq 1 ]]; then
        systemctl restart xray >/dev/null 2>&1 || restore_status=1
    fi
    return "${restore_status}"
}

function cleanup_geodata_transaction() {
    local status="$1"
    local cleanup_temp=1

    trap - EXIT HUP INT TERM
    if [[ "${status}" -ne 0 && "${replacement_started}" -eq 1 && "${commit_complete}" -eq 0 ]]; then
        if ! restore_geodata; then
            cleanup_temp=0
            printf 'GeoData rollback failed; recovery files retained at: %s\n' "${temp_dir}" >&2
        fi
    fi
    if [[ "${cleanup_temp}" -eq 1 ]]; then
        rm -rf -- "${temp_dir}"
    fi
    exit "${status}"
}
trap 'cleanup_geodata_transaction "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

curl -fsSL --retry 3 -o "${temp_dir}/geoip.dat.new" "${GEOIP_URL}"
curl -fsSL --retry 3 -o "${temp_dir}/geosite.dat.new" "${GEOSITE_URL}"
[[ -s "${temp_dir}/geoip.dat.new" && -s "${temp_dir}/geosite.dat.new" ]]

if [[ -f "${XRAY_DIR}/geoip.dat" ]]; then
    cp -p -- "${XRAY_DIR}/geoip.dat" "${temp_dir}/geoip.dat.old"
    geoip_existed=1
fi
if [[ -f "${XRAY_DIR}/geosite.dat" ]]; then
    cp -p -- "${XRAY_DIR}/geosite.dat" "${temp_dir}/geosite.dat.old"
    geosite_existed=1
fi
systemctl -q is-active xray && xray_was_active=1 || true

replacement_started=1
mv -f -- "${temp_dir}/geoip.dat.new" "${XRAY_DIR}/geoip.dat"
mv -f -- "${temp_dir}/geosite.dat.new" "${XRAY_DIR}/geosite.dat"
if [[ "${xray_was_active}" -eq 1 ]]; then
    systemctl restart xray
fi
commit_complete=1
