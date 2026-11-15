"""Relay UI/probe regressions; no real Xray service or remote node is touched."""

import json
import os
from pathlib import Path
import shlex
import socket
import struct
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
UUID = "11111111-1111-4111-8111-111111111111"
PUBLIC_KEY = "A" * 43
LINK = (f"vless://{UUID}@203.0.113.9:443?encryption=none&security=reality"
        f"&sni=www.example.com&fp=chrome&pbk={PUBLIC_KEY}&sid=ab"
        "&type=tcp&flow=xtls-rprx-vision#Imported-node")


class RelayMenuTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-relay-ui-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        (self.work / ".xray-script").mkdir()
        (self.work / ".xray-script/config.json").write_text('{"language":"en"}')
        (self.work / "runtime.json").write_text('{"outbounds":[],"routing":{"rules":[]}}')
        self.saved = self.work / "saved.json"
        self.state = {
            "language": "en",
            "xray": {"relay": {"nodes": [], "active": None, "mode": "off", "domains": []}},
        }

    def bash(self, body, user_input="", state=None, env=None, timeout=20):
        prefix = f'''
source {shlex.quote(str(ROOT / 'lib/common.sh'))}
source {shlex.quote(str(ROOT / 'lib/relay.sh'))}
source {shlex.quote(str(ROOT / 'lib/relay-menu.sh'))}
load_i18n
function apply_xray_state_transaction() {{ printf '%s\\n' "${{SCRIPT_CONFIG}}" >"${{TEST_SAVED}}"; }}
'''
        return subprocess.run(
            ["bash", "-c", prefix + body], input=user_input, text=True,
            capture_output=True, cwd=ROOT, timeout=timeout,
            env=os.environ | {
                "HOME": str(self.work), "PROJECT_ROOT": str(ROOT),
                "READ_PATH": str(ROOT / "core/read.sh"),
                "I18N_DIR": str(ROOT / "i18n"),
                "SCRIPT_CONFIG_PATH": str(self.work / ".xray-script/config.json"),
                "XRAY_CONFIG_PATH": str(self.work / "runtime.json"),
                "SCRIPT_CONFIG": json.dumps(state or self.state),
                "TEST_SAVED": str(self.saved), "TEST_WORK": str(self.work),
            } | (env or {}),
        )

    def add_socks(self, *, active=False):
        self.state["xray"]["relay"]["nodes"] = [{
            "id": "node1", "name": "SOCKS-node", "address": "203.0.113.10", "port": 1080,
            "protocol": "socks", "username": "private-user", "password": "private-password",
        }]
        if active:
            self.state["xray"]["relay"].update(active="node1", mode="all")

    def test_paste_import_saves_without_prompting_manual_fields_or_echoing_secrets(self):
        result = self.bash('relay_import_node', LINK + "\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        node = json.loads(self.saved.read_text())["xray"]["relay"]["nodes"][0]
        self.assertEqual(node["address"], "203.0.113.9")
        self.assertEqual(node["outbound"]["settings"]["vnext"][0]["users"][0]["id"], UUID)
        self.assertTrue(node["id"])
        self.assertIn("Imported-node", result.stderr)
        self.assertEqual(result.stdout, "")
        for secret in [LINK, UUID, PUBLIC_KEY, "B UUID", "B REALITY"]:
            self.assertNotIn(secret, result.stderr)

    def test_invalid_link_aborts_without_saving_or_echoing_uri(self):
        link = "vless://very-private-value@example.net:443?unknown=private-secret"
        result = self.bash('relay_import_node', link + "\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.saved.exists())
        self.assertNotIn("private", result.stdout + result.stderr)

    def test_reimport_replaces_one_node_preserving_active_reference(self):
        result = self.bash('relay_import_node', LINK + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.saved.read_text())
        node_id = state["xray"]["relay"]["nodes"][0]["id"]
        state["xray"]["relay"].update(active=node_id, mode="all")
        result = self.bash(f'relay_import_node {shlex.quote(node_id)}',
                           LINK.replace("203.0.113.9", "203.0.113.20") + "\n", state)
        self.assertEqual(result.returncode, 0, result.stderr)
        relay = json.loads(self.saved.read_text())["xray"]["relay"]
        self.assertEqual(len(relay["nodes"]), 1)
        self.assertEqual(relay["nodes"][0]["address"], "203.0.113.20")
        self.assertEqual(relay["nodes"][0]["id"], node_id)
        self.assertEqual(relay["active"], node_id)
        self.assertEqual(relay["mode"], "all")

    def test_active_node_cannot_be_deleted(self):
        self.add_socks(active=True)
        result = self.bash('relay_delete_node node1', "y\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.saved.exists())
        self.assertIn("active", result.stderr)

    def test_eof_during_domain_input_aborts_before_confirmation_or_write(self):
        self.add_socks()
        result = self.bash('relay_apply_policy node1', "2\nexample.com\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.saved.exists())
        self.assertNotIn("Apply this policy?", result.stderr)

    def test_domains_are_normalized_and_confirmed_without_credentials(self):
        self.add_socks()
        result = self.bash('relay_apply_policy node1',
                           "2\n Example.COM,full:api.example.net\nexample.com\n\ny\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        relay = json.loads(self.saved.read_text())["xray"]["relay"]
        self.assertEqual(relay["mode"], "domains")
        self.assertEqual(relay["domains"], ["domain:example.com", "full:api.example.net"])
        self.assertEqual(relay["active"], "node1")
        self.assertNotIn("private-user", result.stderr)
        self.assertNotIn("private-password", result.stderr)

    def test_failed_transaction_retains_rollback_ledger_in_memory(self):
        self.add_socks()
        body = '''
function apply_xray_state_transaction() {
    SCRIPT_CONFIG="$(printf '%s\\n' "$1" | jq '.xray.firewallRules = [{port:1234}]')"
    return 1
}
relay_store_state '{"nodes":[],"mode":"off","active":null,"domains":[]}'
status=$?
printf '%s\\n' "${SCRIPT_CONFIG}" >"${TEST_SAVED}"
exit "${status}"
'''
        result = self.bash(body)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.saved.read_text())["xray"]["firewallRules"], [{"port": 1234}])

    def test_another_process_listener_cannot_satisfy_test_readiness(self):
        with socket.socket() as unrelated:
            unrelated.bind(("127.0.0.1", 0))
            unrelated.listen(1)
            port = unrelated.getsockname()[1]
            body = f"""
sleep 30 &
child=$!
relay_test_owns_listener "${{child}}" {port}
status=$?
kill "${{child}}"
wait "${{child}}" 2>/dev/null || true
exit "${{status}}"
"""
            result = self.bash(body)
        self.assertNotEqual(result.returncode, 0)

    def test_test_instance_cleanup_is_bounded_when_child_ignores_term(self):
        self.add_socks()
        fake_xray = self.work / "xray"
        fake_xray.write_text('''#!/usr/bin/env python3
import json, os, pathlib, signal, socket, stat, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
p = pathlib.Path(sys.argv[-1])
config = json.loads(p.read_text())
pathlib.Path(os.environ['TEST_WORK'], 'probe-meta.json').write_text(json.dumps({
    'pid':os.getpid(), 'file_mode':stat.S_IMODE(p.stat().st_mode),
    'dir_mode':stat.S_IMODE(p.parent.stat().st_mode), 'dir':str(p.parent)}))
s = socket.socket(); s.bind(('127.0.0.1', config['inbounds'][0]['port'])); s.listen()
while True:
    c, _ = s.accept(); c.close()
''')
        fake_xray.chmod(0o700)
        body = '''
function curl() { printf '198.51.100.10'; }
function python3() { return 1; }
relay_test_node node1
'''
        start = time.monotonic()
        result = self.bash(body, env={"XRAY_BIN_PATH": str(fake_xray)}, timeout=12)
        self.assertNotEqual(result.returncode, 0)  # UDP fake fails.
        self.assertLess(time.monotonic() - start, 8)
        meta = json.loads((self.work / "probe-meta.json").read_text())
        self.assertEqual(meta["file_mode"], 0o600)
        self.assertEqual(meta["dir_mode"], 0o700)
        self.assertFalse(Path(meta["dir"]).exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(meta["pid"], 0)
        self.assertNotIn("private-password", result.stdout + result.stderr)


class RelayUdpProbeTests(unittest.TestCase):
    def run_probe(self, *, response_flags=0x8180, fragment=0):
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        server.settimeout(5)
        datagram = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        datagram.bind(("127.0.0.1", 0))
        datagram.settimeout(5)
        errors = []

        def exact(sock, count):
            data = b""
            while len(data) < count:
                part = sock.recv(count - len(data))
                if not part:
                    raise OSError("unexpected EOF")
                data += part
            return data

        def socks_server():
            try:
                with server.accept()[0] as conn:
                    conn.settimeout(5)
                    self.assertEqual(exact(conn, 3), b"\x05\x01\x00")
                    conn.sendall(b"\x05\x00")
                    self.assertEqual(exact(conn, 10)[1], 3)
                    conn.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1")
                                 + struct.pack("!H", datagram.getsockname()[1]))
                    packet, sender = datagram.recvfrom(65535)
                    self.assertEqual(packet[:10], b"\x00\x00\x00\x01\x01\x01\x01\x01\x00\x35")
                    query = packet[10:]
                    answer = query[:2] + struct.pack("!HHH", response_flags, 1, 1) + query[8:]
                    envelope = packet[:2] + bytes([fragment]) + packet[3:10]
                    datagram.sendto(envelope + answer, sender)
                    conn.recv(1)  # Keep association alive until the probe closes it.
            except Exception as exc:
                errors.append(exc)
            finally:
                server.close()
                datagram.close()

        thread = threading.Thread(target=socks_server, daemon=True)
        thread.start()
        result = subprocess.run(
            ["python3", str(ROOT / "lib/relay-probe.py"), str(server.getsockname()[1])],
            text=True, capture_output=True, timeout=15,
        )
        thread.join(6)
        self.assertFalse(thread.is_alive())
        if errors:
            raise errors[0]
        return result

    def test_real_udp_dns_exchange_succeeds(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_dns_query_echo_is_not_accepted_as_response(self):
        self.assertNotEqual(self.run_probe(response_flags=0x0100).returncode, 0)

    def test_fragmented_socks_udp_response_is_rejected(self):
        self.assertNotEqual(self.run_probe(fragment=1).returncode, 0)


if __name__ == "__main__":
    unittest.main()
