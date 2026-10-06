#!/bin/bash
# 本地与 GitHub Actions 共用：六包测试、类型检查、lint、安全审计、Release 构建。
# 真实 Music 授权与播放、需要窗口焦点的 GUI 回归单独人工执行。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
START="$(date +%s)"
PACKAGES=(ShinAppleKit ShinMusicScript ShinLyricsEngine ShinAppleData ShinAppServices ShinLyricsProvider)

for tool in git python3 swiftlint xcodegen; do
  command -v "$tool" >/dev/null || { echo "错误：缺少 $tool。" >&2; exit 1; }
done
xcrun xcodebuild -version
xcrun swift --version

for package in "${PACKAGES[@]}"; do
  echo "== swift test: $package"
  xcrun swift test --package-path "$ROOT/Packages/$package"
done

"$ROOT/scripts/app-typecheck.sh"
swiftlint lint --strict --quiet
"$ROOT/scripts/check-secrets.sh"
"$ROOT/scripts/audit-outbound.sh"
"$ROOT/scripts/build.sh" Release --unsigned

echo "ci-local：全部自动化门槛通过；耗时 $(( $(date +%s) - START )) 秒。"
