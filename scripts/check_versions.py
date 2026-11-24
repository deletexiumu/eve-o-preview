#!/usr/bin/env python3
"""检查两个平台的版本号一致（1.4.0 起 macOS 与 Windows 用同一个 tag 一起发布）。

版本号写在三处，必须完全相同：
- macos/VERSION：macOS 版打包时写进 Info.plist；
- windows/VERSION：Windows 版打包与发布用；
- windows/Cargo.toml 的 [workspace.package] version：Windows 应用比较新旧时用它。

给出 --tag 时（发布工作流里传入推送的 tag），tag 必须是 v<版本号>。只改了一个平台也一起发版，
另一个平台同号重新打包：这样两个平台的同一个版本号永远指同一次提交。

用法：python3 scripts/check_versions.py [--tag v1.4.0]
不一致时打印原因并以退出码 1 结束；一致时打印版本号。
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Cargo.toml 里 [workspace.package] 一节的 version 行；只认这一节，别的 crate 的 version 不算。
WORKSPACE_VERSION = re.compile(r'^\[workspace\.package\]\s*$(.*?)^version\s*=\s*"([^"]+)"', re.MULTILINE | re.DOTALL)


def read_version(relative: str) -> str:
    """读一个 VERSION 文件，去掉首尾空白。"""
    return (ROOT / relative).read_text(encoding="utf-8").strip()


def cargo_version() -> str | None:
    """windows/Cargo.toml 的工作区版本；找不到时返回 None。"""
    text = (ROOT / "windows" / "Cargo.toml").read_text(encoding="utf-8")
    match = WORKSPACE_VERSION.search(text)
    # 匹配到的 version 必须还在 [workspace.package] 这一节里：中间不能隔着别的节标题。
    if match is None or re.search(r"^\[", match.group(1), re.MULTILINE):
        return None
    return match.group(2)


def main(argv: list[str]) -> int:
    """逐项比较，打印结果；有问题时返回 1。"""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", help="推送的 tag，应为 v<版本号>")
    args = parser.parse_args(argv)
    versions = {
        "macos/VERSION": read_version("macos/VERSION"),
        "windows/VERSION": read_version("windows/VERSION"),
        "windows/Cargo.toml": cargo_version() or "（没找到 [workspace.package] 的 version）",
    }
    problems = []
    if len(set(versions.values())) != 1:
        listing = "，".join(f"{name} 是 {value}" for name, value in versions.items())
        problems.append(f"两个平台的版本号不一致：{listing}")
    version = versions["macos/VERSION"]
    if args.tag is not None and args.tag != f"v{version}":
        problems.append(f"tag {args.tag} 与版本号 {version} 不一致，应为 v{version}")
    for problem in problems:
        print(f"::error::{problem}")
    if problems:
        return 1
    print(f"版本号一致：{version}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
