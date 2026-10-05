#!/usr/bin/env bash
#
# 在 macOS 主机上构建 Astral 并打包为 DMG。
#
# 前置条件（需已安装 Xcode，这是 Apple 工具链的硬性要求）：
#   xcode-select --install          # 或从 App Store 安装完整 Xcode
#   sudo xcodebuild -runFirstLaunch
#
# 与 .github/workflows/macos-build.yaml 执行完全相同的步骤，
# 区别只是跑在本地机器上。
#
# 用法：
#   ./scripts/build_macos_dmg.sh                 # 默认 release
#   FLUTTER_VERSION=stable ./scripts/build_macos_dmg.sh
#   SKIP_BREW=1 ./scripts/build_macos_dmg.sh     # 跳过 brew 安装依赖

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FLUTTER_VERSION="${FLUTTER_VERSION:-beta}"
RUST_VERSION="${RUST_VERSION:-1.89.0}"
SKIP_BREW="${SKIP_BREW:-0}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 环境检查
[[ "$(uname -s)" == "Darwin" ]] || die "此脚本只能在 macOS 上运行（当前：$(uname -s)）"

log "检查 Xcode"
xcode-select -p >/dev/null 2>&1 || die "未找到 Xcode。请运行：xcode-select --install"
xcodebuild -version || die "xcodebuild 不可用"
sudo xcodebuild -runFirstLaunch >/dev/null 2>&1 || true

log "读取版本号"
APP_VERSION="$(grep '^version:' pubspec.yaml | head -1 | awk '{print $2}' | tr -d '\r')"
APP_VERSION="${APP_VERSION%%+*}"
echo "APP_VERSION=$APP_VERSION"

# ---------------------------------------------------------------- 依赖安装
if [[ "$SKIP_BREW" != "1" ]]; then
  log "安装系统依赖 (brew)"
  command -v brew >/dev/null 2>&1 || die "未找到 Homebrew：https://brew.sh"
  brew list protobuf >/dev/null 2>&1 || brew install protobuf
  brew list cmake    >/dev/null 2>&1 || brew install cmake
  brew list ninja    >/dev/null 2>&1 || brew install ninja
  brew list cocoapods >/dev/null 2>&1 || brew install cocoapods
fi

log "装好 protoc / pod"
protoc --version
pod --version

log "设置 Rust $RUST_VERSION"
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain "$RUST_VERSION" --profile minimal
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi
rustup toolchain install "$RUST_VERSION" --profile minimal >/dev/null 2>&1 || true
rustup default "$RUST_VERSION"
# cargokit 会在 Xcode 构建阶段按目标架构调用 cargo。
rustup target add aarch64-apple-darwin x86_64-apple-darwin
rustc --version

log "安装 Flutter ($FLUTTER_VERSION)"
if ! command -v flutter >/dev/null 2>&1; then
  FLUTTER_PATH="${HOME}/flutter"
  if [[ ! -d "$FLUTTER_PATH" ]]; then
    git clone https://github.com/flutter/flutter.git \
      --branch "$FLUTTER_VERSION" "$FLUTTER_PATH" --depth 1
  fi
  export PATH="$FLUTTER_PATH/bin:$PATH"
fi
flutter --version
flutter config --enable-macos-desktop

log "获取 Flutter 依赖"
flutter precache --macos
flutter pub get

log "安装 CocoaPods 依赖"
cd macos
# 仓库内提交的 Podfile.lock 早于当前 pubspec 依赖集，直接重建以免冲突。
rm -f Podfile.lock
pod install --repo-update
cd "$REPO_ROOT"

log "构建 macOS 应用 (release)"
flutter build macos --release --build-name="$APP_VERSION"

APP="build/macos/Build/Products/Release/astral.app"
[[ -d "$APP" ]] || die "构建产物不存在：$APP"

log "校验产物"
lipo -info "$APP/Contents/MacOS/astral"
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" || true
otool -L "$APP/Contents/MacOS/astral" | head -10

log "签名 .app"
# 有 Developer ID 证书时用 SIGN_IDENTITY 指定（如 "Developer ID Application"），
# 否则走 ad-hoc 签名：不需要账号，但无法通过 Gatekeeper，仅供本地使用。
IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
  echo "已使用 ad-hoc 签名（无证书）"
else
  IDENTITY_HASH="$(security find-identity -v -p codesigning | awk -v pat="$IDENTITY" '$0 ~ pat {print $2; exit}')"
  [[ -n "$IDENTITY_HASH" ]] || die "keychain 中找不到匹配 '$IDENTITY' 的签名证书"
  codesign --force --deep --options runtime --timestamp \
    --entitlements macos/Runner/Release.entitlements \
    --sign "$IDENTITY_HASH" "$APP"
  echo "已使用 $IDENTITY 签名"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier|Signature|Authority' || true
spctl -a -vvv "$APP" 2>&1 || echo "（未通过 Gatekeeper 评估，未签名产物属预期）"

log "打包 DMG"
mkdir -p release
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# 未签名时把放行说明一起放进 DMG，避免用户看到"应用已损坏"无从下手。
cp macos/INSTALL.txt "$STAGE/安装说明.txt"

DMG="release/astral-macos-$(uname -m).dmg"
rm -f "$DMG"
hdiutil create -volname "Astral" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
rm -rf "$STAGE"

log "完成"
ls -lh "$DMG"
echo
echo "注意：产物默认使用 ad-hoc 签名，首次打开会被 Gatekeeper 拦截。"
echo "DMG 内已附「安装说明.txt」，或执行："
echo "  xattr -dr com.apple.quarantine /Applications/astral.app"
