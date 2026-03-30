#!/bin/bash
set -e

# Source configuration if it exists
if [[ -f "config.env" ]]; then
  source config.env
fi

if [[ -z "$PROJECT_ID" ]]; then
  echo "Error: PROJECT_ID environment variable is not set."
  exit 1
fi

REGION="${REGION:-us-central1}"

echo "======================================================"
echo "Deploying Scenario 1: Missing JWT Token"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "======================================================"

echo "Enabling necessary APIs (Run, Build)..."
gcloud services enable run.googleapis.com cloudbuild.googleapis.com --project="$PROJECT_ID"

echo ""
echo "1. Deploying 'provider' service..."
# Deploy provider and restrict it to authenticated invocations.
# Note: Because of the org policy run.managed.requireInvokerIam, --no-allow-unauthenticated is enforced implicitly.
gcloud run deploy provider \
  --source services/provider \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --no-allow-unauthenticated \
  --quiet

PROVIDER_URL=$(gcloud run services describe provider --project "$PROJECT_ID" --region "$REGION" --format="value(status.url)")
echo "Provider URL: $PROVIDER_URL"

echo ""
echo "2. Deploying 'caller-without-jwt' service..."
# Deploy caller-without-jwt and inject the PROVIDER_URL.
gcloud run deploy caller-without-jwt \
  --source services/callerWithoutJWT \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --set-env-vars="PROVIDER_URL=$PROVIDER_URL" \
  --no-allow-unauthenticated \
  --quiet

CALLER_WITHOUT_JWT_URL=$(gcloud run services describe caller-without-jwt --project "$PROJECT_ID" --region "$REGION" --format="value(status.url)")
echo "CallerWithoutJWT URL: $CALLER_WITHOUT_JWT_URL"

echo ""
echo "======================================================"
echo "Deployment complete."
echo "Test the scenario by manually invoking caller-without-jwt with your own identity token:"
echo ""
echo "  curl -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" $CALLER_WITHOUT_JWT_URL"
echo ""
echo "Expected outcome: HTTP 403 Forbidden. caller-without-jwt will fail to reach provider because it does not append a JWT token."
echo "======================================================"
