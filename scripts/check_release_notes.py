#!/usr/bin/env python3
"""检查发布说明的语言标记（架构文档 9.7 节，v1.1 设计 8.2 节）。

发布说明原样作为 GitHub Release 的正文，应用内的更新提示按语言标记取对应的一块。
标记写错时应用会退回英文或显示全文，不会报错，所以在 CI 里提前拦下。

规则：
- 每个 `<!-- lang:xx -->` 后面有对应的 `<!-- /lang:xx -->`，不嵌套、不重复。
- 语言代码只能是 en、zh、ja、ko、ru、fr、de、es，且 en 块存在。
- 除 en 外，每块里的 `<details>` 与 `</details>` 成对。
- 顶层的 v<版本>.md（1.4.0 起两个平台共用）第一行是平台标记 `<!-- platforms: macos windows -->`，
  取值是 macos、windows 中的一个或两个（docs/update-manifest.md 第 1 节）。更新清单按它决定哪个平台提示更新，
  所以标记里没有的平台，任何语言块里都不能有以这个平台名为标题的小节（如只标 windows 时不能有 `## macOS`）。
- 不写「升级」小节：怎么升级由应用内更新和 README 说明，发布说明只讲本版本的变化。
  应用会把跳过的各版本说明拼在一起显示，每版都带一段升级说明会反复出现。

用法：python3 scripts/check_release_notes.py [文件 ...]，默认检查 docs/release-notes/ 下的全部 .md：
顶层的 v<版本>.md 是 1.4.0 起两个平台共用一个 tag 发布的说明，macos/、windows/ 里是此前各自发布的说明。
格式与规则都相同。
任一文件不合格时退出码为 1。
"""

import re
import sys
from pathlib import Path

# 应用支持的界面语言代码，与发布说明的语言块一一对应。
LANGUAGES = ("en", "zh", "ja", "ko", "ru", "fr", "de", "es")

# 标记的写法：<!-- lang:xx --> 与 <!-- /lang:xx -->，注释两端的空白可有可无。
MARKER = re.compile(r"<!--\s*(/?)lang:([A-Za-z-]+)\s*-->")

# 平台标记：<!-- platforms: macos windows -->，与 scripts/build_update_manifest.py 的写法一致。
PLATFORM_MARKER = re.compile(r"<!--\s*platforms:([^>]*?)\s*-->")
# 已知的平台，与清单里 latest 的键相同。
PLATFORMS = ("macos", "windows")
# 平台小节的标题：二、三级标题，文字正好是平台名（不分大小写）。应用显示说明时按同样的规则去掉别的平台的小节。
PLATFORM_HEADING = re.compile(r"^#{2,3}\s+(macOS|Windows)\s*$", re.MULTILINE | re.IGNORECASE)

# 各语言「升级」小节的标题写法（二、三级标题），出现即不合格。
# 列的是此前发布说明实际用过的标题，新增语言时一并补上。
UPGRADE_HEADING = re.compile(
    r"^#{2,3}\s+(Upgrading\b.*|升级|从 .* 升级|アップグレード|.*からのアップグレード|업그레이드|.*에서 업그레이드"
    r"|Обновление\b.*|Mise à jour|Aktualisieren|Actualizar)\s*$",
    re.MULTILINE,
)


def is_unified(path: Path) -> bool:
    """是否是 1.4.0 起两个平台共用的说明：直接放在 docs/release-notes/ 下（不在 macos/、windows/ 子目录里）。"""
    return path.resolve().parent.name == "release-notes"


def check_platforms(text: str) -> list[str]:
    """核对平台标记：第一行是标记，取值合法、不重复；标记外的平台没有自己的小节。"""
    problems = []
    markers = PLATFORM_MARKER.findall(text)
    if len(markers) != 1:
        return [f"应有且只有一个平台标记 <!-- platforms: … -->，现有 {len(markers)} 个"]
    if not PLATFORM_MARKER.match(text.lstrip("\ufeff")):
        problems.append("平台标记应在第一行")
    names = markers[0].split()
    unknown = [name for name in names if name not in PLATFORMS]
    if unknown:
        problems.append(f"平台标记里有未知的平台：{' '.join(unknown)}")
    if not names or len(set(names)) != len(names):
        problems.append("平台标记应列出一个或两个不重复的平台")
    # 标记外的平台不能有自己的小节：应用按标记决定提示，说明里却写了这个平台的改动，说明就对不上了。
    for match in PLATFORM_HEADING.finditer(text):
        if match.group(1).lower() not in names:
            line = text.count("\n", 0, match.start()) + 1
            problems.append(f"第 {line} 行：平台标记里没有 {match.group(1)}，却有它的小节")
    return problems


def check(path: Path) -> list[str]:
    """返回该文件的问题列表，空列表表示合格。"""
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    problems = check_platforms(text) if is_unified(path) else []
    open_code = None      # 当前打开、尚未关闭的语言块
    open_at = 0           # 当前块正文的起点
    seen = []             # 已关闭的语言块，按出现顺序
    for match in MARKER.finditer(text):
        closing, code = match.group(1) == "/", match.group(2).lower()
        line = text.count("\n", 0, match.start()) + 1
        if code not in LANGUAGES:
            problems.append(f"第 {line} 行：未知的语言代码 {code}")
            continue
        if not closing:
            if open_code is not None:
                problems.append(f"第 {line} 行：{code} 块开始时 {open_code} 块还没关闭")
            if code in seen:
                problems.append(f"第 {line} 行：{code} 块重复")
            open_code, open_at = code, match.end()
            continue
        if open_code != code:
            problems.append(f"第 {line} 行：关闭标记 /lang:{code} 没有对应的开始标记")
            continue
        # 非英文块应包在 <details> 里，并且开闭成对。
        body = text[open_at:match.start()]
        if code != "en" and body.count("<details>") != body.count("</details>"):
            problems.append(f"{code} 块的 <details> 与 </details> 不成对")
        seen.append(code)
        open_code = None
    if open_code is not None:
        problems.append(f"{open_code} 块没有关闭标记")
    if "en" not in seen:
        problems.append("缺少 en 块")
    # 升级说明不进发布说明，见文件头的规则。
    for match in UPGRADE_HEADING.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        problems.append(f"第 {line} 行：发布说明不写升级小节（{match.group(0).strip()}）")
    return problems


def main(argv: list[str]) -> int:
    """逐个检查文件，打印结果；有问题时返回 1。"""
    notes = Path(__file__).resolve().parent.parent / "docs" / "release-notes"
    paths = [Path(a) for a in argv] or sorted([*notes.glob("*.md"), *notes.glob("*/*.md")])
    if not paths:
        print("没有找到发布说明文件")
        return 1
    failed = False
    for path in paths:
        problems = check(path)
        if problems:
            failed = True
            print(f"{path}：不合格")
            for problem in problems:
                print(f"  - {problem}")
        else:
            print(f"{path}：合格")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
