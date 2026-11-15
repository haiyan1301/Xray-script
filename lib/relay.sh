#!/usr/bin/env bash

# Relay state is the source of truth. Runtime edits are guarded separately by
# runtime-guard.sh before regeneration; this module never imports runtime rules.
[[ -n "${_RELAY_SH_LOADED:-}" ]] && return 0
readonly _RELAY_SH_LOADED=1
readonly _RELAY_LIB_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

function relay_error() {
    printf '[Relay] %s\n' "$1" >&2
}

function relay_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

# Accept only the deliberately supported domain/full syntax. In particular,
# regex/geosite/URL/wildcard inputs must not acquire surprising meanings.
function relay_normalize_domains() {
    local raw="$1" item host prefix normalized result='[]'
    raw="${raw//,/$'\n'}"
    while IFS= read -r item || [[ -n "${item}" ]]; do
        item="$(relay_trim "${item}")"
        [[ -n "${item}" ]] || continue
        item="${item,,}"
        prefix='domain'
        case "${item}" in
        domain:*) host="${item#domain:}" ;;
        full:*) prefix='full'; host="${item#full:}" ;;
        *) host="${item}" ;;
        esac
        if ! valid_domain "${host}"; then
            relay_error 'Invalid relay domain. Use example.com, domain:example.com or full:host.example.com.'
            return 1
        fi
        normalized="${prefix}:${host}"
        result="$(printf '%s\n' "${result}" | jq -c --arg item "${normalized}" 'if index($item) == null then . + [$item] else . end')" || return 1
    done <<<"${raw}"
    printf '%s\n' "${result}"
}

# Canonical comparison avoids bypassing loop checks with expanded IPv6 or
# IPv4-mapped IPv6. No DNS lookup is made for relay endpoints.
function relay_canonical_ip() {
    local address="${1,,}" part left right tail a b c d missing index
    local -a groups=() prefix=() suffix=()
    valid_ip_literal "${address}" || return 1
    if [[ "${address}" != *:* ]]; then
        IFS='.' read -r a b c d <<<"${address}"
        printf '%d.%d.%d.%d\n' "$((10#${a}))" "$((10#${b}))" "$((10#${c}))" "$((10#${d}))"
        return
    fi
    if [[ "${address}" == *.* ]]; then
        tail="${address##*:}"
        IFS='.' read -r a b c d <<<"${tail}"
        printf -v tail '%x:%x' "$(((10#${a} << 8) | 10#${b}))" "$(((10#${c} << 8) | 10#${d}))"
        address="${address%:*}:${tail}"
    fi
    if [[ "${address}" == *::* ]]; then
        left="${address%%::*}"; right="${address#*::}"
        [[ -z "${left}" ]] || IFS=':' read -r -a prefix <<<"${left}"
        [[ -z "${right}" ]] || IFS=':' read -r -a suffix <<<"${right}"
        missing=$((8 - ${#prefix[@]} - ${#suffix[@]}))
        groups=("${prefix[@]}")
        for ((index = 0; index < missing; index++)); do groups+=(0); done
        groups+=("${suffix[@]}")
    else
        IFS=':' read -r -a groups <<<"${address}"
    fi
    address=''
    for part in "${groups[@]}"; do
        printf -v part '%04x' "$((16#${part}))"
        address+="${address:+:}${part}"
    done
    if [[ "${address}" == '0000:0000:0000:0000:0000:ffff:'* ]]; then
        a=$((16#${groups[6]})); b=$((16#${groups[7]}))
        printf '%d.%d.%d.%d\n' "$((a >> 8))" "$((a & 255))" "$((b >> 8))" "$((b & 255))"
    else
        printf '%s\n' "${address}"
    fi
}

function relay_address_is_local() {
    local canonical="$1" value normalized address_json local_addresses
    case "${canonical}" in
    127.*|0.0.0.0|0000:0000:0000:0000:0000:0000:0000:0000|0000:0000:0000:0000:0000:0000:0000:0001) return 0 ;;
    esac
    if command -v ip >/dev/null 2>&1; then
        if address_json="$(ip -j addr show 2>/dev/null)" &&
            local_addresses="$(printf '%s\n' "${address_json}" | jq -er '.[].addr_info[]?.local' 2>/dev/null)"; then
            :
        else
            # CentOS 7 ships iproute versions predating JSON output. Preserve
            # local-address loop detection there using the stable one-line form.
            local_addresses="$(ip -o addr show 2>/dev/null | awk '{print $4}')"
        fi
        while IFS= read -r value; do
            value="${value%/*}"
            [[ -n "${value}" ]] || continue
            normalized="$(relay_canonical_ip "${value}")" || continue
            [[ "${normalized}" != "${canonical}" ]] || return 0
        done <<<"${local_addresses}"
    fi
    return 1
}

function relay_validate_node() {
    local node="$1" state="${2:-${SCRIPT_CONFIG:-}}" address canonical port
    [[ -n "${state}" ]] || state='{}'
    if ! printf '%s\n' "${node}" | jq -e '
        def text: type == "string" and (test("[\u0000-\u001f\u007f-\u009f]") | not);
        type == "object" and
        (.id | type) == "string" and (.id | test("^[A-Za-z0-9_-]{1,64}$")) and
        (.name | text) and (.name | test("[^[:space:]]")) and (.name | length) <= 128 and
        (.address | text) and
        (.port | type) == "number" and (.port | floor) == .port and .port >= 1 and .port <= 65535 and
        (.protocol | type) == "string" and
        (if has("outbound") then (.outbound | type) == "object"
         elif (.protocol | IN("socks", "vless")) then
        (if .protocol == "socks" then
            ((.username // "") | text) and ((.password // "") | text) and
            (((.username // "") | utf8bytelength) <= 255) and (((.password // "") | utf8bytelength) <= 255) and
            ((((.username // "") | length) == 0) == (((.password // "") | length) == 0))
        else
            (.uuid | type) == "string" and (.uuid | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")) and
            (.serverName | text) and
            (.publicKey | type) == "string" and (.publicKey | test("^[A-Za-z0-9_-]{43}$")) and
            ((.shortId // "") | type) == "string" and ((.shortId // "") | test("^([0-9a-fA-F]{2}){0,8}$")) and
            ((.flow // "") | IN("", "xtls-rprx-vision", "xtls-rprx-vision-udp443")) and
            (.encryption | text) and (.encryption | length) > 0 and (.encryption | length) <= 12000 and
            (.encryption == "none" or (.encryption | test("^mlkem768x25519plus\\.[A-Za-z0-9._+/-]+$")))
        end)
        else false end)
    ' >/dev/null 2>&1; then
        relay_error 'Invalid relay node fields or credentials.'
        return 1
    fi
    if printf '%s\n' "${node}" | jq -e 'has("outbound")' >/dev/null; then
        if ! printf '%s\n' "${node}" | python3 "${_RELAY_LIB_DIR}/relay-links.py" --validate-node >/dev/null; then
            relay_error 'Invalid imported relay outbound.'; return 1
        fi
    fi
    address="$(printf '%s\n' "${node}" | jq -r '.address')" || return 1
    if ! canonical="$(relay_canonical_ip "${address}")"; then
        if printf '%s\n' "${node}" | jq -e 'has("outbound")' >/dev/null && valid_hostname "${address}"; then
            # Syntax-only for saved nodes: disabling relay or saving an inactive
            # node must not depend on the availability of its DNS resolver.
            return 0
        fi
        relay_error 'The relay endpoint must be an IP address, or a hostname in an imported link.'
        return 1
    fi
    case "${canonical}" in
    0.0.0.0|255.255.255.255|0000:0000:0000:0000:0000:0000:0000:0000)
        relay_error 'An unspecified or broadcast address cannot be a relay endpoint.'; return 1 ;;
    esac
    if ! printf '%s\n' "${node}" | jq -e 'has("outbound")' >/dev/null &&
        [[ "$(printf '%s\n' "${node}" | jq -r '.protocol')" == 'vless' ]] &&
        ! valid_domain "$(printf '%s\n' "${node}" | jq -r '.serverName')"; then
        relay_error 'Invalid REALITY server name.'; return 1
    fi
    port="$(printf '%s\n' "${node}" | jq -r '.port')" || return 1
    relay_check_listener_loop "${canonical}" "${port}" "${state}"
}

function relay_check_listener_loop() {
    local canonical="$1" port="$2" state="${3:-${SCRIPT_CONFIG:-}}" runtime="${XRAY_CONFIG:-}"
    [[ -n "${state}" ]] || state='{}'
    [[ -n "${runtime}" ]] || runtime='{}'
    if relay_address_is_local "${canonical}" && jq -ne --argjson port "${port}" --argjson state "${state}" --argjson runtime "${runtime}" '
        [$state.xray.port, ($state.xray.nodes[]?.port),
         (if ($state.xray.reverse // 0) == 1 then ($state.xray.reversePort // 8443) else empty end),
         (if ($state.xray.lan.enabled // 0) == 1 then ($state.xray.lan.port // 9443) else empty end),
         ($runtime.inbounds[]?.port), 32768] | any(. == $port)
    ' >/dev/null 2>&1; then
        relay_error 'The relay points to a local Xray listener and would form a loop.'
        return 1
    fi
}

# Resolve only when an imported hostname node is actually used. The validated
# address is pinned into the candidate outbound, avoiding a second DNS lookup
# by Xray after the loop check. Every returned address is checked before one
# is selected; an attacker-controlled mixed local/remote answer is rejected.
function relay_resolve_endpoint() {
    local address="$1" port="$2" resolved value rest canonical result='[]'
    if canonical="$(relay_canonical_ip "${address}")"; then
        relay_check_listener_loop "${canonical}" "${port}" || return 1
        printf '%s\n' "${canonical}"
        return
    fi
    valid_hostname "${address}" || return 1
    if ! resolved="$(timeout 5 getent ahosts "${address}" 2>/dev/null)" || [[ -z "${resolved}" ]]; then
        relay_error 'Relay endpoint DNS resolution failed or timed out.'; return 1
    fi
    while read -r value rest; do
        [[ -n "${value}" ]] || continue
        canonical="$(relay_canonical_ip "${value}")" || { relay_error 'DNS returned an invalid relay address.'; return 1; }
        case "${canonical}" in
        0.0.0.0|255.255.255.255|0000:0000:0000:0000:0000:0000:0000:0000)
            relay_error 'DNS returned an unspecified or broadcast relay address.'; return 1 ;;
        esac
        if printf '%s\n' "${result}" | jq -e --arg ip "${canonical}" 'index($ip) != null' >/dev/null; then
            continue
        fi
        relay_check_listener_loop "${canonical}" "${port}" || return 1
        result="$(printf '%s\n' "${result}" | jq -c --arg ip "${canonical}" '. + [$ip]')" || return 1
        if [[ "$(printf '%s\n' "${result}" | jq 'length')" -gt 64 ]]; then
            relay_error 'Too many DNS addresses for a relay endpoint.'; return 1
        fi
    done <<<"${resolved}"
    [[ "${result}" != '[]' ]] || { relay_error 'DNS returned no usable relay address.'; return 1; }
    printf '%s\n' "${result}" | jq -r '.[0]'
}

function normalize_and_validate_relay_state() {
    local normalized node domains
    normalized="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq '
        if (.xray.relay // null) == null then .xray.relay = {nodes:[],active:null,mode:"off",domains:[]} else . end
    ')" || return 1
    if ! printf '%s\n' "${normalized}" | jq -e '
        .xray.relay as $r |
        ($r | type) == "object" and ($r.nodes | type) == "array" and
        ($r.mode | IN("off", "all", "domains")) and
        ($r.domains | type) == "array" and all($r.domains[]; type == "string") and
        (($r.nodes | map(.id) | unique | length) == ($r.nodes | length)) and
        (($r.active == null) or (($r.active | type) == "string" and any($r.nodes[]; .id == $r.active))) and
        (if $r.mode != "off" then $r.active != null else true end)
    ' >/dev/null 2>&1; then
        relay_error 'Invalid relay state or missing active node.'; return 1
    fi
    while IFS= read -r node; do
        relay_validate_node "${node}" "${normalized}" || return 1
    done < <(printf '%s\n' "${normalized}" | jq -c '.xray.relay.nodes[]')
    domains="$(relay_normalize_domains "$(printf '%s\n' "${normalized}" | jq -r '.xray.relay.domains | join("\n")')")" || return 1
    if [[ "$(printf '%s\n' "${normalized}" | jq -r '.xray.relay.mode')" == 'domains' && "${domains}" == '[]' ]]; then
        relay_error 'Domain relay mode requires at least one domain.'; return 1
    fi
    SCRIPT_CONFIG="$(printf '%s\n' "${normalized}" | jq --argjson domains "${domains}" '.xray.relay.domains = $domains')" || return 1
}

function relay_build_outbound() {
    local node="$1" canonical
    relay_validate_node "${node}" || return 1
    canonical="$(relay_resolve_endpoint "$(printf '%s\n' "${node}" | jq -r '.address')" "$(printf '%s\n' "${node}" | jq -r '.port')")" || return 1
    if printf '%s\n' "${node}" | jq -e 'has("outbound")' >/dev/null; then
        if printf '%s\n' "${node}" | jq -e '
            .outbound.protocol == "vless" and .outbound.streamSettings.network == "kcp" and
            .outbound.streamSettings.security == "none" and
            .outbound.settings.vnext[0].users[0].encryption == "none"
        ' >/dev/null && python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).is_global else 1)' "${canonical}"; then
            relay_error 'Public mKCP relays require VLESS encryption in current Xray. Enable encryption on server B and import its new link, or use a private relay IP.'
            return 1
        fi
        printf '%s\n' "${node}" | jq --arg address "${canonical}" '
            . as $node | .outbound + {tag:("xray-script-relay-" + $node.id)} |
            if .settings.vnext? != null then .settings.vnext[0].address = $address
            elif .settings.servers? != null then .settings.servers[0].address = $address
            else .settings.address = $address end
        '
        return
    fi
    # Modern Xray accepts the long-standing vnext form as well as flat VLESS
    # settings; use the former for compatibility with existing installations.
    printf '%s\n' "${node}" | jq --arg address "${canonical}" '
        . as $n |
        {tag:("xray-script-relay-" + .id),protocol:.protocol} +
        (if .protocol == "socks" then
            {settings:{servers:[{address:$address,port:.port} +
                (if (.username // "") != "" then {users:[{user:.username,pass:.password}]} else {} end)]}}
        else
            {settings:{vnext:[{address:$address,port:.port,users:[{id:.uuid,encryption:.encryption,flow:(.flow // "")}]}]},
             streamSettings:{network:"raw",security:"reality",realitySettings:{
                 serverName:.serverName,publicKey:.publicKey,shortId:(.shortId // ""),fingerprint:"chrome",spiderX:"/"
             }}}
        end)
    '
}

# Sniffing must supply routing metadata without replacing the original target.
# Otherwise an HTTP Host/SNI can turn a private-IP request into a domain before
# the private-IP blocking rule sees it. Keep this protection when relay is off.
# The compatibility flag is for reconstructing a pre-fix baseline only; a new
# candidate must always run this normalization.
function relay_preserve_sniffed_targets() {
    [[ "${_XRAY_LEGACY_SNIFFING:-0}" != 1 ]] || return 0
    XRAY_CONFIG="$(printf '%s\n' "${XRAY_CONFIG}" | jq '
        .inbounds |= map(
            if (.protocol | IN("vless","vmess","trojan","shadowsocks","hysteria","hysteria2","socks","http")) and
               (((.tag // "") | test("^(api$|lan-|reverse-|anti-steal-)")) | not) and
               (.sniffing | type) == "object"
            then .sniffing.routeOnly = true else . end
        )
    ')" || return 1
}

function handler_apply_relay_config() {
    local mode node outbound
    normalize_and_validate_relay_state || return 1
    mode="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq -r '.xray.relay.mode')" || return 1
    relay_preserve_sniffed_targets || return 1
    # Repeated application always produces a single selected outbound/rule.
    XRAY_CONFIG="$(printf '%s\n' "${XRAY_CONFIG}" | jq '
        .outbounds |= map(select(((.tag // "") | startswith("xray-script-relay-")) | not)) |
        .routing.rules |= map(select(((.ruleTag // "") | startswith("xray-script-relay")) | not))
    ')" || return 1
    [[ "${mode}" != 'off' ]] || return 0
    node="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq -c '.xray.relay as $r | $r.nodes[] | select(.id == $r.active)')" || return 1
    outbound="$(relay_build_outbound "${node}")" || return 1
    XRAY_CONFIG="$(printf '%s\n' "${XRAY_CONFIG}" | jq --argjson outbound "${outbound}" --argjson relay "$(printf '%s\n' "${SCRIPT_CONFIG}" | jq -c '.xray.relay')" '
        def business:
            (.protocol | IN("vless","vmess","trojan","shadowsocks","hysteria","hysteria2","socks","http")) and
            (((.tag // "") | test("^(api$|lan-|reverse-|anti-steal-)")) | not);
        def special:
            ((.ruleTag // "") | test("^(api$|reverse-|anti-steal-|lan-)"));
        [.inbounds[] | select(business) | .tag] as $tags |
        if ($tags | length) == 0 then error("No managed business inbounds for relay") else . end |
        if .outbounds[0].tag != "direct" then error("Default direct outbound must remain first") else . end |
        .outbounds += [$outbound] |
        {type:"field",ruleTag:"xray-script-relay",inboundTag:$tags,network:"tcp,udp",outboundTag:$outbound.tag} as $base |
        ($base + (if $relay.mode == "domains" then {domain:$relay.domains} else {} end)) as $rule |
        [.routing.rules[] | select(special)] as $special |
        [.routing.rules[] | select((special | not) and .outboundTag == "block")] as $blocks |
        [.routing.rules[] | select((special | not) and .outboundTag != "block")] as $rest |
        .routing.rules = ($special + $blocks + [$rule] + $rest) |
        if $relay.mode == "domains" then
            .inbounds |= map(if business then
                .sniffing = ((.sniffing // {}) + {enabled:true,routeOnly:true}) |
                .sniffing.destOverride = (((.sniffing.destOverride // []) + ["http","tls","quic"]) | unique)
            else . end)
        else . end
    ')" || return 1

}

# xray run -test does not reliably reject every missing route target or proxy
# cycle. Verify references before publishing either half of the transaction.
function relay_validate_runtime_references() {
    local config="$1"
    if ! printf '%s\n' "${config}" | jq -e '
        def strings: type == "array" and all(.[]; type == "string" and length > 0);
        def unique_tags: length == (unique | length);
        def acyclic($graph; $node; $path):
            if ($path | index($node)) != null then false
            else all($graph[$node][]?; acyclic($graph; .; $path + [$node])) end;
        . as $c |
        [.inbounds[]?.tag] as $in |
        [.outbounds[]?.tag] as $physical |
        ([$c.api.tag // empty] + [$c.reverse.portals[]?.tag] +
         [$c.inbounds[]?.settings.clients[]?.reverse.tag // empty]) as $virtualOut |
        ($physical + $virtualOut) as $out |
        ($in + [$c.reverse.bridges[]?.tag] + [$c.outbounds[]?.settings.reverse.tag // empty] +
         [$c.outbounds[]?.settings.vnext[]?.users[]?.reverse.tag // empty]) as $sources |
        [.routing.balancers[]?.tag] as $balancers |
        [.routing.rules[]?.ruleTag | select(. != null and . != "")] as $ruleTags |
        (reduce $c.outbounds[]? as $o ({};
            .[$o.tag] = ([$o.proxySettings.tag // empty, $o.streamSettings.sockopt.dialerProxy // empty]))) as $graph |
        ($c | type) == "object" and ($c.inbounds | type) == "array" and
        ($c.outbounds | type) == "array" and ($c.routing.rules | type) == "array" and
        ($in | strings) and ($in | unique_tags) and ($sources | unique_tags) and
        ($out | strings) and ($out | unique_tags) and
        ($balancers | strings) and ($balancers | unique_tags) and ($ruleTags | unique_tags) and
        all($c.routing.rules[]?;
            ((.outboundTag // null) == null or (.outboundTag as $tag | $out | index($tag)) != null) and
            ((.balancerTag // null) == null or (.balancerTag as $tag | $balancers | index($tag)) != null) and
            (((.outboundTag // null) != null) != ((.balancerTag // null) != null)) and
            (if .inboundTag? != null then (.inboundTag | strings) and all(.inboundTag[]; . as $tag | $sources | index($tag) != null) else true end)
        ) and
        all($c.routing.balancers[]?;
            (.selector | strings) and
            ([.selector[] as $prefix | $physical[] | select(startswith($prefix))] | length) > 0 and
            (if (.fallbackTag // "") != "" then .fallbackTag as $tag | $out | index($tag) != null else true end)
        ) and
        all($graph[][]; . as $tag | $physical | index($tag) != null) and
        all($physical[]; acyclic($graph; .; [])) and
        all($c.inbounds[]?.streamSettings.sockopt.dialerProxy? | select(. != null); . as $tag | $physical | index($tag) != null)
    ' >/dev/null 2>&1; then
        relay_error 'Invalid runtime references: duplicate tags, missing routing/proxy targets or a proxy cycle.'
        return 1
    fi
}
