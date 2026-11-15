"""Validate generated protocol configurations with a supplied official Xray binary.

Usage: python3 tests/check_core_configs.py --xray /path/to/xray [--smoke]
Place geoip.dat and geosite.dat beside the binary. --smoke also starts a
temporary foreground process on loopback ports and temporary Unix sockets.
No system service, firewall or host configuration is changed.
"""

import argparse
import base64
import copy
import errno
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]


def key_value(output, label):
    match = re.search(rf"(?im)^{label}:\s*(\S+)", output)
    if not match:
        raise RuntimeError(f"Xray did not return {label}")
    return match.group(1)


def configuration_matrix(base, pq):
    """Cover every protocol and the branches that change generated inbounds."""
    cases = []

    def add(tag, backend="nginx", *, name=None, nodes=None, **options):
        config = copy.deepcopy(base)
        config["xray"].update(tag=tag, cdnBackend=backend, **options)
        if nodes:
            config["xray"]["nodes"] = [
                dict(base["xray"], tag=node_tag, port=15000 + index)
                for index, node_tag in enumerate(nodes)
            ]
        cases.append((name or tag + ("/" + backend if tag == "CDN" else ""), config))

    tags = ["Vision", "XHTTP", "Trojan", "Fallback", "hy2", "ss2022", "mKCP", "SNI", "CDN"]
    nodes = ["Vision", "XHTTP", "Trojan", "Fallback", "hy2", "ss2022", "mKCP"]
    for tag in tags:
        add(tag)
    add("CDN", "xray")
    add("multi", nodes=nodes)
    # Optional key material must reach the generated inbounds, including the
    # fallback exception and mixed-node propagation.
    for tag in ["Vision", "XHTTP", "Trojan", "Fallback", "mKCP", "SNI"]:
        add(tag, name=tag + "/post-quantum", **pq)
    add("CDN", "xray", name="CDN/xray/post-quantum", **pq)
    add("CDN", name="CDN/nginx/post-quantum", **pq)
    add("multi", name="multi/post-quantum", nodes=nodes, **pq)
    add("multi", name="multi/hy2-only", nodes=["hy2"])
    add("multi", name="multi/ss2022-only", nodes=["ss2022"])
    # The defaults above exercise packet-up and two CDN domains. Cover all
    # other supported XHTTP modes and each backend's single-domain branch.
    for mode in ["auto", "stream-up", "stream-one"]:
        add("XHTTP", name="XHTTP/" + mode, xhttpMode=mode)
    for backend in ["nginx", "xray"]:
        add("CDN", backend, name="CDN/" + backend + "/single-domain")
        cases[-1][1]["nginx"]["cdnDown"] = ""
    for tag in ["Vision", "XHTTP", "Fallback", "SNI"]:
        add(tag, name=tag + "/reverse", reverse=1, reversePort=18443,
            reverseUuid=str(uuid.uuid4()), reverseTarget="127.0.0.1:18080")

    relay_node = {
        "id": "audit-relay", "name": "Audit relay", "protocol": "socks",
        "address": "203.0.113.10", "port": 1080, "username": "", "password": "",
    }
    relay_cases = [
        ("Vision", "all", "nginx", True),
        ("Vision", "domains", "nginx", False),
        ("XHTTP", "domains", "nginx", False),
        ("Trojan", "all", "nginx", False),
        ("Fallback", "all", "nginx", True),
        ("hy2", "domains", "nginx", False),
        ("ss2022", "all", "nginx", False),
        ("mKCP", "domains", "nginx", False),
        ("SNI", "all", "nginx", False),
        ("CDN", "domains", "nginx", False),
        ("CDN", "all", "xray", True),
        ("multi", "domains", "nginx", False),
        ("multi", "all", "nginx", True),
        ("Vision", "off", "nginx", False),
    ]
    for tag, mode, backend, warp in relay_cases:
        node = copy.deepcopy(relay_node)
        # The second Vision case also exercises REALITY as an outbound.
        if tag == "Vision" and mode == "domains":
            node.update(protocol="vless", port=443, uuid=str(uuid.uuid4()),
                        serverName="relay.example.com", publicKey="A" * 43,
                        shortId="0123456789abcdef", flow="xtls-rprx-vision",
                        encryption="none")
        relay = {"nodes": [node], "active": node["id"] if mode != "off" else None,
                 "mode": mode, "domains": ["domain:example.com", "full:api.example.net"]}
        add(tag, backend, name=f"{tag}/{backend}/relay-{mode}" + ("/warp" if warp else ""),
            nodes=nodes if tag == "multi" else None, relay=relay, warp=int(warp))
        config = cases[-1][1]
        config["rules"] += [
            {"ruleTag": "audit-custom-block", "domain": ["domain:blocked.example"], "outboundTag": "block"},
            {"ruleTag": "audit-warp", "domain": ["domain:example.com"], "outboundTag": "warp"},
        ]
        if tag in {"Fallback", "SNI"}:
            config["xray"].update(reverse=1, reversePort=18443,
                                  reverseUuid=str(uuid.uuid4()), reverseTarget="127.0.0.1:18080")
        # LAN, reverse, Vision anti-steal, custom blocking, WARP and relay must
        # coexist without a dedicated service or a remote relay being online.
        if tag == "Vision" and mode == "all":
            config["xray"].update(reverse=1, reversePort=18443,
                                  reverseUuid=str(uuid.uuid4()), reverseTarget="127.0.0.1:18080")
            config["xray"]["lan"].update(
                enabled=1, port=19443, target="example.com", serverName="example.com",
                serverAddress="203.0.113.1", privateKey=base["xray"]["privateKey"],
                publicKey="A" * 43, shortId="01", sites=[{
                    "id": "audit-site", "accessUuid": str(uuid.uuid4()),
                    "reverseUuid": str(uuid.uuid4()), "reverseTag": "lan-reverse-audit-site",
                    "localCidrs": ["10.23.0.0/24"],
                }],
            )
    return cases


def check_optional_features(config, runtime):
    """A valid configuration must also retain the features requested by users."""
    state = config["xray"]
    if state.get("vlessEncEnable") == "y":
        applicable = [
            inbound for inbound in runtime["inbounds"]
            if inbound.get("protocol") == "vless"
            and "fallbacks" not in inbound.get("settings", {})
        ]
        for inbound in applicable:
            if inbound["settings"].get("decryption") != state["vlessEncDecryption"]:
                raise RuntimeError("VLESS encryption was lost during generation")
        for inbound in runtime["inbounds"]:
            if "fallbacks" in inbound.get("settings", {}) and inbound["settings"].get("decryption") != "none":
                raise RuntimeError("Fallback inbound must keep decryption=none")
    if state.get("mldsa65Enable") == "y":
        for inbound in runtime["inbounds"]:
            stream = inbound.get("streamSettings", {})
            if stream.get("security") == "reality":
                if stream["realitySettings"].get("mldsa65Seed") != state["mldsa65Seed"]:
                    raise RuntimeError("ML-DSA-65 seed was lost during generation")
    if state.get("reverse") == 1:
        if not any(inbound.get("tag") == "reverse-portal" for inbound in runtime["inbounds"]):
            raise RuntimeError("Reverse portal was lost during generation")
    relay = state.get("relay", {})
    if "mode" in relay:
        rules = runtime["routing"]["rules"]
        relay_rules = [rule for rule in rules if rule.get("ruleTag") == "xray-script-relay"]
        relay_outbounds = [outbound for outbound in runtime["outbounds"]
                           if outbound.get("tag", "").startswith("xray-script-relay-")]
        if runtime["outbounds"][0]["tag"] != "direct":
            raise RuntimeError("Relay changed the default direct outbound")
        if relay["mode"] == "off":
            if relay_rules or relay_outbounds:
                raise RuntimeError("Disabled relay still generated routing or outbounds")
            return
        if len(relay_rules) != 1 or len(relay_outbounds) != 1:
            raise RuntimeError("Relay rule/outbound is missing or duplicated")
        rule = relay_rules[0]
        business = [inbound for inbound in runtime["inbounds"]
                    if inbound.get("protocol") in {"vless", "trojan", "vmess", "shadowsocks", "hysteria", "hysteria2", "socks", "http"}
                    and not inbound.get("tag", "").startswith(("lan-", "reverse-"))]
        if set(rule["inboundTag"]) != {inbound["tag"] for inbound in business}:
            raise RuntimeError("Relay does not match all and only business inbound tags")
        if relay["mode"] == "domains":
            if rule.get("domain") != relay["domains"]:
                raise RuntimeError("Relay domain list was changed during generation")
            if any(not inbound.get("sniffing", {}).get("routeOnly") for inbound in business):
                raise RuntimeError("Domain relay sniffing does not preserve the original target")
        elif "domain" in rule:
            raise RuntimeError("All-traffic relay unexpectedly limits domains")
        index = rules.index(rule)
        for other in rules:
            tag = other.get("ruleTag", "")
            if (other.get("outboundTag") == "block" or tag == "api"
                    or tag.startswith(("anti-steal-", "reverse-", "lan-"))):
                if rules.index(other) >= index:
                    raise RuntimeError("Relay takes precedence over a special/blocking rule")
            elif other.get("outboundTag") == "warp" and rules.index(other) <= index:
                raise RuntimeError("WARP takes precedence over relay")
        if bool(state.get("warp")) != any(outbound.get("tag") == "warp" for outbound in runtime["outbounds"]):
            raise RuntimeError("WARP outbound does not match its enabled state")


def smoke_start(binary, runtime, work, env):
    """Start actual protocol listeners without requiring root or fixed ports."""
    runtime = copy.deepcopy(runtime)
    runtime["log"] = {"access": "none", "error": "none", "loglevel": "warning"}
    reservations = []
    expected = []
    try:
        for index, inbound in enumerate(runtime["inbounds"]):
            listen = inbound.get("listen", "0.0.0.0")
            if listen.startswith(("/", "@")):
                path = str(work / f"listener-{index}.sock")
                inbound["listen"] = path
                expected.append(("unix", path))
                continue
            # Reserve the same ephemeral port for both transports. This also
            # supports SS2022, which can listen on TCP and UDP simultaneously.
            for attempt in range(20):
                tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                tcp.bind(("127.0.0.1", 0))
                port = tcp.getsockname()[1]
                udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                try:
                    udp.bind(("127.0.0.1", port))
                except OSError:
                    tcp.close()
                    udp.close()
                    continue
                reservations.extend([tcp, udp])
                break
            else:
                raise RuntimeError("Could not reserve a temporary listener port")
            inbound.update(listen="127.0.0.1", port=port)
            network = inbound.get("streamSettings", {}).get("network", "tcp")
            if network in {"hysteria", "kcp"}:
                expected.append(("udp", port))
            elif inbound.get("protocol") == "shadowsocks":
                expected.extend([("tcp", port), ("udp", port)])
            else:
                expected.append(("tcp", port))
        config = work / "smoke.json"
        config.write_text(json.dumps(runtime))
    finally:
        for reservation in reservations:
            reservation.close()

    def listening(kind, address):
        if kind == "unix":
            return Path(address).exists()
        sock_type = socket.SOCK_STREAM if kind == "tcp" else socket.SOCK_DGRAM
        with socket.socket(socket.AF_INET, sock_type) as probe:
            if kind == "tcp":
                probe.settimeout(0.1)
                return probe.connect_ex(("127.0.0.1", address)) == 0
            try:
                probe.bind(("127.0.0.1", address))
            except OSError as error:
                return error.errno == errno.EADDRINUSE
            return False

    with subprocess.Popen(
        [str(binary), "run", "-c", str(config)], env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    ) as process:
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    output = process.communicate()[0]
                    raise RuntimeError(f"Xray exited during startup: {output}")
                if all(listening(kind, address) for kind, address in expected):
                    # Detect failures that occur immediately after binding.
                    time.sleep(0.15)
                    if process.poll() is None:
                        return
                time.sleep(0.05)
            missing = [f"{kind}:{address}" for kind, address in expected if not listening(kind, address)]
            raise RuntimeError("Listeners did not start: " + ", ".join(missing))
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xray", required=True, type=Path)
    parser.add_argument("--smoke", action="store_true", help="also start temporary foreground listeners")
    args = parser.parse_args()
    binary = args.xray.resolve(strict=True)
    key_output = subprocess.check_output([str(binary), "x25519"], text=True)
    private_key = key_value(key_output, r"Private\s*Key")
    signature_output = subprocess.check_output([str(binary), "mldsa65"], text=True, timeout=15)
    encryption_output = subprocess.run(
        [str(binary), "vlessenc"], input="2\n", capture_output=True,
        text=True, check=True, timeout=15,
    ).stdout
    decryption = re.findall(r'"decryption":\s*"([^\"]+)"', encryption_output)
    encryption = re.findall(r'"encryption":\s*"([^\"]+)"', encryption_output)
    if not decryption or not encryption:
        raise RuntimeError("Xray did not return VLESS encryption keys")
    pq = dict(
        vlessEncEnable="y", vlessEncDecryption=decryption[-1],
        vlessEncEncryption=encryption[-1], mldsa65Enable="y",
        mldsa65Seed=key_value(signature_output, "Seed"),
        mldsa65Verify=key_value(signature_output, "Verify"),
    )

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
        configurations = configuration_matrix(base, pq)
        failures = []
        for name, config in configurations:
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
obtain_warp_endpoint() { printf '%s\\n' '127.0.0.1'; }
get_hy2_cert_dir() { printf '%s' "${XRAY_AUDIT_CERTS}"; }
get_cdn_direct_cert_dir() { printf '%s' "${XRAY_AUDIT_CERTS}"; }
load_i18n
handler_xray_config
"""
            result = subprocess.run(
                ["bash", "-c", body], env=env, cwd=ROOT,
                capture_output=True, text=True, timeout=60,
            )
            if result.returncode:
                failures.append(name)
                print(f"FAIL {name}\n{result.stderr}")
            else:
                try:
                    runtime = json.loads(runtime_path.read_text())
                    check_optional_features(config, runtime)
                    if args.smoke:
                        smoke_start(binary, runtime, work, env)
                except (OSError, RuntimeError, ValueError) as error:
                    failures.append(name)
                    print(f"FAIL {name}\n{error}", flush=True)
                else:
                    print(f"PASS {name}" + (" (started)" if args.smoke else ""), flush=True)
        if failures:
            raise SystemExit("Failed configurations: " + ", ".join(failures))
        print(f"Validated {len(configurations)} generated configurations" +
              (" and started all listeners" if args.smoke else ""))


if __name__ == "__main__":
    main()
