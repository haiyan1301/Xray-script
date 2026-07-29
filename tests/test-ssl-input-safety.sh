#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(mktemp -d)"
readonly TEST_DIR
TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
readonly TEST_PROJECT_ROOT
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

mkdir -p \
    "${TEST_DIR}/home/.xray-script" \
    "${TEST_DIR}/home/.acme.sh" \
    "${TEST_DIR}/nginx/certs/example.com" \
    "${TEST_DIR}/victim_ecc"
jq '.language = "en"' config.json >"${TEST_DIR}/home/.xray-script/config.json"
cp tests/fixtures/fake-acme.sh "${TEST_DIR}/home/.acme.sh/acme.sh"
chmod +x "${TEST_DIR}/home/.acme.sh/acme.sh"
printf 'must survive\n' >"${TEST_DIR}/victim_ecc/sentinel"
printf 'must survive too\n' >"${TEST_DIR}/home/.acme.sh/sentinel"

export HOME="${TEST_DIR}/home"
export FAKE_ACME_LOG="${TEST_DIR}/acme.log"
export FAKE_ACME_HAS_CERT=0
export FAKE_ACME_DOMAIN='example.com'
export NGINX_CONFIG_PATH_OVERRIDE="${TEST_DIR}/nginx"

function assert_no_side_effects() {
    [[ ! -s "${FAKE_ACME_LOG}" ]]
    [[ "$(cat "${TEST_DIR}/victim_ecc/sentinel")" == 'must survive' ]]
    [[ "$(cat "${TEST_DIR}/home/.acme.sh/sentinel")" == 'must survive too' ]]
    [[ -x "${HOME}/.acme.sh/acme.sh" ]]
}

case_number=0
for action in issue status stop-renew info; do
    for invalid_domain in '' '../../victim' 'example.com/../../../victim'; do
        case_number=$((case_number + 1))
        : >"${FAKE_ACME_LOG}"
        if bash service/ssl.sh \
            "--${action}" \
            "--domain=${invalid_domain}" \
            >"${TEST_DIR}/invalid-${case_number}.stdout" \
            2>"${TEST_DIR}/invalid-${case_number}.stderr"; then
            echo "${action} accepted an invalid domain: '${invalid_domain}'" >&2
            exit 1
        fi
        assert_no_side_effects
    done
done

# A valid lookup must compare the first acme.sh list field exactly. A
# superdomain containing the requested text is not a match.
export FAKE_ACME_HAS_CERT=1
export FAKE_ACME_DOMAIN='example.com.evil'
: >"${FAKE_ACME_LOG}"
if bash service/ssl.sh --status --domain=example.com \
    >"${TEST_DIR}/near-match.stdout" \
    2>"${TEST_DIR}/near-match.stderr"; then
    echo 'status matched a different ACME main domain by substring' >&2
    exit 1
fi
[[ "$(grep -Fxc -- "--list --home ${HOME}/.acme.sh" "${FAKE_ACME_LOG}")" -eq 1 ]]
[[ "$(wc -l <"${FAKE_ACME_LOG}")" -eq 1 ]]

export FAKE_ACME_DOMAIN='example.com'
: >"${FAKE_ACME_LOG}"
bash service/ssl.sh --status --domain=example.com \
    >"${TEST_DIR}/exact-match.stdout" \
    2>"${TEST_DIR}/exact-match.stderr"
[[ "$(grep -Fxc -- "--list --home ${HOME}/.acme.sh" "${FAKE_ACME_LOG}")" -eq 1 ]]
[[ "$(wc -l <"${FAKE_ACME_LOG}")" -eq 1 ]]
[[ "$(cat "${TEST_DIR}/victim_ecc/sentinel")" == 'must survive' ]]

# Stopping renewal during an ACME -> custom transition must not remove the
# newly deployed certificate pair for the same hostname.
printf 'new custom certificate\n' >"${TEST_DIR}/nginx/certs/example.com/fullchain.pem"
printf 'new custom key\n' >"${TEST_DIR}/nginx/certs/example.com/privkey.pem"
: >"${FAKE_ACME_LOG}"
bash service/ssl.sh --stop-renew --domain=example.com --keep-cert \
    >"${TEST_DIR}/keep-cert.stdout" \
    2>"${TEST_DIR}/keep-cert.stderr"
[[ "$(cat "${TEST_DIR}/nginx/certs/example.com/fullchain.pem")" == 'new custom certificate' ]]
[[ "$(cat "${TEST_DIR}/nginx/certs/example.com/privkey.pem")" == 'new custom key' ]]
grep -Fqx -- "--remove -d example.com --ecc" "${FAKE_ACME_LOG}"

# The public stop-renew operation keeps deployed certificates by default.
mkdir -p "${TEST_DIR}/nginx/certs/default.example.com"
printf 'still deployed\n' >"${TEST_DIR}/nginx/certs/default.example.com/fullchain.pem"
: >"${FAKE_ACME_LOG}"
bash service/ssl.sh --stop-renew --domain=default.example.com \
    >"${TEST_DIR}/default-keep.stdout" \
    2>"${TEST_DIR}/default-keep.stderr"
[[ "$(cat "${TEST_DIR}/nginx/certs/default.example.com/fullchain.pem")" == 'still deployed' ]]
grep -Fqx -- "--remove -d default.example.com --ecc" "${FAKE_ACME_LOG}"

# A failed acme.sh removal must retain both ACME state and deployed files.
mkdir -p \
    "${HOME}/.acme.sh/fail.example.com_ecc" \
    "${TEST_DIR}/nginx/certs/fail.example.com"
printf 'acme state\n' >"${HOME}/.acme.sh/fail.example.com_ecc/sentinel"
printf 'active cert\n' >"${TEST_DIR}/nginx/certs/fail.example.com/fullchain.pem"
export FAKE_ACME_FAIL_REMOVE=1
if bash service/ssl.sh --stop-renew --domain=fail.example.com \
    >"${TEST_DIR}/remove-fail.stdout" \
    2>"${TEST_DIR}/remove-fail.stderr"; then
    echo 'stop-renew succeeded after acme.sh removal failed' >&2
    exit 1
fi
unset FAKE_ACME_FAIL_REMOVE
[[ -f "${HOME}/.acme.sh/fail.example.com_ecc/sentinel" ]]
[[ "$(cat "${TEST_DIR}/nginx/certs/fail.example.com/fullchain.pem")" == 'active cert' ]]

# A committed domain migration may explicitly delete the obsolete deployment.
mkdir -p \
    "${HOME}/.acme.sh/old.example.com_ecc" \
    "${TEST_DIR}/nginx/certs/old.example.com"
printf 'old state\n' >"${HOME}/.acme.sh/old.example.com_ecc/sentinel"
printf 'old cert\n' >"${TEST_DIR}/nginx/certs/old.example.com/fullchain.pem"
bash service/ssl.sh --stop-renew --domain=old.example.com --delete-cert \
    >"${TEST_DIR}/delete-old.stdout" \
    2>"${TEST_DIR}/delete-old.stderr"
[[ ! -e "${HOME}/.acme.sh/old.example.com_ecc" ]]
[[ ! -e "${TEST_DIR}/nginx/certs/old.example.com" ]]

# Purging the ACME client must not delete deployed/custom site certificates.
bash service/ssl.sh --purge \
    >"${TEST_DIR}/purge.stdout" \
    2>"${TEST_DIR}/purge.stderr"
[[ ! -e "${HOME}/.acme.sh" ]]
[[ "$(cat "${TEST_DIR}/nginx/certs/example.com/fullchain.pem")" == 'new custom certificate' ]]
[[ "$(cat "${TEST_DIR}/nginx/certs/example.com/privkey.pem")" == 'new custom key' ]]

echo "SSL input safety tests passed"
