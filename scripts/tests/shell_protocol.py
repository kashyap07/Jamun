#!/usr/bin/env python3
"""Exercise real zsh ZLE over an isolated PTY and a private fake host socket."""
import fcntl
import struct
import termios
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import socket
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ShellProtocol(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="jm-", dir="/tmp")
        self.marker = Path(self.temp.name) / "fallback"
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(self.temp.name + "/s")
        self.listener.listen(1)
        self.listener.settimeout(3)
        self.pid, self.pty = pty.fork()
        if self.pid == 0:
            env = dict(os.environ, JAMUN_SOCKET=self.temp.name + "/s", ZDOTDIR=self.temp.name, TERM="xterm-256color")
            env.pop("JAMUN_DISABLE", None)
            os.execve("/bin/zsh", ["zsh", "-dfi"], env)
        self.addCleanup(self.tearDown)
        fcntl.ioctl(self.pty, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        # Wait until zsh has installed its terminal mode; input sent earlier can
        # be discarded by its startup tcsetattr(TCSAFLUSH).
        time.sleep(0.2)
        if select.select([self.pty], [], [], 0.2)[0]: os.read(self.pty, 65536)
        self.data = b""
        setup = "PS1='test> '; bindkey -e; _fallback() { print -r -- fallback >> " + shlex.quote(str(self.marker)) + "; }; zle -N _fallback; bindkey '^[[A' _fallback; bindkey '^[[B' _fallback; source " + shlex.quote(str(ROOT / "shell/jamun.zsh")) + "\r"
        os.write(self.pty, setup.encode())
        deadline = time.monotonic() + 3
        startup = b""
        while True:
            ready, _, _ = select.select([self.listener, self.pty], [], [], max(0, deadline - time.monotonic()))
            if self.pty in ready: startup += os.read(self.pty, 65536)
            if self.listener in ready:
                self.conn, _ = self.listener.accept()
                break
            if time.monotonic() >= deadline:
                trace = Path(self.temp.name + "/trace")
                self.fail("Shell setup: " + startup.decode(errors="replace") + (trace.read_text()[-12000:] if trace.exists() else ""))
        self.conn.settimeout(2)
        self.until(lambda m: m.get("t") == "hello")
        if self._testMethodName != "test_legacy_host_cannot_capture_keys": self.send("hello", 2)
        self.snapshot = self.until(lambda m: m.get("t") == "edit")

    def tearDown(self):
        if getattr(self, "cleaned", False): return
        self.cleaned = True
        if hasattr(self, "conn"): self.conn.close()
        self.listener.close()
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        os.close(self.pty)
        self.temp.cleanup()

    def until(self, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while b"\n" in self.data:
                raw, self.data = self.data.split(b"\n", 1)
                message = json.loads(raw)
                if message.get("t") == "edit": self.snapshot = message
                if predicate(message): return message
            ready, _, _ = select.select([self.conn, self.pty], [], [], max(0, deadline-time.monotonic()))
            if self.pty in ready: os.read(self.pty, 65536)
            if self.conn in ready:
                chunk = self.conn.recv(65536)
                if not chunk: raise AssertionError("shell unexpectedly disconnected")
                self.data += chunk
        self.fail("timed out waiting for shell frame")

    def send(self, *fields):
        self.conn.sendall(("\t".join(map(str, fields)) + "\n").encode())

    def capture(self, key, sequence):
        self.send("keys", "up,down,tab,enter")
        time.sleep(0.04)
        os.write(self.pty, sequence)
        return self.until(lambda m: m.get("t") == "key" and m.get("key") == key)

    def done(self, key, handled=1): self.send("done", key["keyId"], handled)

    def test_legacy_host_cannot_capture_keys(self):
        self.send("keys", "up,down")
        time.sleep(0.1)
        self.assertEqual(self.conn.recv(65536), b"")
        os.write(self.pty, b"\x1b[A")
        time.sleep(0.1)
        self.assertTrue(self.marker.exists())

    def test_repeated_navigation_and_tab_keep_connection(self):
        for name, sequence in [("down", b"\x1b[B"), ("down", b"\x1b[B"), ("up", b"\x1b[A"), ("tab", b"\t")]:
            key = self.capture(name, sequence)
            self.done(key)
        time.sleep(0.1)
        self.assertFalse(self.marker.exists(), "navigation leaked into the shell widget")

    def test_passthrough_keeps_other_bindings(self):
        key = self.capture("down", b"\x1b[B")
        self.done(key, 0)
        time.sleep(0.1)
        self.assertTrue(self.marker.exists())
        # No rebind: the next key must still arrive at the host.
        os.write(self.pty, b"\x1b[A")
        key = self.until(lambda m: m.get("t") == "key" and m.get("key") == "up")
        self.done(key)

    def test_timeout_replays_original_widget_and_disconnects(self):
        self.capture("down", b"\x1b[B")
        time.sleep(0.45)
        self.assertTrue(self.marker.exists())
        self.assertEqual(self.conn.recv(65536), b"")

    def test_unicode_literal_edit_and_stale_rejection(self):
        os.write(self.pty, "cat 🍇".encode())
        self.until(lambda m: m.get("t") == "edit" and m.get("buf") == "cat 🍇")
        key = self.capture("enter", b"\r")
        value = "'a b;$(printf BAD)🍇\n'"
        escape = lambda text: "v" + text.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
        self.send("insert", "ok", key["keyId"], self.snapshot["rev"], self.snapshot["cur"], int(time.time()*1000)+1500, 1, 0, 0, escape(self.snapshot["buf"]), escape(value))
        ack = self.until(lambda m: m.get("t") == "editAck")
        self.assertTrue(ack["accepted"])
        edit = self.until(lambda m: m.get("t") == "edit")
        self.assertEqual(edit["buf"], "cat " + value)
        self.assertEqual(edit["cur"], len("cat " + value))
        self.done(key)
        key = self.capture("down", b"\x1b[B")
        self.send("insert", "stale", key["keyId"], 0, 0, int(time.time()*1000)+1500, 0, 0, 0, "vwrong", "vbad")
        ack = self.until(lambda m: m.get("t") == "editAck")
        self.assertFalse(ack["accepted"])
        self.done(key)
        time.sleep(0.1)
        self.assertTrue(self.marker.exists(), "rejected edit returns the original key")

if __name__ == "__main__": unittest.main(verbosity=2)
