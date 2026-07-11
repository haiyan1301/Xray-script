#!/usr/bin/env bash

# Routed virtual LAN support. This file is sourced by handler.sh and uses its
# SCRIPT_CONFIG/XRAY_CONFIG globals and common helper functions.

function lan_text() {
    local key="$1"
    echo "${I18N_DATA}" | jq -r --arg key "${key}" '.handler.lan[$key] // $key'
}

function lan_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf -- "%s" "${value}"
}

function lan_ipv4_to_int() {
    local ip="$1"
    local a b c d extra
    IFS='.' read -r a b c d extra <<<"${ip}"
    [[ -z "${extra}" && "${a}" =~ ^[0-9]+$ && "${b}" =~ ^[0-9]+$ && "${c}" =~ ^[0-9]+$ && "${d}" =~ ^[0-9]+$ ]] || return 1
    a=$((10#${a}))
    b=$((10#${b}))
    c=$((10#${c}))
    d=$((10#${d}))
    ((a <= 255 && b <= 255 && c <= 255 && d <= 255)) || return 1
    printf -- "%u" "$(((a << 24) | (b << 16) | (c << 8) | d))"
}

function lan_int_to_ipv4() {
    local value="$1"
    printf -- "%d.%d.%d.%d" \
        "$(((value >> 24) & 255))" \
        "$(((value >> 16) & 255))" \
        "$(((value >> 8) & 255))" \
        "$((value & 255))"
}

function lan_is_private_range() {
    local start="$1"
    local end="$2"
    ((start >= 167772160 && end <= 184549375)) && return 0
    ((start >= 2886729728 && end <= 2887778303)) && return 0
    ((start >= 3232235520 && end <= 3232301055)) && return 0
    return 1
}

function lan_normalize_cidr() {
    local cidr="$1"
    local ip prefix ip_int mask network broadcast

    [[ "${cidr}" == */* ]] || return 1
    ip="${cidr%/*}"
    prefix="${cidr##*/}"
    [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
    prefix=$((10#${prefix}))
    ((prefix >= 8 && prefix <= 32)) || return 1
    ip_int="$(lan_ipv4_to_int "${ip}")" || return 1

    if ((prefix == 32)); then
        mask=4294967295
    else
        mask=$(((4294967295 << (32 - prefix)) & 4294967295))
    fi
    network=$((ip_int & mask))
    broadcast=$((network | (4294967295 ^ mask)))
    lan_is_private_range "${network}" "${broadcast}" || return 1
    printf -- "%s/%s" "$(lan_int_to_ipv4 "${network}")" "${prefix}"
}

function lan_cidr_bounds() {
    local cidr="$1"
    local ip prefix start mask end
    ip="${cidr%/*}"
    prefix="${cidr##*/}"
    start="$(lan_ipv4_to_int "${ip}")" || return 1
    if ((prefix == 32)); then
        mask=4294967295
    else
        mask=$(((4294967295 << (32 - prefix)) & 4294967295))
    fi
    start=$((start & mask))
    end=$((start | (4294967295 ^ mask)))
    printf -- "%s %s" "${start}" "${end}"
}

function lan_cidrs_overlap() {
    local left="$1"
    local right="$2"
    local left_start left_end right_start right_end
    read -r left_start left_end <<<"$(lan_cidr_bounds "${left}")" || return 1
    read -r right_start right_end <<<"$(lan_cidr_bounds "${right}")" || return 1
    ((left_start <= right_end && right_start <= left_end))
}

function lan_parse_cidrs() {
    local raw="$1"
    local cidrs='[]'
    local item normalized existing pending
    local -a values=()
    IFS=',' read -r -a values <<<"${raw}"

    ((${#values[@]} > 0)) || return 1
    for item in "${values[@]}"; do
        item="$(lan_trim "${item}")"
        normalized="$(lan_normalize_cidr "${item}")" || return 1
        if echo "${cidrs}" | jq -e --arg cidr "${normalized}" 'index($cidr) != null' >/dev/null; then
            continue
        fi
        while IFS= read -r pending; do
            [[ -z "${pending}" ]] && continue
            lan_cidrs_overlap "${normalized}" "${pending}" && return 2
        done < <(echo "${cidrs}" | jq -r '.[]')
        while IFS= read -r existing; do
            [[ -z "${existing}" ]] && continue
            if lan_cidrs_overlap "${normalized}" "${existing}"; then
                return 2
            fi
        done < <(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.sites[]?.localCidrs[]?')
        cidrs="$(echo "${cidrs}" | jq --arg cidr "${normalized}" '. + [$cidr]')"
    done
    echo "${cidrs}"
}

function lan_validate_site_id() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]
}

function lan_validate_host() {
    local value="$1"
    [[ -n "${value}" && "${value}" != *[[:space:]]* && "${value}" != *'/'* ]]
}

function lan_validate_server_name() {
    local value="$1"
    [[ "${value}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

function lan_port_is_available() {
    local port="$1"
    [[ "${port}" =~ ^[1-9][0-9]*$ ]] && ((port >= 1 && port <= 65535)) || return 1
    [[ "${port}" -ne 32768 ]] || return 1

    if echo "${SCRIPT_CONFIG}" | jq -e --argjson port "${port}" '
        (.xray.port == $port) or
        any(.xray.nodes[]?; (.port | tonumber) == $port) or
        ((.xray.reverse // 0) == 1 and (.xray.reversePort // 8443) == $port)
    ' >/dev/null; then
        return 1
    fi
    return 0
}

function lan_strip_xray_config() {
    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq '
        .inbounds = ((.inbounds // []) | map(select((.tag // "") != "lan-hub-in"))) |
        .routing.rules = ((.routing.rules // []) | map(select(
            (.ruleTag // "") != "lan-deny-undeclared" and
            (((.ruleTag // "") | startswith("lan-route-")) | not)
        )))
    ')"
}

function handler_apply_lan_config() {
    lan_strip_xray_config

    local enabled site_count
    enabled="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.enabled // 0')"
    site_count="$(echo "${SCRIPT_CONFIG}" | jq -r '(.xray.lan.sites // []) | length')"
    [[ "${enabled}" -eq 1 && "${site_count}" -gt 0 ]] || return 0

    local port target server_name private_key short_id sites clients inbound route_rules block_rule
    port="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.port')"
    target="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.target')"
    server_name="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.serverName')"
    private_key="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.privateKey')"
    short_id="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.shortId')"
    sites="$(echo "${SCRIPT_CONFIG}" | jq -c '.xray.lan.sites')"

    clients="$(echo "${sites}" | jq '[.[] | [
        {
            email: ("lan-access-" + .id),
            id: .accessUuid,
            flow: "xtls-rprx-vision",
            level: 0
        },
        {
            email: ("lan-reverse-" + .id),
            id: .reverseUuid,
            flow: "xtls-rprx-vision",
            level: 0,
            reverse: {tag: .reverseTag}
        }
    ]] | add')"

    inbound="$(jq -n \
        --argjson port "${port}" \
        --argjson clients "${clients}" \
        --arg target "${target}:443" \
        --arg serverName "${server_name}" \
        --arg privateKey "${private_key}" \
        --arg shortId "${short_id}" '
        {
            tag: "lan-hub-in",
            listen: "0.0.0.0",
            port: $port,
            protocol: "vless",
            settings: {
                clients: $clients,
                decryption: "none"
            },
            streamSettings: {
                network: "raw",
                security: "reality",
                realitySettings: {
                    show: false,
                    dest: $target,
                    xver: 0,
                    serverNames: [$serverName],
                    privateKey: $privateKey,
                    shortIds: [$shortId]
                }
            },
            sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic"],
                routeOnly: true
            }
        }
    ')"

    route_rules="$(echo "${sites}" | jq --argjson sites "${sites}" '
        ($sites | map("lan-access-" + .id)) as $accessUsers |
        [ .[] | {
            ruleTag: ("lan-route-" + .id),
            user: $accessUsers,
            ip: .localCidrs,
            outboundTag: .reverseTag
        } ]
    ')"
    block_rule="$(echo "${sites}" | jq '
        [.[].id as $id | "lan-access-" + $id, "lan-reverse-" + $id] as $users |
        {
            ruleTag: "lan-deny-undeclared",
            user: $users,
            outboundTag: "block"
        }
    ')"

    XRAY_CONFIG="$(echo "${XRAY_CONFIG}" | jq \
        --argjson inbound "${inbound}" \
        --argjson routeRules "${route_rules}" \
        --argjson blockRule "${block_rule}" '
        .inbounds += [$inbound] |
        (.routing.rules | map(.ruleTag // "") | index("private-ip")) as $privateIndex |
        if $privateIndex == null then
            .routing.rules += ($routeRules + [$blockRule])
        else
            .routing.rules = (.routing.rules[:$privateIndex] + $routeRules + [$blockRule] + .routing.rules[$privateIndex:])
        end
    ')"
}

function handler_lan_open_firewall() {
    local enabled port
    enabled="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.enabled // 0')"
    [[ "${enabled}" -eq 1 ]] || return 0
    port="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.port // empty')"
    [[ -n "${port}" ]] || return 0
    if command -v ufw &>/dev/null; then
        ufw allow "${port}"/tcp >/dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${port}"/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif ! iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
        ip6tables -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
    fi
}

function handler_lan_close_firewall() {
    local port="$1"
    [[ -n "${port}" ]] || return 0
    if command -v ufw &>/dev/null; then
        ufw delete allow "${port}"/tcp >/dev/null 2>&1 || true
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --remove-port="${port}"/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    else
        while iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || break
        done
        while ip6tables -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null; do
            ip6tables -D INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || break
        done
    fi
}

function handler_lan_add_site() {
    local enabled site_id site_name cidr_input cidrs_result parse_status mode_choice mode lan_interface access_uuid reverse_uuid reverse_tag site
    enabled="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.enabled // 0')"
    if [[ "${enabled}" -ne 1 ]]; then
        echo -e "${RED}[$(lan_text error)]${NC} $(lan_text not_enabled)" >&2
        return 1
    fi

    while true; do
        printf "${GREEN}[LAN]${NC} %s" "$(lan_text site_id_prompt)" >&2
        read -r site_id
        site_id="${site_id,,}"
        if ! lan_validate_site_id "${site_id}"; then
            echo -e "${YELLOW}[LAN]${NC} $(lan_text site_id_invalid)" >&2
            continue
        fi
        if echo "${SCRIPT_CONFIG}" | jq -e --arg id "${site_id}" 'any(.xray.lan.sites[]?; .id == $id)' >/dev/null; then
            echo -e "${YELLOW}[LAN]${NC} $(lan_text site_exists)" >&2
            continue
        fi
        break
    done

    printf "${GREEN}[LAN]${NC} %s" "$(lan_text site_name_prompt)" >&2
    read -r site_name
    site_name="${site_name:-${site_id}}"

    while true; do
        printf "${GREEN}[LAN]${NC} %s" "$(lan_text cidrs_prompt)" >&2
        read -r cidr_input
        cidrs_result="$(lan_parse_cidrs "${cidr_input}")"
        parse_status=$?
        if [[ "${parse_status}" -eq 0 ]]; then
            break
        elif [[ "${parse_status}" -eq 2 ]]; then
            echo -e "${YELLOW}[LAN]${NC} $(lan_text cidrs_overlap)" >&2
        else
            echo -e "${YELLOW}[LAN]${NC} $(lan_text cidrs_invalid)" >&2
        fi
    done

    printf "${GREEN}[LAN]${NC} %s" "$(lan_text mode_prompt)" >&2
    read -r mode_choice
    mode_choice="${mode_choice:-1}"
    mode='host'
    lan_interface=''
    if [[ "${mode_choice}" == '2' ]]; then
        mode='gateway'
        while [[ -z "${lan_interface}" || ! "${lan_interface}" =~ ^[a-zA-Z0-9_.:-]+$ ]]; do
            printf "${GREEN}[LAN]${NC} %s" "$(lan_text interface_prompt)" >&2
            read -r lan_interface
        done
    fi

    access_uuid="$(exec_generate '--uuid')"
    reverse_uuid="$(exec_generate '--uuid')"
    reverse_tag="lan-reverse-${site_id}"
    site="$(jq -n \
        --arg id "${site_id}" \
        --arg name "${site_name}" \
        --argjson cidrs "${cidrs_result}" \
        --arg mode "${mode}" \
        --arg lanInterface "${lan_interface}" \
        --arg accessUuid "${access_uuid}" \
        --arg reverseUuid "${reverse_uuid}" \
        --arg reverseTag "${reverse_tag}" '
        {
            id: $id,
            name: $name,
            localCidrs: $cidrs,
            mode: $mode,
            lanInterface: $lanInterface,
            accessUuid: $accessUuid,
            reverseUuid: $reverseUuid,
            reverseTag: $reverseTag
        }
    ')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --argjson site "${site}" '.xray.lan.sites += [$site]')"
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
    handler_lan_export_all >/dev/null 2>&1 || true
    echo -e "${GREEN}[LAN]${NC} $(lan_text site_added): ${site_id}" >&2
    echo -e "${YELLOW}[LAN]${NC} $(lan_text redeploy_required)" >&2
}

function handler_lan_enable() {
    local enabled xray_version port target server_name server_address key_pair private_key public_key short_id
    enabled="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.enabled // 0')"
    if [[ "${enabled}" -eq 1 ]]; then
        echo -e "${YELLOW}[LAN]${NC} $(lan_text already_enabled)" >&2
        return 0
    fi
    xray_version="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.version // ""')"
    if [[ -z "${xray_version}" ]] || ! command -v xray >/dev/null 2>&1; then
        echo -e "${RED}[LAN]${NC} $(lan_text xray_required)" >&2
        return 1
    fi

    while true; do
        printf "${GREEN}[LAN]${NC} %s" "$(lan_text port_prompt)" >&2
        read -r port
        port="${port:-9443}"
        lan_port_is_available "${port}" && break
        echo -e "${YELLOW}[LAN]${NC} $(lan_text port_invalid)" >&2
    done

    target="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.serverNames[0] // .xray.target // ""')"
    target="${target:-www.microsoft.com}"
    while true; do
        printf "${GREEN}[LAN]${NC} %s [%s]: " "$(lan_text target_prompt)" "${target}" >&2
        read -r server_name
        server_name="${server_name:-${target}}"
        lan_validate_server_name "${server_name}" && break
        echo -e "${YELLOW}[LAN]${NC} $(lan_text host_invalid)" >&2
    done
    target="${server_name}"

    server_address="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.serverAddress // ""')"
    while true; do
        printf "${GREEN}[LAN]${NC} %s" "$(lan_text server_address_prompt)" >&2
        read -r server_address
        lan_validate_host "${server_address}" && break
        echo -e "${YELLOW}[LAN]${NC} $(lan_text host_invalid)" >&2
    done

    key_pair="$(exec_generate '--x25519')"
    private_key="$(echo "${key_pair}" | cut -d, -f1)"
    public_key="$(echo "${key_pair}" | cut -d, -f2)"
    short_id="$(exec_generate '--short-id' 8)"
    if [[ -z "${private_key}" || -z "${public_key}" || -z "${short_id}" ]]; then
        echo -e "${RED}[LAN]${NC} $(lan_text keygen_failed)" >&2
        return 1
    fi

    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq \
        --argjson port "${port}" \
        --arg target "${target}" \
        --arg serverName "${server_name}" \
        --arg serverAddress "${server_address}" \
        --arg privateKey "${private_key}" \
        --arg publicKey "${public_key}" \
        --arg shortId "${short_id}" '
        .xray.lan = ((.xray.lan // {}) + {
            enabled: 1,
            role: "hub",
            port: $port,
            target: $target,
            serverName: $serverName,
            serverAddress: $serverAddress,
            privateKey: $privateKey,
            publicKey: $publicKey,
            shortId: $shortId,
            tunName: (.xray.lan.tunName // "xray0"),
            mtu: (.xray.lan.mtu // 1400),
            sites: (.xray.lan.sites // [])
        })
    ')"
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
    echo -e "${GREEN}[LAN]${NC} $(lan_text enabled)" >&2

    if [[ "$(echo "${SCRIPT_CONFIG}" | jq '.xray.lan.sites | length')" -eq 0 ]]; then
        handler_lan_add_site
    fi
}

function handler_lan_disable() {
    local port
    port="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.port // empty')"
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq '.xray.lan.enabled = 0')"
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
    handler_lan_close_firewall "${port}"
    echo -e "${GREEN}[LAN]${NC} $(lan_text disabled)" >&2
}

function handler_lan_list() {
    local enabled count
    enabled="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.enabled // 0')"
    count="$(echo "${SCRIPT_CONFIG}" | jq -r '(.xray.lan.sites // []) | length')"
    echo -e "${GREEN}$(lan_text status_title)${NC}"
    echo "$(lan_text status_enabled): ${enabled}"
    echo "$(lan_text status_port): $(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.port // "-"')"
    echo "$(lan_text status_server): $(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.serverAddress // "-"')"
    echo "$(lan_text status_sites): ${count}"
    echo "------------------------------------------------------"
    echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.sites[]? | "\(.id)\t\(.name)\t\(.mode)\t\(.localCidrs | join(","))"'
}

function handler_lan_remove_site() {
    local site_id count
    handler_lan_list >&2
    printf "${GREEN}[LAN]${NC} %s" "$(lan_text remove_prompt)" >&2
    read -r site_id
    site_id="${site_id,,}"
    count="$(echo "${SCRIPT_CONFIG}" | jq --arg id "${site_id}" '[.xray.lan.sites[]? | select(.id == $id)] | length')"
    if [[ "${count}" -eq 0 ]]; then
        echo -e "${RED}[LAN]${NC} $(lan_text site_not_found)" >&2
        return 1
    fi
    SCRIPT_CONFIG="$(echo "${SCRIPT_CONFIG}" | jq --arg id "${site_id}" '.xray.lan.sites |= map(select(.id != $id))')"
    write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"
    rm -rf "${SCRIPT_CONFIG_DIR}/lan/${site_id}"
    rm -f "${SCRIPT_CONFIG_DIR}/lan/xray-lan-${site_id}.tar.gz"
    handler_lan_export_all >/dev/null 2>&1 || true
    echo -e "${GREEN}[LAN]${NC} $(lan_text site_removed): ${site_id}" >&2
    echo -e "${YELLOW}[LAN]${NC} $(lan_text redeploy_required)" >&2
}

function handler_lan_export_site() {
    local site_id site site_count server_address port server_name public_key short_id tun_name mtu remote_cidrs local_cidrs mode lan_interface
    local access_uuid reverse_uuid reverse_in stream_settings config metadata export_root export_dir archive
    site_count="$(echo "${SCRIPT_CONFIG}" | jq -r '(.xray.lan.sites // []) | length')"
    if [[ "${site_count}" -eq 0 ]]; then
        echo -e "${RED}[LAN]${NC} $(lan_text no_sites)" >&2
        return 1
    fi
    site_id="${1:-}"
    if [[ -z "${site_id}" ]]; then
        handler_lan_list >&2
        printf "${GREEN}[LAN]${NC} %s" "$(lan_text export_prompt)" >&2
        read -r site_id
    fi
    site_id="${site_id,,}"
    site="$(echo "${SCRIPT_CONFIG}" | jq -c --arg id "${site_id}" '.xray.lan.sites[]? | select(.id == $id)')"
    if [[ -z "${site}" ]]; then
        echo -e "${RED}[LAN]${NC} $(lan_text site_not_found)" >&2
        return 1
    fi

    server_address="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.serverAddress')"
    port="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.port')"
    server_name="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.serverName')"
    public_key="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.publicKey')"
    short_id="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.shortId')"
    tun_name="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.tunName // "xray0"')"
    mtu="$(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.mtu // 1400')"
    remote_cidrs="$(echo "${SCRIPT_CONFIG}" | jq -c --arg id "${site_id}" '[.xray.lan.sites[] | select(.id != $id) | .localCidrs[]] | unique')"
    local_cidrs="$(echo "${site}" | jq -c '.localCidrs')"
    mode="$(echo "${site}" | jq -r '.mode')"
    lan_interface="$(echo "${site}" | jq -r '.lanInterface')"
    access_uuid="$(echo "${site}" | jq -r '.accessUuid')"
    reverse_uuid="$(echo "${site}" | jq -r '.reverseUuid')"
    reverse_in="lan-in-${site_id}"

    stream_settings="$(jq -n \
        --arg serverName "${server_name}" \
        --arg publicKey "${public_key}" \
        --arg shortId "${short_id}" '
        {
            network: "raw",
            security: "reality",
            realitySettings: {
                serverName: $serverName,
                publicKey: $publicKey,
                shortId: $shortId,
                fingerprint: "chrome",
                spiderX: "/"
            }
        }
    ')"

    config="$(jq -n \
        --arg tunName "${tun_name}" \
        --argjson mtu "${mtu}" \
        --arg reverseIn "${reverse_in}" \
        --arg address "${server_address}" \
        --argjson port "${port}" \
        --arg accessUuid "${access_uuid}" \
        --arg reverseUuid "${reverse_uuid}" \
        --argjson stream "${stream_settings}" \
        --argjson localCidrs "${local_cidrs}" '
        {
            log: {loglevel: "warning"},
            routing: {
                rules: [
                    {ruleTag: "lan-reverse-local", inboundTag: [$reverseIn], outboundTag: "lan-local"},
                    {ruleTag: "lan-tun-to-hub", inboundTag: ["lan-tun"], outboundTag: "lan-to-hub"}
                ]
            },
            inbounds: [
                {
                    tag: "lan-tun",
                    port: 0,
                    protocol: "tun",
                    settings: {name: $tunName, MTU: $mtu}
                }
            ],
            outbounds: [
                {
                    tag: "lan-to-hub",
                    protocol: "vless",
                    settings: {
                        address: $address,
                        port: $port,
                        id: $accessUuid,
                        flow: "xtls-rprx-vision",
                        encryption: "none"
                    },
                    streamSettings: $stream
                },
                {
                    tag: "lan-reverse-to-hub",
                    protocol: "vless",
                    settings: {
                        address: $address,
                        port: $port,
                        id: $reverseUuid,
                        flow: "xtls-rprx-vision",
                        encryption: "none",
                        reverse: {tag: $reverseIn}
                    },
                    streamSettings: $stream
                },
                {
                    tag: "lan-local",
                    protocol: "freedom",
                    settings: {
                        finalRules: ($localCidrs | map({action: "allow", network: "tcp,udp", ip: .}))
                    }
                },
                {tag: "block", protocol: "blackhole"}
            ]
        }
    ')"
    metadata="$(jq -n \
        --arg id "${site_id}" \
        --arg tunName "${tun_name}" \
        --argjson mtu "${mtu}" \
        --arg mode "${mode}" \
        --arg lanInterface "${lan_interface}" \
        --argjson localCidrs "${local_cidrs}" \
        --argjson remoteCidrs "${remote_cidrs}" '
        {
            siteId: $id,
            tunName: $tunName,
            mtu: $mtu,
            mode: $mode,
            lanInterface: $lanInterface,
            localCidrs: $localCidrs,
            remoteCidrs: $remoteCidrs
        }
    ')"

    export_root="${SCRIPT_CONFIG_DIR}/lan"
    export_dir="${export_root}/${site_id}"
    mkdir -p "${export_dir}"
    chmod 700 "${export_root}" "${export_dir}"
    printf '%s\n' "${config}" >"${export_dir}/config.json"
    printf '%s\n' "${metadata}" >"${export_dir}/site.json"
    cp -f "${CONFIG_DIR}/lan/install-edge.sh" "${export_dir}/install.sh"
    cp -f "${CONFIG_DIR}/lan/xray-lan-net.sh" "${export_dir}/xray-lan-net.sh"
    cp -f "${CONFIG_DIR}/lan/xray-lan.service" "${export_dir}/xray-lan.service"
    cp -f "${CONFIG_DIR}/lan/README.txt" "${export_dir}/README.txt"
    chmod 600 "${export_dir}/config.json" "${export_dir}/site.json"
    chmod 700 "${export_dir}/install.sh" "${export_dir}/xray-lan-net.sh"

    archive="${export_root}/xray-lan-${site_id}.tar.gz"
    if command -v tar &>/dev/null; then
        tar -C "${export_root}" -czf "${archive}" "${site_id}"
        chmod 600 "${archive}"
    fi
    echo -e "${GREEN}[LAN]${NC} $(lan_text exported): ${export_dir}" >&2
    [[ -f "${archive}" ]] && echo -e "${GREEN}[LAN]${NC} $(lan_text archive): ${archive}" >&2
}

function handler_lan_export_all() {
    local site_id
    while IFS= read -r site_id; do
        [[ -n "${site_id}" ]] && handler_lan_export_site "${site_id}"
    done < <(echo "${SCRIPT_CONFIG}" | jq -r '.xray.lan.sites[]?.id')
}
