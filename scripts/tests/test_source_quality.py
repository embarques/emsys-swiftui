"""Exercise source quality checks against small Swift source fixtures."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

CHECKER = Path(__file__).resolve().parents[1] / "check-source-quality.py"
SPEC = importlib.util.spec_from_file_location("source_quality", CHECKER)
SOURCE_QUALITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCE_QUALITY)

VIEW_MODEL = "EMSYS/Features/Invoices/ViewModels/InvoiceViewModel.swift"


class SourceQualityTests(unittest.TestCase):
    def check_fixture(self, files, baseline=None):
        """Write a temporary source tree and check it with the supplied baseline."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Use production-relative paths so this exercises folder classification.
            for name, source in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source, encoding="utf-8")
            return SOURCE_QUALITY.check_sources(root, baseline or {})

    def test_repository_and_observable_view_model_pass(self):
        """Accept transport in repositories and ignore ordinary strings and comments."""
        diagnostics = self.check_fixture({
            VIEW_MODEL: '@Observable final class InvoiceViewModel {}\n'
                        '// use APIClient in the repository\n'
                        'let example = "ObservableObject"\n',
            "EMSYS/Features/Invoices/Repositories/InvoiceRepository.swift":
                "import GRDB\nlet client: APIClient",
            "EMSYS/Features/Invoices/Helpers/InvoiceAttachmentFile.swift":
                "enum InvoiceAttachmentFile {}",
        })
        self.assertEqual(diagnostics, [])

    def test_wrong_folder_and_legacy_observation_are_reported(self):
        """Reject a catch-all folder and legacy state even outside presentation folders."""
        diagnostics = self.check_fixture({
            "EMSYS/Features/Invoices/Support/InvoiceState.swift":
                "final class InvoiceState: ObservableObject {}",
        })
        self.assertEqual(len(diagnostics), 2)
        self.assertIn("folder 'Support'", diagnostics[0])
        self.assertIn("Swift Observation", diagnostics[1])

    def test_presentation_layer_rejects_transport_and_database_imports(self):
        """Flag API and database access in both grouped and flat presentation files."""
        diagnostics = self.check_fixture({
            VIEW_MODEL: "import GRDB\nlet session = URLSession.shared\nlet client: APIClient",
            "EMSYS/Features/Home/HomeView.swift": "let session = URLSession.shared",
        })
        self.assertEqual(len(diagnostics), 4)
        self.assertTrue(any(f"{VIEW_MODEL}:1:" in message for message in diagnostics))
        self.assertTrue(any("HomeView.swift:1:" in message for message in diagnostics))

    def test_baseline_allows_only_existing_count_and_requires_cleanup(self):
        """Fail if a file exceeds its allowance or retains an obsolete allowance."""
        baseline = {VIEW_MODEL: 1}
        existing = "let client: APIClient\n"
        self.assertEqual(self.check_fixture({VIEW_MODEL: existing}, baseline), [])
        excess = self.check_fixture({VIEW_MODEL: existing + "let second: APIClient"}, baseline)
        removed = self.check_fixture({VIEW_MODEL: "@Observable final class InvoiceViewModel {}"}, baseline)
        self.assertEqual(len(excess), 1)
        self.assertIn(f"{VIEW_MODEL}:2:", excess[0])
        self.assertIn("reduce the APIClient baseline from 1 to 0", removed[0])
