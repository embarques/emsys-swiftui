"""Check objective folder and presentation-layer conventions in EMSYS source."""

from collections import Counter
import json
from pathlib import Path
import re
import sys

CATCH_ALL_FOLDERS = {"support", "common", "misc"}
PRESENTATION_FOLDERS = {"Views", "ViewModels"}
LEGACY_OBSERVATION = re.compile(
    r"\bObservableObject\b|@(?:Published|StateObject|ObservedObject|EnvironmentObject)\b"
)
TRANSPORT_TYPES = re.compile(r"\b(?:APIClient|URLSession)\b")
GRDB_IMPORT = re.compile(r"\bimport\s+(?:(?:class|struct|enum|func|protocol|typealias|var|let)\s+)?GRDB\b")
# Remove ordinary Swift comments and strings before matching identifiers.
NON_CODE = re.compile(r'//[^\n]*|/\*.*?\*/|""".*?"""|"(?:\\.|[^"\\\n])*"', re.DOTALL)


def check_sources(root: Path, api_client_baseline: dict) -> list:
    """Return diagnostics for source violations and baseline entries to remove."""
    diagnostics = []
    api_client_counts = Counter()

    for path in sorted((root / "EMSYS").rglob("*.swift")):
        relative = path.relative_to(root)
        name = relative.as_posix()

        # Apply naming rules to folders that contain production Swift code.
        for folder in relative.parts[1:-1]:
            if folder.casefold() in CATCH_ALL_FOLDERS:
                diagnostics.append(f"{name}: folder '{folder}' needs a responsibility-based name")

        # Preserve line numbers when ignoring comments and string literals.
        source = NON_CODE.sub(lambda match: "\n" * match[0].count("\n") or " ", path.read_text(encoding="utf-8"))
        is_presentation = relative.parts[1] == "Features" and (
            bool(PRESENTATION_FOLDERS.intersection(relative.parts[2:-1]))
            or path.stem.endswith(("View", "ViewModel"))
        )
        for number, line in enumerate(source.splitlines(), start=1):
            location = f"{name}:{number}"
            if LEGACY_OBSERVATION.search(line):
                diagnostics.append(f"{location}: use Swift Observation for app state")

            if not is_presentation:
                continue
            if GRDB_IMPORT.search(line):
                diagnostics.append(f"{location}: keep GRDB behind the repository boundary")
            for transport in TRANSPORT_TYPES.findall(line):
                if transport == "APIClient":
                    api_client_counts[name] += 1
                    if api_client_counts[name] <= api_client_baseline.get(name, 0):
                        continue
                diagnostics.append(f"{location}: use a repository instead of referencing {transport}")

    # Retire exceptions as call sites disappear so their allowance cannot be reused.
    for name, allowed in sorted(api_client_baseline.items()):
        remaining = api_client_counts[name]
        if remaining < allowed:
            diagnostics.append(f"{name}: reduce the APIClient baseline from {allowed} to {remaining}")

    return diagnostics


def main() -> int:
    """Print actionable diagnostics and return a failing status when any remain."""
    root = Path(__file__).resolve().parents[1]
    baseline_path = root / "scripts" / "source-quality-api-client-baseline.json"
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))

    # Keep the shell gate's matching diagnostics in its normal verification log.
    diagnostics = check_sources(root, baseline)
    for diagnostic in diagnostics:
        print(diagnostic, file=sys.stderr)
    return int(bool(diagnostics))


if __name__ == "__main__":
    raise SystemExit(main())
