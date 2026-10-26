"""Expose the analyst agent to any MCP client as ONE tool.

The tool is the whole agent: the client sends a question, the agent reasons,
writes Python, runs it (locally or in a Cloud Run sandbox), and the final
answer comes back as the tool result.

Local, over stdio (what Claude Code on your laptop uses):
    claude mcp add adk-analyst -- python mcp_server.py

Networked, over streamable HTTP (what the Cloud Run deploy uses):
    python mcp_server.py --http            # serves http://0.0.0.0:$PORT/mcp
"""
import argparse
import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent / "analyst" / ".env")

from analyst.agent import root_agent  # noqa: E402
from google.adk.tools.mcp_tool import to_mcp_server  # noqa: E402

server = to_mcp_server(
    root_agent,
    name="adk_analyst",
    instructions=(
        "adk_analyst answers questions about an orders dataset by writing and "
        "running Python. Send a plain-English question in `request`."
    ),
)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--http", action="store_true", help="serve streamable HTTP instead of stdio")
    args = ap.parse_args()
    if args.http:
        server.run(
            transport="streamable-http",
            host="0.0.0.0",  # not 127.0.0.1: that arms a localhost-only host allowlist (421s on Cloud Run)
            port=int(os.environ.get("PORT", "8080")),
            streamable_http_path="/mcp",
            # Stateful on purpose: one ADK session per MCP connection, so follow-up
            # questions continue the conversation. Stateless mode leaks a session per
            # call until google/adk-python#7155 merges.
        )
    else:
        server.run(transport="stdio")
