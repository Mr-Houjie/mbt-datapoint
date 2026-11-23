// 数据段解析与序列化。
//
// 数据段是 `QN=...;ST=...;CN=...;PW=...;MN=...;Flag=...;PNUM=...;PNO=...;CP=&&...&&`。
//
// 这里有一个容易踩的坑：CP 的取值本身也用 `;` 分隔字段，所以不能把整个
// 数据段直接按 `;` 切开再找 `CP`——那样会把数据区撕成碎片。正确做法是先
// 定位 `CP=`，它之前的部分按 `;` 切字段，它之后的部分整体交给数据区解析。

///|
/// 定位数据区字段 `CP` 的起始位置。
///
/// 不能简单取第一次出现的 `CP=`：其他字段的取值里也可能含 `CP=`（例如
/// `Note=XCP=Y`），那样会把字段从中间切断、把合法帧误判为非法。
/// 因此要求 `CP` 必须处在一个字段的起点——即位于 0 号位置，或紧跟 `;`。
fn find_cp_field(cs : Array[Char]) -> Int32 {
  let mut i = 0
  while i + 3 <= cs.length() {
    let at_boundary = i == 0 || cs[i - 1] == ';'
    if at_boundary && cs[i] == 'C' && cs[i + 1] == 'P' && cs[i + 2] == '=' {
      return i
    }
    i = i + 1
  }
  -1
}

///|
pub fn Segment::parse(text : String) -> Result[Segment, DecodeError] {
  let cs = trim_chars(chars_of(text))
  if cs.length() == 0 {
    return Err(EmptySegment)
  }
  let cp_pos = find_cp_field(cs)
  let (head_cs, cp_text) = if cp_pos >= 0 {
    (chars_slice(cs, 0, cp_pos), slice_chars(cs, cp_pos + 3, cs.length()))
  } else {
    (chars_slice(cs, 0, cs.length()), "")
  }
  let mut qn = ""
  let mut st = ""
  let mut cn = ""
  let mut pw = ""
  let mut mn = ""
  let mut flag_raw : Int32? = None
  let mut pnum : Int32? = None
  let mut pno : Int32? = None
  let mut rf = false
  let extra : Array[DataItem] = []
  let seen_cp = cp_pos >= 0
  // 核心字段只允许出现一次。现场报文偶尔会把 MN 重复贴两遍，
  // 若静默取后者，出问题时很难查，所以宁可报错。
  let seen_fields : Array[String] = []

  let mut start = 0
  let mut i = 0
  while i <= head_cs.length() {
    let at_end = i == head_cs.length()
    if at_end || head_cs[i] == ';' {
      let piece = trim_chars(chars_slice(head_cs, start, i))
      if piece.length() > 0 {
        let eq = find_char(piece, '=', 0)
        if eq < 0 {
          return Err(BadField(slice_chars(piece, 0, piece.length())))
        }
        let name = trim_text(slice_chars(piece, 0, eq))
        let value = trim_text(slice_chars(piece, eq + 1, piece.length()))
        let is_core = name == "QN" ||
          name == "ST" ||
          name == "CN" ||
          name == "PW" ||
          name == "MN" ||
          name == "Flag" ||
          name == "PNUM" ||
          name == "PNO" ||
          name == "RF"
        if is_core {
          if seen_fields.contains(name) {
            return Err(DuplicateField(name))
          }
          seen_fields.push(name)
        }
        match name {
          "QN" => qn = value
          "ST" => st = value
          "CN" => cn = value
          "PW" => pw = value
          "MN" => mn = value
          "Flag" =>
            match parse_uint_all(value) {
              Some(v) => flag_raw = Some(v & 0xFF)
              None => return Err(BadFieldValue(name, value))
            }
          "PNUM" =>
            match parse_uint_all(value) {
              Some(v) => pnum = Some(v)
              None => return Err(BadFieldValue(name, value))
            }
          "PNO" =>
            match parse_uint_all(value) {
              Some(v) => pno = Some(v)
              None => return Err(BadFieldValue(name, value))
            }
          // 2025 版新增：RF=1 表示补传报文，非补传时无本字段。
          "RF" =>
            match parse_uint_all(value) {
              Some(v) => rf = v != 0
              None => return Err(BadFieldValue(name, value))
            }
          _ => extra.push({ name, values: [value], comma_before: false, })
        }
      }
      start = i + 1
    }
    i = i + 1
  }

  if qn == "" {
    return Err(MissingField("QN"))
  }
  if st == "" {
    return Err(MissingField("ST"))
  }
  if cn == "" {
    return Err(MissingField("CN"))
  }
  if mn == "" {
    return Err(MissingField("MN"))
  }
  let flag = match flag_raw {
    Some(v) => Flag::from_raw(v)
    None => return Err(MissingField("Flag"))
  }
  let cp = if seen_cp {
    match DataArea::parse(cp_text) {
      Ok(area) => area
      Err(e) => return Err(e)
    }
  } else {
    return Err(MissingField("CP"))
  }
  Ok({ qn, st, cn, pw, mn, flag, pnum, pno, rf, cp, extra, })
}

///|
/// 渲染成规范的数据段文本。
pub fn Segment::text(self : Segment) -> String {
  let sb = StringBuilder()
  sb.write_string("QN=")
  sb.write_string(self.qn)
  sb.write_string(";ST=")
  sb.write_string(self.st)
  sb.write_string(";CN=")
  sb.write_string(self.cn)
  if self.pw != "" {
    sb.write_string(";PW=")
    sb.write_string(self.pw)
  }
  sb.write_string(";MN=")
  sb.write_string(self.mn)
  sb.write_string(";Flag=")
  sb.write_string(self.flag.text())
  match self.pnum {
    Some(v) => {
      sb.write_string(";PNUM=")
      sb.write_string(v.to_string())
    }
    None => ()
  }
  match self.pno {
    Some(v) => {
      sb.write_string(";PNO=")
      sb.write_string(v.to_string())
    }
    None => ()
  }
  if self.rf {
    sb.write_string(";RF=1")
  }
  let mut i = 0
  while i < self.extra.length() {
    sb.write_string(";")
    sb.write_string(self.extra[i].name)
    sb.write_string("=")
    let values = self.extra[i].values
    let mut j = 0
    while j < values.length() {
      if j > 0 {
        sb.write_char(',')
      }
      sb.write_string(values[j])
      j = j + 1
    }
    i = i + 1
  }
  sb.write_string(";CP=")
  sb.write_string(self.cp.wrapped_text())
  sb.to_string()
}

///|
/// 语义检查。
///
/// 结构性问题在 `parse` 阶段就会失败；这里报的是「能解析但不符合行业惯例」
/// 的情况，例如 MN 长度与版本不匹配、Flag 声明分包却没有包号。
/// 返回空数组表示没有发现问题。
pub fn Segment::validate(self : Segment) -> Array[String] {
  let warnings : Array[String] = []
  let qn_cs = chars_of(self.qn)
  if qn_cs.length() < 14 || qn_cs.length() > 20 {
    warnings.push(
      "QN 长度 \{qn_cs.length()}，通常为 17 位（YYYYMMDDhhmmsszzz）",
    )
  }
  let mut all_digit = true
  for c in qn_cs {
    if !is_digit_char(c) {
      all_digit = false
    }
  }
  if !all_digit {
    warnings.push("QN 含非数字字符")
  }
  match QnTime::parse(self.qn) {
    Some(_) => ()
    None => warnings.push("QN 无法解析成时间戳")
  }
  let cn_cs = chars_of(self.cn)
  if cn_cs.length() != 4 {
    warnings.push("CN 长度 \{cn_cs.length()}，标准为 4 位")
  }
  match self.flag.version() {
    Unknown(n) => warnings.push("Flag 版本位 \{n} 未登记")
    _ => ()
  }
  if self.flag.is_split() {
    if self.pnum is None || self.pno is None {
      warnings.push("Flag 声明分包，但缺少 PNUM 或 PNO")
    }
  } else if self.pnum is Some(_) || self.pno is Some(_) {
    warnings.push("Flag 声明不分包，但出现了 PNUM 或 PNO")
  }
  let mn_len = chars_of(self.mn).length()
  match self.flag.version() {
    V2005 =>
      if mn_len != 14 {
        warnings.push("2005 版 MN 通常为 14 位，实际 \{mn_len} 位")
      }
    V2017 =>
      if mn_len != 24 {
        warnings.push("2017 版 MN 通常为 24 位，实际 \{mn_len} 位")
      }
    V2025 =>
      if mn_len != 24 {
        warnings.push("2025 版 MN 通常为 24 位，实际 \{mn_len} 位")
      }
    Unknown(_) => ()
  }
  warnings
}
