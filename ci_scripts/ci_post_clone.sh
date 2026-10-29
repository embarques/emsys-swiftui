#!/bin/bash
# Xcode Cloud clones do not include the ignored Firebase client configuration.
set +x
set -euo pipefail

python3 - <<'PY'
import base64
import os
import plistlib
import sys
import tempfile
from pathlib import Path

temporary_path = None
try:
    root = Path(os.environ["CI_PRIMARY_REPOSITORY_PATH"])
    encoded = os.environ["EMSYS_FIREBASE_CONFIG_BASE64"]
    content = base64.b64decode(encoded, validate=True)
    client = plistlib.loads(content)
    if not isinstance(client, dict) or client.get("BUNDLE_ID") != "com.embarqueros.emsys":
        raise ValueError("Unexpected Firebase identity")
    if not all(isinstance(client.get(key), str) and client[key].strip()
               for key in ("PROJECT_ID", "GOOGLE_APP_ID", "API_KEY")):
        raise ValueError("Incomplete Firebase client")
    resources = root / "EMSYS" / "Resources"
    if not resources.is_dir():
        raise ValueError("Missing application resources")
    # Validate before replacing anything; a failed retry preserves the last file.
    with tempfile.NamedTemporaryFile(dir=resources, delete=False) as output:
        temporary_path = Path(output.name)
        output.write(content)
    temporary_path.replace(resources / "GoogleService-Info.plist")
    temporary_path = None
except Exception:
    # Never include exception details, configuration values, or decoded content.
    print("Firebase setup failed. Set the secret EMSYS_FIREBASE_CONFIG_BASE64 "
          "to the base64-encoded EMSYS Firebase plist in this Xcode Cloud workflow.",
          file=sys.stderr)
    sys.exit(1)
finally:
    if temporary_path is not None:
        temporary_path.unlink(missing_ok=True)
print("Firebase configuration prepared for EMSYS.")
PY
