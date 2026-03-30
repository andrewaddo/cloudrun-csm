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
echo "Deploying Scenario 2: Successful OIDC Token Invocation"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "======================================================"

PROVIDER_URL=$(gcloud run services describe provider --project "$PROJECT_ID" --region "$REGION" --format="value(status.url)" 2>/dev/null || true)
if [[ -z "$PROVIDER_URL" ]]; then
    echo "Error: The 'provider' service could not be found. Please ensure Scenario 1 is deployed first."
    exit 1
fi
echo "Found Provider URL: $PROVIDER_URL"

# Create a dedicated service account for the caller
SA_NAME="caller-with-jwt-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo ""
echo "1. Creating Service Account: $SA_NAME..."
gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Service Account for caller-with-jwt service" \
    --project="$PROJECT_ID" 2>/dev/null || echo "Service account $SA_NAME already exists, skipping creation."

# IMPORTANT: Grant the invoker role on the provider service exclusively to the caller's service account.
echo ""
echo "2. Granting run.invoker role on 'provider' service to $SA_EMAIL..."
gcloud run services add-iam-policy-binding provider \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/run.invoker" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

echo ""
echo "3. Deploying 'caller-with-jwt' service..."
# Deploy the caller and set its identity to the newly created service account
gcloud run deploy caller-with-jwt \
  --source services/callerWithJWT \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --service-account="$SA_EMAIL" \
  --set-env-vars="PROVIDER_URL=$PROVIDER_URL" \
  --no-allow-unauthenticated \
  --quiet

CALLER_URL=$(gcloud run services describe caller-with-jwt --project "$PROJECT_ID" --region "$REGION" --format="value(status.url)")
echo "Caller-With-JWT URL: $CALLER_URL"

echo ""
echo "======================================================"
echo "Deployment complete."
echo "Test the scenario by manually invoking caller-with-jwt with your own identity token:"
echo ""
echo "  curl -s -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" $CALLER_URL"
echo ""
echo "Expected outcome: The call successfully bridges caller-with-jwt to provider, printing the provider's message."
echo "======================================================"
