# Clean-environment gate

Run from a fresh clone before recording and again before the repo link goes in the description. Steps 1 to 6 must pass. Step 7 decides the last act of the video; record its result here either way.

```bash
git clone https://github.com/pdichone/adk-sandbox-analyst.git fresh-check && cd fresh-check
python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
cp analyst/.env.example analyst/.env   # add GOOGLE_API_KEY
export GOOGLE_CLOUD_PROJECT=… GOOGLE_CLOUD_LOCATION=us-central1 GOOGLE_API_KEY=…
```

| # | Check | Pass looks like | Result (date, ADK version) |
|---|---|---|---|
| 1 | `adk web`, pick `analyst`, ask the median question | A ```python block, then `tool_output`, then **34.09** and a histogram | |
| 2 | `./setup.sh` then `./deploy.sh` | Build finishes, a `https://adk-analyst-….run.app` URL prints; `gcloud beta run services describe adk-analyst --format 'value(spec.template.spec.containers[0].sandboxLauncher)'` prints `true` (or `describe` YAML shows `sandboxLauncher: true`) | |
| 3 | `./test.sh` | Same answer, 34.09, from the cloud; the code and the sandbox output are visible | |
| 4 | Cloud Run logs | `gcloud logging read '… AND sandbox'` shows sandbox start/exit lines for that request | |
| 5 | `./test.sh "fetch https://example.com with urllib"` | Fails with a connection error (egress denied) | |
| 6 | `./test.sh "Diagnostic: run exactly this program and show its raw output. import os; print(len(os.environ)); print(sorted(os.environ))"` | `2` and `['HOME', 'LC_CTYPE']`: none of the service's variables | |
| 7 | `claude mcp add adk-analyst -- "$PWD/.venv/bin/python" "$PWD/mcp_server.py"`, then the cold-open prompt in Claude Code | `/mcp` lists one tool `adk_analyst`; the answer is 34.09 | |
| 8 | `./deploy.sh mcp`, then `claude mcp add --transport http …` with the identity token | `/mcp` lists `adk_analyst` from the cloud URL; same prompt returns 34.09; the Cloud Run logs show a sandbox for that call | |

Verified so far (2026-10-08, ADK 2.11.0, MCP SDK 2.3.0, local machine, no Cloud Run yet): `main.py` serves `/list-apps` and `/mcp` in one process; an MCP client connects over streamable HTTP, initializes, and lists exactly one tool `adk_analyst` with one argument `request`. `mcp_server.py --http` standalone does the same.

Known risks for steps 2 to 8, with the fix if they bite:

- **`argument --region: expected one argument`**: `GOOGLE_CLOUD_LOCATION` is empty in this shell (a new tab does not inherit exports). Re-run `export GOOGLE_CLOUD_PROJECT=… GOOGLE_CLOUD_LOCATION=us-central1`, or keep the exports in a file and `source` it at the top of every tab.
- **`Cannot find service [adk-analyst]`**: `./deploy.sh` has not run on this project and region yet, or it ran elsewhere. `gcloud run services list --project $GOOGLE_CLOUD_PROJECT` shows what exists. `describe` takes the service name (`adk-analyst`), not the project id.
- **First prompt returns 403 `Agent Platform API has not been used in project …`**: `adk deploy cloud_run` sets `GOOGLE_GENAI_USE_ENTERPRISE=1` by default, which routes Gemini to Vertex AI and ignores `GOOGLE_API_KEY`. `deploy.sh` passes `--env GOOGLE_GENAI_USE_ENTERPRISE=0`. If you deployed by hand: `gcloud run services update adk-analyst --region $GOOGLE_CLOUD_LOCATION --update-env-vars GOOGLE_GENAI_USE_ENTERPRISE=0` (new revision, no rebuild).
- **`test.sh` step 3 prints nothing, or `SyntaxError` fragments**: fixed in the repo (macOS bash 3.2 brace-expanded the inline dict; `/run_sse` emits camelCase keys). To see the raw stream: `curl … "$APP_URL/run_sse" -d "$BODY" | head`.
- **`unrecognized arguments: --sandbox-launcher`**: the gcloud beta component is older than July 2026. `gcloud components update`.
- **Build fails on `pip install google-adk`**: the generated image is `python:3.11-slim`; ADK 2.11 needs 3.11+. Nothing to do; if it fails, read the Cloud Build log for the real error.
- **Sandbox output says a module is missing**: the sandbox runs the image's Python with the host filesystem read-only, so packages installed into `/home/myuser/.local` should be visible, but the environment is empty. The agent's instruction limits code to the standard library, so this should not trigger. If it does for your own extension, the fix is `--env` on `sandbox do`, which the ADK executor does not pass; use stdlib or vendor the code.
- **`test.sh` 403**: your account lacks `roles/run.invoker` on the service, or the token audience is wrong (use the `*.run.app` URL, not a custom domain).
- **Step 8 answers `421 Misdirected Request`**: `streamable_http_app()` was called without `host="0.0.0.0"` (the SDK then only accepts localhost Host headers). `main.py` passes it; if you changed it, put it back.
- **Step 8 MCP connect works but the tool call hangs**: the MCP session is stateful and `--max-instances=1` keeps it on one container. If you raised max instances, set `stateless_http=True` in `mcp_server.py`/`main.py`.
- **Step 8 token expired mid-recording**: identity tokens last 60 minutes. Re-export `ADK_ID_TOKEN` and restart `claude`, or use `gcloud run services proxy` and the `http://localhost:8080/mcp` URL instead.
