#!/usr/bin/env python3
"""代码质量门禁：检查 Swift、Rust 与 Slint 源码的注释率、文件行数与函数行数。

口径（与 docs/macos/architecture.md、docs/windows/architecture.md 7.3 节保持一致）：
- 注释率 = 注释行 / (注释行 + 代码行)，空行不计入分母，每种语言分开算，各自要超过 20%。
  一行里既有代码又有行尾注释时，按代码行计（不重复计数），
  这样注释率只会被低估，不会被高估。
- 文件行数上限 1000 行（含空行）。
- 函数行数上限 500 行：从声明行起，到对应的右花括号止。
  Swift 认 func / init / deinit；Rust 认 fn；Slint 认 function。
- 注释的写法：三种语言都认 // 行注释（含 /// 与 //!）与 /* */ 块注释。
- 生成的文件（前 5 行里有 @generated）与 Rust 的 target/ 目录不检查。

用法：python3 scripts/check_quality.py [目录 ...]，默认检查 macos/Sources、macos/Tests 与 windows/。
任一项不达标时退出码为 1。
"""

import re
import sys
from pathlib import Path

# 门禁阈值
MIN_COMMENT_RATIO = 0.20
MAX_FILE_LINES = 1000
MAX_FUNC_LINES = 500

# 识别 Swift 函数类声明的正则：允许前面带访问修饰符、属性包装等关键字
FUNC_DECL = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|private|fileprivate|internal|open|static|class|final|"
    r"override|mutating|nonisolated|convenience|required|async)\s+)*"
    r"(?:func\s+\S+|init[?!]?\s*[(<]|deinit\b)"
)

# Rust 的函数声明：可见性、const / async / unsafe / extern "C" 之后跟 fn。
# 字符串在判断前已换成 ""，所以 extern "C" 这里写成 extern ""。
RUST_FUNC_DECL = re.compile(
    r"^\s*(?:pub(?:\([^)]*\))?\s+)?"
    r"(?:(?:const|async|unsafe|default)\s+|extern\s+(?:\"\"\s+)?)*"
    r"fn\s+\w+"
)

# Slint 的函数声明：可带 public / pure 修饰。
SLINT_FUNC_DECL = re.compile(r"^\s*(?:(?:public|pure|protected)\s+)*function\s+[\w-]+")

# Rust 的字符字面量（'a'、'\n'、'\u{1F600}'、'"'），与生命周期 'a 区分开。
RUST_CHAR = re.compile(r"'(?:\\u\{[0-9a-fA-F]+\}|\\.|[^\\'])'")

# Rust 原始字符串的开头：r"、r#"、br##" 等。
RUST_RAW_START = re.compile(r"b?r(#*)\"")

# 每种语言：扩展名、函数声明的正则。
LANGUAGES = {
    "Swift": (".swift", FUNC_DECL),
    "Rust": (".rs", RUST_FUNC_DECL),
    "Slint": (".slint", SLINT_FUNC_DECL),
}


def classify_lines(text: str, language: str = "Swift"):
    """逐行分类，返回 (注释行数, 代码行数, 去掉注释与字符串后的行列表)。

    处理 // 行注释、/* */ 块注释（含跨行）和字符串字面量，
    避免把字符串里的 "//" 误判成注释。字符串一律按代码处理：
    - Swift：普通字符串只在一行内；多行字符串 \"\"\" 可以跨行。
    - Rust 与 Slint：普通字符串可以跨行，按 \\ 转义；Rust 另有原始字符串 r#"…"# 与字符字面量 '"'。
    """
    multiline_plain = language != "Swift"
    comment_lines = 0
    code_lines = 0
    stripped_lines = []
    in_block = False
    # 跨行的字符串：(结束标记, 是否处理转义)；不在字符串里时为 None。
    in_string = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line and not in_block and in_string is None:
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
            if in_string is not None:
                has_code = True
                end, escapes = in_string
                if escapes and ch == "\\":
                    i += 2
                elif raw.startswith(end, i):
                    in_string = None
                    i += len(end)
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
            if language == "Swift" and raw.startswith('"""', i):
                in_string = ('"""', False)
                has_code = True
                i += 3
                continue
            if language == "Rust" and (i == 0 or not (raw[i - 1].isalnum() or raw[i - 1] == "_")):
                raw_start = RUST_RAW_START.match(raw, i)
                if raw_start:
                    in_string = ('"' + raw_start.group(1), False)
                    has_code = True
                    i = raw_start.end()
                    out.append('""')
                    continue
            if language == "Rust" and ch == "'":
                char_literal = RUST_CHAR.match(raw, i)
                if char_literal:
                    has_code = True
                    i = char_literal.end()
                    out.append("''")
                    continue
            if ch == '"':
                has_code = True
                out.append('""')
                if multiline_plain:
                    in_string = ('"', True)
                    i += 1
                    continue
                # Swift：跳过一行内的普通字符串字面量，处理转义
                i += 1
                while i < n and raw[i] != '"':
                    i += 2 if raw[i] == "\\" else 1
                i += 1
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


def long_functions(stripped_lines, decl_pattern=FUNC_DECL, semicolon_ends_decl=False):
    """用花括号配对找出超过上限的函数，返回 [(起始行号, 行数, 声明)]。

    semicolon_ends_decl 为真时（Rust），声明之后、左花括号之前遇到同一层的分号，
    说明是没有函数体的声明（trait 里的 fn a();），不再等它的花括号。
    """
    results = []
    depth = 0
    # 栈元素：(声明所在行号, 声明开始时的花括号深度, 声明文本)
    pending = None
    stack = []
    for idx, line in enumerate(stripped_lines, start=1):
        if decl_pattern.match(line):
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
            elif ch == ";" and semicolon_ends_decl and pending is not None and pending[1] == depth:
                pending = None
    return results


def is_generated(text: str) -> bool:
    """前 5 行里有 @generated 标记的文件是生成的（文案、词表），不检查。"""
    return any("@generated" in line for line in text.splitlines()[:5])


def source_files(roots, suffix):
    """列出各目录下某种扩展名的源文件，跳过 Rust 的 target/ 目录。"""
    found = set()
    for root in roots:
        if root.is_file() and root.suffix == suffix:
            found.add(root)
        elif root.is_dir():
            found.update(p for p in root.rglob(f"*{suffix}") if "target" not in p.relative_to(root).parts)
    return sorted(found)


def check_language(language, files, failures):
    """检查一种语言的全部文件，打印每个文件的注释率；不达标的项加进 failures。返回检查的文件数。"""
    suffix, decl_pattern = LANGUAGES[language]
    total_comment = 0
    total_code = 0
    checked = 0
    for path in files:
        text = path.read_text(encoding="utf-8")
        if is_generated(text):
            print(f"  生成的  {path}")
            continue
        checked += 1
        line_count = len(text.splitlines())
        c, k, stripped = classify_lines(text, language)
        total_comment += c
        total_code += k
        if line_count > MAX_FILE_LINES:
            failures.append(f"文件超过 {MAX_FILE_LINES} 行：{path}（{line_count} 行）")
        for start, length, decl in long_functions(stripped, decl_pattern, semicolon_ends_decl=language == "Rust"):
            failures.append(f"函数超过 {MAX_FUNC_LINES} 行：{path}:{start}（{length} 行）{decl}")
        ratio = c / (c + k) if c + k else 0.0
        print(f"{ratio:6.1%}  {line_count:5d} 行  {path}")
    if not checked:
        return 0
    overall = total_comment / (total_comment + total_code) if total_comment + total_code else 0.0
    print(f"\n{language}：文件数 {checked}，注释行 {total_comment}，代码行 {total_code}，总注释率 {overall:.1%}\n")
    if overall <= MIN_COMMENT_RATIO:
        failures.append(f"{language} 总注释率 {overall:.1%} 未超过 {MIN_COMMENT_RATIO:.0%}")
    return checked


def main(argv):
    repo = Path(__file__).resolve().parent.parent
    default_roots = [repo / "macos" / "Sources", repo / "macos" / "Tests", repo / "windows"]
    roots = [Path(a) for a in argv[1:]] or default_roots
    failures = []
    checked = 0
    for language, (suffix, _) in LANGUAGES.items():
        checked += check_language(language, source_files(roots, suffix), failures)
    if not checked:
        print("未找到 Swift、Rust 或 Slint 源文件")
        return 1
    if failures:
        print("不达标：")
        for f in failures:
            print(f"- {f}")
        return 1
    print("质量门禁通过")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
