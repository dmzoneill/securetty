#!/usr/bin/env python3
"""HMAC-authenticated SSH agent proxy.

Host side: listens on a Unix socket, validates HMAC token from client,
then bridges to the real SSH agent socket. Container must present the
correct token (derived from a shared secret) before any SSH operations
are proxied.

Protocol:
  1. Client sends token line (hex string + newline)
  2. Proxy validates via hmac.compare_digest against the token file
  3. On success, remaining bytes (and all subsequent data) are bridged
     bidirectionally to the real SSH agent socket
  4. On failure, connection is silently closed

Based on carbonite's macos_proxy_agent.py pattern.

Environment:
  SSH_AUTH_SOCK_REAL  - path to the real SSH agent socket
  SSH_PROXY_SOCK     - path for proxy listen socket (default: /run/user/UID/securetty-ssh-proxy.sock)
  SSH_PROXY_TOKEN_FILE - path to file containing the shared token
"""

import hmac
import os
import select
import signal
import socket
import sys

__all__ = [
    "bridge",
    "connect_agent",
    "handle_client",
    "main",
    "read_file",
]

AGENT_SOCK = os.environ.get("SSH_AUTH_SOCK_REAL", "")
LISTEN_SOCK = os.environ.get(
    "SSH_PROXY_SOCK",
    "/run/user/{}/securetty-ssh-proxy.sock".format(os.getuid()),
)
TOKEN_FILE = os.environ.get(
    "SSH_PROXY_TOKEN_FILE",
    "/run/user/{}/securetty-ssh-token".format(os.getuid()),
)


def read_file(path):
    """Read and strip a single-line file."""
    with open(path) as f:
        return f.read().strip()


def bridge(sock_a, sock_b):
    """Bidirectionally forward data between two sockets until one closes."""
    try:
        while True:
            readable, _, _ = select.select([sock_a, sock_b], [], [], 30)
            if not readable:
                continue
            for s in readable:
                data = s.recv(4096)
                if not data:
                    return
                dst = sock_b if s is sock_a else sock_a
                dst.sendall(data)
    except (OSError, BrokenPipeError):
        pass


def connect_agent(agent_sock):
    """Connect to the real SSH agent socket."""
    agent = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        agent.connect(agent_sock)
        return agent
    except (OSError, FileNotFoundError):
        agent.close()
        return None


def handle_client(conn, token_file, agent_sock):
    """Authenticate and bridge a single client connection."""
    try:
        conn.settimeout(5)
        raw = b""
        while b"\n" not in raw and len(raw) < 256:
            chunk = conn.recv(256)
            if not chunk:
                return
            raw += chunk
        conn.settimeout(None)

        client_token = raw.split(b"\n", 1)[0].decode("utf-8", errors="replace")
        expected = read_file(token_file)
        if not hmac.compare_digest(client_token, expected):
            return

        remainder = raw.split(b"\n", 1)[1] if b"\n" in raw else b""

        agent = connect_agent(agent_sock)
        if agent is None:
            return

        if remainder:
            agent.sendall(remainder)

        bridge(conn, agent)
        agent.close()
    except Exception:
        pass
    finally:
        conn.close()


def main():
    if not AGENT_SOCK:
        print("SSH_AUTH_SOCK_REAL required", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(TOKEN_FILE):
        print(f"Token file not found: {TOKEN_FILE}", file=sys.stderr)
        sys.exit(1)

    # Remove stale socket
    try:
        os.unlink(LISTEN_SOCK)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(LISTEN_SOCK)
    os.chmod(LISTEN_SOCK, 0o600)
    server.listen(5)
    print(f"SSH proxy listening on {LISTEN_SOCK}", flush=True)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    def _reap_children(*_):
        try:
            while True:
                os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            pass

    signal.signal(signal.SIGCHLD, _reap_children)

    while True:
        try:
            conn, _ = server.accept()

            pid = os.fork()
            if pid == 0:
                server.close()
                handle_client(conn, TOKEN_FILE, AGENT_SOCK)
                os._exit(0)
            else:
                conn.close()
        except KeyboardInterrupt:
            break

    # Cleanup
    try:
        os.unlink(LISTEN_SOCK)
    except FileNotFoundError:
        pass


if __name__ == "__main__":
    main()
