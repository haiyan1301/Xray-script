"""Failure-path checks for standalone tools; never touch host networking."""

import json
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StandaloneToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xray-tools-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.env = os.environ | {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "TEST_WORK": str(self.work),
            "XRAY_API_PORT": "10085",
        }

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\n" + body + "\n")
        path.chmod(0o755)
        return path

    def run_tool(self, path, *args, env=None):
        return subprocess.run(
            ["bash", str(ROOT / path), *args],
            env=self.env | (env or {}),
            text=True,
            capture_output=True,
            timeout=10,
        )

    def setup_traffic(self, response, status=0):
        (self.work / "response.json").write_text(response)
        binary = self.command(
            "xray",
            'printf "%s\\n" "$@" >"${TEST_WORK}/args"\n'
            'cat "${TEST_WORK}/response.json"\n'
            f"exit {status}",
        )
        self.command("column", "cat")
        self.env["XRAY_BIN_PATH_OVERRIDE"] = str(binary)

    def test_traffic_accepts_compact_json_and_omitted_zero_values(self):
        self.setup_traffic(json.dumps({"stat": [
            {"name": "inbound>>>vision>>>traffic>>>uplink", "value": "1024"},
            {"name": "user>>>alice>>>traffic>>>downlink"},
        ]}))
        result = self.run_tool("tool/traffic.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("inbound:vision->up", result.stdout)
        self.assertIn("1.0KB", result.stdout)
        self.assertIn("user:alice->down", result.stdout)
        self.assertNotIn("", (self.work / "args").read_text().splitlines())

    def test_traffic_preserves_reset_flag(self):
        self.setup_traffic("{}")
        result = self.run_tool("tool/traffic.sh", "reset")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-reset=true", (self.work / "args").read_text().splitlines())

    def test_traffic_api_failure_is_not_presented_as_zero_traffic(self):
        self.setup_traffic("{}", status=23)
        result = self.run_tool("tool/traffic.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SUM->TOTAL", result.stdout)

    def test_traffic_invalid_json_fails(self):
        self.setup_traffic("API unavailable")
        result = self.run_tool("tool/traffic.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("SUM->TOTAL", result.stdout)

    def setup_warp(self, *, ignore_term=False):
        self.command("warp-svc", ('trap "" TERM\n' if ignore_term else "") + 'echo "$$" >"${TEST_WORK}/daemon-pid"\nexec sleep 60')
        self.command("socat", 'touch "${TEST_WORK}/forwarded"\nexit 9')
        self.command("warp-cli", '''printf '%s\\n' "$*" >>"${TEST_WORK}/cli-log"
# Model real daemon IPC readiness: settings cannot succeed before the
# background daemon has started. This is an explicit handshake, not a sleep.
if [[ "$*" == *" settings" ]]; then
    [[ -s "${TEST_WORK}/daemon-pid" ]]
elif [[ "$*" == *"registration show"* ]]; then
    [[ -f "${TEST_WORK}/registered" ]]
elif [[ "$*" == *"registration new"* ]]; then
    touch "${TEST_WORK}/registered"
elif [[ -n "${TEST_FAIL_STEP:-}" && "$*" == *"${TEST_FAIL_STEP}"* ]]; then
    exit 7
fi''')

    def assert_daemon_stopped(self):
        pid = int((self.work / "daemon-pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_warp_configuration_failure_stops_daemon_before_forwarding(self):
        self.setup_warp()
        result = self.run_tool("config/cloudflare-warp/startup.sh", env={"TEST_FAIL_STEP": "mode proxy"})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / "forwarded").exists())
        self.assert_daemon_stopped()

    def test_warp_listener_failure_stops_daemon_and_fails_container(self):
        self.setup_warp()
        # A persisted registration still requires proxy mode and connect.
        (self.work / "registered").touch()
        result = self.run_tool("config/cloudflare-warp/startup.sh")
        self.assertEqual(result.returncode, 9, result.stderr)
        commands = (self.work / "cli-log").read_text()
        self.assertIn("settings", commands)
        self.assertIn("mode proxy", commands)
        self.assertIn("connect", commands)
        self.assertNotIn("registration new", commands)
        self.assert_daemon_stopped()

    def test_warp_first_registration_connects_without_restart(self):
        self.setup_warp()
        result = self.run_tool("config/cloudflare-warp/startup.sh")
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertTrue((self.work / "registered").exists())
        self.assertTrue((self.work / "forwarded").exists())
        self.assert_daemon_stopped()

    def test_warp_cleanup_kills_daemon_that_ignores_term(self):
        self.setup_warp(ignore_term=True)
        # run_tool's subprocess deadline also verifies cleanup is bounded.
        result = self.run_tool("config/cloudflare-warp/startup.sh")
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assert_daemon_stopped()

    def setup_geodata(self):
        data = self.work / "geodata"
        data.mkdir()
        (data / "geoip.dat").write_text("old-ip")
        (data / "geosite.dat").write_text("old-site")
        self.env["XRAY_DIR_OVERRIDE"] = str(data)
        self.command("curl", '''output=''
while (($#)); do
    if [[ "$1" == -o ]]; then output="$2"; shift 2
    else shift; fi
done
[[ "${TEST_DOWNLOAD_FAILURE:-0}" == 0 ]] || exit 23
printf 'new-data' >"${output}"
''')
        self.command("systemctl", '''printf '%s\\n' "$*" >>"${TEST_WORK}/systemctl-log"
if [[ "$*" == "-q is-active xray" ]]; then
    [[ "${TEST_ACTIVE:-0}" == 1 ]]
elif [[ "${TEST_RESTART_FAILURE:-0}" == 1 && ! -f "${TEST_WORK}/restart-failed" ]]; then
    touch "${TEST_WORK}/restart-failed"
    exit 24
fi
''')
        return data

    def test_geodata_success_does_not_start_stopped_service(self):
        data = self.setup_geodata()
        result = self.run_tool("tool/geodata.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((data / "geoip.dat").read_text(), "new-data")
        self.assertEqual((data / "geosite.dat").read_text(), "new-data")
        self.assertNotIn("restart", (self.work / "systemctl-log").read_text())
        # A persistent lock file must not prevent a later independent update.
        result = self.run_tool("tool/geodata.sh")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_geodata_download_failure_preserves_both_files(self):
        data = self.setup_geodata()
        result = self.run_tool("tool/geodata.sh", env={"TEST_DOWNLOAD_FAILURE": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((data / "geoip.dat").read_text(), "old-ip")
        self.assertEqual((data / "geosite.dat").read_text(), "old-site")
        self.assertFalse(list(data.glob(".geodata.*.old")))
        self.assertFalse([path for path in data.glob(".geodata.*") if path.is_dir()])

    def test_geodata_restart_failure_rolls_back_both_files(self):
        data = self.setup_geodata()
        result = self.run_tool("tool/geodata.sh", env={"TEST_ACTIVE": "1", "TEST_RESTART_FAILURE": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((data / "geoip.dat").read_text(), "old-ip")
        self.assertEqual((data / "geosite.dat").read_text(), "old-site")
        self.assertEqual((self.work / "systemctl-log").read_text().count("restart xray"), 2)

    def test_geodata_competing_update_cannot_enter_transaction(self):
        data = self.setup_geodata()
        with (data / ".geodata.lock").open("w") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_tool("tool/geodata.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Another GeoData update", result.stderr)
        self.assertEqual((data / "geoip.dat").read_text(), "old-ip")
        self.assertEqual((data / "geosite.dat").read_text(), "old-site")


if __name__ == "__main__":
    unittest.main()
