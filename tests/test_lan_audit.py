"""Run the LAN network script with a fake ip tool and temporary ledgers."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LanNetworkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-lan-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.state = self.work / "routes.state"
        self.metadata = self.work / "site.json"
        self.metadata.write_text(json.dumps({
            "tunName": "xray0", "mode": "host", "lanInterface": "",
            "remoteCidrs": ["10.2.0.0/24"],
        }))
        ip = self.bin / "ip"
        ip.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >>"${TEST_WORK}/ip-log"
if [[ "$*" == "-4 route show exact "* ]]; then
    if [[ "${TEST_TUN_GONE:-0}" == 1 && "$*" == *" dev "* ]]; then
        exit 1
    fi
    [[ "${TEST_QUERY_FAILURE:-0}" == 0 ]] || exit 23
    printf '%s' "${TEST_EXISTING_ROUTE:-}"
elif [[ "$*" == "-4 route del "* ]]; then
    [[ "${TEST_DELETE_FAILURE:-0}" == 0 ]] || exit 24
fi
''')
        ip.chmod(0o755)
        self.env = os.environ | {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "TEST_WORK": str(self.work),
            "XRAY_LAN_DIR": str(self.work),
            "XRAY_LAN_STATE_FILE": str(self.work / "sysctl.state"),
            "XRAY_LAN_ROUTE_STATE_FILE": str(self.state),
            "XRAY_LAN_FORWARD_STATE_FILE": str(self.work / "forward.state"),
        }

    def run_network(self, operation, **env):
        return subprocess.run(
            ["bash", str(ROOT / "config/lan/xray-lan-net.sh"), operation],
            env=self.env | env, text=True, capture_output=True, timeout=10,
        )

    def test_start_refuses_interface_with_similar_name(self):
        result = self.run_network("start", TEST_EXISTING_ROUTE="10.2.0.0/24 dev xray01 metric 5")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace existing route", result.stderr)
        self.assertFalse(self.state.exists())

    def test_start_accepts_exact_interface(self):
        result = self.run_network("start", TEST_EXISTING_ROUTE="10.2.0.0/24 dev xray0 metric 5")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state.read_text(), "10.2.0.0/24\n")

    def test_start_refuses_mixed_routes(self):
        result = self.run_network("start", TEST_EXISTING_ROUTE=(
            "10.2.0.0/24 dev xray0 metric 5\n10.2.0.0/24 dev eth0 metric 10"
        ))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.state.exists())

    def test_failed_route_query_does_not_create_route(self):
        result = self.run_network("start", TEST_QUERY_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("route replace", (self.work / "ip-log").read_text())
        self.assertFalse(self.state.exists())

    def test_failed_stale_route_removal_preserves_old_ledger(self):
        self.state.write_text("10.3.0.0/24\n")
        result = self.run_network("start", TEST_EXISTING_ROUTE="10.3.0.0/24 dev xray0", TEST_DELETE_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state.read_text(), "10.3.0.0/24\n")

    def test_stop_retains_failed_routes_for_retry(self):
        self.state.write_text("10.2.0.0/24\n")
        result = self.run_network("stop", TEST_EXISTING_ROUTE="10.2.0.0/24 dev xray0", TEST_DELETE_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state.read_text(), "10.2.0.0/24\n")
        result = self.run_network("stop", TEST_EXISTING_ROUTE="10.2.0.0/24 dev xray0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.state.exists())

    def test_stop_retains_state_when_query_fails(self):
        self.state.write_text("10.2.0.0/24\n")
        result = self.run_network("stop", TEST_QUERY_FAILURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state.read_text(), "10.2.0.0/24\n")

    def test_stop_succeeds_after_xray_destroyed_the_tun(self):
        self.state.write_text("10.2.0.0/24\n")
        result = self.run_network("stop", TEST_TUN_GONE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.state.exists())

    def test_stop_does_not_delete_foreign_route(self):
        self.state.write_text("10.2.0.0/24\n")
        result = self.run_network("stop", TEST_EXISTING_ROUTE="10.2.0.0/24 dev xray01")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("route del", (self.work / "ip-log").read_text())
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main()
