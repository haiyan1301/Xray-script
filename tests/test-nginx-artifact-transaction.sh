#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(mktemp -d)"
readonly TEST_DIR
TEST_PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
readonly TEST_PROJECT_ROOT
trap 'rm -rf "${TEST_DIR}"' EXIT

cd "${TEST_PROJECT_ROOT}"
command -v jq >/dev/null 2>&1 || {
    echo 'jq is required' >&2
    exit 1
}

export HOME="${TEST_DIR}/home"
export XRAY_CONFIG_PATH_OVERRIDE="${TEST_DIR}/runtime.json"
export NGINX_CONFIG_DIR_OVERRIDE="${TEST_DIR}/nginx"
mkdir -p \
    "${HOME}/.xray-script" \
    "${NGINX_CONFIG_DIR_OVERRIDE}/sites-available" \
    "${NGINX_CONFIG_DIR_OVERRIDE}/sites-enabled" \
    "${NGINX_CONFIG_DIR_OVERRIDE}/modules-enabled" \
    "${TEST_DIR}/baseline"

jq '
    .xray.tag = "SNI" |
    .xray.cdnBackend = "nginx" |
    .nginx.domain = "old-origin.example.test" |
    .nginx.cdn = "old-cdn.example.test"
' config.json >"${HOME}/.xray-script/config.json"
printf '%s\n' '{"marker":"old-runtime"}' >"${XRAY_CONFIG_PATH_OVERRIDE}"

# shellcheck disable=SC1091
source core/main.sh
I18N_DATA="$(jq . i18n/en.json)"

readonly OLD_ORIGIN='old-origin.example.test'
readonly OLD_CDN='old-cdn.example.test'
readonly NEW_CDN='new-cdn.example.test'
readonly UNRELATED='unrelated.example.test'

readonly OLD_ORIGIN_AVAILABLE="${NGINX_CONFIG_DIR}/sites-available/${OLD_ORIGIN}.conf"
readonly OLD_ORIGIN_ENABLED="${NGINX_CONFIG_DIR}/sites-enabled/${OLD_ORIGIN}.conf"
readonly OLD_CDN_AVAILABLE="${NGINX_CONFIG_DIR}/sites-available/${OLD_CDN}.conf"
readonly OLD_CDN_ENABLED="${NGINX_CONFIG_DIR}/sites-enabled/${OLD_CDN}.conf"
readonly NEW_CDN_AVAILABLE="${NGINX_CONFIG_DIR}/sites-available/${NEW_CDN}.conf"
readonly NEW_CDN_ENABLED="${NGINX_CONFIG_DIR}/sites-enabled/${NEW_CDN}.conf"
readonly STREAM_CONFIG="${NGINX_CONFIG_DIR}/modules-enabled/stream.conf"
readonly UNRELATED_AVAILABLE="${NGINX_CONFIG_DIR}/sites-available/${UNRELATED}.conf"
readonly UNRELATED_ENABLED="${NGINX_CONFIG_DIR}/sites-enabled/${UNRELATED}.conf"
readonly UNRELATED_MODULE="${NGINX_CONFIG_DIR}/modules-enabled/unrelated.conf"

printf '%s\n' 'old origin contents' >"${OLD_ORIGIN_AVAILABLE}"
printf '%s\n' 'old cdn contents' >"${OLD_CDN_AVAILABLE}"
printf '%s\n' 'old stream contents' >"${STREAM_CONFIG}"
printf '%s\n' 'unrelated site contents' >"${UNRELATED_AVAILABLE}"
printf '%s\n' 'unrelated module contents' >"${UNRELATED_MODULE}"
ln -s "../sites-available/${OLD_ORIGIN}.conf" "${OLD_ORIGIN_ENABLED}"
ln -s "${OLD_CDN_AVAILABLE}" "${OLD_CDN_ENABLED}"
ln -s "../sites-available/${UNRELATED}.conf" "${UNRELATED_ENABLED}"

chmod 640 "${OLD_ORIGIN_AVAILABLE}"
chmod 604 "${OLD_CDN_AVAILABLE}"
chmod 600 "${STREAM_CONFIG}"
chmod 644 "${UNRELATED_AVAILABLE}"
chmod 444 "${UNRELATED_MODULE}"
touch -t 202001020304.05 "${OLD_ORIGIN_AVAILABLE}"
touch -t 202102030405.06 "${OLD_CDN_AVAILABLE}"
touch -t 202203040506.07 "${STREAM_CONFIG}"
touch -t 202304050607.08 "${UNRELATED_AVAILABLE}"
touch -t 202405060708.09 "${UNRELATED_MODULE}"
touch -h -t 202506070809.10 \
    "${OLD_ORIGIN_ENABLED}" "${OLD_CDN_ENABLED}" "${UNRELATED_ENABLED}"

readonly SCRIPT_BASELINE="${TEST_DIR}/baseline/script.json"
readonly RUNTIME_BASELINE="${TEST_DIR}/baseline/runtime.json"
readonly OLD_ORIGIN_BASELINE="${TEST_DIR}/baseline/old-origin.conf"
readonly OLD_CDN_BASELINE="${TEST_DIR}/baseline/old-cdn.conf"
readonly STREAM_BASELINE="${TEST_DIR}/baseline/stream.conf"
readonly UNRELATED_AVAILABLE_BASELINE="${TEST_DIR}/baseline/unrelated.conf"
readonly UNRELATED_MODULE_BASELINE="${TEST_DIR}/baseline/unrelated-module.conf"
cp -p -- "${SCRIPT_CONFIG_PATH}" "${SCRIPT_BASELINE}"
cp -p -- "${XRAY_RUNTIME_CONFIG_PATH}" "${RUNTIME_BASELINE}"
cp -p -- "${OLD_ORIGIN_AVAILABLE}" "${OLD_ORIGIN_BASELINE}"
cp -p -- "${OLD_CDN_AVAILABLE}" "${OLD_CDN_BASELINE}"
cp -p -- "${STREAM_CONFIG}" "${STREAM_BASELINE}"
cp -p -- "${UNRELATED_AVAILABLE}" "${UNRELATED_AVAILABLE_BASELINE}"
cp -p -- "${UNRELATED_MODULE}" "${UNRELATED_MODULE_BASELINE}"

readonly OLD_ORIGIN_METADATA="$(stat -c '%a:%Y' "${OLD_ORIGIN_AVAILABLE}")"
readonly OLD_CDN_METADATA="$(stat -c '%a:%Y' "${OLD_CDN_AVAILABLE}")"
readonly STREAM_METADATA="$(stat -c '%a:%Y' "${STREAM_CONFIG}")"
readonly OLD_ORIGIN_LINK_METADATA="$(stat -c '%F:%Y' "${OLD_ORIGIN_ENABLED}")"
readonly OLD_CDN_LINK_METADATA="$(stat -c '%F:%Y' "${OLD_CDN_ENABLED}")"
readonly OLD_ORIGIN_LINK_TARGET="$(readlink "${OLD_ORIGIN_ENABLED}")"
readonly OLD_CDN_LINK_TARGET="$(readlink "${OLD_CDN_ENABLED}")"
readonly UNRELATED_AVAILABLE_METADATA="$(stat -c '%a:%Y' "${UNRELATED_AVAILABLE}")"
readonly UNRELATED_MODULE_METADATA="$(stat -c '%a:%Y' "${UNRELATED_MODULE}")"
readonly UNRELATED_LINK_METADATA="$(stat -c '%F:%Y' "${UNRELATED_ENABLED}")"
readonly UNRELATED_LINK_TARGET="$(readlink "${UNRELATED_ENABLED}")"

function artifacts_match_baseline() {
    cmp -s "${OLD_ORIGIN_BASELINE}" "${OLD_ORIGIN_AVAILABLE}" &&
        cmp -s "${OLD_CDN_BASELINE}" "${OLD_CDN_AVAILABLE}" &&
        cmp -s "${STREAM_BASELINE}" "${STREAM_CONFIG}" &&
        [[ "$(stat -c '%a:%Y' "${OLD_ORIGIN_AVAILABLE}")" == \
            "${OLD_ORIGIN_METADATA}" ]] &&
        [[ "$(stat -c '%a:%Y' "${OLD_CDN_AVAILABLE}")" == \
            "${OLD_CDN_METADATA}" ]] &&
        [[ "$(stat -c '%a:%Y' "${STREAM_CONFIG}")" == \
            "${STREAM_METADATA}" ]] &&
        [[ -L "${OLD_ORIGIN_ENABLED}" ]] &&
        [[ "$(readlink "${OLD_ORIGIN_ENABLED}")" == \
            "${OLD_ORIGIN_LINK_TARGET}" ]] &&
        [[ "$(stat -c '%F:%Y' "${OLD_ORIGIN_ENABLED}")" == \
            "${OLD_ORIGIN_LINK_METADATA}" ]] &&
        [[ -L "${OLD_CDN_ENABLED}" ]] &&
        [[ "$(readlink "${OLD_CDN_ENABLED}")" == \
            "${OLD_CDN_LINK_TARGET}" ]] &&
        [[ "$(stat -c '%F:%Y' "${OLD_CDN_ENABLED}")" == \
            "${OLD_CDN_LINK_METADATA}" ]] &&
        [[ ! -e "${NEW_CDN_AVAILABLE}" && ! -L "${NEW_CDN_AVAILABLE}" ]] &&
        [[ ! -e "${NEW_CDN_ENABLED}" && ! -L "${NEW_CDN_ENABLED}" ]]
}

function unrelated_artifacts_match_baseline() {
    cmp -s "${UNRELATED_AVAILABLE_BASELINE}" "${UNRELATED_AVAILABLE}" &&
        cmp -s "${UNRELATED_MODULE_BASELINE}" "${UNRELATED_MODULE}" &&
        [[ "$(stat -c '%a:%Y' "${UNRELATED_AVAILABLE}")" == \
            "${UNRELATED_AVAILABLE_METADATA}" ]] &&
        [[ "$(stat -c '%a:%Y' "${UNRELATED_MODULE}")" == \
            "${UNRELATED_MODULE_METADATA}" ]] &&
        [[ -L "${UNRELATED_ENABLED}" ]] &&
        [[ "$(readlink "${UNRELATED_ENABLED}")" == \
            "${UNRELATED_LINK_TARGET}" ]] &&
        [[ "$(stat -c '%F:%Y' "${UNRELATED_ENABLED}")" == \
            "${UNRELATED_LINK_METADATA}" ]]
}

RECOVERY_LOG="${TEST_DIR}/recovery.log"
RECOVERY_BAD_STATE="${TEST_DIR}/recovery-bad-state"
SHARE_LOG="${TEST_DIR}/share.log"
SIGNAL_DURING_XRAY="${TEST_DIR}/signal-during-xray"
FAIL_SHARE="${TEST_DIR}/fail-share"
: >"${RECOVERY_LOG}"
: >"${SHARE_LOG}"
FAIL_RESTART=1

function choose_cdn_backend() {
    printf '%s\n' nginx
}

function choose_web_backend() {
    printf '%s\n' normal
}

function replace_script_config() {
    local filter="$1"
    local temporary="${SCRIPT_CONFIG_PATH}.handler"

    jq "${filter}" "${SCRIPT_CONFIG_PATH}" >"${temporary}" &&
        mv -f -- "${temporary}" "${SCRIPT_CONFIG_PATH}"
}

function exec_handler() {
    case "$1" in
    --script-config)
        replace_script_config "
            .xray.tag = \"CDN\" |
            .xray.cdnBackend = \"nginx\" |
            .nginx.domain = \"${OLD_ORIGIN}\" |
            .nginx.cdn = \"${NEW_CDN}\"
        "
        ;;
    --install | --cdn-backend)
        return 0
        ;;
    --nginx-install)
        printf '%s\n' 'mutated origin' >"${OLD_ORIGIN_AVAILABLE}"
        rm -f -- "${OLD_ORIGIN_ENABLED}"
        printf '%s\n' 'wrong enabled type' >"${OLD_ORIGIN_ENABLED}"
        rm -f -- "${OLD_CDN_AVAILABLE}" "${OLD_CDN_ENABLED}"
        printf '%s\n' 'new cdn contents' >"${NEW_CDN_AVAILABLE}"
        ln -s "../sites-available/${NEW_CDN}.conf" "${NEW_CDN_ENABLED}"
        rm -f -- "${STREAM_CONFIG}"
        ln -s '../sites-available/not-stream.conf' "${STREAM_CONFIG}"
        ;;
    --xray-config)
        replace_script_config '.nginx.domain = ""'
        printf '%s\n' '{"marker":"new-runtime"}' >"${XRAY_RUNTIME_CONFIG_PATH}"
        if [[ -e "${SIGNAL_DURING_XRAY}" ]]; then
            kill -TERM "${BASHPID}"
        fi
        ;;
    --restart)
        [[ "${FAIL_RESTART}" -eq 0 ]]
        ;;
    --recover-runtime)
        printf 'recover\n' >>"${RECOVERY_LOG}"
        if ! cmp -s "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}" ||
            ! cmp -s "${RUNTIME_BASELINE}" "${XRAY_RUNTIME_CONFIG_PATH}" ||
            ! artifacts_match_baseline ||
            ! unrelated_artifacts_match_baseline; then
            : >"${RECOVERY_BAD_STATE}"
        fi
        ;;
    --share)
        printf 'share\n' >>"${SHARE_LOG}"
        [[ ! -e "${FAIL_SHARE}" ]]
        ;;
    *)
        echo "unexpected handler call: $*" >&2
        return 1
        ;;
    esac
}

if install_protocol CDN; then
    echo 'CDN installation ignored the simulated restart failure' >&2
    exit 1
fi

[[ "$(wc -l <"${RECOVERY_LOG}")" -eq 1 ]]
[[ ! -e "${RECOVERY_BAD_STATE}" ]]
cmp -s "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}"
cmp -s "${RUNTIME_BASELINE}" "${XRAY_RUNTIME_CONFIG_PATH}"
artifacts_match_baseline
unrelated_artifacts_match_baseline

function assert_no_transaction_files() {
    local journal_leftovers install_leftovers runtime_leftovers

    journal_leftovers="$(
        compgen -G "${SCRIPT_CONFIG_PATH}.nginx-journal.*" || true
    )"
    install_leftovers="$(compgen -G "${SCRIPT_CONFIG_PATH}.install.*" || true)"
    runtime_leftovers="$(
        compgen -G "${XRAY_RUNTIME_CONFIG_PATH}.install.*" || true
    )"
    [[ -z "${journal_leftovers}${install_leftovers}${runtime_leftovers}" ]]
}

assert_no_transaction_files
[[ ! -s "${SHARE_LOG}" ]]

# TERM after files have been mutated must take the same rollback path as an
# ordinary stage failure.
: >"${SIGNAL_DURING_XRAY}"
if install_protocol CDN; then
    echo 'CDN installation ignored TERM during Xray config generation' >&2
    exit 1
fi
rm -f -- "${SIGNAL_DURING_XRAY}"
[[ "$(wc -l <"${RECOVERY_LOG}")" -eq 2 ]]
[[ ! -e "${RECOVERY_BAD_STATE}" ]]
cmp -s "${SCRIPT_BASELINE}" "${SCRIPT_CONFIG_PATH}"
cmp -s "${RUNTIME_BASELINE}" "${XRAY_RUNTIME_CONFIG_PATH}"
artifacts_match_baseline
unrelated_artifacts_match_baseline
assert_no_transaction_files

# A held advisory lock rejects a concurrent install before the first mutation.
LOCKED_SCRIPT_HASH="$(sha256sum "${SCRIPT_CONFIG_PATH}")"
exec {HELD_LOCK_FD}>"${SCRIPT_CONFIG_PATH}.lock"
flock -n "${HELD_LOCK_FD}"
if install_protocol CDN >/dev/null 2>&1; then
    echo 'Concurrent protocol installation bypassed the transaction lock' >&2
    exit 1
fi
flock -u "${HELD_LOCK_FD}"
exec {HELD_LOCK_FD}>&-
[[ "$(sha256sum "${SCRIPT_CONFIG_PATH}")" == "${LOCKED_SCRIPT_HASH}" ]]
assert_no_transaction_files

# A successful second attempt keeps the newly rendered artifacts and removes
# the journal instead of leaving transaction state behind.
FAIL_RESTART=0
install_protocol CDN
[[ "$(wc -l <"${SHARE_LOG}")" -eq 1 ]]
[[ -f "${NEW_CDN_AVAILABLE}" ]]
[[ -L "${NEW_CDN_ENABLED}" ]]
[[ -L "${STREAM_CONFIG}" ]]
unrelated_artifacts_match_baseline
assert_no_transaction_files

# Share rendering is post-commit. Its failure must not report the healthy
# protocol installation as failed or roll the runtime back.
: >"${FAIL_SHARE}"
if ! install_protocol CDN >"${TEST_DIR}/share-failure.stdout" \
    2>"${TEST_DIR}/share-failure.stderr"; then
    echo 'Post-commit share failure was reported as an install failure' >&2
    exit 1
fi
rm -f -- "${FAIL_SHARE}"
if ! grep -Fq 'share-link generation failed' \
    "${TEST_DIR}/share-failure.stderr"; then
    cat "${TEST_DIR}/share-failure.stderr" >&2
    echo 'Missing post-commit share warning' >&2
    exit 1
fi
[[ "$(wc -l <"${SHARE_LOG}")" -eq 2 ]]
[[ -f "${NEW_CDN_AVAILABLE}" ]]
[[ -L "${NEW_CDN_ENABLED}" ]]
assert_no_transaction_files

# Invalid domains and non-fixed relative paths must be rejected before any
# path outside the explicitly supported Nginx artifact set can be considered.
readonly INVALID_CONFIG="${TEST_DIR}/invalid.json"
jq '.nginx.cdn = "../../escape"' \
    "${SCRIPT_BASELINE}" >"${INVALID_CONFIG}"
if create_nginx_artifact_journal \
    "${SCRIPT_BASELINE}" "${INVALID_CONFIG}" >/dev/null; then
    echo 'Nginx artifact journal accepted a traversal-shaped domain' >&2
    exit 1
fi
jq '.nginx.cdn = "safe.example.test\nother.example.test"' \
    "${SCRIPT_BASELINE}" >"${INVALID_CONFIG}"
if create_nginx_artifact_journal \
    "${SCRIPT_BASELINE}" "${INVALID_CONFIG}" >/dev/null; then
    echo 'Nginx artifact journal split and accepted a multiline domain' >&2
    exit 1
fi
! nginx_artifact_relative_path_is_safe '../sites-available/example.test.conf'
! nginx_artifact_relative_path_is_safe 'certs/example.test/fullchain.pem'
assert_no_transaction_files

echo 'Nginx artifact transaction tests passed'
