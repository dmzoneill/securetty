#!/bin/bash
# Start headroom proxy (HTTP) + MCP HTTP server (HTTPS if certs available)
if [ -f /certs/server.crt ] && [ -f /certs/server.key ]; then
    python3.12 -c "from headroom.cli import main; import sys; sys.argv=['headroom','mcp','serve','--transport','http','--host','0.0.0.0','--port','8788','--proxy-url','http://localhost:8787']; main()" &
    exec python3.12 -c "from headroom.cli import main; import sys; sys.argv=['headroom','proxy','--host','0.0.0.0','--port','8787']; main()"
else
    python3.12 -c "from headroom.cli import main; import sys; sys.argv=['headroom','mcp','serve','--transport','http','--host','0.0.0.0','--port','8788','--proxy-url','http://localhost:8787']; main()" &
    exec python3.12 -c "from headroom.cli import main; import sys; sys.argv=['headroom','proxy','--host','0.0.0.0','--port','8787']; main()"
fi
