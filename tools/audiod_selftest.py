#!/usr/bin/env python3
"""Self-test for cellbridge_audiod's loopback protocol (docs/protocol.md). No call needed.

Needs the Mi 8 Lite on adb with root. Pushes the daemon, starts it, forwards 8766 and checks
that every mixer route is back to Off after each scenario.
"""
import socket
import struct
import subprocess
import sys
import time

PORT, TOKEN = 8766, "selftest-token"
DEV = "/data/local/tmp/cb"
TINYMIX = "/data/local/tmp/ts/tinymix"
ROUTES = ["MultiMedia1 Mixer VOC_REC_DL", "Incall_Music Audio Mixer MultiMedia2"]
AUTH, START, STOP, DL, UL, OK, ERR = 0x00, 0x01, 0x02, 0x10, 0x11, 0x80, 0x81
PERIOD_BYTES = 640


def adb(*args, check=True):
    return subprocess.run(["adb", *args], capture_output=True, text=True, check=check).stdout


def routes_off():
    return all(adb("shell", f"{TINYMIX} get '{r}'").strip().startswith("Off") for r in ROUTES)


def send(s, typ, payload=b""):
    s.sendall(struct.pack("<BH", typ, len(payload)) + payload)


def recv(s):
    head = b""
    while len(head) < 3:
        chunk = s.recv(3 - len(head))
        if not chunk:
            return None, b""
        head += chunk
    typ, n = struct.unpack("<BH", head)
    body = b""
    while len(body) < n:
        body += s.recv(n - len(body))
    return typ, body


def connect():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    return s


def authed():
    s = connect()
    send(s, AUTH, TOKEN.encode())
    assert recv(s)[0] == OK, "auth should succeed"
    return s


def check(name, ok):
    print(("PASS " if ok else "FAIL ") + name)
    return ok


def main():
    adb("push", "android/daemon/build/cellbridge_audiod", "android/daemon/profiles/platina.profile", DEV)
    adb("shell", "pkill -f 'cellbridge_audiod .* serve' || true", check=False)
    adb("shell", f"cd {DEV} && chmod +x cellbridge_audiod && "
                 f"(setsid ./cellbridge_audiod platina.profile serve {TOKEN} > serve.log 2>&1 &)")
    adb("forward", f"tcp:{PORT}", f"tcp:{PORT}")
    time.sleep(1)
    results = []

    s = connect(); send(s, AUTH, b"wrong"); typ, _ = recv(s)
    results.append(check("wrong token -> ERR", typ == ERR)); s.close()

    s = authed(); send(s, START, bytes([1]))
    results.append(check("START dl -> OK", recv(s)[0] == OK))
    t0, frames = time.time(), 0
    while frames < 50:
        typ, body = recv(s)
        if typ != DL or len(body) != PERIOD_BYTES:
            break
        frames += 1
    secs = time.time() - t0
    results.append(check(f"50 DL frames of {PERIOD_BYTES} B in {secs:.2f}s (expect ~1.0s)", frames == 50 and 0.8 < secs < 1.3))
    results.append(check("route on while started", not routes_off()))
    send(s, STOP)
    while True:
        typ, _ = recv(s)
        if typ == OK:
            break
        assert typ == DL, "only DL frames may precede the STOP ack"
    time.sleep(0.2)
    results.append(check("STOP -> routes off", routes_off())); s.close()

    s = authed(); send(s, START, bytes([1])); recv(s); recv(s); s.close()
    time.sleep(1)
    results.append(check("abrupt disconnect -> routes off", routes_off()))

    s = authed(); send(s, START, bytes([3]))
    results.append(check("START dl+ul -> OK", recv(s)[0] == OK))
    send(s, START, bytes([1]))
    while True:
        typ, _ = recv(s)
        if typ != DL:
            break
    results.append(check("second START -> ERR", typ == ERR))
    send(s, UL, b"\0" * 10)
    while True:
        typ, _ = recv(s)
        if typ != DL:
            break
    results.append(check("short UL frame -> ERR", typ == ERR)); s.close()
    time.sleep(1)
    results.append(check("routes off after scenario", routes_off()))

    s = authed(); send(s, UL, b"\0" * PERIOD_BYTES)
    results.append(check("UL frame before START -> ERR", recv(s)[0] == ERR)); s.close()

    adb("shell", "pkill -f 'cellbridge_audiod .* serve' || true", check=False)
    time.sleep(0.5)
    results.append(check("routes off after daemon killed", routes_off()))
    adb("forward", "--remove", f"tcp:{PORT}", check=False)
    print(f"{sum(results)}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
