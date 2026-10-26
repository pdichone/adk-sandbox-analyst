"""One container, two front doors: the ADK API server and an MCP endpoint.

Used by `deploy.sh mcp` (gcloud beta run deploy --source . --sandbox-launcher).
`adk deploy cloud_run` does not use this file; it generates its own entrypoint
that runs `adk api_server` only.

Routes:
    /list-apps, /apps/..., /run_sse   the ADK API server, same as `adk api_server`
    /mcp                              the agent as one MCP tool (streamable HTTP)
"""
import os
from contextlib import asynccontextmanager
from pathlib import Path

import uvicorn
from google.adk.cli.fast_api import get_fast_api_app

from mcp_server import server  # builds the agent + MCP server at import time

HERE = Path(__file__).resolve().parent
PORT = int(os.environ.get("PORT", "8080"))

# Two traps, both verified on MCP SDK 2.3.0:
# 1. host="0.0.0.0" is required. Without it the SDK arms DNS-rebinding
#    protection for localhost only and every request on Cloud Run gets
#    421 Misdirected Request.
# 2. A Starlette sub-app's lifespan never runs when it is mounted, so the MCP
#    session manager has to be started from the outer app's lifespan.
mcp_app = server.streamable_http_app(streamable_http_path="/mcp", host="0.0.0.0")


@asynccontextmanager
async def lifespan(_app):
    async with mcp_app.router.lifespan_context(mcp_app):
        yield


adk_app = get_fast_api_app(
    agents_dir=str(HERE),
    web=False,
    use_local_storage=False,  # in-memory sessions; Cloud Run's agents dir is read-only anyway
    host="0.0.0.0",
    port=PORT,
    lifespan=lifespan,
)


async def app(scope, receive, send):
    """Hand /mcp to the MCP app untouched (no Mount, so no path rewriting or
    trailing-slash redirects); everything else, including lifespan, to ADK."""
    if scope["type"] == "http" and scope["path"].startswith("/mcp"):
        await mcp_app(scope, receive, send)
    else:
        await adk_app(scope, receive, send)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)
