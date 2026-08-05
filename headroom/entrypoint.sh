#!/bin/bash
# Start headroom proxy + MCP HTTP server
headroom mcp serve --transport http --host 0.0.0.0 --port 8788 --proxy-url http://localhost:8787 &
exec headroom proxy --host 0.0.0.0 --port 8787
