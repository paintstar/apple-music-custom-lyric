#!/bin/bash
# 自动获取模型集成回归：URLProtocol 拦截与挂起 HTTP，原创夹具、临时数据库及偏好隔离。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
SWIFT_COMPILER="${SWIFT_EXEC:-$(xcrun -f swiftc)}"
SDK="$(xcrun --show-sdk-path)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shin-auto-fetch-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$CHECK_DIR/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CLANG_MODULE_CACHE_PATH}"
# 默认使用本轮临时构建目录，避免读取过期模块或争抢其他回归的 SwiftPM 构建锁。
APP_PACKAGE_BUILD="$ROOT/Packages/ShinAppServices/.build"
MUSIC_PACKAGE_BUILD="$ROOT/Packages/ShinMusicScript/.build"
PROVIDER_PACKAGE_BUILD="$ROOT/Packages/ShinLyricsProvider/.build"
if [[ "${1:-}" != "--skip-build" ]]; then
    for package in ShinAppServices ShinMusicScript ShinLyricsProvider; do
        xcrun swift build --package-path "$ROOT/Packages/$package" --disable-sandbox \
            --scratch-path "$CHECK_DIR/$package"
    done
    APP_PACKAGE_BUILD="$CHECK_DIR/ShinAppServices"
    MUSIC_PACKAGE_BUILD="$CHECK_DIR/ShinMusicScript"
    PROVIDER_PACKAGE_BUILD="$CHECK_DIR/ShinLyricsProvider"
fi
APP_BUILD="$APP_PACKAGE_BUILD/$ARCH-apple-macosx/debug"
MUSIC_BUILD="$MUSIC_PACKAGE_BUILD/$ARCH-apple-macosx/debug"
PROVIDER_BUILD="$PROVIDER_PACKAGE_BUILD/$ARCH-apple-macosx/debug"
OBJECTS=()
for module in ShinAppServices ShinAppleData ShinAppleKit ShinLyricsEngine GRDB; do
    OBJECTS+=("$APP_BUILD/$module.build/"*.o)
done
for module in ShinMusicScript ShinMSObjC; do
    OBJECTS+=("$MUSIC_BUILD/$module.build/"*.o)
done
OBJECTS+=("$PROVIDER_BUILD/ShinLyricsProvider.build/"*.o)
APP_SOURCES=()
for source in "$ROOT"/App/*.swift; do
    if [[ "$(basename "$source")" != "ShinAppleApp.swift" ]]; then APP_SOURCES+=("$source"); fi
done
"$SWIFT_COMPILER" -module-cache-path "$CLANG_MODULE_CACHE_PATH" -parse-as-library -swift-version 6 \
    -sdk "$SDK" -target "$ARCH-apple-macosx14.0" \
    -I "$APP_BUILD/Modules" -I "$MUSIC_BUILD/Modules" -I "$PROVIDER_BUILD/Modules" \
    -Xcc "-I$APP_PACKAGE_BUILD/checkouts/GRDB.swift/Sources/GRDBSQLite" \
    -Xcc "-fmodule-map-file=$MUSIC_BUILD/ShinMSObjC.build/module.modulemap" \
    "${APP_SOURCES[@]}" \
    "$ROOT/scripts/auto-fetch-check.swift" "${OBJECTS[@]}" \
    -framework ScriptingBridge -lsqlite3 -o "$CHECK_DIR/auto-fetch-check"
# 切目录场景写 UserDefaults；通过 CFFIXED_USER_HOME 隔离到临时目录。
# Swift 检查执行前断言临时 HOME 已生效，不改写当前用户偏好。
mkdir -p "$CHECK_DIR/home"
export CFFIXED_USER_HOME="$(cd "$CHECK_DIR/home" && pwd)"
"$CHECK_DIR/auto-fetch-check"
