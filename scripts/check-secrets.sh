#!/bin/bash
# 默认扫描待提交工作区（跟踪文件 + 未忽略的新文件）；--staged 扫描整个暂存树。
# 只输出路径、行号、规则编号，不打印候选值。Package.resolved 仅放行公开哈希；
# 行级白名单仅适用于测试夹具或 .env.example，且必须写明理由。
set -euo pipefail
cd "$(dirname "$0")/.."
command -v python3 >/dev/null || { echo "错误：缺少 python3。" >&2; exit 2; }
python3 - "$@" <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys

if sys.argv[1:] not in ([], ["--staged"]):
    print("用法：scripts/check-secrets.sh [--staged]", file=sys.stderr)
    sys.exit(2)
staged = bool(sys.argv[1:])
command = ["git", "ls-files", "-z", "--cached"]
if not staged:
    command += ["--others", "--exclude-standard"]
try:
    listing = subprocess.run(command, check=True, capture_output=True).stdout
except (OSError, subprocess.CalledProcessError):
    print("check-secrets：无法读取 Git 文件清单。", file=sys.stderr)
    sys.exit(2)
paths = sorted({os.fsdecode(item) for item in listing.split(b"\0") if item})

# R1：敏感文件名；R2：私钥块；R3：JWT；R4：长 hex；R5：不透明 token；R6：凭据赋值。
rules = {
    "R2": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "R3": re.compile(r"eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}"),
    "R4": re.compile(r"(?<![A-Za-z0-9])[0-9a-fA-F]{32,}(?![A-Za-z0-9])"),
    "R6": re.compile(
        r"(?:developer[_-]?token|user[_-]?token|access[_-]?token|api[_-]?key|"
        r"secret[_-]?key|private[_-]?key|client[_-]?secret|password)"
        r"[\"']?\s*[:=]\s*[\"'][A-Za-z0-9_+/.-]{20,}[\"']", re.IGNORECASE
    ),
}
opaque = re.compile(r"[A-Za-z0-9_-]{40,}")
public_hash = re.compile(r'("(?:originHash|revision)"\s*:\s*")[0-9a-fA-F]{32,}("\s*[,}]?)')
allow_marker = re.compile(r"SECRET-CHECK-ALLOWLIST\s*(?::|：|—|-)\s*\S.+")
hits = set()
scanned = 0
for name in paths:
    path = Path(name)
    if not staged and not path.is_file() and not path.is_symlink():
        continue  # 已从工作区删除的旧文件不属于待发布内容。
    scanned += 1
    if path.suffix.lower() in {".p8", ".pem", ".key", ".p12", ".mobileprovision", ".provisionprofile"}:
        hits.add((name, 0, "R1"))
    if (path.name == ".env" or path.name.startswith(".env.")) and path.name != ".env.example":
        hits.add((name, 0, "R1"))
    try:
        if staged:
            data = subprocess.run(["git", "show", ":" + name], check=True, capture_output=True).stdout
        elif path.is_symlink():
            data = os.fsencode(os.readlink(path))  # 不读取仓库外的链接目标。
        else:
            data = path.read_bytes()
    except (OSError, subprocess.CalledProcessError):
        hits.add((name, 0, "R0"))
        continue
    text = data.decode("utf-8", errors="replace")
    dependency_file = path.name == "Package.resolved"
    if dependency_file:
        try:
            dependency_file = isinstance(json.loads(text), dict)
        except json.JSONDecodeError:
            dependency_file = False
    fixture_file = (
        (name.startswith("Packages/") and "/Tests/" in name)
        or (name.startswith("scripts/") and name.endswith("-check.swift"))
        or path.name == ".env.example"
    )
    for number, line in enumerate(text.splitlines(), 1):
        if fixture_file and allow_marker.search(line):
            continue
        candidate = public_hash.sub(r"\1PUBLIC_DEPENDENCY_HASH\2", line) if dependency_file else line
        for rule, pattern in rules.items():
            if pattern.search(candidate):
                hits.add((name, number, rule))
        for match in opaque.finditer(candidate):
            token = match.group()
            if all(re.search(pattern, token) for pattern in (r"[A-Z]", r"[a-z]", r"[0-9]")):
                hits.add((name, number, "R5"))

print(f"check-secrets：扫描 {scanned} 个文件（{'暂存树' if staged else '工作区'}）。")
for name, number, rule in sorted(hits):
    print(f"  {json.dumps(name, ensure_ascii=False)}:{number} {rule}")
if hits:
    print(f"check-secrets：发现 {len(hits)} 处疑似凭据或读取错误，请核对；未输出候选值。")
    sys.exit(1)
print("check-secrets：通过。")
PY
