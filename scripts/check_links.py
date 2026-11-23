#!/usr/bin/env python3
"""检查仓库内 Markdown 文档的相对链接（docs/windows/architecture.md 7.6 节）。

目录重组之后，文档之间、文档到源码的相对链接最容易失效，而 GitHub 不会报错。
这里只查仓库内的相对链接：

- 查 [文字](路径)、[文字]: 路径 与 <img src="路径"> 三种写法里的路径，去掉 #锚点 与 ?参数后，
  相对 Markdown 文件所在目录解析，目标文件或目录要存在。
- 以 http:、https:、mailto: 开头的外部链接与只有 #锚点 的页内链接不查。
- 代码块（``` 围起来的部分）与行内代码（`…`）里的内容不查。

用法：python3 scripts/check_links.py [文件或目录 ...]，默认检查整个仓库里已提交的 .md 文件。
有失效链接时退出码为 1。
"""

import re
import subprocess
import sys
from pathlib import Path

# [文字](路径) 与 ![图](路径)：路径里不含空白与右括号；可带 "标题"。
INLINE_LINK = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
# [标签]: 路径 形式的引用定义。
REFERENCE_DEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$")
# HTML 图片的 src。
IMG_SRC = re.compile(r"<img\b[^>]*\bsrc=\"([^\"]+)\"")
# 行内代码。
INLINE_CODE = re.compile(r"`[^`]*`")
# 不查的链接前缀。
EXTERNAL = ("http:", "https:", "mailto:", "#")


def links(text):
    """逐行取出链接目标，返回 [(行号, 目标)]，跳过代码块与行内代码。"""
    found = []
    in_fence = False
    for number, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        line = INLINE_CODE.sub("", line)
        found.extend((number, m.group(1)) for m in INLINE_LINK.finditer(line))
        found.extend((number, m.group(1)) for m in IMG_SRC.finditer(line))
        ref = REFERENCE_DEF.match(line)
        if ref:
            found.append((number, ref.group(1)))
    return found


def broken_links(path):
    """返回一个 Markdown 文件里失效的相对链接 [(行号, 目标)]。"""
    problems = []
    for number, target in links(path.read_text(encoding="utf-8")):
        if target.startswith(EXTERNAL):
            continue
        relative = target.split("#", 1)[0].split("?", 1)[0]
        if not relative:
            continue
        if not (path.parent / relative).exists():
            problems.append((number, target))
    return problems


def markdown_files(repo, args):
    """命令行给的文件与目录下的 .md；没给时取 git 里已提交的全部 .md。"""
    if args:
        files = []
        for arg in map(Path, args):
            files.extend(sorted(arg.rglob("*.md")) if arg.is_dir() else [arg])
        return files
    tracked = subprocess.run(["git", "-C", str(repo), "ls-files", "*.md"],
                             check=True, capture_output=True, text=True).stdout.split()
    return [repo / name for name in tracked]


def main(argv):
    repo = Path(__file__).resolve().parent.parent
    files = markdown_files(repo, argv)
    failed = 0
    for path in files:
        for number, target in broken_links(path):
            failed += 1
            print(f"{path}:{number}：链接失效 {target}")
    print(f"检查了 {len(files)} 个 Markdown 文件，失效链接 {failed} 个")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
