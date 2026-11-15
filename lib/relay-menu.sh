#!/usr/bin/env bash
# Interactive relay management. Sourced by core/handler.sh after lib/relay.sh.
# Credentials stay in protected JSON files and are never included in summaries.
[[ -n "${_RELAY_MENU_SH_LOADED:-}" ]] && return 0
readonly _RELAY_MENU_SH_LOADED=1

function relay_message() { t ".handler.relay.$1"; }

function relay_read_value() {
    printf '%s ' "$(relay_message "$1")" >&2
    local value
    IFS= read -r value || return 1
    printf '%s\n' "${value}"
}

function relay_show_nodes() {
    printf '\n%s\n' "$(relay_message nodes)" >&2
    printf '%s\n' "${SCRIPT_CONFIG}" | jq -r '
        (.xray.relay.nodes // []) | to_entries[] |
        [((.key + 1) | tostring), .value.name, .value.address,
         (.value.port | tostring), .value.protocol] |
        map(tostring | gsub("[\u0000-\u001f\u007f]"; "?")) | @tsv
    ' >&2
}

function relay_choose_node() {
    local choice count
    count="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq '.xray.relay.nodes // [] | length')" || return 1
    if [[ "${count}" -eq 0 ]]; then
        log_tip "$(relay_message no_nodes)" >&2
        return 1
    fi
    relay_show_nodes || return 1
    choice="$(relay_read_value node_number)" || return 1
    [[ "${choice}" =~ ^[1-9][0-9]{0,5}$ ]] && ((choice <= count)) || {
        log_error "$(relay_message invalid_choice)" >&2
        return 1
    }
    printf '%s\n' "${SCRIPT_CONFIG}" | jq -r --argjson index "$((choice - 1))" '.xray.relay.nodes[$index].id'
}

# Every mutation uses the same paired configuration/restart rollback as WARP.
function relay_store_state() {
    local relay="$1" previous_script_config="${SCRIPT_CONFIG}" previous_xray_config candidate
    previous_xray_config="$(jq '.' "${XRAY_CONFIG_PATH}")" || {
        log_error "$(relay_message config_unavailable)" >&2
        return 1
    }
    candidate="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq --argjson relay "${relay}" '.xray.relay = $relay')" || return 1
    SCRIPT_CONFIG="${candidate}"
    if apply_xray_state_transaction "${previous_script_config}" "${previous_xray_config}"; then
        log_config "$(relay_message saved)" >&2
        return 0
    fi
    return 1
}

function relay_edit_node() {
    local node_id="${1:-}" old='{}' node field value default protocol relay
    if [[ -n "${node_id}" ]]; then
        old="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq -ce --arg id "${node_id}" '.xray.relay.nodes[] | select(.id == $id)')" || return 1
        log_tip "$(relay_message edit_hint)" >&2
    else
        node_id="r$(date +%s)-${RANDOM}${RANDOM}"
    fi
    node="$(jq -n --arg id "${node_id}" '{id:$id}')" || return 1
    for field in name address port protocol uuid serverName publicKey shortId flow encryption username password; do
        # Protocol determines the remaining fields; replacing a protocol clears
        # obsolete credentials rather than carrying them into another protocol.
        if [[ "${field}" == 'uuid' || "${field}" == 'serverName' || "${field}" == 'publicKey' ||
              "${field}" == 'shortId' || "${field}" == 'flow' || "${field}" == 'encryption' ]]; then
            [[ "${protocol}" == 'vless' ]] || continue
        fi
        if [[ "${field}" == 'username' || "${field}" == 'password' ]]; then
            [[ "${protocol}" == 'socks' ]] || continue
        fi
        value="$(bash "${READ_PATH}" --relay-field "${field}")" || return 1
        if [[ -n "${1:-}" && -z "${value}" ]]; then
            value="$(printf '%s\n' "${old}" | jq -r --arg field "${field}" '.[$field] // ""')" || return 1
        elif [[ "${value}" == '-' ]]; then
            value=''
        fi
        if [[ "${field}" == 'protocol' ]]; then
            case "${value,,}" in
            1|vless) value='vless' ;;
            2|socks|socks5) value='socks' ;;
            *) log_error "$(relay_message invalid_node)" >&2; return 1 ;;
            esac
            protocol="${value}"
        elif [[ "${field}" == 'encryption' && -z "${value}" ]]; then
            value='none'
        elif [[ "${field}" == 'port' ]]; then
            [[ "${value}" =~ ^[0-9]{1,5}$ ]] && ((10#${value} >= 1 && 10#${value} <= 65535)) || {
                log_error "$(relay_message invalid_node)" >&2
                return 1
            }
            node="$(printf '%s\n' "${node}" | jq --argjson port "$((10#${value}))" '.port = $port')" || return 1
            continue
        fi
        node="$(printf '%s\n' "${node}" | jq --arg field "${field}" --arg value "${value}" '.[$field] = $value')" || return 1
    done
    relay_validate_node "${node}" || {
        log_error "$(relay_message invalid_node)" >&2
        return 1
    }
    relay="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq --argjson node "${node}" '
        (.xray.relay // {nodes:[], active:null, mode:"off", domains:[]}) |
        .nodes = (if any(.nodes[]; .id == $node.id) then
            .nodes | map(if .id == $node.id then $node else . end)
        else .nodes + [$node] end)
    ')" || return 1
    relay_store_state "${relay}"
}

function relay_import_node() {
    local node_id="${1:-}" link node relay
    if ! cmd_exists python3; then
        log_error "$(relay_message import_requirements)" >&2
        return 1
    fi
    link="$(bash "${READ_PATH}" --relay-field shareLink)" || return 1
    node="$(printf '%s\n' "${link}" | python3 "${PROJECT_ROOT}/lib/relay-links.py")" || {
        log_error "$(relay_message invalid_link)" >&2
        return 1
    }
    link=''
    printf '%s\n' "$(relay_message preview)" >&2
    printf '%s\n' "${node}" | jq -r '[.name,.address,(.port | tostring),.protocol] |
        map(gsub("[\u0000-\u001f\u007f]"; "?")) | @tsv' >&2
    [[ -n "${node_id}" ]] || node_id="r$(date +%s)-${RANDOM}${RANDOM}"
    node="$(printf '%s\n' "${node}" | jq --arg id "${node_id}" '.id = $id')" || return 1
    relay_validate_node "${node}" || {
        log_error "$(relay_message invalid_node)" >&2
        return 1
    }
    relay="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq --argjson node "${node}" '
        (.xray.relay // {nodes:[], active:null, mode:"off", domains:[]}) |
        .nodes = (if any(.nodes[]; .id == $node.id) then
            .nodes | map(if .id == $node.id then $node else . end)
        else .nodes + [$node] end)
    ')" || return 1
    relay_store_state "${relay}"
}

function relay_edit_imported_node() {
    local node_id="$1" choice name relay
    choice="$(relay_read_value imported_edit)" || return 1
    case "${choice}" in
    1)
        name="$(bash "${READ_PATH}" --relay-field name)" || return 1
        [[ -n "${name}" ]] || return 0
        relay="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq --arg id "${node_id}" --arg name "${name}" '
            .xray.relay | .nodes |= map(if .id == $id then .name = $name else . end)
        ')" || return 1
        relay_store_state "${relay}"
        ;;
    2) relay_import_node "${node_id}" ;;
    *) log_error "$(relay_message invalid_choice)" >&2; return 1 ;;
    esac
}

function relay_delete_node() {
    local node_id="$1" relay active mode answer
    active="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq -r '.xray.relay.active // ""')" || return 1
    mode="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq -r '.xray.relay.mode // "off"')" || return 1
    if [[ "${active}" == "${node_id}" && "${mode}" != 'off' ]]; then
        log_error "$(relay_message active_delete)" >&2
        return 1
    fi
    answer="$(relay_read_value confirm_delete)" || return 1
    [[ "${answer,,}" == 'y' ]] || return 0
    relay="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq --arg id "${node_id}" '
        .xray.relay | .nodes |= map(select(.id != $id)) |
        if .active == $id then .active = null else . end
    ')" || return 1
    relay_store_state "${relay}"
}

# Match a listening socket owned by our exact child. A busy random port must
# never make a different local SOCKS proxy look like the node being tested.
function relay_test_owns_listener() {
    local process_id="$1" port="$2" descriptor target inode port_hex inodes=' '
    local slot local_address remote_address status queues timer retries uid expires rest
    [[ -r "/proc/${process_id}/net/tcp" ]] || return 1
    printf -v port_hex '%04X' "${port}"
    for descriptor in /proc/"${process_id}"/fd/*; do
        target="$(readlink -- "${descriptor}" 2>/dev/null)" || continue
        if [[ "${target}" =~ ^socket:\[([0-9]+)\]$ ]]; then
            inodes+="${BASH_REMATCH[1]} "
        fi
    done
    while read -r slot local_address remote_address status queues timer retries uid expires inode rest; do
        [[ "${local_address}" == "0100007F:${port_hex}" && "${status}" == '0A' &&
            "${inodes}" == *" ${inode} "* ]] && return 0
    done <"/proc/${process_id}/net/tcp"
    return 1
}

# Run a disposable Xray bound to loopback. This does not alter service/state.
# UDP status is a real SOCKS5 UDP/DNS exchange; absence of python3 is unknown.
function relay_test_node() (
    local node_id="$1" node outbound work_dir='' test_pid='' port attempt tcp_ok=0 udp_ok=0
    node="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq -ce --arg id "${node_id}" '.xray.relay.nodes[] | select(.id == $id)')" || return 1
    relay_validate_node "${node}" || return 1
    if [[ ! -x "${XRAY_BIN_PATH}" ]] || ! cmd_exists curl; then
        log_error "$(relay_message test_requirements)" >&2
        return 1
    fi
    outbound="$(relay_build_outbound "${node}")" || return 1
    umask 077
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/xray-relay-test.XXXXXX")" || return 1
    function relay_test_cleanup() {
        local status="$1" remaining
        trap - EXIT HUP INT TERM
        if [[ -n "${test_pid}" ]]; then
            kill "${test_pid}" 2>/dev/null || true
            for ((remaining = 0; remaining < 20; remaining++)); do
                kill -0 "${test_pid}" 2>/dev/null || break
                sleep 0.1
            done
            kill -KILL "${test_pid}" 2>/dev/null || true
            wait "${test_pid}" 2>/dev/null || true
        fi
        rm -rf -- "${work_dir}"
        exit "${status}"
    }
    trap 'relay_test_cleanup "$?"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    port="$((20000 + RANDOM))"
    jq -n --argjson port "${port}" --argjson outbound "${outbound}" '{
        log:{loglevel:"none"},
        inbounds:[{tag:"relay-test",listen:"127.0.0.1",port:$port,
            protocol:"socks",settings:{auth:"noauth",udp:true,ip:"127.0.0.1"}}],
        outbounds:[$outbound]
    }' >"${work_dir}/config.json" || return 1
    (
        # A test child must not keep the operation lock alive if the menu
        # process is forcibly terminated before its cleanup trap can run.
        if [[ -n "${_XRAY_RUNTIME_GUARD_LOCK_FD:-}" ]]; then
            exec {_XRAY_RUNTIME_GUARD_LOCK_FD}>&-
        fi
        exec "${XRAY_BIN_PATH}" run -c "${work_dir}/config.json"
    ) >"${work_dir}/xray.log" 2>&1 &
    test_pid=$!
    # Wait at most three seconds for the local listener, before making requests.
    for ((attempt = 0; attempt < 30; attempt++)); do
        kill -0 "${test_pid}" 2>/dev/null || break
        if relay_test_owns_listener "${test_pid}" "${port}"; then
            break
        fi
        sleep 0.1
    done
    if ! kill -0 "${test_pid}" 2>/dev/null || ((attempt >= 30)); then
        log_error "$(relay_message test_start_failed)" >&2
        return 1
    fi
    log_test "$(relay_message tcp_testing)" >&2
    if curl --proxy "socks5h://127.0.0.1:${port}" --noproxy '' \
        --connect-timeout 4 --max-time 8 --retry 0 --proto '=https' \
        --fail --silent 'https://api.ipify.org' >"${work_dir}/egress" 2>/dev/null &&
        valid_ip_literal "$(cat "${work_dir}/egress")"; then
        tcp_ok=1
        log_pass "$(relay_message tcp_pass) $(cat "${work_dir}/egress")" >&2
    else
        log_fail "$(relay_message tcp_fail)" >&2
    fi
    if cmd_exists python3; then
        if python3 "${PROJECT_ROOT}/lib/relay-probe.py" "${port}"; then
            udp_ok=1
            log_pass "$(relay_message udp_pass)" >&2
        else
            log_fail "$(relay_message udp_fail)" >&2
        fi
    else
        log_warn "$(relay_message udp_unknown)" >&2
    fi
    log_tip "$(relay_message udp_scope)" >&2
    [[ "${tcp_ok}" -eq 1 && "${udp_ok}" -eq 1 ]]
)

function relay_apply_policy() {
    local node_id="$1" choice domains='[]' raw='' line answer relay node
    choice="$(relay_read_value mode_prompt)" || return 1
    case "${choice}" in
    1) choice='all' ;;
    2)
        choice='domains'
        log_tip "$(relay_message domains_prompt)" >&2
        # Commas and newline input are both accepted; a blank line ends input.
        while :; do
            IFS= read -r line || return 1
            [[ -n "${line}" ]] || break
            raw+="${line}"$'\n'
        done
        domains="$(relay_normalize_domains "${raw}")" || {
            log_error "$(relay_message invalid_domains)" >&2
            return 1
        }
        [[ "$(printf '%s\n' "${domains}" | jq 'length')" -gt 0 ]] || return 1
        ;;
    *) log_error "$(relay_message invalid_choice)" >&2; return 1 ;;
    esac
    node="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq -ce --arg id "${node_id}" '.xray.relay.nodes[] | select(.id == $id)')" || return 1
    printf '%s\n' "$(relay_message preview)" >&2
    printf '%s\n' "${node}" | jq -r '[.name,.address,(.port | tostring),.protocol] |
        map(gsub("[\u0000-\u001f\u007f]"; "?")) | @tsv' >&2
    printf '%s: %s\n' "$(relay_message mode)" "${choice}" >&2
    printf '%s\n' "${domains}" | jq -r '.[]' >&2
    if [[ "${choice}" == 'all' ]]; then
        relay_test_node "${node_id}" || true
        log_warn "$(relay_message all_warning)" >&2
    fi
    answer="$(relay_read_value confirm_apply)" || return 1
    [[ "${answer,,}" == 'y' ]] || return 0
    relay="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq --arg id "${node_id}" --arg mode "${choice}" --argjson domains "${domains}" '
        .xray.relay | .active = $id | .mode = $mode | .domains = $domains
    ')" || return 1
    relay_store_state "${relay}"
}

function handler_relay() {
    local choice node_id relay
    # Validate manual state edits before displaying or changing any node.
    # The normalizer supplies the default for old states in memory only.
    normalize_and_validate_relay_state || return 1
    while :; do
        printf '\n%s\n' "$(relay_message title)" >&2
        printf '%s\n' "${SCRIPT_CONFIG}" | jq -r '
            [.xray.relay.mode, (.xray.relay.active // "-")] |
            map(tostring | gsub("[\u0000-\u001f\u007f]"; "?")) | @tsv
        ' >&2
        relay_show_nodes || return 1
        printf '%s\n' "$(relay_message actions)" >&2
        choice="$(relay_read_value choose)" || return 0
        case "${choice}" in
        0|'') return 0 ;;
        1) relay_import_node || return 1 ;;
        2)
            node_id="$(relay_choose_node)" || continue
            if printf '%s\n' "${SCRIPT_CONFIG}" | jq -e --arg id "${node_id}" 'any(.xray.relay.nodes[]; .id == $id and has("outbound"))' >/dev/null; then
                relay_edit_imported_node "${node_id}" || return 1
            else
                relay_edit_node "${node_id}" || return 1
            fi
            ;;
        3) node_id="$(relay_choose_node)" || continue; relay_test_node "${node_id}" || true ;;
        4) node_id="$(relay_choose_node)" || continue; relay_delete_node "${node_id}" || return 1 ;;
        5) node_id="$(relay_choose_node)" || continue; relay_apply_policy "${node_id}" || return 1 ;;
        6)
            relay="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq '.xray.relay | .mode = "off" | .active = null')" || return 1
            relay_store_state "${relay}" || return 1
            ;;
        7) relay_edit_node || return 1 ;;
        *) log_error "$(relay_message invalid_choice)" >&2 ;;
        esac
    done
}
