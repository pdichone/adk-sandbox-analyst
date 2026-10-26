#!/usr/bin/env bash
# Deploy the analyst agent to Cloud Run with the sandbox launcher enabled.
#
#   ./deploy.sh          one command: adk deploy cloud_run --with_cloud_run_sandbox
#                        (ADK's API server: /list-apps, /run_sse ...)
#   ./deploy.sh mcp      same agent, same sandbox, plus /mcp for Claude Code
#                        (gcloud beta run deploy --source . --sandbox-launcher, runs main.py)
#
# Needs: gcloud >= 588 (beta component with --sandbox-launcher), a project with
# billing, and the one-time setup in README.md (APIs, Cloud Build role, secret).
set -euo pipefail

: "${GOOGLE_CLOUD_PROJECT:?export GOOGLE_CLOUD_PROJECT=your-project-id}"
: "${GOOGLE_CLOUD_LOCATION:=us-central1}"
SERVICE_NAME="${SERVICE_NAME:-adk-analyst}"
MODE="${1:-adk}"

# GOOGLE_GENAI_USE_ENTERPRISE=0: adk deploy sets it to 1 by default, which routes
# Gemini calls to Vertex AI (needs aiplatform.googleapis.com and a service-account
# role) and ignores GOOGLE_API_KEY. 0 keeps the Gemini API key path, same as local.
# Both modes: private service (identity token required), one instance plus
# session affinity so an MCP session stays on the same container, 2 GiB because
# the sandbox shares the instance's memory, and the Gemini key from Secret Manager.
GCLOUD_FLAGS=(
  --no-allow-unauthenticated
  --min-instances=0 --max-instances=1 --session-affinity
  --memory=2Gi --cpu=1
  --update-secrets=GOOGLE_API_KEY=GOOGLE_API_KEY:latest
)

if [[ "$MODE" == "adk" ]]; then
  # ADK generates the Dockerfile, runs `gcloud beta run deploy ... --sandbox-launcher`.
  adk deploy cloud_run \
    --project="$GOOGLE_CLOUD_PROJECT" \
    --region="$GOOGLE_CLOUD_LOCATION" \
    --service_name="$SERVICE_NAME" \
    --app_name=analyst \
    --with_cloud_run_sandbox \
    --env GOOGLE_GENAI_USE_ENTERPRISE=0 \
    ./analyst \
    -- "${GCLOUD_FLAGS[@]}"
elif [[ "$MODE" == "mcp" ]]; then
  # Same image recipe, our Dockerfile, main.py serves the API server and /mcp.
  gcloud beta run deploy "$SERVICE_NAME" \
    --source . \
    --project="$GOOGLE_CLOUD_PROJECT" \
    --region="$GOOGLE_CLOUD_LOCATION" \
    --sandbox-launcher \
    --port=8080 \
    --update-env-vars="GOOGLE_CLOUD_PROJECT=$GOOGLE_CLOUD_PROJECT,GOOGLE_CLOUD_LOCATION=$GOOGLE_CLOUD_LOCATION,GOOGLE_GENAI_USE_ENTERPRISE=0" \
    "${GCLOUD_FLAGS[@]}"
else
  echo "usage: $0 [adk|mcp]" >&2; exit 2
fi

echo
echo "Service URL:"
gcloud run services describe "$SERVICE_NAME" --project="$GOOGLE_CLOUD_PROJECT" \
  --region="$GOOGLE_CLOUD_LOCATION" --format='value(status.url)'
