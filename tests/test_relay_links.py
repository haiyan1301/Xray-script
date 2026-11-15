"""Share URI import tests, including the repository's actual link builders."""

import base64
import copy
import importlib.util
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("relay_links", ROOT / "lib/relay-links.py")
LINKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LINKS)
UUID = "11111111-1111-4111-8111-111111111111"
KEY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
REALITY = "security=reality&sni=example.com&pbk=" + KEY + "&sid=0123&spx=%2F&fp=chrome"
PASSWORD = base64.b64encode(bytes(range(32))).decode()


def uri(scheme="vless", network="raw", **params):
    credential = UUID if scheme == "vless" else "pa%40ss%3Aword"
    return f"{scheme}://{credential}@[2001:db8::2]:443?type={network}&{REALITY}" + (
        "&" + urllib.parse.urlencode(params) if params else "")


class RelayLinksTests(unittest.TestCase):
    def parse(self, link):
        return LINKS.parse_link(link)

    def reject(self, link):
        with self.assertRaises((ValueError, TypeError, KeyError)):
            self.parse(link)

    def test_vision_ipv6_and_unicode_remark(self):
        node = self.parse(uri(flow="xtls-rprx-vision") + "#" + urllib.parse.quote("香港 B"))
        self.assertEqual(node["name"], "香港 B")
        self.assertEqual(node["address"], "2001:db8::2")
        self.assertEqual(node["outbound"]["settings"]["vnext"][0]["users"][0]["flow"], "xtls-rprx-vision")
        self.assertEqual(LINKS.validate_node(node), node)

    def test_tcp_alias_and_hostname_normalization(self):
        node = self.parse(uri(network="tcp").replace("[2001:db8::2]", "RELAY.Example.COM"))
        self.assertEqual(node["address"], "relay.example.com")
        self.assertEqual(node["outbound"]["streamSettings"]["network"], "raw")

    def test_xhttp_reserved_path_and_obfuscation(self):
        extra = {"xPaddingObfsMode": True, "xPaddingKey": "requestId", "seqKey": "X-Seq"}
        node = self.parse(uri(network="xhttp", path="/p?one=1&two=2", mode="packet-up", extra=json.dumps(extra)))
        xs = node["outbound"]["streamSettings"]["xhttpSettings"]
        self.assertEqual(xs["path"], "/p?one=1&two=2")
        self.assertEqual(xs["extra"], extra)

    def test_trojan_password_keeps_reserved_characters(self):
        node = self.parse(uri("trojan", "xhttp", path="/trojan/"))
        self.assertEqual(node["outbound"]["settings"]["servers"][0]["password"], "pa@ss:word")

    def test_mkcp_seed_uses_finalmask_compatible_with_template(self):
        node = self.parse(f"vless://{UUID}@192.0.2.3:9527?type=kcp&security=none&seed=a%26b%2Bc&headerType=none")
        stream = node["outbound"]["streamSettings"]
        self.assertEqual(stream["finalmask"]["udp"][0]["settings"]["value"], "a&b+c")

    def test_hy2_auth_and_verified_tls(self):
        for scheme in ["hy2", "hysteria2"]:
            node = self.parse(f"{scheme}://u%3Ap%40ss@relay.example.com:443/?insecure=0&sni=cert.example.com")
            self.assertEqual(node["protocol"], "hysteria")
            self.assertEqual(node["outbound"]["settings"], {"version": 2, "address": "relay.example.com", "port": 443})
            self.assertEqual(node["outbound"]["streamSettings"]["hysteriaSettings"]["auth"], "u:p@ss")

    def test_ss_sip002_and_plain_userinfo(self):
        credential = "2022-blake3-aes-256-gcm:" + PASSWORD
        encoded = base64.urlsafe_b64encode(credential.encode()).decode().rstrip("=")
        for userinfo in [encoded, urllib.parse.quote(credential, safe=":")]:
            node = self.parse(f"ss://{userinfo}@192.0.2.3:443#ss")
            self.assertEqual(node["outbound"]["settings"]["servers"][0]["password"], PASSWORD)

    def test_legacy_whole_ss_base64_preserves_ipv6_endpoint(self):
        raw = f"2022-blake3-aes-256-gcm:{PASSWORD}@[2001:db8::7]:1443"
        for encode in [base64.b64encode, base64.urlsafe_b64encode]:
            encoded = encode(raw.encode()).decode().rstrip("=")
            node = self.parse("ss://" + encoded + "#legacy")
            self.assertEqual(node["address"], "2001:db8::7")
            self.assertEqual(node["port"], 1443)
            self.assertEqual(node["name"], "legacy")

    def test_duplicate_nested_json_keys_are_rejected(self):
        self.reject(uri(network="xhttp", extra='{"xPaddingKey":"first","xPaddingKey":"second"}'))

    def test_rejects_unsupported_combos_and_ambiguous_query(self):
        for link in [uri(network="ws"), uri(network="grpc"), uri().replace("security=reality", "security=tls"),
                     uri("trojan", "raw"), uri() + "&security=none", uri() + "&allowInsecure=1",
                     uri(network="xhttp", extra=json.dumps({"downloadSettings": {"address": "elsewhere"}})),
                     "hy2://secret@192.0.2.1:443?insecure=1", "ss://YWVzLTEyOC1nY206cGFzcw@192.0.2.1:443",
                     uri(flow="xtls-rprx-vision", network="xhttp")]:
            with self.subTest(link_type=link.split(":", 1)[0]):
                self.reject(link)

    def test_rejects_malformed_ports_addresses_and_percent_encoding(self):
        for link in [uri().replace(":443?", ":0?"), uri().replace(":443?", ":65536?"),
                     uri().replace("[2001:db8::2]", "999.1.1.1"), uri().replace("[2001:db8::2]", "a..example.com"),
                     uri() + "#%00bad", uri() + "#%ZZ", uri() + "#line%0Ainjection"]:
            self.reject(link)

    def test_saved_nodes_cannot_inject_chains_or_change_endpoint(self):
        good = self.parse(uri(network="xhttp", path="/ok/"))
        mutations = [
            lambda n: n["outbound"].update(proxySettings={"tag": "direct"}),
            lambda n: n["outbound"]["streamSettings"].update(sockopt={"dialerProxy": "direct"}),
            lambda n: n["outbound"].update(tag="direct"),
            lambda n: n.update(address="192.0.2.9"),
            lambda n: n["outbound"]["settings"]["vnext"][0].update(port=8443),
            lambda n: n["outbound"]["streamSettings"]["xhttpSettings"].update(extra={"downloadSettings": {}}),
        ]
        for mutate in mutations:
            node = copy.deepcopy(good)
            mutate(node)
            with self.assertRaises(ValueError):
                LINKS.validate_node(node)

    def test_cli_errors_do_not_echo_credentials(self):
        result = subprocess.run(["python3", str(ROOT / "lib/relay-links.py")],
                                input="hy2://VerySecretPassword@192.0.2.1:443?insecure=1\n",
                                capture_output=True, text=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("VerySecretPassword", result.stderr)

    def generated_link(self, kind, encryption_value="", mldsa=""):
        template = {"vision": "Vision", "xhttp": "XHTTP", "trojan": "Trojan",
                    "mkcp": "mKCP", "hy2": "hy2", "ss2022": "ss2022"}[kind]
        values = dict(remote_host="2001:db8::20", port="24443", protocol="vless", type="raw", uuid=UUID,
                      password="p@ss:&+word", seed="kcp+seed&value", security="reality", server_name="example.com",
                      public_key=KEY, short_id="0123", flow="xtls-rprx-vision", path="/link?one=1&two=2",
                      mode="packet-up", host="", hy2_auth="auth:@&+", hy2_cert_domain="cert.example.com",
                      ss2022_method="2022-blake3-aes-256-gcm", ss2022_password=PASSWORD, tag=kind,
                      vless_enc_encryption=encryption_value, mldsa65_verify=mldsa)
        if kind in {"xhttp", "trojan"}:
            values.update(type="xhttp", flow="")
        if kind == "trojan":
            values.update(protocol="trojan")
        if kind == "mkcp":
            values.update(type="kcp", security="none", flow="")
        assignments = "\n".join(f"CLIENT_CONFIG[{key}]={shlex.quote(value)}" for key, value in values.items())
        body = f"source {shlex.quote(str(ROOT / 'core/share.sh'))}\n{assignments}\n"
        body += f"XRAY_CONFIG=\"$(cat {shlex.quote(str(ROOT / ('config/xray/' + template + '.json')))})\"\n"
        if kind == "xhttp":
            body += "setup_xhttp_obfs_extra 1 || exit\n"
        body += f"get_{kind}_share_link || exit\nprintf '%s' \"$SHARE_LINK\"\n"
        result = subprocess.run(["bash", "-c", body], capture_output=True, text=True, cwd=ROOT, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_all_standalone_link_builders_roundtrip(self):
        for kind in ["vision", "xhttp", "trojan", "mkcp", "hy2", "ss2022"]:
            with self.subTest(kind=kind):
                node = self.parse(self.generated_link(kind))
                self.assertEqual(node["address"], "2001:db8::20")
                self.assertEqual(node["port"], 24443)

    def test_post_quantum_builder_fields_reach_outbound(self):
        encryption_value = "mlkem768x25519plus.native.0rtt." + KEY
        verify = base64.urlsafe_b64encode(b"public-verify-material").decode().rstrip("=")
        for kind in ["vision", "xhttp", "mkcp"]:
            with self.subTest(kind=kind):
                node = self.parse(self.generated_link(kind, encryption_value, verify))
                user = node["outbound"]["settings"]["vnext"][0]["users"][0]
                self.assertEqual(user["encryption"], encryption_value)
                if kind != "mkcp":
                    self.assertEqual(node["outbound"]["streamSettings"]["realitySettings"]["mldsa65Verify"], verify)

    def test_actual_core_accepts_generated_post_quantum_link(self):
        binary = os.environ.get("XRAY_TEST_BIN") or shutil.which("xray")
        if not binary:
            self.skipTest("Set XRAY_TEST_BIN to verify with an actual Xray binary")
        enc = subprocess.run([str(binary), "vlessenc"], input="2\n", capture_output=True, text=True, timeout=10)
        verify = subprocess.run([str(binary), "mldsa65"], capture_output=True, text=True, timeout=10)
        encryption_value = re.findall(r'"encryption":\s*"([^"\n]+)"', enc.stdout)[-1]
        verify_value = re.search(r"(?m)^Verify:\s*(\S+)", verify.stdout).group(1)
        with tempfile.TemporaryDirectory(prefix="relay-postquantum-") as directory:
            path = Path(directory) / "config.json"
            for kind in ["vision", "xhttp", "mkcp"]:
                with self.subTest(kind=kind):
                    outbound = self.parse(self.generated_link(kind, encryption_value, verify_value))["outbound"]
                    path.write_text(json.dumps({"log": {"access": "none", "error": "none"}, "outbounds": [outbound]}))
                    result = subprocess.run([str(binary), "run", "-test", "-c", str(path)],
                                            capture_output=True, text=True, timeout=10)
                    # Do not put configuration or generated key material in test diagnostics.
                    self.assertEqual(result.returncode, 0, "Core rejected " + kind + " post-quantum outbound")

    def test_actual_core_accepts_all_supported_imports(self):
        binary = os.environ.get("XRAY_TEST_BIN") or shutil.which("xray")
        if not binary:
            self.skipTest("Set XRAY_TEST_BIN to verify with an actual Xray binary")
        with tempfile.TemporaryDirectory(prefix="relay-links-core-") as directory:
            path = Path(directory) / "config.json"
            for kind in ["vision", "xhttp", "trojan", "mkcp", "hy2", "ss2022"]:
                with self.subTest(kind=kind):
                    link = self.generated_link(kind)
                    if kind == "mkcp":
                        # Current Xray forbids unencrypted VLESS over a public IP.
                        link = link.replace("[2001:db8::20]", "10.23.0.2")
                    outbound = self.parse(link)["outbound"]
                    path.write_text(json.dumps({"log": {"access": "none", "error": "none"}, "outbounds": [outbound]}))
                    result = subprocess.run([str(binary), "run", "-test", "-c", str(path)],
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
