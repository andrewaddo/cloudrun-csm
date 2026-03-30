import os
import urllib.request
from flask import Flask

app = Flask(__name__)

@app.route("/")
def call_provider():
    provider_url = os.environ.get("PROVIDER_URL")
    if not provider_url:
        return "Error: PROVIDER_URL environment variable is missing", 500

    try:
        # 1. Fetch OIDC token from the Google Metadata Server
        # The audience must match the target service URL
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
            
    except urllib.error.HTTPError as e:
        return f"Failed to call provider. HTTP Error: {e.code} - {e.reason}\n", e.code
    except Exception as e:
        return f"An error occurred: {str(e)}", 500

if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
