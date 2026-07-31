#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

mkdir -p "${TEST_DIR}/home/.xray-script"
cp config.json "${TEST_DIR}/home/.xray-script/config.json"
cp config.json "${TEST_DIR}/script.json"
export HOME="${TEST_DIR}/home"
export SCRIPT_CONFIG_PATH_OVERRIDE="${TEST_DIR}/script.json"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/xray.json"

source core/handler.sh
I18N_DATA="$(jq . i18n/en.json)"
readonly ORIGINAL_FIREWALL_FUNCTION="$(declare -f open_xray_firewall_port)"

function fail_test() {
    echo "$1" >&2
    exit 1
}

# ACME rejects dot-edge/double-dot local parts and malformed domain labels.
for invalid_email in \
    'g.@p.com' \
    '.a@' \
    'a..b@' \
    'a@-example.com' \
    'a@example-.com' \
    'a@bad_label.com'; do
    if command bash core/check.sh --email "${invalid_email}" >/dev/null 2>&1; then
        fail_test "invalid email was accepted: ${invalid_email}"
    fi
done

if ! command bash core/check.sh --email 'user.name+tag@example.com' >/dev/null 2>&1; then
    fail_test 'valid email was rejected: user.name+tag@example.com'
fi

# generate_server_names must update through an atomic temporary file and
# preserve an invalid source file byte-for-byte when jq fails.
jq '.target = null' config.json >"${HOME}/.xray-script/config.json"
generated_names="$(command bash -c '
    set -euo pipefail
    source core/generate.sh
    generate_server_names "new-target.example.com"
')"
[[ "$(jq -c . <<<"${generated_names}")" == '["new-target.example.com"]' ]] ||
    fail_test "generate_server_names returned an unexpected value: ${generated_names}"
jq -e '
    .target["new-target.example.com"] == ["new-target.example.com"]
' "${HOME}/.xray-script/config.json" >/dev/null
printf '%s\n' '{"target":' >"${HOME}/.xray-script/config.json"
cp "${HOME}/.xray-script/config.json" "${TEST_DIR}/invalid-generator-config.before"
if command bash -c '
    set -euo pipefail
    source core/generate.sh
    generate_server_names "must-not-write.example.com"
' >/dev/null 2>&1; then
    fail_test 'generate_server_names accepted invalid JSON'
fi
cmp -s \
    "${TEST_DIR}/invalid-generator-config.before" \
    "${HOME}/.xray-script/config.json" ||
    fail_test 'generate_server_names truncated invalid JSON after jq failure'
cp config.json "${HOME}/.xray-script/config.json"

# Xray v26 labels the client value as "Password (PublicKey)" while older
# releases used "Public key". Both formats must remain parseable.
parsed_x25519="$(command bash -c '
    set -euo pipefail
    source core/generate.sh
    function xray() {
        printf "%s\n" \
            "PrivateKey: private-new" \
            "Password (PublicKey): public-new" \
            "Hash32: hash-new"
    }
    generate_x25519
')"
[[ "${parsed_x25519}" == 'private-new,public-new,hash-new' ]] ||
    fail_test "failed to parse current xray x25519 output: ${parsed_x25519}"

parsed_x25519="$(command bash -c '
    set -euo pipefail
    source core/generate.sh
    function xray() {
        printf "%s\n" "Private key: private-old" "Public key: public-old"
    }
    generate_x25519
')"
[[ "${parsed_x25519}" == 'private-old,public-old,' ]] ||
    fail_test "failed to parse legacy xray x25519 output: ${parsed_x25519}"

readonly X25519_ORIGINAL_PATH="${TEST_DIR}/x25519-original.json"
jq '
    .xray.privateKey = "original-private" |
    .xray.publicKey = "original-public" |
    .xray.hash32 = "original-hash"
' config.json >"${X25519_ORIGINAL_PATH}"

function restore_x25519_config() {
    SCRIPT_CONFIG="$(jq . "${X25519_ORIGINAL_PATH}")"
    cp "${X25519_ORIGINAL_PATH}" "${SCRIPT_CONFIG_PATH}"
}

function assert_x25519_config_unchanged() {
    if ! diff -u \
        <(jq -S . "${X25519_ORIGINAL_PATH}") \
        <(jq -S . "${SCRIPT_CONFIG_PATH}"); then
        fail_test 'handler_x25519_config overwrote the config file after a generation failure'
    fi
    if ! diff -u \
        <(jq -S . "${X25519_ORIGINAL_PATH}") \
        <(jq -S . <<<"${SCRIPT_CONFIG}"); then
        fail_test 'handler_x25519_config changed SCRIPT_CONFIG after a generation failure'
    fi
}

function exec_generate() {
    return 23
}

restore_x25519_config
if handler_x25519_config 2>"${TEST_DIR}/x25519-generator-failure.log"; then
    fail_test 'handler_x25519_config succeeded when the generator failed'
fi
assert_x25519_config_unchanged

function exec_generate() {
    printf '%s\n' 'new-private,,new-hash'
}

restore_x25519_config
if handler_x25519_config 2>"${TEST_DIR}/x25519-empty-public.log"; then
    fail_test 'handler_x25519_config accepted an empty public key'
fi
assert_x25519_config_unchanged

readonly SUCCESS_PRIVATE_KEY='success-private-key-must-stay-secret'
function exec_generate() {
    printf '%s\n' "${SUCCESS_PRIVATE_KEY},success-public,success-hash"
}

restore_x25519_config
handler_x25519_config 2>"${TEST_DIR}/x25519-success.log"
if grep -Fq "${SUCCESS_PRIVATE_KEY}" "${TEST_DIR}/x25519-success.log"; then
    fail_test 'handler_x25519_config printed the private key to stderr'
fi
jq -e '
    .xray.privateKey == "success-private-key-must-stay-secret" and
    .xray.publicKey == "success-public" and
    .xray.hash32 == "success-hash"
' "${SCRIPT_CONFIG_PATH}" >/dev/null

readonly SYSTEMCTL_LOG="${TEST_DIR}/systemctl.log"
: >"${SYSTEMCTL_LOG}"
function systemctl() {
    printf '%s\n' "$*" >>"${SYSTEMCTL_LOG}"
    case "$*" in
    'reset-failed xray') return 0 ;;
    '-q is-active xray') return 0 ;;
    '-q is-active nginx') return 1 ;;
    '-q is-enabled nginx') return 1 ;;
    '-q restart xray') return 1 ;;
    '-q start xray') return 0 ;;
    '-q is-enabled xray') return 1 ;;
    '-q enable xray') return 0 ;;
    '--no-pager --full status xray') return 0 ;;
    *) fail_test "unexpected systemctl call: $*" ;;
    esac
}

if handler_restart; then
    fail_test 'handler_restart hid a failed restart behind a successful enable'
fi
grep -Fxq -- '-q restart xray' "${SYSTEMCTL_LOG}"

RENEW_NGINX_RESTARTS=0
RENEW_XRAY_RESTARTS=0
function exec_ssl() { return 23; }
function handler_nginx_restart() {
    RENEW_NGINX_RESTARTS=$((RENEW_NGINX_RESTARTS + 1))
}
function handler_restart() {
    RENEW_XRAY_RESTARTS=$((RENEW_XRAY_RESTARTS + 1))
}
if handler_renew_ssl; then
    fail_test 'handler_renew_ssl hid a certificate renewal failure'
fi
[[ "${RENEW_NGINX_RESTARTS}" -eq 0 ]]
[[ "${RENEW_XRAY_RESTARTS}" -eq 0 ]]

FIREWALL_CALLS=0
function open_xray_firewall_port() {
    FIREWALL_CALLS=$((FIREWALL_CALLS + 1))
    return 0
}

function prompt_cert_reuse() {
    printf '%s\n' 'new'
}

SCRIPT_CONFIG="$(jq '
    .xray.tag = "hy2" |
    .xray.hy2CertSource = "2" |
    .xray.hy2CertDomain = "192.0.2.10" |
    .nginx.ca = "g.@p.com"
' config.json)"
if handler_hy2_cert 2>"${TEST_DIR}/hy2-invalid-email.log"; then
    fail_test 'handler_hy2_cert accepted the malformed ACME email from the reported installation failure'
fi
if [[ "${FIREWALL_CALLS}" -ne 0 ]]; then
    fail_test 'handler_hy2_cert opened the firewall after rejecting the ACME email'
fi

readonly TEST_CERT_DIR="${TEST_DIR}/xray-certs"
mkdir -p "${TEST_CERT_DIR}" "${HOME}/.acme.sh"
export XRAY_CERT_DIR_OVERRIDE="${TEST_CERT_DIR}"
HY2_IP_CERT_DIR="$(get_hy2_cert_dir '192.0.2.10' '2')"
mkdir -p "${HY2_IP_CERT_DIR}"
cat >"${HOME}/.acme.sh/acme.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'--issue'* ]]; then
    exit 23
fi
exit 0
EOF
chmod +x "${HOME}/.acme.sh/acme.sh"

SCRIPT_CONFIG="$(jq '
    .xray.tag = "hy2" |
    .xray.hy2CertSource = "2" |
    .xray.hy2CertDomain = "192.0.2.10" |
    .nginx.ca = "valid@example.com"
' config.json)"
if handler_hy2_cert 2>"${TEST_DIR}/hy2-ip-issue-failure.log"; then
    fail_test 'handler_hy2_cert succeeded after the IP certificate request failed'
fi
if [[ "${FIREWALL_CALLS}" -ne 0 ]]; then
    fail_test 'handler_hy2_cert opened the firewall after the IP certificate request failed'
fi

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${HY2_IP_CERT_DIR}/privkey.pem" \
    -out "${HY2_IP_CERT_DIR}/fullchain.pem" \
    -days 1 \
    -subj '/CN=192.0.2.10' \
    -addext 'subjectAltName=IP:192.0.2.10' >/dev/null 2>&1
rm -f "${HOME}/.acme.sh/acme.sh"
ln -s /bin/true "${HOME}/.acme.sh/acme.sh"
function crontab() { return 0; }
if handler_hy2_cert 2>"${TEST_DIR}/hy2-stale-cert.log"; then
    fail_test 'handler_hy2_cert let an unchanged old certificate hide a failed IP certificate request'
fi

mkdir -p "${TEST_DIR}/new-ip-cert"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${TEST_DIR}/new-ip-cert/privkey.pem" \
    -out "${TEST_DIR}/new-ip-cert/fullchain.pem" \
    -days 1 \
    -subj '/CN=192.0.2.10' \
    -addext 'subjectAltName=IP:192.0.2.10' >/dev/null 2>&1
export FAKE_ACME_PRIVKEY="${TEST_DIR}/new-ip-cert/privkey.pem"
export FAKE_ACME_FULLCHAIN="${TEST_DIR}/new-ip-cert/fullchain.pem"
rm -f "${HOME}/.acme.sh/acme.sh"
cat >"${HOME}/.acme.sh/acme.sh" <<'EOF'
#!/usr/bin/env bash
key_file=''
fullchain_file=''
while [[ "$#" -gt 0 ]]; do
    case "$1" in
    --key-file)
        shift
        key_file="$1"
        ;;
    --fullchain-file)
        shift
        fullchain_file="$1"
        ;;
    esac
    shift
done
if [[ -n "${key_file}" && -n "${fullchain_file}" ]]; then
    cp "${FAKE_ACME_PRIVKEY}" "${key_file}"
    cp "${FAKE_ACME_FULLCHAIN}" "${fullchain_file}"
fi
EOF
chmod +x "${HOME}/.acme.sh/acme.sh"
CRONTAB_LOG="${TEST_DIR}/crontab.log"
: >"${CRONTAB_LOG}"
function crontab() {
    printf '%s\n' "$*" >>"${CRONTAB_LOG}"
    if [[ "$*" == '-l' ]]; then
        echo 'no crontab for test-user' >&2
        return 1
    fi
    return 1
}

SCRIPT_CONFIG="$(jq '
    .xray.tag = "hy2" |
    .xray.hy2CertSource = "2" |
    .xray.hy2CertDomain = "192.0.2.10" |
    .nginx.ca = "valid@example.com"
' config.json)"
if handler_hy2_cert 2>"${TEST_DIR}/hy2-crontab-failure.log"; then
    fail_test 'handler_hy2_cert succeeded after the IP certificate renewal cron write failed'
fi
grep -Fxq -- '-' "${CRONTAB_LOG}"
if grep -Fq 'Certificate auto-renewal configured' "${TEST_DIR}/hy2-crontab-failure.log"; then
    fail_test 'handler_hy2_cert printed a false cron success message'
fi

SCRIPT_CONFIG="$(jq '
    .xray.tag = "hy2" |
    .xray.port = 24443 |
    .xray.hy2CertSource = "invalid-source"
' config.json)"
if handler_hy2_cert 2>"${TEST_DIR}/hy2-invalid-source.log"; then
    fail_test 'handler_hy2_cert accepted an invalid certificate source'
fi
if [[ "${FIREWALL_CALLS}" -ne 0 ]]; then
    fail_test 'handler_hy2_cert opened the firewall before rejecting the certificate source'
fi

eval "${ORIGINAL_FIREWALL_FUNCTION}"
function firewall-cmd() {
    if [[ "$*" == '--state' ]]; then
        printf '%s\n' 'not running'
        return 1
    fi
    fail_test 'open_xray_firewall_port changed an inactive firewalld configuration'
}
function ufw() {
    if [[ "$*" == 'status' ]]; then
        printf '%s\n' 'Status: active'
        return 0
    fi
    return 1
}
if open_xray_firewall_port 24443 udp 2>"${TEST_DIR}/firewall-failure.log"; then
    fail_test 'open_xray_firewall_port reported success after ufw failed'
fi
if grep -Fq 'Firewall port is open' "${TEST_DIR}/firewall-failure.log"; then
    fail_test 'open_xray_firewall_port printed a false success message'
fi

function ufw() {
    if [[ "$*" == 'status' ]]; then
        printf '%s\n' 'Status: inactive'
        return 0
    fi
    fail_test 'open_xray_firewall_port changed an inactive ufw configuration'
}
if ! open_xray_firewall_port 24443 udp 2>"${TEST_DIR}/firewall-inactive.log"; then
    fail_test 'open_xray_firewall_port failed merely because ufw was installed but inactive'
fi
grep -Fq 'The installed firewall manager is inactive' "${TEST_DIR}/firewall-inactive.log"

readonly FIREWALLD_TRANSACTION_LOG="${TEST_DIR}/firewalld-transaction.log"
readonly FIREWALLD_RELOAD_COUNT="${TEST_DIR}/firewalld-reload-count"
: >"${FIREWALLD_TRANSACTION_LOG}"
printf '%s\n' 0 >"${FIREWALLD_RELOAD_COUNT}"
function firewall-cmd() {
    printf '%s\n' "$*" >>"${FIREWALLD_TRANSACTION_LOG}"
    case "$*" in
    --state)
        printf '%s\n' running
        ;;
    '--permanent --query-port=24443/udp')
        return 1
        ;;
    '--permanent --add-port=24443/udp' | '--permanent --remove-port=24443/udp')
        ;;
    --reload)
        local reload_count
        reload_count="$(cat "${FIREWALLD_RELOAD_COUNT}")"
        reload_count=$((reload_count + 1))
        printf '%s\n' "${reload_count}" >"${FIREWALLD_RELOAD_COUNT}"
        [[ "${reload_count}" -gt 1 ]]
        ;;
    *)
        return 99
        ;;
    esac
}
if open_xray_firewall_port 24443 udp 2>"${TEST_DIR}/firewalld-transaction.log"; then
    fail_test 'open_xray_firewall_port hid a firewalld reload failure'
fi
grep -Fxq -- '--permanent --remove-port=24443/udp' "${FIREWALLD_TRANSACTION_LOG}" ||
    fail_test 'firewalld rule was not rolled back after reload failed'
[[ "$(cat "${FIREWALLD_RELOAD_COUNT}")" -eq 2 ]] ||
    fail_test 'firewalld was not reloaded after rolling back its new rule'

readonly INSTALL_CURL_LOG="${TEST_DIR}/install-curl.log"
readonly INSTALL_BASH_LOG="${TEST_DIR}/install-bash.log"
: >"${INSTALL_CURL_LOG}"
: >"${INSTALL_BASH_LOG}"
function ensure_service_users() { return 0; }
function handler_xray_version() {
    CONFIG_DATA['version']='v-test'
    return 0
}
function cmd_exists() { return 1; }
function curl() {
    printf '%s\n' "$*" >>"${INSTALL_CURL_LOG}"
    return 22
}
function bash() {
    printf '%s\n' "$*" >>"${INSTALL_BASH_LOG}"
    command bash "$@"
}

install_status=0
(
    handler_install 'release' <<'EOF'
n
EOF
) >"${TEST_DIR}/install-download-failure.stdout" \
    2>"${TEST_DIR}/install-download-failure.stderr" || install_status=$?

if [[ "${install_status}" -eq 0 ]]; then
    fail_test 'handler_install succeeded after the Xray install script download failed'
fi
if [[ -s "${INSTALL_BASH_LOG}" ]]; then
    fail_test 'handler_install executed bash after the Xray install script download failed'
fi
[[ -s "${INSTALL_CURL_LOG}" ]]

# A syntactically valid installer must receive "install" as its first
# argument. The old bash -c form needed an @ placeholder for $0; bash -s does
# not, and forwarding it would make Xray-install reject an unknown option.
: >"${INSTALL_CURL_LOG}"
: >"${INSTALL_BASH_LOG}"
CMD_EXISTS_CALLS=0
function cmd_exists() {
    CMD_EXISTS_CALLS=$((CMD_EXISTS_CALLS + 1))
    [[ "${CMD_EXISTS_CALLS}" -gt 1 ]]
}
function curl() {
    printf '%s\n' "$*" >>"${INSTALL_CURL_LOG}"
    cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "install" ]]
[[ "$2" == "-u" ]]
[[ "$3" == "xray" ]]
[[ "$4" == "--version" ]]
[[ "$5" == "v-test" ]]
EOF
}

if ! (
    handler_install 'release' <<'EOF'
n
EOF
) >"${TEST_DIR}/install-success.stdout" \
    2>"${TEST_DIR}/install-success.stderr"; then
    fail_test 'handler_install did not pass the expected arguments to the downloaded installer'
fi
grep -Fq -- '-s -- install -u xray --version v-test' "${INSTALL_BASH_LOG}"

# A pre-install questionnaire choice must be consumed without reading stdin
# again after package installation has started.
readonly INSTALL_READ_LOG="${TEST_DIR}/install-read.log"
: >"${INSTALL_CURL_LOG}"
: >"${INSTALL_BASH_LOG}"
: >"${INSTALL_READ_LOG}"
if ! (
    SCRIPT_CONFIG="$(jq '.xray.githubProxy = "y"' config.json)"
    CMD_EXISTS_CALLS=0
    function read() {
        printf '%s\n' 'unexpected read' >>"${INSTALL_READ_LOG}"
        return 1
    }
    handler_install 'release' </dev/null
) >"${TEST_DIR}/install-persisted-proxy.stdout" \
    2>"${TEST_DIR}/install-persisted-proxy.stderr"; then
    fail_test 'handler_install failed while consuming a persisted GitHub proxy choice'
fi
[[ ! -s "${INSTALL_READ_LOG}" ]] ||
    fail_test 'handler_install read stdin despite a persisted GitHub proxy choice'
grep -Fq -- 'https://gh-proxy.com/https://github.com/XTLS/Xray-install/raw/main/install-release.sh' "${INSTALL_CURL_LOG}" ||
    fail_test 'handler_install ignored the persisted GitHub proxy choice'

# Purge must preserve local state unless both the download and the upstream
# uninstall command complete successfully.
readonly PURGE_ORIGINAL="${TEST_DIR}/purge-original.json"
jq '.xray.version = "v-test" | .xray.tag = "Vision"' config.json >"${PURGE_ORIGINAL}"
function restore_purge_config() {
    cp "${PURGE_ORIGINAL}" "${SCRIPT_CONFIG_PATH}"
    SCRIPT_CONFIG="$(jq . "${PURGE_ORIGINAL}")"
}
function curl() { return 22; }
restore_purge_config
if handler_purge >"${TEST_DIR}/purge-download.stdout" 2>"${TEST_DIR}/purge-download.stderr"; then
    fail_test 'handler_purge succeeded after its installer download failed'
fi
cmp -s "${PURGE_ORIGINAL}" "${SCRIPT_CONFIG_PATH}" ||
    fail_test 'handler_purge cleared state after its installer download failed'
function curl() { printf '%s\n' '#!/usr/bin/env bash' 'exit 23'; }
restore_purge_config
if handler_purge >"${TEST_DIR}/purge-run.stdout" 2>"${TEST_DIR}/purge-run.stderr"; then
    fail_test 'handler_purge succeeded after the upstream uninstall failed'
fi
cmp -s "${PURGE_ORIGINAL}" "${SCRIPT_CONFIG_PATH}" ||
    fail_test 'handler_purge cleared state after the upstream uninstall failed'
function curl() { printf '%s\n' '#!/usr/bin/env bash' 'exit 0'; }
restore_purge_config
: >"${INSTALL_BASH_LOG}"
if (
    function write_config() { return 23; }
    handler_purge
) >"${TEST_DIR}/purge-stage.stdout" 2>"${TEST_DIR}/purge-stage.stderr"; then
    fail_test 'handler_purge succeeded when its local state could not be prepared'
fi
if grep -Fq -- '-s -- remove --purge' "${INSTALL_BASH_LOG}"; then
    fail_test 'handler_purge ran the upstream uninstall before preparing local state'
fi
cmp -s "${PURGE_ORIGINAL}" "${SCRIPT_CONFIG_PATH}" ||
    fail_test 'handler_purge changed state after local preparation failed'
function curl() { printf '%s\n' '#!/usr/bin/env bash' '[[ "$1" == remove && "$2" == --purge ]]'; }
restore_purge_config
handler_purge >"${TEST_DIR}/purge-success.stdout" 2>"${TEST_DIR}/purge-success.stderr"
[[ "$(jq -r '.xray.version // empty' "${SCRIPT_CONFIG_PATH}")" == '' ]] ||
    fail_test 'handler_purge did not clear state after a successful uninstall'

# Rejecting an enable request before Xray is installed must not leave sensitive
# backup copies alongside either configuration file.
jq '.xray.version = "" | .xray.reverse = 0' config.json >"${SCRIPT_CONFIG_PATH}"
jq . config/xray/Vision.json >"${XRAY_CONFIG_PATH}"
SCRIPT_CONFIG="$(jq . "${SCRIPT_CONFIG_PATH}")"
if handler_reverse_toggle >"${TEST_DIR}/reverse-not-installed.stdout" 2>"${TEST_DIR}/reverse-not-installed.stderr"; then
    fail_test 'handler_reverse_toggle enabled reverse proxy without Xray'
fi
if compgen -G "${SCRIPT_CONFIG_PATH}.reverse-backup.*" >/dev/null ||
    compgen -G "${XRAY_CONFIG_PATH}.reverse-backup.*" >/dev/null; then
    fail_test 'handler_reverse_toggle left a backup after rejecting an enable request'
fi

# Reverse toggles regenerate the runtime configuration themselves. A failed
# generation must restore both files instead of committing only the flag.
readonly REVERSE_RUNTIME_ORIGINAL="${TEST_DIR}/reverse-runtime-original.json"
jq '.xray.version = "v-test" | .xray.tag = "Vision" | .xray.reverse = 1' config.json >"${SCRIPT_CONFIG_PATH}"
jq . config/xray/Vision.json >"${XRAY_CONFIG_PATH}"
cp "${SCRIPT_CONFIG_PATH}" "${TEST_DIR}/reverse-script-original.json"
cp "${XRAY_CONFIG_PATH}" "${REVERSE_RUNTIME_ORIGINAL}"
SCRIPT_CONFIG="$(jq . "${SCRIPT_CONFIG_PATH}")"
XRAY_CONFIG="$(jq . "${XRAY_CONFIG_PATH}")"
REVERSE_CONFIG_CALLS=0
function handler_xray_config() {
    REVERSE_CONFIG_CALLS=$((REVERSE_CONFIG_CALLS + 1))
    XRAY_CONFIG='{"partial":true}'
    printf '%s\n' '{"partial":true}' >"${SCRIPT_CONFIG_PATH}"
    printf '%s\n' '{"partial":true}' >"${XRAY_CONFIG_PATH}"
    return 23
}
function cmd_exists() { return 0; }
if handler_reverse_toggle >"${TEST_DIR}/reverse-failure.stdout" 2>"${TEST_DIR}/reverse-failure.stderr"; then
    fail_test 'handler_reverse_toggle hid runtime regeneration failure'
fi
[[ "${REVERSE_CONFIG_CALLS}" -eq 1 ]] ||
    fail_test 'handler_reverse_toggle did not regenerate the runtime config'
cmp -s "${TEST_DIR}/reverse-script-original.json" "${SCRIPT_CONFIG_PATH}" ||
    fail_test 'handler_reverse_toggle did not restore script state'
cmp -s "${REVERSE_RUNTIME_ORIGINAL}" "${XRAY_CONFIG_PATH}" ||
    fail_test 'handler_reverse_toggle did not restore runtime state'
diff -u \
    <(jq -S . "${REVERSE_RUNTIME_ORIGINAL}") \
    <(jq -S . <<<"${XRAY_CONFIG}") ||
    fail_test 'handler_reverse_toggle did not restore in-memory runtime state'

# UUID readers must retry invalid input, and a failed reader subprocess must be
# returned to the caller instead of being accepted as an empty value.
(
    readonly READ_ATTEMPT_FILE="${TEST_DIR}/uuid-read-attempted"
    rm -f -- "${READ_ATTEMPT_FILE}"
    function bash() {
        if [[ "$1" == "${READ_PATH}" && "$2" == '--uuid' ]]; then
            if [[ -f "${READ_ATTEMPT_FILE}" ]]; then
                printf '%s\n' valid-uuid
            else
                : >"${READ_ATTEMPT_FILE}"
                printf '%s\n' invalid-uuid
            fi
            return 0
        fi
        command bash "$@"
    }
    function exec_check() { [[ "$2" == 'valid-uuid' ]]; }
    exec_read uuid
    [[ "${CONFIG_DATA['uuid']}" == 'valid-uuid' ]]
)
if (
    function bash() { return 23; }
    exec_read uuid
); then
    fail_test 'exec_read hid a reader subprocess failure'
fi

# Restore test doubles used by the remainder of this regression suite.
function handler_xray_config() {
    XRAY_CONFIG_CALLS=$((XRAY_CONFIG_CALLS + 1))
    return 0
}
function cmd_exists() { return 1; }

# Certificate acquisition is a hard gate for both single and multi HY2
# runtime config generation.
function load_i18n() { :; }
function handler_prepare_protocol_services() { :; }
HY2_CERT_CALLS=0
XRAY_CONFIG_CALLS=0
function handler_hy2_cert() {
    HY2_CERT_CALLS=$((HY2_CERT_CALLS + 1))
    return 23
}
function handler_xray_config() {
    XRAY_CONFIG_CALLS=$((XRAY_CONFIG_CALLS + 1))
    return 0
}

for hy2_mode in single multi; do
    HY2_CERT_CALLS=0
    XRAY_CONFIG_CALLS=0
    if [[ "${hy2_mode}" == 'single' ]]; then
        SCRIPT_CONFIG="$(jq '.xray.tag = "hy2"' config.json)"
    else
        SCRIPT_CONFIG="$(jq '
            .xray.tag = "multi" |
            .xray.nodes = [{"tag":"hy2","port":24443}]
        ' config.json)"
    fi
    if main '--xray-config' ''; then
        fail_test "${hy2_mode} HY2 flow ignored a certificate acquisition failure"
    fi
    [[ "${HY2_CERT_CALLS}" -eq 1 ]] ||
        fail_test "${hy2_mode} HY2 flow did not attempt certificate acquisition exactly once"
    [[ "${XRAY_CONFIG_CALLS}" -eq 0 ]] ||
        fail_test "${hy2_mode} HY2 flow generated Xray config after certificate failure"
done

# The legacy quick entry point must enforce the same gate.
function handler_script_config() { :; }
function handler_install() { :; }
HY2_CERT_CALLS=0
XRAY_CONFIG_CALLS=0
if handler_quick_install 'hy2'; then
    fail_test 'quick HY2 flow ignored a certificate acquisition failure'
fi
[[ "${HY2_CERT_CALLS}" -eq 1 ]]
[[ "${XRAY_CONFIG_CALLS}" -eq 0 ]]

command bash tests/test-cron-transaction.sh

echo "Install regression tests passed"
