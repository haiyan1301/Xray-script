"""Exercise real Xray installation and process lifecycle in a disposable container.

Invoke through tests/run_isolated.sh. Never run against a host installation.
Only systemctl and the upstream release download are adapted: systemctl manages
a real Xray process as the xray user, and download_xray copies a verified official
release archive. The pinned upstream's argument parser, installation, users,
permissions, geodata, unit-file generation, and removal all execute normally.
"""

import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pty
import pwd
import re
import shlex
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
BINARY = Path("/usr/local/bin/xray")
RUNTIME = Path("/usr/local/etc/xray/config.json")
SERVICE_STATE = Path("/run/xray-isolated-service")


def version(binary):
    output = subprocess.check_output([str(binary), "version"], text=True)
    return "v" + output.splitlines()[0].split()[1]


def proxy_transfer(work, restart):
    """Send real HTTP traffic through a local client and the installed SS2022 node."""
    payload = b"Xray-script isolated encrypted proxy transfer passed"

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *args):
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    server_thread.start()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        client_port = reservation.getsockname()[1]
    key = json.loads(RUNTIME.read_text())["inbounds"][1]["settings"]["password"]
    client_config = work / "client.json"
    client_config.write_text(json.dumps({
        "log": {"access": "none", "error": str(work / "client-error.log"), "loglevel": "debug"},
        "inbounds": [{"listen": "127.0.0.1", "port": client_port, "protocol": "socks", "settings": {"auth": "noauth"}}],
        "outbounds": [{"protocol": "shadowsocks", "settings": {"servers": [{
            "address": "127.0.0.1", "port": 14443,
            "method": "2022-blake3-aes-256-gcm", "password": key,
        }]}}],
    }))
    try:
        # Current Xray cores also reject private targets inside freedom. Permit
        # only this temporary local HTTP endpoint in the disposable runtime;
        # production templates and all other private destinations stay intact.
        runtime = json.loads(RUNTIME.read_text())
        runtime["routing"]["rules"].insert(0, {
            "ruleTag": "integration-loopback", "type": "field",
            "inboundTag": [runtime["inbounds"][1]["tag"]],
            "ip": ["127.0.0.1/32"], "port": httpd.server_port,
            "outboundTag": "direct",
        })
        direct = next(outbound for outbound in runtime["outbounds"] if outbound.get("tag") == "direct")
        direct.setdefault("settings", {}).setdefault("finalRules", []).insert(0, {
            "action": "allow", "network": "tcp", "ip": ["127.0.0.1/32"],
            "port": httpd.server_port,
        })
        RUNTIME.write_text(json.dumps(runtime))
        restart()
        with subprocess.Popen(
            [str(BINARY), "run", "-config", str(client_config)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        ) as client:
            try:
                deadline = time.monotonic() + 5
                while True:
                    try:
                        connection = socket.create_connection(("127.0.0.1", client_port), timeout=2)
                        break
                    except ConnectionRefusedError:
                        if client.poll() is not None or time.monotonic() >= deadline:
                            raise
                        time.sleep(0.05)
                with connection:
                    connection.settimeout(5)
                    def read_exact(size):
                        result = b""
                        while len(result) < size:
                            chunk = connection.recv(size - len(result))
                            assert chunk, "SOCKS client closed the connection"
                            result += chunk
                        return result

                    connection.sendall(b"\x05\x01\x00")
                    assert read_exact(2) == b"\x05\x00"
                    connection.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", httpd.server_port))
                    response = read_exact(4)
                    assert response[:2] == b"\x05\x00", "SOCKS CONNECT failed"
                    if response[3] == 1:
                        read_exact(6)
                    elif response[3] == 4:
                        read_exact(18)
                    else:
                        read_exact(read_exact(1)[0] + 2)
                    connection.sendall(f"GET /integration HTTP/1.0\r\nHost: 127.0.0.1:{httpd.server_port}\r\n\r\n".encode())
                    received = b""
                    while b"\r\n\r\n" not in received:
                        chunk = connection.recv(65536)
                        assert chunk, "Proxy closed before returning HTTP headers"
                        received += chunk
                    headers, body = received.split(b"\r\n\r\n", 1)
                    assert b"200 OK" in headers, "Proxy did not return HTTP success"
                    assert b"content-length: " + str(len(payload)).encode() in headers.lower()
                    # Verify HTTP framing rather than waiting for the proxy's
                    # TCP idle timeout after the complete response has arrived.
                    while len(body) < len(payload):
                        chunk = connection.recv(len(payload) - len(body))
                        assert chunk, "Proxy closed before returning the HTTP body"
                        body += chunk
                    assert body == payload, "Proxy data transfer failed"
            except (AssertionError, OSError):
                for log_path in (work / "client-error.log", Path("/var/log/xray/error.log")):
                    if log_path.exists():
                        print(f"Proxy diagnostic {log_path.name}:\n{log_path.read_text()[-4000:]}", file=sys.stderr)
                raise
            finally:
                client.terminate()
                try:
                    client.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait()
    finally:
        httpd.shutdown()
        httpd.server_close()
        server_thread.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", required=True, type=Path)
    parser.add_argument("--previous-core", required=True, type=Path)
    args = parser.parse_args()
    if (os.environ.get("XRAY_ISOLATED_CONTAINER") != "1"
            or not Path("/.dockerenv").exists() or os.geteuid() != 0):
        parser.error("Use tests/run_isolated.sh: this test requires a disposable root container")
    if BINARY.exists() or Path("/etc/systemd/system/xray.service").exists():
        parser.error("Refusing to replace an existing Xray installation")
    latest, previous = args.core.resolve(), args.previous_core.resolve()
    latest_version, previous_version = version(latest / "xray"), version(previous / "xray")
    if latest_version == previous_version:
        parser.error("Use two different official releases to exercise a real upgrade")
    # lib/common.sh puts /bin and /usr/bin before /usr/local/bin. Replace the
    # container's systemctl at its normal location so every installer subprocess
    # uses this adapter, including shells that reset PATH.
    shim = Path("/usr/bin/systemctl")
    shutil.copyfile(ROOT / "tests/fixtures/systemctl.py", shim)
    shim.chmod(0o755)
    fixture = ROOT / "tests/fixtures/upstream-install-release.sh"
    expected = re.search(r"XRAY_INSTALL_SHA256='([a-f0-9]{64})'", (ROOT / "core/handler.sh").read_text()).group(1)
    assert hashlib.sha256(fixture.read_bytes()).hexdigest() == expected, "Pinned installer fixture changed"

    with tempfile.TemporaryDirectory(prefix="xray-lifecycle-") as temporary:
        work = Path(temporary)
        config = work / "config.json"
        data = json.loads((ROOT / "config.json").read_text())
        key_output = subprocess.check_output([str(latest / "xray"), "x25519"], text=True)
        private_key = re.search(r"Private\s*[Kk]ey:\s*(\S+)", key_output).group(1)
        data["language"] = "en"
        data["xray"].update(
            version=previous_version, tag="Vision", port=14443,
            uuid=str(uuid.uuid4()), privateKey=private_key,
            target="example.com", serverNames=["example.com"],
            shortIds=["0123456789abcdef"], vlessEncEnable="n",
            mldsa65Enable="n", githubProxy="n",
        )
        config.write_text(json.dumps(data))
        env = os.environ | {
            "SCRIPT_CONFIG_PATH_OVERRIDE": str(config),
            "XRAY_TEST_FIXTURE": str(fixture),
            "XRAY_TEST_ARCHIVE": str(next(previous.glob("Xray-linux-*.zip"))),
        }
        preamble = "source " + shlex.quote(str(ROOT / "core/handler.sh")) + "\nload_i18n\n" + r'''
fetch_xray_install_script() {
    cat <<'INSTALLER'
source <(sed '$d' "${XRAY_TEST_FIXTURE}")
download_xray() {
    [[ "${XRAY_TEST_INSTALL_MODE:-ok}" != download-fail ]] || return 1
    cp -- "${XRAY_TEST_ARCHIVE}" "${ZIP_FILE}" || return 1
    cp -- "${XRAY_TEST_ARCHIVE}.dgst" "${ZIP_FILE}.dgst" || return 1
    local expected actual
    expected="$(awk -F '= ' '/^SHA2-256=/ {print $2}' "${ZIP_FILE}.dgst")"
    actual="$(sha256sum "${ZIP_FILE}")"
    [[ "${actual%% *}" == "${expected}" ]]
}
install() {
    command install "$@" || return 1
    if [[ "${XRAY_TEST_INSTALL_MODE:-ok}" == after-install-fail &&
          "${*: -1}" == /usr/local/bin/xray ]]; then
        return 23
    fi
}
main "$@"
INSTALLER
}
'''

        def run(body, *, success=True, changes=None, terminal=False):
            run_env = env | (changes or {})
            if terminal:
                master, slave = pty.openpty()
                try:
                    process = subprocess.Popen(
                        ["bash", "-c", preamble + body], cwd=ROOT, env=run_env,
                        stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        text=True, start_new_session=True,
                    )
                    os.close(slave)
                    slave = None
                    os.write(master, b"yes\n")
                    try:
                        output, _ = process.communicate(timeout=90)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate()
                        raise
                    code = process.returncode
                finally:
                    os.close(master)
                    if slave is not None:
                        os.close(slave)
            else:
                result = subprocess.run(
                    ["bash", "-c", preamble + body], cwd=ROOT, env=run_env,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                    timeout=90,
                )
                code, output = result.returncode, result.stdout
            assert (code == 0) == success, f"Unexpected exit {code}:\n{output}"
            return output

        def listening():
            with socket.create_connection(("127.0.0.1", 14443), timeout=2):
                pass

        try:
            run(f"handler_install {shlex.quote(previous_version)} y y")
            assert version(BINARY) == previous_version
            assert "User=xray" in Path("/etc/systemd/system/xray.service").read_text()
            for user in ("xray", "nginx"):
                groups = subprocess.check_output(["id", "-nG", user], text=True).split()
                assert "xray-nginx" in groups
            print(f"PASS real upstream installation {previous_version}", flush=True)

            # Earlier root-run validation could leave these files inaccessible
            # to User=xray. Verify recovery of that legacy first-install state.
            for name in ("access.log", "error.log"):
                log = Path("/var/log/xray") / name
                log.write_text("")
                log.chmod(0o600)
                os.chown(log, 0, 0)

            # The official installer already starts its initial empty config;
            # activate the newly generated node through the project's restart.
            run("handler_xray_config 1 && handler_restart && handler_start")
            listening()
            assert stat.S_IMODE(RUNTIME.stat().st_mode) == 0o640
            assert all((Path("/var/log/xray") / name).stat().st_uid == pwd.getpwnam("xray").pw_uid
                       for name in ("access.log", "error.log"))
            first_pid = (SERVICE_STATE / "pid").read_text()
            run("handler_restart")
            listening()
            assert (SERVICE_STATE / "pid").read_text() != first_pid
            print("PASS generate, start, restart, listeners and xray account permissions", flush=True)

            before_runtime = RUNTIME.read_bytes()
            before_config = config.read_bytes()
            broken = json.loads(before_config)
            # Xray accepts short non-UUID strings and maps them to UUIDs. Use
            # malformed REALITY key material to exercise actual core rejection.
            broken["xray"]["privateKey"] = "invalid-private-key"
            config.write_text(json.dumps(broken))
            run("handler_xray_config 1", success=False)
            assert RUNTIME.read_bytes() == before_runtime
            config.write_bytes(before_config)
            listening()
            print("PASS invalid generated configuration preserves running configuration", flush=True)

            before_binary = BINARY.read_bytes()
            latest_env = {"XRAY_TEST_ARCHIVE": str(next(latest.glob("Xray-linux-*.zip")))}
            for mode in ("download-fail", "after-install-fail", "version-mismatch"):
                # Also prove that binary permissions survive the replacement.
                BINARY.chmod(0o751)
                requested_version = "v0.0.1" if mode == "version-mismatch" else latest_version
                run(
                    f"handler_install {shlex.quote(requested_version)} y y", success=False,
                    changes=latest_env | {"XRAY_TEST_INSTALL_MODE": mode},
                )
                assert BINARY.read_bytes() == before_binary
                assert stat.S_IMODE(BINARY.stat().st_mode) == 0o751
                assert config.read_bytes() == before_config
                # This assertion must precede any explicit start/restart: the
                # handler itself must recover a service stopped by upstream.
                assert subprocess.run([str(shim), "is-active", "xray"]).returncode == 0
                assert subprocess.run([str(shim), "is-enabled", "xray"]).returncode == 0
                listening()
                print(f"PASS real upgrade failure rollback ({mode})", flush=True)

            run("handler_stop")
            run(
                "handler_install v0.0.1 y y", success=False,
                changes=latest_env,
            )
            assert BINARY.read_bytes() == before_binary
            assert config.read_bytes() == before_config
            assert subprocess.run([str(shim), "is-active", "xray"]).returncode != 0
            assert subprocess.run([str(shim), "is-enabled", "xray"]).returncode != 0
            run("handler_start")
            listening()
            print("PASS failed upgrade preserves previously stopped and disabled state", flush=True)

            run(f"handler_install {shlex.quote(latest_version)} y y", changes=latest_env)
            assert version(BINARY) == latest_version
            assert BINARY.read_bytes() == (latest / "xray").read_bytes()
            assert json.loads(config.read_text())["xray"]["version"] == latest_version
            run("handler_restart")
            listening()
            print(f"PASS real upgrade {previous_version} -> {latest_version}", flush=True)

            transferred = json.loads(config.read_text())
            transferred["xray"].update(tag="ss2022", ss2022Key=base64.b64encode(os.urandom(32)).decode())
            transferred["rules"] = []
            config.write_text(json.dumps(transferred))
            run("handler_xray_config 1 && handler_restart")
            proxy_transfer(work, lambda: run("handler_restart"))
            print("PASS real encrypted SS2022 client -> installed node -> HTTP data transfer", flush=True)

            run("handler_stop")
            run("handler_start", success=False, changes={"XRAY_TEST_SERVICE_FAIL": "start"})
            assert subprocess.run([str(shim), "is-active", "xray"]).returncode != 0
            run("handler_start")
            listening()
            print("PASS service start failure propagation and recovery", flush=True)

            run("handler_purge", terminal=True)
            assert not BINARY.exists()
            assert not RUNTIME.parent.exists()
            assert not Path("/etc/systemd/system/xray.service").exists()
            assert not Path("/usr/local/share/xray").exists()
            assert not Path("/var/log/xray").exists()
            assert subprocess.run([str(shim), "is-active", "xray"]).returncode != 0
            assert json.loads(config.read_text())["xray"]["version"] == ""
            print("PASS confirmed script uninstall removes core, units, geodata, config and logs", flush=True)
        finally:
            subprocess.run([str(shim), "stop", "xray"], check=False)


if __name__ == "__main__":
    main()
