#!/usr/bin/env python3
"""检查发布说明的语言标记（架构文档 9.7 节，v1.1 设计 8.2 节）。

发布说明原样作为 GitHub Release 的正文，应用内的更新提示按语言标记取对应的一块。
标记写错时应用会退回英文或显示全文，不会报错，所以在 CI 里提前拦下。

规则：
- 每个 `<!-- lang:xx -->` 后面有对应的 `<!-- /lang:xx -->`，不嵌套、不重复。
- 语言代码只能是 en、zh、ja、ko、ru、fr、de、es，且 en 块存在。
- 除 en 外，每块里的 `<details>` 与 `</details>` 成对。

用法：python3 scripts/check_release_notes.py [文件 ...]，默认检查 docs/release-notes/*.md。
任一文件不合格时退出码为 1。
"""

import re
import sys
from pathlib import Path

# 应用支持的界面语言代码，与发布说明的语言块一一对应。
LANGUAGES = ("en", "zh", "ja", "ko", "ru", "fr", "de", "es")

# 标记的写法：<!-- lang:xx --> 与 <!-- /lang:xx -->，注释两端的空白可有可无。
MARKER = re.compile(r"<!--\s*(/?)lang:([A-Za-z-]+)\s*-->")


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
    return problems


def main(argv: list[str]) -> int:
    """逐个检查文件，打印结果；有问题时返回 1。"""
    paths = [Path(a) for a in argv] or sorted(Path("docs/release-notes").glob("*.md"))
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
