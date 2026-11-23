#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 由 dist/release/ 的内容生成本地更新测试用的 feed.json（v1.1 设计 14.2 节第 5 组）。
# feed.json 模仿 GitHub「最新 Release」接口的返回，只含应用读取的字段（设计 8.4 节）。
#
# 用法：scripts/make-update-test-feed.sh [版本号]
#   版本号默认取 VERSION 文件；写成 tag_name 时前面加 v。可以写成与 dmg 不同的版本，用来测「版本不符」。
# 环境变量：
#   LABEL  dist/release/ 里文件名的版本标签，默认等于 VERSION 文件的内容
#   PORT   本地 HTTP 服务的端口，默认 8123
#   NOTES  用作 body 的发布说明文件，默认 docs/release-notes/v<版本号>.md，不存在时用一段占位文字
#
# 另外写 dist/release/feed-SHA256SUMS.txt 与 releases.json（Release 列表，供显示中间版本的说明，设计 8.8 节）。
# 这些文件只用于本地测试，测完删掉，免得混进发布附件。
#
# 生成后在 dist/release/ 下运行：python3 -m http.server "$PORT" --bind 127.0.0.1
# 再用 open --env EVEO_UPDATE_FEED_URL=http://127.0.0.1:$PORT/feed.json 打开待测的应用。

set -euo pipefail

# 仓库根目录：脚本在 scripts/ 下，根目录是它的上一级。
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASE_VERSION="$(tr -d '[:space:]' < VERSION)"
FEED_VERSION="${1:-$BASE_VERSION}"
LABEL="${LABEL:-$BASE_VERSION}"
PORT="${PORT:-8123}"
NOTES="${NOTES:-docs/release-notes/v${FEED_VERSION}.md}"
OUT="$ROOT/dist/release"

for f in "EVE-O-Preview-${LABEL}.dmg" SHA256SUMS.txt; do
    if [[ ! -f "$OUT/$f" ]]; then
        echo "找不到 $OUT/$f，请先运行 scripts/package-release.sh" >&2
        exit 1
    fi
done

# 用 Python 生成 JSON，避免手写转义；附件地址指向本地服务，大小取实际文件大小。
python3 - "$OUT" "$FEED_VERSION" "$LABEL" "$PORT" "$NOTES" <<'PY'
import json, os, sys, datetime
out, version, label, port, notes = sys.argv[1:6]
base = f"http://127.0.0.1:{port}/"
# 发布说明文件不存在时用占位文字，测试仍能看到窗口。
body = open(notes, encoding="utf-8").read() if os.path.isfile(notes) else "<!-- lang:en -->\nLocal update test.\n<!-- /lang:en -->\n"
# 应用按固定名字找 dmg（设计 8.1 节），对外的附件名用 feed 的版本号，地址仍指向实际的 dmg。
# 校验和按对外的名字另写一份 feed-SHA256SUMS.txt（哈希不变），这样 feed 版本与 dmg 不同时，
# 应用走到「版本不符」那一步，而不是先报找不到校验和。
dmg_file = f"EVE-O-Preview-{label}.dmg"
dmg_public = f"EVE-O-Preview-{version}.dmg"
digest = None
for line in open(os.path.join(out, "SHA256SUMS.txt"), encoding="utf-8"):
    parts = line.split()
    if len(parts) == 2 and parts[1] == dmg_file:
        digest = parts[0]
if digest is None:
    sys.exit(f"SHA256SUMS.txt 里没有 {dmg_file}")
with open(os.path.join(out, "feed-SHA256SUMS.txt"), "w", encoding="utf-8") as f:
    f.write(f"{digest}  {dmg_public}\n")
assets = [
    {"name": dmg_public, "browser_download_url": base + dmg_file, "size": os.path.getsize(os.path.join(out, dmg_file))},
    {"name": "SHA256SUMS.txt", "browser_download_url": base + "feed-SHA256SUMS.txt",
     "size": os.path.getsize(os.path.join(out, "feed-SHA256SUMS.txt"))},
]
feed = {
    "tag_name": f"v{version}",
    "name": f"EVE-O Preview for macOS v{version}",
    "body": body,
    "html_url": base,
    "draft": False,
    "prerelease": False,
    "published_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "assets": assets,
}
with open(os.path.join(out, "feed.json"), "w", encoding="utf-8") as f:
    json.dump(feed, f, ensure_ascii=False, indent=2)
print(f"已写 {os.path.join(out, 'feed.json')}：tag_name v{version}，附件指向 {base}")

# releases.json 模仿 GitHub 的 Release 列表接口（设计 8.8 节），应用用它显示中间版本的说明：
# 第一项是 feed 本身，其后是 docs/release-notes 里比 feed 版本旧的各版本，新版在前，只含应用读取的字段。
import glob, re
def key(text):
    return tuple(int(x) for x in text.split("."))
older = []
for path in glob.glob("docs/release-notes/v*.md"):
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)\.md", os.path.basename(path))
    if match and re.fullmatch(r"\d+\.\d+\.\d+", version) and key(match.group(1)) < key(version):
        older.append((key(match.group(1)), match.group(1), open(path, encoding="utf-8").read()))
older.sort(reverse=True)
releases = [{"tag_name": f"v{version}", "draft": False, "prerelease": False, "body": body}]
releases += [{"tag_name": f"v{v}", "draft": False, "prerelease": False, "body": text} for _, v, text in older]
with open(os.path.join(out, "releases.json"), "w", encoding="utf-8") as f:
    json.dump(releases, f, ensure_ascii=False, indent=2)
print(f"已写 {os.path.join(out, 'releases.json')}：{len(releases)} 个版本")
PY
