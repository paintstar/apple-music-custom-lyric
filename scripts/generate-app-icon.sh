#!/bin/bash
# macOS AppIcon 的 16–512 pt、1x/2x 是平台要求，统一从同一透明源图生成。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-$ROOT/Resources/AppIcon-source.png}"
DESTINATION="$ROOT/App/Assets.xcassets/AppIcon.appiconset"
if [[ ! -f "$SOURCE" ]]; then
    echo "图标源文件不存在。" >&2
    exit 1
fi
read -r WIDTH HEIGHT < <(sips -g pixelWidth -g pixelHeight "$SOURCE" | awk '/pixelWidth:/ { width=$2 } /pixelHeight:/ { print width, $2 }')
if [[ "$WIDTH" != "$HEIGHT" || "$WIDTH" -lt 1024 ]]; then
    echo "图标源文件必须为至少 1024 × 1024 像素的正方形。" >&2
    exit 1
fi
mkdir -p "$DESTINATION"
for POINTS in 16 32 128 256 512; do
    for SCALE in 1 2; do
        PIXELS=$((POINTS * SCALE))
        SUFFIX=""
        if [[ "$SCALE" == 2 ]]; then SUFFIX="@2x"; fi
        sips -s format png -z "$PIXELS" "$PIXELS" "$SOURCE" \
            --out "$DESTINATION/icon_${POINTS}x${POINTS}${SUFFIX}.png" >/dev/null
    done
done
echo "已生成 macOS AppIcon 全部尺寸。"
