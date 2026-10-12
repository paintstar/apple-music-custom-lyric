#!/bin/bash
# 构建 Release，签名并生成 DMG / ZIP；不导入证书、不创建 tag、不上传或公证。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHITECTURE=arm64
SIGNING_MODE=auto
SKIP_BUILD=0
BUILD_DIR="$ROOT/.build/release-xcode"
OUTPUT_DIR="$ROOT/.build/release"

usage() {
  echo "用法：scripts/package-release.sh [--arch arm64|x86_64|universal] [--signing auto|ad-hoc|developer-id] [--skip-build]"
  echo "默认构建 Apple Silicon；auto 使用 APPLE_SIGNING_IDENTITY，未配置时采用 ad-hoc 签名。"
}
fail() { echo "错误：$1" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      case "$2" in
        arm64|x86_64|universal) ARCHITECTURE="$2" ;;
        *) echo "错误：不支持的架构。" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --signing)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      case "$2" in
        auto|ad-hoc|developer-id) SIGNING_MODE="$2" ;;
        *) echo "错误：不支持的签名模式。" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "错误：未知打包参数。" >&2; usage >&2; exit 2 ;;
  esac
done

SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
if [[ "$SIGNING_MODE" == auto ]]; then
  if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != - ]]; then
    SIGNING_MODE=developer-id
  else
    SIGNING_MODE=ad-hoc
  fi
fi
if [[ "$SIGNING_MODE" == developer-id ]]; then
  [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != - ]] || fail "Developer ID 模式需要本机 APPLE_SIGNING_IDENTITY。"
else
  SIGNING_IDENTITY=-
fi

for tool in codesign ditto hdiutil plutil xcrun; do
  command -v "$tool" >/dev/null || fail "缺少打包工具 ${tool}。"
done
cd "$ROOT"
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  bash scripts/build.sh Release --unsigned --arch "$ARCHITECTURE" --derived-data "$BUILD_DIR"
fi

APP="$BUILD_DIR/Build/Products/Release/ShinApple.app"
INFO="$APP/Contents/Info.plist"
[[ -f "$INFO" ]] || fail "缺少 Release App；先执行默认打包命令完成构建。"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO" 2>/dev/null; }
VERSION="$(plist_value CFBundleShortVersionString)" || fail "App 缺少版本号。"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "App 版本号不适合发布包命名。"
[[ "$(plist_value CFBundlePackageType)" == APPL ]] || fail "构建产物不是 macOS App。"
EXECUTABLE="$(plist_value CFBundleExecutable)" || fail "App 缺少可执行文件声明。"
[[ -n "$EXECUTABLE" && "$EXECUTABLE" != */* && "$EXECUTABLE" != .* ]] || fail "App 可执行文件声明无效。"
[[ -x "$APP/Contents/MacOS/$EXECUTABLE" ]] || fail "App 缺少可执行文件。"
[[ -n "$(plist_value NSAppleEventsUsageDescription)" ]] || fail "App 缺少 Music 自动化用途说明。"
[[ -s "$APP/Contents/Resources/ThirdPartyNotices.txt" && -s "$ROOT/LICENSE" ]] || fail "App 缺少分发所需的许可证。"

# 包名依据实际 Mach-O 架构，同时拒绝把旧架构产物冒充本次请求的构建。
ACTUAL_ARCHITECTURES="$(xcrun lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")" || fail "无法读取 App 架构。"
case "$ACTUAL_ARCHITECTURES" in
  arm64) PACKAGE_ARCH=arm64 ;;
  x86_64) PACKAGE_ARCH=x86_64 ;;
  "arm64 x86_64"|"x86_64 arm64") PACKAGE_ARCH=universal ;;
  *) fail "App 含不支持的架构组合。" ;;
esac
[[ "$PACKAGE_ARCH" == "$ARCHITECTURE" ]] || fail "现有 App 的架构与请求不符，请去掉 --skip-build 重新构建。"

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.package.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
DMG_ROOT="$WORK_DIR/dmg"
mkdir "$DMG_ROOT"
STAGED_APP="$DMG_ROOT/ShinApple.app"
# 只复制构建 App；不把源码、日志、数据库、开发环境或签名材料装入安装包。
ditto --norsrc --noextattr "$APP" "$STAGED_APP"
cp "$ROOT/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE.txt"
UNEXPECTED_FILE="$(find "$STAGED_APP" \( -name '.env' -o -name '.env.*' -o -name '*.p12' -o -name '*.p8' -o -name '*.pem' -o -name '*.key' -o -name '*.mobileprovision' -o -name '*.sqlite*' -o -name '*.db' -o -name '*.db-*' -o -name '*.log' -o -name '.git' -o -name 'xcuserdata' \) -print -quit)"
[[ -z "$UNEXPECTED_FILE" ]] || fail "App 含不应分发的开发或本机数据文件，已停止打包。"

SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_MODE" == developer-id ]]; then
  # 仅在发行副本启用 Hardened Runtime，并允许公开 Music Apple Events。
  RELEASE_ENTITLEMENTS="$WORK_DIR/Release.entitlements"
  cp "$ROOT/App/ShinApple.entitlements" "$RELEASE_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Set :com.apple.security.automation.apple-events true" "$RELEASE_ENTITLEMENTS" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :com.apple.security.automation.apple-events bool true" "$RELEASE_ENTITLEMENTS"
  SIGN_ARGS+=(--entitlements "$RELEASE_ENTITLEMENTS" --options runtime --timestamp)
else
  SIGN_ARGS+=(--timestamp=none)
fi
codesign "${SIGN_ARGS[@]}" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
SIGNATURE_INFO="$(codesign --display --verbose=4 "$STAGED_APP" 2>&1)"
if [[ "$SIGNING_MODE" == developer-id ]]; then
  [[ "$SIGNATURE_INFO" == *"Authority=Developer ID Application:"* ]] || fail "签名身份不是 Developer ID Application，已停止打包。"
  SIGNING_DESCRIPTION="Developer ID 已签名，未公证"
else
  [[ "$SIGNATURE_INFO" == *"Signature=adhoc"* ]] || fail "App 未获得预期的 ad-hoc 签名。"
  SIGNING_DESCRIPTION="ad-hoc 已签名，未公证"
fi

PACKAGE_NAME="ShinApple-${VERSION}-macOS-${PACKAGE_ARCH}"
ditto -c -k --norsrc --noextattr --keepParent "$STAGED_APP" "$WORK_DIR/$PACKAGE_NAME.zip"
# /Applications 是 macOS 的系统安装目录，不是开发者个人路径。
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -quiet -volname "ShinApple $VERSION" -srcfolder "$DMG_ROOT" -format UDZO "$WORK_DIR/$PACKAGE_NAME.dmg"
hdiutil verify -quiet "$WORK_DIR/$PACKAGE_NAME.dmg"

cat > "$WORK_DIR/RELEASE-NOTES.md" <<EOF
# ShinApple $VERSION

macOS 歌曲语言学习播放器。官方「音乐」App 负责账号与音频播放，学习资料保存在本机。

- 资料库浏览、搜索、选歌播放，完整与紧凑播放器，以及播放列表和随机播放。
- 同步双语歌词、行级重听、歌词导入与编辑；新增可调整大小、锁定和置顶的独立悬浮歌词窗。
- 网易云歌词手动获取与所选播放列表自动获取，保护人工导入和编辑内容。
- 本地歌词库、LRC 导出、JSON 备份恢复和可配置数据目录。
- 提供 DMG 拖到 Applications 安装及 ZIP 解压安装。

系统要求：macOS 14.0 及以上。此安装包架构：${PACKAGE_ARCH}。安装包${SIGNING_DESCRIPTION}。

下载 DMG 后打开，将 ShinApple 拖到 Applications；或解压 ZIP，将 ShinApple.app 移到 Applications。首次启动时允许控制「音乐」App。若 macOS 提示无法验证开发者，确认来源后按 [Apple 官方说明](https://support.apple.com/zh-cn/102445) 操作。

升级安装保留原有本地学习资料；建议先在设置中导出 JSON 备份。真实 Music 授权与播放、在线歌词获取仍需在实际用户环境中确认。
EOF

# 所有检查完成后才更新最终文件；失败时保留此前成功的安装包。
mv -f "$WORK_DIR/$PACKAGE_NAME.zip" "$OUTPUT_DIR/$PACKAGE_NAME.zip"
mv -f "$WORK_DIR/$PACKAGE_NAME.dmg" "$OUTPUT_DIR/$PACKAGE_NAME.dmg"
mv -f "$WORK_DIR/RELEASE-NOTES.md" "$OUTPUT_DIR/RELEASE-NOTES.md"
echo "打包完成：.build/release/$PACKAGE_NAME.dmg"
echo "打包完成：.build/release/$PACKAGE_NAME.zip"
echo "签名状态：${SIGNING_DESCRIPTION}。"
