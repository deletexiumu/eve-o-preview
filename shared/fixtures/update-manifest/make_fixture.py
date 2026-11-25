#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""生成更新清单的跨平台用例（README.md 写了结构）。

用 scripts/build_update_manifest.py 的 build、message、envelope 三个子命令生成一份有效的清单，再做出几份应当被拒收的变体。
签名用 openssl（与 release.yml 相同的做法），私钥是下面固定的测试种子，只用于用例，与发布用的私钥无关。

用法：python3 shared/fixtures/update-manifest/make_fixture.py（在仓库根目录运行）。生成的 manifest.json 与
cases.json 要提交；改了 build_update_manifest.py 或清单格式后重新生成，两端的一致性测试据此核对。
"""

import base64
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
SCRIPT = ROOT / "scripts" / "build_update_manifest.py"
# 测试种子：固定字符串的 SHA-256，谁都能算出来，所以只能用于用例。
SEED = hashlib.sha256(b"eve-o-preview update manifest test key").digest()
# 另一把测试私钥：用它签的清单应当验不过。
OTHER_SEED = hashlib.sha256(b"eve-o-preview update manifest other key").digest()
# ed25519 私钥 PKCS#8 DER 的固定前缀，与 release.yml 相同。
PKCS8_PREFIX = bytes.fromhex("302e020100300506032b657004220420")
REPO = "deletexiumu/eve-o-preview"
R2 = "https://dl.example.com"

# 用例的发布说明：1.4.3 只改 macOS，1.4.2 只改 Windows，1.4.1 与 1.4.0 两端都改。
NOTES = {
    "1.4.3": "macos",
    "1.4.2": "windows",
    "1.4.1": "macos windows",
    "1.4.0": "macos windows",
}


def run(*args: str) -> str:
    """运行命令，失败时退出。"""
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return result.stdout


def notes_text(version: str, platforms: str) -> str:
    """一份最小的发布说明：平台标记、英文块，按平台分小节。"""
    sections = "".join(f"\n## {'macOS' if p == 'macos' else 'Windows'}\n\n- {p} change in {version}.\n"
                       for p in platforms.split())
    return f"<!-- platforms: {platforms} -->\n<!-- lang:en -->\nRelease {version}.\n{sections}<!-- /lang:en -->\n"


def sign(seed: bytes, message: Path, work: Path) -> str:
    """用 openssl 签名，返回一行 base64。"""
    key = work / "key.der"
    key.write_bytes(PKCS8_PREFIX + seed)
    out = work / "sig.bin"
    run("openssl", "pkeyutl", "-sign", "-keyform", "DER", "-inkey", str(key), "-rawin", "-in", str(message),
        "-out", str(out))
    return base64.b64encode(out.read_bytes()).decode("ascii")


def public_key(seed: bytes, work: Path) -> str:
    """种子对应的公钥，十六进制。"""
    key = work / "key.der"
    key.write_bytes(PKCS8_PREFIX + seed)
    der = subprocess.run(["openssl", "pkey", "-inform", "DER", "-in", str(key), "-pubout", "-outform", "DER"],
                         check=True, capture_output=True).stdout
    return der[-32:].hex()


def envelope(payload: bytes, signature: str, fmt: int = 1) -> str:
    """把正文与签名包成信封的文字。"""
    return json.dumps({"format": fmt, "payload": base64.b64encode(payload).decode("ascii"), "signature": signature},
                      separators=(",", ":"))


def main() -> None:
    """生成 manifest.json 与 cases.json。"""
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        notes = work / "notes"
        notes.mkdir()
        for version, platforms in NOTES.items():
            (notes / f"v{version}.md").write_text(notes_text(version, platforms), encoding="utf-8")
        # 各版本的文件：内容是文件名，大小与哈希由脚本算出。
        files = work / "files"
        files.mkdir()
        older = work / "older" / "v1.4.2"
        older.mkdir(parents=True)
        for directory, version in ((files, "1.4.3"), (older, "1.4.2")):
            for name in (f"EVE-O-Preview-{version}.dmg", f"EVE-O-Preview-{version}-windows-x64.zip",
                         "SHA256SUMS.txt", "SHA256SUMS.txt.sig"):
                (directory / name).write_text(f"{version} {name}\n", encoding="utf-8")
        payload_path = work / "payload.json"
        run(sys.executable, str(SCRIPT), "build", "--version", "1.4.3", "--repo", REPO, "--notes-dir", str(notes),
            "--files-dir", str(files), "--mac-label", "1.4.3", "--windows-label", "1.4.3",
            "--older-dir", str(work / "older"), "--r2-base", R2, "--out", str(payload_path))
        # 固定序号与时刻，重新生成时内容不变。
        payload_obj = json.loads(payload_path.read_bytes())
        payload_obj["sequence"] = 1700000000
        payload_obj["generatedAt"] = "2023-11-14T22:13:20Z"
        payload = json.dumps(payload_obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        payload_path.write_bytes(payload)
        message = work / "message"
        run(sys.executable, str(SCRIPT), "message", "--payload", str(payload_path), "--out", str(message))
        good_signature = sign(SEED, message, work)
        (HERE / "manifest.json").write_text(envelope(payload, good_signature) + "\n", encoding="ascii")

        # 应当被拒收的变体，各自说明原因。
        tampered = payload.replace(b'"sequence":1700000000', b'"sequence":1700000001')
        raw_message = work / "raw"
        raw_message.write_bytes(payload)
        no_sha = json.loads(payload)
        for entry in no_sha["latest"].values():
            del entry["files"][0]["sha256"]
        no_sha_bytes = json.dumps(no_sha, separators=(",", ":")).encode("utf-8")
        no_sha_message = work / "nosha"
        no_sha_message.write_bytes(b"eveo-update-manifest-v1\n" + no_sha_bytes)
        schema2 = json.loads(payload)
        schema2["schema"] = 2
        schema2_bytes = json.dumps(schema2, separators=(",", ":")).encode("utf-8")
        schema2_message = work / "schema2"
        schema2_message.write_bytes(b"eveo-update-manifest-v1\n" + schema2_bytes)
        invalid = [
            {"name": "正文被改过", "envelope": envelope(tampered, good_signature)},
            {"name": "另一把私钥签的", "envelope": envelope(payload, sign(OTHER_SEED, message, work))},
            {"name": "签名时没有前缀", "envelope": envelope(payload, sign(SEED, raw_message, work))},
            {"name": "format 不是 1", "envelope": envelope(payload, good_signature, fmt=2)},
            {"name": "schema 不是 1", "envelope": envelope(schema2_bytes, sign(SEED, schema2_message, work))},
            {"name": "安装包缺 sha256", "envelope": envelope(no_sha_bytes, sign(SEED, no_sha_message, work))},
            {"name": "不是 JSON", "envelope": "not json"},
        ]

        latest = payload_obj["latest"]
        cases = {
            "publicKey": public_key(SEED, work),
            "sequence": 1700000000,
            "latest": {platform: {"version": entry["version"], "tag": entry["tag"], "pageURL": entry["pageURL"],
                                  "files": entry["files"]} for platform, entry in latest.items()},
            # 中间版本：平台含本平台、且 running < v < latest，新版在前。
            "intermediate": [
                {"platform": "macos", "running": "1.4.0", "versions": ["1.4.1"]},
                {"platform": "macos", "running": "1.3.2", "versions": ["1.4.1", "1.4.0"]},
                {"platform": "windows", "running": "1.4.0", "versions": ["1.4.1"]},
                {"platform": "windows", "running": "1.4.1", "versions": []},
            ],
            "invalid": invalid,
        }
        (HERE / "cases.json").write_text(json.dumps(cases, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("已生成 manifest.json 与 cases.json")


if __name__ == "__main__":
    main()
