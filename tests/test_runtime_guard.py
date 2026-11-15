"""Routing drift guard checks that need neither a service nor network access."""

import copy
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = {
    "log": {"loglevel": "warning"},
    "api": {"tag": "api"},
    "inbounds": [{"tag": "proxy", "port": 443, "protocol": "vless",
                  "settings": {"clients": [{"id": "old-id"}]}}],
    "outbounds": [{"tag": "direct", "protocol": "freedom"}],
    "routing": {"rules": []},
}


class RuntimeGuardLifetimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-runtime-guard-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.runtime = self.work / "runtime.json"
        self.state = self.work / "state.json"
        self.state.write_text(json.dumps({"language": "en", "xray": {}}))
        self.env = os.environ | {
            "TEST_RUNTIME": json.dumps(RUNTIME),
            "SCRIPT_CONFIG_PATH": str(self.state),
            "XRAY_CONFIG_PATH": str(self.runtime),
        }
        self.prelude = f"source {shlex.quote(str(ROOT / 'lib/runtime-guard.sh'))}\n"
        self.prelude += 'SCRIPT_CONFIG="$(cat -- "$SCRIPT_CONFIG_PATH")"\n'

    def bash(self, body, env=None):
        return subprocess.run(
            ["bash", "-c", self.prelude + body], cwd=ROOT,
            env=self.env | (env or {}), capture_output=True, text=True, timeout=10,
        )

    def test_fresh_install_has_no_runtime_to_adopt_or_modify(self):
        original = self.state.read_bytes()
        result = self.bash('runtime_guard_begin "$SCRIPT_CONFIG" || exit\n'
                           'printf "%s" "$_XRAY_RUNTIME_GUARD_ARMED"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "1")
        self.assertFalse(self.runtime.exists())
        self.assertEqual(self.state.read_bytes(), original)

    def test_missing_runtime_after_management_cannot_be_treated_as_new_install(self):
        result = self.bash(r'''
snapshot="$(runtime_routing_snapshot "$TEST_RUNTIME")" || exit
SCRIPT_CONFIG="$(printf '%s' "$SCRIPT_CONFIG" | jq --argjson s "$snapshot" '.xray.runtimeRoutingSnapshot = $s')" || exit
runtime_guard_begin "$SCRIPT_CONFIG"
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("previously managed runtime JSON is missing", result.stderr)
        self.assertFalse(self.runtime.exists())

    def test_runtime_appearing_after_fresh_preflight_is_a_conflict(self):
        result = self.bash('runtime_guard_begin "$SCRIPT_CONFIG" || exit\n'
                           'printf "%s" "$TEST_RUNTIME" >"$XRAY_CONFIG_PATH"\n'
                           'runtime_guard_assert_current\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed during this operation", result.stderr)
        self.assertEqual(json.loads(self.runtime.read_text()), RUNTIME)

    def test_intentional_state_write_refresh_cannot_adopt_a_runtime_change(self):
        self.runtime.write_text(json.dumps(RUNTIME))
        begin = 'runtime_guard_begin "$SCRIPT_CONFIG" "$TEST_RUNTIME" || exit\n'
        update = ('printf "%s\\n" "$SCRIPT_CONFIG" >"$SCRIPT_CONFIG_PATH"\n'
                  'runtime_guard_refresh_script_digest || exit\n')
        good = self.bash(begin + update + 'runtime_guard_assert_current\n')
        self.assertEqual(good.returncode, 0, good.stderr)
        bad = self.bash(begin + update + 'printf " " >>"$XRAY_CONFIG_PATH"\n'
                        'runtime_guard_refresh_script_digest || exit\n'
                        'runtime_guard_assert_current\n')
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("changed during this operation", bad.stderr)

    def test_exact_concurrent_edit_check_includes_log_changes(self):
        self.runtime.write_text(json.dumps(RUNTIME))
        result = self.bash(r'''
runtime_guard_begin "$SCRIPT_CONFIG" "$TEST_RUNTIME" || exit
jq '.log.loglevel = "debug"' "$XRAY_CONFIG_PATH" >"$XRAY_CONFIG_PATH.edit" || exit
mv "$XRAY_CONFIG_PATH.edit" "$XRAY_CONFIG_PATH" || exit
runtime_guard_assert_current
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed during this operation", result.stderr)
        self.assertEqual(json.loads(self.runtime.read_text())["log"]["loglevel"], "debug")

    def test_after_commit_uses_known_written_bytes_and_keeps_conflicts_armed(self):
        for changed_file in ["XRAY_CONFIG_PATH", "SCRIPT_CONFIG_PATH"]:
            with self.subTest(changed_file=changed_file):
                self.state.write_text(json.dumps({"language": "en", "xray": {}}))
                self.runtime.write_text(json.dumps(RUNTIME))
                result = self.bash(r'''
runtime_guard_begin "$SCRIPT_CONFIG" "$TEST_RUNTIME" || exit
printf '%s\n' "$TEST_RUNTIME" >"$XRAY_CONFIG_PATH" || exit
printf '%s\n' "$SCRIPT_CONFIG" >"$SCRIPT_CONFIG_PATH" || exit
runtime_guard_after_commit "$TEST_RUNTIME" "$SCRIPT_CONFIG" || exit
printf ' ' >>"${!TEST_CHANGED_FILE}"
if runtime_guard_after_commit "$TEST_RUNTIME" "$SCRIPT_CONFIG"; then exit 98; fi
if [[ "$_XRAY_RUNTIME_GUARD_ARMED" != 1 ]]; then exit 99; fi
runtime_guard_assert_current
''', {"TEST_CHANGED_FILE": changed_file})
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("changed during this operation", result.stderr)
                path = self.runtime if changed_file == "XRAY_CONFIG_PATH" else self.state
                self.assertTrue(path.read_bytes().endswith(b" "))

    def test_failed_rebaseline_preserves_existing_guard_for_rollback_check(self):
        self.runtime.write_text(json.dumps(RUNTIME))
        result = self.bash(r'''
runtime_guard_begin "$SCRIPT_CONFIG" "$TEST_RUNTIME" || exit
jq '.outbounds += [{tag:"manual",protocol:"freedom"}]' "$XRAY_CONFIG_PATH" >"$XRAY_CONFIG_PATH.edit" || exit
mv "$XRAY_CONFIG_PATH.edit" "$XRAY_CONFIG_PATH" || exit
if runtime_guard_begin "$SCRIPT_CONFIG"; then exit 98; fi
if [[ "$_XRAY_RUNTIME_GUARD_ARMED" != 1 ]]; then exit 99; fi
runtime_guard_assert_current
''')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("manual outbound/routing/inbound changes", result.stderr)
        self.assertIn("changed during this operation", result.stderr)

    def snapshot(self, runtime):
        result = self.bash('runtime_routing_snapshot "$TEST_RUNTIME"\n',
                           {"TEST_RUNTIME": json.dumps(runtime)})
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_baseline_ignores_auth_rotation_but_protects_routing_dependencies(self):
        baseline = self.snapshot(RUNTIME)
        irrelevant = copy.deepcopy(RUNTIME)
        irrelevant["log"]["loglevel"] = "debug"
        irrelevant["inbounds"][0]["settings"]["clients"][0]["id"] = "rotated-id"
        self.assertEqual(self.snapshot(irrelevant), baseline)
        for module, value in [
            ("dns", {"servers": ["localhost"]}),
            ("fakedns", [{"ipPool": "198.18.0.0/15", "poolSize": 65535}]),
            ("observatory", {"subjectSelector": ["direct"]}),
            ("burstObservatory", {"subjectSelector": ["direct"]}),
            ("transport", {"tcpSettings": {"acceptProxyProtocol": True}}),
            ("reverse", {"bridges": [{"tag": "bridge", "domain": "relay.local"}]}),
        ]:
            with self.subTest(module=module):
                changed = copy.deepcopy(RUNTIME)
                changed[module] = value
                self.assertNotEqual(self.snapshot(changed), baseline)

    def test_script_lock_serializes_writers_through_release(self):
        holder = subprocess.Popen(
            ["bash", "-c", self.prelude +
             'runtime_guard_acquire_lock || exit\nprintf "locked\\n"\n'
             'read -r release\nruntime_guard_release_lock\n'],
            cwd=ROOT, env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
        )
        try:
            self.assertEqual(holder.stdout.readline(), "locked\n")
            blocked = self.bash('runtime_guard_acquire_lock\n')
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn("another script operation", blocked.stderr)
        finally:
            holder.communicate("release\n", timeout=10)
        available = self.bash('runtime_guard_acquire_lock && runtime_guard_release_lock\n')
        self.assertEqual(available.returncode, 0, available.stderr)
        lock = Path(str(self.state) + ".operation.lock")
        self.assertTrue(lock.exists())
        self.assertEqual(stat.S_IMODE(lock.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
