#!/usr/bin/env bash
# Creates the CouponCock prompt/response safety template once per GCP project.
# This command changes cloud state; run it only after reviewing the filters and logging policy.
set -euo pipefail

project_id="${1:?usage: bootstrap-model-armor.sh <PROJECT_ID> [LOCATION] [TEMPLATE_ID]}"
location="${2:-asia-northeast3}"
template_id="${3:-couponcok-production-guardrail}"

gcloud services enable modelarmor.googleapis.com dlp.googleapis.com --project="$project_id"
# Model Armor is served from a regional endpoint. Pin it before any describe/create
# call so the CLI does not fall back to the global endpoint.
gcloud config set api_endpoint_overrides/modelarmor "https://modelarmor.${location}.rep.googleapis.com/"

if gcloud model-armor templates describe "$template_id" --project="$project_id" --location="$location" >/dev/null 2>&1; then
  echo "Model Armor template already exists: $template_id"
  exit 0
fi

if [[ "$location" == "asia-northeast3" ]]; then
  # Seoul currently supports the baseline template only. The application keeps
  # jailbreak/URI/RAI policy in its in-process guardrail and uses Cloud DLP for
  # sensitive-data redaction, both fail-closed in enforce mode.
  gcloud model-armor templates create "$template_id" \
    --project="$project_id" \
    --location="$location" \
    --basic-config-filter-enforcement=enabled \
    --template-metadata-log-operations \
    --template-metadata-log-sanitize-operations
else
  gcloud model-armor templates create "$template_id" \
    --project="$project_id" \
    --location="$location" \
    --rai-settings-filters='[{"filterType":"HATE_SPEECH","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"HARASSMENT","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"SEXUALLY_EXPLICIT","confidenceLevel":"MEDIUM_AND_ABOVE"}]' \
    --basic-config-filter-enforcement=enabled \
    --pi-and-jailbreak-filter-settings-enforcement=enabled \
    --pi-and-jailbreak-filter-settings-confidence-level=HIGH \
    --malicious-uri-filter-settings-enforcement=enabled \
    --template-metadata-log-operations \
    --template-metadata-log-sanitize-operations
fi

echo "Created $template_id. Use _MODEL_ARMOR_TEMPLATE=$template_id in Cloud Build substitutions."
