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
cp config.json "${TEST_DIR}/script.json"
export HOME="${TEST_DIR}/home"
export SCRIPT_CONFIG_PATH_OVERRIDE="${TEST_DIR}/script.json"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/xray.json"

# shellcheck disable=SC1091
source core/handler.sh

CRONTAB_STATE="${TEST_DIR}/crontab.txt"
CRONTAB_WRITES="${TEST_DIR}/crontab-writes.log"
: >"${CRONTAB_WRITES}"

function crontab() {
    case "${1:-}" in
    -l)
        [[ -s "${CRONTAB_STATE}" ]] || return 1
        cat "${CRONTAB_STATE}"
        ;;
    -)
        cat >"${CRONTAB_STATE}"
        printf 'write\n' >>"${CRONTAB_WRITES}"
        ;;
    *)
        echo "Unexpected crontab call: $*" >&2
        return 1
        ;;
    esac
}

cat >"${CRONTAB_STATE}" <<EOF
5 4 * * * echo keep
17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d 192.0.2.40 --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1
17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d 192.0.2.41 --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1 # xray-script-hy2-ip-renew
EOF

# The current IP source replaces both the legacy unmarked job and any old
# managed job while preserving unrelated user entries.
configure_hy2_ip_renewal_cron '2' '198.51.100.9'
cat >"${TEST_DIR}/ip.expected" <<EOF
5 4 * * * echo keep
17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d 198.51.100.9 --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1 # xray-script-hy2-ip-renew
EOF
diff -u "${TEST_DIR}/ip.expected" "${CRONTAB_STATE}"
[[ "$(grep -Fc '# xray-script-hy2-ip-renew' "${CRONTAB_STATE}")" -eq 1 ]]

# Domain certificates rely on acme.sh's own renewal schedule, so switching
# from an IP certificate removes the script-owned short-lived renewal job.
configure_hy2_ip_renewal_cron '1' 'hy2.example.com'
printf '5 4 * * * echo keep\n' >"${TEST_DIR}/clean.expected"
diff -u "${TEST_DIR}/clean.expected" "${CRONTAB_STATE}"

# Custom certificates must also remove an old unmarked job left by releases
# that predate the managed marker.
cat >"${CRONTAB_STATE}" <<EOF
5 4 * * * echo keep
17 3 */3 * * ${HOME}/.acme.sh/acme.sh --renew -d 203.0.113.8 --ecc --force --home ${HOME}/.acme.sh >/dev/null 2>&1
EOF
configure_hy2_ip_renewal_cron '3' 'custom.example.com'
diff -u "${TEST_DIR}/clean.expected" "${CRONTAB_STATE}"
[[ "$(wc -l <"${CRONTAB_WRITES}")" -eq 3 ]]

echo "HY2 renewal cron tests passed"
