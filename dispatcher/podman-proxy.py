#!/usr/bin/env python3
"""Restricted podman API proxy — exposes only container lifecycle operations
for dispatch jobs. Blocks exec, image management, volume/network changes,
and access to non-dispatch containers.

Sits between the dispatcher and the real podman socket. Dispatcher connects
to this proxy over TCP; proxy forwards allowed requests to the Unix socket."""

import http.client
import json
import os
import re
import socket
import ssl
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler

PODMAN_SOCKET = os.environ.get("PODMAN_SOCKET", "/run/podman/podman.sock")
LISTEN_PORT = int(os.environ.get("PODMAN_PROXY_PORT", "9402"))
ALLOWED_IMAGE = os.environ.get("PODMAN_PROXY_ALLOWED_IMAGE", "securetty_dev")
CONTAINER_PREFIX = os.environ.get("PODMAN_PROXY_PREFIX", "securetty-dispatch-")
MAX_CONTAINERS = int(os.environ.get("PODMAN_PROXY_MAX_CONTAINERS", "10"))

TLS_CERT = os.environ.get("TLS_CERT", "/certs/podman-proxy.crt")
TLS_KEY = os.environ.get("TLS_KEY", "/certs/podman-proxy.key")
TLS_CA = os.environ.get("TLS_CA", "/certs/ca.crt")

_created_ids = set()
_lock = threading.Lock()

# API version prefix pattern
_API_RE = re.compile(r"^/v[\d.]+/libpod")


def _strip_version(path):
    """Remove /vX.Y.Z/libpod prefix, return remainder."""
    m = _API_RE.match(path)
    if m:
        return path[m.end():]
    return path


def _podman_request(method, path, body=None):
    """Forward a request to the real podman socket."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(PODMAN_SOCKET)
    try:
        conn = http.client.HTTPConnection("localhost")
        conn.sock = s
        headers = {"Content-Type": "application/json"} if body else {}
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        return resp.status, dict(resp.getheaders()), data
    finally:
        s.close()


def _count_active():
    """Count running dispatch containers."""
    status, _, data = _podman_request(
        "GET",
        f"/v4.0.0/libpod/containers/json?filters={{\"name\":[\"{CONTAINER_PREFIX}\"]}}",
    )
    if status == 200:
        try:
            return len(json.loads(data))
        except (json.JSONDecodeError, TypeError):
            pass
    return 0


def _validate_create(body_bytes):
    """Validate container create request. Returns (ok, reason)."""
    try:
        body = json.loads(body_bytes)
    except (json.JSONDecodeError, TypeError):
        return False, "invalid JSON body"

    image = body.get("Image", "")
    if ALLOWED_IMAGE not in image:
        return False, f"image {image} not allowed (must contain {ALLOWED_IMAGE})"

    name = body.get("Name", "")
    if not name.startswith(CONTAINER_PREFIX):
        return False, f"container name must start with {CONTAINER_PREFIX}"

    host_config = body.get("HostConfig", {})

    if host_config.get("Privileged"):
        return False, "privileged containers not allowed"

    net_mode = host_config.get("NetworkMode", "")
    if net_mode == "host":
        return False, "host networking not allowed"

    for cap in host_config.get("CapAdd", []):
        return False, f"adding capabilities not allowed: {cap}"

    blocked_mounts = {"/etc/shadow", "/etc/passwd", "/root", "/run/podman"}
    for bind in host_config.get("Binds", []):
        src = bind.split(":")[0]
        if src in blocked_mounts:
            return False, f"mount {src} not allowed"

    with _lock:
        if len(_created_ids) >= MAX_CONTAINERS:
            return False, f"max concurrent dispatch containers ({MAX_CONTAINERS}) reached"

    return True, ""


def _is_owned(container_id):
    """Check if container ID was created through this proxy."""
    with _lock:
        return container_id in _created_ids


class ProxyHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        pass

    def _deny(self, reason="forbidden", status=403):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"error": reason}).encode())

    def _proxy(self, method):
        path = self.path
        normalized = _strip_version(path)

        body = None
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > 0:
            body = self.rfile.read(content_length)

        # --- Route: create container ---
        if method == "POST" and normalized == "/containers/create":
            ok, reason = _validate_create(body)
            if not ok:
                self._deny(reason)
                return
            if _count_active() >= MAX_CONTAINERS:
                self._deny(f"concurrency limit: {MAX_CONTAINERS} dispatch containers running")
                return

            status, headers, data = _podman_request(method, path, body)
            if status in (200, 201):
                try:
                    result = json.loads(data)
                    cid = result.get("Id", "")
                    if cid:
                        with _lock:
                            _created_ids.add(cid)
                            _created_ids.add(cid[:12])
                except (json.JSONDecodeError, TypeError):
                    pass

            self.send_response(status)
            for k, v in headers:
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)
            return

        # --- Route: start/wait/logs/inspect on owned container ---
        m = re.match(r"/containers/([a-f0-9]+)/(start|wait|logs|json)$", normalized)
        if m:
            cid, action = m.group(1), m.group(2)
            if not _is_owned(cid):
                self._deny(f"container {cid[:12]} not managed by this proxy")
                return

            status, headers, data = _podman_request(method, path, body)
            self.send_response(status)
            for k, v in headers:
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)

            if action == "wait":
                with _lock:
                    _created_ids.discard(cid)
                    _created_ids.discard(cid[:12])
            return

        # --- Route: list containers (filtered to dispatch prefix) ---
        if method == "GET" and normalized == "/containers/json":
            filter_param = f'{{"name":["{CONTAINER_PREFIX}"]}}'
            filtered_path = f"{path}{'&' if '?' in path else '?'}filters={filter_param}"
            status, headers, data = _podman_request(method, filtered_path)
            self.send_response(status)
            for k, v in headers:
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)
            return

        # --- Everything else: denied ---
        self._deny(f"operation not allowed: {method} {normalized}")

    def do_GET(self):
        self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def do_PUT(self):
        self._deny("PUT not allowed")

    def do_DELETE(self):
        self._deny("DELETE not allowed")


def main():
    server = HTTPServer(("0.0.0.0", LISTEN_PORT), ProxyHandler)

    if os.path.exists(TLS_CERT) and os.path.exists(TLS_KEY):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(TLS_CERT, TLS_KEY)
        if os.path.exists(TLS_CA):
            ctx.load_verify_locations(TLS_CA)
            ctx.verify_mode = ssl.CERT_REQUIRED
        server.socket = ctx.wrap_socket(server.socket, server_side=True)

    print(f"podman-proxy listening on :{LISTEN_PORT} (prefix={CONTAINER_PREFIX}, max={MAX_CONTAINERS})")
    server.serve_forever()


if __name__ == "__main__":
    main()
