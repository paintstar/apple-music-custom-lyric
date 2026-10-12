#!/bin/bash
# 用法：scripts/build.sh [Debug|Release] [--unsigned] [--arch arm64|x86_64|universal] [--derived-data 路径]
# 默认沿用 Xcode 签名配置；--unsigned 仅用于编译验证，不生成分发签名或公证。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
case "$CONFIGURATION" in
  Debug|Release) ;;
  *) echo "用法：scripts/build.sh [Debug|Release] [--unsigned] [--arch arm64|x86_64|universal] [--derived-data 路径]" >&2; exit 2 ;;
esac
if [[ $# -gt 0 ]]; then shift; fi
UNSIGNED=0
ARCHITECTURE=""
DERIVED_DATA="$ROOT/.build/xcode"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned) UNSIGNED=1; shift ;;
    --arch)
      [[ $# -ge 2 ]] || { echo "错误：--arch 缺少参数。" >&2; exit 2; }
      case "$2" in
        arm64|x86_64|universal) ARCHITECTURE="$2" ;;
        *) echo "错误：架构仅支持 arm64、x86_64 或 universal。" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --derived-data)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "错误：--derived-data 缺少路径。" >&2; exit 2; }
      DERIVED_DATA="$2"
      if [[ "$DERIVED_DATA" != /* ]]; then DERIVED_DATA="$ROOT/$DERIVED_DATA"; fi
      shift 2 ;;
    *) echo "错误：未知构建参数。" >&2; exit 2 ;;
  esac
done

XCODE_VERSION="$(xcrun xcodebuild -version | sed -n 's/^Xcode //p')"
if [[ "${XCODE_VERSION%%.*}" -lt 26 ]]; then
  echo "错误：构建需要完整 Xcode 26 或更新版本。" >&2
  exit 1
fi
command -v xcodegen >/dev/null || { echo "错误：缺少 XcodeGen。" >&2; exit 1; }
cd "$ROOT"
xcodegen generate
BUILD_ARGS=(-project ShinApple.xcodeproj -scheme ShinApple
  -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED_DATA")
if [[ "$UNSIGNED" -eq 1 ]]; then
  BUILD_ARGS+=(CODE_SIGNING_ALLOWED=NO)
fi
if [[ -n "$ARCHITECTURE" ]]; then
  if [[ "$ARCHITECTURE" == universal ]]; then
    BUILD_ARGS+=("ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
  else
    BUILD_ARGS+=("ARCHS=$ARCHITECTURE" ONLY_ACTIVE_ARCH=NO)
  fi
fi
xcrun xcodebuild "${BUILD_ARGS[@]}" build
echo "构建完成：${DERIVED_DATA#"$ROOT/"}/Build/Products/$CONFIGURATION/ShinApple.app"
