"""Offline audit probes against the current source, not acceptance tests.

Run on Linux/WSL: python3 audit_2026-11-12/reproduce_findings.py
Requires bash, jq and openssl. All writes stay in temporary directories.
No ACME request, Docker operation or system service operation is performed.
CONFIRMED means the faulty behavior was reproduced, not that the code is fixed.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RESULTS = []


def functions(path, *names):
    source = (ROOT / path).read_text(encoding="utf-8")
    result = []
    for name in names:
        match = re.search(
            rf"^function {re.escape(name)}\(\) [{{(]\n.*?^[}})]$",
            source, re.MULTILINE | re.DOTALL,
        )
        if not match:
            raise RuntimeError(f"Missing function {path}:{name}")
        result.append(match.group())
    return "\n".join(result) + "\n"


def run(body, work):
    result = subprocess.run(
        ["bash", "-c", body], cwd=ROOT,
        env=os.environ | {"AUDIT_TMP": str(work), "AUDIT_ROOT": str(ROOT)},
        capture_output=True, text=True, timeout=20,
    )
    if result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result.stdout.strip()


def record(identifier, detail):
    RESULTS.append({"id": identifier, "status": "CONFIRMED", "evidence": detail})


QUIET = """
t() { printf '%s' "$1"; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_tip() { :; }
log_config() { :; }
print_info() { :; }
"""


def main():
    with tempfile.TemporaryDirectory(prefix="xray-focused-audit-") as directory:
        work = Path(directory)
        # Match a Linux checkout; Windows Git may materialize templates as CRLF.
        template = Path("config/nginx/conf/modules-enabled/stream.conf")
        (work / template).parent.mkdir(parents=True)
        (work / template).write_text((ROOT / template).read_text(encoding="utf-8"), encoding="utf-8")
        render = functions("core/handler.sh", "render_nginx_stream_config")
        output = run(render + r'''
CONFIG_DIR="${AUDIT_TMP}/config"
SCRIPT_CONFIG='{"xray":{"tag":"CDN"},"nginx":{"domain":"","cdn":"up.example.com","cdnDown":"down.example.com"}}'
render_nginx_stream_config "${AUDIT_TMP}/stream.conf"
result=$?
[[ $result -eq 1 ]] || exit 1
printf 'pure CDN render exit=%s\n' "$result"
SCRIPT_CONFIG='{"xray":{"tag":"CDN"},"nginx":{"domain":"old.example.com","cdn":"up.example.com","cdnDown":"down.example.com"}}'
render_nginx_stream_config "${AUDIT_TMP}/stream.conf" || exit 1
grep -q 'up.example.com.*cdn_to_nginx' "${AUDIT_TMP}/stream.conf" || exit 1
if grep -q 'down.example.com' "${AUDIT_TMP}/stream.conf"; then exit 1; fi
printf 'legacy domain present: render exit=0, downlink mapping absent\n'
''', work)
        record("CDN-1/CDN-2", output)

        # Use real OpenSSL certificates and the real deployment/renew entry points.
        (work / "index.txt").touch()
        (work / "serial").write_text("01\n")
        (work / "ca.cnf").write_text(
            "[ca]\ndefault_ca=local\n[local]\n"
            f"database={work}/index.txt\nserial={work}/serial\nnew_certs_dir={work}\n"
            "default_md=sha256\npolicy=names\n[names]\ncommonName=supplied\n"
        )
        for args in [
            ["openssl", "req", "-new", "-newkey", "ec", "-pkeyopt",
             "ec_paramgen_curve:P-256", "-nodes", "-subj", "/CN=cert.example.com",
             "-keyout", str(work / "key.pem"), "-out", str(work / "cert.csr")],
            ["openssl", "ca", "-selfsign", "-batch", "-notext", "-config", str(work / "ca.cnf"),
             "-in", str(work / "cert.csr"), "-keyfile", str(work / "key.pem"),
             "-startdate", "20200101000000Z", "-enddate", "20200102000000Z",
             "-out", str(work / "expired.pem")],
            ["openssl", "x509", "-req", "-in", str(work / "cert.csr"),
             "-signkey", str(work / "key.pem"), "-days", "1",
             "-out", str(work / "valid.pem")],
        ]:
            subprocess.run(args, check=True, capture_output=True)
        mock_acme = work / "mock-acme"
        mock_acme.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >>"${AUDIT_TMP}/acme-calls"
while (($#)); do
    case "$1" in
        --key-file) cp "${AUDIT_TMP}/key.pem" "$2"; shift ;;
        --fullchain-file) cp "${AUDIT_TMP}/selected.pem" "$2"; shift ;;
    esac
    shift
done
exit 0
''', encoding="utf-8")
        mock_acme.chmod(0o700)
        body = functions("lib/cert.sh", "cert_validate_pair", "cert_backup_pair", "cert_restore_pair")
        body += functions("core/handler.sh", "build_certificate_reload_command",
                          "install_acme_managed_certificate", "install_acme_xray_certificate",
                          "handler_restore_certificate_renewal_hooks", "handler_renew_ssl")
        output = run(body + QUIET + r'''
CUR_DIR="${AUDIT_ROOT}/core"
ACME_PATH="${AUDIT_TMP}/mock-acme"
SCRIPT_CONFIG='{"xray":{"tag":"hy2"}}'
list_active_acme_certificate_consumers() {
    printf 'cert.example.com\txray\tcert.example.com\t%s/deployed\n' "${AUDIT_TMP}"
}
validate_cdn_direct_certificate() { cert_validate_pair "$1" "$2"; }
cert_set_permissions() { :; }
reload_certificate_consumer() { :; }
current_protocol_uses_nginx() { return 1; }
handler_restart() { :; }
exec_ssl() { printf '%s\n' "$*" >>"${AUDIT_TMP}/renew-calls"; }
cp "${AUDIT_TMP}/expired.pem" "${AUDIT_TMP}/selected.pem"
handler_renew_ssl
result=$?
[[ $result -eq 1 && ! -f "${AUDIT_TMP}/renew-calls" ]] || exit 1
printf 'expired stored certificate: renew entry exit=%s, ACME renewal not reached\n' "$result"
cp "${AUDIT_TMP}/valid.pem" "${AUDIT_TMP}/selected.pem"
handler_renew_ssl || exit 1
grep -q -- '--renew' "${AUDIT_TMP}/renew-calls" || exit 1
printf 'valid certificate control: renewal reached\n'
''', work)
        record("CERT-EXPIRED", output)

        # The ACME list contains a wildcard record covering the configured host.
        wildcard_acme = work / "wildcard-acme"
        wildcard_acme.write_text("#!/bin/sh\nprintf '%s\\n' 'Main_Domain KeyLength SAN_Domains' '*.example.com ec-256 no'\n")
        wildcard_acme.chmod(0o700)
        body = functions("core/handler.sh", "acme_main_domain_for_name",
                         "emit_active_acme_certificate_consumer", "list_active_acme_certificate_consumers")
        output = run(body + r'''
ACME_PATH="${AUDIT_TMP}/wildcard-acme"
NGINX_CONFIG_DIR="${AUDIT_TMP}/nginx"
SCRIPT_CONFIG='{"xray":{"tag":"CDN"},"nginx":{"cdn":"up.example.com","cdnDown":"","certificates":{"cdn":{"source":"1","hostname":"up.example.com"}}}}'
get_cdn_backend() { printf nginx; }
known="$(acme_main_domain_for_name '*.example.com')"
[[ $known == '*.example.com' ]] || exit 1
lines="$(list_active_acme_certificate_consumers '*.example.com')"
[[ $? -eq 0 && -z $lines ]] || exit 1
list_active_acme_certificate_consumers >/dev/null
result=$?
[[ $result -eq 1 ]] || exit 1
printf 'wildcard record found; renewal callback consumers=0; hook restoration exit=%s\n' "$result"
''', work)
        record("CERT-WILDCARD", output)

        body = functions("core/handler.sh", "handler_hy2_cert", "configure_hy2_ip_renewal_cron")
        output = run(body + QUIET + r'''
SCRIPT_CONFIG='{"xray":{"hy2CertSource":"2","hy2CertDomain":"192.0.2.11"},"nginx":{}}'
SCRIPT_CONFIG_PATH="${AUDIT_TMP}/hy2.json"
exec_check() { :; }
get_hy2_cert_dir() { printf '%s/hy2' "${AUDIT_TMP}"; }
prompt_cert_reuse() { printf '192.0.2.10'; }
acme_main_domain_for_name() { printf '192.0.2.10'; }
install_acme_xray_certificate() { touch "$3/fullchain.pem" "$3/privkey.pem"; }
validate_cdn_direct_certificate() { :; }
set_xray_certificate_permissions() { :; }
read_current_crontab() { :; }
is_managed_hy2_ip_cron_line() { return 1; }
crontab() { cat >"${AUDIT_TMP}/hy2.cron"; }
write_config() { printf '%s' "$1" >"$2"; }
handler_hy2_cert || exit 1
[[ $(jq -r .xray.hy2CertAcmeDomain "${SCRIPT_CONFIG_PATH}") == '192.0.2.10' ]] || exit 1
grep -q -- '--renew -d 192.0.2.11 ' "${AUDIT_TMP}/hy2.cron" || exit 1
printf 'saved ACME main=192.0.2.10; dedicated renewal cron targets SAN=192.0.2.11\n'
''', work)
        record("IP-CRON", output)

        body = functions("config/cloudflare-warp/startup.sh", "repair_registration", "warp_cli_retry", "configure_warp")
        output = run(body + QUIET + r'''
CONFIG_ATTEMPTS=3
REGISTRATION_ATTEMPTS=3
RETRY_INTERVAL=0
AUDIT_CONNECT_ATTEMPTS=0
warp_cli() {
    printf '%s\n' "$*" >>"${AUDIT_TMP}/warp-cli-calls"
    if [[ $1 == connect ]]; then
        AUDIT_CONNECT_ATTEMPTS=$((AUDIT_CONNECT_ATTEMPTS + 1))
        ((AUDIT_CONNECT_ATTEMPTS > 3)) || return 1
    fi
    return 0
}
configure_warp || exit 1
grep -qx 'registration delete' "${AUDIT_TMP}/warp-cli-calls" || exit 1
grep -qx 'registration new' "${AUDIT_TMP}/warp-cli-calls" || exit 1
printf 'three generic connect failures triggered registration delete/new, then success\n'
''', work)
        record("WARP-IDENTITY", output)

        body = functions("config/cloudflare-warp/startup.sh", "probe_proxy_port")
        body += functions("service/docker.sh", "_warp_container_ready", "wait_for_warp",
                          "_warp_container_connected", "_warp_status", "warp_health")
        output = run(body + QUIET + r'''
WARP_PROXY_PORT=40000
WARP_HOST=127.0.0.1
WARP_NAME=xray-script-warp
timeout() { return 1; }
probe_proxy_port || exit 1
cmd_exists() { return 1; }
_warp_container_state() { printf running; }
_warp_container_has_expected_runtime() { return 0; }
docker() {
    printf '%s\n' "$*" >>"${AUDIT_TMP}/docker-health-calls"
    case "$1 $2" in
        'info ') return 0 ;;
        'inspect --format={{.State.Status}}') printf running ;;
        'inspect --format={{.State.Health.Status}}') printf unhealthy ;;
        'exec xray-script-warp') printf 'Status update: Connected\n' ;;
        *) return 99 ;;
    esac
}
endpoint="$(wait_for_warp "${WARP_NAME}" 0)" || exit 1
[[ $endpoint == 127.0.0.1 ]] || exit 1
warp_health || exit 1
if grep -q 'State.Health' "${AUDIT_TMP}/docker-health-calls"; then exit 1; fi
printf 'closed SOCKS probe accepted; wait_for_warp and warp_health succeed without checking Docker health or endpoint\n'
''', work)
        record("WARP-READY", output)

        body = functions("service/docker.sh", "repair_warp")
        output = run(body + QUIET + r'''
WARP_NAME=xray-script-warp
WARP_IMAGE=xray-script-warp:latest
docker_ready() { :; }
_warp_container_state() { printf running; }
_warp_container_has_expected_runtime() { return 1; }
build_warp() { :; }
docker() {
    [[ "$*" == 'rm -f xray-script-warp' ]] || return 99
    printf 'old container removed\n' >>"${AUDIT_TMP}/migration"
}
_warp_run_container() {
    printf 'replacement failed\n' >>"${AUDIT_TMP}/migration"
    return 1
}
repair_warp
result=$?
[[ $result -eq 1 ]] || exit 1
[[ $(wc -l <"${AUDIT_TMP}/migration") -eq 2 ]] || exit 1
printf 'repair exit=%s after deleting old container; no restoration attempted\n' "$result"
''', work)
        record("WARP-MIGRATION", output)

    print(json.dumps(RESULTS, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
