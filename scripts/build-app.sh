#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 组装并签名 dist/EVE-O Preview.app（架构文档 9.1 节）。
#
# 用法：scripts/build-app.sh
# 环境变量：
#   VERSION        写进 Info.plist 的版本号，默认取仓库根目录 VERSION 文件的内容
#   LABEL          构建标签，写进 Info.plist 的 EVEOBuildLabel，默认等于 VERSION；CI 给 PR 构建填 1.1.0-pr.12.abc1234 这样的值
#   SIGN_IDENTITY  代码签名身份；不设时钥匙串里有「EVEO Preview Dev」就用它，否则 ad-hoc（-）
#   UNIVERSAL      设为 1 时分别编译 arm64 与 x86_64，再用 lipo 合成通用二进制；默认只编译本机架构
#
# 只依赖 Command Line Tools：swift、plutil、codesign、security、lipo；有图标时另用 sips 与 iconutil。

set -euo pipefail

# 仓库根目录：脚本在 scripts/ 下，根目录是它的上一级。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
LABEL="${LABEL:-$VERSION}"
APP_NAME="EVE-O Preview"
BUNDLE_ID="io.github.deletexiumu.eveopreview-macos"
DEV_IDENTITY="EVEO Preview Dev"
APP="$ROOT/dist/$APP_NAME.app"

# 1. 编译发布版。
# 通用二进制不用 swift build --arch arm64 --arch x86_64：那条路径要 Xcode 自带的 xcbuild，
# 只装 Command Line Tools 时不可用。改为按目标三元组各编一次，再用 lipo 合并。
# 临时目录放合并后的二进制与图标集，脚本退出时（含出错）一并删除。
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/EVEOPreview"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    SLICES=()
    for arch in arm64 x86_64; do
        TRIPLE="${arch}-apple-macosx14.0"
        echo "==> swift build -c release --product EVEOPreview --triple ${TRIPLE}"
        swift build -c release --product EVEOPreview --triple "$TRIPLE"
        SLICES+=("$(swift build -c release --triple "$TRIPLE" --show-bin-path)/EVEOPreview")
    done
    lipo -create "${SLICES[@]}" -output "$BIN"
else
    echo "==> swift build -c release --product EVEOPreview"
    swift build -c release --product EVEOPreview
    cp "$(swift build -c release --show-bin-path)/EVEOPreview" "$BIN"
fi
lipo -info "$BIN"

# 2. 建包目录，复制可执行文件。先删旧包，避免残留文件影响签名。
echo "==> 组装 ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EVEOPreview"

# 3. 由模板生成 Info.plist，填版本号并检查格式。
# 版本号里的 /、&、\ 对 sed 的替换串有特殊含义，先转义；& < > 在 plist（XML）里也要转义。
VERSION_XML="$(printf '%s' "$VERSION" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
VERSION_SED="$(printf '%s' "$VERSION_XML" | sed -e 's/[\/&]/\\&/g')"
sed "s/__VERSION__/$VERSION_SED/g" "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"

# 4. 有 packaging/AppIcon.png 时生成 icns，并在 Info.plist 里登记图标。
if [[ -f "$ROOT/packaging/AppIcon.png" ]]; then
    echo "==> 生成图标"
    ICONSET="$WORK/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ROOT/packaging/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ROOT/packaging/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    plutil -insert CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
fi
# 4b. 构建标签与提交号（v1.1 设计 8.1、8.3 节）：应用据此判断 PR 或 main 构建是否该收到同版本号正式版的更新。
#     不在 git 仓库里（如从源码包构建）时取不到提交号，就不写 EVEOBuildCommit。
plutil -insert EVEOBuildLabel -string "$LABEL" "$APP/Contents/Info.plist"
if COMMIT="$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null)"; then
    plutil -insert EVEOBuildCommit -string "$COMMIT" "$APP/Contents/Info.plist"
fi
plutil -lint "$APP/Contents/Info.plist"

# 5. 选签名身份。先把 security 的输出存进变量再匹配：
#    直接用管道接 grep -q 时，grep 提前退出会让 security 收到 SIGPIPE，pipefail 下误判为「找不到」。
#    不加 -v：自签名证书不受信任，-v 只列「有效」身份，会漏掉它，但它可以用来签名。
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$SIGN_IDENTITY"
else
    IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
    if [[ "$IDENTITIES" == *"\"$DEV_IDENTITY\""* ]]; then
        IDENTITY="$DEV_IDENTITY"
    else
        IDENTITY="-"
    fi
fi

# 签名。首次使用钥匙串里的私钥时系统可能弹窗询问，这里限时 120 秒，避免无人值守时一直挂起。
echo "==> codesign（身份：${IDENTITY}）"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" &
SIGN_PID=$!
for _ in $(seq 1 120); do
    kill -0 "$SIGN_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$SIGN_PID" 2>/dev/null; then
    kill "$SIGN_PID" 2>/dev/null || true
    echo "codesign 超过 120 秒没有完成：可能在等钥匙串授权弹窗。请在弹窗里选「始终允许」后重试。" >&2
    exit 1
fi
wait "$SIGN_PID"
codesign --verify --strict --verbose=2 "$APP"

# 6. 打印结果。
echo
echo "产物：${APP}"
if [[ "$IDENTITY" == "-" ]]; then
    echo "签名：ad-hoc"
    echo "提示：ad-hoc 签名没有稳定身份，每次重新构建后都要重新授予屏幕录制与辅助功能权限（见 README）。"
else
    echo "签名：${IDENTITY}"
fi
