"""Relay routing and dependency regression checks without host services."""

import copy
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

from test_service_audit import ROOT


SOCKS_NODE = {
    "id": "node-a", "name": "Relay A", "protocol": "socks",
    "address": "203.0.113.10", "port": 1080, "username": "", "password": "",
}
VLESS_NODE = {
    "id": "node-b", "name": "Relay B", "protocol": "vless",
    "address": "2001:db8::20", "port": 443,
    "uuid": "4ea7f7dd-118c-4d41-b4b0-67ce8aff917c",
    "serverName": "relay.example.com", "publicKey": "A" * 43,
    "shortId": "0123456789abcdef", "flow": "xtls-rprx-vision",
    "encryption": "none",
}


def relay_state(mode="all", **values):
    return {"xray": {"relay": {
        "nodes": [copy.deepcopy(SOCKS_NODE)], "active": SOCKS_NODE["id"],
        "mode": mode, "domains": ["domain:example.com"], **values,
    }}}


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-relay-test-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def bash(self, body, **values):
        return subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(ROOT / 'lib/common.sh'))}\n"
             f"source {shlex.quote(str(ROOT / 'lib/relay.sh'))}\n" + body],
            cwd=ROOT, text=True, capture_output=True, timeout=20,
            env=os.environ | {key: value if isinstance(value, str) else json.dumps(value)
                              for key, value in values.items()},
        )

    def apply(self, runtime, state=None, *, twice=False):
        body = "SCRIPT_CONFIG=$TEST_STATE\nXRAY_CONFIG=$TEST_RUNTIME\n"
        body += "normalize_and_validate_relay_state || exit $?\n"
        body += "handler_apply_relay_config || exit $?\n"
        if twice:
            body += "handler_apply_relay_config || exit $?\n"
        body += "printf '%s\\n' \"$XRAY_CONFIG\"\n"
        result = self.bash(body, TEST_STATE=state or relay_state(), TEST_RUNTIME=runtime)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_domain_normalization_and_rejection(self):
        result = self.bash('relay_normalize_domains "$TEST_DOMAINS"',
                           TEST_DOMAINS=" Example.COM, full:API.example.net\nexample.com,domain:example.com ")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ["domain:example.com", "full:api.example.net"])
        for domains in ["https://example.com", "*.example.com", "example .com",
                        "regexp:.*", "example.com:443", "-bad.example", "bad..example", "a/b"]:
            with self.subTest(domains=domains):
                result = self.bash('relay_normalize_domains "$TEST_DOMAINS"', TEST_DOMAINS=domains)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_nodes_validate_literal_addresses_ports_and_required_fields(self):
        for node in [SOCKS_NODE, VLESS_NODE, SOCKS_NODE | {"address": "2001:db8::10"}]:
            result = self.bash('relay_validate_node "$TEST_NODE"', TEST_NODE=node)
            self.assertEqual(result.returncode, 0, result.stderr)
        invalid = [
            SOCKS_NODE | {"address": "256.1.1.1"}, SOCKS_NODE | {"address": "2001:db8::bad::1"},
            SOCKS_NODE | {"address": "relay.example.com"}, SOCKS_NODE | {"port": 0},
            SOCKS_NODE | {"port": 65536}, SOCKS_NODE | {"port": 1.5},
            SOCKS_NODE | {"port": "1080"}, SOCKS_NODE | {"id": "../unsafe"},
            SOCKS_NODE | {"username": "user", "password": ""},
            VLESS_NODE | {"uuid": ""}, VLESS_NODE | {"publicKey": "invalid"},
            VLESS_NODE | {"shortId": "1"}, VLESS_NODE | {"shortId": "00zz"},
            VLESS_NODE | {"flow": "unknown"}, VLESS_NODE | {"serverName": ""},
        ]
        for node in invalid:
            with self.subTest(node=node):
                result = self.bash('relay_validate_node "$TEST_NODE"', TEST_NODE=node)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_state_defaults_off_but_invalid_explicit_state_fails(self):
        result = self.bash('SCRIPT_CONFIG=\'{"xray":{}}\'; normalize_and_validate_relay_state && '
                           'printf "%s\\n" "$SCRIPT_CONFIG"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["xray"]["relay"]["mode"], "off")
        bad = [relay_state(active="missing"), relay_state(mode="invalid"),
               relay_state(nodes=[SOCKS_NODE, SOCKS_NODE]), relay_state(mode="domains", domains=[]),
               {"xray": {"relay": "broken"}}]
        for state in bad:
            with self.subTest(state=state):
                result = self.bash('SCRIPT_CONFIG=$TEST_STATE; normalize_and_validate_relay_state',
                                   TEST_STATE=state)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_all_mode_preserves_special_and_block_priority_and_direct_default(self):
        runtime = json.loads((ROOT / "config/xray/Vision.json").read_text())
        # Deliberately put a user block after WARP; relay must still respect it.
        runtime["outbounds"].append({"tag": "warp", "protocol": "socks", "settings": {
            "servers": [{"address": "127.0.0.1", "port": 40001}]}})
        runtime["routing"]["rules"] += [
            {"ruleTag": "warp-domain", "domain": ["domain:example.com"], "outboundTag": "warp"},
            {"ruleTag": "custom-block", "domain": ["domain:blocked.example"], "outboundTag": "block"},
        ]
        result = self.apply(runtime)
        rules = result["routing"]["rules"]
        relay = next(rule for rule in rules if rule.get("ruleTag") == "xray-script-relay")
        relay_index = rules.index(relay)
        self.assertEqual(result["outbounds"][0]["tag"], "direct")
        self.assertEqual(relay["outboundTag"], "xray-script-relay-node-a")
        self.assertEqual(relay["inboundTag"], ["VLESS-Vision-REALITY"])
        self.assertNotIn("domain", relay)
        self.assertTrue(all(rules.index(rule) < relay_index for rule in rules
                            if rule.get("outboundTag") == "block" or rule.get("ruleTag") == "api"))
        self.assertGreater(next(i for i, rule in enumerate(rules)
                                if rule.get("ruleTag") == "warp-domain"), relay_index)

    def test_domain_mode_covers_actual_business_tags_and_uses_route_only_sniffing(self):
        for template in ["Vision", "XHTTP", "Trojan", "Fallback", "hy2", "ss2022", "mKCP", "CDN", "SNI"]:
            with self.subTest(template=template):
                runtime = json.loads((ROOT / f"config/xray/{template}.json").read_text())
                result = self.apply(runtime, relay_state("domains"))
                rule = next(rule for rule in result["routing"]["rules"]
                            if rule.get("ruleTag") == "xray-script-relay")
                business = [item for item in result["inbounds"]
                            if item["protocol"] != "dokodemo-door"]
                self.assertEqual(set(rule["inboundTag"]), {item["tag"] for item in business})
                self.assertEqual(rule["domain"], ["domain:example.com"])
                for inbound in business:
                    self.assertTrue(inbound["sniffing"]["enabled"])
                    self.assertTrue(inbound["sniffing"]["routeOnly"])
                    self.assertTrue({"http", "tls", "quic"}.issubset(inbound["sniffing"]["destOverride"]))

    def test_multi_suffix_and_fallback_internal_inbound_are_included(self):
        runtime = json.loads((ROOT / "config/xray/Fallback.json").read_text())
        for inbound in runtime["inbounds"][1:]:
            inbound["tag"] += "-2"
        runtime["inbounds"] += [
            {"tag": "lan-tun", "protocol": "tun"},
            {"tag": "reverse-portal", "protocol": "vless"},
            {"tag": "lan-managed", "protocol": "vless"},
        ]
        result = self.apply(runtime)
        rule = next(rule for rule in result["routing"]["rules"]
                    if rule.get("ruleTag") == "xray-script-relay")
        self.assertEqual(set(rule["inboundTag"]), {"VLESS-Vision-REALITY-2", "VLESS-XHTTP-REALITY-2"})

    def test_reapply_is_idempotent_and_disable_cleans_generated_relay_only(self):
        runtime = json.loads((ROOT / "config/xray/Fallback.json").read_text())
        applied = self.apply(runtime)
        repeated = self.apply(applied, twice=True)
        self.assertEqual(repeated, applied)
        disabled = self.apply(applied, relay_state("off", active=None, domains=[]))
        self.assertFalse(any(item["tag"].startswith("xray-script-relay-") for item in disabled["outbounds"]))
        self.assertFalse(any(rule.get("ruleTag") == "xray-script-relay" for rule in disabled["routing"]["rules"]))
        self.assertEqual(disabled["outbounds"], runtime["outbounds"])

    def test_vless_outbound_contains_reality_parameters_and_socks_credentials_are_optional(self):
        result = self.bash('relay_build_outbound "$TEST_NODE"', TEST_NODE=VLESS_NODE)
        self.assertEqual(result.returncode, 0, result.stderr)
        outbound = json.loads(result.stdout)
        user = outbound["settings"]["vnext"][0]["users"][0]
        self.assertEqual(user["id"], VLESS_NODE["uuid"])
        self.assertEqual(user["flow"], VLESS_NODE["flow"])
        self.assertEqual(user["encryption"], "none")
        self.assertEqual(outbound["streamSettings"]["security"], "reality")
        self.assertEqual(outbound["streamSettings"]["realitySettings"]["serverName"], VLESS_NODE["serverName"])
        result = self.bash('relay_build_outbound "$TEST_NODE"', TEST_NODE=SOCKS_NODE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)["settings"]["servers"][0].get("users"))

    def test_references_reject_ambiguous_dangling_and_cyclic_configuration(self):
        runtime = json.loads((ROOT / "config/xray/Vision.json").read_text())
        result = self.bash('relay_validate_runtime_references "$TEST_RUNTIME"', TEST_RUNTIME=runtime)
        self.assertEqual(result.returncode, 0, result.stderr)
        invalid = []
        for target, value in [("outbounds", runtime["outbounds"][0]),
                              ("inbounds", runtime["inbounds"][0])]:
            candidate = copy.deepcopy(runtime)
            candidate[target].append(value)
            invalid.append(candidate)
        for rule in [{"domain": ["domain:example.com"], "outboundTag": "missing"},
                     {"inboundTag": ["missing"], "outboundTag": "direct"},
                     {"domain": ["domain:example.com"], "balancerTag": "missing"}]:
            candidate = copy.deepcopy(runtime)
            candidate["routing"]["rules"].append(rule)
            invalid.append(candidate)
        for settings in [{"proxySettings": {"tag": "missing"}},
                         {"streamSettings": {"sockopt": {"dialerProxy": "missing"}}},
                         {"proxySettings": {"tag": "direct"}}]:
            candidate = copy.deepcopy(runtime)
            candidate["outbounds"][0].update(settings)
            invalid.append(candidate)
        candidate = copy.deepcopy(runtime)
        candidate["outbounds"][0]["proxySettings"] = {"tag": "chain"}
        candidate["outbounds"].append({"tag": "chain", "protocol": "freedom", "proxySettings": {"tag": "direct"}})
        invalid.append(candidate)
        for index, candidate in enumerate(invalid):
            with self.subTest(index=index):
                result = self.bash('relay_validate_runtime_references "$TEST_RUNTIME"', TEST_RUNTIME=candidate)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def hostname_node(self, port=23456):
        return {
            "id": "dns-node", "name": "DNS relay", "address": "relay.example.net",
            "port": port, "protocol": "vless", "outbound": {
                "protocol": "vless", "settings": {"vnext": [{
                    "address": "relay.example.net", "port": port,
                    "users": [{"id": VLESS_NODE["uuid"], "encryption": "none", "flow": "xtls-rprx-vision"}],
                }]}, "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {
                    "serverName": "tls.example.net", "fingerprint": "chrome", "publicKey": "A" * 43,
                    "shortId": "01", "spiderX": "/",
                }},
            },
        }

    def test_stored_hostname_validation_does_not_require_dns(self):
        node = self.hostname_node()
        state = relay_state("off", nodes=[node], active=None)
        result = self.bash('''getent() { printf 'Unexpected DNS request\\n' >&2; return 99; }
timeout() { printf 'Unexpected DNS request\\n' >&2; return 99; }
SCRIPT_CONFIG=$TEST_STATE
normalize_and_validate_relay_state
''', TEST_STATE=state)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Unexpected DNS", result.stderr)

    def test_active_hostname_pins_validated_ip_and_preserves_sni(self):
        node = self.hostname_node()
        result = self.bash('''timeout() { shift; "$@"; }
getent() { printf '198.51.100.1 STREAM relay.example.net\\n198.51.100.2 DGRAM relay.example.net\\n'; }
relay_build_outbound "$TEST_NODE"
''', TEST_NODE=node)
        self.assertEqual(result.returncode, 0, result.stderr)
        outbound = json.loads(result.stdout)
        self.assertEqual(outbound["settings"]["vnext"][0]["address"], "198.51.100.1")
        self.assertEqual(outbound["streamSettings"]["realitySettings"]["serverName"], "tls.example.net")
        self.assertEqual(node["address"], "relay.example.net")

    def test_hostname_resolution_failure_or_mixed_local_answer_cannot_apply(self):
        node = self.hostname_node(port=443)
        for resolver in ["return 1", "printf '198.51.100.1 STREAM host\\n127.0.0.1 STREAM host\\n'"]:
            with self.subTest(resolver=resolver):
                result = self.bash('''timeout() { shift; "$@"; }
getent() { ''' + resolver + '''; }
SCRIPT_CONFIG='{"xray":{"port":443}}'
relay_build_outbound "$TEST_NODE"
''', TEST_NODE=node)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


class RuntimeGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-runtime-guard-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.runtime = json.loads((ROOT / "config/xray/Vision.json").read_text())
        self.runtime_path = self.work / "runtime.json"
        self.state_path = self.work / "state.json"
        self.runtime_path.write_text(json.dumps(self.runtime))
        self.state_path.write_text(json.dumps({"xray": {}}))

    def bash(self, body, **values):
        return subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(ROOT / 'lib/runtime-guard.sh'))}\n"
             'XRAY_CONFIG_PATH=$TEST_RUNTIME_PATH\nSCRIPT_CONFIG_PATH=$TEST_STATE_PATH\n' + body],
            cwd=ROOT, text=True, capture_output=True, timeout=20,
            env=os.environ | {"TEST_RUNTIME_PATH": str(self.runtime_path),
                              "TEST_STATE_PATH": str(self.state_path)} |
            {key: value if isinstance(value, str) else json.dumps(value)
             for key, value in values.items()},
        )

    def snapshot(self, runtime=None):
        result = self.bash('runtime_routing_snapshot "$TEST_RUNTIME"', TEST_RUNTIME=runtime or self.runtime)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_snapshot_is_canonical_hides_credentials_and_ignores_logging(self):
        snapshot = self.snapshot()
        self.assertEqual(snapshot["version"], 1)
        self.assertEqual(len(snapshot["sha256"]), 64)
        self.assertNotIn("privateKey", json.dumps(snapshot))
        runtime = dict(reversed(list(self.runtime.items())))
        runtime["log"] = {"loglevel": "debug", "access": "none", "error": "none"}
        self.assertEqual(self.snapshot(runtime), snapshot)

    def test_snapshot_detects_outbound_order_routing_and_inbound_sniffing_changes(self):
        baseline = self.snapshot()
        candidates = []
        runtime = copy.deepcopy(self.runtime)
        runtime["outbounds"].reverse()
        candidates.append(runtime)
        runtime = copy.deepcopy(self.runtime)
        runtime["routing"]["domainStrategy"] = "IPIfNonMatch"
        candidates.append(runtime)
        runtime = copy.deepcopy(self.runtime)
        runtime["inbounds"][1]["sniffing"]["routeOnly"] = False
        candidates.append(runtime)
        runtime = copy.deepcopy(self.runtime)
        runtime["outbounds"][0]["streamSettings"] = {"sockopt": {"mark": 123}}
        candidates.append(runtime)
        for runtime in candidates:
            self.assertNotEqual(self.snapshot(runtime), baseline)

    def test_saved_baseline_accepts_same_runtime_and_refuses_manual_outbound_edit(self):
        state = {"xray": {"runtimeRoutingSnapshot": self.snapshot()}}
        result = self.bash('runtime_guard_begin "$TEST_STATE"', TEST_STATE=state)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.runtime["outbounds"][0]["protocol"] = "blackhole"
        self.runtime_path.write_text(json.dumps(self.runtime))
        before = self.runtime_path.read_bytes()
        result = self.bash('runtime_guard_begin "$TEST_STATE"', TEST_STATE=state)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.runtime_path.read_bytes(), before)

    def test_legacy_requires_matching_expected_generation_before_recording_snapshot(self):
        result = self.bash('runtime_guard_begin "$TEST_STATE" "$TEST_EXPECTED"',
                           TEST_STATE={"xray": {}}, TEST_EXPECTED=self.runtime)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.bash('runtime_guard_begin "$TEST_STATE"', TEST_STATE={"xray": {}})
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        changed = copy.deepcopy(self.runtime)
        changed["outbounds"].append({"tag": "custom", "protocol": "freedom"})
        self.runtime_path.write_text(json.dumps(changed))
        result = self.bash('runtime_guard_begin "$TEST_STATE" "$TEST_EXPECTED"',
                           TEST_STATE={"xray": {}}, TEST_EXPECTED=self.runtime)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_concurrent_disk_edit_after_guard_is_detected_before_commit(self):
        state = {"xray": {"runtimeRoutingSnapshot": self.snapshot()}}
        result = self.bash('''runtime_guard_begin "$TEST_STATE" || exit $?
printf '\\n' >>"$XRAY_CONFIG_PATH"
runtime_guard_assert_current
''', TEST_STATE=state)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.bash('''runtime_guard_begin "$TEST_STATE" || exit $?
printf '\\n' >>"$SCRIPT_CONFIG_PATH"
runtime_guard_assert_current
''', TEST_STATE=state)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_malformed_runtime_fails_without_writing(self):
        self.runtime_path.write_text('{"outbounds": [')
        result = self.bash('runtime_guard_begin "$TEST_STATE" "$TEST_EXPECTED"',
                           TEST_STATE={"xray": {}}, TEST_EXPECTED=self.runtime)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.runtime_path.read_text(), '{"outbounds": [')


class RelayHandlerIntegrationTests(unittest.TestCase):
    """Exercise the real generator/transaction using only temporary files."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-relay-handler-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.state_path = self.work / "script.json"
        self.runtime_path = self.work / "runtime.json"
        self.state = json.loads((ROOT / "config.json").read_text())
        self.state["language"] = "en"
        self.state["xray"].update(
            tag="XHTTP", port=14443,
            uuid="4ea7f7dd-118c-4d41-b4b0-67ce8aff917c",
            target="example.com", serverNames=["example.com"], shortIds=["01"],
            privateKey="A" * 43, path="/relay-test/", xhttpMode="auto",
        )
        self.state_path.write_text(json.dumps(self.state))

    def bash(self, body):
        return subprocess.run(
            ["bash", "-c", f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n" + r'''
sync() { :; }
id() { return 1; }
firewall_owned_open() { return 0; }
handler_lan_open_firewall() { return 0; }
handler_restart() { printf 'restart\n' >>"$TEST_EVENTS"; return 0; }
load_i18n
''' + body],
            env=os.environ | {"SCRIPT_CONFIG_PATH_OVERRIDE": str(self.state_path),
                              "XRAY_CONFIG_PATH_OVERRIDE": str(self.runtime_path),
                              "TEST_EVENTS": str(self.work / "events"),
                              "XRAY_CONFIG_VALIDATE": "0"},
            cwd=ROOT, text=True, capture_output=True, timeout=25,
        )

    def generate(self):
        result = self.bash("handler_xray_config 1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_manual_runtime_drift_aborts_transaction_without_writes_or_restart(self):
        self.generate()
        runtime = json.loads(self.runtime_path.read_text())
        runtime["outbounds"].append({"tag": "custom-socks", "protocol": "socks", "settings": {
            "servers": [{"address": "203.0.113.88", "port": 1080}]}})
        runtime["routing"]["rules"].append({"domain": ["domain:manual.example"], "outboundTag": "custom-socks"})
        self.runtime_path.write_text(json.dumps(runtime))
        old_runtime = self.runtime_path.read_bytes()
        old_state = self.state_path.read_bytes()
        result = self.bash(r'''
previous_script_config=$SCRIPT_CONFIG
previous_xray_config=$(cat "$XRAY_CONFIG_PATH")
SCRIPT_CONFIG=$(jq '.xray.relay.mode = "off"' <<<"$SCRIPT_CONFIG")
apply_xray_state_transaction "$previous_script_config" "$previous_xray_config"
''')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.runtime_path.read_bytes(), old_runtime)
        self.assertEqual(self.state_path.read_bytes(), old_state)
        self.assertFalse((self.work / "events").exists())
        self.assertIn("manual", result.stderr.lower())

    def test_legacy_matching_runtime_is_verified_then_receives_snapshot(self):
        self.generate()
        generated = self.runtime_path.read_bytes()
        legacy = json.loads(self.state_path.read_text())
        legacy["xray"].pop("runtimeRoutingSnapshot", None)
        legacy["xray"].pop("relay", None)
        self.state_path.write_text(json.dumps(legacy))
        self.generate()
        migrated = json.loads(self.state_path.read_text())
        self.assertEqual(migrated["xray"]["relay"]["mode"], "off")
        self.assertEqual(migrated["xray"]["runtimeRoutingSnapshot"]["version"], 1)
        self.assertEqual(self.runtime_path.read_bytes(), generated)
        self.assertFalse((self.work / "events").exists())

    def test_legacy_manual_outbound_is_not_silently_discarded(self):
        self.generate()
        legacy = json.loads(self.state_path.read_text())
        legacy["xray"].pop("runtimeRoutingSnapshot", None)
        self.state_path.write_text(json.dumps(legacy))
        runtime = json.loads(self.runtime_path.read_text())
        runtime["outbounds"][0]["settings"] = {"domainStrategy": "UseIPv4"}
        self.runtime_path.write_text(json.dumps(runtime))
        old_runtime = self.runtime_path.read_bytes()
        old_state = self.state_path.read_bytes()
        result = self.bash("handler_xray_config 1")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.runtime_path.read_bytes(), old_runtime)
        self.assertEqual(self.state_path.read_bytes(), old_state)
        self.assertFalse((self.work / "events").exists())

    def test_restart_failure_restores_relay_state_routing_and_snapshot(self):
        self.generate()
        old_state = json.loads(self.state_path.read_text())
        old_runtime = json.loads(self.runtime_path.read_text())
        result = self.bash(r'''
restart_attempts=0
handler_restart() {
    restart_attempts=$((restart_attempts + 1))
    printf 'restart\n' >>"$TEST_EVENTS"
    [[ "$restart_attempts" -gt 1 ]]
}
previous_script_config=$SCRIPT_CONFIG
previous_xray_config=$(cat "$XRAY_CONFIG_PATH")
SCRIPT_CONFIG=$(jq --argjson relay ''' + shlex.quote(json.dumps(relay_state()["xray"]["relay"])) + r''' '.xray.relay = $relay' <<<"$SCRIPT_CONFIG")
apply_xray_state_transaction "$previous_script_config" "$previous_xray_config"
''')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.state_path.read_text()), old_state)
        self.assertEqual(json.loads(self.runtime_path.read_text()), old_runtime)
        self.assertEqual((self.work / "events").read_text().splitlines(), ["restart", "restart"])
        result = self.bash("runtime_guard_preflight")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
