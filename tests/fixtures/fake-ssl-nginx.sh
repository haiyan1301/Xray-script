#!/usr/bin/env bash
set -u

: "${FAKE_NGINX_LOG:?}"
: "${FAKE_NGINX_CONFIG:?}"

printf '%s\n' "$*" >>"${FAKE_NGINX_LOG}"
[[ "${1:-}" == "-t" ]] || exit 64

count_file="${FAKE_NGINX_LOG}.test.count"
call_number=0
[[ ! -f "${count_file}" ]] || read -r call_number <"${count_file}"
call_number=$((call_number + 1))
printf '%s\n' "${call_number}" >"${count_file}"

if [[ ",${FAKE_NGINX_FAIL_TEST_CALLS:-}," == *",${call_number},"* ]]; then
    exit 1
fi

[[ -f "${FAKE_NGINX_CONFIG}" ]] || exit 1
if grep -Fq '# requires-certificate' "${FAKE_NGINX_CONFIG}"; then
    [[ -s "${FAKE_NGINX_FULLCHAIN:?}" && -s "${FAKE_NGINX_PRIVKEY:?}" ]] ||
        exit 1
fi
