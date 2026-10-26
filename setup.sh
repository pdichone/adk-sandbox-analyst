#!/usr/bin/env bash
# One-time project setup for deploy.sh. Safe to re-run.
#   export GOOGLE_CLOUD_PROJECT=your-project-id   (billing must be enabled)
#   export GOOGLE_API_KEY=...                      (a Gemini API key from AI Studio)
#   ./setup.sh
set -euo pipefail
: "${GOOGLE_CLOUD_PROJECT:?export GOOGLE_CLOUD_PROJECT=your-project-id}"
: "${GOOGLE_API_KEY:?export GOOGLE_API_KEY=your-gemini-key}"

gcloud config set project "$GOOGLE_CLOUD_PROJECT" >/dev/null
echo "# APIs (Cloud Run, Cloud Build, Artifact Registry, Secret Manager)"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com \
  artifactregistry.googleapis.com secretmanager.googleapis.com

PROJECT_NUMBER=$(gcloud projects describe "$GOOGLE_CLOUD_PROJECT" --format='value(projectNumber)')
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
echo "# default compute service account: $SA"

echo "# Cloud Build may build the image (adk deploy and --source use Cloud Build)"
gcloud projects add-iam-policy-binding "$GOOGLE_CLOUD_PROJECT" \
  --member="serviceAccount:$SA" --role="roles/cloudbuild.builds.builder" --condition=None >/dev/null

echo "# Gemini key into Secret Manager (never into the image or the repo)"
if ! gcloud secrets describe GOOGLE_API_KEY >/dev/null 2>&1; then
  printf '%s' "$GOOGLE_API_KEY" | gcloud secrets create GOOGLE_API_KEY --data-file=-
else
  echo "secret GOOGLE_API_KEY exists; adding a new version"
  printf '%s' "$GOOGLE_API_KEY" | gcloud secrets versions add GOOGLE_API_KEY --data-file=-
fi
gcloud secrets add-iam-policy-binding GOOGLE_API_KEY \
  --member="serviceAccount:$SA" --role="roles/secretmanager.secretAccessor" >/dev/null
echo "done. Next: ./deploy.sh"
