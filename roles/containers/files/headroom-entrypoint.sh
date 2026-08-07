#!/bin/bash
# Start headroom proxy + MCP HTTP server
python3.12 -c "from headroom.cli import main; import sys; sys.argv=['headroom','mcp','serve','--transport','http','--host','0.0.0.0','--port','8788','--proxy-url','http://localhost:8787']; main()" &
exec python3.12 -c "from headroom.cli import main; import sys; sys.argv=['headroom','proxy','--host','0.0.0.0','--port','8787']; main()"
