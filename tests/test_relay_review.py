"""Review regressions: legacy WARP endpoint must never establish its own trust."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

from test_service_audit import ROOT


class LegacyWarpReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-legacy-warp-review-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.state_path = self.work / "script.json"
        self.runtime_path = self.work / "runtime.json"
        state = json.loads((ROOT / "config.json").read_text())
        state["language"] = "en"
        state["xray"].update(
            tag="XHTTP", port=14443, warp=1,
            uuid="4ea7f7dd-118c-4d41-b4b0-67ce8aff917c",
            target="example.com", serverNames=["example.com"], shortIds=["01"],
            privateKey="A" * 43, path="/relay-test/", xhttpMode="auto",
        )
        self.state_path.write_text(json.dumps(state))
        generated = self.bash('handler_xray_config 1')
        self.assertEqual(generated.returncode, 0, generated.stdout + generated.stderr)
        state = json.loads(self.state_path.read_text())
        state["xray"].pop("runtimeRoutingSnapshot", None)
        state["xray"].pop("relay", None)
        self.state_path.write_text(json.dumps(state))

    def bash(self, body):
        return subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n" + r'''
sync() { :; }
id() { return 1; }
firewall_owned_open() { return 0; }
handler_lan_open_firewall() { return 0; }
handler_restart() { printf 'restart\n' >>"$TEST_EVENTS"; return 0; }
obtain_warp_endpoint() { printf '127.0.0.1\n'; }
load_i18n
''' + body],
            env=os.environ | {
                "SCRIPT_CONFIG_PATH_OVERRIDE": str(self.state_path),
                "XRAY_CONFIG_PATH_OVERRIDE": str(self.runtime_path),
                "TEST_EVENTS": str(self.work / "events"),
                "XRAY_CONFIG_VALIDATE": "0",
            },
            cwd=ROOT, text=True, capture_output=True, timeout=25,
        )

    def test_clean_legacy_warp_loopback_migrates_without_repair_or_restart(self):
        before_runtime = self.runtime_path.read_bytes()
        result = self.bash('exec_docker() { printf "unexpected repair\\n" >&2; return 99; }; handler_xray_config 1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.runtime_path.read_bytes(), before_runtime)
        self.assertEqual(json.loads(self.state_path.read_text())["xray"]["runtimeRoutingSnapshot"]["version"], 1)
        self.assertFalse((self.work / "events").exists())
        self.assertNotIn("unexpected repair", result.stderr)

    def test_manually_changed_legacy_warp_endpoint_is_not_adopted(self):
        for address in ["203.0.113.50", "172.20.0.2", "::1"]:
            with self.subTest(address=address):
                runtime = json.loads(self.runtime_path.read_text())
                warp = next(outbound for outbound in runtime["outbounds"] if outbound["tag"] == "warp")
                warp["settings"]["servers"][0]["address"] = address
                self.runtime_path.write_text(json.dumps(runtime))
                before_runtime = self.runtime_path.read_bytes()
                before_state = self.state_path.read_bytes()
                result = self.bash('handler_xray_config 1')
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.runtime_path.read_bytes(), before_runtime)
                self.assertEqual(self.state_path.read_bytes(), before_state)
                self.assertFalse((self.work / "events").exists())
                self.assertIn("manual", result.stderr.lower())


class GuardedGeneratorReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-guarded-generator-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.user_home = self.work / "home"
        (self.user_home / ".xray-script").mkdir(parents=True)
        self.state_path = self.user_home / ".xray-script/config.json"
        state = json.loads((ROOT / "config.json").read_text())
        state["language"] = "en"
        self.state_path.write_text(json.dumps(state))
        self.env = os.environ | {
            "HOME": str(self.user_home),
            "SCRIPT_CONFIG_PATH_OVERRIDE": str(self.state_path),
            "XRAY_CONFIG_PATH_OVERRIDE": str(self.work / "runtime.json"),
        }

    def test_sni_generator_is_read_only_for_known_and_new_targets(self):
        original = self.state_path.read_bytes()
        state = json.loads(original)
        known = next(iter(state["target"]))
        for target in [known, "custom-relay-review.example"]:
            with self.subTest(target=target):
                result = subprocess.run(
                    ["bash", str(ROOT / "core/generate.sh"), "--server-names", target],
                    cwd=ROOT, env=self.env, text=True, capture_output=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), state["target"].get(target, [target]))
                self.assertEqual(self.state_path.read_bytes(), original)

    def test_guarded_protocol_state_generation_accepts_custom_target(self):
        body = f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n" + r'''
sync() { :; }
load_i18n
runtime_guard_preflight || exit $?
CONFIG_DATA[uuid]='4ea7f7dd-118c-4d41-b4b0-67ce8aff917c'
CONFIG_DATA[target]='custom-relay-review.example'
CONFIG_DATA[path]='/relay-review/'
CONFIG_DATA[rules]='n'
handler_script_config XHTTP
'''
        result = subprocess.run(
            ["bash", "-c", body], cwd=ROOT, env=self.env,
            text=True, capture_output=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        state = json.loads(self.state_path.read_text())
        self.assertEqual(state["xray"]["tag"], "XHTTP")
        self.assertEqual(state["xray"]["serverNames"], ["custom-relay-review.example"])
        self.assertNotIn("custom-relay-review.example", state["target"])
