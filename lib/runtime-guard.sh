#!/usr/bin/env bash
# Protect template rebuilds from silently discarding hand-edited routing.
# Only defines functions; callers own their transaction and service lifetime.

function runtime_guard_error() {
    local reason="$1"
    if [[ "${LANG_PARAM:-}" == 'zh' || "$(printf '%s\n' "${SCRIPT_CONFIG:-null}" | jq -r '.language // ""' 2>/dev/null)" == 'zh' ]]; then
        printf '已停止重建 Xray 配置：%s\n' "${reason}" >&2
        printf '%s\n' '请先备份运行 JSON 和脚本状态，再核对手动出站、路由及其引用；恢复脚本生成的配置后重试。现有运行配置未被自动采纳或覆盖。' >&2
    else
        printf 'Xray configuration rebuild stopped: %s\n' "${reason}" >&2
        printf '%s\n' 'Back up the runtime JSON and script state, then reconcile manual outbounds, routing and references. Restore the script-generated configuration before retrying. Existing routing was not adopted or overwritten.' >&2
    fi
    return 1
}

# Array order is intentional: outbound[0] is the default, rules use first match,
# and adding an inbound can otherwise leave its traffic using default direct.
# Inbound authentication/key rotations and log edits do not affect this digest.
# Optional routing-related modules must also be protected against being dropped.
function runtime_routing_projection() {
    printf '%s\n' "$1" | jq -sceS '
        if length != 1 then error("one JSON document required") else .[0] end |
        if type != "object" or (.outbounds | type) != "array" or
            (.inbounds | type) != "array" or (.routing | type) != "object" or
            (.routing.rules | type) != "array"
        then error("invalid runtime routing structure") else . end |
        {
            outbounds: .outbounds,
            routing: .routing,
            reverse: (.reverse // null),
            inbounds: [.inbounds[] | {
                tag: (.tag // null), listen: (.listen // null),
                port: (.port // null), protocol: (.protocol // null),
                sniffing: (.sniffing // null),
                fallbacks: (.settings.fallbacks // null),
                target: (if .protocol == "dokodemo-door" then .settings else null end),
                clients: [.settings.clients[]? | {email:(.email // null), reverse:(.reverse // null)}],
                users: [.settings.users[]? | {email:(.email // null), reverse:(.reverse // null)}],
                stream: ((.streamSettings // null) |
                    if type == "object" then del(.realitySettings.privateKey, .realitySettings.mldsa65Seed, .tlsSettings.certificates)
                    else . end)
            }],
            api: (.api // null), dns: (.dns // null), fakedns: (.fakedns // null),
            observatory: (.observatory // null),
            burstObservatory: (.burstObservatory // null),
            transport: (.transport // null)
        }
    ' 2>/dev/null
}

function runtime_routing_snapshot() {
    local projection digest
    projection="$(runtime_routing_projection "$1")" || return 1
    digest="$(printf '%s' "${projection}" | sha256sum)" || return 1
    digest="${digest%% *}"
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
    jq -cn --arg digest "${digest}" '{version:1,sha256:$digest}'
}

function runtime_guard_file_digest() {
    local path="$1" digest
    if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        printf '%s' 'absent'
        return 0
    fi
    [[ -f "${path}" && -r "${path}" ]] || return 1
    digest="$(sha256sum <"${path}")" || return 1
    digest="${digest%% *}"
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${digest}"
}

# STATE is the old, trusted script state, not an automatically adopted runtime.
# A legacy installation without a snapshot needs a generation of that old state
# supplied by the caller in EXPECTED; that generation must have no side effects.
function runtime_guard_begin() {
    local state="$1" expected="${2:-}" saved runtime actual runtime_digest script_digest
    # Preserve an existing guard until the replacement baseline verifies. A
    # failed post-write verification must not make a rollback bypass checks.
    saved="$(printf '%s\n' "${state}" | jq -c '.xray.runtimeRoutingSnapshot // null')" || return 1
    runtime_digest="$(runtime_guard_file_digest "${XRAY_CONFIG_PATH}")" || {
        runtime_guard_error 'the runtime configuration cannot be read / 无法读取运行配置'
        return 1
    }
    script_digest="$(runtime_guard_file_digest "${SCRIPT_CONFIG_PATH}")" || {
        runtime_guard_error 'the script state cannot be read / 无法读取脚本状态'
        return 1
    }
    if [[ "${runtime_digest}" == 'absent' ]]; then
        if [[ "${saved}" != 'null' ]]; then
            runtime_guard_error 'the previously managed runtime JSON is missing / 已管理的运行 JSON 已丢失'
            return 1
        fi
    else
        runtime="$(cat -- "${XRAY_CONFIG_PATH}")" || return 1
        actual="$(runtime_routing_snapshot "${runtime}")" || {
            runtime_guard_error 'invalid runtime JSON or routing structure / 运行 JSON 或路由结构无效'
            return 1
        }
        if [[ "${saved}" == 'null' ]]; then
            if [[ -z "${expected}" ]]; then
                runtime_guard_error 'legacy routing has no verified baseline / 旧版路由缺少已验证的基准'
                return 1
            fi
            saved="$(runtime_routing_snapshot "${expected}")" || return 1
        elif ! printf '%s\n' "${saved}" | jq -e '
            type == "object" and .version == 1 and
            (.sha256 | type) == "string" and (.sha256 | test("^[0-9a-f]{64}$"))
        ' >/dev/null 2>&1; then
            runtime_guard_error 'invalid saved routing baseline / 已保存的路由基准无效'
            return 1
        fi
        if [[ "$(printf '%s\n' "${saved}" | jq -r '.sha256')" != "$(printf '%s\n' "${actual}" | jq -r '.sha256')" ]]; then
            runtime_guard_error 'manual outbound/routing/inbound changes detected / 检测到手动修改出站、路由或入口'
            return 1
        fi
        # Keep the verified legacy baseline in memory so resets/upgrades can
        # preserve it; committing is still exclusively the caller's decision.
        SCRIPT_CONFIG="$(printf '%s\n' "${SCRIPT_CONFIG:-$state}" | jq --argjson snapshot "${actual}" '.xray.runtimeRoutingSnapshot = $snapshot')" || return 1
    fi
    _XRAY_RUNTIME_GUARD_RUNTIME_DIGEST="${runtime_digest}"
    _XRAY_RUNTIME_GUARD_SCRIPT_DIGEST="${script_digest}"
    _XRAY_RUNTIME_GUARD_ARMED=1
    runtime_guard_assert_current
}

# Call immediately before the first rename in a two-file commit. Comparing
# exact bytes here also catches another editor changing credentials or logs
# while a candidate was being generated/validated.
function runtime_guard_assert_current() {
    [[ "${_XRAY_RUNTIME_GUARD_ARMED:-0}" == 1 ]] || return 0
    local runtime_digest script_digest
    runtime_digest="$(runtime_guard_file_digest "${XRAY_CONFIG_PATH}")" || {
        runtime_guard_error 'the runtime configuration is no longer readable / 运行配置已无法读取'
        return 1
    }
    script_digest="$(runtime_guard_file_digest "${SCRIPT_CONFIG_PATH}")" || {
        runtime_guard_error 'the script state is no longer readable / 脚本状态已无法读取'
        return 1
    }
    if [[ "${runtime_digest}" != "${_XRAY_RUNTIME_GUARD_RUNTIME_DIGEST}" ||
        "${script_digest}" != "${_XRAY_RUNTIME_GUARD_SCRIPT_DIGEST}" ]]; then
        runtime_guard_error 'configuration changed during this operation; retry after reconciliation / 操作期间配置被修改，请核对后重试'
        return 1
    fi
}

# Use only after this process intentionally wrote the script state. This never
# refreshes/adopts the runtime digest, so manual runtime edits still abort.
function runtime_guard_refresh_script_digest() {
    [[ "${_XRAY_RUNTIME_GUARD_ARMED:-0}" == 1 ]] || return 0
    _XRAY_RUNTIME_GUARD_SCRIPT_DIGEST="$(runtime_guard_file_digest "${SCRIPT_CONFIG_PATH}")"
}

function runtime_guard_record_candidate() {
    local snapshot
    snapshot="$(runtime_routing_snapshot "${XRAY_CONFIG}")" || return 1
    SCRIPT_CONFIG="$(printf '%s\n' "${SCRIPT_CONFIG}" | jq --argjson snapshot "${snapshot}" '.xray.runtimeRoutingSnapshot = $snapshot')"
}

# Paired commits serialize both values with one trailing newline. Establish
# those known bytes as the expected files, never adopt freshly re-read bytes:
# another editor may have changed either file immediately after the renames.
function runtime_guard_after_commit() {
    local runtime_content="$1" script_content="$2" digest
    digest="$(printf '%s\n' "${runtime_content}" | sha256sum)" || return 1
    _XRAY_RUNTIME_GUARD_RUNTIME_DIGEST="${digest%% *}"
    digest="$(printf '%s\n' "${script_content}" | sha256sum)" || return 1
    _XRAY_RUNTIME_GUARD_SCRIPT_DIGEST="${digest%% *}"
    _XRAY_RUNTIME_GUARD_ARMED=1
    runtime_guard_assert_current
}

function runtime_guard_disarm() {
    _XRAY_RUNTIME_GUARD_ARMED=0
    unset _XRAY_RUNTIME_GUARD_RUNTIME_DIGEST _XRAY_RUNTIME_GUARD_SCRIPT_DIGEST
}

# Keep the descriptor open for the complete operation, including restart and
# rollback. Do not remove the lock file: replacing its inode defeats flock.
function runtime_guard_acquire_lock() {
    [[ -z "${_XRAY_RUNTIME_GUARD_LOCK_FD:-}" ]] || return 0
    command -v flock >/dev/null 2>&1 || {
        runtime_guard_error 'flock is required to serialize configuration changes / 需要 flock 串行执行配置修改'
        return 1
    }
    local previous_umask
    previous_umask="$(umask)"
    umask 077
    exec {_XRAY_RUNTIME_GUARD_LOCK_FD}>"${SCRIPT_CONFIG_PATH}.operation.lock"
    local status=$?
    umask "${previous_umask}"
    [[ "${status}" -eq 0 ]] || return 1
    if ! flock -n "${_XRAY_RUNTIME_GUARD_LOCK_FD}"; then
        exec {_XRAY_RUNTIME_GUARD_LOCK_FD}>&-
        unset _XRAY_RUNTIME_GUARD_LOCK_FD
        runtime_guard_error 'another script operation is in progress / 另一个脚本操作正在进行'
        return 1
    fi
}

function runtime_guard_release_lock() {
    [[ -n "${_XRAY_RUNTIME_GUARD_LOCK_FD:-}" ]] || return 0
    flock -u "${_XRAY_RUNTIME_GUARD_LOCK_FD}"
    exec {_XRAY_RUNTIME_GUARD_LOCK_FD}>&-
    unset _XRAY_RUNTIME_GUARD_LOCK_FD
}
