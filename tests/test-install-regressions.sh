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
