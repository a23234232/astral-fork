"""Negative test: prove validate_macos_script.py fails on genuinely broken scripts.

A validator that only ever prints PASS proves nothing. This mutates the real
script in known-bad ways and asserts the validator rejects each one.

Fixtures are piped through stdin so no temporary files are needed (the sandbox
does not grant write access to the system temp directory).
"""

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(r"C:\Users\Mouren\Desktop\Project\astral-main")
VALIDATOR = REPO / "scripts" / "validate_macos_script.py"
TARGET = REPO / "scripts" / "build_macos_dmg.sh"
PY = sys.executable

good = TARGET.read_bytes().decode("utf-8")

MUTATIONS = {
    "unclosed if": lambda s: s.replace("fi\n", "", 1),
    "missing shebang": lambda s: s.replace("#!/usr/bin/env bash\n", "", 1),
    "no strict mode": lambda s: s.replace("set -euo pipefail", "echo hi", 1),
    "CRLF line endings": lambda s: s.replace("\n", "\r\n"),
    "unterminated quote": lambda s: s.replace(
        'lipo -info "$APP/Contents/MacOS/astral"', 'lipo -info "$APP/Contents/MacOS/astral', 1
    ),
    "wrong app bundle path": lambda s: s.replace(
        "build/macos/Build/Products/Release/astral.app",
        "build/macos/Build/Products/Release/Astral.app",
    ),
    "missing rust targets": lambda s: s.replace(
        "rustup target add aarch64-apple-darwin x86_64-apple-darwin", "echo skipped", 1
    ),
    "undeclared variable": lambda s: s.replace(
        'lipo -info "$APP/Contents/MacOS/astral"', 'lipo -info "$TOTALLY_UNDEFINED_VAR"', 1
    ),
    "no dmg packaging": lambda s: s.replace("hdiutil create", "echo no-dmg", 1),
    "stale podfile lock kept": lambda s: s.replace("rm -f Podfile.lock", "echo keep-lock", 1),
}


def run_validator(content: str) -> tuple[int, str]:
    # Force the stdin path by pointing SCRIPT at a nonexistent file.
    src = VALIDATOR.read_text(encoding="utf-8").replace(
        'SCRIPT = REPO / "scripts" / "build_macos_dmg.sh"',
        'SCRIPT = REPO / "scripts" / "__does_not_exist__.sh"',
    )
    proc = subprocess.run(
        [PY, "-c", src],
        input=content.encode("utf-8"),
        capture_output=True,
    )
    return proc.returncode, (proc.stdout or b"").decode("utf-8", "replace") + (
        proc.stderr or b""
    ).decode("utf-8", "replace")


# Sanity: the pristine script must pass.
rc, out = run_validator(good)
if rc != 0:
    print("SETUP FAILURE: pristine script did not pass")
    print(out)
    sys.exit(1)
print("ok  pristine script passes")

failures = []
for name, mutate in MUTATIONS.items():
    mutated = mutate(good)
    if mutated == good:
        failures.append(f"{name}: mutation was a no-op (test is invalid)")
        continue
    rc, out = run_validator(mutated)
    if rc == 0:
        failures.append(f"{name}: validator PASSED a broken script")
        print(f"FAIL  {name}: not detected")
    else:
        first = next((l for l in out.splitlines() if l.startswith("ERROR")), "")
        print(f"ok  {name}: rejected -> {first[:95]}")

print()
if failures:
    print("NEGATIVE TEST FAILURES:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print(f"PASS: all {len(MUTATIONS)} mutations detected")
