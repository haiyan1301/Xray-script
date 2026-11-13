"""Run the real certificate-name validator with an existing OpenSSL binary.

Linux/WSL usage:
  python3 audit_2026-11-12/probe_openssl_compatibility.py --prefix /tmp/extracted

The prefix can be a temporary directory populated using dpkg-deb -x with
Ubuntu openssl/libssl packages. This script does not download/install anything.
Omit --prefix to use the current system OpenSSL as a control.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from reproduce_findings import functions


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", type=Path)
    args = parser.parse_args()
    env = os.environ.copy()
    if args.prefix:
        prefix = args.prefix.resolve()
        env["PATH"] = str(prefix / "usr/bin") + ":" + env["PATH"]
        env["LD_LIBRARY_PATH"] = str(prefix / "usr/lib/x86_64-linux-gnu")
    with tempfile.TemporaryDirectory(prefix="xray-openssl-compat-") as directory:
        work = Path(directory)
        # Generate with the host OpenSSL, then validate with the selected version.
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
            "ec_paramgen_curve:P-256", "-nodes", "-subj", "/CN=right.example.com",
            "-addext", "subjectAltName=DNS:right.example.com", "-keyout",
            str(work / "key.pem"), "-out", str(work / "cert.pem"), "-days", "1",
        ], check=True, capture_output=True)
        evidence = {
            "version": subprocess.check_output(["openssl", "version"], env=env, text=True).strip(),
            "checks": [],
        }
        for option, name in [
            ("-checkhost", "right.example.com"),
            ("-checkhost", "wrong.example.com"),
            ("-checkip", "192.0.2.11"),
        ]:
            result = subprocess.run(
                ["openssl", "x509", "-in", str(work / "cert.pem"), "-noout", option, name],
                env=env, text=True, capture_output=True, timeout=10,
            )
            evidence["checks"].append({"argument": name, "exit": result.returncode, "output": result.stdout.strip()})
        body = functions("lib/cert.sh", "cert_validate_pair")
        body += functions("core/handler.sh", "validate_tls_certificate_pair",
                          "certificate_matches_server_name", "validate_cdn_direct_certificate")
        body += r'''
validate_cdn_direct_certificate "$1" "$2" wrong.example.com
printf 'wrong_domain_validator_exit=%s\n' "$?"
validate_cdn_direct_certificate "$1" "$2" 192.0.2.11
printf 'wrong_ip_validator_exit=%s\n' "$?"
'''
        result = subprocess.run(
            ["bash", "-c", body, "audit", str(work / "cert.pem"), str(work / "key.pem")],
            env=env, text=True, capture_output=True, timeout=10, check=True,
        )
        evidence["project_validation"] = result.stdout.strip()
        print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()
