#!/usr/bin/env python3
"""Check one lab console WebSocket endpoint (noVNC gateway) without a browser.

Usage: console_check.py URL [--origin ORIGIN] [--no-origin]
URL is a console URL as printed by ./lab console, for example
http://127.0.0.1:6111/vnc.html#...&path=websockify%3Ftoken%3D...
The script opens ws://HOST:PORT/<path> with the Origin of the URL (or --origin) and prints one
line: "accepted RFB <version>" (exit 0) or "rejected <reason>" (exit 1).
It never prints the token.
"""

import argparse
import base64
import os
import socket
import sys
import urllib.parse


def ws_path(url):
    """Return the WebSocket request path that noVNC builds from the console URL."""
    parts = urllib.parse.urlsplit(url)
    params = urllib.parse.parse_qs(parts.query)
    params.update(urllib.parse.parse_qs(parts.fragment))
    path = params.get("path", ["websockify"])[0]
    return "/" + path.lstrip("/")


def read_frame(sock):
    """Read one server WebSocket frame (unmasked) and return its payload."""
    head = sock.recv(2)
    if len(head) < 2:
        return b""
    length = head[1] & 0x7F
    if length == 126:
        length = int.from_bytes(sock.recv(2), "big")
    elif length == 127:
        length = int.from_bytes(sock.recv(8), "big")
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            break
        data += chunk
    return data


def check(url, origin):
    parts = urllib.parse.urlsplit(url)
    host, port = parts.hostname, parts.port or 80
    key = base64.b64encode(os.urandom(16)).decode()
    lines = [
        f"GET {ws_path(url)} HTTP/1.1",
        f"Host: {host}:{port}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        f"Sec-WebSocket-Key: {key}",
        "Sec-WebSocket-Version: 13",
        "Sec-WebSocket-Protocol: binary",
    ]
    if origin:
        lines.append(f"Origin: {origin}")
    request = ("\r\n".join(lines) + "\r\n\r\n").encode()
    try:
        with socket.create_connection((host, port), timeout=10) as sock:
            sock.sendall(request)
            response = b""
            while b"\r\n\r\n" not in response:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                response += chunk
            status = response.split(b"\r\n", 1)[0].decode(errors="replace")
            if " 101 " not in status + " ":
                return False, status or "connection closed without a response"
            banner = read_frame(sock)
    except OSError as exc:
        return False, f"connection error: {exc}"
    if banner.startswith(b"RFB "):
        return True, "RFB " + banner[4:11].decode(errors="replace")
    return False, "upgraded, but no RFB banner (target not reachable)"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("url")
    parser.add_argument("--origin", help="Origin header (default: scheme://host:port of URL)")
    parser.add_argument("--no-origin", action="store_true", help="send no Origin header")
    args = parser.parse_args()
    parts = urllib.parse.urlsplit(args.url)
    origin = None if args.no_origin else args.origin or f"{parts.scheme}://{parts.netloc}"
    accepted, detail = check(args.url, origin)
    print(("accepted " if accepted else "rejected ") + detail)
    return 0 if accepted else 1


if __name__ == "__main__":
    sys.exit(main())
