#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(mktemp -d)"
readonly TEST_DIR
TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
readonly TEST_PROJECT_ROOT
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

mkdir -p "${TEST_DIR}/home/.xray-script"
cp config.json "${TEST_DIR}/home/.xray-script/config.json"
export HOME="${TEST_DIR}/home"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/runtime.json"
printf '{"marker":"old-runtime"}\n' >"${XRAY_CONFIG_PATH_OVERRIDE}"

# shellcheck disable=SC1091
source core/main.sh

SCRIPT_BASELINE="${TEST_DIR}/script.baseline.json"
RUNTIME_BASELINE="${TEST_DIR}/runtime.baseline.json"
CRONTAB_MODE_FILE="${TEST_DIR}/crontab.mode"
CRONTAB_STATE_FILE="${TEST_DIR}/crontab.txt"
CRONTAB_DURING_INSTALL="${TEST_DIR}/crontab-during-install.txt"
FLOW_LOG="${TEST_DIR}/flow.log"
cp "${SCRIPT_CONFIG_PATH}" "${SCRIPT_BASELINE}"
cp "${XRAY_RUNTIME_CONFIG_PATH}" "${RUNTIME_BASELINE}"

function crontab() {
    case "${1:-}" in
    -l)
        case "$(cat "${CRONTAB_MODE_FILE}")" in
        present)
            cat "${CRONTAB_STATE_FILE}"
            ;;
        absent)
            echo 'no crontab for test-user' >&2
            return 1
            ;;
        error)
            echo 'permission denied: no crontab data can be read' >&2
            return 1
            ;;
        *)
            return 2
            ;;
        esac
        ;;
    -r)
        rm -f -- "${CRONTAB_STATE_FILE}"
        printf 'absent\n' >"${CRONTAB_MODE_FILE}"
        ;;
    *)
        cp -f -- "$1" "${CRONTAB_STATE_FILE}"
        printf 'present\n' >"${CRONTAB_MODE_FILE}"
        ;;
    esac
}

FAILED_STAGE='--restart'
STOP_FAIL=0
function exec_handler() {
    printf '%s\n' "$*" >>"${FLOW_LOG}"
    if [[ "$1" == '--recover-runtime' ]]; then
        return 0
    fi
    if [[ "$1" == '--stop' && "${STOP_FAIL}" -eq 1 ]]; then
        return 1
    fi
    printf '{"mutatedBy":"%s"}\n' "$1" >"${SCRIPT_CONFIG_PATH}"
    printf '{"mutatedBy":"%s"}\n' "$1" >"${XRAY_RUNTIME_CONFIG_PATH}"
    if [[ "$1" == '--xray-config' ]]; then
        cp "${CRONTAB_DURING_INSTALL}" "${CRONTAB_STATE_FILE}"
        printf 'present\n' >"${CRONTAB_MODE_FILE}"
    fi
    [[ "$1" != "${FAILED_STAGE}" ]]
}

function restore_baseline() {
    cp "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}"
    cp "${RUNTIME_BASELINE}" "${XRAY_RUNTIME_CONFIG_PATH}"
    : >"${FLOW_LOG}"
}

function assert_no_transaction_files() {
    local leftovers=''

    leftovers="$(compgen -G "${SCRIPT_CONFIG_PATH}.install.*" || true)"
    leftovers+="${leftovers:+$'\n'}$(compgen -G "${XRAY_RUNTIME_CONFIG_PATH}.install.*" || true)"
    leftovers+="${leftovers:+$'\n'}$(compgen -G "${SCRIPT_CONFIG_PATH}.cron.*" || true)"
    [[ -z "${leftovers}" ]] || {
        printf 'Transaction files were not removed:\n%s\n' "${leftovers}" >&2
        return 1
    }
}

legacy_old="17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d 192.0.2.10 --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1"
marked_old="17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d 192.0.2.11 --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1 # xray-script-hy2-ip-renew"
domain_user="17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d cert.example.com --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1"
global_acme="23 0 * * * ${HOME}/.acme.sh/acme.sh --cron --home ${HOME}/.acme.sh >/dev/null 2>&1"
legacy_new="17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d 198.51.100.8 --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1"
marked_new="17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d 198.51.100.9 --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1 # xray-script-hy2-ip-renew"

cat >"${CRONTAB_STATE_FILE}" <<EOF
7 1 * * * echo user-before
${legacy_old}
${marked_old}
${domain_user}
EOF
printf 'present\n' >"${CRONTAB_MODE_FILE}"
cat >"${CRONTAB_DURING_INSTALL}" <<EOF
7 1 * * * echo user-before
${domain_user}
${global_acme}
9 2 * * * echo user-added-during-install
${legacy_new}
${marked_new}
EOF

# Rollback removes only the replacement HY2 line and restores the two old
# managed lines. New acme.sh global cron and all user entries survive.
restore_baseline
if install_protocol hy2; then
    echo 'HY2 install unexpectedly succeeded' >&2
    exit 1
fi
cat >"${TEST_DIR}/present.expected" <<EOF
7 1 * * * echo user-before
${domain_user}
${global_acme}
9 2 * * * echo user-added-during-install
${legacy_old}
${marked_old}
EOF
diff -u "${TEST_DIR}/present.expected" "${CRONTAB_STATE_FILE}"
cmp -s "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}"
cmp -s "${RUNTIME_BASELINE}" "${XRAY_RUNTIME_CONFIG_PATH}"
assert_no_transaction_files

# Starting without a user crontab is distinct from a read failure. A global
# acme.sh cron created during installation must still survive the rollback.
printf 'absent\n' >"${CRONTAB_MODE_FILE}"
rm -f -- "${CRONTAB_STATE_FILE}"
cat >"${CRONTAB_DURING_INSTALL}" <<EOF
${global_acme}
${marked_new}
EOF
restore_baseline
if install_protocol hy2; then
    echo 'HY2 install unexpectedly succeeded from an absent crontab' >&2
    exit 1
fi
printf '%s\n' "${global_acme}" >"${TEST_DIR}/absent.expected"
diff -u "${TEST_DIR}/absent.expected" "${CRONTAB_STATE_FILE}"
[[ "$(cat "${CRONTAB_MODE_FILE}")" == 'present' ]]
assert_no_transaction_files

# Switching away from an existing HY2/IP deployment also needs a cron
# snapshot. If the replacement runtime fails, the old renewal line must come
# back with the restored HY2 configuration.
jq '
    .xray.tag = "hy2" |
    .xray.hy2CertSource = "2" |
    .xray.hy2CertDomain = "192.0.2.11"
' config.json >"${SCRIPT_BASELINE}"
cp "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}"
cp "${RUNTIME_BASELINE}" "${XRAY_RUNTIME_CONFIG_PATH}"
cat >"${CRONTAB_STATE_FILE}" <<EOF
7 1 * * * echo user-before
${marked_old}
EOF
printf 'present\n' >"${CRONTAB_MODE_FILE}"
cat >"${CRONTAB_DURING_INSTALL}" <<EOF
7 1 * * * echo user-before
9 2 * * * echo user-added-during-install
EOF
: >"${FLOW_LOG}"
if install_protocol vision; then
    echo 'Vision replacement unexpectedly succeeded over HY2' >&2
    exit 1
fi
cat >"${TEST_DIR}/hy2-to-vision.expected" <<EOF
7 1 * * * echo user-before
9 2 * * * echo user-added-during-install
${marked_old}
EOF
diff -u "${TEST_DIR}/hy2-to-vision.expected" "${CRONTAB_STATE_FILE}"
cmp -s "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}"
cmp -s "${RUNTIME_BASELINE}" "${XRAY_RUNTIME_CONFIG_PATH}"
assert_no_transaction_files

# An unreadable crontab cannot safely be treated as empty. Abort before the
# first handler stage and leave script/runtime state untouched.
printf 'error\n' >"${CRONTAB_MODE_FILE}"
restore_baseline
if install_protocol hy2 2>"${TEST_DIR}/read-error.stderr"; then
    echo 'HY2 install ignored a crontab read error' >&2
    exit 1
fi
[[ ! -s "${FLOW_LOG}" ]]
grep -Fq 'permission denied: no crontab data can be read' "${TEST_DIR}/read-error.stderr"
cmp -s "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}"
cmp -s "${RUNTIME_BASELINE}" "${XRAY_RUNTIME_CONFIG_PATH}"
assert_no_transaction_files

# On a first-install rollback, never unlink the only runtime JSON while a
# failed stop may have left Xray running with that file loaded.
FIRST_INSTALL_SCRIPT_SNAPSHOT="$(mktemp "${SCRIPT_CONFIG_PATH}.install.XXXXXX")"
cp "${SCRIPT_BASELINE}" "${FIRST_INSTALL_SCRIPT_SNAPSHOT}"
printf '%s\n' '{"marker":"failed-first-runtime"}' >"${XRAY_RUNTIME_CONFIG_PATH}"
STOP_FAIL=1
if rollback_protocol_install \
    "${FIRST_INSTALL_SCRIPT_SNAPSHOT}" '' '' 'unavailable' '' \
    2>"${TEST_DIR}/first-runtime-retained.stderr"; then
    echo 'First-install rollback ignored a failed Xray stop' >&2
    exit 1
fi
STOP_FAIL=0
[[ -f "${XRAY_RUNTIME_CONFIG_PATH}" ]]
grep -Fq "${XRAY_RUNTIME_CONFIG_PATH}" \
    "${TEST_DIR}/first-runtime-retained.stderr"

# If restoration itself fails, keep the recovery copies for manual repair
# instead of deleting the only known-good data.
RETAINED_SCRIPT="$(mktemp "${SCRIPT_CONFIG_PATH}.install.XXXXXX")"
RETAINED_RUNTIME="$(mktemp "${XRAY_RUNTIME_CONFIG_PATH}.install.XXXXXX")"
cp "${SCRIPT_BASELINE}" "${RETAINED_SCRIPT}"
cp "${RUNTIME_BASELINE}" "${RETAINED_RUNTIME}"
function restore_protocol_snapshot() { return 1; }
if rollback_protocol_install \
    "${RETAINED_SCRIPT}" "${RETAINED_RUNTIME}" '' 'unavailable' '' \
    2>"${TEST_DIR}/retained-recovery.stderr"; then
    echo 'Rollback unexpectedly succeeded when snapshot restoration failed' >&2
    exit 1
fi
[[ -f "${RETAINED_SCRIPT}" ]]
[[ -f "${RETAINED_RUNTIME}" ]]
grep -Fq "${RETAINED_SCRIPT}" "${TEST_DIR}/retained-recovery.stderr"
grep -Fq "${RETAINED_RUNTIME}" "${TEST_DIR}/retained-recovery.stderr"
rm -f -- "${RETAINED_SCRIPT}" "${RETAINED_RUNTIME}"

echo "Cron transaction tests passed"
