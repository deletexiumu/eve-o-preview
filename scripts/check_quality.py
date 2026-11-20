#!/usr/bin/env python3
"""代码质量门禁：检查 Swift 源码的注释率、文件行数与函数行数。

口径（与 docs/architecture.md 保持一致）：
- 注释率 = 注释行 / (注释行 + 代码行)，空行不计入分母。
  一行里既有代码又有行尾注释时，按代码行计（不重复计数），
  这样注释率只会被低估，不会被高估。
- 文件行数上限 1000 行（含空行）。
- 函数行数上限 500 行：从 func / init / deinit / 计算属性的声明行起，
  到对应的右花括号止。

用法：python3 scripts/check_quality.py [目录 ...]，默认检查 Sources 与 Tests。
任一项不达标时退出码为 1。
"""

import re
import sys
from pathlib import Path

# 门禁阈值
MIN_COMMENT_RATIO = 0.20
MAX_FILE_LINES = 1000
MAX_FUNC_LINES = 500

# 识别函数类声明的正则：允许前面带访问修饰符、属性包装等关键字
FUNC_DECL = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|private|fileprivate|internal|open|static|class|final|"
    r"override|mutating|nonisolated|convenience|required|async)\s+)*"
    r"(?:func\s+\S+|init[?!]?\s*[(<]|deinit\b)"
)


def classify_lines(text: str):
    """逐行分类，返回 (注释行数, 代码行数, 去掉注释与字符串后的行列表)。

    处理 // 行注释、/* */ 块注释（含跨行）和字符串字面量，
    避免把字符串里的 "//" 误判成注释。多行字符串 \"\"\" 按代码处理。
    """
    comment_lines = 0
    code_lines = 0
    stripped_lines = []
    in_block = False
    in_multiline_string = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line and not in_block:
            stripped_lines.append("")
            continue
        has_code = False
        has_comment = False
        out = []
        i = 0
        n = len(raw)
        while i < n:
            ch = raw[i]
            if in_block:
                has_comment = True
                if raw.startswith("*/", i):
                    in_block = False
                    i += 2
                else:
                    i += 1
                continue
            if in_multiline_string:
                has_code = True
                if raw.startswith('"""', i):
                    in_multiline_string = False
                    i += 3
                else:
                    i += 1
                continue
            if raw.startswith("//", i):
                has_comment = True
                break
            if raw.startswith("/*", i):
                in_block = True
                has_comment = True
                i += 2
                continue
            if raw.startswith('"""', i):
                in_multiline_string = True
                has_code = True
                i += 3
                continue
            if ch == '"':
                # 跳过普通字符串字面量，处理转义
                has_code = True
                i += 1
                while i < n and raw[i] != '"':
                    i += 2 if raw[i] == "\\" else 1
                i += 1
                out.append('""')
                continue
            if not ch.isspace():
                has_code = True
            out.append(ch)
            i += 1
        if has_code:
            code_lines += 1
        elif has_comment:
            comment_lines += 1
        stripped_lines.append("".join(out))
    return comment_lines, code_lines, stripped_lines


def long_functions(stripped_lines):
    """用花括号配对找出超过上限的函数，返回 [(起始行号, 行数, 声明)]。"""
    results = []
    depth = 0
    # 栈元素：(声明所在行号, 声明开始时的花括号深度, 声明文本)
    pending = None
    stack = []
    for idx, line in enumerate(stripped_lines, start=1):
        if FUNC_DECL.match(line):
            pending = (idx, depth, line.strip())
        for ch in line:
            if ch == "{":
                if pending is not None:
                    stack.append(pending)
                    pending = None
                depth += 1
            elif ch == "}":
                depth -= 1
                if stack and stack[-1][1] == depth:
                    start, _, decl = stack.pop()
                    length = idx - start + 1
                    if length > MAX_FUNC_LINES:
                        results.append((start, length, decl))
    return results


def main(argv):
    roots = [Path(a) for a in argv[1:]] or [Path("Sources"), Path("Tests")]
    files = sorted(p for r in roots if r.exists() for p in r.rglob("*.swift"))
    if not files:
        print("未找到 Swift 源文件")
        return 1
    total_comment = 0
    total_code = 0
    failures = []
    for path in files:
        text = path.read_text(encoding="utf-8")
        line_count = len(text.splitlines())
        c, k, stripped = classify_lines(text)
        total_comment += c
        total_code += k
        if line_count > MAX_FILE_LINES:
            failures.append(f"文件超过 {MAX_FILE_LINES} 行：{path}（{line_count} 行）")
        for start, length, decl in long_functions(stripped):
            failures.append(f"函数超过 {MAX_FUNC_LINES} 行：{path}:{start}（{length} 行）{decl}")
        ratio = c / (c + k) if c + k else 0.0
        print(f"{ratio:6.1%}  {line_count:5d} 行  {path}")
    overall = total_comment / (total_comment + total_code) if total_comment + total_code else 0.0
    print(f"\n文件数 {len(files)}，注释行 {total_comment}，代码行 {total_code}，总注释率 {overall:.1%}")
    if overall <= MIN_COMMENT_RATIO:
        failures.append(f"总注释率 {overall:.1%} 未超过 {MIN_COMMENT_RATIO:.0%}")
    if failures:
        print("\n不达标：")
        for f in failures:
            print(f"- {f}")
        return 1
    print("质量门禁通过")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
