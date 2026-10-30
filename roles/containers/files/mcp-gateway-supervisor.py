#!/usr/bin/env python3
"""MCP Gateway — runs 5 MCP servers in one container on separate ports.

Each server runs in its own process with its skill directory and TLS cert.
Parent monitors children and exits if any die (fail-fast for container restart).
"""

import importlib
import multiprocessing
import os
import signal
import sys
import time

# Bind address for the MCP servers. Defaults to loopback; the compose file sets
# MCP_GATEWAY_BIND_HOST so peers on the internal container network can connect.
BIND_HOST = os.environ.get("MCP_GATEWAY_BIND_HOST", "127.0.0.1")

MCP_SERVICES = [
    {"name": "jira", "port": 8801, "skill_dir": "/mcp/jira", "cert": "mcp-jira"},
    {"name": "gitlab", "port": 8802, "skill_dir": "/mcp/gitlab", "cert": "mcp-gitlab"},
    {"name": "github", "port": 8803, "skill_dir": "/mcp/github", "cert": "mcp-github"},
    {"name": "slack", "port": 8804, "skill_dir": "/mcp/slack", "cert": "mcp-slack"},
    {
        "name": "wordpress",
        "port": 8805,
        "skill_dir": "/mcp/wordpress",
        "cert": "mcp-wordpress",
    },
]


def run_server(svc):
    """Import the skill's MCP server and serve it over TLS on its port."""
    name, port = svc["name"], svc["port"]
    cert = f"/certs/{svc['cert']}.crt"
    key = f"/certs/{svc['cert']}.key"

    sys.path.insert(0, svc["skill_dir"])
    try:
        uvicorn = importlib.import_module("uvicorn")
        mcp = importlib.import_module("server").mcp
        app = mcp.http_app()
        uvicorn.run(
            app,
            host=BIND_HOST,
            port=port,
            ssl_certfile=cert,
            ssl_keyfile=key,
            log_level="warning",
        )
    except (ImportError, AttributeError, OSError, RuntimeError, ValueError) as e:
        print(f"[{name}] FATAL: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    """Start one process per MCP service and stop all if any exits."""
    procs = []

    def shutdown(_signum, _frame):
        for p in procs:
            if p.is_alive():
                p.terminate()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    for svc in MCP_SERVICES:
        proc_name = f"mcp-{svc['name']}"
        p = multiprocessing.Process(target=run_server, args=(svc,), name=proc_name)
        p.start()
        procs.append(p)

    while True:
        time.sleep(5)
        for p in procs:
            if not p.is_alive():
                msg = f"{p.name} died (exit {p.exitcode}), shutting down"
                print(msg, file=sys.stderr)
                for q in procs:
                    if q.is_alive():
                        q.terminate()
                sys.exit(1)


if __name__ == "__main__":
    multiprocessing.set_start_method("spawn", force=True)
    main()
