// SPDX-License-Identifier: GPL-3.0-or-later
//
// 发布说明的行内 Markdown 解析与转义：把单块文字（标题、段落、列表项）转换成 Slint 的 `StyledText`。
//
// 为什么不把原始发布说明直接交给 `StyledText::from_markdown`：
// 1. Slint 的 `StyledText` 只支持 CommonMark 的子集，遇到原生 HTML 标签（如 `<details>`、`<b>`）、
//    图片 `![alt](url)`、块级前缀（`# `、`> `、`- `、`1. `、`---`、4 空格缩进）时会直接返回错误，
//    回退成纯文本后会丢掉整块的粗体与代码样式。
// 2. 链接只允许 `https://`（与 macOS 的 `ReleaseNotesView.swift` 一致），其他协议要去掉链接属性只留文字，
//    同时规范化协议头为小写 `https://`，确保下游 `shell::open_url` 校验口径一致。
// 3. 中日韩文字常写「**标题：**正文」（全角标点紧接 `**` 且后面无空格），法文常写「**Titre :**texte」，
//    严格 CommonMark 的侧翼规则不会闭合这种标记；这里把外侧会破坏闭合的标点与暴露出的空白挪到标记外，
//    既不增减任何文字，又保证粗体生效。
// 4. 链接或行内代码被包在 `**...**` 内且外侧紧贴中文文字时（如 `**[说明](https://...)**` 或
//    ``开启**`Lock Layout`**功能``），外侧的 `[` 或反引号会被 CommonMark 当作标点破坏侧翼规则；
//    单个链接把样式下沉进链接文字内部（`[**说明**](url)`），首尾非文本节点挪至外侧避免残留字面星号。
//
// 支持的行内语法（按解析优先级排列）：
// - 反斜杠转义：`\*`、`\_`、`` \` ``、`\[`、`\]`、`\\` 等任意 ASCII 标点，原样进入文本节点。
// - 行内代码：单反引号或多反引号配对（`` `code` ``、```` ``a ` b`` ````），内部不解析任何其他语法。
// - 图片：`![alt](url)`，不加载远程图片，递归解析替代文字作为普通内容输出。
// - 链接：`[label](url)`，支持嵌套括号与文字内粗体/斜体/代码；仅保留合法 `https://` 地址。
// - 粗斜体：`***...***`、`___...___`（先于双定界符匹配）。
// - 粗体：`**...**`、`__...__`；删除线：`~~...~~`；斜体：`*...*`、`_..._`。
// - 下划线定界符（`_`、`__`、`___`）要求外侧不是字母或数字，防止 `foo_bar_baz` 被误拆成斜体。
//
// 输出阶段的不变量：
// - 所有 `Inline::Text` 节点里的 ASCII 标点全部加反斜杠转义，换行与制表符压成空格；
//   因此输出字符串绝不会意外触发 HTML 标签、块级标题、引用、列表、分隔线或缩进代码块。
// - 任何侧翼重排只调整定界符相对位置，纯文本内容（`get_raw_text`）与语义结果逐字符一致。
// - 最终仍通过 `StyledText::from_markdown` 解析，若发生未预见的错误则安全退回 `from_plain_text`。

//! 发布说明的行内 Markdown 渲染。

use slint::StyledText;

/// 行内 Markdown 节点。
#[derive(Debug, Clone, PartialEq, Eq)]
enum Inline {
    /// 普通文字（尚未做 Markdown 转义）。
    Text(String),
    /// 粗体（`**...**` 或 `__...__`）。
    Strong(Vec<Inline>),
    /// 斜体（`*...*` 或 `_..._`）。
    Emphasis(Vec<Inline>),
    /// 删除线（`~~...~~`）。
    Strike(Vec<Inline>),
    /// 行内代码（`` `...` ``）。
    Code(String),
    /// 仅限 `https://` 的可点击链接。
    Link {
        /// 链接文字，内部允许粗体、斜体或行内代码。
        label: Vec<Inline>,
        /// 已核对过的 `https://` 地址。
        url: String,
    },
}

/// 把一块发布说明的行内 Markdown 转成 `StyledText`。
/// `bold_all` 为真时整块按粗体渲染（供标题使用，因 Slint 的 `StyledText` 没有默认字重属性）。
/// 若解析仍意外失败，退回纯文本保证内容不丢失。
pub fn render_inline(text: &str, bold_all: bool) -> StyledText {
    let markdown = to_slint_markdown(text, bold_all);
    StyledText::from_markdown(&markdown).unwrap_or_else(|_| StyledText::from_plain_text(text))
}

/// 把行内 Markdown 清洗并序列化成 `StyledText::from_markdown` 可安全解析的 Markdown。
/// 整段先解析为行内节点树，再按 `StyledText` 支持的子集重新输出，避免原文里的 HTML 或块前缀触发报错。
pub(crate) fn to_slint_markdown(text: &str, bold_all: bool) -> String {
    // 去掉行首空白：防止 4 个以上前导空格触发 CommonMark 缩进代码块错误。
    let mut nodes = parse_inlines(text.trim_start(), false);
    if bold_all && has_visible_text(&nodes) {
        // 标题整体加粗，去掉内部重复的 Strong 避免生成嵌套 `****`。
        nodes = vec![Inline::Strong(strip_strong(nodes))];
    }
    let mut out = String::new();
    let mut prev_char: Option<char> = None;
    emit_nodes(&nodes, None, &mut prev_char, &mut out);
    out
}

/// 核对并规范化链接地址：只允许 `https://`（不区分大小写，规范化为小写协议头），
/// 要求主机名非空且不含空白、控制字符或尖括号，防止异常地址或非安全协议被交给系统打开。
pub fn normalize_safe_https_url(url: &str) -> Option<String> {
    let trimmed = url.trim();
    // 按字节切片比较 ASCII 协议头，避免非 ASCII 链接在第 8 字节落入多字节 UTF-8 字符内部引发 panic。
    let prefix = trimmed.as_bytes().get(..8)?;
    if !prefix.eq_ignore_ascii_case(b"https://") {
        return None;
    }
    let rest = &trimmed[8..];
    // 主机名不能为空，也不能以 `/` 开头（如 `https:///`）。
    if rest.is_empty() || rest.starts_with('/') {
        return None;
    }
    if trimmed
        .chars()
        .any(|c| c.is_whitespace() || c.is_control() || matches!(c, '<' | '>'))
    {
        return None;
    }
    Some(format!("https://{rest}"))
}

/// 核对链接地址是否为安全的 `https://` 地址。
/// 只返回布尔结果，需要规范化后的小写协议头地址时应使用 `normalize_safe_https_url`。
pub fn is_safe_https_url(url: &str) -> bool {
    normalize_safe_https_url(url).is_some()
}

/// 解析一段行内 Markdown。`in_link` 为真时不再解析嵌套链接，避免生成嵌套 `[...](...)`。
/// 按优先级依次尝试：反斜杠转义、行内代码、图片、链接、粗斜体、粗体、删除线、斜体；
/// 均未命中时按普通字符累积，并在遇到下一个结构节点或输入结束时经 `flush_text` 收拢。
fn parse_inlines(input: &str, in_link: bool) -> Vec<Inline> {
    let bytes = input.as_bytes();
    let mut nodes = Vec::new();
    let mut text = String::new();
    let mut i = 0;

    while i < bytes.len() {
        let b = bytes[i];
        // 反斜杠转义：CommonMark 允许转义任意 ASCII 标点，原样落入普通文字，后续输出时再统一转义。
        if b == b'\\'
            && let Some(&next) = bytes.get(i + 1)
            && next.is_ascii_punctuation()
        {
            text.push(next as char);
            i += 2;
            continue;
        }
        // 行内代码：与开头的反引号个数完全相同才闭合，内部不解析其他语法。
        if b == b'`'
            && let Some((code, next)) = parse_code_span(input, i)
        {
            flush_text(&mut text, &mut nodes);
            nodes.push(Inline::Code(code));
            i = next;
            continue;
        }
        // 图片 `![alt](url)`：不加载图片，只保留替代文字（与 macOS 一致，避免发起远程请求或报图片不支持）。
        if b == b'!'
            && bytes.get(i + 1) == Some(&b'[')
            && let Some((alt, _, next)) = parse_link_like(input, i + 1)
        {
            flush_text(&mut text, &mut nodes);
            nodes.extend(parse_inlines(&alt, in_link));
            i = next;
            continue;
        }
        // 链接 `[label](url)`：只保留 `https://` 链接并规范化协议头为小写，其他协议退回普通文字。
        if !in_link
            && b == b'['
            && let Some((label, url, next)) = parse_link_like(input, i)
        {
            flush_text(&mut text, &mut nodes);
            let parsed_label = parse_inlines(&label, true);
            if let Some(normalized) = normalize_safe_https_url(&url) {
                nodes.push(Inline::Link {
                    label: parsed_label,
                    url: normalized,
                });
            } else {
                nodes.extend(parsed_label);
            }
            i = next;
            continue;
        }
        // 粗斜体 `***...***` 或 `___...___`：先于双定界符匹配，确保同时开闭的三星号组合完整解析。
        if (b == b'*' || b == b'_')
            && bytes.get(i + 1) == Some(&b)
            && bytes.get(i + 2) == Some(&b)
            && let Some((inner, next)) = parse_delimited(input, i, b, 3)
        {
            flush_text(&mut text, &mut nodes);
            let inner_nodes = parse_inlines(&inner, in_link);
            nodes.push(Inline::Strong(vec![Inline::Emphasis(inner_nodes)]));
            i = next;
            continue;
        }
        // 粗体 `**...**` 或 `__...__`（先于单个 `*` / `_` 匹配，避免把 `**` 拆成两个空斜体）。
        if (b == b'*' || b == b'_')
            && bytes.get(i + 1) == Some(&b)
            && let Some((inner, next)) = parse_delimited(input, i, b, 2)
        {
            flush_text(&mut text, &mut nodes);
            nodes.push(Inline::Strong(parse_inlines(&inner, in_link)));
            i = next;
            continue;
        }
        // 删除线 `~~...~~`。
        if b == b'~'
            && bytes.get(i + 1) == Some(&b'~')
            && let Some((inner, next)) = parse_delimited(input, i, b'~', 2)
        {
            flush_text(&mut text, &mut nodes);
            nodes.push(Inline::Strike(parse_inlines(&inner, in_link)));
            i = next;
            continue;
        }
        // 斜体 `*...*` 或 `_..._`。
        if (b == b'*' || b == b'_')
            && let Some((inner, next)) = parse_delimited(input, i, b, 1)
        {
            flush_text(&mut text, &mut nodes);
            nodes.push(Inline::Emphasis(parse_inlines(&inner, in_link)));
            i = next;
            continue;
        }
        // 普通字符：按完整 UTF-8 字符前进，保持 `i` 始终位于字符边界。
        let ch = input[i..].chars().next().expect("i 落在字符边界上");
        text.push(ch);
        i += ch.len_utf8();
    }

    flush_text(&mut text, &mut nodes);
    nodes
}

/// 把累积的普通文字收进节点列表；空串不产生冗余节点。
fn flush_text(text: &mut String, nodes: &mut Vec<Inline>) {
    if !text.is_empty() {
        nodes.push(Inline::Text(std::mem::take(text)));
    }
}

/// 解析行内代码：匹配与起始位置相同长度的反引号串，返回内容与结束后的字节位置。
/// 找不到同长度闭合反引号时返回 `None`，外层将起始反引号当作普通字符处理。
///
/// 遵循 CommonMark 规则：
/// - 起始连续 `N` 个反引号只能被同样连续 `N` 个反引号闭合（更长或更短的反引号串整体跳过）。
/// - 内容非全空格且首尾各有一个空格时，首尾各剥离一个空格（用来包裹以反引号起止的代码）。
fn parse_code_span(input: &str, start: usize) -> Option<(String, usize)> {
    let bytes = input.as_bytes();
    let ticks = bytes[start..].iter().take_while(|&&b| b == b'`').count();
    let content_start = start + ticks;
    let mut i = content_start;
    while i < bytes.len() {
        if bytes[i] == b'`' {
            let run = bytes[i..].iter().take_while(|&&b| b == b'`').count();
            if run == ticks {
                let mut content = &input[content_start..i];
                // CommonMark 规则：首尾各有一个空格且不全为空格时，各去掉一个。
                if content.len() >= 2
                    && content.starts_with(' ')
                    && content.ends_with(' ')
                    && content.bytes().any(|b| b != b' ')
                {
                    content = &content[1..content.len() - 1];
                }
                return Some((content.to_owned(), i + run));
            }
            // 长度不等的反引号串直接整段跳过，不能拆成更短的闭合标记。
            i += run;
        } else {
            i += 1;
        }
    }
    None
}

/// 解析 `[label](url)`，从 `[` 所在下标起；方括号与圆括号均跟踪嵌套层级。
/// 这样链接文字里的 `[tag]` 或维基百科地址里的 `(disambiguation)` 不会提前截断链接。
///
/// 返回 `(label, url, next_index)`：
/// - `label` 尚未递归解析，交由调用方决定是否允许嵌套链接或只留纯文本。
/// - `url` 保持原样，交由 `normalize_safe_https_url` 统一做协议与字符安全校验。
/// - `next_index` 指向闭合 `)` 之后的字节偏移。
fn parse_link_like(input: &str, bracket_start: usize) -> Option<(String, String, usize)> {
    let bytes = input.as_bytes();
    let mut i = bracket_start + 1;
    let mut bracket_depth = 1usize;
    while i < bytes.len() {
        match bytes[i] {
            // 跳过被转义的括号，避免 `\]` 提前结束链接文字。
            b'\\' if i + 1 < bytes.len() => i += 2,
            b'[' => {
                bracket_depth += 1;
                i += 1;
            }
            b']' => {
                bracket_depth -= 1;
                if bracket_depth == 0 {
                    break;
                }
                i += 1;
            }
            _ => i += 1,
        }
    }
    // `]` 后必须紧跟 `(`，中间不允许插空格。
    if bracket_depth != 0 || bytes.get(i + 1) != Some(&b'(') {
        return None;
    }
    let label = &input[bracket_start + 1..i];
    let url_start = i + 2;
    let mut j = url_start;
    let mut paren_depth = 1usize;
    while j < bytes.len() {
        match bytes[j] {
            // 跳过地址中的转义字符。
            b'\\' if j + 1 < bytes.len() => j += 2,
            b'(' => {
                paren_depth += 1;
                j += 1;
            }
            b')' => {
                paren_depth -= 1;
                if paren_depth == 0 {
                    let url = &input[url_start..j];
                    return Some((label.to_owned(), url.to_owned(), j + 1));
                }
                j += 1;
            }
            _ => j += 1,
        }
    }
    None
}

/// 解析成对定界符（`***`、`___`、`**`、`__`、`~~`、`*`、`_`）。
/// `_` / `__` / `___` 要求外侧不是字母或数字，防止 `foo_bar_baz` 被误拆成斜体。
/// `*` / `**` / `***` 不限制外侧字符，确保中文、日文、韩文紧贴粗体标记也能正常识别。
///
/// 扫描闭合标记时跳过反斜杠转义和行内代码片段，避免 `\*` 或 `` `a*b` `` 提前截断外层样式；
/// 当单定界符遇到连续 3 个以上同字符（如 `*斜体 **粗斜体***`）时，用末尾那个闭合外层，
/// 把前面的双定界符留给内层递归解析。
fn parse_delimited(input: &str, start: usize, delim: u8, count: usize) -> Option<(String, usize)> {
    let bytes = input.as_bytes();
    let prev = input[..start].chars().next_back();
    if delim == b'_' && prev.is_some_and(char::is_alphanumeric) {
        return None;
    }
    let content_start = start + count;
    // 开定界符后面紧跟空白或同字符时不算合法的起始标记。
    let first = input[content_start..].chars().next()?;
    if first.is_whitespace() || (count == 1 && first == delim as char) {
        return None;
    }
    let mut i = content_start;
    while i < bytes.len() {
        let b = bytes[i];
        // 跳过反斜杠转义，避免 `\*` 提前闭合外层粗体或斜体。
        if b == b'\\' && i + 1 < bytes.len() {
            i += 2;
            continue;
        }
        // 跳过行内代码，避免代码里的 `*` 或 `_` 提前闭合外层样式。
        if b == b'`'
            && let Some((_, next)) = parse_code_span(input, i)
        {
            i = next;
            continue;
        }
        if b == delim {
            let run = bytes[i..].iter().take_while(|&&c| c == delim).count();
            // 混合嵌套遇到 `***`（如 `*斜体 **粗斜体***` 或 `**粗体 *粗斜体***`）时，
            // 取末尾 `count` 个定界符闭合外层，把前面剩余的定界符留给内层递归解析，避免残留孤立星号。
            let (close_at, after_pos, exact_match) = if (count == 1 || count == 2) && run >= 3 {
                (i + run - count, i + run, true)
            } else if count == 1 {
                (i, i + 1, run == 1)
            } else {
                (i, i + count, run >= count)
            };
            // 闭合标记不能紧跟在空白后；`_` 闭合后不能紧跟字母或数字。
            let before = input[..close_at].chars().next_back();
            let after = input.get(after_pos..).and_then(|s| s.chars().next());
            let valid_underscore = delim != b'_' || !after.is_some_and(char::is_alphanumeric);
            if exact_match
                && close_at > content_start
                && !before.is_some_and(char::is_whitespace)
                && valid_underscore
            {
                return Some((input[content_start..close_at].to_owned(), after_pos));
            }
            i += run;
            continue;
        }
        i += 1;
    }
    None
}

/// 节点树里是否含有非空文字。
/// 用于决定标题是否需要加粗包装，以及剥离空白和标点后的样式节点是否还有内容可输出。
fn has_visible_text(nodes: &[Inline]) -> bool {
    nodes.iter().any(|node| match node {
        Inline::Text(s) | Inline::Code(s) => !s.is_empty(),
        Inline::Strong(c) | Inline::Emphasis(c) | Inline::Strike(c) => has_visible_text(c),
        Inline::Link { label, .. } => has_visible_text(label),
    })
}

/// 去掉节点树里的 `Strong` 包装，保留内层其他样式（用于整体加粗的标题）。
/// 避免把标题原文里的 `**...**` 再包进外层 `**...**` 产生连续四个星号。
fn strip_strong(nodes: Vec<Inline>) -> Vec<Inline> {
    let mut out = Vec::with_capacity(nodes.len());
    for node in nodes {
        match node {
            Inline::Strong(children) => out.extend(strip_strong(children)),
            Inline::Emphasis(children) => out.push(Inline::Emphasis(strip_strong(children))),
            Inline::Strike(children) => out.push(Inline::Strike(strip_strong(children))),
            Inline::Link { label, url } => out.push(Inline::Link {
                label: strip_strong(label),
                url,
            }),
            other => out.push(other),
        }
    }
    out
}

/// 取节点列表展平后的第一个可见字符，用于判断是否会触发 CommonMark 侧翼规则冲突。
/// 递归深入样式与链接子节点，忽略空文本节点。
fn first_char(nodes: &[Inline]) -> Option<char> {
    for node in nodes {
        let found = match node {
            Inline::Text(s) | Inline::Code(s) => s.chars().next(),
            Inline::Strong(c) | Inline::Emphasis(c) | Inline::Strike(c) => first_char(c),
            Inline::Link { label, .. } => first_char(label),
        };
        if found.is_some() {
            return found;
        }
    }
    None
}

/// 取节点列表展平后的最后一个可见字符，供闭合定界符检查右翼标点。
fn last_char(nodes: &[Inline]) -> Option<char> {
    for node in nodes.iter().rev() {
        let found = match node {
            Inline::Text(s) | Inline::Code(s) => s.chars().next_back(),
            Inline::Strong(c) | Inline::Emphasis(c) | Inline::Strike(c) => last_char(c),
            Inline::Link { label, .. } => last_char(label),
        };
        if found.is_some() {
            return found;
        }
    }
    None
}

/// 是否为标点字符（CommonMark 侧翼规则把 ASCII 与 Unicode 标点都视为标点）。
/// 中日韩全角冒号、书名号、圆括号等非字母数字且非空白的字符均按标点处理。
fn is_cmark_punct(c: char) -> bool {
    c.is_ascii_punctuation() || (!c.is_alphanumeric() && !c.is_whitespace())
}

/// 把一串节点序列化为安全的 Slint Markdown。
/// 向每个子节点传入紧随其后的首个字符（`following` 兜底），供 `emit_wrapped` 判断右翼标点是否冲突。
fn emit_nodes(nodes: &[Inline], following: Option<char>, prev_char: &mut Option<char>, out: &mut String) {
    for (idx, node) in nodes.iter().enumerate() {
        let next_char = first_char(&nodes[idx + 1..]).or(following);
        emit_node(node, next_char, prev_char, out);
    }
}

/// 序列化单个节点，并同步更新 `prev_char` 供下一个兄弟节点检查左翼标点。
fn emit_node(node: &Inline, next_char: Option<char>, prev_char: &mut Option<char>, out: &mut String) {
    match node {
        Inline::Text(s) => {
            escape_text_into(s, out);
            if let Some(c) = s.chars().next_back() {
                *prev_char = Some(c);
            }
        }
        Inline::Code(code) => {
            emit_code_into(code, out);
            if let Some(c) = code.chars().next_back() {
                *prev_char = Some(c);
            }
        }
        Inline::Strong(children) => emit_styled(StyleWrap::Strong, children, next_char, prev_char, out),
        Inline::Emphasis(children) => emit_styled(StyleWrap::Emphasis, children, next_char, prev_char, out),
        Inline::Strike(children) => emit_styled(StyleWrap::Strike, children, next_char, prev_char, out),
        Inline::Link { label, url } => {
            out.push('[');
            let mut inner_prev = None;
            emit_nodes(label, None, &mut inner_prev, out);
            out.push_str("](");
            // 地址里的圆括号与反斜杠必须转义，防止提前闭合 `](...)`。
            for c in url.chars() {
                match c {
                    '(' | ')' | '\\' => {
                        out.push('\\');
                        out.push(c);
                    }
                    _ => out.push(c),
                }
            }
            out.push(')');
            if let Some(c) = last_char(label) {
                *prev_char = Some(c);
            }
        }
    }
}

/// 可包裹子节点的三种行内样式种类。
#[derive(Debug, Clone, Copy)]
enum StyleWrap {
    /// 粗体（`**`）。
    Strong,
    /// 斜体（`*`）。
    Emphasis,
    /// 删除线（`~~`）。
    Strike,
}

impl StyleWrap {
    /// 对应的 CommonMark 定界符。
    fn marker(self) -> &'static str {
        match self {
            Self::Strong => "**",
            Self::Emphasis => "*",
            Self::Strike => "~~",
        }
    }

    /// 把子节点重新包进同类节点（用于下沉样式到链接文字内部）。
    fn wrap(self, children: Vec<Inline>) -> Inline {
        match self {
            Self::Strong => Inline::Strong(children),
            Self::Emphasis => Inline::Emphasis(children),
            Self::Strike => Inline::Strike(children),
        }
    }
}

/// 节点按 Markdown 输出时，首字符是否为 ASCII 标点（如行内代码的反引号、链接的 `[`、内层样式的 `*`/`~`）。
/// CommonMark 侧翼规则看的是源码里紧贴定界符的字符，而非纯文本字符。
fn starts_with_markup_punct(nodes: &[Inline]) -> bool {
    match nodes.first() {
        Some(Inline::Text(_)) => first_char(nodes).is_some_and(is_cmark_punct),
        Some(_) => true,
        None => false,
    }
}

/// 节点按 Markdown 输出时，尾字符是否为 ASCII 标点（如反引号、`)`、`*`、`~`）。
fn ends_with_markup_punct(nodes: &[Inline]) -> bool {
    match nodes.last() {
        Some(Inline::Text(_)) => last_char(nodes).is_some_and(is_cmark_punct),
        Some(_) => true,
        None => false,
    }
}

/// 输出带定界符的样式节点（`**`、`*`、`~~`）。
/// 处理三类 CommonMark 侧翼冲突，保证 `pulldown_cmark` 一定识别成样式而不是字面星号：
/// 1. 仅包住单个链接（如 `**[说明](url)**`）时，把样式下沉到链接文字内部（`[**说明**](url)`），
///    由 `[` 与 `]` 天然充当外侧标点，不与中文文字冲突。
/// 2. 外侧紧贴非空白非标点字符且内侧起止为标点（含法文 `**Titre :**texte` 的冒号前空格）时，
///    按「外空白 → 标点 → 暴露出的内空白」剥离到定界符外，既满足侧翼规则又逐字符保留原文。
/// 3. 首尾是非文本节点（如 ``开启**`Lock Layout`**功能``）且外侧为文字时，先单独输出该首尾非文本节点，
///    避免 `**` 紧挨反引号与文字而退化成字面星号。
fn emit_styled(
    kind: StyleWrap,
    children: &[Inline],
    next_char: Option<char>,
    prev_char: &mut Option<char>,
    out: &mut String,
) {
    // 单个链接直接把样式下沉进 label，避开 `**[...](...)**` 紧贴文字时的侧翼冲突。
    if let [Inline::Link { label, url }] = children {
        let pushed = Inline::Link {
            label: vec![kind.wrap(label.clone())],
            url: url.clone(),
        };
        emit_node(&pushed, next_char, prev_char, out);
        return;
    }

    let mut cloned = children.to_vec();
    let marker = kind.marker();
    // 定界符内侧紧挨空白时 CommonMark 不识别为样式，先把两端空白挪到外侧。
    let leading_ws = take_leading_while(&mut cloned, char::is_whitespace);
    let trailing_ws = take_trailing_while(&mut cloned, char::is_whitespace);

    // 若前一个字符是文字/数字，且当前段开头输出为标点（或源码标点），依次剥离前导非文本或前导标点。
    let prev_is_word = prev_char.is_some_and(|c| !c.is_whitespace() && !is_cmark_punct(c));
    let mut leading_nodes = Vec::new();
    let mut leading_punct = String::new();
    let mut leading_inner_ws = String::new();
    if prev_is_word && leading_ws.is_empty() && starts_with_markup_punct(&cloned) {
        if matches!(cloned.first(), Some(Inline::Text(_))) {
            leading_punct = take_leading_while(&mut cloned, is_cmark_punct);
            // 剥掉标点后（例如 `前文**✨ 新功能**`），若紧接着露出空白也要一并挪到定界符外。
            leading_inner_ws = take_leading_while(&mut cloned, char::is_whitespace);
        } else if !cloned.is_empty() {
            // 首节点是 Code/Link/嵌套样式等以源码标点开头的节点：挪到外侧单独输出。
            leading_nodes.push(cloned.remove(0));
            leading_inner_ws = take_leading_while(&mut cloned, char::is_whitespace);
        }
    }

    // 若后一个字符是文字/数字，且当前段末尾输出为标点（或源码标点），对称处理尾部。
    let next_is_word = next_char.is_some_and(|c| !c.is_whitespace() && !is_cmark_punct(c));
    let mut trailing_nodes = Vec::new();
    let mut trailing_punct = String::new();
    let mut trailing_inner_ws = String::new();
    if next_is_word && trailing_ws.is_empty() && ends_with_markup_punct(&cloned) {
        if matches!(cloned.last(), Some(Inline::Text(_))) {
            trailing_punct = take_trailing_while(&mut cloned, is_cmark_punct);
            // 法文 `**Titre :**texte` 剥掉 `:` 后会露出空格，把该空格挪到闭合定界符外。
            trailing_inner_ws = take_trailing_while(&mut cloned, char::is_whitespace);
        } else if !cloned.is_empty() {
            trailing_nodes.push(cloned.pop().expect("非空"));
            trailing_inner_ws = take_trailing_while(&mut cloned, char::is_whitespace);
        }
    }

    // 严格按原有字符顺序输出各段，保证纯文本一字不差。
    if !leading_ws.is_empty() {
        escape_text_into(&leading_ws, out);
        *prev_char = leading_ws.chars().next_back();
    }
    if !leading_nodes.is_empty() {
        let following = first_char(&cloned).or(next_char);
        emit_nodes(&leading_nodes, following, prev_char, out);
    }
    if !leading_punct.is_empty() {
        escape_text_into(&leading_punct, out);
        *prev_char = leading_punct.chars().next_back();
    }
    if !leading_inner_ws.is_empty() {
        escape_text_into(&leading_inner_ws, out);
        *prev_char = leading_inner_ws.chars().next_back();
    }
    // 剥离后若仍有可见内容，才输出成对定界符，避免产生空标记。
    if has_visible_text(&cloned) {
        out.push_str(marker);
        let mut inner_prev = None;
        emit_nodes(&cloned, None, &mut inner_prev, out);
        out.push_str(marker);
        if let Some(c) = last_char(&cloned) {
            *prev_char = Some(c);
        }
    }
    if !trailing_inner_ws.is_empty() {
        escape_text_into(&trailing_inner_ws, out);
        *prev_char = trailing_inner_ws.chars().next_back();
    }
    if !trailing_punct.is_empty() {
        escape_text_into(&trailing_punct, out);
        *prev_char = trailing_punct.chars().next_back();
    }
    if !trailing_nodes.is_empty() {
        emit_nodes(&trailing_nodes, next_char, prev_char, out);
    }
    if !trailing_ws.is_empty() {
        escape_text_into(&trailing_ws, out);
        *prev_char = trailing_ws.chars().next_back();
    }
}

/// 拆出首部文本节点开头满足条件的字符前缀。
/// 只从连续的 `Inline::Text` 首节点摘取，不越过代码、链接或内层样式节点。
/// 整段文本都被拆空时顺手移除该节点，避免留下空的 `Inline::Text`。
/// 典型调用场景：
/// - 在输出样式定界符前，先把内侧前导空白挪到定界符外；
/// - 外侧紧贴文字而内侧以标点开头时，把标点及其后暴露出的空白按原顺序挪到外侧。
fn take_leading_while(nodes: &mut Vec<Inline>, predicate: impl Fn(char) -> bool) -> String {
    let mut taken = String::new();
    while let Some(Inline::Text(first)) = nodes.first_mut() {
        // 找到第一个不满足条件的字符边界，避免把多字节 UTF-8 字符从中间切开。
        let split = first
            .char_indices()
            .find(|&(_, c)| !predicate(c))
            .map_or(first.len(), |(idx, _)| idx);
        if split == 0 {
            break;
        }
        taken.push_str(&first[..split]);
        first.drain(..split);
        if first.is_empty() {
            // 整段文本已被掏空，继续看下一个兄弟节点是否还是纯文本。
            nodes.remove(0);
        } else {
            break;
        }
    }
    taken
}

/// 拆出尾部文本节点末尾满足条件的字符后缀。
/// 倒序收集各段后缀后再反转拼接，保持原有字符顺序；空节点一并弹出。
/// 典型调用场景：
/// - 剥离定界符内侧末尾空白（如 `**粗体 **`）；
/// - 剥离法文或中日韩标点紧接闭合星号时的尾随标点与内侧空格（如 `**Titre :**texte`）。
fn take_trailing_while(nodes: &mut Vec<Inline>, predicate: impl Fn(char) -> bool) -> String {
    let mut chunks = Vec::new();
    while let Some(Inline::Text(last)) = nodes.last_mut() {
        // 从后往前定位最后一个不满足条件的字符，切分点落在其 UTF-8 结束偏移上。
        let keep = last
            .char_indices()
            .rev()
            .find(|&(_, c)| !predicate(c))
            .map_or(0, |(idx, c)| idx + c.len_utf8());
        if keep == last.len() {
            break;
        }
        chunks.push(last[keep..].to_owned());
        last.truncate(keep);
        if last.is_empty() {
            // 尾节点被掏空后弹出，继续向前检查相邻的纯文本节点。
            nodes.pop();
        } else {
            break;
        }
    }
    chunks.reverse();
    chunks.concat()
}

/// 把纯文本按 CommonMark 转义写入 `out`：ASCII 标点加反斜杠，换行与制表符换成空格。
/// 转义后的纯文本绝不会触发 HTML 标签、块级标题、列表、引用或意外样式。
/// 非 ASCII 字符（中日韩文字、俄文、全角标点）在 CommonMark 中不具语法含义，直接原样输出。
fn escape_text_into(text: &str, out: &mut String) {
    for c in text.chars() {
        match c {
            // 单块内不保留控制空白，全部压成普通空格避免触发硬换行或缩进代码块。
            '\n' | '\r' | '\t' => out.push(' '),
            c if c.is_ascii_punctuation() => {
                out.push('\\');
                out.push(c);
            }
            c => out.push(c),
        }
    }
}

/// 把行内代码写成安全反引号包裹形式，内部含反引号时自动增加外层反引号个数。
/// 首尾出现反引号或空格时两侧各补一个空格，由 CommonMark 规则对称剥离，保持代码内容原样不变。
/// 换行与制表符统一替换为空格，确保行内代码只落在同一段落内。
fn emit_code_into(code: &str, out: &mut String) {
    let cleaned = code.replace(['\n', '\r', '\t'], " ");
    // 统计内部最长的连续反引号长度，外层定界符至少多 1 个反引号。
    let mut max_run = 0usize;
    let mut current = 0usize;
    for b in cleaned.bytes() {
        if b == b'`' {
            current += 1;
            max_run = max_run.max(current);
        } else {
            current = 0;
        }
    }
    let fence = "`".repeat(max_run + 1);
    let pad = cleaned.starts_with('`')
        || cleaned.ends_with('`')
        || cleaned.starts_with(' ')
        || cleaned.ends_with(' ');
    out.push_str(&fence);
    if pad {
        out.push(' ');
    }
    out.push_str(&cleaned);
    if pad {
        out.push(' ');
    }
    out.push_str(&fence);
}

#[cfg(test)]
mod tests {
    use super::*;
    use eveo_core::model::AppLanguage;
    use eveo_core::support::StringEnum;
    use eveo_core::update::notes::{self, ReleaseNotesBlock};
    use i_slint_core::styled_text::get_raw_text;

    /// 常见行内语法：粗体、斜体、删除线、行内代码、安全链接均正确解析，纯文本不残留标记字符。
    #[test]
    fn renders_common_inline_markdown() {
        let input = "**锁定布局视觉特效动画：** 开启 `Lock Layout` 与 *斜体*、~~旧行为~~，见 [说明](https://example.com/docs)。";
        let md = to_slint_markdown(input, false);
        let styled = StyledText::from_markdown(&md).expect("合法的 Slint Markdown");
        assert_eq!(
            get_raw_text(&styled),
            "锁定布局视觉特效动画： 开启 Lock Layout 与 斜体、旧行为，见 说明。"
        );
        // 通过 Debug 输出确认五种行内样式均已进入 StyledText 的格式区间。
        let debug = format!("{styled:?}");
        assert!(debug.contains("Strong"), "{debug}");
        assert!(debug.contains("Code"), "{debug}");
        assert!(debug.contains("Emphasis"), "{debug}");
        assert!(debug.contains("Strikethrough"), "{debug}");
        assert!(debug.contains("Link"), "{debug}");
    }

    /// 中日韩全角标点、法文冒号前空格、表情符号与嵌套代码/链接紧贴 `**` 时，不留字面星号。
    #[test]
    fn handles_cjk_punctuation_flanking() {
        for sample in [
            "**锁定布局视觉特效动画：**开启特效",
            "前文**「锁定布局」**后文",
            "**布局：**（测试）",
            "**Titre :**texte",
            "前文**✨ 新功能**",
            "点击**[说明](https://example.com)**查看",
        ] {
            let md = to_slint_markdown(sample, false);
            let styled = StyledText::from_markdown(&md).expect("应能解析");
            let raw = get_raw_text(&styled);
            assert!(!raw.contains("**"), "不应残留原始星号：{raw} (md={md})");
            assert!(
                format!("{styled:?}").contains("Strong"),
                "应包含 Strong：{styled:?} (md={md})"
            );
        }
        // 中日韩文字紧贴行内代码包裹在粗体里时，不残留字面星号且保留代码样式。
        let code_in_strong = to_slint_markdown("开启**`Lock Layout`**功能", false);
        let styled = StyledText::from_markdown(&code_in_strong).expect("应能解析");
        assert_eq!(get_raw_text(&styled), "开启Lock Layout功能");
        assert!(format!("{styled:?}").contains("Code"));
    }

    /// 粗斜体 `***...***` 与混合嵌套 `*斜体 **粗斜体***` 均能正确闭合，不残留星号。
    #[test]
    fn parses_bold_italic_combinations() {
        let triple = StyledText::from_markdown(&to_slint_markdown("***粗斜体***", false)).expect("应能解析");
        assert_eq!(get_raw_text(&triple), "粗斜体");
        let debug = format!("{triple:?}");
        assert!(debug.contains("Strong") && debug.contains("Emphasis"), "{debug}");

        let nested =
            StyledText::from_markdown(&to_slint_markdown("*斜体 **粗斜体***", false)).expect("应能解析");
        assert_eq!(get_raw_text(&nested), "斜体 粗斜体");
        let debug = format!("{nested:?}");
        assert!(debug.contains("Strong") && debug.contains("Emphasis"), "{debug}");

        let nested_rev =
            StyledText::from_markdown(&to_slint_markdown("**粗体 *粗斜体***", false)).expect("应能解析");
        assert_eq!(get_raw_text(&nested_rev), "粗体 粗斜体");
        let debug = format!("{nested_rev:?}");
        assert!(debug.contains("Strong") && debug.contains("Emphasis"), "{debug}");
    }

    /// 非 ASCII 链接地址不触发 UTF-8 字节边界 panic；大写 `HTTPS://` 规范化为小写；空主机与尖括号被拒。
    #[test]
    fn validates_and_normalizes_https_urls_safely() {
        // 多字节中文恰好跨越第 8 字节时不应 panic，且非 https 被拒绝。
        assert_eq!(normalize_safe_https_url("http://中文"), None);
        assert_eq!(normalize_safe_https_url("中文链接地址"), None);
        assert_eq!(normalize_safe_https_url("https:///"), None);
        assert_eq!(normalize_safe_https_url("https://a<b>.com"), None);
        assert_eq!(
            normalize_safe_https_url("  HTTPS://Example.com/Path "),
            Some("https://Example.com/Path".to_owned())
        );
        // 含中文链接的整段 Markdown 解析不 panic，非 https 退回纯文字。
        let md = to_slint_markdown("见 [坏链](http://中文) 与 [好链](HTTPS://example.com)", false);
        let styled = StyledText::from_markdown(&md).expect("应能解析");
        assert_eq!(get_raw_text(&styled), "见 坏链 与 好链");
        assert!(format!("{styled:?}").contains("https://example.com"));
    }

    /// 下划线标识符不被误判成斜体；非 https 链接去掉链接只留文字；图片与原生 HTML 按纯文本显示不报错。
    #[test]
    fn sanitizes_unsafe_links_images_html_and_snake_case() {
        let input = "变量 foo_bar_baz，[点我](javascript:alert(1))，![图](https://a/b.png)，<b>粗</b> <details>x</details>";
        let md = to_slint_markdown(input, false);
        let styled = StyledText::from_markdown(&md).expect("不应因 HTML 或图片报错");
        assert_eq!(
            get_raw_text(&styled),
            "变量 foo_bar_baz，点我，图，<b>粗</b> <details>x</details>"
        );
        let debug = format!("{styled:?}");
        assert!(!debug.contains("Link"), "不应保留非 https 链接：{debug}");
        assert!(!debug.contains("Emphasis"), "下划线标识符不应变斜体：{debug}");
    }

    /// 块级前缀（`# `、`> `、`- `、`1. `、`---`、4 空格缩进）出现在正文里时不触发块语法报错或重复圆点。
    #[test]
    fn escapes_block_prefixes() {
        for sample in ["# tag", "> quote", "- item", "1. numbered", "---", "    indented"] {
            let md = to_slint_markdown(sample, false);
            let styled = StyledText::from_markdown(&md).expect("块级前缀应被转义");
            assert_eq!(get_raw_text(&styled).trim(), sample.trim());
        }
    }

    /// 仓库里真实的 1.5.2 八语发布说明全部解析通过，且粗体生效、不残留 `**`。
    /// 同时覆盖英文、简体中文、日语、韩语、俄语、法语、德语、西班牙语八个语言块。
    #[test]
    fn real_v152_release_notes_all_languages() {
        let body = include_str!("../../../../docs/release-notes/v1.5.2.md");
        for &lang in AppLanguage::ALL {
            // 按窗口实际显示链路依次执行：选语言块 → 过滤掉非 Windows 小节 → 按行切块。
            let section = notes::section(lang, body);
            let filtered = notes::platform_only(&section, "Windows");
            let blocks = notes::blocks(&filtered);
            assert!(!blocks.is_empty(), "{lang:?}");
            let mut saw_strong = false;
            for block in blocks {
                let (text, bold_all) = match block {
                    ReleaseNotesBlock::Heading { text, .. } => (text, true),
                    ReleaseNotesBlock::Paragraph(text)
                    | ReleaseNotesBlock::Bullet { text, .. }
                    | ReleaseNotesBlock::Numbered { text, .. } => (text, false),
                    ReleaseNotesBlock::Code(_) => continue,
                };
                // 每一块都必须直接通过 Slint Markdown 解析，不允许回退到纯文本。
                let md = to_slint_markdown(&text, bold_all);
                let styled = StyledText::from_markdown(&md)
                    .unwrap_or_else(|e| panic!("{lang:?} 解析失败：{e}\nmd={md}"));
                let raw = get_raw_text(&styled);
                // 解析后纯文本中绝不能残留未生效的 `**` 标记。
                assert!(!raw.contains("**"), "{lang:?} 残留星号：{raw}");
                if format!("{styled:?}").contains("Strong") {
                    saw_strong = true;
                }
            }
            // 每种语言的 1.5.2 说明都至少包含标题与条目小标题粗体。
            assert!(saw_strong, "{lang:?} 应包含粗体");
        }
    }
}
