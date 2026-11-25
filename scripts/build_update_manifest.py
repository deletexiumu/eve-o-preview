#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""生成、打包与拆开更新清单 update-manifest.json（格式见 docs/update-manifest.md）。

release.yml 的 publish 任务用它，签名本身用 openssl 做（与 SHA256SUMS.txt.sig 相同的私钥与写法），
这里只处理 JSON：

- plan：列出各平台 latest 要用的、比本次早的版本（一行一个），workflow 据此下载那些版本的文件。
- build：生成清单正文（payload）。每个平台的 latest 是发布说明标记里含这个平台的最高版本，每次都从仓库里的
  docs/release-notes/v*.md 重新算出，不沿用上一份清单；文件的大小与 SHA-256 从本地文件算出。
- message：正文前面接上签名前缀，写成要签名的消息（openssl 签这个文件）。
- envelope：把正文与 base64 的签名包成对外发布的信封；超过 512 KiB 时报错（build 已按预算去掉旧的说明）。
- open：把信封拆成正文、要验签的消息与原始签名字节，供 openssl 验签与样例核对。
- files：列出正文里各平台 latest 指向的文件（tag、文件名、SHA-256，去重），供上传 R2 时逐个下载、核对。

用法见各子命令的 --help。出错时打印原因、退出码为 1。
"""

import argparse
import base64
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# 清单正文的版本与信封的格式号；应用只认这两个值。
SCHEMA = 1
FORMAT = 1
# releases 里最多保留的版本数。应用最多列 10 个中间版本，多留一些给落后更多的用户看标题。
MAX_RELEASES = 20
# 应用接受的信封上限是 1 MiB；生成时留一半余量，超过预算就从最旧的版本开始去掉说明。
MAX_ENVELOPE_BYTES = 524_288
# 签名的消息 = 这个前缀 + 正文字节。与 SHA256SUMS.txt.sig 用同一把私钥，前缀让两种签名不能互相冒充。
SIGNING_PREFIX = b"eveo-update-manifest-v1\n"
# 已知的平台，也是 latest 的键。
PLATFORMS = ("macos", "windows")
# 平台标记，与 scripts/check_release_notes.py 一致。
PLATFORM_MARKER = re.compile(r"<!--\s*platforms:([^>]*?)\s*-->")
# 顶层发布说明的文件名：v<主>.<次>.<修订>.md，不带预发布标识（预发布不进清单）。
NOTES_NAME = re.compile(r"^v(\d+)\.(\d+)\.(\d+)\.md$")
# 两个平台都要下载的校验和文件与它的签名。
SHARED_FILES = ("SHA256SUMS.txt", "SHA256SUMS.txt.sig")


def fail(message: str) -> None:
    """打印错误并以退出码 1 结束。"""
    print(f"错误：{message}", file=sys.stderr)
    sys.exit(1)


def parse_version(text: str) -> tuple[int, int, int]:
    """把 1.5.0 这样的正式版版本号转成可比较的三元组；带预发布标识或格式不对时报错。"""
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", text)
    if not match:
        fail(f"版本号 {text} 不是正式版的 主.次.修订 写法（预发布版不写进清单）")
    return tuple(int(part) for part in match.groups())


def platforms_of(notes: str, path: Path) -> list[str]:
    """读发布说明的平台标记，按 PLATFORMS 的顺序返回；没有或不合法时报错。"""
    markers = PLATFORM_MARKER.findall(notes)
    if len(markers) != 1:
        fail(f"{path} 应有且只有一个平台标记")
    names = markers[0].split()
    if not names or any(name not in PLATFORMS for name in names) or len(set(names)) != len(names):
        fail(f"{path} 的平台标记不合法：{markers[0].strip()}")
    return [name for name in PLATFORMS if name in names]


def collect_releases(notes_dir: Path, version: tuple[int, int, int]) -> list[dict]:
    """收集不晚于本次版本的各个共用说明，新版在前（不限个数，由 build 截取）。"""
    found = []
    for path in notes_dir.glob("v*.md"):
        match = NOTES_NAME.match(path.name)
        if not match:
            continue
        number = tuple(int(part) for part in match.groups())
        # 仓库里可能已有更新版本的说明（例如补发旧版本时），清单只写到本次版本为止。
        if number > version:
            continue
        text = path.read_text(encoding="utf-8")
        found.append((number, {
            "version": ".".join(str(part) for part in number),
            "platforms": platforms_of(text, path),
            "notes": text,
        }))
    found.sort(key=lambda item: item[0], reverse=True)
    return [entry for _, entry in found]


def latest_versions(releases: list[dict]) -> dict[str, str]:
    """每个平台的最新版本：releases（新版在前）里第一个标记含这个平台的版本。有平台找不到时报错。"""
    result = {}
    for platform in PLATFORMS:
        match = next((entry["version"] for entry in releases if platform in entry["platforms"]), None)
        if match is None:
            fail(f"发布说明里没有任何版本标记了 {platform}")
        result[platform] = match
    return result


def installer_name(platform: str, label: str) -> str:
    """一个平台的安装包文件名，与 macos.yml、windows.yml 的打包结果一致。label 一般等于版本号。"""
    return f"EVE-O-Preview-{label}.dmg" if platform == "macos" else f"EVE-O-Preview-{label}-windows-x64.zip"


def file_entry(files_dir: Path, name: str, urls: list[str]) -> dict:
    """一个要下载的文件：名字、大小、SHA-256（小写十六进制）与按优先顺序排列的地址。"""
    path = files_dir / name
    if not path.is_file():
        fail(f"{files_dir} 里没有 {name}")
    data = path.read_bytes()
    return {"name": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "urls": urls}


def platform_latest(args: argparse.Namespace, platform: str, version: str) -> dict:
    """一个平台的 latest：安装包与两个校验和文件，地址 R2 在前、GitHub 在后。

    是本次版本时文件在 --files-dir，安装包名用本次的构建标签；更早的版本在 --older-dir/v<版本>/，安装包名按版本号拼。
    """
    tag = f"v{version}"
    if version == args.version:
        files_dir = Path(args.files_dir)
        label = args.mac_label if platform == "macos" else args.windows_label
    else:
        files_dir = Path(args.older_dir) / tag
        label = version
    files = []
    for name in (installer_name(platform, label), *SHARED_FILES):
        urls = []
        if args.r2_base:
            urls.append(f"{args.r2_base.rstrip('/')}/{tag}/{name}")
        urls.append(f"https://github.com/{args.repo}/releases/download/{tag}/{name}")
        files.append(file_entry(files_dir, name, urls))
    return {
        "version": version,
        "tag": tag,
        "pageURL": f"https://github.com/{args.repo}/releases/tag/{tag}",
        "files": files,
    }


def plan(args: argparse.Namespace) -> None:
    """子命令 plan：打印 latest 要用的、比本次早的版本，去重，一行一个。"""
    releases = collect_releases(Path(args.notes_dir), parse_version(args.version))
    older = sorted({version for version in latest_versions(releases).values() if version != args.version})
    for version in older:
        print(version)


def encoded_size(payload: dict) -> int:
    """正文包成信封后的大约字节数（base64 后约 4/3，再加签名与括号）。"""
    raw = len(json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    return (raw + 2) // 3 * 4 + 200


def build(args: argparse.Namespace) -> None:
    """子命令 build：生成清单正文，写到 --out。"""
    version = parse_version(args.version)
    releases = collect_releases(Path(args.notes_dir), version)
    if not releases or releases[0]["version"] != args.version:
        fail(f"找不到本次版本的发布说明 v{args.version}.md")
    versions = latest_versions(releases)
    now = datetime.now(timezone.utc)
    payload = {
        "schema": SCHEMA,
        # 应用记下接受过的最大序号，拒收更旧的清单（防止旧清单被重放）。
        "sequence": int(now.timestamp()),
        "generatedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "latest": {platform: platform_latest(args, platform, versions[platform]) for platform in PLATFORMS},
        "releases": releases[:MAX_RELEASES],
    }
    # 超过预算时从最旧的版本开始去掉；latest 指向的版本要留着（窗口显示它的说明）。
    keep = set(versions.values())
    while encoded_size(payload) > MAX_ENVELOPE_BYTES:
        removable = [index for index, entry in enumerate(payload["releases"]) if entry["version"] not in keep]
        if not removable:
            fail("清单超过预算，且没有可以去掉的旧版本说明")
        del payload["releases"][removable[-1]]
    # 正文用紧凑的 UTF-8 写法：签名的是这些字节，应用拿到后原样验签再解析。
    Path(args.out).write_bytes(json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    changed = " ".join(releases[0]["platforms"])
    summary = ", ".join(f"{name} {entry['version']}" for name, entry in payload["latest"].items())
    print(f"已生成清单正文：本次改动 {changed}；latest：{summary}；releases {len(payload['releases'])} 个")


def message(args: argparse.Namespace) -> None:
    """子命令 message：写出要签名的消息（前缀 + 正文字节）。"""
    Path(args.out).write_bytes(SIGNING_PREFIX + Path(args.payload).read_bytes())


def envelope(args: argparse.Namespace) -> None:
    """子命令 envelope：正文与 base64 的签名包成信封，写到 --out。"""
    payload = Path(args.payload).read_bytes()
    signature = Path(args.signature).read_text(encoding="ascii").strip()
    # 签名应是 64 字节的 ed25519 签名；解不开或长度不对说明前一步出了错。
    if len(base64.b64decode(signature, validate=True)) != 64:
        fail("签名不是 64 字节")
    document = {"format": FORMAT, "payload": base64.b64encode(payload).decode("ascii"), "signature": signature}
    data = json.dumps(document, separators=(",", ":")).encode("ascii") + b"\n"
    if len(data) > MAX_ENVELOPE_BYTES:
        fail(f"清单有 {len(data)} 字节，超过 512 KiB 的预算")
    Path(args.out).write_bytes(data)
    print(f"已写 {args.out}（{len(data)} 字节）")


def open_envelope(args: argparse.Namespace) -> None:
    """子命令 open：信封拆成正文与原始签名字节，各写一个文件。格式不对时报错。"""
    try:
        document = json.loads(Path(args.envelope).read_bytes())
        payload = base64.b64decode(document["payload"], validate=True)
        signature = base64.b64decode(document["signature"], validate=True)
    except (ValueError, KeyError, TypeError) as error:
        fail(f"信封解析不了：{error}")
    if document.get("format") != FORMAT or len(signature) != 64:
        fail("信封的 format 或签名长度不对")
    Path(args.payload_out).write_bytes(payload)
    Path(args.message_out).write_bytes(SIGNING_PREFIX + payload)
    Path(args.signature_out).write_bytes(signature)


def list_files(args: argparse.Namespace) -> None:
    """子命令 files：每行「tag 文件名 SHA-256」，两个平台共用的文件只列一次。"""
    payload = json.loads(Path(args.payload).read_bytes())
    seen = set()
    for platform in PLATFORMS:
        entry = payload["latest"][platform]
        for file in entry["files"]:
            line = f"{entry['tag']} {file['name']} {file['sha256']}"
            # 文件名与 tag 只含发布脚本生成的字符；有空白说明正文不对，不往下传。
            if len(line.split()) != 3:
                fail(f"文件名或 tag 里有空白：{line}")
            if line not in seen:
                seen.add(line)
                print(line)


def main(argv: list[str]) -> None:
    """解析命令行并调用子命令。"""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    zero = commands.add_parser("plan", help="列出 latest 要用的更早版本")
    zero.add_argument("--version", required=True, help="本次版本号，如 1.5.0")
    zero.add_argument("--notes-dir", required=True, help="docs/release-notes")
    zero.set_defaults(handler=plan)

    one = commands.add_parser("build", help="生成清单正文")
    one.add_argument("--version", required=True, help="本次版本号，如 1.5.0")
    one.add_argument("--repo", required=True, help="仓库，如 deletexiumu/eve-o-preview")
    one.add_argument("--notes-dir", required=True, help="docs/release-notes")
    one.add_argument("--files-dir", required=True, help="本次 Release 的附件目录（含 SHA256SUMS.txt 与签名）")
    one.add_argument("--mac-label", required=True, help="本次 dmg 文件名里的构建标签")
    one.add_argument("--windows-label", required=True, help="本次 Windows zip 文件名里的构建标签")
    one.add_argument("--older-dir", default="older", help="更早版本的文件，放在 <目录>/v<版本>/ 下")
    one.add_argument("--r2-base", default="", help="R2 的公开地址；为空时清单里只有 GitHub 的地址")
    one.add_argument("--out", required=True, help="写出的正文文件")
    one.set_defaults(handler=build)

    msg = commands.add_parser("message", help="写出要签名的消息")
    msg.add_argument("--payload", required=True)
    msg.add_argument("--out", required=True)
    msg.set_defaults(handler=message)

    two = commands.add_parser("envelope", help="正文与签名包成信封")
    two.add_argument("--payload", required=True)
    two.add_argument("--signature", required=True, help="一行 base64 的签名文件")
    two.add_argument("--out", required=True)
    two.set_defaults(handler=envelope)

    three = commands.add_parser("open", help="信封拆成正文与原始签名")
    three.add_argument("--envelope", required=True)
    three.add_argument("--payload-out", required=True)
    three.add_argument("--message-out", required=True, help="要验签的消息（前缀 + 正文）")
    three.add_argument("--signature-out", required=True)
    three.set_defaults(handler=open_envelope)

    four = commands.add_parser("files", help="列出 latest 指向的文件")
    four.add_argument("--payload", required=True)
    four.set_defaults(handler=list_files)

    args = parser.parse_args(argv)
    args.handler(args)


if __name__ == "__main__":
    main(sys.argv[1:])
