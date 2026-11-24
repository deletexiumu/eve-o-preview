#!/usr/bin/env python3
"""检查发布说明的语言标记（架构文档 9.7 节，v1.1 设计 8.2 节）。

发布说明原样作为 GitHub Release 的正文，应用内的更新提示按语言标记取对应的一块。
标记写错时应用会退回英文或显示全文，不会报错，所以在 CI 里提前拦下。

规则：
- 每个 `<!-- lang:xx -->` 后面有对应的 `<!-- /lang:xx -->`，不嵌套、不重复。
- 语言代码只能是 en、zh、ja、ko、ru、fr、de、es，且 en 块存在。
- 除 en 外，每块里的 `<details>` 与 `</details>` 成对。
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

# 各语言「升级」小节的标题写法（二、三级标题），出现即不合格。
# 列的是此前发布说明实际用过的标题，新增语言时一并补上。
UPGRADE_HEADING = re.compile(
    r"^#{2,3}\s+(Upgrading\b.*|升级|从 .* 升级|アップグレード|.*からのアップグレード|업그레이드|.*에서 업그레이드"
    r"|Обновление\b.*|Mise à jour|Aktualisieren|Actualizar)\s*$",
    re.MULTILINE,
)


def check(path: Path) -> list[str]:
    """返回该文件的问题列表，空列表表示合格。"""
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    problems = []
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
