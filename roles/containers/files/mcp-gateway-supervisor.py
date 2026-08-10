#!/usr/bin/env python3
"""MCP Gateway — runs 5 MCP servers in one container on separate ports.

Each server runs in its own process with its skill directory and TLS cert.
Parent monitors children and exits if any die (fail-fast for container restart).
"""

import multiprocessing
import os
import signal
import sys
import time

MCP_SERVICES = [
    {"name": "jira", "port": 8801, "skill_dir": "/mcp/jira", "cert": "mcp-jira"},
    {"name": "gitlab", "port": 8802, "skill_dir": "/mcp/gitlab", "cert": "mcp-gitlab"},
    {"name": "github", "port": 8803, "skill_dir": "/mcp/github", "cert": "mcp-github"},
    {"name": "slack", "port": 8804, "skill_dir": "/mcp/slack", "cert": "mcp-slack"},
    {"name": "wordpress", "port": 8805, "skill_dir": "/mcp/wordpress", "cert": "mcp-wordpress"},
]


def run_server(svc):
    name, port = svc["name"], svc["port"]
    cert = f"/certs/{svc['cert']}.crt"
    key = f"/certs/{svc['cert']}.key"

    sys.path.insert(0, svc["skill_dir"])
    try:
        from server import mcp
        import uvicorn

        app = mcp.http_app()
        uvicorn.run(app, host="0.0.0.0", port=port, ssl_certfile=cert, ssl_keyfile=key, log_level="warning")
    except Exception as e:
        print(f"[{name}] FATAL: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    procs = []

    def shutdown(signum, frame):
        for p in procs:
            if p.is_alive():
                p.terminate()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    for svc in MCP_SERVICES:
        p = multiprocessing.Process(target=run_server, args=(svc,), name=f"mcp-{svc['name']}")
        p.start()
        procs.append(p)

    while True:
        time.sleep(5)
        for p in procs:
            if not p.is_alive():
                print(f"{p.name} died (exit {p.exitcode}), shutting down", file=sys.stderr)
                for q in procs:
                    if q.is_alive():
                        q.terminate()
                sys.exit(1)


if __name__ == "__main__":
    multiprocessing.set_start_method("spawn", force=True)
    main()
