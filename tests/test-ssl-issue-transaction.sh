#!/usr/bin/env bash
set -euo pipefail

readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
readonly TEST_DIR="$(mktemp -d)"
readonly TEST_DOMAIN='cdn.example.com'
readonly OLD_KEY="${TEST_DIR}/old.key"
readonly OLD_CERT="${TEST_DIR}/old.crt"
readonly NEW_KEY="${TEST_DIR}/new.key"
readonly NEW_CERT="${TEST_DIR}/new.crt"
trap 'rm -rf -- "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
for dependency in bash jq openssl; do
    command -v "${dependency}" >/dev/null 2>&1 || {
        echo "${dependency} is required" >&2
        exit 1
    }
done

openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
    -subj "/CN=${TEST_DOMAIN}" \
    -keyout "${OLD_KEY}" -out "${OLD_CERT}" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 2 \
    -subj "/CN=${TEST_DOMAIN}" \
    -keyout "${NEW_KEY}" -out "${NEW_CERT}" >/dev/null 2>&1

CASE_ROOT=''
CERT_DIR=''
NGINX_CONF=''
SYSTEMCTL_STATE=''
SYSTEMCTL_LOG=''
NGINX_LOG=''
ACME_LOG=''
RELOAD_HOOK=''
ORIGINAL_CONFIG=''
LAST_ISSUE_STATUS=0

function fail() {
    echo "FAIL: $*" >&2
    exit 1
}

function setup_case() {
    local name="$1"
    local initial_state="$2"
    local has_existing_pair="$3"
    local has_original_config="$4"

    CASE_ROOT="${TEST_DIR}/${name}"
    CERT_DIR="${CASE_ROOT}/nginx/certs/${TEST_DOMAIN}"
    NGINX_CONF="${CASE_ROOT}/nginx/nginx.conf"
    SYSTEMCTL_STATE="${CASE_ROOT}/systemctl.state"
    SYSTEMCTL_LOG="${CASE_ROOT}/systemctl.log"
    NGINX_LOG="${CASE_ROOT}/nginx.log"
    ACME_LOG="${CASE_ROOT}/acme.log"
    RELOAD_HOOK="${CASE_ROOT}/reload-hook"
    ORIGINAL_CONFIG="${CASE_ROOT}/nginx.conf.expected"

    mkdir -p \
        "${CASE_ROOT}/bin" \
        "${CASE_ROOT}/home/.xray-script" \
        "${CASE_ROOT}/home/.acme.sh" \
        "${CERT_DIR}"
    jq '.language = "en"' config.json \
        >"${CASE_ROOT}/home/.xray-script/config.json"
    cp tests/fixtures/fake-ssl-systemctl.sh "${CASE_ROOT}/bin/systemctl"
    cp tests/fixtures/fake-ssl-nginx.sh "${CASE_ROOT}/bin/nginx"
    cp tests/fixtures/fake-ssl-acme.sh "${CASE_ROOT}/home/.acme.sh/acme.sh"
    chmod +x \
        "${CASE_ROOT}/bin/systemctl" \
        "${CASE_ROOT}/bin/nginx" \
        "${CASE_ROOT}/home/.acme.sh/acme.sh"

    printf '%s\n' "${initial_state}" >"${SYSTEMCTL_STATE}"
    : >"${SYSTEMCTL_LOG}"
    : >"${NGINX_LOG}"
    : >"${ACME_LOG}"

    if [[ "${has_original_config}" == "yes" ]]; then
        {
            printf '# original config for %s\n' "${name}"
            printf '# requires-certificate\n'
        } >"${NGINX_CONF}"
        cp -- "${NGINX_CONF}" "${ORIGINAL_CONFIG}"
    fi
    if [[ "${has_existing_pair}" == "yes" ]]; then
        cp -- "${OLD_CERT}" "${CERT_DIR}/fullchain.pem"
        cp -- "${OLD_KEY}" "${CERT_DIR}/privkey.pem"
    fi

    export HOME="${CASE_ROOT}/home"
    export NGINX_CONFIG_PATH_OVERRIDE="${CASE_ROOT}/nginx"
    export ACME_WEBROOT_PATH_OVERRIDE="${CASE_ROOT}/webroot"
    export SSL_CERT_PATH_OVERRIDE="${CASE_ROOT}/nginx/certs"
    export SSL_NGINX_COMMAND_OVERRIDE="${CASE_ROOT}/bin/nginx"
    export SSL_SYSTEMCTL_COMMAND_OVERRIDE="${CASE_ROOT}/bin/systemctl"
    export FAKE_SYSTEMCTL_STATE="${SYSTEMCTL_STATE}"
    export FAKE_SYSTEMCTL_LOG="${SYSTEMCTL_LOG}"
    export FAKE_NGINX_CONFIG="${NGINX_CONF}"
    export FAKE_NGINX_FULLCHAIN="${CERT_DIR}/fullchain.pem"
    export FAKE_NGINX_PRIVKEY="${CERT_DIR}/privkey.pem"
    export FAKE_NGINX_LOG="${NGINX_LOG}"
    export FAKE_ACME_LOG="${ACME_LOG}"
    export FAKE_ACME_NEW_KEY="${NEW_KEY}"
    export FAKE_ACME_NEW_FULLCHAIN="${NEW_CERT}"
    export FAKE_ACME_RELOAD_HOOK_FILE="${RELOAD_HOOK}"

    unset \
        FAKE_SYSTEMCTL_FAIL_START_CALLS \
        FAKE_SYSTEMCTL_FAIL_RELOAD_CALLS \
        FAKE_SYSTEMCTL_FAIL_STOP_CALLS \
        FAKE_NGINX_FAIL_TEST_CALLS \
        FAKE_ACME_FAIL_ALL_ISSUES \
        FAKE_ACME_FAIL_FIRST_ISSUE \
        FAKE_ACME_PARTIAL_INSTALL_FAIL \
        FAKE_ACME_RUN_RELOAD_BEFORE_COPY \
        FAKE_ACME_SIGNAL_PARENT \
        BASH_ENV
}

function run_issue_successfully() {
    if ! bash service/ssl.sh --issue --domain="${TEST_DOMAIN}" \
        >"${CASE_ROOT}/stdout" 2>"${CASE_ROOT}/stderr"; then
        sed -n '1,160p' "${CASE_ROOT}/stderr" >&2
        fail "certificate issue unexpectedly failed for $(basename "${CASE_ROOT}")"
    fi
}

function run_issue_with_failure() {
    if bash service/ssl.sh --issue --domain="${TEST_DOMAIN}" \
        >"${CASE_ROOT}/stdout" 2>"${CASE_ROOT}/stderr"; then
        fail "certificate issue unexpectedly succeeded for $(basename "${CASE_ROOT}")"
    else
        LAST_ISSUE_STATUS=$?
    fi
}

function assert_original_config_restored() {
    cmp -s -- "${ORIGINAL_CONFIG}" "${NGINX_CONF}" ||
        fail "original nginx.conf was not restored for $(basename "${CASE_ROOT}")"
}

function assert_pair_is() {
    local expected_cert="$1"
    local expected_key="$2"

    cmp -s -- "${expected_cert}" "${CERT_DIR}/fullchain.pem" ||
        fail "unexpected fullchain for $(basename "${CASE_ROOT}")"
    cmp -s -- "${expected_key}" "${CERT_DIR}/privkey.pem" ||
        fail "unexpected private key for $(basename "${CASE_ROOT}")"
}

function assert_no_transaction_backups() {
    if find "${CASE_ROOT}/nginx" \
        \( -name '*.ssl_script.*' -o -name '*.ssl-backup.*' \) \
        -print -quit | grep -q .; then
        fail "transaction backup remained for $(basename "${CASE_ROOT}")"
    fi
}

# A successful debug retry is a successful issuance and must proceed through
# installation, config restoration, and service restoration.
setup_case debug-retry active yes yes
export FAKE_ACME_FAIL_FIRST_ISSUE=1
run_issue_successfully
[[ "$(grep -Fc -- '--issue' "${ACME_LOG}")" -eq 2 ]] ||
    fail 'debug retry did not perform two issue attempts'
grep -Fq -- '--debug' "${ACME_LOG}" ||
    fail 'second issue attempt did not enable debug mode'
grep -Fq -- '--install-cert' "${ACME_LOG}" ||
    fail 'successful debug retry did not install the certificate'
assert_original_config_restored
assert_pair_is "${NEW_CERT}" "${NEW_KEY}"
[[ "$(cat "${SYSTEMCTL_STATE}")" == "active" ]] ||
    fail 'initially active nginx was not left active'
[[ -s "${RELOAD_HOOK}" ]] || fail 'renewal reload hook was not stored'
assert_no_transaction_backups

# On first installation the original config may reference certificate files
# that do not exist yet. Even a reload callback invoked before acme.sh copies
# them must see the challenge config. Nginx must return to its inactive state.
setup_case first-install inactive no yes
export FAKE_ACME_RUN_RELOAD_BEFORE_COPY=1
run_issue_successfully
assert_original_config_restored
assert_pair_is "${NEW_CERT}" "${NEW_KEY}"
[[ "$(cat "${SYSTEMCTL_STATE}")" == "inactive" ]] ||
    fail 'initially inactive nginx was not stopped after issuance'
[[ -s "${RELOAD_HOOK}" ]] || fail 'first install did not store a reload hook'
assert_no_transaction_backups

# The persisted renewal hook must be harmless while nginx is inactive, and
# must validate/reload nginx after it is started later.
: >"${SYSTEMCTL_LOG}"
bash -c "$(cat "${RELOAD_HOOK}")"
grep -Fq -- 'is-active --quiet nginx' "${SYSTEMCTL_LOG}" ||
    fail 'renewal hook did not check nginx state'
if grep -Fq -- 'reload nginx' "${SYSTEMCTL_LOG}"; then
    fail 'renewal hook tried to reload inactive nginx'
fi
printf 'active\n' >"${SYSTEMCTL_STATE}"
: >"${SYSTEMCTL_LOG}"
bash -c "$(cat "${RELOAD_HOOK}")"
grep -Fq -- 'reload nginx' "${SYSTEMCTL_LOG}" ||
    fail 'renewal hook did not reload active nginx'

# Both issue attempts failing must skip installation and restore nginx plus
# the existing certificate pair.
setup_case issue-failure active yes yes
export FAKE_ACME_FAIL_ALL_ISSUES=1
run_issue_with_failure
assert_original_config_restored
assert_pair_is "${OLD_CERT}" "${OLD_KEY}"
[[ "$(cat "${SYSTEMCTL_STATE}")" == "active" ]] ||
    fail 'nginx state changed after issue failure'
[[ "$(grep -Fc -- '--issue' "${ACME_LOG}")" -eq 2 ]] ||
    fail 'issue failure did not perform its debug retry'
if grep -Fq -- '--install-cert' "${ACME_LOG}"; then
    fail 'install-cert ran after both issue attempts failed'
fi

# A partial install may overwrite only one member of an existing pair. The
# transaction must restore both members before restoring the site config.
setup_case partial-install active yes yes
export FAKE_ACME_PARTIAL_INSTALL_FAIL=1
run_issue_with_failure
assert_original_config_restored
assert_pair_is "${OLD_CERT}" "${OLD_KEY}"
[[ "$(cat "${SYSTEMCTL_STATE}")" == "active" ]] ||
    fail 'nginx state changed after partial install failure'
assert_no_transaction_backups

# Failure while activating the challenge config must still restore the exact
# old config. The cleanup reload is allowed to recover on its next call.
setup_case challenge-reload-failure active yes yes
export FAKE_SYSTEMCTL_FAIL_RELOAD_CALLS=1
run_issue_with_failure
assert_original_config_restored
assert_pair_is "${OLD_CERT}" "${OLD_KEY}"
[[ "$(cat "${SYSTEMCTL_STATE}")" == "active" ]] ||
    fail 'nginx was not restored after challenge reload failure'
[[ ! -s "${ACME_LOG}" ]] ||
    fail 'acme.sh ran after challenge activation failed'
assert_no_transaction_backups

# If no nginx.conf existed, a failed issuance must remove the challenge file
# and stop the nginx instance that it started.
setup_case no-original-config inactive no no
export FAKE_ACME_FAIL_ALL_ISSUES=1
run_issue_with_failure
[[ ! -e "${NGINX_CONF}" ]] ||
    fail 'temporary nginx.conf remained after a failed issuance'
[[ "$(cat "${SYSTEMCTL_STATE}")" == "inactive" ]] ||
    fail 'temporary nginx instance remained active after failed issuance'
assert_no_transaction_backups

# Each handled signal must cause the subshell EXIT trap to restore the old
# pair, config, and initial service state after install-cert has overwritten
# one certificate file.
for signal_case in HUP INT TERM; do
    initial_signal_state='active'
    [[ "${signal_case}" != 'INT' ]] || initial_signal_state='inactive'
    setup_case \
        "signal-${signal_case,,}" \
        "${initial_signal_state}" \
        yes \
        yes
    export FAKE_ACME_SIGNAL_PARENT="${signal_case}"
    run_issue_with_failure
    case "${signal_case}" in
    HUP) expected_status=129 ;;
    INT) expected_status=130 ;;
    TERM) expected_status=143 ;;
    esac
    [[ "${LAST_ISSUE_STATUS}" -eq "${expected_status}" ]] ||
        fail "${signal_case} returned ${LAST_ISSUE_STATUS}, expected ${expected_status}"
    assert_original_config_restored
    assert_pair_is "${OLD_CERT}" "${OLD_KEY}"
    [[ "$(cat "${SYSTEMCTL_STATE}")" == "${initial_signal_state}" ]] ||
        fail "nginx state changed after ${signal_case}"
    assert_no_transaction_backups
done

# Exercise an unexpected shell exit after a successful install but before the
# normal cleanup path. The caller's own EXIT trap must still run because the
# transaction trap is scoped to the issue_certificate subshell.
setup_case unexpected-exit active yes yes
export CALLER_TRAP_LOG="${CASE_ROOT}/caller-exit.log"
export SSL_TRAP_OWNER_PID=''
cat >"${CASE_ROOT}/bash-env" <<'EOF'
if [[ -z "${SSL_TRAP_OWNER_PID:-}" ]]; then
    SSL_TRAP_OWNER_PID="${BASHPID}"
    export SSL_TRAP_OWNER_PID
    trap 'printf "caller-exit\n" >>"${CALLER_TRAP_LOG}"' EXIT
fi
function getent() {
    exit 77
}
EOF
export BASH_ENV="${CASE_ROOT}/bash-env"
run_issue_with_failure
[[ "${LAST_ISSUE_STATUS}" -eq 77 ]] ||
    fail "unexpected EXIT returned ${LAST_ISSUE_STATUS}, expected 77"
assert_original_config_restored
assert_pair_is "${OLD_CERT}" "${OLD_KEY}"
[[ "$(cat "${SYSTEMCTL_STATE}")" == "active" ]] ||
    fail 'nginx state changed after unexpected EXIT'
[[ "$(grep -Fxc -- 'caller-exit' "${CALLER_TRAP_LOG}")" -eq 1 ]] ||
    fail "issue transaction overwrote the caller's EXIT trap"
assert_no_transaction_backups

echo 'SSL issue transaction tests passed'
