// 公共数据类型。
//
// 本库不依赖任何第三方包，所有解析都只基于输入文本，
// 因此同一份报文在 native / wasm / js 后端上得到相同结果。

///|
/// 标准版本。
///
/// 版本号编码在报文 `Flag` 字段的 V5–V0 位里。现场设备并不统一：
/// 2005 版与 2017 版的数采仪可能挂在同一条链路上，因此解析器
/// 必须读完 `Flag` 才知道该用哪套字段规则去解释这条报文。
pub(all) enum Version {
  /// HJ/T 212-2005，版本位 `000000`
  V2005
  /// HJ 212-2017，版本位 `000001`
  V2017
  /// HJ 212-2025，版本位 `000010`
  V2025
  /// 未在标准中登记的版本位
  Unknown(Int32)
}

///|
pub fn Version::from_code(code : Int32) -> Version {
  match code {
    0 => V2005
    1 => V2017
    2 => V2025
    _ => Unknown(code)
  }
}

///|
pub fn Version::code(self : Version) -> Int32 {
  match self {
    V2005 => 0
    V2017 => 1
    V2025 => 2
    Unknown(n) => n
  }
}

///|
pub fn Version::label(self : Version) -> String {
  match self {
    V2005 => "HJ/T 212-2005"
    V2017 => "HJ 212-2017"
    V2025 => "HJ 212-2025"
    Unknown(n) => "未知版本(\{n})"
  }
}

///|
/// 报文的 `Flag` 字段，一个 8 位无符号整数。
///
/// 位布局（高位到低位）：`V5 V4 V3 V2 V1 V0 | 分包位 | 应答位`
///
/// - `V5..V0`：标准版本号，`000000` = 2005 版，`000001` = 2017 版，`000010` = 2025 版；
/// - bit1：数据段是否携带 `PNUM` / `PNO` 分包序号；
/// - bit0：本条命令是否需要应答。
///
/// 注意：这两位的**字母**在两次修订里换过名。2017 版写作 `D`（分包）
/// 与 `A`（应答），2025 版写作 `A`（分包）与 `D`（应答）。位权没有变，
/// 变的只是字母，这也是最容易抄错的一处；本库只按位权判断，不引用字母。
///
/// 例：`Flag=9` 即 `00001001`，表示 2025 版、不分包、需要应答。
pub(all) struct Flag {
  raw : Int32
}

///|
pub fn Flag::from_raw(raw : Int32) -> Flag {
  { raw: raw & 0xFF, }
}

///|
pub fn Flag::new(version : Version, split : Bool, ack : Bool) -> Flag {
  let v = version.code() & 0x3F
  let d = if split { 1 } else { 0 }
  let a = if ack { 1 } else { 0 }
  { raw: (v << 2) | (d << 1) | a, }
}

///|
pub fn Flag::version(self : Flag) -> Version {
  Version::from_code((self.raw >> 2) & 0x3F)
}

///|
pub fn Flag::is_split(self : Flag) -> Bool {
  ((self.raw >> 1) & 1) == 1
}

///|
pub fn Flag::needs_ack(self : Flag) -> Bool {
  (self.raw & 1) == 1
}

///|
pub fn Flag::text(self : Flag) -> String {
  self.raw.to_string()
}

///|
/// 解码失败的原因。
///
/// 结构性错误（包头、长度、CRC、包尾）一律视为失败并拒绝该帧；
/// 字段取值是否符合行业惯例属于语义问题，交由 `Segment::validate` 报告，
/// 两者刻意分开。
pub(all) enum DecodeError {
  /// 没有以 `##` 开头
  MissingHeader
  /// 包头后的 4 位长度不是十进制数字
  BadLengthField(String)
  /// 长度字段声明的字节数超出实际可用文本
  Truncated(Int32, Int32)
  /// CRC 校验失败：声明的校验码、实际算出的校验码
  BadCrc(String, String)
  /// CRC 之后不是 `<CR><LF>`
  BadTail(String)
  /// 数据段为空
  EmptySegment
  /// 缺少必需字段
  MissingField(String)
  /// 字段重复出现
  DuplicateField(String)
  /// 字段没有 `=` 分隔符
  BadField(String)
  /// 字段值不合法：字段名、取值
  BadFieldValue(String, String)
  /// 数据区结构不合法
  BadDataArea(String)
  /// CRC 与包尾之间还有多余字符
  TrailingGarbage(String)
}

///|
/// 稳定的错误码，供上层程序分支判断或写日志用。
///
/// 与 `message()` 的区别：`message()` 是给人看的中文描述，措辞可能随版本调整；
/// `kind()` 是给程序看的标识，一旦发布就不再变化。
pub fn DecodeError::kind(self : DecodeError) -> String {
  match self {
    MissingHeader => "MissingHeader"
    BadLengthField(_) => "BadLengthField"
    Truncated(_, _) => "Truncated"
    BadCrc(_, _) => "BadCrc"
    BadTail(_) => "BadTail"
    EmptySegment => "EmptySegment"
    MissingField(_) => "MissingField"
    DuplicateField(_) => "DuplicateField"
    BadField(_) => "BadField"
    BadFieldValue(_, _) => "BadFieldValue"
    BadDataArea(_) => "BadDataArea"
    TrailingGarbage(_) => "TrailingGarbage"
  }
}

///|
pub fn DecodeError::message(self : DecodeError) -> String {
  match self {
    MissingHeader => "报文没有以 \"##\" 开头"
    BadLengthField(s) => "长度字段 \"\{s}\" 不是 4 位十进制数字"
    Truncated(declared, available) =>
      "长度字段声明 \{declared} 字节，实际只有 \{available} 字节可用"
    BadCrc(declared, computed) =>
      "CRC 校验失败：报文声明 \{declared}，实际应为 \{computed}"
    BadTail(s) => "包尾应为 CRLF，实际是 \{describe_invisible(s)}"
    EmptySegment => "数据段为空"
    MissingField(name) => "缺少必需字段 \{name}"
    DuplicateField(name) => "字段 \{name} 重复出现"
    BadField(name) => "字段 \{name} 缺少 \"=\" 分隔符"
    BadFieldValue(name, value) =>
      "字段 \{name} 的取值 \"\{value}\" 不合法"
    BadDataArea(reason) => "数据区不合法：\{reason}"
    TrailingGarbage(s) =>
      "包尾之后还有多余字符 \{describe_invisible(s)}"
  }
}

///|
/// 把不可见字符渲染成可读形式，用于错误信息。
fn describe_invisible(s : String) -> String {
  if s == "" {
    return "<空>"
  }
  let sb = StringBuilder()
  for c in s {
    let cp = c.to_int()
    if cp == 13 {
      sb.write_string("\\r")
    } else if cp == 10 {
      sb.write_string("\\n")
    } else if cp == 9 {
      sb.write_string("\\t")
    } else if cp == 32 {
      sb.write_string("␠")
    } else if cp < 32 {
      sb.write_string("\\x\{pad_hex2(cp)}")
    } else {
      sb.write_char(c)
    }
  }
  sb.to_string()
}

///|
/// 数据项的数据类型，对应标准 6.3.3.2.2 的类型定义表。
///
/// - `C4` 表示最多 4 位的字符串；
/// - `N5` 表示最多 5 位数字；
/// - `N14.2` 表示 14 位整数与 2 位小数，带符号，最大长度 18；
/// - `YYYY` / `MM` / `DD` / `hh` / `mm` / `ss` / `zzz` 表示时间片段。
pub(all) enum FieldType {
  Chars(Int32)
  Number(Int32, Int32)
  Year
  Month
  Day
  Hour
  Minute
  Second
  Millisecond
}

///|
/// 数据区中的一项：`名称=值`，同一项可以有多个用 `,` 分隔的值。
pub(all) struct DataItem {
  name : String
  mut values : Array[String]
}

///|
/// 指令参数（`CP`）的数据区。
///
/// 序列化时按标准约定：同项多值用 `,` 连接，不同项用 `;` 连接。
pub(all) struct DataArea {
  items : Array[DataItem]
}

///|
/// 数据段：一条命令的固定头部加上指令参数。
///
/// 字段顺序按标准固定为 `QN;ST;CN;PW;MN;Flag;PNUM;PNO;CP`。
/// `pnum` / `pno` 只在 `Flag` 的 D 位为 1 时出现；`extra` 用来保留
/// 现场设备自行追加的扩展字段，保证解码后再编码不会丢信息。
pub(all) struct Segment {
  qn : String
  st : String
  cn : String
  pw : String
  mn : String
  flag : Flag
  pnum : Int32?
  pno : Int32?
  cp : DataArea
  extra : Array[DataItem]
}

///|
/// 一条完整的报文。
pub(all) struct Frame {
  segment : Segment
}
