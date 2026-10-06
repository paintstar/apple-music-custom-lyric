#!/bin/bash
# 用法：scripts/build.sh [Debug|Release] [--unsigned]
# 默认沿用 Xcode 签名配置；--unsigned 仅用于编译验证，不生成分发签名或公证。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
case "$CONFIGURATION" in
  Debug|Release) ;;
  *) echo "用法：scripts/build.sh [Debug|Release] [--unsigned]" >&2; exit 2 ;;
esac
UNSIGNED=0
case "${2:-}" in
  "") ;;
  --unsigned) UNSIGNED=1 ;;
  *) echo "错误：未知参数；仅支持 --unsigned。" >&2; exit 2 ;;
esac
if [[ $# -gt 2 ]]; then
  echo "错误：参数过多。" >&2
  exit 2
fi

XCODE_VERSION="$(xcrun xcodebuild -version | sed -n 's/^Xcode //p')"
if [[ "${XCODE_VERSION%%.*}" -lt 26 ]]; then
  echo "错误：构建需要完整 Xcode 26 或更新版本。" >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo "错误：缺少 XcodeGen。" >&2; exit 1; }
cd "$ROOT"
xcodegen generate
BUILD_ARGS=(-project ShinApple.xcodeproj -scheme ShinApple
  -configuration "$CONFIGURATION" -derivedDataPath "$ROOT/.build/xcode")
if [[ "$UNSIGNED" -eq 1 ]]; then
  BUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO)
fi
xcrun xcodebuild "${BUILD_ARGS[@]}" build
echo "构建完成：.build/xcode/Build/Products/$CONFIGURATION/ShinApple.app"
