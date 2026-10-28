#!/usr/bin/env bash
# Disposable Debian/Ubuntu integration check. No host services, firewall, Docker
# socket, or writable project directories are exposed to the inner container.
# Usage: bash tests/run_isolated.sh debian:12-slim /tmp/core-new /tmp/core-old
# Prepare both directories with tests/download_core.py (different release tags).
set -euo pipefail

if [[ "$#" != 3 ]]; then
    echo "Usage: $0 IMAGE VERIFIED_CORE_DIRECTORY VERIFIED_PREVIOUS_CORE_DIRECTORY" >&2
    exit 2
fi

test_image="$1"
test_core="$(realpath -- "$2")"
test_previous_core="$(realpath -- "$3")"
test_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_ca_bundle='/etc/ssl/certs/ca-certificates.crt'
[[ -r "${test_ca_bundle}" && -x "${test_core}/xray" && -x "${test_previous_core}/xray" ]]
docker_cmd=(env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH docker --host=unix:///var/run/docker.sock)

"${docker_cmd[@]}" run --rm --init --pids-limit 256 --memory 2g \
    --mount "type=bind,src=${test_root},dst=/project,readonly" \
    --mount "type=bind,src=${test_core},dst=/opt/core,readonly" \
    --mount "type=bind,src=${test_previous_core},dst=/opt/previous-core,readonly" \
    --mount "type=bind,src=${test_ca_bundle},dst=/run/test-ca-bundle.pem,readonly" \
    -e XRAY_ISOLATED_CONTAINER=1 -e PYTHONDONTWRITEBYTECODE=1 \
    -e SSL_CERT_FILE=/run/test-ca-bundle.pem -e CURL_CA_BUNDLE=/run/test-ca-bundle.pem \
    -e DEBIAN_FRONTEND=noninteractive -w /project "${test_image}" bash -c '
set -euo pipefail
apt_options=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
if ! { apt-get "${apt_options[@]}" update >/tmp/test-packages.log 2>&1 &&
    apt-get "${apt_options[@]}" install -y --no-install-recommends python3 jq openssl curl unzip \
        shellcheck systemd passwd util-linux procps psmisc ncurses-bin \
        >>/tmp/test-packages.log 2>&1; }; then
    tail -80 /tmp/test-packages.log >&2
    exit 1
fi
head -2 /etc/os-release
python3 -m unittest discover -s tests -v
shellcheck --severity=warning --exclude=SC1090,SC1091,SC2034,SC2155 \
    install.sh core/*.sh lib/*.sh service/*.sh tool/*.sh \
    config/lan/*.sh config/cloudflare-warp/*.sh tests/run_isolated.sh
python3 tests/check_core_configs.py --xray /opt/core/xray --smoke
python3 tests/isolated_lifecycle.py --core /opt/core --previous-core /opt/previous-core
'
