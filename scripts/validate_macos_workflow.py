"""Semantic validation of .github/workflows/macos-build.yaml.

Parses the workflow with a real YAML parser, then asserts the things that
actually break a macOS build. This complement checks cross-references into the
repository (scripts, bundle name, deployment target, Rust build gating) that no
generic YAML linter would catch.
"""

import re
import sys
from pathlib import Path

import yaml

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

REPO = Path(r"C:\Users\Mouren\Desktop\Project\astral-main")
WORKFLOW = REPO / ".github" / "workflows" / "macos-build.yaml"

errors: list[str] = []
warnings: list[str] = []


def fail(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


raw = WORKFLOW.read_bytes().decode("utf-8")

if "\r" in raw:
    fail("workflow contains CR characters; GitHub expects LF")

try:
    doc = yaml.safe_load(raw)
except yaml.YAMLError as exc:
    print(f"ERROR: workflow is not valid YAML: {exc}")
    sys.exit(1)

if not isinstance(doc, dict):
    print("ERROR: workflow root is not a mapping")
    sys.exit(1)

print("  ok: valid YAML")


# ------------------------------------------------------------- YAML 1.1 `on:`
# PyYAML resolves the bare key `on` to boolean True. Normalise it back.
def get_key(d: dict, name: str):
    if name in d:
        return d[name]
    if name == "on" and True in d:
        return d[True]
    return None


triggers = get_key(doc, "on")
if triggers is None:
    fail("no `on:` trigger block")
else:
    print(f"  ok: triggers = {sorted(triggers) if isinstance(triggers, dict) else triggers}")
    if "workflow_dispatch" not in triggers:
        fail("missing workflow_dispatch trigger (needed to run the build manually)")

jobs = doc.get("jobs")
if not isinstance(jobs, dict) or not jobs:
    print("ERROR: no jobs defined")
    sys.exit(1)

for job_name, job in jobs.items():
    runner = job.get("runs-on")
    if not runner:
        fail(f"job '{job_name}' has no runs-on")
    elif "macos" not in str(runner):
        fail(f"job '{job_name}' runs on '{runner}'; a macOS build needs a macOS runner")
    else:
        print(f"  ok: job '{job_name}' runs-on {runner}")

    steps = job.get("steps")
    if not isinstance(steps, list) or not steps:
        fail(f"job '{job_name}' has no steps")
        continue

    for i, step in enumerate(steps, 1):
        if not isinstance(step, dict):
            fail(f"job '{job_name}' step {i} is not a mapping")
            continue
        name = step.get("name", f"<step {i}>")
        has_uses = "uses" in step
        has_run = "run" in step
        if has_uses == has_run:
            fail(f"step '{name}': must have exactly one of uses/run")
        if "with" in step and not has_uses:
            fail(f"step '{name}': has `with` without `uses`")
        if has_run:
            body = step.get("run")
            if not isinstance(body, str) or not body.strip():
                fail(f"step '{name}': run body is empty")
            elif re.search(r"\|\s*tee\b", body) and "set -o pipefail" not in body:
                # Without pipefail the step reports tee's exit status, so a failed
                # build silently passes.
                fail(f"step '{name}': pipes into tee without `set -o pipefail`")
        if has_uses:
            ref = str(step["uses"])
            if not re.match(r"^[\w.\-]+/[\w.\-]+@[\w.\-]+$", ref):
                fail(f"step '{name}': malformed action ref '{ref}'")
            if "with" in step:
                w = step["with"]
                if not isinstance(w, dict) or not w:
                    fail(f"step '{name}': `with:` block is empty")
        if "run" in step and not step.get("run", "").strip().startswith(("set ", "flutter", "brew", "cd ", "xcode", "pod", "/", "$")):
            warn(f"step '{name}': run body does not start with an expected command")

    print(f"  ok: steps parsed = {len(steps)}")

# ------------------------------------------------------- cross-references
for m in re.finditer(r"\$GITHUB_WORKSPACE/(scripts/[A-Za-z0-9_.\-]+)", raw):
    rel = m.group(1)
    if not (REPO / rel).is_file():
        fail(f"workflow references missing script: {rel}")
    else:
        print(f"  ok: {rel} exists")

pubspec = (REPO / "pubspec.yaml").read_bytes().decode("utf-8")
vm = re.search(r"^version:\s*(\S+)$", pubspec, re.M)
if not vm:
    fail("could not read version from pubspec.yaml")
else:
    print(f"  ok: pubspec version = {vm.group(1)}")

appinfo = (REPO / "macos" / "Runner" / "Configs" / "AppInfo.xcconfig").read_bytes().decode("utf-8")
pm = re.search(r"^PRODUCT_NAME = (\S+)", appinfo, re.M)
product = pm.group(1) if pm else None
print(f"  ok: PRODUCT_NAME = {product}")
if product:
    expected_app = f"{product}.app"
    if f"/{expected_app}" not in raw:
        fail(f"workflow does not reference bundle {expected_app} (PRODUCT_NAME={product})")

pbx = (REPO / "macos" / "Runner.xcodeproj" / "project.pbxproj").read_bytes().decode("utf-8")
targets = sorted(set(re.findall(r"MACOSX_DEPLOYMENT_TARGET = ([0-9.]+);", pbx)))
print(f"  ok: deployment targets in pbxproj = {targets}")
if not targets:
    fail("no MACOSX_DEPLOYMENT_TARGET found in project.pbxproj")
elif any(t < "12.0" for t in targets):
    # Flutter's MacOSDeploymentTargetMigration rewrites anything below 12.0 to
    # 12.0; keeping the project on an older value breaks pod install because
    # FlutterMacOS.podspec requires a higher minimum.
    fail(f"deployment target below Flutter's minimum 12.0: {targets}")

podfile = (REPO / "macos" / "Podfile").read_bytes().decode("utf-8")
pm2 = re.search(r"platform :osx, '([0-9.]+)'", podfile)
print(f"  ok: Podfile platform = {pm2.group(1) if pm2 else None}")
if not pm2:
    fail("Podfile has no `platform :osx, '...'` line")
elif pm2.group(1) < "12.0":
    fail(f"Podfile deployment target below 12.0: {pm2.group(1)}")

buildrs = (REPO / "rust" / "build.rs").read_bytes().decode("utf-8")
if 'cfg(all(windows, target_env = "msvc"))' not in buildrs:
    fail("rust/build.rs npcap link is not windows-only; macOS build would fail")
else:
    print("  ok: rust/build.rs npcap link is windows-only")

# The Rust static library is force-loaded into the app, so Apple frameworks used
# by Rust crates must be declared in the podspec link flags. easytier pulls in
# system-configuration, whose SCDynamicStore*/SCNetwork* symbols live in
# SystemConfiguration.framework; without this the app fails to link.
podspec = (REPO / "rust_builder" / "macos" / "rust_lib_astral.podspec").read_bytes().decode("utf-8")
if "-framework SystemConfiguration" not in podspec:
    fail("rust_lib_astral.podspec does not link SystemConfiguration.framework")
else:
    print("  ok: podspec links SystemConfiguration.framework")
if "-force_load" not in podspec:
    fail("rust_lib_astral.podspec lost its -force_load of the Rust archive")

# ------------------------------------------------- required build behaviour
required = {
    "flutter build macos --release": "macOS release build",
    "hdiutil create": "DMG packaging",
    "pod install": "CocoaPods install",
    "rustup target add aarch64-apple-darwin": "Apple Silicon Rust target",
    "flutter pub get": "Dart dependency resolution",
    "codesign --force --deep --sign -": "ad-hoc signing fallback",
    "codesign --verify --deep --strict": "signature verification",
    "set -o pipefail": "pipefail so a failed build is not masked by tee",
}
for needle, what in required.items():
    if needle not in raw:
        fail(f"workflow is missing {what} (`{needle}`)")
    else:
        print(f"  ok: {what}")

# Third-party actions must be ones we can vouch for; an unexpected `uses:` is a
# supply-chain change worth failing on rather than silently trusting.
#
# These must also stay on Node 24-capable majors: GitHub force-runs Node 20
# actions on Node 24 and emits a deprecation warning. checkout/upload-artifact
# v4 and action-gh-release v1 are Node 20, hence v6/v6/v2 here.
known_actions = {
    "actions/checkout@v6",
    "actions/upload-artifact@v6",
    "actions/cache@v4",
    "softprops/action-gh-release@v2",
}
node20_actions = {
    "actions/checkout@v4",
    "actions/upload-artifact@v4",
    "softprops/action-gh-release@v1",
}
for ref in sorted(set(re.findall(r"uses: (\S+)", raw))):
    if ref in node20_actions:
        fail(f"action {ref} targets deprecated Node 20; bump to a Node 24 major")
    elif ref not in known_actions:
        fail(f"unvetted action reference: {ref}")
print(f"  ok: {len(known_actions)} vetted actions, all on Node 24 majors")

# Release publishing is optional and must be gated, otherwise every manual build
# would try to publish a release.
if "release_tag" not in raw:
    fail("workflow has no `release_tag` input for optional release publishing")
elif not re.search(r"if:\s*\$\{\{\s*github\.event_name == 'push'", raw):
    fail("release step is not gated on a tag push / explicit release_tag")
else:
    print("  ok: release publishing is opt-in and gated")

# Caching: the Rust build dominates the job (~1095s of ~1207s measured), so the
# cache must cover the cargo target dir. cargokit points --target-dir at Xcode's
# per-build TARGET_TEMP_DIR, which is uncacheable, so the workflow has to redirect
# it via CARGOKIT_CARGO_TARGET_DIR and cache that same fixed path.
if "CARGOKIT_CARGO_TARGET_DIR" not in raw:
    fail("workflow does not set CARGOKIT_CARGO_TARGET_DIR; cargo target dir "
         "stays in Xcode's per-build temp dir and cannot be cached")
else:
    print("  ok: cargo target dir redirected to a stable path")
if "actions/cache@" not in raw:
    fail("workflow does not use actions/cache")
else:
    print("  ok: actions/cache wired")
if "rust/target" not in raw:
    fail("workflow does not cache rust/target")

# Persistent fallback: actions/cache is evicted by GitHub after 7 days without
# access; Release assets are not. The snapshot must only be downloaded when the
# cache genuinely missed, otherwise every build pays ~800MB of transfer.
if "snapshot_cache" not in raw:
    fail("workflow has no snapshot_cache input for the durable Release fallback")
else:
    print("  ok: durable snapshot input present")
if "cache-hit != 'true'" not in raw:
    fail("snapshot restore is not gated on a cache miss; every build would "
         "download it unconditionally")
else:
    print("  ok: snapshot restore gated on cache miss")
if not re.search(r"^\s{2}schedule:", raw, re.M):
    fail("no `schedule:` trigger; the cache would expire after 7 idle days")
else:
    print("  ok: scheduled warm-up keeps the cache alive")
if "timeout-minutes" not in raw:
    warnings.append(
        "no timeout-minutes on the build job; a hung runner burns the 6h default"
    )

# Any step shelling out to `gh release ...` needs GH_TOKEN, otherwise gh fails
# and an `|| exit 0` guard turns that into a silent fallback. This exact bug
# shipped once: the restore step had no GH_TOKEN, so it always reported "no
# snapshot" and every build ran cold (measured 1382s vs 179s).
for i, step in enumerate(steps, 1):
    body = step.get("run")
    if not isinstance(body, str):
        continue
    if re.search(r"\bgh release\b", body):
        env = step.get("env") or {}
        if "GH_TOKEN" not in env:
            fail(
                f"step '{step.get('name', i)}' calls `gh release` without GH_TOKEN; "
                "it will fail and any fallback guard will hide it"
            )
        else:
            print(f"  ok: gh release step authenticated ({step.get('name', i)[:24]})")

# The redirected target dir must stay gitignored or a multi-GB artifact tree
# could be committed.
if not (
    (REPO / "rust" / ".gitignore").is_file()
    and "/target" in (REPO / "rust" / ".gitignore").read_bytes().decode("utf-8")
):
    fail("rust/.gitignore no longer ignores /target; cargo output could be committed")
else:
    print("  ok: rust/target is gitignored")

# The DMG must ship the Gatekeeper workaround, otherwise users hitting
# "app is damaged" have no path forward on an unsigned build.
if "macos/INSTALL.txt" not in raw:
    fail("workflow does not copy macos/INSTALL.txt into the DMG")
elif not (REPO / "macos" / "INSTALL.txt").is_file():
    fail("macos/INSTALL.txt does not exist")
else:
    print("  ok: DMG ships macos/INSTALL.txt")

# Signing must be able to fall back when no certificate secret is configured.
if "MACOS_CERT_P12" not in raw:
    fail("workflow has no certificate secret wiring (MACOS_CERT_P12)")
else:
    print("  ok: certificate import is secret-driven and optional")

print()
for w in warnings:
    print(f"WARN: {w}")
for e in errors:
    print(f"ERROR: {e}")
print()
print(f"RESULT: {'FAIL' if errors else 'PASS'} ({len(errors)} errors, {len(warnings)} warnings)")
sys.exit(1 if errors else 0)
