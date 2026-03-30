#!/bin/bash
set -e

if [[ -f "config.env" ]]; then
  source config.env
fi

if [[ -z "$PROJECT_ID" ]]; then
  echo "Error: PROJECT_ID environment variable is not set."
  exit 1
fi

REGION="${REGION:-us-central1}"
VPC_NAME="csm-vpc"
SUBNET_NAME="csm-subnet"
MESH_NAME="csm-mesh"
DOMAIN_NAME="mesh.local"
PROVIDER_HOST="provider.$DOMAIN_NAME"

echo "======================================================"
echo "Deploying Scenario 3: Cloud Service Mesh Auto-Injection"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "======================================================"

echo "Enabling necessary APIs..."
gcloud services enable \
    compute.googleapis.com \
    dns.googleapis.com \
    networkservices.googleapis.com \
    networksecurity.googleapis.com \
    trafficdirector.googleapis.com \
    --project="$PROJECT_ID"

echo ""
echo "1. Setting up VPC Network and Subnet..."
gcloud compute networks describe $VPC_NAME --project="$PROJECT_ID" >/dev/null 2>&1 || \
    gcloud compute networks create $VPC_NAME --subnet-mode=custom --project="$PROJECT_ID"

gcloud compute networks subnets describe $SUBNET_NAME --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1 || \
    gcloud compute networks subnets create $SUBNET_NAME \
        --network=$VPC_NAME \
        --range=10.128.0.0/20 \
        --region="$REGION" \
        --enable-private-ip-google-access \
        --project="$PROJECT_ID"

echo ""
echo "2. Setting up Cloud Service Mesh..."
cat <<YAML > mesh.yaml
name: $MESH_NAME
YAML

gcloud network-services meshes describe $MESH_NAME --location=global --project="$PROJECT_ID" >/dev/null 2>&1 || \
    gcloud network-services meshes import $MESH_NAME --source=mesh.yaml --location=global --project="$PROJECT_ID"
rm -f mesh.yaml

echo ""
echo "3. Configuring Cloud DNS for the Mesh..."
gcloud dns managed-zones describe $MESH_NAME-zone --project="$PROJECT_ID" >/dev/null 2>&1 || \
    gcloud dns managed-zones create $MESH_NAME-zone \
        --description="Domain for $DOMAIN_NAME service mesh routes" \
        --dns-name="$DOMAIN_NAME." \
        --networks=$VPC_NAME \
        --visibility=private \
        --project="$PROJECT_ID"

gcloud dns record-sets describe "*.$DOMAIN_NAME." --type=A --zone="$MESH_NAME-zone" --project="$PROJECT_ID" >/dev/null 2>&1 || \
    gcloud dns record-sets create "*.$DOMAIN_NAME." \
        --type=A \
        --zone="$MESH_NAME-zone" \
        --rrdatas=10.0.0.1 \
        --ttl=3600 \
        --project="$PROJECT_ID"

echo ""
echo "4. Setting up Serverless NEG and Backend Service for 'provider'..."
gcloud compute network-endpoint-groups describe provider-neg --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1 || \
    gcloud compute network-endpoint-groups create provider-neg \
        --region="$REGION" \
        --network-endpoint-type=serverless \
        --cloud-run-service=provider \
        --project="$PROJECT_ID"

gcloud compute backend-services describe provider-backend --global --project="$PROJECT_ID" >/dev/null 2>&1 || \
    gcloud compute backend-services create provider-backend \
        --global \
        --load-balancing-scheme=INTERNAL_SELF_MANAGED \
        --project="$PROJECT_ID"

gcloud compute backend-services add-backend provider-backend \
    --global \
    --network-endpoint-group=provider-neg \
    --network-endpoint-group-region="$REGION" \
    --project="$PROJECT_ID" >/dev/null 2>&1 || true

echo ""
echo "5. Configuring HTTP Routing in the Mesh..."
cat <<YAML > http_route.yaml
name: "provider-route"
hostnames:
- "$PROVIDER_HOST"
meshes:
- "projects/$PROJECT_ID/locations/global/meshes/$MESH_NAME"
rules:
- action:
    destinations:
    - serviceName: "projects/$PROJECT_ID/locations/global/backendServices/provider-backend"
YAML

gcloud network-services http-routes import provider-route \
    --source=http_route.yaml \
    --location=global \
    --project="$PROJECT_ID"
rm -f http_route.yaml

echo ""
echo "6. Creating Service Account and Granting Permissions..."
SA_NAME="caller-csm-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Service Account for caller-with-csm service" \
    --project="$PROJECT_ID" 2>/dev/null || echo "Service account $SA_NAME already exists."

sleep 5

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/trafficdirector.client" \
    --quiet

gcloud run services add-iam-policy-binding provider \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/run.invoker" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --quiet

echo ""
echo "7. Deploying 'caller-with-csm' service..."
# Deploying the caller using the same source as callerWithoutJWT
# Attaching it to the VPC and the Mesh
gcloud beta run deploy caller-with-csm \
  --source services/callerWithoutJWT \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --service-account="$SA_EMAIL" \
  --set-env-vars="PROVIDER_URL=http://$PROVIDER_HOST" \
  --network="$VPC_NAME" \
  --subnet="$SUBNET_NAME" \
  --vpc-egress="all-traffic" \
  --mesh="projects/$PROJECT_ID/locations/global/meshes/$MESH_NAME" \
  --no-allow-unauthenticated \
  --quiet

CALLER_CSM_URL=$(gcloud run services describe caller-with-csm --project "$PROJECT_ID" --region "$REGION" --format="value(status.url)")
echo "Caller-With-CSM URL: $CALLER_CSM_URL"

echo ""
echo "======================================================"
echo "Deployment complete."
echo "Test the scenario by manually invoking caller-with-csm with your own identity token:"
echo ""
echo "  curl -s -H \"Authorization: Bearer \$(gcloud auth print-identity-token)\" $CALLER_CSM_URL"
echo ""
echo "Expected outcome: The call successfully reaches provider. The Cloud Service Mesh sidecar automatically intercepts the request, generates an OIDC token for the caller's identity, and injects it into the request."
echo "======================================================"
