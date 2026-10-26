#!/usr/bin/env bash
# Smoke-test the deployed service with an identity token.
#   ./test.sh                       asks the median question
#   ./test.sh "your question here"  asks anything else
set -euo pipefail

: "${GOOGLE_CLOUD_PROJECT:?export GOOGLE_CLOUD_PROJECT=your-project-id}"
: "${GOOGLE_CLOUD_LOCATION:=us-central1}"
SERVICE_NAME="${SERVICE_NAME:-adk-analyst}"
QUESTION="${1:-What is the median order value? Also show a histogram of order totals.}"

APP_URL=$(gcloud run services describe "$SERVICE_NAME" --project="$GOOGLE_CLOUD_PROJECT" \
  --region="$GOOGLE_CLOUD_LOCATION" --format='value(status.url)')
TOKEN=$(gcloud auth print-identity-token)   # valid for 60 minutes
SESSION="s-$(date +%s)"

echo "# 1. apps"
curl -sS -H "Authorization: Bearer $TOKEN" "$APP_URL/list-apps"; echo
echo "# 2. session $SESSION"
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$APP_URL/apps/analyst/users/demo/sessions/$SESSION" -d '{}' > /dev/null && echo "created"
echo "# 3. run (the agent writes Python and runs it in a sandbox; 20-60 s)"
# Body built by a quoted heredoc: macOS bash 3.2 brace-expands a dict literal
# nested inside "$(python3 -c "...")", splitting it into broken fragments.
BODY=$(SESSION="$SESSION" QUESTION="$QUESTION" python3 - <<'PY'
import json, os
print(json.dumps({'app_name': 'analyst', 'user_id': 'demo', 'session_id': os.environ['SESSION'],
                  'new_message': {'role': 'user', 'parts': [{'text': os.environ['QUESTION']}]},
                  'streaming': False}))
PY
)
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$APP_URL/run_sse" -d "$BODY" \
  | sed -n 's/^data: //p' \
  | python3 -c "
import json,sys
# The API server emits camelCase (executableCode, codeExecutionResult); adk web shows snake_case.
for line in sys.stdin:
    ev=json.loads(line)
    err=ev.get('errorMessage') or ev.get('error_message')
    if err: print('--- error from the service ---'); print(err); continue
    for p in (ev.get('content') or {}).get('parts') or []:
        code=p.get('executableCode') or p.get('executable_code')
        result=p.get('codeExecutionResult') or p.get('code_execution_result')
        if code: print('--- code the agent wrote ---'); print(code['code'])
        if result: print('--- sandbox output ---'); print(result.get('output',''))
        if p.get('text'): print('--- answer ---'); print(p['text'])
"
echo
echo "# 4. proof it ran in a sandbox: Cloud Run logs"
echo "gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=$SERVICE_NAME AND textPayload:\"sandbox do\"' --project=$GOOGLE_CLOUD_PROJECT --limit=5 --freshness=10m --format='value(timestamp,textPayload)'"
