// SPDX-License-Identifier: GPL-3.0-or-later
//
// 把读到的字节切成完整的文本行（反馈文档 7.4 节），与 macOS 的 LogLineFramer.swift 行为相同：
// - 编码在凑够开头 3 个字节后判断一次：FF FE 是 UTF-16 小端，FE FF 是 UTF-16 大端，EF BB BF 是带 BOM 的
//   UTF-8，其余是 UTF-8。BOM 不进入输出。游戏日志通常是不带 BOM 的 UTF-8，UTF-16 只作防御。
// - 从文件中间开始读时，调用方用文件头确定编码后以 `with_encoding` 建分行器，不对中间的字节做 BOM 判断。
// - 只在换行符（UTF-8 的 0A，UTF-16 按 2 字节码元对齐的 000A）处切行，所以多字节字符被两次读取切开时，
//   尾部自然留在缓冲里；行尾的回车去掉。
// - 一行超过上限时丢弃这一行直到下一个换行符，缓冲的大小因此有上限。
// - 解码失败的字节用 U+FFFD 代替，不报错。

//! 按换行符切行的分行器。

/// 日志文件的文本编码。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogTextEncoding {
    /// UTF-8（带不带 BOM 都是它）。
    Utf8,
    /// UTF-16 小端。
    Utf16LittleEndian,
    /// UTF-16 大端。
    Utf16BigEndian,
}

/// 一行的默认字节上限：64 KiB。
pub const DEFAULT_MAX_LINE_BYTES: usize = 65_536;

/// 按换行符切行的分行器。由调用方持有，每个文件一个。
#[derive(Debug, Clone)]
pub struct LogLineFramer {
    /// 当前编码；`None` 表示还没读到足够的字节来判断。
    encoding: Option<LogTextEncoding>,
    /// 建分行器时指定的编码，`reset` 后恢复成它。
    initial_encoding: Option<LogTextEncoding>,
    /// 一行的字节上限，超过的行被丢弃。
    max_line_bytes: usize,
    /// 还没凑成完整行的字节。
    buffer: Vec<u8>,
    /// 正在丢弃一条超长的行，直到下一个换行符。
    discarding: bool,
}

impl Default for LogLineFramer {
    fn default() -> Self {
        Self::new(None, DEFAULT_MAX_LINE_BYTES)
    }
}

impl LogLineFramer {
    /// 建分行器。`encoding` 为 `None` 时按开头的字节判断编码；有值时直接使用，不做 BOM 判断。
    pub fn new(encoding: Option<LogTextEncoding>, max_line_bytes: usize) -> Self {
        Self {
            encoding,
            initial_encoding: encoding,
            max_line_bytes: max_line_bytes.max(1),
            buffer: Vec::new(),
            discarding: false,
        }
    }

    /// 用已知的编码与默认上限建分行器（从文件中间读起时用）。
    pub fn with_encoding(encoding: LogTextEncoding) -> Self {
        Self::new(Some(encoding), DEFAULT_MAX_LINE_BYTES)
    }

    /// 当前编码；还没判断出来时为 `None`。
    pub fn encoding(&self) -> Option<LogTextEncoding> {
        self.encoding
    }

    /// 追加一段字节，返回这次凑齐的完整行（不含换行符）。不完整的尾部留到下次。
    pub fn append(&mut self, data: &[u8]) -> Vec<String> {
        self.buffer.extend_from_slice(data);
        if self.encoding.is_none() {
            // 不到 3 个字节时还分不清是不是 BOM，先攒着。
            if self.buffer.len() < 3 {
                return Vec::new();
            }
            self.detect_encoding();
        }
        match self.encoding {
            Some(LogTextEncoding::Utf8) => self.split_utf8(),
            Some(LogTextEncoding::Utf16LittleEndian) => self.split_utf16(false),
            Some(LogTextEncoding::Utf16BigEndian) => self.split_utf16(true),
            None => Vec::new(),
        }
    }

    /// 清空缓冲，编码恢复成建分行器时指定的值（文件被截断、从头重读时调用）。
    pub fn reset(&mut self) {
        self.buffer = Vec::new();
        self.discarding = false;
        self.encoding = self.initial_encoding;
    }

    /// 按开头的字节判断编码，去掉 BOM。
    fn detect_encoding(&mut self) {
        let b = &self.buffer;
        let (encoding, bom) = if b[0] == 0xFF && b[1] == 0xFE {
            (LogTextEncoding::Utf16LittleEndian, 2)
        } else if b[0] == 0xFE && b[1] == 0xFF {
            (LogTextEncoding::Utf16BigEndian, 2)
        } else if b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF {
            (LogTextEncoding::Utf8, 3)
        } else {
            (LogTextEncoding::Utf8, 0)
        };
        self.encoding = Some(encoding);
        self.buffer.drain(..bom);
    }

    /// UTF-8：在 0A 处切行，去掉行尾的 0D。
    fn split_utf8(&mut self) -> Vec<String> {
        let mut lines = Vec::new();
        let mut start = 0;
        while let Some(offset) = self.buffer[start..].iter().position(|&b| b == 0x0A) {
            let newline = start + offset;
            let mut end = newline;
            if end > start && self.buffer[end - 1] == 0x0D {
                end -= 1;
            }
            if self.accepts(end - start) {
                lines.push(String::from_utf8_lossy(&self.buffer[start..end]).into_owned());
            }
            start = newline + 1;
        }
        self.keep_tail(start);
        lines
    }

    /// UTF-16：按 2 字节的码元对齐查找 000A，去掉行尾的 000D。
    fn split_utf16(&mut self, big_endian: bool) -> Vec<String> {
        let mut lines = Vec::new();
        let mut start = 0;
        let mut index = 0;
        while index + 1 < self.buffer.len() {
            if self.unit(index, big_endian) == 0x000A {
                let mut end = index;
                if end - start >= 2 && self.unit(end - 2, big_endian) == 0x000D {
                    end -= 2;
                }
                if self.accepts(end - start) {
                    let units: Vec<u16> = (start..end)
                        .step_by(2)
                        .map(|i| self.unit(i, big_endian))
                        .collect();
                    lines.push(String::from_utf16_lossy(&units));
                }
                start = index + 2;
            }
            index += 2;
        }
        self.keep_tail(start);
        lines
    }

    /// 读缓冲里第 `i` 个字节起的一个 UTF-16 码元。
    fn unit(&self, i: usize, big_endian: bool) -> u16 {
        let (a, b) = (self.buffer[i], self.buffer[i + 1]);
        if big_endian {
            u16::from_be_bytes([a, b])
        } else {
            u16::from_le_bytes([a, b])
        }
    }

    /// 一行是否输出。正在丢弃超长行时，这一段是超长行的结尾，不输出；超过上限的行同样丢弃。
    fn accepts(&mut self, byte_count: usize) -> bool {
        if self.discarding {
            self.discarding = false;
            return false;
        }
        byte_count <= self.max_line_bytes
    }

    /// 去掉已切出的部分，只留不完整的尾部。尾部超过上限时清空并进入丢弃状态，缓冲不会无限增长。
    ///
    /// 比较长度时不计尾部可能属于行尾 CRLF 的回车（见 `trailing_carriage_return_bytes`），
    /// 这样「内容正好等于上限、回车与换行被切开」的行与一次追加时的结果一致。
    fn keep_tail(&mut self, start: usize) {
        self.buffer.drain(..start);
        if self.buffer.len() - self.trailing_carriage_return_bytes() > self.max_line_bytes {
            // UTF-16 的缓冲是奇数个字节时，最后一个字节是半个码元，留下它以免后面的码元错位。
            let utf16 = self.encoding != Some(LogTextEncoding::Utf8);
            let keep = usize::from(utf16 && self.buffer.len() % 2 == 1);
            let drop = self.buffer.len() - keep;
            self.buffer.drain(..drop);
            self.discarding = true;
        }
    }

    /// 缓冲尾部可能属于行尾 CRLF 的字节数（回车，以及切在换行码元中间的前半个码元）。
    ///
    /// UTF-8 是 1（0D）。UTF-16 是完整的 000D 码元的 2 字节；缓冲是奇数个字节时，最后一个字节是下一个码元的
    /// 前半个，它可能是回车或换行的前半个（小端 0D、0A，大端 00），也算进去。宁可少算：算少只会推迟丢弃。
    fn trailing_carriage_return_bytes(&self) -> usize {
        let Some(&last) = self.buffer.last() else {
            return 0;
        };
        match self.encoding {
            Some(LogTextEncoding::Utf8) => usize::from(last == 0x0D),
            Some(encoding) => {
                let little = encoding == LogTextEncoding::Utf16LittleEndian;
                let mut n = self.buffer.len();
                let mut uncounted = 0;
                if n % 2 == 1 {
                    // 最后一个字节是下一个码元的前半个。
                    let line_end_start = if little {
                        last == 0x0D || last == 0x0A
                    } else {
                        last == 0x00
                    };
                    if !line_end_start {
                        return 0;
                    }
                    uncounted = 1;
                    n -= 1;
                }
                if n < 2 {
                    return uncounted;
                }
                let (a, b) = (self.buffer[n - 2], self.buffer[n - 1]);
                let is_cr = if little {
                    a == 0x0D && b == 0x00
                } else {
                    a == 0x00 && b == 0x0D
                };
                uncounted + if is_cr { 2 } else { 0 }
            }
            None => 0,
        }
    }
}
