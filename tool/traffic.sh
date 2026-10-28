#!/usr/bin/env bash

set -euo pipefail

# Xray API 端口由调用方（core/handler.sh）通过环境变量传入，避免这里再写死一份
_APISERVER="127.0.0.1:${XRAY_API_PORT:?XRAY_API_PORT is not set}"
_XRAY="${XRAY_BIN_PATH_OVERRIDE:-/usr/local/bin/xray}"

apidata() {
    local -a args=()
    if [[ "${1:-}" == "reset" ]]; then
        args+=(-reset=true)
    fi
    "${_XRAY}" api statsquery "--server=${_APISERVER}" "${args[@]}" |
        jq -r '
            (.stat // [])[] |
            (.name | split(">>>")) as $parts |
            select(($parts | length) == 4) |
            [($parts[0] + ":" + $parts[1] + "->" + ($parts[3] | sub("link$"; ""))),
             (.value // "0" | tostring)] | @tsv
        '
}

print_sum() {
    local DATA="$1"
    local PREFIX="$2"
    local SORTED
    SORTED=$(printf '%s\n' "$DATA" | awk -v prefix="${PREFIX}:" 'index($0, prefix) == 1' | sort -r)
    local SUM=$(echo "$SORTED" | awk '
        /->up/{us+=$2}
        /->down/{ds+=$2}
        END{
            printf "SUM->up:\t%.0f\nSUM->down:\t%.0f\nSUM->TOTAL:\t%.0f\n", us, ds, us+ds;
        }')
    echo -e "${SORTED}\n${SUM}" |
        numfmt --field=2 --suffix=B --to=iec |
        column -t
}

# numfmt 来自 coreutils，column 来自 util-linux / bsdmainutils。
# 先给出可读提示，避免直接抛 "command not found"。
for _cmd in jq numfmt column; do
    if ! command -v "${_cmd}" >/dev/null 2>&1; then
        echo "Required command not found: ${_cmd}" >&2
        exit 1
    fi
done

DATA=$(apidata "${1:-}") || exit 1
echo "------------Inbound----------"
print_sum "$DATA" "inbound"
echo "-----------------------------"
echo "------------Outbound----------"
print_sum "$DATA" "outbound"
echo "-----------------------------"
echo
echo "-------------User------------"
print_sum "$DATA" "user"
echo "-----------------------------"
