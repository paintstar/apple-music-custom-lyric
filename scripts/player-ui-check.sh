#!/bin/bash
# App 模型回归：只使用临时数据库、原创歌词和测试控制器，不访问 Music.app。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
SWIFT_COMPILER="${SWIFT_EXEC:-$(xcrun -f swiftc)}"
SDK="$(xcrun --show-sdk-path)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shin-player-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$CHECK_DIR/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CLANG_MODULE_CACHE_PATH}"
if [[ "${1:-}" != "--skip-build" ]]; then
for package in ShinAppServices ShinMusicScript ShinLyricsProvider; do
    swift build --package-path "$ROOT/Packages/$package" --disable-sandbox \
        --cache-path "$CHECK_DIR/swift-cache"
done
fi
APP_BUILD="$ROOT/Packages/ShinAppServices/.build/$ARCH-apple-macosx/debug"
MUSIC_BUILD="$ROOT/Packages/ShinMusicScript/.build/$ARCH-apple-macosx/debug"
PROVIDER_BUILD="$ROOT/Packages/ShinLyricsProvider/.build/$ARCH-apple-macosx/debug"
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
    -Xcc "-I$ROOT/Packages/ShinAppServices/.build/checkouts/GRDB.swift/Sources/GRDBSQLite" \
    -Xcc "-fmodule-map-file=$MUSIC_BUILD/ShinMSObjC.build/module.modulemap" \
    "${APP_SOURCES[@]}" \
    "$ROOT/scripts/player-ui-check.swift" "$ROOT/scripts/lyrics-motion-ui-check.swift" \
    "$ROOT/scripts/playback-progress-ui-check.swift" "${OBJECTS[@]}" \
    -framework ScriptingBridge -lsqlite3 -o "$CHECK_DIR/player-ui-check"
"$CHECK_DIR/player-ui-check"
