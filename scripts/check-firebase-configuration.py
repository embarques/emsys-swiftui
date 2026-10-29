#!/usr/bin/env python3
"""Check the packaged iPhone Firebase client, without displaying its credentials."""
import json
import plistlib
import subprocess
import sys
from pathlib import Path


def main():
    result = subprocess.run(
        ["xcodebuild", "-project", sys.argv[1], "-scheme", "EMSYS",
         "-destination", "generic/platform=iOS", "-disableAutomaticPackageResolution",
         "-quiet", "-showBuildSettings", "-json", "CODE_SIGNING_ALLOWED=NO"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise ValueError("Could not resolve the current iPhone build settings.")
    targets = json.loads(result.stdout)
    application = next(item["buildSettings"] for item in targets if item["target"] == "EMSYS")
    products = Path(application["TARGET_BUILD_DIR"])
    info = plistlib.loads((products / application["INFOPLIST_PATH"]).read_bytes())
    client = plistlib.loads((products / application["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "GoogleService-Info.plist").read_bytes())
    identifier = info.get("CFBundleIdentifier")
    if not identifier or identifier != application["PRODUCT_BUNDLE_IDENTIFIER"] or client.get("BUNDLE_ID") != identifier:
        raise ValueError("Packaged Firebase client does not match the built app identifier. Restore the intended app identity or supply its matching Firebase client.")
    if not client.get("PROJECT_ID") or not client.get("GOOGLE_APP_ID"):
        raise ValueError("Packaged Firebase client is incomplete.")
    print("Packaged Firebase client matches the built iPhone app identity.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, StopIteration, plistlib.InvalidFileException):
        # Never print decoded options or subprocess output: it can contain client
        # credentials and unrelated signing settings.
        print("Firebase configuration validation failed: check the packaged client and app identity.", file=sys.stderr)
        sys.exit(1)
