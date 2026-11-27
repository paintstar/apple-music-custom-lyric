#!/bin/bash
# scripts/audit-outbound.sh — 现行脚本路线的出站与播放边界静态审计
#
# App 与各包（含测试）禁止直接网络/子进程调用；本地歌词不通过这些原语出站。
# ShinLyricsProvider 是唯一允许 HTTP 出站的模块
# （仅 music.163.com 与 interface3.music.163.com）；测试经 URLProtocol 拦截，不打真实网络。
# Packages/ShinAppServices/Sources/ShinAppServices/AudioLinkImportService.swift 是唯一允许使用
# Foundation.Process 的文件，仅通过参数数组（禁止 shell）调用本机 yt-dlp 与 ffmpeg。
# MusicKit 与私有播放 API 禁止使用；Apple Events 原语只能位于 ShinMusicScript。
# 当前 App 的文件/设置操作均不使用 AppleScript，没有需要放行的非 Music 脚本。
# 若新增此类用途，须按具体固定目标审查，不能整目录豁免脚本执行能力。
# 本检查是静态门槛；公开词典命令、参数白名单与真实权限需在本机单独验证。
# 幂等、只读；任一部分失败即返回非 0。
set -euo pipefail

cd "$(dirname "$0")/.."
FAILURES=0

# 只检查项目源码，不把 SwiftPM 依赖、构建缓存作为产品实现。
source_files() {
  find App Packages -type d \( -name .build -o -name .swiftpm -o -name build -o -name DerivedData -o -name '*.xcodeproj' \) -prune -o \
    -type f \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.h' -o -name '*.c' \) \
    -print | LC_ALL=C sort
}

AUDIO_IMPORT_SERVICE="Packages/ShinAppServices/Sources/ShinAppServices/AudioLinkImportService.swift"

FORBIDDEN_NETWORK=(
  -e 'URLSession|NSURLConnection|dataTask|downloadTask|uploadTask'
  -e 'import[[:space:]]+Network|NWConnection|NWListener|NWPathMonitor'
)
FORBIDDEN_SUBPROCESS=(
  -e '(^|[^[:alnum:]_])(Process([[:space:]]*\(|[.])|NSTask|posix_spawn|popen[[:space:]]*\()'
  # 不把 SwiftUI 的 Font.system(...) 当成 C system()。
  -e '(^|[^[:alnum:]_.])system[[:space:]]*\('
  -e '(Darwin|Glibc)[.]system[[:space:]]*\('
)
FORBIDDEN_OUTBOUND=(
  "${FORBIDDEN_NETWORK[@]}"
  "${FORBIDDEN_SUBPROCESS[@]}"
)

echo "== 1) App 与所有包的网络/子进程禁令（ShinLyricsProvider、ShinAIProvider 与 AudioLinkImportService.swift 例外分别单审）=="
FOUND=0
while IFS= read -r file; do
  case "$file" in
    Packages/ShinLyricsProvider/*|Packages/ShinAIProvider/*|"$AUDIO_IMPORT_SERVICE") continue ;;
  esac
  hits="$(grep -nE "${FORBIDDEN_OUTBOUND[@]}" "$file" | grep -vE ':[[:space:]]*//' || true)"
  if [ -n "$hits" ]; then
    echo "  FAIL $file:$hits"
    FOUND=$((FOUND + 1))
  fi
done < <(source_files)
if [ "$FOUND" -eq 0 ]; then
  echo "  通过：除单审例外外，项目源码未发现直接网络或子进程原语。"
else
  FAILURES=$((FAILURES + 1))
fi

echo "== 1b) ShinLyricsProvider：集中 host 与匿名歌词端点白名单 =="
if python3 - <<'AUDIT_PY'
from pathlib import Path
import re
from urllib.parse import urlsplit

root = Path("Packages/ShinLyricsProvider")
client = root / "Sources/ShinLyricsProvider/NeteaseLyricsClient.swift"
allowed_hosts = {"music.163.com", "interface3.music.163.com"}
expected_constants = {
    "apiHost": "music.163.com",
    "eapiHost": "interface3.music.163.com",
    "searchPath": "/api/search/get",
    "eapiLyricPath": "/eapi/song/lyric",
    "eapiLyricAPIPath": "/api/song/lyric",
}
failures = 0

def fail(path, number, reason):
    global failures
    failures += 1
    print(f"  FAIL {path}:{number} {reason}")

text = client.read_text()
for name, value in expected_constants.items():
    pattern = rf'\bstatic let {name} = "{re.escape(value)}"'
    if len(re.findall(pattern, text)) != 1:
        fail(client, 0, f"缺少集中常量 {name}，或定义不唯一")

# HTTP 出站例外不包括下载、上传、原始 socket、子进程或账号凭据。
forbidden = re.compile(
    r"NSURLConnection|downloadTask|uploadTask|import\s+Network|NWConnection|NWListener|"
    r"\b(?:NSTask|posix_spawn|popen|URLCredential)\b|"
    r"\bProcess\s*(?:\(|\.)|(?<![\w.])system\s*\(|(?:Darwin|Glibc)\.system\s*\("
)
for path in sorted(root.rglob("*.swift")):
    if ".build" in path.parts or ".swiftpm" in path.parts:
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("//"):
            continue
        if forbidden.search(line):
            fail(path, number, "出现歌词 HTTP 例外之外的出站或凭据原语")
        for match in re.finditer(r'https?://[^\s"<>]+', line):
            if urlsplit(match.group()).hostname not in allowed_hosts:
                fail(path, number, "URL 目标不在精确 host 白名单")
        host_assignment = re.search(r'\.host\s*=(?!=)\s*(.*)', line)
        if host_assignment and (
            path != client or host_assignment.group(1).strip() not in {"Self.apiHost", "Self.eapiHost"}
        ):
            fail(path, number, "host 必须引用客户端集中常量")
        path_assignment = re.search(r'components\.path\s*=(?!=)\s*(.*)', line)
        if path_assignment and (
            path != client or path_assignment.group(1).strip() not in {"Self.searchPath", "Self.eapiLyricPath"}
        ):
            fail(path, number, "请求 path 必须引用搜索或歌词集中常量")
if failures:
    raise SystemExit(1)
print("  通过：两项精确 host 白名单、搜索/歌词端点与出站原语符合当前匿名获取范围。")
AUDIT_PY
then
  :
else
  FAILURES=$((FAILURES + 1))
fi

echo "== 1c) AudioLinkImportService.swift：仅允许 Foundation.Process（禁止网络/shell/其它子进程原语）=="
if [ ! -f "$AUDIO_IMPORT_SERVICE" ]; then
  echo "  FAIL 缺少文件：$AUDIO_IMPORT_SERVICE"
  FAILURES=$((FAILURES + 1))
else
  FORBIDDEN_IN_AUDIO_IMPORT=(
    "${FORBIDDEN_NETWORK[@]}"
    -e '(^|[^[:alnum:]_])(NSTask|posix_spawn|popen[[:space:]]*\()'
    -e '(^|[^[:alnum:]_.])system[[:space:]]*\('
    -e '(Darwin|Glibc)[.]system[[:space:]]*\('
    -e '/bin/(sh|zsh|bash)'
  )
  hits="$(grep -nE "${FORBIDDEN_IN_AUDIO_IMPORT[@]}" "$AUDIO_IMPORT_SERVICE" | grep -vE ':[[:space:]]*//' || true)"
  if [ -n "$hits" ]; then
    echo "  FAIL $AUDIO_IMPORT_SERVICE:$hits"
    FAILURES=$((FAILURES + 1))
  else
    echo "  通过：AudioLinkImportService.swift 未发现网络、shell 或 Process 之外的子进程原语。"
  fi
fi

echo "== 1d) ShinAIProvider：受控 AI 出站与密钥边界 =="
if python3 - <<'AUDIT_AI_PY'
from pathlib import Path
import re

root = Path("Packages/ShinAIProvider")
client = root / "Sources/ShinAIProvider/OpenAICompatibleClient.swift"
keychain_store = root / "Sources/ShinAIProvider/AIKeychainStore.swift"
config_file = root / "Sources/ShinAIProvider/AIProviderConfiguration.swift"
failures = 0

def fail(path, number, reason):
    global failures
    failures += 1
    print(f"  FAIL {path}:{number} {reason}")

if not client.is_file():
    fail(client, 0, "缺少唯一允许 URLSession 的客户端文件")
if not keychain_store.is_file():
    fail(keychain_store, 0, "缺少钥匙串凭据存储文件")
if not config_file.is_file():
    fail(config_file, 0, "缺少配置与端点校验文件")

if keychain_store.is_file():
    kc_text = keychain_store.read_text()
    if 'serviceName = "com.shinapple.ai-credentials"' not in kc_text:
        fail(keychain_store, 0, "缺少统一钥匙串 Service 常量 com.shinapple.ai-credentials")
    if "UserDefaults" in kc_text:
        fail(keychain_store, 0, "钥匙串存储文件禁止引用 UserDefaults")

if config_file.is_file() and "validatedEndpointURL(" not in config_file.read_text():
    fail(config_file, 0, "缺少端点协议安全校验函数 validatedEndpointURL")

forbidden_primitives = re.compile(
    r"NSURLConnection|downloadTask|uploadTask|import\s+Network|NWConnection|NWListener|NWPathMonitor|"
    r"\b(?:NSTask|posix_spawn|popen|URLCredential)\b|"
    r"\bProcess\s*(?:\(|\.)|(?<![\w.])system\s*\(|(?:Darwin|Glibc)\.system\s*\(|"
    r"\b(?:NSAppleScript|NSUserAppleScriptTask|NSAppleEventDescriptor|NSAppleEventManager|"
    r"SBApplication|SBObject|AESend|AESendMessage|AECreateAppleEvent|AECreateDesc|OSAExecute)\b|"
    r"import\s+ScriptingBridge|executeAndReturnError|sendEventWithClass|"
    r"tell\s+(?:application|app)\s|com\.apple\.Music|/usr/bin/osascript"
)
hardcoded_secret = re.compile(
    r"(?:sk-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{20,}|xox[baprs]-[A-Za-z0-9-]{16,}|"
    r"ghp_[A-Za-z0-9]{20,}|Bearer\s+[A-Za-z0-9_+/.-]{20,})"
)

for path in sorted(root.rglob("*.swift")):
    if ".build" in path.parts or ".swiftpm" in path.parts:
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith("//"):
            continue
        if "URLSession" in line and path != client:
            fail(path, number, "URLSession 仅允许出现在 OpenAICompatibleClient.swift")
        if forbidden_primitives.search(line):
            fail(path, number, "出现 AI HTTP 例外之外的出站、子进程或 Apple Events 原语")
        if hardcoded_secret.search(line):
            fail(path, number, "出现疑似硬编码第三方 API Key")

if failures:
    raise SystemExit(1)
print("  通过：URLSession 限于 OpenAICompatibleClient.swift，未发现禁止原语或硬编码 API Key。")
AUDIT_AI_PY
then
  :
else
  FAILURES=$((FAILURES + 1))
fi

echo "== 2) 播放 API 边界：仅允许公开脚本 =="
FORBIDDEN_PLAYBACK=(
  -e 'MusicKit|MediaRemote|MRMediaRemote|MPMusicPlayerController'
  -e '(^|[^[:alnum:]_])(ApplicationMusicPlayer|SystemMusicPlayer|MusicPlayer|MusicAuthorization|MusicSubscription|MusicDataRequest|MusicLibraryRequest|MusicCatalog[A-Za-z]*Request)([^[:alnum:]_]|$)'
  -e 'PrivateFrameworks/'
)
FOUND=0
while IFS= read -r file; do
  hits="$(grep -nE "${FORBIDDEN_PLAYBACK[@]}" "$file" || true)"
  if [ -n "$hits" ]; then
    echo "  FAIL $file:$hits"
    FOUND=$((FOUND + 1))
  fi
done < <(source_files)
if [ "$FOUND" -eq 0 ]; then
  echo "  通过：未发现 MusicKit 或私有播放 API。"
else
  FAILURES=$((FAILURES + 1))
fi

echo "== 3) Music Apple Events 仅由 ShinMusicScript 发送 =="
SCRIPT_PRIMITIVES=(
  -e '(^|[^[:alnum:]_])(NSAppleScript|NSUserAppleScriptTask|NSAppleEventDescriptor|NSAppleEventManager|SBApplication|SBObject|AESend|AESendMessage|AECreateAppleEvent|AECreateDesc|OSAExecute)([^[:alnum:]_]|$)'
  -e 'import[[:space:]]+ScriptingBridge|executeAndReturnError|sendEventWithClass'
  -e 'tell[[:space:]]+(application|app)[[:space:]]|com\.apple\.Music|/usr/bin/osascript'
)
FOUND=0
while IFS= read -r file; do
  case "$file" in Packages/ShinMusicScript/*) continue ;; esac
  hits="$(grep -nE "${SCRIPT_PRIMITIVES[@]}" "$file" || true)"
  if [ -n "$hits" ]; then
    echo "  FAIL $file:$hits"
    FOUND=$((FOUND + 1))
  fi
done < <(source_files)
if [ "$FOUND" -eq 0 ]; then
  echo "  通过：App/领域/存储/引擎/服务没有直接脚本或 Apple Events 调用。"
else
  FAILURES=$((FAILURES + 1))
fi
# 列出实际执行入口以便复核播放边界。
echo "  ShinMusicScript 执行入口："
while IFS= read -r file; do
  grep -nE '(NSAppleScript|SBApplication)[[:space:]]*\(|executeAndReturnError' "$file" \
    | grep -vE '^[0-9]+:[[:space:]]*//' \
    | while IFS= read -r hit; do echo "    $file:$hit"; done || true
done < <(find Packages/ShinMusicScript/Sources -type f -name '*.swift' | LC_ALL=C sort)

echo "== 4) 禁止仓库内复制 SDK/脚本依赖 =="
FOUND=0
while IFS= read -r file; do
  [ -e "$file" ] || continue
  echo "  FAIL 跟踪文件含 vendored 痕迹：$file"
  FOUND=$((FOUND + 1))
done < <(git ls-files | grep -iE '\.js$|\.framework($|/)|\.xcframework|node_modules|Vendor/|ThirdParty/' || true)
while IFS= read -r file; do
  echo "  FAIL 工作树含 vendored 痕迹：$file"
  FOUND=$((FOUND + 1))
done < <(find . -type d \( -name .git -o -name .build -o -name .swiftpm -o -name build -o -name DerivedData -o -name '*.xcodeproj' \) -prune -o \
  \( -type d \( -name '*.framework' -o -name '*.xcframework' -o -name node_modules \) -print -prune \) -o \
  -type f -name '*.js' -print | LC_ALL=C sort)
if [ "$FOUND" -eq 0 ]; then
  echo "  通过：未发现复制的 SDK/脚本依赖；GRDB 由 SwiftPM 解析。"
else
  FAILURES=$((FAILURES + 1))
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "audit-outbound：通过。播放集成限于 ShinMusicScript → 本机 Music.app 公开脚本；"
  echo "网络出站限于 ShinLyricsProvider → music.163.com / interface3.music.163.com（搜索与歌词文本），"
  echo "以及 ShinAIProvider/OpenAICompatibleClient.swift → 用户配置的 HTTPS/本地回环 OpenAI 兼容端点；"
  echo "本地子进程限于 AudioLinkImportService.swift → 本机 yt-dlp / ffmpeg 参数数组调用；"
  echo "其余源码未发现网络/子进程原语。静态检查不替代真实 Music 人工验证。"
  exit 0
fi
echo "audit-outbound：$FAILURES 个审计部分未通过。"
exit 1
