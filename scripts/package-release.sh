#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 生成发布文件（架构文档 9.4 节）：安装用的 dmg、源码包（tar.gz 与 zip）和 SHA-256 校验和。
# 产物放在 dist/release/，CI 把这个目录整个上传。
#
# 用法：scripts/package-release.sh
# 环境变量：
#   VERSION     写进 Info.plist 的版本号，默认取仓库根目录 VERSION 文件的内容
#   LABEL       文件名里的版本标签，默认等于 VERSION；CI 给 PR 构建填 1.0.0-pr.12.abc1234 这样的值。
#               同时传给 build-app.sh，写进 Info.plist 的 EVEOBuildLabel
#   SKIP_BUILD  设为 1 时不调用 build-app.sh，直接打包已有的 dist/EVE-O Preview.app
#   UNIVERSAL、SIGN_IDENTITY  原样传给 build-app.sh
#
# 源码包用 git archive 从 HEAD 导出，只含已提交的文件；工作区有未提交改动时会打印提醒。

set -euo pipefail

# 仓库根目录：脚本在 scripts/ 下，根目录是它的上一级。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 源码包要用 git archive，先确认在 git 仓库里，免得构建完才失败。
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "需要在 git 仓库里运行：源码包由 git archive 导出" >&2
    exit 1
fi

VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
LABEL="${LABEL:-$VERSION}"
APP="$ROOT/dist/EVE-O Preview.app"
OUT="$ROOT/dist/release"

# 1. 构建并签名 .app。
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    VERSION="$VERSION" LABEL="$LABEL" "$ROOT/scripts/build-app.sh"
fi
if [[ ! -d "$APP" ]]; then
    echo "找不到 ${APP}，请先运行 scripts/build-app.sh" >&2
    exit 1
fi

# 2. 清空输出目录。
rm -rf "${OUT:?}"
mkdir -p "$OUT"

# 3. dmg：卷里放 .app 和指向「应用程序」的替身，打开后拖过去即可安装。
#    用 ditto 复制，保留代码签名依赖的扩展属性与符号链接。
DMG="$OUT/EVE-O-Preview-${LABEL}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# mktemp 建的目录是 0700，dmg 卷根目录会继承这个权限，改成 755。
chmod 755 "$STAGE"
ditto "$APP" "$STAGE/EVE-O Preview.app"
ln -s /Applications "$STAGE/Applications"
echo "==> hdiutil create ${DMG}"
# GitHub 的 macOS 运行器上 hdiutil 偶尔报「资源忙」，失败后等几秒重试，最多 3 次。
for attempt in 1 2 3; do
    if hdiutil create -volname "EVE-O Preview" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"; then
        break
    fi
    if [[ "$attempt" == "3" ]]; then
        echo "hdiutil create 连续失败 3 次" >&2
        exit 1
    fi
    sleep 5
done
hdiutil verify "$DMG"

# 4. 源码包：从 HEAD 导出，顶层目录名带版本标签。
if [[ -n "$(git status --porcelain)" ]]; then
    echo "提醒：工作区有未提交的改动，源码包只含 HEAD 里已提交的内容。" >&2
fi
SRC="eve-o-preview-macos-${LABEL}"
git archive --format=tar.gz --prefix="${SRC}/" -o "$OUT/${SRC}-source.tar.gz" HEAD
git archive --format=zip --prefix="${SRC}/" -o "$OUT/${SRC}-source.zip" HEAD

# 5. 校验和：在输出目录里算，文件列只有文件名，下载后可以直接 shasum -c。
(cd "$OUT" && shasum -a 256 -- *.dmg *.tar.gz *.zip > SHA256SUMS.txt)

echo
echo "发布文件：${OUT}"
ls -l "$OUT"
