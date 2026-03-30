# cloudrun-csm

## Project Objectives

The primary goal of this project is to demonstrate the features of Cloud Service Mesh (CSM) for Cloud Run. Specifically, this project highlights:

*   **Service-to-Service Communication:** Seamless and secure communication between Cloud Run services.
*   **JWT Auto-Injection:** Automatic injection and validation of JSON Web Tokens for authentication.
*   **Strong Security:** Meeting and exceeding strict security requirements for inter-service communication.

## Security Configurations

To meet the strong security requirements for service-to-service communication, the following Organization Policies must be configured at the project level (`cloudrun-csm`):

### 1. `run.managed.requireInvokerIam`
*   **Description:** This boolean policy enforces that all Cloud Run services require explicit IAM authentication. When enforced, it prevents services from being accidentally or intentionally made publicly accessible (e.g., by preventing grants to `allUsers` or `allAuthenticatedUsers`). All invocations must carry a valid identity token with the `roles/run.invoker` permission.
*   **Configuration:** Enforced (True).

### 2. `iam.allowedPolicyMemberDomains`
*   **Description:** This list policy restricts IAM role bindings strictly to identities (users, groups, service accounts) from specified, trusted customer workspaces or domains. It mitigates the risk of granting access to unauthorized external identities, ensuring that only verified organizational identities can participate in the service mesh and access project resources.
*   **Configuration:** Restricted to allowed Customer IDs.

## Setup Instructions

This project is designed to be easily repeatable across different GCP environments. Use the provided automation scripts to bootstrap and configure your environment.

### Prerequisites
*   Google Cloud SDK (`gcloud`) installed and authenticated.
*   Permissions to set Organization Policies at the project level (e.g., `roles/orgpolicy.policyAdmin`).
*   Your Google Workspace / Cloud Identity Customer ID (for `iam.allowedPolicyMemberDomains`). *Note: This usually starts with `is:` (e.g., `is:C01234567`).*

### 1. Configure Organization Policies

Run the setup script to apply the required security constraints to your project. You can configure your environment using either a `config.env` file or exported environment variables.

**Option A: Using `config.env` (Recommended)**
Create a `config.env` file in the project root:
```env
PROJECT_ID="cloudrun-csm"
CUSTOMER_ID="is:C0xxxxxxx" # Replace with your actual Customer ID
```

**Option B: Using Environment Variables**
```bash
export PROJECT_ID="cloudrun-csm"
export CUSTOMER_ID="is:C0xxxxxxx" # Replace with your actual Customer ID
```

**Run the setup script:**
```bash
./scripts/01-setup-org-policies.sh
```

### 2. Validate Organization Policies

Verify that the organizational policies were successfully applied to your project:

```bash
gcloud org-policies list --project=$PROJECT_ID
```

Expected output:
```text
CONSTRAINT                      LIST_POLICY  BOOLEAN_POLICY  ETAG
iam.allowedPolicyMemberDomains  SET          -               ...
run.managed.requireInvokerIam   -            SET             ...
```

## Scenarios

### Scenario 1: Missing JWT Token (Unauthenticated Invocation)

In this scenario, we deploy two Cloud Run services: `callerWithoutJWT` and `provider`. 
Because of the `run.managed.requireInvokerIam` organization policy, both services strictly require IAM authentication to be invoked. 
When `callerWithoutJWT` attempts to call `provider`, the request fails because `callerWithoutJWT` does not include a valid OIDC (JWT) token in its request headers.

#### Setup and Deploy

Run the deployment script to build and deploy both services. The script will deploy the `provider`, retrieve its URL, and then deploy `callerWithoutJWT` with the `PROVIDER_URL` injected as an environment variable.

```bash
./scripts/02-deploy-scenario-1.sh
```

#### Test the Scenario

Since `callerWithoutJWT` is protected by IAM, you must use your own gcloud identity token to successfully reach it from your terminal:

```bash
# Get the URL of callerWithoutJWT
export CALLER_WITHOUT_JWT_URL=$(gcloud run services describe caller-without-jwt --project $PROJECT_ID --region us-central1 --format="value(status.url)")

# Invoke callerWithoutJWT with your credentials
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" $CALLER_WITHOUT_JWT_URL
```

**Expected Result:**
Your request will successfully reach `callerWithoutJWT`, but `callerWithoutJWT` will fail to communicate with the `provider` service, returning an expected HTTP 403 error.

```text
Failed to call provider. HTTP Error: 403 - Forbidden
This is expected because no JWT token was provided.
```

### Scenario 2: Successful Invocation with JWT (OIDC Token)

In this scenario, we deploy a new Cloud Run service named `caller-with-jwt`. This service demonstrates the correct method for authenticating service-to-service communication when `run.managed.requireInvokerIam` is enforced.

To successfully call `provider`, the `caller-with-jwt` service uses the Google Cloud Metadata Server to fetch a signed JSON Web Token (JWT) that asserts its own identity (via a dedicated Service Account). It then appends this OIDC token to the `Authorization: Bearer <token>` header of the outgoing HTTP request.

#### Setup and Deploy

Run the deployment script for Scenario 2. The script will:
1. Ensure the `provider` service exists.
2. Create a new service account `caller-with-jwt-sa` specifically for the caller service.
3. Grant this service account the `roles/run.invoker` role directly on the `provider` service.
4. Deploy the `caller-with-jwt` service.

```bash
./scripts/03-deploy-scenario-2.sh
```

#### Test the Scenario

Use your own identity to call the `caller-with-jwt` service:

```bash
# Get the URL of caller-with-jwt
export CALLER_JWT_URL=$(gcloud run services describe caller-with-jwt --project $PROJECT_ID --region us-central1 --format="value(status.url)")

# Invoke caller-with-jwt with your credentials
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" $CALLER_JWT_URL
```

**Expected Result:**
Your request successfully authenticates to `caller-with-jwt`. In turn, `caller-with-jwt` securely queries the metadata server for an OIDC token and invokes the `provider` successfully.

```text
Success! Provider says: Hello from Provider! This message requires a valid JWT token.
```

### Scenario 3: Cloud Service Mesh Auto-Injection

In this scenario, we deploy a new Cloud Run service named `caller-with-csm` using the *exact same code* as the original `callerWithoutJWT`. However, we configure Cloud Service Mesh (CSM) to transparently intercept and handle the service-to-service communication.

When `caller-with-csm` makes an HTTP call to the internal DNS hostname of the provider (`http://provider.mesh.local`), the CSM Envoy sidecar intercepts the request. Because the target is a protected Serverless Network Endpoint Group, Traffic Director automatically generates an identity (OIDC) token on behalf of the `caller-with-csm` service account and injects it into the outgoing request's `Authorization: Bearer` header.

#### Setup and Deploy

Run the deployment script for Scenario 3. The script will:
1. Ensure the necessary Network Services and Traffic Director APIs are enabled.
2. Create a custom VPC and Subnet with **Private Google Access enabled**.
3. Create a Cloud Service Mesh resource and configure a private Cloud DNS zone (`mesh.local`).
4. Set up a Serverless NEG pointing to the existing `provider` service.
5. Configure HTTP routing to map `provider.mesh.local` to the NEG.
6. Create a dedicated service account (`caller-csm-sa`) with the `roles/trafficdirector.client` and `roles/run.invoker` permissions.
7. Deploy the `caller-with-csm` service attached to the VPC and the Mesh, injecting `PROVIDER_URL=http://provider.mesh.local`.

```bash
./scripts/04-deploy-scenario-3.sh
```

#### Test the Scenario

Use your own identity to call the `caller-with-csm` service:

```bash
# Get the URL of caller-with-csm
export CALLER_CSM_URL=$(gcloud run services describe caller-with-csm --project $PROJECT_ID --region us-central1 --format="value(status.url)")

# Invoke caller-with-csm with your credentials
curl -s -H "Authorization: Bearer $(gcloud auth print-identity-token)" $CALLER_CSM_URL
```

**Expected Result:**
Your request successfully authenticates to `caller-with-csm`. Even though the application code does not know about or fetch any JWTs, the Cloud Service Mesh sidecar intercepts the outgoing request to `http://provider.mesh.local`, injects the required OIDC token, and successfully invokes the `provider`.

```text
Success! Provider says: Hello from Provider! This message requires a valid JWT token.
```

#### Validating the Mesh Resources

The Cloud Service Mesh resources created in this scenario (specifically the `networkservices.googleapis.com/Mesh` and `HttpRoute` APIs) are **API-first** and do not currently have a dedicated visual configuration UI in the Google Cloud Console.

To inspect your mesh and its routing rules, use the following `gcloud` commands:

1.  **View the Mesh:**
    ```bash
    gcloud network-services meshes describe csm-mesh --location=global --project=$PROJECT_ID
    ```

2.  **View the HTTP Route:**
    *(This route defines that traffic for `provider.mesh.local` is sent to the backend service)*
    ```bash
    gcloud network-services http-routes describe provider-route --location=global --project=$PROJECT_ID
    ```

3.  **View the Backend Service:**
    Unlike the Mesh and Route, the underlying backend service *is* visible in the Google Cloud Console.
    You can view `provider-backend` by navigating to: **Navigation Menu > Network Services > Load balancing > Backends**. Or, via CLI:
    ```bash
    gcloud compute backend-services describe provider-backend --global --project=$PROJECT_ID
    ```
