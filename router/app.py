#!/usr/bin/env python3
import secrets
import socket
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

# (container host, container port, public port)
BACKENDS = [
    ("novnc1", 6080, 6081),
    ("novnc2", 6080, 6082),
    ("novnc3", 6080, 6083),
    ("novnc4", 6080, 6084),
    ("novnc5", 6080, 6085),
]

_state = {"index": 0, "sessions": {}}
SESSION_TTL_SECONDS = 1800


def _reachable(host, port, timeout=0.3):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _cleanup_sessions(now):
    stale = [k for k, v in _state["sessions"].items() if now - v["last_seen"] > SESSION_TTL_SECONDS]
    for k in stale:
        del _state["sessions"][k]


def _allocate_session():
    now = time.time()
    _cleanup_sessions(now)

    if len(_state["sessions"]) >= len(BACKENDS):
        return None, None

    n = len(BACKENDS)
    start = _state["index"]
    for i in range(n):
        idx = (start + i) % n
        host, port, public_port = BACKENDS[idx]
        if not _reachable(host, port):
            continue

        in_use = any(v["public_port"] == public_port for v in _state["sessions"].values())
        if in_use:
            continue

        token = secrets.token_urlsafe(16)
        _state["index"] = (idx + 1) % n
        _state["sessions"][token] = {
            "public_port": public_port,
            "last_seen": now,
            "ip_ua": None,
        }
        return token, public_port

    return None, None


def _get_token(path):
    query = urlparse(path).query
    params = parse_qs(query)
    return params.get("token", [None])[0]


def _ip_ua(handler):
    ip = handler.client_address[0]
    ua = handler.headers.get("User-Agent", "")
    return f"{ip}|{ua}"


class Handler(BaseHTTPRequestHandler):
    def _log(self, message):
        print(message, flush=True)

    def do_GET(self):
        if self.path.startswith("/heartbeat"):
            token = _get_token(self.path)
            now = time.time()
            _cleanup_sessions(now)
            if token in _state["sessions"] and _state["sessions"][token]["ip_ua"] == _ip_ua(self):
                _state["sessions"][token]["last_seen"] = now
                self._log(f"heartbeat ok token={token[:8]}")
                self.send_response(204)
                self.end_headers()
                return
            self._log(f"heartbeat missing token={token}")
            self.send_response(404)
            self.end_headers()
            return

        token, public_port = _allocate_session()
        if public_port is None:
            self._log("no desktops available")
            self.send_response(503)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"<html><body><h1>No desktops available</h1></body></html>")
            return
        _state["sessions"][token]["ip_ua"] = _ip_ua(self)
        host = self.headers.get("Host", "localhost")
        host_only = host.split(":")[0]
        target = f"http://{host_only}:{public_port}/vnc.html?token={token}"
        self._log(f"assign token={token[:8]} port={public_port} host={host_only}")
        self.send_response(302)
        self.send_header("Location", target)
        self.end_headers()

    def log_message(self, fmt, *args):
        return


def main():
    server = HTTPServer(("0.0.0.0", 8080), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
