#!/usr/bin/env bash
set -euo pipefail

readonly TEST_DIR="$(mktemp -d)"
readonly TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

mkdir -p "${TEST_DIR}/home/.xray-script" "${TEST_DIR}/home/.acme.sh"
cp config.json "${TEST_DIR}/script.json"
cp tests/fixtures/fake-acme.sh "${TEST_DIR}/home/.acme.sh/acme.sh"
chmod +x "${TEST_DIR}/home/.acme.sh/acme.sh"

export HOME="${TEST_DIR}/home"
export SCRIPT_CONFIG_PATH_OVERRIDE="${TEST_DIR}/script.json"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/xray.json"
export CDN_XRAY_CERT_DIR_OVERRIDE="${TEST_DIR}/xray-certs/cdn"
export XRAY_CERT_DIR_OVERRIDE="${TEST_DIR}/legacy-xray-certs"
export XRAY_CONFIG_VALIDATE=0
export FAKE_ACME_LOG="${TEST_DIR}/acme.log"
export FAKE_ACME_DOMAIN="hy2.example.com"
export FAKE_ACME_KEY_LENGTH="ec-256"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj '/CN=hy2.example.com' \
    -addext 'subjectAltName=DNS:hy2.example.com' \
    -keyout "${TEST_DIR}/hy2.key" \
    -out "${TEST_DIR}/hy2.crt" >/dev/null 2>&1
export FAKE_ACME_CERT="${TEST_DIR}/hy2.crt"
export FAKE_ACME_KEY="${TEST_DIR}/hy2.key"

source core/handler.sh
I18N_DATA="$(jq . i18n/en.json)"

SCRIPT_CONFIG="$(jq '
    .xray.tag = "hy2" |
    .xray.hy2CertSource = "1" |
    .xray.hy2CertDomain = "hy2.example.com" |
    .xray.hy2CertAcmeDomain = "hy2.example.com" |
    .nginx.ca = "certs@example.com"
' config.json)"
write_config "${SCRIPT_CONFIG}" "${SCRIPT_CONFIG_PATH}"

function prompt_cert_reuse() {
    printf '%s\n' 'xray-certs'
}

CRON_CALLS=0
function configure_hy2_ip_renewal_cron() {
    CRON_CALLS=$((CRON_CALLS + 1))
}

# A local pair without a live ECC ACME record is not an automatically
# renewable certificate and must not unlock HY2 config generation.
export FAKE_ACME_HAS_CERT=0
if handler_hy2_cert 2>"${TEST_DIR}/missing-acme.log"; then
    echo "HY2 reused an unmanaged local certificate" >&2
    exit 1
fi
[[ "${CRON_CALLS}" -eq 0 ]]
grep -Fq 'Certificate application failed' "${TEST_DIR}/missing-acme.log"

# With the ECC record present, reuse must reinstall into the isolated target,
# thereby rebinding acme.sh's renewal target and reload command.
export FAKE_ACME_HAS_CERT=1
: >"${FAKE_ACME_LOG}"
handler_hy2_cert
HY2_CERT_DIR="$(get_hy2_cert_dir 'hy2.example.com' '1')"
grep -Fq -- '--install-cert --ecc -d hy2.example.com' "${FAKE_ACME_LOG}"
grep -Fq -- "--key-file ${HY2_CERT_DIR}/privkey.pem" "${FAKE_ACME_LOG}"
grep -Fq -- "--fullchain-file ${HY2_CERT_DIR}/fullchain.pem" "${FAKE_ACME_LOG}"
[[ "${CRON_CALLS}" -eq 1 ]]
[[ "$(jq -r '.xray.hy2CertAcmeDomain' "${SCRIPT_CONFIG_PATH}")" == 'hy2.example.com' ]]
validate_cdn_direct_certificate \
    "${HY2_CERT_DIR}/fullchain.pem" \
    "${HY2_CERT_DIR}/privkey.pem" \
    'hy2.example.com'

echo "HY2 certificate reuse tests passed"
