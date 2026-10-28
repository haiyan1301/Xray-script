"""Exercise generated client links without network access or host mutations."""

import copy
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[1]


class CoreShareAuditTests(unittest.TestCase):
    def sni_links(self, *, mode="packet-up", verify="post-quantum-verify"):
        config = json.loads((ROOT / "config.json").read_text())
        config["xray"].update(
            tag="SNI", port=443, path="/split-path/", publicKey="reality-public-key",
            mldsa65Verify=verify,
        )
        config["nginx"].update(domain="origin.example.com", cdn="cdn.example.com")
        runtime = json.loads((ROOT / "config/xray/SNI.json").read_text())
        for inbound in runtime["inbounds"][1:]:
            inbound["settings"]["clients"][0]["id"] = "d2b823b9-5983-41b1-9297-1beb939a5954"
        runtime["inbounds"][1]["streamSettings"]["realitySettings"].update(
            serverNames=["origin.example.com"], shortIds=["0123456789abcdef"],
        )
        runtime["inbounds"][2]["streamSettings"]["xhttpSettings"].update(
            path="/split-path/", mode=mode,
        )
        with tempfile.TemporaryDirectory(prefix="xray-share-audit-") as directory:
            work = Path(directory)
            (work / "script.json").write_text(json.dumps(config))
            (work / "runtime.json").write_text(json.dumps(runtime))
            result = subprocess.run(
                ["bash", "-c", f"source {shlex.quote(str(ROOT / 'core/share.sh'))}\n" + """
cache_json_data || exit 1
show_config() {
    jq -cn --arg tag "${CLIENT_CONFIG[tag]}" --arg link "${SHARE_LINK}" '{tag:$tag,link:$link}'
}
get_common_config 1 origin.example.com || exit 1
show_sni_config
"""],
                env=os.environ | {
                    "SCRIPT_CONFIG_PATH_OVERRIDE": str(work / "script.json"),
                    "XRAY_CONFIG_PATH_OVERRIDE": str(work / "runtime.json"),
                },
                cwd=ROOT, capture_output=True, text=True, timeout=20,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return {row["tag"]: urlsplit(row["link"]) for row in map(json.loads, result.stdout.splitlines())}, runtime

    def test_sni_reality_download_uses_cdn_tls_uplink(self):
        links, _ = self.sni_links()
        self.assertEqual(len(links), 5)
        link = links["sni_reality_down"]
        query = parse_qs(link.query)
        self.assertEqual(link.hostname, "cdn.example.com")
        self.assertEqual(query["security"], ["tls"])
        self.assertEqual(query["sni"], ["cdn.example.com"])
        download = json.loads(query["extra"][0])["downloadSettings"]
        self.assertEqual(download["security"], "reality")
        self.assertEqual(download["address"], "origin.example.com")
        self.assertEqual(download["realitySettings"]["publicKey"], "reality-public-key")
        self.assertEqual(download["realitySettings"]["mldsa65Verify"], "post-quantum-verify")

    def test_sni_split_transports_preserve_mode_and_obfuscation(self):
        for mode in ["packet-up", "stream-up", "auto"]:
            with self.subTest(mode=mode):
                links, runtime = self.sni_links(mode=mode)
                expected = copy.deepcopy(runtime["inbounds"][2]["streamSettings"]["xhttpSettings"])
                for key in ["host", "path", "mode"]:
                    expected.pop(key)
                for tag in ["sni_tls_down", "sni_reality_down"]:
                    query = parse_qs(links[tag].query)
                    extra = json.loads(query["extra"][0])
                    download = extra.pop("downloadSettings")
                    self.assertEqual(extra, expected)
                    self.assertEqual(download["xhttpSettings"]["extra"], expected)
                    self.assertEqual(download["xhttpSettings"]["mode"], mode)
                # A plain CDN link must not retain the preceding split link.
                plain = parse_qs(links["sni_xhttp_cdn"].query)
                self.assertNotIn("downloadSettings", json.loads(plain["extra"][0]))


class CoreGeneratorAuditTests(unittest.TestCase):
    def generate(self, body):
        return subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(ROOT / 'core/generate.sh'))}\n" + body],
            cwd=ROOT, capture_output=True, text=True, timeout=10,
        )

    def test_uuid_command_failure_never_becomes_a_credential(self):
        for output in ["command failed", "d2b823b9-5983-41b1-9297-1beb939a5954"]:
            with self.subTest(output=output):
                result = self.generate(f"xray() {{ printf '%s' {shlex.quote(output)}; return 23; }}\ngenerate_uuid custom-id")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_uuid_rejects_successful_but_invalid_output(self):
        result = self.generate("xray() { printf 'unexpected output'; }; generate_uuid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_short_id_entropy_failure_is_propagated(self):
        for command in ["generate_short_id 8", "generate_short_ids 8 8"]:
            with self.subTest(command=command):
                result = self.generate("openssl() { return 23; }\n" + command)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_random_source_failure_is_propagated(self):
        for command in ["generate_random", "generate_port"]:
            with self.subTest(command=command):
                result = self.generate("od() { return 23; }\n" + command)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_secret_generators_propagate_entropy_failure(self):
        for command in ["generate_password", "generate_hy2_auth", "generate_path"]:
            with self.subTest(command=command):
                result = self.generate("openssl() { return 23; }\n" + command)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_secret_generators_work_with_pipefail(self):
        for command in ["generate_password", "generate_hy2_auth", "generate_path"]:
            with self.subTest(command=command):
                result = self.generate("set -o pipefail\ngenerate_random() { printf 32; }\n" + command)
                self.assertEqual(result.returncode, 0, result.stderr)
                value = result.stdout.strip()
                if command == "generate_path":
                    self.assertTrue(value.startswith("/") and value.endswith("/"))
                    value = value[1:-1]
                self.assertEqual(len(value), 32)
                self.assertRegex(value, "^[A-Za-z0-9!@]+$" if command == "generate_password" else "^[A-Za-z0-9]+$")


if __name__ == "__main__":
    unittest.main()
