# adk-sandbox-analyst

An Agent Development Kit (ADK) agent that answers data questions by **writing and running its own Python**, deployed to Cloud Run where that code runs inside a **Cloud Run sandbox** (no network, no secrets, no metadata server, read-only filesystem), and exposed to **Claude Code as one MCP tool**. Companion repo to the video *Your ADK agent can run its own code now (safely, on Cloud Run)*.

Three things that shipped in ADK 2.x make this possible, and this repo is the first place they are wired together:

| Piece | Where | Since |
|---|---|---|
| `CloudRunSandboxCodeExecutor` | `google.adk.integrations.cloud_run` | ADK 2.5.0 (Jul 16, 2026) |
| `adk deploy cloud_run --with_cloud_run_sandbox` | runs `gcloud beta run deploy … --sandbox-launcher` for you | ADK 2.6.3 (Aug 7, 2026) |
| `to_mcp_server()` | `google.adk.tools.mcp_tool` | ADK 2.5.0; HTTP transport verified on 2.11.0, source unchanged in 2.12.0 |

Cloud Run sandboxes are in **preview** (announced July 9, 2026). The container, the launcher and the sandbox are Google's; this repo is the glue.

## What's in here

```
analyst/
  agent.py           root_agent: Gemini + an instruction + code_executor=pick_executor()
  executors.py       8 lines: Cloud Run sandbox when K_SERVICE is set, local executor otherwise
  data/orders.csv    2,000 synthetic orders (median order_total = 34.09)
  requirements.txt   what the adk-generated image installs on top of ADK
mcp_server.py        to_mcp_server(root_agent): stdio by default, --http for streamable HTTP on /mcp
main.py              one container, two front doors: ADK API server + /mcp (used by deploy.sh mcp)
Dockerfile           for deploy.sh mcp (mirrors the image adk deploy generates, entrypoint main.py)
setup.sh             one-time: APIs, Cloud Build role, Gemini key into Secret Manager
deploy.sh            ./deploy.sh (adk deploy) or ./deploy.sh mcp (gcloud --source, with /mcp)
test.sh              list-apps, create session, run_sse, with an identity token
CLEANRUN.md          the gate: what must pass from a fresh clone before this is "done"
```

## 1. Run it locally first (2 minutes)

```bash
git clone https://github.com/pdichone/adk-sandbox-analyst.git
cd adk-sandbox-analyst
python3 -m venv .venv && source .venv/bin/activate     # Python 3.11+
pip install -r requirements.txt                        # google-adk[mcp] 2.12+, mcp 2.x
cp analyst/.env.example analyst/.env                   # put your Gemini API key in it
adk web                                                # http://localhost:8000, pick "analyst"
```

Ask: *What is the median order value? Show a histogram of order totals.* The agent writes a ```python block, ADK runs it, the output comes back, and the answer is 34.09 with a text histogram. Locally the code runs through `UnsafeLocalCodeExecutor`, on your machine, unsandboxed. That is the whole reason the next step exists.

The switch is `analyst/executors.py`:

```python
def pick_executor():
    if os.environ.get("K_SERVICE"):            # set by Cloud Run
        from google.adk.integrations.cloud_run import CloudRunSandboxCodeExecutor
        return CloudRunSandboxCodeExecutor(timeout_seconds=120)
    return UnsafeLocalCodeExecutor()
```

`CloudRunSandboxCodeExecutor` shells out to `/usr/local/gcp/bin/sandbox`, a binary that only exists inside a Cloud Run instance deployed with the sandbox launcher. Anywhere else it returns `Sandbox binary … not found` to the model, so the switch is not optional. (`BuiltInCodeExecutor`, Gemini's own server-side sandbox, also works locally, but it cannot share an agent with other tools; the local executor can.)

## 2. One-time project setup

You need a Google Cloud project with billing, `gcloud` 588 or newer (`gcloud components update`; the beta component must be from October 2026 or later to know `--sandbox-launcher`), and a Gemini API key.

```bash
export GOOGLE_CLOUD_PROJECT=your-project-id
export GOOGLE_CLOUD_LOCATION=us-central1
export GOOGLE_API_KEY=your-gemini-key
./setup.sh
```

That enables Cloud Run, Cloud Build, Artifact Registry and Secret Manager, gives the default compute service account the Cloud Build role (ADK builds with Cloud Build), and stores the key in Secret Manager as `GOOGLE_API_KEY` with `secretAccessor` for that account. The key never goes in the image or the repo.

## 3. Deploy with the sandbox launcher (one command)

```bash
./deploy.sh
```

which is

```bash
adk deploy cloud_run \
  --project=$GOOGLE_CLOUD_PROJECT --region=$GOOGLE_CLOUD_LOCATION \
  --service_name=adk-analyst --app_name=analyst \
  --with_cloud_run_sandbox \
  ./analyst \
  -- --no-allow-unauthenticated --max-instances=1 --memory=2Gi \
     --update-secrets=GOOGLE_API_KEY=GOOGLE_API_KEY:latest
```

`--with_cloud_run_sandbox` makes ADK run `gcloud beta run deploy … --sandbox-launcher` instead of plain `gcloud run deploy`. Do not pass `--sandbox-launcher` yourself after `--`; ADK manages that flag and rejects a duplicate. Everything after `--` goes to gcloud untouched. The first build takes 3 to 6 minutes.

Test it:

```bash
./test.sh
```

It fetches the service URL, mints an identity token (valid 60 minutes), lists apps, creates a session, and posts the median question to `/run_sse`. You see the code the agent wrote, the sandbox output, and the answer. Then the proof it ran in a sandbox: Cloud Run logs sandbox lifecycle events, so

```bash
gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=adk-analyst AND textPayload:"sandbox do"' --limit=5 --freshness=10m
```

shows the sandbox start and exit for that request.

## 4. Prove the isolation (30 seconds)

```bash
./test.sh "Write Python that fetches https://example.com with urllib and prints the first 100 bytes."
./test.sh "Diagnostic: run exactly this program and show its raw output. import os; print(len(os.environ)); print(sorted(os.environ))"
```

The first fails: outbound traffic from a sandbox is denied unless the executor is built with `allow_egress=True`. The second prints `2` and `['HOME', 'LC_CTYPE']`: the sandbox starts with two environment variables, none of the service's (`GOOGLE_API_KEY`, `GOOGLE_CLOUD_PROJECT`, `K_SERVICE`, `PORT` are all absent). Ask for names and counts, not values: Gemini refuses prompts that name a secret's value regardless of instruction.

## 5. Call it from Claude Code

### Local, over stdio

```bash
claude mcp add adk-analyst -- "$PWD/.venv/bin/python" "$PWD/mcp_server.py"
claude
```

`/mcp` shows **one** tool, `adk_analyst`, with one argument, `request`. Ask Claude Code: *Use adk_analyst to find the median order value and show the distribution.* Claude Code calls the tool, the ADK agent runs its full loop (reason, write Python, execute, answer), and the final answer is the tool result. The agent's reasoning does not leak into Claude Code's context as separate tools; that is what `to_mcp_server` gives you over exposing functions one by one. One ADK session is kept per MCP connection, so a follow-up ("now by region") continues the same conversation.

The ADK docs show `to_mcp_server` with `app.run()` over stdio only. Two things they do not show, both verified on ADK 2.11.0 and MCP SDK 2.3.0:

### Deployed, over streamable HTTP

`to_mcp_server` returns the MCP SDK's server object, and `server.run(transport="streamable-http", host="0.0.0.0", port=PORT)` serves `/mcp`. `main.py` mounts that app next to ADK's own API server so one Cloud Run service answers on both. Deploy it:

```bash
./deploy.sh mcp
```

(`gcloud beta run deploy --source . --sandbox-launcher`, our Dockerfile, entrypoint `main.py`.) Two traps in `main.py`, both verified on MCP SDK 2.3.0: `streamable_http_app()` must get `host="0.0.0.0"`, otherwise the SDK arms a localhost-only host allowlist and every request on Cloud Run answers `421 Misdirected Request`; and a Starlette sub-app's lifespan never runs when mounted, so the MCP session manager is started from the outer lifespan and `/mcp` is handed to the MCP app by a five-line ASGI dispatcher instead of a `Mount` (a `Mount` also turns `/mcp` into a 307 to `/mcp/`).

Then connect Claude Code to the cloud:

```bash
export ADK_URL=$(gcloud run services describe adk-analyst --region $GOOGLE_CLOUD_LOCATION --format 'value(status.url)')
export ADK_ID_TOKEN=$(gcloud auth print-identity-token)
claude mcp add --transport http adk-analyst-cloud "$ADK_URL/mcp" \
  --header 'Authorization: Bearer ${ADK_ID_TOKEN}'
claude
```

Single quotes matter: Claude Code expands `${ADK_ID_TOKEN}` from the environment at startup, so the config holds the placeholder, not the token. Identity tokens last 60 minutes. For a setup that outlives that, put the server in `.mcp.json` with a `headersHelper`, which Claude Code re-runs on every connection and after any 401:

```json
{
  "mcpServers": {
    "adk-analyst-cloud": {
      "type": "http",
      "url": "${ADK_URL}/mcp",
      "headersHelper": "echo '{\"Authorization\": \"Bearer '\"$(gcloud auth print-identity-token)\"'\"}'",
      "timeout": 600000
    }
  }
}
```

(`timeout` is the per-call limit in milliseconds; a sandbox run takes 20 to 60 seconds, and ADK streams the agent's intermediate text as MCP progress notifications, so the idle timer never trips.) If you would rather not deal with tokens at all, `gcloud run services proxy adk-analyst --region $GOOGLE_CLOUD_LOCATION --port 8080` authenticates for you and the URL becomes `http://localhost:8080/mcp`.

Same prompt, same tool, except the Python now runs in a sandbox in the cloud with no network and no secrets, and Claude Code never needed to know that.

## Extend it

- **Real data:** replace the CSV with a BigQuery query. The sandbox blocks egress, so build the executor with `CloudRunSandboxCodeExecutor(allow_egress=True)` and give the service account BigQuery read; the model's code still cannot see the key or the metadata server.
- **Memory:** add `--session_service_uri=agentengine://…` (or a SQLAlchemy URL) to `deploy.sh`; without it sessions live in memory and vanish when the instance recycles.
- **Agent-to-agent:** `adk deploy cloud_run … --a2a` exposes the same agent over A2A for another agent to call, the way `/mcp` exposes it for an IDE.
- **Exercise from the video:** add a second tool to the agent (for example a function that returns the column descriptions). Locally it works alongside the local executor; on Cloud Run alongside the sandbox executor. In Claude Code it is still one tool, `adk_analyst`; the new function is used inside the agent's reasoning, not exposed as a second MCP tool.

## Honest notes

- Cloud Run sandboxes are preview, under Pre-GA terms. Jobs and worker pools got sandbox support on August 5, 2026.
- The executor returns stdout and stderr only, never files. Charts come back as text histograms, by design of this agent's instruction. For PNGs you would need `--write` plus `--export-tar`, which the ADK executor does not use.
- Every code block runs in a fresh sandbox; `stateful=True` and `optimize_data_file=True` are rejected by the class.
- The sandbox shares the instance's CPU and memory; the launch post says there is no additional charge for it. `deploy.sh` sets 2 GiB.
- `to_mcp_server` is marked experimental in ADK. It works; the API may still move. Its HTTP mode is stateful here on purpose: stateless mode leaks one ADK session per tool call in every release through 2.13.0; the fix (google/adk-python#7155) merged to main on 2026-10-21 and is not yet in a release.
- The announcement blog's ADK snippet uses `system_instruction=`; `Agent` takes `instruction=`. The guide page for the executor (google/adk-docs#1914) is an open PR as of 2026-10-26; the deploy guide gained `--with_cloud_run_sandbox` on 2026-10-23 (google/adk-docs#2411).
- `adk deploy cloud_run` sets `GOOGLE_GENAI_USE_ENTERPRISE=1` on the service by default and does not carry `GOOGLE_GENAI_USE_VERTEXAI=FALSE` over from `analyst/.env`, so an API-key agent would call Vertex AI and fail with a 403. `deploy.sh` passes `--env GOOGLE_GENAI_USE_ENTERPRISE=0`.

## Sources

- ADK releases: https://github.com/google/adk-python/releases (2.5.0 added the executor and `to_mcp_server`; 2.6.3 added `--with_cloud_run_sandbox`)
- Deploy to Cloud Run: https://adk.dev/deploy/cloud-run/
- Agent as MCP server: https://adk.dev/tools-custom/mcp-tools/agent-as-server/
- Cloud Run sandboxes: https://docs.cloud.google.com/run/docs/code-execution and https://docs.cloud.google.com/run/docs/configuring/services/sandboxes
- Announcement (July 9, 2026): https://cloud.google.com/blog/topics/developers-practitioners/google-cloud-run-sandboxes-are-in-public-preview/
- Hosting MCP servers on Cloud Run: https://docs.cloud.google.com/run/docs/host-mcp-servers
- Claude Code MCP: https://code.claude.com/docs/en/mcp

MIT. Use it however you like.
