#!/bin/bash
# 资料库浏览模型检查：只用原创内存夹具，不读取或控制真实 Music。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
SWIFT_COMPILER="${SWIFT_EXEC:-$(xcrun -f swiftc)}"
SDK="$(xcrun --show-sdk-path)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shin-library-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$CHECK_DIR/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CLANG_MODULE_CACHE_PATH}"
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build --package-path "$ROOT/Packages/ShinAppleKit" --disable-sandbox --cache-path "$CHECK_DIR/swift-cache"
fi
KIT_BUILD="$ROOT/Packages/ShinAppleKit/.build/$ARCH-apple-macosx/debug"
"$SWIFT_COMPILER" -module-cache-path "$CLANG_MODULE_CACHE_PATH" -parse-as-library -swift-version 6 \
    -sdk "$SDK" -target "$ARCH-apple-macosx14.0" -I "$KIT_BUILD/Modules" \
    "$ROOT/App/MusicLibraryBrowserModel.swift" "$ROOT/scripts/library-ui-check.swift" \
    "$KIT_BUILD/ShinAppleKit.build/"*.o -o "$CHECK_DIR/library-ui-check"
"$CHECK_DIR/library-ui-check"
