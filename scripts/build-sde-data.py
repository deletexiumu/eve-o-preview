#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""从 CCP 的静态数据（SDE）生成精简的星图数据文件 packaging/eve-static.json。

做法见 docs/design-intel-translate.md 4.1 节与 4.2 节：
1. 读 latest.jsonl 取 buildNumber 与 releaseDate。
2. 用 HTTP 分段请求读压缩包末尾的目录，只下载用到的 5 个文件，边下载边解压边按行解析。
   服务器不支持分段请求时，把整个压缩包下载到临时文件再读，读完删除。
3. 只留星系（ID 在 30,000,000～31,999,999）、星域、星门连接、已发布的舰船分组与舰船。
4. 英文名写进 n；其余 7 种语言的名称去掉首尾空白后与英文不同的才写进 l。
5. 键按固定顺序，记录按 ID 排序，分隔符不带空格，末尾一个换行。同一个 SDE 版本两次运行的输出逐字节相同。

只用 Python 标准库。用法：
  python3 scripts/build-sde-data.py                 生成文件，打印各类记录的数量与文件大小
  python3 scripts/build-sde-data.py --check         只比较版本：相同退出 0，落后退出 2，连不上退出 3
  python3 scripts/build-sde-data.py --output 路径    写到别的位置
  python3 scripts/build-sde-data.py --build 版本号   用指定的 SDE 版本，不读 latest.jsonl
"""

import argparse
import io
import json
import os
import struct
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
import zlib
from pathlib import Path

# SDE 的下载地址（S1、S2）。
BASE_URL = "https://developers.eveonline.com/static-data/tranquility"
LATEST_URL = BASE_URL + "/latest.jsonl"
# 通用的客户端名，不带任何项目或用户信息。
USER_AGENT = "sde-data-builder/1.0"
# 网络请求的超时，单位是秒。
TIMEOUT = 120
# 数据文件格式的版本（4.2 节）。结构变化时加 1，并同步改 StaticDataFile.currentFormat。
FORMAT = 1
# 名称的语言：英文写进 n，其余写进 l（与 AppLanguage 的原始值相同）。
OTHER_LANGUAGES = ("zh", "ru", "ja", "ko", "fr", "de", "es")
# 保留的星系 ID 范围：已知空间与虫洞空间（4.1 节第 3 步）。
SYSTEM_ID_RANGE = (30_000_000, 31_999_999)
# 舰船的类别 ID。
SHIP_CATEGORY_ID = 6
# 默认的输出位置：仓库的 packaging/eve-static.json。
DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "packaging" / "eve-static.json"
# 分段读压缩包目录时，每次请求的块大小。
RANGE_BLOCK = 65_536


def request(url, headers=None, method="GET"):
    """发一个 HTTP 请求，返回响应对象。"""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})}, method=method)
    return urllib.request.urlopen(req, timeout=TIMEOUT)


def latest_release():
    """读 latest.jsonl，返回 (buildNumber, releaseDate)。"""
    with request(LATEST_URL) as resp:
        for line in resp.read().decode("utf-8").splitlines():
            if not line.strip():
                continue
            obj = json.loads(line)
            if obj.get("_key") == "sde":
                return int(obj["buildNumber"]), obj.get("releaseDate")
    raise RuntimeError("latest.jsonl 里没有 sde 一行")


def zip_url(build):
    """某个 SDE 版本的 JSONL 压缩包地址。"""
    return f"{BASE_URL}/eve-online-static-data-{build}-jsonl.zip"


class RangeFile(io.RawIOBase):
    """把远端文件包装成可定位读取的文件对象，按块用分段请求取数据，供 zipfile 读目录。"""

    def __init__(self, url, size):
        super().__init__()
        self.url = url
        self.size = size
        self.pos = 0
        # 已取到的块，键是块号。目录只在文件末尾，用到的块很少。
        self.blocks = {}

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        base = {0: 0, 1: self.pos, 2: self.size}[whence]
        self.pos = max(0, base + offset)
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        out = bytearray()
        while n > 0 and self.pos < self.size:
            index = self.pos // RANGE_BLOCK
            if index not in self.blocks:
                start = index * RANGE_BLOCK
                end = min(start + RANGE_BLOCK, self.size) - 1
                with request(self.url, {"Range": f"bytes={start}-{end}"}) as resp:
                    self.blocks[index] = resp.read()
            block = self.blocks[index]
            offset = self.pos % RANGE_BLOCK
            piece = block[offset:offset + n]
            if not piece:
                break
            out += piece
            self.pos += len(piece)
            n -= len(piece)
        return bytes(out)

    def readinto(self, buffer):
        data = self.read(len(buffer))
        buffer[:len(data)] = data
        return len(data)


def iter_json_lines(chunks):
    """把一串字节块按换行切开，逐行解析成 JSON 对象，空行跳过。"""
    rest = b""
    for chunk in chunks:
        rest += chunk
        *lines, rest = rest.split(b"\n")
        for line in lines:
            if line.strip():
                yield json.loads(line)
    if rest.strip():
        yield json.loads(rest)


class RemoteArchive:
    """用分段请求读压缩包里的单个文件：先读目录，再只下载那个文件的压缩数据。"""

    def __init__(self, url):
        self.url = url
        with request(url, method="HEAD") as resp:
            self.size = int(resp.headers["Content-Length"])
            accepts = resp.headers.get("Accept-Ranges", "")
        if "bytes" not in accepts.lower():
            raise RangeUnsupported()
        infos = zipfile.ZipFile(RangeFile(url, self.size)).infolist()
        # 包里的文件可能放在子目录下，按最后一段文件名查。
        self.infos = {info.filename.rsplit("/", 1)[-1]: info for info in infos}

    def rows(self, name):
        """逐行解析包里名为 name 的 JSONL 文件。"""
        info = self.infos[name]
        # 本地文件头 30 字节，之后是文件名与扩展字段，再之后才是压缩数据。
        with request(self.url, {"Range": f"bytes={info.header_offset}-{info.header_offset + 29}"}) as resp:
            header = resp.read()
        name_length, extra_length = struct.unpack("<HH", header[26:30])
        start = info.header_offset + 30 + name_length + extra_length
        end = start + info.compress_size - 1
        with request(self.url, {"Range": f"bytes={start}-{end}"}) as resp:
            yield from iter_json_lines(decompressed(resp, info.compress_type))


class RangeUnsupported(Exception):
    """服务器不支持分段请求。"""


def decompressed(stream, method):
    """边读边解压：deflate（8）或不压缩（0）。"""
    inflater = zlib.decompressobj(-15) if method == zipfile.ZIP_DEFLATED else None
    if method not in (zipfile.ZIP_DEFLATED, zipfile.ZIP_STORED):
        raise RuntimeError(f"不支持的压缩方式 {method}")
    while True:
        raw = stream.read(262_144)
        if not raw:
            break
        yield inflater.decompress(raw) if inflater else raw
    if inflater:
        yield inflater.flush()


class LocalArchive:
    """分段请求不可用时的退路：整个压缩包下载到临时文件，读完由调用方删除。"""

    def __init__(self, url, path):
        with request(url) as resp, open(path, "wb") as out:
            while True:
                block = resp.read(1_048_576)
                if not block:
                    break
                out.write(block)
        self.zip = zipfile.ZipFile(path)
        self.names = {info.filename.rsplit("/", 1)[-1]: info.filename for info in self.zip.infolist()}

    def rows(self, name):
        """逐行解析包里名为 name 的 JSONL 文件。"""
        with self.zip.open(self.names[name]) as f:
            yield from iter_json_lines(iter(lambda: f.read(262_144), b""))

    def close(self):
        self.zip.close()


def names_of(value):
    """把 SDE 的多语言名称对象拆成 (英文名, 与英文不同的其他语言名称)。"""
    value = value or {}
    english = str(value.get("en", "")).strip()
    localized = {}
    for language in OTHER_LANGUAGES:
        text = value.get(language)
        if isinstance(text, str) and text.strip() and text.strip() != english:
            localized[language] = text.strip()
    return english, localized


def named_record(key, name_value, extra=None):
    """建一条 {i, n, l, …} 记录，键按固定顺序；没有不同的名称时省略 l。"""
    english, localized = names_of(name_value)
    record = {"i": key, "n": english}
    if localized:
        record["l"] = localized
    for field, value in (extra or {}).items():
        if value is not None:
            record[field] = value
    return record


def security_value(raw):
    """安全等级保留 3 位小数；-0.0 写成 0.0，保证输出稳定。"""
    if raw is None:
        return None
    value = round(float(raw), 3)
    return 0.0 if value == 0 else value


def build_data(archive, build, release_date):
    """从压缩包里取数，返回要写进文件的字典。"""
    regions = [named_record(o["_key"], o.get("name")) for o in archive.rows("mapRegions.jsonl")]

    systems = []
    for o in archive.rows("mapSolarSystems.jsonl"):
        key = o["_key"]
        if not SYSTEM_ID_RANGE[0] <= key <= SYSTEM_ID_RANGE[1]:
            continue
        systems.append(named_record(key, o.get("name"),
                                    {"s": security_value(o.get("securityStatus")), "r": o.get("regionID")}))
    kept = {s["i"] for s in systems}

    jumps = set()
    for o in archive.rows("mapStargates.jsonl"):
        a = o.get("solarSystemID")
        b = (o.get("destination") or {}).get("solarSystemID")
        # 两端不同、且都在保留的星系里时记一对，小的 ID 在前。
        if a and b and a != b and a in kept and b in kept:
            jumps.add((min(a, b), max(a, b)))

    ship_groups = []
    group_ids = set()
    for o in archive.rows("groups.jsonl"):
        if o.get("categoryID") == SHIP_CATEGORY_ID and o.get("published"):
            ship_groups.append(named_record(o["_key"], o.get("name")))
            group_ids.add(o["_key"])

    ships = []
    for o in archive.rows("types.jsonl"):
        if o.get("published") and o.get("groupID") in group_ids:
            english, localized = names_of(o.get("name"))
            record = {"i": o["_key"], "g": o["groupID"], "n": english}
            if localized:
                record["l"] = localized
            ships.append(record)

    data = {"format": FORMAT, "sdeBuild": build}
    if release_date:
        data["sdeReleaseDate"] = release_date
    by_id = lambda r: r["i"]  # noqa: E731
    data["regions"] = sorted(regions, key=by_id)
    data["systems"] = sorted(systems, key=by_id)
    data["jumps"] = [list(pair) for pair in sorted(jumps)]
    data["shipGroups"] = sorted(ship_groups, key=by_id)
    data["ships"] = sorted(ships, key=by_id)
    return data


def encode(data):
    """固定写法的 JSON 字节：不转义非 ASCII，分隔符不带空格，末尾一个换行。"""
    return (json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def check(path):
    """--check：比较文件里的 sdeBuild 与最新版本，返回退出码 0、2 或 3。"""
    try:
        latest, _ = latest_release()
    except (urllib.error.URLError, OSError, ValueError, RuntimeError) as error:
        print(f"连不上 SDE 服务器：{error}", file=sys.stderr)
        return 3
    try:
        current = json.loads(path.read_text(encoding="utf-8")).get("sdeBuild")
    except (OSError, ValueError):
        current = None
    print(f"文件里的版本 {current}，最新版本 {latest}")
    return 0 if current == latest else 2


def generate(output, build_override):
    """生成数据文件，打印各类记录的数量与文件大小。"""
    if build_override is None:
        build, release_date = latest_release()
    else:
        build = build_override
        # 指定的版本恰好是最新版本时才知道发布日期，否则省略这个键。
        try:
            latest, latest_date = latest_release()
            release_date = latest_date if latest == build else None
        except (urllib.error.URLError, OSError, ValueError, RuntimeError):
            release_date = None
    url = zip_url(build)
    print(f"SDE 版本 {build}（{release_date or '发布日期未知'}）")
    temp_path = None
    try:
        try:
            archive = RemoteArchive(url)
        except RangeUnsupported:
            print("服务器不支持分段请求，改为下载整个压缩包")
            handle, temp_path = tempfile.mkstemp(suffix=".zip")
            os.close(handle)
            archive = LocalArchive(url, temp_path)
        data = build_data(archive, build, release_date)
        if isinstance(archive, LocalArchive):
            archive.close()
    finally:
        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)
    raw = encode(data)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(raw)
    wormholes = sum(1 for s in data["systems"] if s["i"] >= 31_000_000)
    print(f"星域 {len(data['regions'])}，星系 {len(data['systems'])}（虫洞 {wormholes}），"
          f"星门连接 {len(data['jumps'])}，舰船分组 {len(data['shipGroups'])}，舰船 {len(data['ships'])}")
    print(f"写入 {output}：{len(raw):,} 字节")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="从 CCP 的 SDE 生成 eve-static.json")
    parser.add_argument("--check", action="store_true", help="只比较版本，不生成文件")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="输出路径")
    parser.add_argument("--build", type=int, help="指定 SDE 版本号，不读 latest.jsonl")
    args = parser.parse_args(argv)
    if args.check:
        return check(args.output)
    return generate(args.output, args.build)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
