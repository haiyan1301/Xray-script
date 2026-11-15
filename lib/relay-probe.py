#!/usr/bin/env python3
"""Bounded real UDP probe through an isolated Xray SOCKS5 inbound.

No node credentials are accepted on the command line. A DNS exchange tests
SOCKS5 UDP ASSOCIATE, rather than mistaking a TCP connection for UDP support.
Exit 0 means this DNS exchange succeeded; it does not certify all UDP ports.
"""
import ipaddress
import secrets
import signal
import socket
import struct
import sys


def receive_exact(sock, count):
    result = b""
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise OSError("SOCKS connection closed")
        result += chunk
    return result


def read_address(sock, atyp):
    if atyp == 1:
        return socket.inet_ntop(socket.AF_INET, receive_exact(sock, 4))
    if atyp == 4:
        return socket.inet_ntop(socket.AF_INET6, receive_exact(sock, 16))
    if atyp == 3:
        length = receive_exact(sock, 1)[0]
        return receive_exact(sock, length).decode("ascii")
    raise OSError("Invalid SOCKS address type")


def probe(port):
    with socket.create_connection(("127.0.0.1", port), timeout=4) as control:
        control.settimeout(4)
        control.sendall(b"\x05\x01\x00")
        if receive_exact(control, 2) != b"\x05\x00":
            raise OSError("SOCKS authentication failed")
        control.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
        version, status, reserved, atyp = receive_exact(control, 4)
        if version != 5 or status != 0 or reserved != 0:
            raise OSError("SOCKS UDP association failed")
        relay_address = read_address(control, atyp)
        relay_port = struct.unpack("!H", receive_exact(control, 2))[0]
        try:
            if ipaddress.ip_address(relay_address).is_unspecified:
                relay_address = "127.0.0.1"
        except ValueError:
            pass
        family = socket.AF_INET6 if ":" in relay_address else socket.AF_INET
        with socket.socket(family, socket.SOCK_DGRAM) as datagram:
            datagram.settimeout(5)
            identifier = secrets.token_bytes(2)
            query = identifier + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
            query += b"\x07example\x03com\x00\x00\x01\x00\x01"
            packet = b"\x00\x00\x00\x01" + socket.inet_aton("1.1.1.1")
            packet += struct.pack("!H", 53) + query
            datagram.connect((relay_address, relay_port))
            datagram.send(packet)
            reply = datagram.recv(65535)
            if len(reply) < 10 or reply[:3] != b"\x00\x00\x00":
                raise OSError("Invalid UDP envelope")
            if reply[3] == 1:
                offset = 8
            elif reply[3] == 4:
                offset = 20
            elif reply[3] == 3:
                offset = 5 + reply[4]
            else:
                raise OSError("Invalid UDP source")
            if len(reply) < offset + 2 or struct.unpack("!H", reply[offset:offset + 2])[0] != 53:
                raise OSError("Invalid UDP source port")
            response = reply[offset + 2:]
            if len(response) < 12 or response[:2] != identifier:
                raise OSError("Invalid DNS response")
            flags, _, answers = struct.unpack("!HHH", response[2:8])
            if not flags & 0x8000 or flags & 0x000F or not answers:
                raise OSError("DNS request did not succeed")


if __name__ == "__main__":
    signal.alarm(12)
    try:
        port_number = int(sys.argv[1])
        if not 1 <= port_number <= 65535:
            raise ValueError("invalid port")
        probe(port_number)
    except (OSError, ValueError, IndexError, UnicodeError, struct.error):
        sys.exit(1)
