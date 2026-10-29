"""Regression checks for the verification gate itself; no Xcode build is started."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
CHECKER = PROJECT / "scripts" / "check-compiler-diagnostics.py"
VERIFY = PROJECT / "scripts" / "verify.sh"


class VerificationGateTests(unittest.TestCase):
    def check_diagnostics(self, content):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "build.log"
            log.write_text(content)
            return subprocess.run([sys.executable, str(CHECKER), str(PROJECT), str(log)],
                                  capture_output=True, text=True)

    def test_application_warning_blocks_the_gate(self):
        result = self.check_diagnostics(
            f"{PROJECT}/EMSYS/Authentication/AuthorizedSessionStore.swift:48:1: warning: actor isolation failure\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("actor isolation failure", result.stderr)

    def test_test_source_warning_also_blocks_the_gate(self):
        result = self.check_diagnostics(
            f"{PROJECT}/EMSYSTests/InvoiceDocumentTests.swift:102:1: warning: unavailable Sendable conformance\n")
        self.assertNotEqual(result.returncode, 0)

    def test_system_notices_and_dependency_warnings_are_not_misattributed_to_app_sources(self):
        result = self.check_diagnostics(
            "/Library/Developer/SourcePackages/checkouts/vendor/Package.swift:1:1: warning: vendor notice\n"
            "appintentsmetadataprocessor: warning: No AppIntents dependency\n** TEST SUCCEEDED **\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_package_failure_stops_before_any_build_or_test(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tools = root / "tools"
            tools.mkdir()
            logs = root / "logs"
            logs.mkdir()
            marker = root / "calls.txt"
            fake = tools / "xcodebuild"
            fake.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$VERIFICATION_GATE_TEST_RECORD"\n'
                            'printf "Intentional package-resolution failure\\n" >&2\nexit 17\n')
            fake.chmod(0o700)
            environment = os.environ.copy()
            environment["PATH"] = str(tools) + os.pathsep + os.defpath
            environment["TMPDIR"] = str(logs)
            environment["VERIFICATION_GATE_TEST_RECORD"] = str(marker)
            result = subprocess.run([str(VERIFY)], cwd=root, env=environment,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FAIL packages", result.stderr)
            self.assertNotIn("All verification checks passed", result.stdout)
            calls = marker.read_text().splitlines()
            self.assertEqual(len(calls), 1, calls)
            self.assertIn("-resolvePackageDependencies", calls[0])
            self.assertIn("-onlyUsePackageVersionsFromResolvedFile", calls[0])


if __name__ == "__main__":
    unittest.main()
