#!/usr/bin/env python3
"""Compare raw mDNS multicast with and without local loopback (synthetic data).

No DNSService registrations, account identities, or file transfers. Requires
the compiled self-discovery-observer next to the compiled scope probe. This
is an announcement-only diagnostic, not a replacement for an mDNS responder.
"""
import ipaddress
from pathlib import Path
import re
import socket
import struct
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
TYPES = ("_appSvcPrePair._tcp.local.", "_applicationServicePairing._tcp.local.")


def name(value):
    labels = value.rstrip(".").split(".")
    return b"".join(bytes([len(label.encode())]) + label.encode() for label in labels) + b"\0"


def record(owner, kind, value, ttl=10, unique=False):
    return name(owner) + struct.pack("!HHIH", kind, 0x8001 if unique else 1, ttl, len(value)) + value


def response(instance, host, address, ttl=10):
    records = []
    for service in TYPES:
        fullname = instance + "." + service
        txt = [b"sn=pl.aimdrop.self-discovery-probe", b"sid=" + instance.encode()]
        records.extend([
            record(service, 12, name(fullname), ttl),
            record(fullname, 33, struct.pack("!HHH", 0, 0, 9) + name(host), ttl, True),
            record(fullname, 16, b"".join(bytes([len(item)]) + item for item in txt), ttl, True),
        ])
    records.append(record(host, 28, ipaddress.IPv6Address(address).packed, ttl, True))
    return struct.pack("!HHHHHH", 0, 0x8400, 0, len(records), 0, 0) + b"".join(records)


def main():
    prefix = "ADProbe-" + uuid.uuid4().hex[:10]
    observer = subprocess.Popen([str(ROOT / ".build/self-discovery/observer"), prefix],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output_lines = []
    started = threading.Event()
    def collect():
        for line in observer.stdout:
            output_lines.append(line)
            if line.strip() == "observer_started":
                started.set()
    reader = threading.Thread(target=collect, daemon=True)
    reader.start()
    sockets = []
    try:
        if not started.wait(15):
            raise RuntimeError("Observer did not start within 15 seconds")
        interfaces = subprocess.check_output(["/sbin/ifconfig", "-l"], text=True).split()
        for interface in interfaces:
            if interface != "awdl0" and not re.fullmatch(r"en[0-9]+", interface):
                continue
            config = subprocess.check_output(["/sbin/ifconfig", interface], text=True)
            address = re.search(r"inet6 (fe80:[0-9a-f:]+)%", config)
            if not address or "status: active" not in config:
                continue
            index = socket.if_nametoindex(interface)
            sender = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
            sender.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sender.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            sender.setsockopt(socket.SOL_SOCKET, 0x1104, 1)  # Darwin SO_RECV_ANYIF: AWDL.
            sender.bind((address[1], 5353, 0, index))
            sender.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, index)
            sender.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
            sender.settimeout(1)
            sockets.append((sender, interface, index, address[1]))
        if not sockets:
            raise RuntimeError("No active link-local multicast interface")
        time.sleep(1)
        for _ in range(3):
            for sender, interface, index, address in sockets:
                for loopback in (True, False):
                    sender.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_LOOP, int(loopback))
                    instance = prefix + ("-loop" if loopback else "-remote")
                    packet = response(instance, instance.lower() + ".local.", address)
                    try:
                        sender.sendto(packet, ("ff02::fb", 5353, 0, index))
                        print(f"sent interface={interface} loopback={int(loopback)} bytes={len(packet)}")
                    except OSError as error:
                        print(f"send_failed interface={interface} loopback={int(loopback)} error={type(error).__name__} errno={error.errno}")
            time.sleep(1)
        observer.wait(timeout=15)
        reader.join(timeout=2)
        output = "".join(output_lines)
        print(output, end="")
        if observer.returncode:
            raise RuntimeError(f"Observer exited {observer.returncode}")
        loop_seen = f"name={prefix}-loop " in output
        remote_seen = f"name={prefix}-remote " in output
        print(f"result baseline_visible={int(loop_seen)} remote_only_visible={int(remote_seen)}")
        if not loop_seen:
            raise RuntimeError("Inconclusive: loopback baseline was not discovered")
    finally:
        for sender, interface, index, address in sockets:
            for loopback in (True, False):
                instance = prefix + ("-loop" if loopback else "-remote")
                sender.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_LOOP, int(loopback))
                try:
                    sender.sendto(response(instance, instance.lower() + ".local.", address, ttl=0),
                                  ("ff02::fb", 5353, 0, index))
                except OSError:
                    pass
            sender.close()
        if observer.poll() is None:
            observer.terminate()
            observer.wait(timeout=5)
        reader.join(timeout=2)


if __name__ == "__main__":
    main()
