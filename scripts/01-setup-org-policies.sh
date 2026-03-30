#!/bin/bash
set -e

# Source configuration if it exists
if [[ -f "config.env" ]]; then
  source config.env
fi

# Use provided environment variables, otherwise fail
if [[ -z "$PROJECT_ID" ]]; then
  echo "Error: PROJECT_ID environment variable is not set."
  echo "You can set it in config.env or export it: export PROJECT_ID=my-project"
  exit 1
fi

echo "======================================================"
echo "Configuring organization policies for project: $PROJECT_ID"
echo "======================================================"

# Ensure the Org Policy API is enabled
echo "Enabling orgpolicy.googleapis.com..."
gcloud services enable orgpolicy.googleapis.com --project="$PROJECT_ID"

# 1. Enforce run.managed.requireInvokerIam
echo ""
echo "Enforcing constraints/run.managed.requireInvokerIam..."
cat <<EOF > run_managed_require_invoker_iam.yaml
name: projects/$PROJECT_ID/policies/run.managed.requireInvokerIam
spec:
  rules:
  - enforce: true
EOF
gcloud org-policies set-policy run_managed_require_invoker_iam.yaml --project="$PROJECT_ID"
rm run_managed_require_invoker_iam.yaml
echo "Successfully enforced run.managed.requireInvokerIam."

# 2. Configure iam.allowedPolicyMemberDomains
echo ""
if [[ -n "$CUSTOMER_ID" ]]; then
  echo "Configuring constraints/iam.allowedPolicyMemberDomains for customer ID: $CUSTOMER_ID..."
  cat <<EOF > iam_allowed_policy_member_domains.yaml
name: projects/$PROJECT_ID/policies/iam.allowedPolicyMemberDomains
spec:
  rules:
  - values:
      allowedValues:
      - $CUSTOMER_ID
EOF
  gcloud org-policies set-policy iam_allowed_policy_member_domains.yaml --project="$PROJECT_ID"
  rm iam_allowed_policy_member_domains.yaml
  echo "Successfully allowed $CUSTOMER_ID for iam.allowedPolicyMemberDomains."
else
  echo "Warning: CUSTOMER_ID environment variable not provided."
  echo "Skipping constraints/iam.allowedPolicyMemberDomains configuration."
fi

echo ""
echo "======================================================"
echo "Organization policies configuration completed."
echo "======================================================"
