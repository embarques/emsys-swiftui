#!/bin/bash
# Run from any directory. Use the same DerivedData location as normal Xcode.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
project="$project_root/EMSYS.xcodeproj"
log_directory="$(mktemp -d "${TMPDIR:-/tmp}/emsys-verification.XXXXXX")"
cd "$project_root"

if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi

verify() {
    local name="$1"
    shift
    printf 'Checking %s…\n' "$name"
    if "$@" > "$log_directory/$name.log" 2>&1; then
        if [[ "$1" == xcodebuild ]]; then
            if ! python3 "$project_root/scripts/check-compiler-diagnostics.py" "$project_root" "$log_directory/$name.log"; then
                printf '\nFAIL %s compiler diagnostics. Logs: %s\n' "$name" "$log_directory" >&2
                exit 1
            fi
        fi
        printf 'PASS %s\n' "$name"
    else
        printf '\nFAIL %s. No later checks were run.\n' "$name" >&2
        tail -n 60 "$log_directory/$name.log" >&2
        printf '\nFull logs: %s\n' "$log_directory" >&2
        exit 1
    fi
}

common=(-project "$project" -scheme EMSYS)
verify packages xcodebuild "${common[@]}" -resolvePackageDependencies -onlyUsePackageVersionsFromResolvedFile
verify destinations xcodebuild "${common[@]}" -showdestinations -disableAutomaticPackageResolution
verify simulators xcrun simctl list devices available --json

# Select only destinations that Xcode says this scheme can actually build.
# Prefer already booted devices on the newest compatible installed runtime.
verify simulator-selection python3 - "$log_directory/destinations.log" "$log_directory/simulators.log" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text().split("Ineligible destinations", 1)[0]
simulators = json.loads(Path(sys.argv[2]).read_text())
booted = {device["udid"] for devices in simulators["devices"].values()
          for device in devices if device["state"] == "Booted"}
candidates = {"iPhone": {}, "iPad": {}}
for line in text.splitlines():
    if "platform:iOS Simulator," not in line:
        continue
    identity = re.search(r"\bid:([0-9A-Fa-f-]{36})\b", line)
    version = re.search(r"\bOS:([0-9.]+)", line)
    name = re.search(r"\bname:([^}]+)", line)
    if not (identity and version and name):
        continue
    identity = identity.group(1)
    for family in candidates:
        if name.group(1).strip().startswith(family):
            candidates[family][identity] = (tuple(map(int, version.group(1).split("."))), identity in booted)
for family, choices in candidates.items():
    if not choices:
        raise SystemExit(f"No eligible {family} simulator. Install a compatible iOS runtime in Xcode and rerun verification.")
    identity = max(choices, key=choices.get)
    print(f"platform=iOS Simulator,id={identity}")
PY
iphone_destination="$(sed -n '1p' "$log_directory/simulator-selection.log")"
ipad_destination="$(sed -n '2p' "$log_directory/simulator-selection.log")"

# Signing is disabled only for these local checks; saved project settings stay intact.
checks=(-disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO)
verify macos-tests xcodebuild "${common[@]}" -destination 'platform=macOS' "${checks[@]}" test
verify iphone-tests xcodebuild "${common[@]}" -destination "$iphone_destination" "${checks[@]}" test
verify ipad-tests xcodebuild "${common[@]}" -destination "$ipad_destination" "${checks[@]}" test
# Physical iPhones use a separate SDK/build graph from the simulator. Compile it
# too, without deploying or changing the owner's saved signing configuration.
verify iphone-device-build xcodebuild "${common[@]}" -destination 'generic/platform=iOS' "${checks[@]}" build
verify firebase-configuration python3 "$project_root/scripts/check-firebase-configuration.py" "$project"
verify macos-release xcodebuild "${common[@]}" -configuration Release -destination 'platform=macOS' "${checks[@]}" build
verify ios-release xcodebuild "${common[@]}" -configuration Release -destination 'generic/platform=iOS Simulator' "${checks[@]}" build
verify diff git diff --check
printf '\nAll verification checks passed. Logs: %s\n' "$log_directory"
