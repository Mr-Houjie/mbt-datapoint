// 文本与字节工具。
//
// 报文本身是 ASCII，但数据区的取值允许出现中文（UTF-8）。
// 长度字段按「数据段的 ASCII 字符数」定义，实际部署中普遍按 UTF-8
// 字节数计算，因此这里统一以 UTF-8 字节为准，并把码点级工具单独列出。

///|
fn chars_of(s : String) -> Array[Char] {
  let out : Array[Char] = []
  for c in s {
    out.push(c)
  }
  out
}

///|
/// 取 `[start, end)` 的字符区间拼成字符串，越界部分自动截断。
fn slice_chars(cs : Array[Char], start : Int32, end : Int32) -> String {
  let sb = StringBuilder()
  let mut i = if start < 0 { 0 } else { start }
  let stop = if end > cs.length() { cs.length() } else { end }
  while i < stop {
    sb.write_char(cs[i])
    i = i + 1
  }
  sb.to_string()
}

///|
/// 取 `[start, end)` 的字符区间副本，越界部分自动截断。
fn chars_slice(cs : Array[Char], start : Int32, end : Int32) -> Array[Char] {
  let out : Array[Char] = []
  let mut i = if start < 0 { 0 } else { start }
  let stop = if end > cs.length() { cs.length() } else { end }
  while i < stop {
    out.push(cs[i])
    i = i + 1
  }
  out
}

///|
/// 在字符数组中查找子串首次出现的位置，找不到返回 `-1`。
fn find_seq(cs : Array[Char], pat : String, from : Int32) -> Int32 {
  let p = chars_of(pat)
  let n = p.length()
  if n == 0 {
    return from
  }
  let mut i = if from < 0 { 0 } else { from }
  while i + n <= cs.length() {
    let mut j = 0
    let mut matched = true
    while j < n {
      if cs[i + j] != p[j] {
        matched = false
        break
      }
      j = j + 1
    }
    if matched {
      return i
    }
    i = i + 1
  }
  -1
}

///|
fn is_digit_char(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// 十六进制字符转数值，非法字符返回 `-1`。
fn hex_value(c : Char) -> Int32 {
  if c >= '0' && c <= '9' {
    c.to_int() - 48
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 87
  } else if c >= 'A' && c <= 'F' {
    c.to_int() - 55
  } else {
    -1
  }
}

///|
/// 解析一段十进制数字，空段或含非数字返回 `None`。
///
/// 超出 `Int32` 范围也返回 `None`，**不静默溢出**。报文字段是外部输入，
/// `PNUM=99999999999` 这种值累加出来会翻成负数或垃圾正数（实测
/// `99999999999 -> 1215752191`、`2147483648 -> -2147483648`），
/// 下游再拿它做包号比较，行为完全不可预测。
fn parse_uint(cs : Array[Char], start : Int32, len : Int32) -> Int32? {
  if len <= 0 || start < 0 || start + len > cs.length() {
    return None
  }
  let mut value = 0
  let mut i = 0
  while i < len {
    let c = cs[start + i]
    if !is_digit_char(c) {
      return None
    }
    let digit = c.to_int() - 48
    // 2147483647 是 Int32 上限：先看再乘，乘完就不会越界。
    if value > 214748364 || (value == 214748364 && digit > 7) {
      return None
    }
    value = value * 10 + digit
    i = i + 1
  }
  Some(value)
}

///|
/// 解析一个完整字符串里的十进制数字。
fn parse_uint_all(s : String) -> Int32? {
  let cs = chars_of(s)
  parse_uint(cs, 0, cs.length())
}

///|
fn is_space_char(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\r' || c == '\n'
}

///|
/// 去掉首尾空白，返回新的字符数组。
fn trim_chars(cs : Array[Char]) -> Array[Char] {
  let mut start = 0
  let mut stop = cs.length()
  while start < stop && is_space_char(cs[start]) {
    start = start + 1
  }
  while stop > start && is_space_char(cs[stop - 1]) {
    stop = stop - 1
  }
  let out : Array[Char] = []
  let mut i = start
  while i < stop {
    out.push(cs[i])
    i = i + 1
  }
  out
}

///|
/// 去空白后的字符串。
fn trim_text(s : String) -> String {
  let cs = trim_chars(chars_of(s))
  slice_chars(cs, 0, cs.length())
}

///|
/// 单个码点在 UTF-8 下占用的字节数。
fn utf8_char_len(c : Char) -> Int32 {
  let cp = c.to_int()
  if cp < 0x80 {
    1
  } else if cp < 0x800 {
    2
  } else if cp < 0x10000 {
    3
  } else {
    4
  }
}

///|
/// 字符串的 UTF-8 字节数。
///
/// 报文的长度字段按字节计，且 CRC 也按字节计算；两者必须使用同一套计数，
/// 否则含中文的数据区会算错。
pub fn utf8_len(s : String) -> Int32 {
  let mut n = 0
  for c in s {
    n = n + utf8_char_len(c)
  }
  n
}

///|
/// 把字符串编码成 UTF-8 字节序列。
fn utf8_bytes(s : String) -> Array[Byte] {
  let out : Array[Byte] = []
  for c in s {
    let cp = c.to_int()
    if cp < 0x80 {
      out.push(cp.to_byte())
    } else if cp < 0x800 {
      out.push((0xC0 | (cp >> 6)).to_byte())
      out.push((0x80 | (cp & 0x3F)).to_byte())
    } else if cp < 0x10000 {
      out.push((0xE0 | (cp >> 12)).to_byte())
      out.push((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      out.push((0x80 | (cp & 0x3F)).to_byte())
    } else {
      out.push((0xF0 | (cp >> 18)).to_byte())
      out.push((0x80 | ((cp >> 12) & 0x3F)).to_byte())
      out.push((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      out.push((0x80 | (cp & 0x3F)).to_byte())
    }
  }
  out
}

///|
/// 两位大写十六进制。
fn pad_hex2(value : Int32) -> String {
  let v = value & 0xFF
  let hi = (v >> 4) & 0xF
  let lo = v & 0xF
  "\{hex_digit(hi)}\{hex_digit(lo)}"
}

///|
fn hex_digit(v : Int32) -> String {
  if v < 10 {
    (v + 48).unsafe_to_char().to_string()
  } else {
    (v - 10 + 65).unsafe_to_char().to_string()
  }
}

///|
/// 四位大写十六进制。
fn hex4(value : Int32) -> String {
  let v = value & 0xFFFF
  "\{hex_digit((v >> 12) & 0xF)}\{hex_digit((v >> 8) & 0xF)}\{hex_digit((v >> 4) & 0xF)}\{hex_digit(v & 0xF)}"
}

///|
/// 左补零的定宽二进制串，用于按位展示位域（例如 Flag 的 V5~V0）。
fn bin_pad(value : Int32, width : Int32) -> String {
  let sb = StringBuilder()
  let mut i = width - 1
  while i >= 0 {
    if ((value >> i) & 1) == 1 {
      sb.write_char('1')
    } else {
      sb.write_char('0')
    }
    i = i - 1
  }
  sb.to_string()
}

///|
/// 左补零到固定宽度。
fn zero_pad(value : Int32, width : Int32) -> String {
  let digits = value.to_string()
  let mut pad = width - digits.length()
  if pad < 0 {
    pad = 0
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < pad {
    sb.write_char('0')
    i = i + 1
  }
  sb.write_string(digits)
  sb.to_string()
}

///|
/// 等宽终端下的显示宽度：CJK 与全角符号记 2 列，其余记 1 列。
fn display_width(s : String) -> Int32 {
  let mut width = 0
  for c in s {
    let cp = c.to_int()
    if cp < 0x20 {
      width = width + 0
    } else if cp < 0x7F {
      width = width + 1
    } else if is_wide_codepoint(cp) {
      width = width + 2
    } else {
      width = width + 1
    }
  }
  width
}

///|
/// 粗略的东亚宽字符判定，仅用于终端表格对齐。
fn is_wide_codepoint(cp : Int32) -> Bool {
  if cp >= 0x1100 && cp <= 0x115F {
    return true
  }
  if cp >= 0x2E80 && cp <= 0xA4CF {
    return true
  }
  if cp >= 0xAC00 && cp <= 0xD7A3 {
    return true
  }
  if cp >= 0xF900 && cp <= 0xFAFF {
    return true
  }
  if cp >= 0xFE30 && cp <= 0xFE6F {
    return true
  }
  if cp >= 0xFF00 && cp <= 0xFF60 {
    return true
  }
  if cp >= 0xFFE0 && cp <= 0xFFE6 {
    return true
  }
  false
}

///|
/// 按显示宽度右补空格。
pub fn pad_display(s : String, width : Int32) -> String {
  let w = display_width(s)
  if w >= width {
    return s
  }
  let sb = StringBuilder()
  sb.write_string(s)
  let mut i = w
  while i < width {
    sb.write_char(' ')
    i = i + 1
  }
  sb.to_string()
}
