#!/usr/bin/env bash
printf '%s\n' "$*" >>"${IP_LOG}"
if [[ -n "${IP_FAIL_MATCH:-}" && "$*" == *"${IP_FAIL_MATCH}"* ]]; then
    exit 23
fi
if [[ "$*" == 'link show dev xray0' ]]; then
    exit 0
fi
exit 0
