"""Failure paths for persistent configuration and firewall ownership."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

from test_regressions import ROOT, definitions


class BootstrapFirewallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-bootstrap-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.config = self.work / "config.json"
        self.config.write_text('{"original":true}\n')
        self.before = self.config.read_bytes()
        self.env = os.environ | {"AUDIT_CONFIG": str(self.config)}

    def bash(self, body, expected=0):
        result = subprocess.run(
            ["bash", "-c", body], cwd=ROOT, env=self.env,
            capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def writer(self, standalone=False):
        launcher = ROOT / "install.sh"
        if standalone:
            launcher = self.work / "install.sh"
            shutil.copyfile(ROOT / "install.sh", launcher)
        return f"source {shlex.quote(str(launcher))}\nsync() {{ :; }}\n"

    def test_config_writer_rejects_nonobject_or_multiple_documents(self):
        for standalone in (False, True):
            for content in ("null", "[]", '"text"', "{} {}", "", "{broken"):
                with self.subTest(standalone=standalone, content=content):
                    self.bash(self.writer(standalone) +
                              f'write_config {shlex.quote(content)} "$AUDIT_CONFIG"', 1)
                    self.assertEqual(self.config.read_bytes(), self.before)

    def test_config_permission_failure_preserves_original_and_cleans_temp(self):
        for standalone in (False, True):
            with self.subTest(standalone=standalone):
                self.bash(self.writer(standalone) + """
chmod() { return 1; }
write_config '{"new":true}' "$AUDIT_CONFIG"
""", 1)
                self.assertEqual(self.config.read_bytes(), self.before)
                self.assertFalse(list(self.work.glob("config.json.tmp.*")))

    def download(self, payload, status=0):
        return definitions("install.sh", "download_default_script_config") + f"""
SCRIPT_CONFIG_PATH="$AUDIT_CONFIG"
SCRIPT_REPO_OWNER=test
SCRIPT_REPO_NAME=test
backup_config() {{ cp "$1" "$1.bak"; }}
curl() {{
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -o ]]; then
            printf '%s\\n' {shlex.quote(payload)} >"$2"
            return {status}
        fi
        shift
    done
    return 1
}}
download_default_script_config
"""

    def test_failed_and_invalid_defaults_preserve_previous_state(self):
        for payload, status in (("{}", 18), ("null", 0), ("{} {}", 0), ("{}", 0)):
            with self.subTest(payload=payload, status=status):
                self.bash(self.download(payload, status), 1)
                self.assertEqual(self.config.read_bytes(), self.before)
                self.assertFalse(list(self.work.glob("config.json.download.*")))

    def test_valid_defaults_keep_backup_and_restrict_permissions(self):
        data = {"xray": {}, "nginx": {}}
        self.bash(self.download(json.dumps(data)))
        self.assertEqual(json.loads(self.config.read_text()), data)
        self.assertEqual(self.config.with_suffix(".json.bak").read_bytes(), self.before)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def firewall(self):
        return f'source {shlex.quote(str(ROOT / "lib/firewall.sh"))}\n'

    def test_backend_query_errors_are_not_missing_rules(self):
        for backend, mock, ipv4, ipv6 in (
            ("ufw", "ufw() { return 2; }", False, False),
            ("firewalld", '''firewall-cmd() {
                [[ "$1" != --state ]] || { echo running; return 0; }
                return 102;
            }''', False, False),
            ("iptables", "iptables() { return 4; }", True, False),
            ("iptables", "ip6tables() { return 4; }", False, True),
        ):
            with self.subTest(backend=backend, ipv6=ipv6):
                self.bash(self.firewall() + mock +
                          f'\nfirewall_rule_remove_fields {backend} 443 tcp '
                          f'{str(ipv4).lower()} {str(ipv6).lower()}', 1)

    def test_missing_rules_can_be_removed_idempotently(self):
        self.bash(self.firewall() + """
ufw() { return 0; }
firewall_rule_remove_fields ufw 443 tcp false false || exit 1
iptables() { [[ "$1" == -S ]]; }
firewall_rule_remove_fields iptables 443 tcp true false || exit 1
firewall-cmd() {
    [[ "$1" != --state ]] || { echo running; return 0; }
    return 1
}
firewall_rule_remove_fields firewalld 443 tcp false false
""")

    def test_unknown_firewalld_state_keeps_owned_ledger(self):
        self.bash(self.firewall() + """
SCRIPT_CONFIG='{"xray":{"firewallRules":[{"feature":"xray","backend":"firewalld","port":443,"protocol":"tcp","ipv4":false,"ipv6":false}]}}'
original="$SCRIPT_CONFIG"
firewall-cmd() {
    [[ "$1" != --state ]] || { echo running; return 0; }
    return 102
}
write_config() { echo 'unexpected state commit' >&2; exit 8; }
if firewall_owned_close xray; then exit 9; fi
[[ "$SCRIPT_CONFIG" == "$original" ]]
""")


if __name__ == "__main__":
    unittest.main()
