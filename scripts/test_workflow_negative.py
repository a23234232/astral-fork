"""Negative test for validate_macos_workflow.py.

Proves the workflow validator rejects workflows that are actually broken,
rather than only ever printing PASS.

Fixtures are written inside the repo (the sandbox blocks the system temp dir)
and removed afterwards.
"""

import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

REPO = Path(r"C:\Users\Mouren\Desktop\Project\astral-main")
VALIDATOR = REPO / "scripts" / "validate_macos_workflow.py"
TARGET = REPO / ".github" / "workflows" / "macos-build.yaml"
FIXTURE = REPO / "scripts" / "_fixture_workflow.yaml"
PY = sys.executable

good = TARGET.read_bytes().decode("utf-8")

MUTATIONS = {
    "tab indentation": lambda s: s.replace(
        "      - name: 🛠️ 检出代码仓库", "      - name: checkout\t# tab", 1
    ),
    "step with both uses and run": lambda s: s.replace(
        "      - name: 🐦 安装 Flutter\n        run: |",
        "      - name: 🐦 安装 Flutter\n        uses: actions/checkout@v6\n        run: |",
        1,
    ),
    "with block with no children": lambda s: s.replace(
        "        with:\n          fetch-depth: 0\n          lfs: true\n",
        "        with:\n        if: always()\n",
        1,
    ),
    "missing install script": lambda s: s.replace(
        "scripts/install_flutter.sh", "scripts/install_flutter_MISSING.sh"
    ),
    "empty run block": lambda s: s.replace(
        "        run: |\n          set -euo pipefail\n          xcode-select -p",
        "        run: |\n        continue-on-error: true\n          set -euo pipefail\n          xcode-select -p",
        1,
    ),
    "malformed action ref": lambda s: s.replace(
        "uses: actions/checkout@v6", "uses: actions/checkout", 1
    ),
    "regress to Node 20 action": lambda s: s.replace(
        "uses: actions/checkout@v6", "uses: actions/checkout@v4", 1
    ),
}


def run_validator(content: str) -> tuple[int, str]:
    FIXTURE.write_bytes(content.encode("utf-8"))
    src = VALIDATOR.read_text(encoding="utf-8").replace(
        'WORKFLOW = REPO / ".github" / "workflows" / "macos-build.yaml"',
        f'WORKFLOW = Path(r"{FIXTURE}")',
    )
    try:
        proc = subprocess.run([PY, "-c", src], capture_output=True)
    finally:
        FIXTURE.unlink(missing_ok=True)
    out = (proc.stdout or b"").decode("utf-8", "replace") + (proc.stderr or b"").decode(
        "utf-8", "replace"
    )
    return proc.returncode, out


rc, out = run_validator(good)
if rc != 0:
    print("SETUP FAILURE: pristine workflow did not pass")
    print(out)
    sys.exit(1)
print("ok  pristine workflow passes")

# The deployment-target check reads project.pbxproj, not the workflow fixture,
# so test it directly against a regressed copy of the real file.
failures = []
for name, mutate in MUTATIONS.items():
    mutated = mutate(good)
    if mutated == good:
        failures.append(f"{name}: mutation was a no-op (test is invalid)")
        continue
    rc, out = run_validator(mutated)
    if rc == 0:
        failures.append(f"{name}: validator PASSED a broken workflow")
        print(f"FAIL  {name}: not detected")
    else:
        first = next((l for l in out.splitlines() if l.startswith(("ERROR", "WARN"))), "")
        print(f"ok  {name}: rejected -> {first[:95]}")

# --- direct test of the pbxproj deployment-target guard
PBX = REPO / "macos" / "Runner.xcodeproj" / "project.pbxproj"
original = PBX.read_bytes().decode("utf-8")
try:
    PBX.write_bytes(original.replace("MACOSX_DEPLOYMENT_TARGET = 12.0;", "MACOSX_DEPLOYMENT_TARGET = 10.14;").encode("utf-8"))
    rc, out = run_validator(good)
    if rc == 0:
        failures.append("deployment target regression: not detected")
        print("FAIL  deployment target regression: not detected")
    else:
        first = next((l for l in out.splitlines() if l.startswith("ERROR")), "")
        print(f"ok  deployment target regression: rejected -> {first[:95]}")
finally:
    PBX.write_bytes(original.encode("utf-8"))

print()
if failures:
    print("NEGATIVE TEST FAILURES:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print(f"PASS: all {len(MUTATIONS)} workflow mutations + pbxproj guard detected")
