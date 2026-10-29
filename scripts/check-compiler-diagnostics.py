#!/usr/bin/env python3
"""Fail the verification gate on warnings in application/test sources."""
from pathlib import Path
import sys

project_root = Path(sys.argv[1]).resolve()
log_path = Path(sys.argv[2])
source_roots = [str(project_root / "EMSYS") + "/", str(project_root / "EMSYSTests") + "/"]
warnings = {
    line for line in log_path.read_text(errors="replace").splitlines()
    if ": warning:" in line and any(root in line for root in source_roots)
}
if warnings:
    print("Resolve application/test compiler warnings before continuing:", file=sys.stderr)
    print("\n".join(sorted(warnings)), file=sys.stderr)
    raise SystemExit(1)
