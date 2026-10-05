"""Structural validation for scripts/build_macos_dmg.sh.

No shell available under the workspace sandbox (MSYS bash cannot create pipes),
so this checks the properties that actually cause runtime failures: balanced
quoting, matched block keywords, defined variables, and referenced paths.
"""

import re
import sys
from pathlib import Path

REPO = Path(r"C:\Users\Mouren\Desktop\Project\astral-main")
SCRIPT = REPO / "scripts" / "build_macos_dmg.sh"

errors: list[str] = []
warnings: list[str] = []

# Read as bytes and decode manually: text mode would translate CRLF -> LF and
# silently hide the line-ending defect that breaks bash on macOS.
if SCRIPT.is_file():
    text = SCRIPT.read_bytes().decode("utf-8")
else:
    text = sys.stdin.buffer.read().decode("utf-8")
lines = text.split("\n")

if "\r" in text:
    errors.append("script contains CR characters; must be LF-only for macOS")

if not text.startswith("#!/usr/bin/env bash"):
    errors.append("missing or non-portable shebang")

if "set -euo pipefail" not in text:
    errors.append("missing `set -euo pipefail`")

# --- block keyword balance, ignoring comments and quoted strings
def strip_comment(line: str) -> str:
    out, i, in_s, in_d = [], 0, False, False
    while i < len(line):
        c = line[i]
        if c == "'" and not in_d:
            in_s = not in_s
        elif c == '"' and not in_s:
            in_d = not in_d
        elif c == "#" and not in_s and not in_d:
            break
        out.append(c)
        i += 1
    return "".join(out)


code = "\n".join(strip_comment(ln) for ln in lines)

# Count block openers only where they start a command position: at the beginning
# of a line, or after a control operator (&&, ||, ;, |, then, else, do).
for opener, closer in [("if", "fi"), ("case", "esac")]:
    n_open = len(re.findall(rf"(?:^|[;&|]|\bthen\b|\belse\b|\bdo\b)\s*{opener}\b", code, re.M))
    n_close = len(re.findall(rf"(?:^|[;&|]|\bthen\b|\belse\b|\bdo\b|\s){closer}\b", code, re.M))
    if n_open != n_close:
        errors.append(f"unbalanced {opener}/{closer}: {n_open} vs {n_close}")
    else:
        print(f"  ok: {opener}/{closer} balanced ({n_open})")

for opener, closer in [("do", "done")]:
    n_open = len(re.findall(r"\bdo\b", code))
    n_close = len(re.findall(rf"\b{closer}\b", code))
    if n_open != n_close:
        errors.append(f"unbalanced {opener}/{closer}: {n_open} vs {n_close}")
    else:
        print(f"  ok: {opener}/{closer} balanced ({n_open})")

# --- unterminated quotes per line (single-line heuristic)
for i, line in enumerate(lines, 1):
    stripped = strip_comment(line)
    if stripped.count('"') % 2 != 0:
        errors.append(f"line {i}: odd number of double quotes: {line.strip()[:70]}")
    if stripped.count("'") % 2 != 0:
        errors.append(f"line {i}: odd number of single quotes: {line.strip()[:70]}")

# --- command substitution balance
if code.count("$(") != code.count(")"):
    warnings.append("possible unbalanced $( ) nesting (heuristic, may be benign)")

# --- every variable referenced must be assigned somewhere
assigned = set(re.findall(r"^([A-Z_][A-Z0-9_]*)=", code, re.M))
assigned |= set(re.findall(r"^\s*([A-Z_][A-Z0-9_]*)=", code, re.M))
assigned |= set(re.findall(r"for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in", code))
assigned |= {"BASH_SOURCE", "HOME", "PATH", "PWD", "GITHUB_PATH", "REPO_ROOT", "FLUTTER_PATH"}
referenced = set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", code))
referenced |= set(re.findall(r"\$([A-Z_][A-Z0-9_]{2,})\b", code))
undeclared = {v for v in referenced if v not in assigned}
if undeclared:
    errors.append(f"referenced but never assigned (would fail under set -u): {sorted(undeclared)}")
else:
    print(f"  ok: all {len(referenced)} referenced variables are assigned")

# --- key paths must match the real project
expected = {
    "build/macos/Build/Products/Release/astral.app": "app bundle path",
}
for needle, what in expected.items():
    if needle not in text:
        errors.append(f"missing {what}: {needle}")

if "flutter build macos --release" not in text:
    errors.append("missing `flutter build macos --release`")

if "hdiutil create" not in text:
    errors.append("missing `hdiutil create` for DMG packaging")

if "rustup target add aarch64-apple-darwin x86_64-apple-darwin" not in text:
    errors.append("missing rustup target add for Apple Darwin targets")

if "rm -f Podfile.lock" not in text:
    errors.append("missing stale Podfile.lock removal")

# --- shellcheck-ish: unquoted variable in a path position
for i, line in enumerate(lines, 1):
    for m in re.finditer(r"(?<![{\"'=])\$(APP_VERSION|APP|DMG|STAGE|REPO_ROOT|FLUTTER_PATH)\b(?![\"'])", line):
        stripped = line.strip()
        if stripped.startswith("#") or "=" in stripped.split(m.group(0))[0][:2]:
            continue
    if re.search(r"\brm -rf \$[A-Za-z_]", line) and '"' not in line:
        errors.append(f"line {i}: rm -rf with unquoted variable -> {line.strip()}")

print()
for w in warnings:
    print(f"WARN: {w}")
for e in errors:
    print(f"ERROR: {e}")
print()
print(f"RESULT: {'FAIL' if errors else 'PASS'} ({len(errors)} errors, {len(warnings)} warnings)")
sys.exit(1 if errors else 0)
