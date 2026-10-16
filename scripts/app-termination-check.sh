#!/bin/bash
# 退出设置与延迟退出检查：只编译独立接线，使用隔离偏好和虚构清理闭包，不控制 Music 或退出 App。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
SWIFT_COMPILER="${SWIFT_EXEC:-$(xcrun -f swiftc)}"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shin-app-termination-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
"$SWIFT_COMPILER" -parse-as-library -swift-version 6 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target "$ARCH-apple-macosx14.0" \
    "$ROOT/App/PlaybackCleanupSettings.swift" "$ROOT/App/AppTerminationDelegate.swift" \
    "$ROOT/scripts/app-termination-check.swift" -o "$CHECK_DIR/app-termination-check"
mkdir -p "$CHECK_DIR/home"
export CFFIXED_USER_HOME="$(cd "$CHECK_DIR/home" && pwd)"
"$CHECK_DIR/app-termination-check"
