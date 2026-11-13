"""Exercise ssl.sh's real CLI dispatch with an isolated ACME executable."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SSLRecordValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-ssl-record-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.repo = self.work / "repo"
        # Normalizing CRLF also lets these integration tests run on a Windows
        # checkout through WSL, without rewriting any checked-in dependency.
        for relative in [
            "service/ssl.sh", "lib/i18n.sh", "lib/log.sh", "lib/system.sh",
            "lib/cert.sh", "lib/transaction.sh", "i18n/zh.json",
        ]:
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text((ROOT / relative).read_text(encoding="utf-8"), encoding="utf-8")
        self.home = self.work / "home"
        self.acme = self.home / ".acme.sh"
        self.acme.mkdir(parents=True)
        self.log = self.work / "calls.jsonl"
        self.list_file = self.work / "records.txt"
        executable = self.acme / "acme.sh"
        executable.write_text("""#!/usr/bin/python3
import json, os, pathlib, sys
with open(os.environ['MOCK_CALLS'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if '--list' in sys.argv:
    print(pathlib.Path(os.environ['MOCK_RECORDS']).read_text(), end='')
    sys.exit(int(os.environ.get('MOCK_LIST_STATUS', '0')))
sys.exit(int(os.environ.get('MOCK_ACTION_STATUS', '0')))
""", encoding="utf-8")
        executable.chmod(0o755)
        self.env = os.environ | {
            "HOME": str(self.home), "MOCK_CALLS": str(self.log),
            "MOCK_RECORDS": str(self.list_file),
            "NGINX_CONFIG_PATH_OVERRIDE": str(self.work / "nginx"),
        }

    def records(self, *rows):
        self.list_file.write_text(
            "Main_Domain KeyLength SAN_Domains CA Created Renew\n"
            + "".join(row + "\n" for row in rows), encoding="utf-8",
        )

    def run_cli(self, action, domain, *extra, env=None):
        return subprocess.run(
            ["bash", str(self.repo / "service/ssl.sh"), action, f"--domain={domain}", *extra],
            capture_output=True, text=True, timeout=15, env=self.env | (env or {}),
        )

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def clear_calls(self):
        self.log.write_text("")

    def test_record_actions_accept_wildcard_ipv4_ipv6_and_dns_primary(self):
        for primary in ["*.example.com", "192.0.2.11", "2001:db8::1", "::ffff:192.0.2.11", "example.com"]:
            for action in ["--status", "--info", "--stop-renew"]:
                with self.subTest(primary=primary, action=action):
                    self.clear_calls()
                    self.records(f"{primary} ec-256 no CA now later")
                    record_dir = self.acme / f"{primary}_ecc"
                    record_dir.mkdir(exist_ok=True)
                    (record_dir / "keep.txt").write_text("record")
                    deployed = self.work / "nginx" / "certs" / primary
                    deployed.mkdir(parents=True, exist_ok=True)
                    (deployed / "fullchain.pem").write_text("deployed")
                    result = self.run_cli(action, primary)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    if action == "--status":
                        self.assertEqual(result.stdout.strip(), primary)
                    else:
                        operation = "--remove" if action == "--stop-renew" else "--info"
                        self.assertIn([operation, "-d", primary, "--ecc"], self.calls())
                    self.assertEqual(record_dir.exists(), action != "--stop-renew")
                    self.assertEqual((deployed / "fullchain.pem").read_text(), "deployed")

    def test_dns_only_issue_rejects_wildcard_and_ip_before_acme(self):
        for identifier in ["*.example.com", "192.0.2.11", "2001:db8::1"]:
            with self.subTest(identifier=identifier):
                self.clear_calls()
                result = self.run_cli("--issue", identifier)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
                self.assertFalse((self.work / "nginx").exists())

    def test_invalid_identifier_is_rejected_before_record_lookup(self):
        for identifier in [
            "../outside", "*.example.com/../../outside", "*.*.example.com",
            "a;touch /tmp/unsafe", "$(id).example.com", "a.example.com\nother",
            "256.0.0.1", "12345::", "1::2::3", "[2001:db8::1]", "fe80::1%eth0",
            "1:2:3:4:5:6:7:8:9", "1::2:3:4:5:6:7:8", "::ffff:256.0.0.1",
        ]:
            with self.subTest(identifier=identifier):
                self.clear_calls()
                result = self.run_cli("--stop-renew", identifier)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_untrusted_listed_primary_cannot_escape_record_directory(self):
        outside = self.home / "outside_ecc"
        outside.mkdir()
        (outside / "keep.txt").write_text("keep")
        self.records("../outside ec-256 api.example.com CA now later")
        result = self.run_cli("--stop-renew", "api.example.com")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((outside / "keep.txt").exists())
        self.assertFalse(any("--remove" in call for call in self.calls()))

    def test_failed_list_never_uses_partial_output_to_remove_record(self):
        self.records("example.com ec-256 no CA now later")
        result = self.run_cli("--stop-renew", "example.com", env={"MOCK_LIST_STATUS": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("--remove" in call for call in self.calls()))

    def test_exact_primary_wins_over_an_earlier_san(self):
        self.records(
            "other.example.com ec-256 target.example.com CA now later",
            "target.example.com ec-256 no CA now later",
        )
        result = self.run_cli("--stop-renew", "target.example.com")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["--remove", "-d", "target.example.com", "--ecc"], self.calls())

    def test_ambiguous_san_and_missing_records_do_not_remove_anything(self):
        self.records(
            "one.example.com ec-256 target.example.com CA now later",
            "two.example.com ec-256 target.example.com CA now later",
        )
        for identifier in ["target.example.com", "missing.example.com"]:
            with self.subTest(identifier=identifier):
                self.clear_calls()
                result = self.run_cli("--stop-renew", identifier)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any("--remove" in call for call in self.calls()))

    def test_failed_remove_retains_local_record_and_deployed_files(self):
        primary = "*.example.com"
        self.records(f"{primary} ec-256 no CA now later")
        record_dir = self.acme / f"{primary}_ecc"
        record_dir.mkdir()
        (record_dir / "keep.txt").write_text("keep")
        deployed = self.work / "nginx" / "certs" / primary
        deployed.mkdir(parents=True)
        (deployed / "fullchain.pem").write_text("keep")
        result = self.run_cli("--stop-renew", primary, "--delete-cert", env={"MOCK_ACTION_STATUS": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((record_dir / "keep.txt").exists())
        self.assertTrue((deployed / "fullchain.pem").exists())


if __name__ == "__main__":
    unittest.main()
