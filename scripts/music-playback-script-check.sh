#!/bin/bash
# 纯AppleScript分支检查：Swift只导出原创夹具，shell解释器不含任何Music事件。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
SWIFT_COMPILER="${SWIFT_EXEC:-$(xcrun -f swiftc)}"
SDK="$(xcrun --show-sdk-path)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shin-playback-script-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
if [[ "${1:-}" != "--skip-build" ]]; then
    swift build --package-path "$ROOT/Packages/ShinMusicScript"
fi
BUILD="$ROOT/Packages/ShinMusicScript/.build/$ARCH-apple-macosx/debug"
"$SWIFT_COMPILER" -swift-version 6 -parse-as-library -sdk "$SDK" -target "$ARCH-apple-macosx14.0" -I "$BUILD/Modules" \
    -Xcc "-fmodule-map-file=$BUILD/ShinMSObjC.build/module.modulemap" \
    "$ROOT/scripts/music-playback-script-check.swift" \
    "$BUILD/ShinMusicScript.build/"*.o "$BUILD/ShinAppleKit.build/"*.o "$BUILD/ShinMSObjC.build/"*.o \
    -o "$CHECK_DIR/export-fixtures"
"$CHECK_DIR/export-fixtures" "$CHECK_DIR"
for source in "$CHECK_DIR/"*.applescript; do
    result="$(/usr/bin/osascript "$source")"
    [[ "$result" == "ok" ]] || { echo "播放脚本检查失败。" >&2; exit 1; }
done
echo "播放脚本检查通过（12份原创内存夹具，无Music事件）。"
