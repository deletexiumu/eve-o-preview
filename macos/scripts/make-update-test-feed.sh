#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 由 dist/release/ 的内容生成本地更新测试用的更新清单 update-manifest.json（v1.1 设计 14.2 节第 5 组；
# 清单格式见 docs/update-manifest.md）。清单用测试私钥签名，应用要配合测试公钥打开。
#
# 用法：macos/scripts/make-update-test-feed.sh [版本号]
#   版本号默认取 macos/VERSION 文件；写成 tag 时前面加 v。可以写成与 dmg 不同的版本，用来测「版本不符」。
# 环境变量：
#   LABEL  dist/release/ 里文件名的版本标签，默认等于 macos/VERSION 文件的内容
#   PORT   本地 HTTP 服务的端口，默认 8123
#   NOTES  清单里这个版本的发布说明文件，默认 docs/release-notes/v<版本号>.md，不存在时用一段占位文字
#
# 清单的 releases 另含 docs/release-notes/ 里比这个版本旧的各版本（统一发布的说明按平台标记，macos/ 下的旧说明
# 都算 macOS），供显示中间版本的说明（设计 8.8 节）。另外写 dist/release/feed-SHA256SUMS.txt。
# 签名用 EVEOProbe update sign-manifest（测试种子与 shared/fixtures/update-manifest 相同，人人可算，只用于测试）。
# 这些文件只用于本地测试，测完删掉，免得混进发布附件。
#
# 生成后在 dist/release/ 下运行：python3 -m http.server "$PORT" --bind 127.0.0.1
# 再按脚本最后打印的命令打开待测的应用（带 EVEO_UPDATE_FEED_URL 与 EVEO_UPDATE_TEST_PUBLIC_KEY 两个环境变量）。

set -euo pipefail

# macOS 工程目录（脚本在 macos/scripts/ 下，工程目录是它的上一级）与仓库根目录。
# 在仓库根目录运行，dist/ 与 docs/ 都按仓库根目录的相对路径找。
MACOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$MACOS/.." && pwd)"
cd "$REPO"

BASE_VERSION="$(tr -d '[:space:]' < "$MACOS/VERSION")"
FEED_VERSION="${1:-$BASE_VERSION}"
LABEL="${LABEL:-$BASE_VERSION}"
PORT="${PORT:-8123}"
NOTES="${NOTES:-docs/release-notes/v${FEED_VERSION}.md}"
OUT="$REPO/dist/release"

for f in "EVE-O-Preview-${LABEL}.dmg" SHA256SUMS.txt; do
    if [[ ! -f "$OUT/$f" ]]; then
        echo "找不到 $OUT/$f，请先运行 macos/scripts/package-release.sh" >&2
        exit 1
    fi
done

# 用 Python 生成清单正文，避免手写转义；附件地址指向本地服务，大小与 SHA-256 取实际文件的。
python3 - "$OUT" "$FEED_VERSION" "$LABEL" "$PORT" "$NOTES" <<'PY'
import glob, hashlib, json, os, re, sys, time
out, version, label, port, notes = sys.argv[1:6]
base = f"http://127.0.0.1:{port}/"
# 发布说明文件不存在时用占位文字，测试仍能看到窗口。
body = open(notes, encoding="utf-8").read() if os.path.isfile(notes) else "<!-- lang:en -->\nLocal update test.\n<!-- /lang:en -->\n"
# 应用按固定名字找 dmg（设计 8.1 节），对外的附件名用清单的版本号，地址仍指向实际的 dmg。
# 校验和按对外的名字另写一份 feed-SHA256SUMS.txt（哈希不变），这样清单版本与 dmg 不同时，
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
sums = os.path.join(out, "feed-SHA256SUMS.txt")
with open(sums, "w", encoding="utf-8") as f:
    f.write(f"{digest}  {dmg_public}\n")

def file_entry(name, path):
    """清单 files 里的一项：名字、实际大小、实际 SHA-256、指向本地服务的地址。"""
    data = open(path, "rb").read()
    return {"name": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "urls": [base + os.path.basename(path)]}

def key(text):
    return tuple(int(x) for x in text.split("."))

def platforms_of(text, default):
    """发布说明第一行的平台标记；没有时取 default。"""
    match = re.match(r"<!--\s*platforms:\s*([a-z ]+?)\s*-->", text)
    return match.group(1).split() if match else default

# releases：清单这个版本在前，之后是比它旧的各版本，新版在前；统一发布的说明优先于 macos/ 下的旧说明。
older = {}
if re.fullmatch(r"\d+\.\d+\.\d+", version):
    for pattern, default in (("docs/release-notes/macos/v*.md", ["macos"]), ("docs/release-notes/v*.md", ["macos"])):
        for path in glob.glob(pattern):
            match = re.fullmatch(r"v(\d+\.\d+\.\d+)\.md", os.path.basename(path))
            if match and key(match.group(1)) < key(version):
                text = open(path, encoding="utf-8").read()
                older[match.group(1)] = {"version": match.group(1), "platforms": platforms_of(text, default),
                                         "notes": text}
releases = [{"version": version, "platforms": platforms_of(body, ["macos", "windows"]), "notes": body}]
releases += [older[v] for v in sorted(older, key=key, reverse=True)][:19]
payload = {
    "schema": 1,
    "sequence": int(time.time()),
    "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "latest": {"macos": {
        "version": version,
        "tag": f"v{version}",
        "pageURL": base,
        "files": [file_entry(dmg_public, os.path.join(out, dmg_file)), file_entry("SHA256SUMS.txt", sums)],
    }},
    "releases": releases,
}
with open(os.path.join(out, "update-manifest.payload.json"), "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
print(f"清单正文：v{version}，附件指向 {base}，{len(releases)} 个版本的说明")
PY

# 签名：构建并运行探针，它打印测试公钥那一行。
swift build --package-path "$MACOS" --product EVEOProbe > /dev/null
KEY_LINE="$("$MACOS/.build/debug/EVEOProbe" update sign-manifest "$OUT/update-manifest.payload.json" "$OUT/update-manifest.json")"
rm -f "$OUT/update-manifest.payload.json"
echo "已写 $OUT/update-manifest.json"
echo "打开待测的应用：open --env EVEO_UPDATE_FEED_URL=http://127.0.0.1:${PORT}/update-manifest.json --env ${KEY_LINE} <应用>"
