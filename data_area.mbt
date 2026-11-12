// 指令参数（CP）数据区。
//
// 标准约定：字段名与字段值用 `=` 连接；同一项的不同取值用 `,` 分隔；
// 不同项之间用 `;` 分隔；整个数据区外面套一层 `&& ... &&`。
//
// 解析必须容忍现场设备的写法差异：空格、末尾多余的分号、缺失的 `&&`。
// 但序列化一律输出规范形式，因此「解码再编码」是一步归一化，而不是原样回吐。

///|
pub fn DataArea::new() -> DataArea {
  { items: [], }
}

///|
/// 解析数据区文本。
///
/// 接受带 `&&...&&` 包装的形式，也接受裸数据区（便于单独测试数据区）。
pub fn DataArea::parse(text : String) -> Result[DataArea, DecodeError] {
  let mut cs = trim_chars(chars_of(text))
  // 标准 6.3.2 规定指令参数 CP 的取值是 `&&数据区&&`。没有这层包装说明
  // 对方用的不是 HJ 212 的数据区格式，宁可报错也不要猜。
  if cs.length() < 2 || cs[0] != '&' || cs[1] != '&' {
    return Err(BadDataArea("数据区必须以 \"&&\" 开头"))
  }
  let close = find_seq(cs, "&&", 2)
  if close < 0 {
    return Err(BadDataArea("以 \"&&\" 开头但没有结束的 \"&&\""))
  }
  let mut tail = close + 2
  while tail < cs.length() {
    if !is_space_char(cs[tail]) {
      return Err(TrailingGarbage(slice_chars(cs, tail, cs.length())))
    }
    tail = tail + 1
  }
  cs = trim_chars(chars_slice(cs, 2, close))
  let items : Array[DataItem] = []
  if cs.length() == 0 {
    return Ok({ items, })
  }
  let mut start = 0
  let mut i = 0
  while i <= cs.length() {
    let at_end = i == cs.length()
    if at_end || cs[i] == ';' {
      let piece = trim_chars(chars_slice(cs, start, i))
      if piece.length() > 0 {
        match parse_item(piece) {
          Ok(item) => items.push(item)
          Err(e) => return Err(e)
        }
      }
      start = i + 1
    }
    i = i + 1
  }
  Ok({ items, })
}

///|
/// 解析单个 `名称=值[,值...]`。
fn parse_item(cs : Array[Char]) -> Result[DataItem, DecodeError] {
  let eq = find_char(cs, '=', 0)
  if eq < 0 {
    return Err(BadField(slice_chars(cs, 0, cs.length())))
  }
  let name = trim_text(slice_chars(cs, 0, eq))
  if name == "" {
    return Err(BadDataArea("出现空的字段名"))
  }
  if !is_valid_field_name(name) {
    return Err(BadDataArea("字段名 \"\{name}\" 含非法字符"))
  }
  let vcs = trim_chars(chars_slice(cs, eq + 1, cs.length()))
  let values : Array[String] = []
  let mut start = 0
  let mut i = 0
  while i <= vcs.length() {
    let at_end = i == vcs.length()
    if at_end || vcs[i] == ',' {
      values.push(trim_text(slice_chars(vcs, start, i)))
      start = i + 1
    }
    i = i + 1
  }
  Ok({ name, values, })
}

///|
fn find_char(cs : Array[Char], target : Char, from : Int32) -> Int32 {
  let mut i = from
  while i < cs.length() {
    if cs[i] == target {
      return i
    }
    i = i + 1
  }
  -1
}

///|
/// 字段名只允许字母、数字、下划线与连字符（如 `Data-Flag`）。
fn is_valid_field_name(name : String) -> Bool {
  if name == "" {
    return false
  }
  for c in name {
    let ok = (c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == '_' ||
      c == '-'
    if !ok {
      return false
    }
  }
  true
}

///|
/// 渲染成规范形式（不含 `&&` 包装）。
pub fn DataArea::text(self : DataArea) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < self.items.length() {
    if i > 0 {
      sb.write_char(';')
    }
    let item = self.items[i]
    sb.write_string(item.name)
    sb.write_char('=')
    let mut j = 0
    while j < item.values.length() {
      if j > 0 {
        sb.write_char(',')
      }
      sb.write_string(item.values[j])
      j = j + 1
    }
    i = i + 1
  }
  sb.to_string()
}

///|
/// 渲染成报文里的 `CP` 取值，带 `&&` 包装。
pub fn DataArea::wrapped_text(self : DataArea) -> String {
  "&&\{self.text()}&&"
}

///|
/// 取某个字段的第一个值。
pub fn DataArea::get(self : DataArea, name : String) -> String? {
  let mut i = 0
  while i < self.items.length() {
    if self.items[i].name == name {
      let values = self.items[i].values
      if values.length() > 0 {
        return Some(values[0])
      }
      return Some("")
    }
    i = i + 1
  }
  None
}

///|
/// 取某个字段的全部值。
pub fn DataArea::get_all(self : DataArea, name : String) -> Array[String] {
  let out : Array[String] = []
  let mut i = 0
  while i < self.items.length() {
    if self.items[i].name == name {
      for v in self.items[i].values {
        out.push(v)
      }
    }
    i = i + 1
  }
  out
}

///|
/// 字段是否出现。
pub fn DataArea::has(self : DataArea, name : String) -> Bool {
  match self.get(name) {
    Some(_) => true
    None => false
  }
}

///|
/// 追加或覆盖一个单值字段。
pub fn DataArea::set(self : DataArea, name : String, value : String) -> Unit {
  self.set_values(name, [value])
}

///|
/// 追加或覆盖一个多值字段。
pub fn DataArea::set_values(
  self : DataArea,
  name : String,
  values : Array[String],
) -> Unit {
  let mut i = 0
  while i < self.items.length() {
    if self.items[i].name == name {
      self.items[i].values = values
      return
    }
    i = i + 1
  }
  self.items.push({ name, values, })
}

///|
/// 字段个数。
pub fn DataArea::length(self : DataArea) -> Int32 {
  self.items.length()
}
