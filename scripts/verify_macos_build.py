"""One-shot validation for the macOS build artifacts.

Runs every check that can be performed on a non-macOS host:
  1. workflow YAML parses and satisfies the macOS build requirements
  2. build script shell structure is sound (LF, quoting, block keywords, vars)
  3. negative tests prove both validators actually detect breakage

Anything that genuinely requires macOS/Xcode (compiling, pod install, DMG
creation) cannot run here and is verified in the workflow itself on the runner.

Usage:  python scripts/verify_macos_build.py
"""

import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

REPO = Path(__file__).resolve().parent.parent
PY = sys.executable

CHECKS = [
    ("workflow semantic validation", REPO / "scripts" / "validate_macos_workflow.py"),
    ("build script structural validation", REPO / "scripts" / "validate_macos_script.py"),
    ("workflow validator negative test", REPO / "scripts" / "test_workflow_negative.py"),
    ("script validator negative test", REPO / "scripts" / "test_validator_negative.py"),
]

results = []
for title, script in CHECKS:
    print("=" * 72)
    print(f"==> {title}")
    print("=" * 72)
    if not script.is_file():
        print(f"MISSING: {script}")
        results.append((title, False))
        continue
    proc = subprocess.run([PY, str(script)], capture_output=True)
    out = (proc.stdout or b"").decode("utf-8", "replace")
    err = (proc.stderr or b"").decode("utf-8", "replace")
    print(out, end="")
    if err.strip():
        print(err, end="")
    results.append((title, proc.returncode == 0))
    print()

print("=" * 72)
print("SUMMARY")
print("=" * 72)
failed = 0
for title, ok in results:
    print(f"  {'PASS' if ok else 'FAIL'}  {title}")
    if not ok:
        failed += 1

print()
if failed:
    print(f"RESULT: {failed}/{len(results)} checks FAILED")
    sys.exit(1)
print(f"RESULT: all {len(results)} checks passed")
print()
print("Note: compilation, pod install and DMG creation require macOS + Xcode and")
print("run inside .github/workflows/macos-build.yaml on the runner.")
