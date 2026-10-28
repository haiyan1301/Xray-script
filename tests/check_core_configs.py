"""Validate generated protocol configurations with a supplied official Xray binary.

Usage: python3 tests/check_core_configs.py --xray /path/to/xray
Place geoip.dat and geosite.dat beside the binary. No service is started.
"""

import argparse
import base64
import copy
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xray", required=True, type=Path)
    args = parser.parse_args()
    binary = args.xray.resolve(strict=True)
    key_output = subprocess.check_output([str(binary), "x25519"], text=True)
    private_key = re.search(r"Private\s*[Kk]ey:\s*(\S+)", key_output).group(1)

    with tempfile.TemporaryDirectory(prefix="xray-core-configs-") as directory:
        work = Path(directory)
        certs = work / "certs"
        certs.mkdir()
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                "ec_paramgen_curve:P-256", "-nodes", "-days", "1",
                "-subj", "/CN=cdn.example.com", "-addext",
                "subjectAltName=DNS:cdn.example.com,DNS:download.example.com",
                "-keyout", str(certs / "privkey.pem"),
                "-out", str(certs / "fullchain.pem"),
            ],
            check=True,
            capture_output=True,
        )
        base = json.loads((ROOT / "config.json").read_text())
        base["language"] = "en"
        base["xray"].update(
            port=14443, uuid=str(uuid.uuid4()), fallback=str(uuid.uuid4()),
            trojan="ExampleStrongPassword", hy2auth="ExampleHy2Password",
            kcp="ExampleKcpSeed", ss2022Key=base64.b64encode(os.urandom(32)).decode(),
            privateKey=private_key, serverNames=["example.com"],
            shortIds=["0123456789abcdef"], target="example.com", path="/audit-path/",
            xhttpMode="packet-up", vlessEncEnable="n", mldsa65Enable="n",
            hy2CertDomain="cdn.example.com", hy2CertSource="3", cdnCertSource="3",
            cdnDownCertSource="3",
        )
        base["nginx"].update(cdn="cdn.example.com", cdnDown="download.example.com")
        configurations = [(tag, "nginx") for tag in
                          ["Vision", "XHTTP", "Trojan", "Fallback", "hy2", "ss2022", "mKCP", "SNI", "CDN"]]
        configurations += [("CDN", "xray"), ("multi", "nginx")]
        failures = []
        for tag, backend in configurations:
            config = copy.deepcopy(base)
            config["xray"].update(tag=tag, cdnBackend=backend)
            if tag == "multi":
                config["xray"]["nodes"] = [
                    dict(base["xray"], tag=node_tag, port=15000 + index)
                    for index, node_tag in enumerate(
                        ["Vision", "XHTTP", "Trojan", "Fallback", "hy2", "ss2022", "mKCP"]
                    )
                ]
            config_path = work / "script-config.json"
            runtime_path = work / "runtime.json"
            config_path.write_text(json.dumps(config))
            runtime_path.unlink(missing_ok=True)
            env = os.environ | {
                "SCRIPT_CONFIG_PATH_OVERRIDE": str(config_path),
                "XRAY_CONFIG_PATH_OVERRIDE": str(runtime_path),
                "XRAY_AUDIT_BIN": str(binary),
                "XRAY_AUDIT_CERTS": str(certs),
                "XRAY_AUDIT_WORK": str(work),
                "XRAY_LOCATION_ASSET": str(binary.parent),
            }
            # Only user/group changes, firewall mutations, and certificate paths
            # are replaced. The project's generator and Xray validator both run.
            body = f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n" + """
sync() { :; }
id() { return 1; }
xray() {
    # The normal installer creates /var/log/xray. Redirect logs only during this
    # unprivileged validation so the check does not write into the host's /var.
    if [[ "$1 $2 $3" == 'run -test -c' ]]; then
        jq '.log.access = "none" | .log.error = "none"' "$4" >"${XRAY_AUDIT_WORK}/validation.json" || return 1
        "${XRAY_AUDIT_BIN}" run -test -c "${XRAY_AUDIT_WORK}/validation.json"
    else
        "${XRAY_AUDIT_BIN}" "$@"
    fi
}
firewall_owned_open() { return 0; }
handler_lan_open_firewall() { return 0; }
get_hy2_cert_dir() { printf '%s' "${XRAY_AUDIT_CERTS}"; }
get_cdn_direct_cert_dir() { printf '%s' "${XRAY_AUDIT_CERTS}"; }
load_i18n
handler_xray_config 1
"""
            result = subprocess.run(
                ["bash", "-c", body], env=env, cwd=ROOT,
                capture_output=True, text=True, timeout=60,
            )
            name = tag + ("/" + backend if tag == "CDN" else "")
            if result.returncode:
                failures.append(name)
                print(f"FAIL {name}\n{result.stderr}")
            else:
                print(f"PASS {name}")
        if failures:
            raise SystemExit("Failed configurations: " + ", ".join(failures))


if __name__ == "__main__":
    main()
