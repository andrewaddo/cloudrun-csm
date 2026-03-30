# Cloud Service Mesh for Cloud Run: Implementation Report

## Executive Summary

This report details the implementation of a secure service-to-service communication architecture on Google Cloud Platform using Cloud Run and Cloud Service Mesh (CSM). The primary objective was to demonstrate how to enforce strict authentication between serverless applications while simplifying the developer experience through automated identity injection.

## The Challenge: Secure Serverless Communication

When building microservices on serverless platforms like Cloud Run, a critical challenge emerges: **How do we ensure that only authorized services can invoke each other, without exposing endpoints to the public internet?**

### Security Requirements
1.  **Zero Trust Architecture:** Every request between services must be explicitly authenticated and authorized.
2.  **IAM Enforcement:** We must enforce that services cannot be accidentally made public (e.g., granting `allUsers` access).
3.  **Identity Verification:** Services must prove their identity using short-lived, cryptographically signed JSON Web Tokens (JWTs/OIDC tokens) issued by Google Cloud.

The challenge is that while Google Cloud Run natively supports requiring IAM authentication, managing the retrieval, caching, and attachment of these OIDC tokens within every application's source code adds significant boilerplate, complexity, and potential security risks if implemented incorrectly by developers.

## The Solution: Cloud Service Mesh Auto-Injection

We addressed these challenges through a two-pronged approach:

### 1. Enforcing Organizational Policies
We applied two strict Google Cloud Organization Policies at the project level to mandate security:
*   `run.managed.requireInvokerIam`: Enforces that all Cloud Run services strictly require IAM authentication. No service can be public.
*   `iam.allowedPolicyMemberDomains`: Restricts IAM role bindings to only trusted organizational identities, preventing external access.

### 2. Implementing Cloud Service Mesh (CSM)
To solve the developer burden of managing JWTs, we implemented a **client-side proxy (egress) mesh pattern** using Cloud Service Mesh. 

By deploying a sidecar proxy (Envoy) alongside the calling Cloud Run service, the application code can make plain HTTP requests to internal DNS names (e.g., `http://provider.mesh.local`). The sidecar transparently intercepts the outbound request, automatically requests an OIDC token from the Google Metadata Server using the caller's Service Account identity, and injects it into the `Authorization` header before securely routing the traffic to the destination service over the VPC.

---

## Scenarios and Implementation

We developed three scenarios to demonstrate the progression from an insecure/failing state to a fully automated mesh architecture.

### Common Provider Service
All scenarios attempt to invoke a common `provider` service that simply returns a greeting. Due to the `requireInvokerIam` policy, this service rejects any request lacking a valid JWT.

**`services/provider/main.py`**
```python
import os
from flask import Flask

app = Flask(__name__)

@app.route("/")
def hello():
    return "Hello from Provider! This message requires a valid JWT token.\n"

if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
```

---

### Scenario 1: The Failing Unauthenticated Call

**Objective:** Demonstrate that a standard HTTP call fails when strict IAM policies are enforced.

**Implementation:** The `callerWithoutJWT` service makes a standard `urllib.request` to the `provider` URL without attaching an `Authorization` header.

**Code Snippet (`services/callerWithoutJWT/main.py`):**
```python
@app.route("/")
def call_provider():
    provider_url = os.environ.get("PROVIDER_URL")
    try:
        req = urllib.request.Request(provider_url)
        # Intentionally NOT adding the required Authorization header
        with urllib.request.urlopen(req) as response:
            return f"Success! Provider says: {response.read().decode('utf-8')}"
    except urllib.error.HTTPError as e:
        return f"Failed to call provider. HTTP Error: {e.code} - {e.reason}\nThis is expected because no JWT token was provided.\n", e.code
```

**Test Execution:**
```bash
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" $CALLER_WITHOUT_JWT_URL
```

**Test Result:**
```bash
$ export CALLER_WITHOUT_JWT_URL=$(gcloud run services describe caller-without-jwt --project $PROJECT_ID --region us-central1 --format="value(status.url)")

$ curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" $CALLER_WITHOUT_JWT_URL

Failed to call provider. HTTP Error: 403 - Forbidden
This is expected because no JWT token was provided.
```

---

### Scenario 2: Manual JWT Management (The "Hard Way")

**Objective:** Demonstrate how to successfully authenticate by manually fetching and injecting the OIDC token in the application code.

**Implementation:** The `callerWithJWT` service uses the Google Cloud Metadata Server API to request an identity token scoped to the audience of the `provider` service. It then constructs a new request with the `Authorization: Bearer <token>` header.

**Code Snippet (`services/callerWithJWT/main.py`):**
```python
@app.route("/")
def call_provider():
    provider_url = os.environ.get("PROVIDER_URL")
    try:
        # 1. Fetch OIDC token from the Google Metadata Server
        token_url = f"http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience={provider_url}"
        token_req = urllib.request.Request(token_url, headers={"Metadata-Flavor": "Google"})
        
        with urllib.request.urlopen(token_req) as response:
            token = response.read().decode('utf-8')

        # 2. Call the provider service with the retrieved token
        req_provider = urllib.request.Request(
            provider_url,
            headers={"Authorization": f"Bearer {token}"}
        )
        with urllib.request.urlopen(req_provider) as response:
            return f"Success! Provider says: {response.read().decode('utf-8')}"
```

**Test Execution:**
```bash
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" $CALLER_JWT_URL
```

**Test Result:**
```bash
$ export CALLER_JWT_URL=$(gcloud run services describe caller-with-jwt --project $PROJECT_ID --region us-central1 --format="value(status.url)")

$ curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" $CALLER_JWT_URL

Success! Provider says: Hello from Provider! This message requires a valid JWT token.
```

---

### Scenario 3: Cloud Service Mesh Auto-Injection (The "Smart Way")

**Objective:** Achieve the success of Scenario 2 using the simple code from Scenario 1, relying on Cloud Service Mesh to handle the complexity.

**Implementation:** 
1. We deployed a new service `caller-with-csm` using the *exact same source code* as Scenario 1 (`callerWithoutJWT`). 
2. We configured a Cloud Service Mesh resource (`csm-mesh`), a private DNS zone (`mesh.local`), and an HTTP Route directing traffic for `provider.mesh.local` to a Serverless NEG pointing to the `provider` service.
3. We deployed the caller with the CSM sidecar enabled and instructed it to call the internal mesh DNS name:
   `PROVIDER_URL=http://provider.mesh.local`

Because the sidecar recognizes the route is managed by Traffic Director and targets a protected Cloud Run service, it automatically intercepts the egress traffic, fetches the OIDC token, and injects it.

**Test Execution:**
```bash
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" $CALLER_CSM_URL
```

**Test Result:**
```bash
$ export CALLER_CSM_URL=$(gcloud run services describe caller-with-csm --project $PROJECT_ID --region us-central1 --format="value(status.url)")
$ curl -s -H "Authorization: Bearer $(gcloud auth print-identity-token)" $CALLER_CSM_URL

Success! Provider says: Hello from Provider! This message requires a valid JWT token.
```

## Conclusion

Cloud Service Mesh provides a powerful abstraction for Cloud Run service-to-service communication. By offloading identity management and token injection to the Envoy sidecar proxy, developers can write simpler, framework-agnostic code (Scenario 1/3) while operations and security teams can strictly enforce zero-trust policies and IAM authentication across the entire serverless architecture.
