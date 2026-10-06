#!/bin/bash
# App 全源码类型检查；使用用户选择的完整 Xcode 工具链。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGES=(ShinAppleKit ShinMusicScript ShinLyricsEngine ShinAppleData ShinAppServices ShinLyricsProvider)
ARCH="$(uname -m)"
SWIFT_COMPILER="${SWIFT_EXEC:-$(xcrun --find swiftc)}"

XCODE_VERSION="$(xcrun xcodebuild -version | sed -n 's/^Xcode //p')"
if [[ "${XCODE_VERSION%%.*}" -lt 26 ]]; then
  echo "错误：App 检查需要完整 Xcode 26 或更新版本；请检查 DEVELOPER_DIR 或 xcode-select 配置。" >&2
  exit 1
fi

INCLUDE_ARGS=()
for package in "${PACKAGES[@]}"; do
  echo "== swift build: $package"
  xcrun swift build --package-path "$ROOT/Packages/$package"
  package_build="$(xcrun swift build --package-path "$ROOT/Packages/$package" --show-bin-path)"
  INCLUDE_ARGS+=(-I "$package_build/Modules")
  if [[ "$package" == ShinMusicScript ]]; then
    INCLUDE_ARGS+=(-Xcc "-fmodule-map-file=$package_build/ShinMSObjC.build/module.modulemap")
  fi
done

# GRDB 的 Clang 模块与 SwiftPM 生成的 Music ObjC 模块属于真实编译依赖。
GRDB_SQLITE="$ROOT/Packages/ShinAppleData/.build/checkouts/GRDB.swift/Sources/GRDBSQLite"
INCLUDE_ARGS+=(-Xcc "-I$GRDB_SQLITE")
"$SWIFT_COMPILER" -typecheck \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$ARCH-apple-macosx14.0" -swift-version 6 \
  "${INCLUDE_ARGS[@]}" "$ROOT"/App/*.swift

echo "App typecheck 通过（Swift 6，最低目标 macOS 14.0）。"
