"""Run real relay generation/commit/rollback with host services replaced."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

from test_service_audit import ROOT


class RelayTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-relay-transaction-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.state_path = self.work / "state.json"
        self.runtime_path = self.work / "runtime.json"
        self.events_path = self.work / "events"
        state = json.loads((ROOT / "config.json").read_text())
        state["language"] = "en"
        state["xray"].update(
            tag="Vision", port=14443,
            uuid="11111111-1111-4111-8111-111111111111",
            privateKey="A" * 43, publicKey="B" * 43,
            target="example.com", serverNames=["example.com"], shortIds=["01"],
            vlessEncEnable="n", mldsa65Enable="n",
        )
        state["xray"]["rules"].update(reset=0, resetBy="")
        state["xray"]["relay"] = {
            "nodes": [{"id": "relay-a", "name": "Relay A", "protocol": "socks",
                       "address": "203.0.113.20", "port": 1080,
                       "username": "", "password": ""}],
            "active": "relay-a", "mode": "domains", "domains": ["domain:example.com"],
        }
        self.initial_state = state
        self.state_path.write_text(json.dumps(state))
        self.env = os.environ | {
            "SCRIPT_CONFIG_PATH_OVERRIDE": str(self.state_path),
            "XRAY_CONFIG_PATH_OVERRIDE": str(self.runtime_path),
            "XRAY_CONFIG_VALIDATE": "0", "TEST_WORK": str(self.work),
        }
        self.prelude = f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n" + r'''
sync() { :; }
set_xray_config_permissions() { chmod 600 "$1"; }
prepare_xray_managed_logs() { :; }
firewall_owned_open() { :; }
handler_lan_open_firewall() { :; }
validate_xray_runtime_config() {
    printf 'validate\n' >>"${TEST_WORK}/events"
    [[ ! -f "${TEST_WORK}/validation-fails" ]]
}
handler_restart() {
    printf 'restart\n' >>"${TEST_WORK}/events"
    if [[ -f "${TEST_WORK}/restart-fails-once" ]]; then
        rm -- "${TEST_WORK}/restart-fails-once"
        return 42
    fi
}
load_i18n
handler_xray_config 1 || exit
cp -- "$SCRIPT_CONFIG_PATH" "${TEST_WORK}/old-state.json" || exit
cp -- "$XRAY_CONFIG_PATH" "${TEST_WORK}/old-runtime.json" || exit
previous_script_config="$SCRIPT_CONFIG"
previous_xray_config="$XRAY_CONFIG"
: >"${TEST_WORK}/events"
'''

    def bash(self, body):
        result = subprocess.run(
            ["bash", "-c", self.prelude + body], cwd=ROOT, env=self.env,
            text=True, capture_output=True, timeout=30,
        )
        return result

    def assert_unchanged(self):
        self.assertEqual(self.state_path.read_bytes(), (self.work / "old-state.json").read_bytes())
        self.assertEqual(self.runtime_path.read_bytes(), (self.work / "old-runtime.json").read_bytes())

    def events(self):
        return self.events_path.read_text().splitlines()

    def test_restart_failure_restores_both_files_and_restarts_old_configuration(self):
        result = self.bash(r'''
touch "${TEST_WORK}/restart-fails-once"
SCRIPT_CONFIG="$(printf '%s' "$SCRIPT_CONFIG" | jq '.xray.relay.mode = "all"')" || exit
apply_xray_state_transaction "$previous_script_config" "$previous_xray_config"
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assert_unchanged()
        self.assertEqual(self.events(), ["validate", "restart", "validate", "restart"])
        self.assertFalse(list(self.work.glob("*.rollback.*")))
        self.assertFalse(list(self.work.glob("*.tmp.*")))

    def test_candidate_validation_failure_does_not_restore_or_restart(self):
        result = self.bash(r'''
touch "${TEST_WORK}/validation-fails"
SCRIPT_CONFIG="$(printf '%s' "$SCRIPT_CONFIG" | jq '.xray.relay.mode = "all"')" || exit
apply_xray_state_transaction "$previous_script_config" "$previous_xray_config"
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assert_unchanged()
        self.assertEqual(self.events(), ["validate"])
        self.assertFalse(list(self.work.glob("*.rollback.*")))

    def test_dangling_persisted_route_fails_before_commit_or_core_validation(self):
        result = self.bash(r'''
SCRIPT_CONFIG="$(printf '%s' "$SCRIPT_CONFIG" | jq '.rules += [{ruleTag:"custom",domain:["domain:custom.example"],outboundTag:"missing-custom-outbound"}]')" || exit
apply_xray_state_transaction "$previous_script_config" "$previous_xray_config"
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assert_unchanged()
        self.assertEqual(self.events(), [])

    def test_external_edit_during_validation_survives_and_no_restart_occurs(self):
        result = self.bash(r'''
validate_xray_runtime_config() {
    printf 'validate\n' >>"${TEST_WORK}/events"
    jq '.outbounds += [{tag:"manual",protocol:"freedom"}]' "$XRAY_CONFIG_PATH" >"${TEST_WORK}/edit.json" || return 1
    mv -- "${TEST_WORK}/edit.json" "$XRAY_CONFIG_PATH" || return 1
}
SCRIPT_CONFIG="$(printf '%s' "$SCRIPT_CONFIG" | jq '.xray.relay.mode = "all"')" || exit
apply_xray_state_transaction "$previous_script_config" "$previous_xray_config"
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.events(), ["validate"])
        self.assertEqual(self.state_path.read_bytes(), (self.work / "old-state.json").read_bytes())
        runtime = json.loads(self.runtime_path.read_text())
        self.assertEqual(runtime["outbounds"][-1]["tag"], "manual")

    def test_external_edit_after_failed_restart_prevents_rollback_overwrite(self):
        result = self.bash(r'''
handler_restart() {
    printf 'restart\n' >>"${TEST_WORK}/events"
    jq '.outbounds += [{tag:"manual",protocol:"freedom"}]' "$XRAY_CONFIG_PATH" >"${TEST_WORK}/edit.json" || return 1
    mv -- "${TEST_WORK}/edit.json" "$XRAY_CONFIG_PATH" || return 1
    return 42
}
SCRIPT_CONFIG="$(printf '%s' "$SCRIPT_CONFIG" | jq '.xray.relay.mode = "all"')" || exit
apply_xray_state_transaction "$previous_script_config" "$previous_xray_config"
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.events(), ["validate", "restart"])
        self.assertEqual(json.loads(self.runtime_path.read_text())["outbounds"][-1]["tag"], "manual")
        self.assertEqual(json.loads(self.state_path.read_text())["xray"]["relay"]["mode"], "all")

    def test_explicit_route_reset_disables_relay_and_preserves_saved_nodes(self):
        result = self.bash(r'''
SCRIPT_CONFIG="$(printf '%s' "$SCRIPT_CONFIG" | jq '.xray.rules.reset = 1 | .xray.rules.resetBy = .version')" || exit
handler_xray_config 1
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads(self.state_path.read_text())
        self.assertEqual(state["xray"]["relay"], self.initial_state["xray"]["relay"] |
                         {"active": None, "mode": "off", "domains": []})
        self.assertEqual(state["xray"]["rules"]["reset"], 0)
        runtime = json.loads(self.runtime_path.read_text())
        self.assertFalse(any(o["tag"].startswith("xray-script-relay-") for o in runtime["outbounds"]))
        self.assertFalse(any(r.get("ruleTag") == "xray-script-relay" for r in runtime["routing"]["rules"]))

    def test_stale_reset_marker_does_not_disable_saved_relay(self):
        result = self.bash(r'''
SCRIPT_CONFIG="$(printf '%s' "$SCRIPT_CONFIG" | jq '.xray.rules.reset = 1 | .xray.rules.resetBy = "older-version"')" || exit
handler_xray_config 1
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.state_path.read_text())["xray"]["relay"],
                         self.initial_state["xray"]["relay"])

    def test_protocol_reconfiguration_inherits_relay_and_rebuilds_new_inbound_scope(self):
        result = self.bash(r'''
CONFIG_DATA['rules']='n'
CONFIG_DATA['port']=14444
CONFIG_DATA['ss2022-password']='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
handler_script_config ss2022 || exit
handler_xray_config 1
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.state_path.read_text())["xray"]["relay"],
                         self.initial_state["xray"]["relay"])
        runtime = json.loads(self.runtime_path.read_text())
        rule = next(r for r in runtime["routing"]["rules"] if r.get("ruleTag") == "xray-script-relay")
        self.assertEqual(rule["inboundTag"], [i["tag"] for i in runtime["inbounds"] if i["protocol"] == "shadowsocks"])
        self.assertNotIn("VLESS-Vision-REALITY", rule["inboundTag"])

    def test_legacy_preflight_compares_without_committing_or_health_mutations(self):
        result = self.bash(r'''
SCRIPT_CONFIG="$(printf '%s' "$SCRIPT_CONFIG" | jq 'del(.xray.runtimeRoutingSnapshot)')" || exit
printf '%s\n' "$SCRIPT_CONFIG" >"$SCRIPT_CONFIG_PATH" || exit
cp -- "$SCRIPT_CONFIG_PATH" "${TEST_WORK}/legacy-state.json" || exit
runtime_guard_disarm
exec_docker() { printf 'unexpected-docker\n' >>"${TEST_WORK}/events"; return 99; }
runtime_guard_preflight || exit
cmp -s "$SCRIPT_CONFIG_PATH" "${TEST_WORK}/legacy-state.json" || exit
runtime_guard_assert_current
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.events(), [])
        self.assertNotIn("runtimeRoutingSnapshot", json.loads(self.state_path.read_text())["xray"])
        self.assertEqual(self.runtime_path.read_bytes(), (self.work / "old-runtime.json").read_bytes())

    def test_legacy_preflight_rejects_manual_outbound_without_adopting_or_writing(self):
        result = self.bash(r'''
SCRIPT_CONFIG="$(printf '%s' "$SCRIPT_CONFIG" | jq 'del(.xray.runtimeRoutingSnapshot)')" || exit
printf '%s\n' "$SCRIPT_CONFIG" >"$SCRIPT_CONFIG_PATH" || exit
cp -- "$SCRIPT_CONFIG_PATH" "${TEST_WORK}/legacy-state.json" || exit
jq '.outbounds[0].settings.domainStrategy = "UseIPv6"' "$XRAY_CONFIG_PATH" >"${TEST_WORK}/edit.json" || exit
mv -- "${TEST_WORK}/edit.json" "$XRAY_CONFIG_PATH" || exit
cp -- "$XRAY_CONFIG_PATH" "${TEST_WORK}/legacy-runtime.json" || exit
runtime_guard_disarm
runtime_guard_preflight
''')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.events(), [])
        self.assertIn("manual outbound/routing/inbound changes", result.stderr)
        self.assertEqual(self.state_path.read_bytes(), (self.work / "legacy-state.json").read_bytes())
        self.assertEqual(self.runtime_path.read_bytes(), (self.work / "legacy-runtime.json").read_bytes())


if __name__ == "__main__":
    unittest.main()
