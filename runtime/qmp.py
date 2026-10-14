#!/usr/bin/env python3
"""Minimal QMP client (stdlib only) used for checkpoint save/restore.

Usage:
  qmp.py SOCK status                 -> prints run state (running/paused/inmigrate/...)
  qmp.py SOCK stop | cont | quit | powerdown
  qmp.py SOCK eject DEVICE_ID        -> force-eject removable media (e.g. cd0)
  qmp.py SOCK save FILE [--mapped-ram]
        stop the VM (if running) and write its full device+RAM state to FILE.
        Writes FILE.caps with the migration capabilities used.
  qmp.py SOCK load FILE              -> restore state into a QEMU started with -incoming defer
  qmp.py SOCK wait-status STATE [TIMEOUT]
  qmp.py SOCK raw JSON               -> send an arbitrary QMP command object
"""
import json
import os
import socket
import sys
import time


class QMP:
    def __init__(self, path, timeout=30.0):
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                self.sock.close()
                if time.time() > deadline:
                    raise SystemExit(f"qmp: socket {path} not available")
                time.sleep(0.1)
        self.buf = b""
        self._read()  # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise SystemExit("qmp: connection closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def cmd(self, name, **args):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        self.sock.sendall(json.dumps(msg).encode() + b"\n")
        while True:
            resp = self._read()
            if "event" in resp:
                continue
            if "error" in resp:
                raise RuntimeError(f"{name}: {resp['error'].get('desc', resp['error'])}")
            return resp.get("return")

    def status(self):
        return self.cmd("query-status")["status"]

    def supported_caps(self):
        return {c["capability"] for c in self.cmd("query-migrate-capabilities")}

    def set_caps(self, caps):
        if caps:
            self.cmd("migrate-set-capabilities",
                     capabilities=[{"capability": c, "state": True} for c in caps])

    def wait_migration(self, timeout=900):
        deadline = time.time() + timeout
        while time.time() < deadline:
            info = self.cmd("query-migrate")
            st = info.get("status", "none")
            if st == "completed":
                return info
            if st in ("failed", "cancelled"):
                raise SystemExit(f"qmp: migration {st}: {info.get('error-desc', '')}")
            time.sleep(0.05)
        raise SystemExit("qmp: migration timed out")


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    sock, action, rest = argv[1], argv[2], argv[3:]
    q = QMP(sock)
    if action == "status":
        print(q.status())
    elif action in ("stop", "cont"):
        q.cmd(action)
    elif action == "quit":
        try:
            q.cmd("quit")
        except SystemExit:
            pass  # QEMU may close the socket before replying
    elif action == "powerdown":
        q.cmd("system_powerdown")
    elif action == "eject":
        try:
            q.cmd("eject", id=rest[0], force=True)
        except RuntimeError as e:  # already empty is fine
            print(f"qmp: eject: {e}", file=sys.stderr)
    elif action == "save":
        path = rest[0]
        want = ["mapped-ram"] if "--mapped-ram" in rest else []
        sup = q.supported_caps()
        caps = [c for c in want if c in sup]
        if want and not caps:
            print("qmp: mapped-ram unsupported by this QEMU, using plain stream", file=sys.stderr)
        if q.status() == "running":
            q.cmd("stop")
        if os.path.exists(path):
            os.unlink(path)
        q.set_caps(caps)
        t0 = time.time()
        q.cmd("migrate", uri=f"file:{path}")
        info = q.wait_migration()
        with open(path + ".caps", "w") as f:
            json.dump({"caps": caps, "total_time_ms": info.get("total-time")}, f)
        print(f"saved {path} in {time.time() - t0:.1f}s "
              f"({os.path.getsize(path) / 2**20:.0f} MiB apparent, caps={caps or 'none'})")
    elif action == "load":
        path = rest[0]
        caps = []
        if os.path.exists(path + ".caps"):
            with open(path + ".caps") as f:
                caps = json.load(f).get("caps", [])
        q.set_caps(caps)
        t0 = time.time()
        q.cmd("migrate-incoming", uri=f"file:{path}")
        # On the destination, query-migrate reports 'completed' once the state is loaded.
        q.wait_migration()
        # Leave the VM paused (-S / source was stopped); orchestrator issues 'cont'.
        print(f"loaded {path} in {time.time() - t0:.1f}s, status={q.status()}")
    elif action == "wait-status":
        want, timeout = rest[0], float(rest[1]) if len(rest) > 1 else 60
        deadline = time.time() + timeout
        while q.status() != want:
            if time.time() > deadline:
                raise SystemExit(f"qmp: status still {q.status()}, wanted {want}")
            time.sleep(0.05)
    elif action == "raw":
        print(json.dumps(q.cmd(**{"name": json.loads(rest[0])["execute"]},
                               **json.loads(rest[0]).get("arguments", {}))))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
