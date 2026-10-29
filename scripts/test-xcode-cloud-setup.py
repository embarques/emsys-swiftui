#!/usr/bin/env python3
"""Exercise cloud configuration with synthetic clients, never real credentials."""
import base64
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "ci_scripts/ci_post_clone.sh"


class CloudConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.resources = self.root / "EMSYS/Resources"
        self.resources.mkdir(parents=True)
        self.destination = self.resources / "GoogleService-Info.plist"
        self.client = {"BUNDLE_ID": "com.embarqueros.emsys", "PROJECT_ID": "fixture",
                       "GOOGLE_APP_ID": "fixture-app", "API_KEY": "private-fixture-marker"}

    def run_setup(self, content=None):
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("EMSYS_FIREBASE_CONFIG_BASE64", "BASH_ENV", "SHELLOPTS")}
        environment["CI_PRIMARY_REPOSITORY_PATH"] = str(self.root)
        if content is not None:
            environment["EMSYS_FIREBASE_CONFIG_BASE64"] = content
        result = subprocess.run(["/bin/bash", str(SCRIPT)], env=environment,
                                capture_output=True, text=True, check=False)
        self.assertNotIn("private-fixture-marker", result.stdout + result.stderr)
        if content:
            self.assertNotIn(content, result.stdout + result.stderr)
        return result

    def encoded_client(self):
        return base64.b64encode(plistlib.dumps(self.client)).decode()

    def test_valid_configuration_is_installed_privately_and_can_be_retried(self):
        for _ in range(2):
            self.assertEqual(self.run_setup(self.encoded_client()).returncode, 0)
            self.assertEqual(plistlib.loads(self.destination.read_bytes()), self.client)
            self.assertEqual(self.destination.stat().st_mode & 0o777, 0o600)

    def test_missing_or_invalid_configuration_preserves_existing_file(self):
        self.destination.write_bytes(b"existing")
        for content in (None, "", "invalid-base64!", base64.b64encode(b"not a plist").decode()):
            with self.subTest(content=content):
                self.assertNotEqual(self.run_setup(content).returncode, 0)
                self.assertEqual(self.destination.read_bytes(), b"existing")

    def test_wrong_identity_and_incomplete_client_are_rejected(self):
        for field, value in (("BUNDLE_ID", "com.example.other"), ("API_KEY", ""),
                             ("PROJECT_ID", ""), ("GOOGLE_APP_ID", "")):
            with self.subTest(field=field):
                original = self.client[field]
                self.client[field] = value
                self.assertNotEqual(self.run_setup(self.encoded_client()).returncode, 0)
                self.assertFalse(self.destination.exists())
                self.client[field] = original


if __name__ == "__main__":
    unittest.main()
