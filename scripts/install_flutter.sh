#!/bin/bash
# 统一的Flutter安装脚本 (Linux/macOS)
# FLUTTER_VERSION=beta 表示克隆 beta 分支，即最新 beta 预发布版

set -e

FLUTTER_VERSION="${FLUTTER_VERSION:-beta}"
FLUTTER_PATH="${HOME}/flutter"

echo "=========================================="
echo "🐦 安装 Flutter"
echo "版本: $FLUTTER_VERSION"
echo "=========================================="

# 克隆 Flutter 仓库（已存在则复用，避免 CI 上重复克隆）
if [ -d "$FLUTTER_PATH/.git" ]; then
  echo "复用已存在的 Flutter: $FLUTTER_PATH"
else
  echo "正在克隆 Flutter $FLUTTER_VERSION 分支..."
  git clone https://github.com/flutter/flutter.git --branch "$FLUTTER_VERSION" "$FLUTTER_PATH" --depth 1
fi

# 添加到 PATH
# export 只影响本脚本，$GITHUB_PATH 只影响后续步骤，两者都要做：
# 调用方若在本脚本之后继续使用 flutter，必须自行 source 下面的 env 文件。
export PATH="$FLUTTER_PATH/bin:$PATH"
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$FLUTTER_PATH/bin" >> "$GITHUB_PATH"
fi

# 授予执行权限
chmod +x "$FLUTTER_PATH/bin/flutter"

# 验证安装
echo "验证 Flutter 安装..."
flutter --version
echo "✅ Flutter 安装完成！"
