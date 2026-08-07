#!/bin/bash
# Start headroom proxy + MCP HTTP server
python3.12 -m headroom mcp serve --transport http --host 0.0.0.0 --port 8788 --proxy-url http://localhost:8787 &
exec python3.12 -m headroom proxy --host 0.0.0.0 --port 8787
