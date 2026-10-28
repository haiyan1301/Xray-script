#!/usr/bin/env python3
"""Container-only systemctl adapter managing a real foreground Xray process.

This deliberately does not emulate systemd sandboxing, socket units, cgroups,
boot ordering, or automatic restart policies. It only supplies process lifecycle
operations needed by the isolated installer regression check.
"""

import os
from pathlib import Path
import signal
import subprocess
import sys
import time


if os.environ.get("XRAY_ISOLATED_CONTAINER") != "1" or not Path("/.dockerenv").exists():
    raise SystemExit("This adapter can only run inside the isolated test container")

STATE = Path("/run/xray-isolated-service")
STATE.mkdir(exist_ok=True)
PID = STATE / "pid"
ENABLED = STATE / "enabled"
UNIT = Path("/etc/systemd/system/xray.service")
LOG = STATE / "service.log"
args = [item for item in sys.argv[1:] if not item.startswith("-")]
if not args:
    raise SystemExit(1)
action = args[0]
service = args[1] if len(args) > 1 else ""
with (STATE / "commands.log").open("a") as log:
    log.write(" ".join(sys.argv[1:]) + "\n")


def active():
    try:
        pid = int(PID.read_text())
        os.kill(pid, 0)
        # A stopped, unreaped process is not an active service.
        return Path(f"/proc/{pid}/stat").read_text().split()[2] != "Z"
    except (FileNotFoundError, ProcessLookupError, ValueError):
        return False


def stop():
    if active():
        os.killpg(int(PID.read_text()), signal.SIGTERM)
        for _ in range(30):
            if not active():
                break
            time.sleep(0.05)
        if active():
            os.killpg(int(PID.read_text()), signal.SIGKILL)
    PID.unlink(missing_ok=True)


def start():
    if active():
        return 0
    with LOG.open("ab") as log:
        process = subprocess.Popen(
            ["/usr/local/bin/xray", "run", "-config",
             "/usr/local/etc/xray/config.json"],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True, user="xray", group="xray", extra_groups=["xray-nginx"],
        )
    PID.write_text(str(process.pid))
    time.sleep(0.3)
    return 0 if active() else 1


if action in ("daemon-reload", "reset-failed"):
    raise SystemExit(0)
if action == "list-unit-files":
    if UNIT.exists():
        print("xray.service " + ("enabled" if ENABLED.exists() else "disabled"))
    raise SystemExit(0)
if action == "list-units":
    if active():
        print("xray.service loaded active running Xray")
    raise SystemExit(0)
if service not in ("xray", "xray.service"):
    raise SystemExit(1)
if os.environ.get("XRAY_TEST_SERVICE_FAIL") == action:
    raise SystemExit(1)
if action == "is-active":
    raise SystemExit(0 if active() else 3)
if action == "is-enabled":
    raise SystemExit(0 if ENABLED.exists() else 1)
if action == "status":
    print("Xray process " + ("active" if active() else "inactive"))
    if LOG.exists():
        print(LOG.read_text()[-5000:])
    raise SystemExit(0 if active() else 3)
if action == "enable":
    ENABLED.touch()
elif action == "disable":
    ENABLED.unlink(missing_ok=True)
elif action == "stop":
    stop()
elif action == "start":
    raise SystemExit(start())
elif action == "restart":
    stop()
    raise SystemExit(start())
else:
    raise SystemExit(f"Unsupported systemctl test operation: {action}")
