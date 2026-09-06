"""Entry point so `tina4 serve` boots the Tina4Pascal MCP server.

The tool definitions live in src/routes/tina4pascal.py, which auto-discovers on
startup and mounts the MCP endpoint on the Tina4 router. Run with `tina4 serve`
(host/port come from .env: 127.0.0.1:7146) or `python app.py`.
"""
from tina4_python.core.server import run

if __name__ == "__main__":
    run()
