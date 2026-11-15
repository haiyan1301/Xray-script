"""Migrate exact pre-routeOnly runtimes without accepting manual JSON edits."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

from test_service_audit import ROOT


class RelaySniffingMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-relay-sniffing-migration-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.state_path = self.work / "script.json"
        self.runtime_path = self.work / "runtime.json"
        self.events_path = self.work / "events"
        self.state = json.loads((ROOT / "config.json").read_text())
        self.state["language"] = "en"
        self.state["xray"].update(
            tag="XHTTP", port=14443,
            uuid="11111111-1111-4111-8111-111111111111",
            privateKey="A" * 43, publicKey="B" * 43,
            target="example.com", serverNames=["example.com"], shortIds=["01"],
            path="/migration/", xhttpMode="auto", vlessEncEnable="n", mldsa65Enable="n",
        )
        self.state["xray"]["rules"].update(reset=0, resetBy="")
        self.state["xray"]["relay"] = {
            "nodes": [{"id": "relay-a", "name": "Relay A", "protocol": "socks",
                       "address": "203.0.113.20", "port": 1080,
                       "username": "", "password": ""}],
            "active": None, "mode": "off", "domains": [],
        }
        self.write_state()

    def write_state(self):
        self.state_path.write_text(json.dumps(self.state))

    def bash(self, body):
        return subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n" + r'''
sync() { :; }
set_xray_config_permissions() { chmod 600 "$1"; }
prepare_xray_managed_logs() { :; }
firewall_owned_open() { :; }
handler_lan_open_firewall() { :; }
validate_xray_runtime_config() { printf 'validate\n' >>"$TEST_EVENTS"; }
handler_restart() { printf 'restart\n' >>"$TEST_EVENTS"; }
exec_docker() { printf 'docker\n' >>"$TEST_EVENTS"; return 99; }
load_i18n
''' + body],
            env=os.environ | {
                "SCRIPT_CONFIG_PATH_OVERRIDE": str(self.state_path),
                "XRAY_CONFIG_PATH_OVERRIDE": str(self.runtime_path),
                "TEST_EVENTS": str(self.events_path),
                "TEST_WORK": str(self.work),
            }, cwd=ROOT, text=True, capture_output=True, timeout=30,
        )

    def install_expected_runtime(self, *, legacy=True):
        original_state = self.state_path.read_bytes()
        flag = "1" if legacy else "0"
        result = self.bash('runtime_guard_expected_runtime "$SCRIPT_CONFIG" ' + flag)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        runtime = json.loads(result.stdout)
        self.assertEqual(self.state_path.read_bytes(), original_state)
        self.assertFalse(self.runtime_path.exists())
        self.assertFalse(self.events_path.exists())
        self.runtime_path.write_text(json.dumps(runtime))
        return runtime

    @staticmethod
    def business(runtime):
        return next(inbound for inbound in runtime["inbounds"] if inbound["protocol"] == "vless")

    def assert_migrated(self):
        result = self.bash("handler_xray_config 1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        runtime = json.loads(self.runtime_path.read_text())
        state = json.loads(self.state_path.read_text())
        self.assertIs(self.business(runtime)["sniffing"]["routeOnly"], True)
        self.assertEqual(state["xray"]["runtimeRoutingSnapshot"]["version"], 1)
        self.assertEqual(self.events_path.read_text().splitlines(), ["validate"])
        return runtime, state

    def test_exact_legacy_off_runtime_migrates_to_route_only(self):
        legacy = self.install_expected_runtime()
        self.assertNotIn("routeOnly", self.business(legacy)["sniffing"])
        runtime, state = self.assert_migrated()
        self.assertEqual(state["xray"]["relay"]["mode"], "off")
        self.assertFalse(any(outbound["tag"].startswith("xray-script-relay-") for outbound in runtime["outbounds"]))

    def test_exact_legacy_all_runtime_migrates_and_retains_policy(self):
        self.state["xray"]["relay"].update(mode="all", active="relay-a")
        self.write_state()
        legacy = self.install_expected_runtime()
        self.assertNotIn("routeOnly", self.business(legacy)["sniffing"])
        runtime, state = self.assert_migrated()
        self.assertEqual(state["xray"]["relay"]["mode"], "all")
        relay = [rule for rule in runtime["routing"]["rules"] if rule.get("ruleTag") == "xray-script-relay"]
        self.assertEqual(len(relay), 1)
        self.assertEqual(relay[0]["outboundTag"], "xray-script-relay-relay-a")

    def test_current_safe_runtime_with_missing_snapshot_is_accepted(self):
        self.state["xray"]["relay"].update(mode="all", active="relay-a")
        self.write_state()
        safe = self.install_expected_runtime(legacy=False)
        self.assertIs(self.business(safe)["sniffing"]["routeOnly"], True)
        runtime, _ = self.assert_migrated()
        self.assertEqual(runtime, safe)

    def test_manual_outbound_change_is_not_accepted_via_legacy_fallback(self):
        runtime = self.install_expected_runtime()
        runtime["outbounds"][0].setdefault("settings", {})["domainStrategy"] = "UseIPv4"
        self.runtime_path.write_text(json.dumps(runtime))
        before_runtime = self.runtime_path.read_bytes()
        before_state = self.state_path.read_bytes()
        result = self.bash("handler_xray_config 1")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.runtime_path.read_bytes(), before_runtime)
        self.assertEqual(self.state_path.read_bytes(), before_state)
        self.assertFalse(self.events_path.exists())

    def test_manual_sniffing_false_is_not_equivalent_to_exact_old_template(self):
        runtime = self.install_expected_runtime()
        self.business(runtime)["sniffing"]["routeOnly"] = False
        self.runtime_path.write_text(json.dumps(runtime))
        before_runtime = self.runtime_path.read_bytes()
        before_state = self.state_path.read_bytes()
        result = self.bash("handler_xray_config 1")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.runtime_path.read_bytes(), before_runtime)
        self.assertEqual(self.state_path.read_bytes(), before_state)
        self.assertFalse(self.events_path.exists())
