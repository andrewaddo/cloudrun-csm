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
        req = urllib.request.Request(provider_url)
        # Intentionally NOT adding the required Authorization header
        with urllib.request.urlopen(req) as response:
            return f"Success! Provider says: {response.read().decode('utf-8')}"
    except urllib.error.HTTPError as e:
        return f"Failed to call provider. HTTP Error: {e.code} - {e.reason}\nThis is expected because no JWT token was provided.\n", e.code
    except Exception as e:
        return f"An error occurred: {str(e)}", 500

if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
