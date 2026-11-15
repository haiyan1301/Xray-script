#!/usr/bin/env python3
"""Exercise actual relay TCP/UDP data paths using temporary local Xray processes.

Usage: python3 tests/check_relay_data_plane.py --xray /path/to/xray
Put geoip.dat and geosite.dat beside the supplied binary. No root, host service,
firewall, external network, or pre-existing Xray configuration is used.

The real handler generates an SS2022 server A in all/domains/off modes. A real
SS2022 client sends requests through A and an independent SOCKS5 server B. Local
HTTP/UDP receivers distinguish B's 127.0.0.2 source from A's 127.0.0.1 source.
Test-only changes bind listeners to loopback/ephemeral ports, disable disk logs,
set domainStrategy=AsIs, and redirect every freedom outbound to a local receiver
while preserving its destination port. freedom.finalRules explicitly permit
loopback for this isolated fixture. Generated private/custom blocking rules,
relay rules, relay outbound, sniffing, and the SS2022 transport remain in use.
These overrides permit public-IP routing tests without contacting that public IP.
"""

import argparse
import base64
from contextlib import ExitStack
import json
import os
from pathlib import Path
import secrets
import shlex
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
PUBLIC_IP = "8.8.8.8"  # A routing input only; freedom.redirect prevents Internet I/O.
RELAY_DOMAIN = "relay.example.test"
BLOCKED_DOMAIN = "blocked.relay.example.test"
DIRECT_SOURCE = "127.0.0.1"
RELAY_SOURCE = "127.0.0.2"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def free_port():
    """Choose a port usable by both TCP and UDP Xray listeners."""
    for _ in range(30):
        with socket.socket() as tcp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            tcp.bind((DIRECT_SOURCE, 0))
            port = tcp.getsockname()[1]
            try:
                udp.bind((DIRECT_SOURCE, port))
            except OSError:
                continue
            return port
    raise RuntimeError("Could not reserve a local TCP/UDP port")


class Receivers:
    def __init__(self):
        self.lock = threading.Lock()
        self.seen = []

    def record(self, transport, peer, payload):
        with self.lock:
            self.seen.append((transport, peer, payload))

    def count(self):
        with self.lock:
            return len(self.seen)

    def __enter__(self):
        receivers = self

        class HTTP(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(3)
                data = b""
                while b"\r\n\r\n" not in data and len(data) < 16384:
                    chunk = self.request.recv(4096)
                    if not chunk:
                        return
                    data += chunk
                receivers.record("tcp", self.client_address[0], data)
                body = json.dumps({"peer": self.client_address[0]}).encode()
                self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " +
                                     str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)

        class UDP(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                receivers.record("udp", self.client_address[0], data)
                body = json.dumps({"peer": self.client_address[0], "payload": data.decode("ascii")}).encode()
                sock.sendto(body, self.client_address)

        self.tcp = socketserver.ThreadingTCPServer((DIRECT_SOURCE, 0), HTTP)
        self.udp = socketserver.ThreadingUDPServer((DIRECT_SOURCE, 0), UDP)
        self.tcp.daemon_threads = self.udp.daemon_threads = True
        self.threads = []
        for server in (self.tcp, self.udp):
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
            thread.start()
            self.threads.append(thread)
        return self

    def __exit__(self, *_):
        for server in (self.tcp, self.udp):
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join(timeout=2)


class Xray:
    def __init__(self, binary, config, path, port, env):
        self.binary, self.config, self.path, self.port, self.env = binary, config, path, port, env
        self.process = None
        self.log = None

    def start(self):
        self.path.write_text(json.dumps(self.config))
        self.path.chmod(0o600)
        result = subprocess.run([str(self.binary), "run", "-test", "-c", str(self.path)],
                                env=self.env, capture_output=True, text=True, timeout=15)
        require(result.returncode == 0, f"Invalid {self.path.name}: {result.stdout}{result.stderr}")
        self.log = self.path.with_suffix(".log").open("w+")
        self.process = subprocess.Popen([str(self.binary), "run", "-c", str(self.path)], env=self.env,
                                        stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.log.seek(0)
                raise RuntimeError(f"{self.path.name} exited: {self.log.read()}")
            with socket.socket() as probe:
                probe.settimeout(0.1)
                if probe.connect_ex((DIRECT_SOURCE, self.port)) == 0:
                    return self
            time.sleep(0.03)
        raise RuntimeError(f"{self.path.name} did not start its listener")

    def close(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=4)
            self.process = None
        if self.log is not None:
            self.log.close()
            self.log = None

    def __enter__(self):
        try:
            return self.start()
        except BaseException:
            self.close()
            raise

    def __exit__(self, exception_type, *_):
        if exception_type is not None and self.log is not None:
            self.log.flush()
            self.log.seek(0)
            print(f"Xray log ({self.path.name}):\n{self.log.read()}", file=sys.stderr)
        self.close()


def exact(sock, length):
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise OSError("Proxy closed the connection")
        data += chunk
    return data


def address_bytes(host):
    try:
        return b"\x01" + socket.inet_aton(host)
    except OSError:
        value = host.encode("ascii")
        return b"\x03" + bytes([len(value)]) + value


def read_address(sock, kind):
    if kind == 1:
        return socket.inet_ntop(socket.AF_INET, exact(sock, 4))
    if kind == 4:
        return socket.inet_ntop(socket.AF_INET6, exact(sock, 16))
    if kind == 3:
        return exact(sock, exact(sock, 1)[0]).decode("ascii")
    raise OSError("Invalid SOCKS address type")


def socks_command(port, command, host, destination_port, timeout):
    sock = socket.create_connection((DIRECT_SOURCE, port), timeout=timeout)
    try:
        sock.settimeout(timeout)
        sock.sendall(b"\x05\x01\x00")
        require(exact(sock, 2) == b"\x05\x00", "SOCKS authentication failed")
        sock.sendall(b"\x05" + bytes([command]) + b"\x00" + address_bytes(host) + struct.pack("!H", destination_port))
        version, status, reserved, kind = exact(sock, 4)
        if version != 5 or status != 0 or reserved != 0:
            raise OSError("SOCKS request rejected")
        address = read_address(sock, kind)
        returned_port = struct.unpack("!H", exact(sock, 2))[0]
        return sock, address, returned_port
    except BaseException:
        sock.close()
        raise


def tcp_request(proxy_port, host, destination_port, http_host=None, timeout=2):
    sock, _, _ = socks_command(proxy_port, 1, host, destination_port, timeout)
    with sock:
        header = http_host or (host if not host[0].isdigit() else "unmatched.example.test")
        sock.sendall(f"GET /{secrets.token_hex(8)} HTTP/1.1\r\nHost: {header}\r\nConnection: close\r\n\r\n".encode())
        data = b""
        while True:
            part = sock.recv(4096)
            if not part:
                break
            data += part
            if b"\r\n\r\n" in data:
                headers, body = data.split(b"\r\n\r\n", 1)
                lengths = [line.split(b":", 1)[1].strip() for line in headers.split(b"\r\n")
                           if line.lower().startswith(b"content-length:")]
                if lengths and len(body) >= int(lengths[0]):
                    break
        if b"\r\n\r\n" not in data:
            raise OSError("No HTTP response")
        return json.loads(data.split(b"\r\n\r\n", 1)[1])["peer"]


def udp_request(proxy_port, host, destination_port, timeout=2):
    control, relay_address, relay_port = socks_command(proxy_port, 3, "0.0.0.0", 0, timeout)
    with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as datagram:
        datagram.settimeout(timeout)
        if relay_address == "0.0.0.0":
            relay_address = DIRECT_SOURCE
        datagram.connect((relay_address, relay_port))
        token = secrets.token_hex(12).encode()
        datagram.send(b"\x00\x00\x00" + address_bytes(host) + struct.pack("!H", destination_port) + token)
        reply = datagram.recv(65535)
        require(len(reply) >= 4 and reply[:3] == b"\x00\x00\x00", "Invalid SOCKS UDP envelope")
        if reply[3] == 1:
            offset = 8
        elif reply[3] == 4:
            offset = 20
        elif reply[3] == 3:
            offset = 5 + reply[4]
        else:
            raise OSError("Invalid SOCKS UDP source")
        result = json.loads(reply[offset + 2:])
        require(result["payload"] == token.decode(), "UDP echo payload was corrupted")
        return result["peer"]


def local_freedom(source):
    return {"tag": "direct", "protocol": "freedom", "sendThrough": source,
            "settings": {"redirect": "127.0.0.1:0", "finalRules": [
                {"action": "allow", "network": "tcp,udp", "ip": ["127.0.0.0/8"]}]}}


def generate_server(mode, state_path, env, a_port, api_port):
    state = json.loads((ROOT / "config.json").read_text())
    key = base64.b64encode(secrets.token_bytes(32)).decode()
    state["language"] = "en"
    state["xray"].update(tag="ss2022", port=a_port, ss2022Key=key,
                         warp=0, reverse=0, vlessEncEnable="n")
    state["xray"]["rules"].update(reset=0, bt=0, cn=0, ad=0)
    state["xray"]["relay"] = {
        "nodes": [{"id": "smoke-b", "name": "Local smoke B", "protocol": "socks",
                   "address": DIRECT_SOURCE, "port": int(env["RELAY_SMOKE_B_PORT"]),
                   "username": "", "password": ""}],
        "active": "smoke-b" if mode != "off" else None, "mode": mode,
        "domains": [f"domain:{RELAY_DOMAIN}", "full:only.example.test"] if mode == "domains" else [],
    }
    state["rules"].append({"ruleTag": "smoke-custom-block", "domain": [f"full:{BLOCKED_DOMAIN}"], "outboundTag": "block"})
    state_path.write_text(json.dumps(state))
    state_path.chmod(0o600)
    body = f"source {shlex.quote(str(ROOT / 'core/handler.sh'))}\n" + """
_XRAY_GENERATE_ONLY=1
_XRAY_RUNTIME_GUARD_DRY_RUN=1
load_i18n
handler_xray_config 1 >&2 || exit $?
printf '%s\\n' "$XRAY_CONFIG"
"""
    result = subprocess.run(["bash", "-c", body], cwd=ROOT, env=env,
                            text=True, capture_output=True, timeout=25)
    require(result.returncode == 0, f"Generator failed ({mode}): {result.stderr}")
    runtime = json.loads(result.stdout)
    require(any(r.get("ruleTag") == "private-ip" for r in runtime["routing"]["rules"]), "Private block was lost")
    require(any(r.get("ruleTag") == "smoke-custom-block" for r in runtime["routing"]["rules"]), "Custom block was lost")
    for inbound in runtime["inbounds"]:
        inbound["listen"] = DIRECT_SOURCE
        if inbound["tag"] == "api":
            inbound["port"] = api_port
    runtime["log"] = {"loglevel": "info"}
    runtime["routing"]["domainStrategy"] = "AsIs"
    runtime["outbounds"] = [local_freedom(DIRECT_SOURCE) if outbound["tag"] == "direct" else outbound
                            for outbound in runtime["outbounds"]]
    client = {
        "log": {"loglevel": "info"},
        "inbounds": [{"tag": "client-socks", "listen": DIRECT_SOURCE, "port": int(env["RELAY_SMOKE_C_PORT"]),
                      "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}],
        "outbounds": [{"tag": "to-a", "protocol": "shadowsocks", "settings": {"servers": [
            {"address": DIRECT_SOURCE, "port": a_port, "method": "2022-blake3-aes-256-gcm", "password": key}]}}],
    }
    return runtime, client


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xray", required=True, type=Path)
    args = parser.parse_args()
    binary = args.xray.resolve(strict=True)
    passed = 0
    with tempfile.TemporaryDirectory(prefix="xray-relay-data-") as directory, Receivers() as receivers, ExitStack() as stack:
        work = Path(directory)
        ports = set()
        while len(ports) < 4:
            ports.add(free_port())
        a_port, api_port, b_port, c_port = ports
        env = os.environ | {"XRAY_LOCATION_ASSET": str(binary.parent), "SCRIPT_CONFIG_PATH_OVERRIDE": str(work / "state.json"),
                            "XRAY_CONFIG_PATH_OVERRIDE": str(work / "unused-runtime.json"),
                            "RELAY_SMOKE_B_PORT": str(b_port), "RELAY_SMOKE_C_PORT": str(c_port)}
        b_config = {"log": {"loglevel": "info"},
                    "inbounds": [{"tag": "b-socks", "listen": DIRECT_SOURCE, "port": b_port, "protocol": "socks",
                                  "settings": {"auth": "noauth", "udp": True}}],
                    "outbounds": [local_freedom(RELAY_SOURCE)]}
        b = stack.enter_context(Xray(binary, b_config, work / "b.json", b_port, env))

        def expect(mode, transport, host, source, *, http_host=None):
            nonlocal passed
            if transport == "tcp":
                actual = tcp_request(c_port, host, receivers.tcp.server_address[1], http_host)
            else:
                actual = udp_request(c_port, host, receivers.udp.server_address[1])
            require(actual == source, f"{mode}/{transport}/{host}: expected source {source}, got {actual}")
            passed += 1
            print(f"PASS {mode}/{transport}/{host}" + (f" Host={http_host}" if http_host else "") + f" via {actual}", flush=True)

        def reject(mode, transport, host, *, timeout=1):
            nonlocal passed
            before = receivers.count()
            try:
                if transport == "tcp":
                    tcp_request(c_port, host, receivers.tcp.server_address[1], timeout=timeout)
                else:
                    udp_request(c_port, host, receivers.udp.server_address[1], timeout=timeout)
            except (OSError, ValueError):
                pass
            else:
                raise RuntimeError(f"{mode}/{transport}/{host}: blocked/downstream request unexpectedly succeeded")
            require(receivers.count() == before, f"{mode}/{transport}/{host}: target received blocked/fallback traffic")
            passed += 1
            spoof = " with HTTP Host=unmatched.example.test" if transport == "tcp" and host == DIRECT_SOURCE else ""
            print(f"PASS {mode}/{transport}/{host}{spoof} rejected; receiver unchanged", flush=True)

        for mode in ("all", "domains", "off"):
            runtime, client = generate_server(mode, work / "state.json", env, a_port, api_port)
            with Xray(binary, runtime, work / f"a-{mode}.json", a_port, env), Xray(binary, client, work / f"c-{mode}.json", c_port, env):
                if mode == "all":
                    cases = [(PUBLIC_IP, RELAY_SOURCE), (RELAY_DOMAIN, RELAY_SOURCE)]
                elif mode == "domains":
                    cases = [(RELAY_DOMAIN, RELAY_SOURCE), ("child." + RELAY_DOMAIN, RELAY_SOURCE),
                             ("only.example.test", RELAY_SOURCE), ("child.only.example.test", DIRECT_SOURCE),
                             ("unmatched.example.test", DIRECT_SOURCE), (PUBLIC_IP, DIRECT_SOURCE)]
                else:
                    cases = [(RELAY_DOMAIN, DIRECT_SOURCE), (PUBLIC_IP, DIRECT_SOURCE)]
                for host, source in cases:
                    for transport in ("tcp", "udp"):
                        expect(mode, transport, host, source)
                if mode == "domains":
                    expect(mode, "tcp", PUBLIC_IP, RELAY_SOURCE, http_host=RELAY_DOMAIN)
                for host in (BLOCKED_DOMAIN, DIRECT_SOURCE):
                    for transport in ("tcp", "udp"):
                        reject(mode + "/block", transport, host)
                if mode == "all":
                    b.close()
                    for transport in ("tcp", "udp"):
                        reject("all/B-down-no-fallback", transport, PUBLIC_IP, timeout=3)
                    b.start()
        print(f"Validated {passed} real TCP/UDP relay assertions using local temporary processes; no remote-host claim.")


if __name__ == "__main__":
    main()
