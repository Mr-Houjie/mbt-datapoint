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
  let mut comma_before = false
  while i <= cs.length() {
    let at_end = i == cs.length()
    // 逗号两侧可能是「同一项目的不同类别」（两个独立字段），也可能是
    // 同一个字段的多个取值。区别在于逗号之后是不是又一个 "名="。
    let is_comma_field = !at_end &&
      cs[i] == ',' &&
      looks_like_field_start(cs, i + 1)
    if at_end || cs[i] == ';' || is_comma_field {
      let piece = trim_chars(chars_slice(cs, start, i))
      if piece.length() > 0 {
        match parse_item(piece, comma_before) {
          Ok(item) => items.push(item)
          Err(e) => return Err(e)
        }
      }
      comma_before = is_comma_field
      start = i + 1
    }
    i = i + 1
  }
  Ok({ items, })
}

///|
/// 解析单个 `名称=值[,值...]`。
fn parse_item(cs : Array[Char], comma_before : Bool) -> Result[DataItem, DecodeError] {
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
  Ok({ name, values, comma_before, })
}

///|
/// 从 `from` 出发，判断接下来是否是「字段名=」的开头。
///
/// 用于区分数据区里的两种逗号：`a01011-Min=1.35,a01011-Avg=1.35` 里逗号
/// 之后是新字段；`x=1.5,2.0` 里逗号之后是这个字段的第二个取值。
/// 判定方式：一路跳过字段名允许的字符，若紧接着是 `=` 就是新字段。
fn looks_like_field_start(cs : Array[Char], from : Int32) -> Bool {
  let mut i = from
  while i < cs.length() && is_space_char(cs[i]) {
    i = i + 1
  }
  let name_start = i
  while i < cs.length() {
    let c = cs[i]
    if c == '=' {
      return i > name_start
    }
    let ok = (c >= 'A' && c <= 'Z') ||
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      c == '_' ||
      c == '-'
    if !ok {
      return false
    }
    i = i + 1
  }
  false
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
    let item = self.items[i]
    if i > 0 {
      if item.comma_before {
        sb.write_char(',')
      } else {
        sb.write_char(';')
      }
    }
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
/// 取某个字段的值，不存在时返回给定的默认值。
pub fn DataArea::get_or(
  self : DataArea,
  name : String,
  fallback : String,
) -> String {
  match self.get(name) {
    Some(v) => v
    None => fallback
  }
}

///|
/// 把字段值当整数读。
///
/// 常见于 `RtdInterval`、`Flag` 一类整数字段。返回 `None` 有两种情况：
/// 字段不存在，或者取值不是整数——包括标准里用 `N` / `U` 表示
/// 「无有效数据」的那种写法，此时上层应当按缺失处理而不是当成 0。
pub fn DataArea::get_int(self : DataArea, name : String) -> Int32? {
  match self.get(name) {
    Some(v) => parse_int_text(v)
    None => None
  }
}

///|
/// 把字段值当浮点数读。
///
/// 监测值形如 `1.52`、`-3.00`、`0`；无有效数据时现场会写 `N`，此时返回
/// `None`。不接受科学计数法——标准里的数值类型（`N14.2` 等）没有这种写法，
/// 放进来只会掩盖「对方发的不是这个字段」的问题。
pub fn DataArea::get_float(self : DataArea, name : String) -> Double? {
  match self.get(name) {
    Some(v) => parse_float_text(v)
    None => None
  }
}

///|
/// 删除某个字段，返回是否真的删掉了。
pub fn DataArea::remove(self : DataArea, name : String) -> Bool {
  let mut i = 0
  while i < self.items.length() {
    if self.items[i].name == name {
      let _ = self.items.remove(i)
      return true
    }
    i = i + 1
  }
  false
}

///|
/// 解析带符号整数。允许前导 `+` / `-`，不允许小数点。
fn parse_int_text(text : String) -> Int32? {
  let cs = trim_chars(chars_of(text))
  if cs.length() == 0 {
    return None
  }
  let mut i = 0
  let mut negative = false
  if cs[0] == '-' {
    negative = true
    i = 1
  } else if cs[0] == '+' {
    i = 1
  }
  if i >= cs.length() {
    return None
  }
  let mut value : Int32 = 0
  while i < cs.length() {
    if !is_digit_char(cs[i]) {
      return None
    }
    value = value * 10 + (cs[i].to_int() - 48)
    i = i + 1
  }
  if negative {
    Some(-value)
  } else {
    Some(value)
  }
}

///|
/// 解析十进制小数，形如 `-12.34`、`0`、`.5`、`5.`。
///
/// 手写而不是转调标准库的浮点解析：核心库要保持零依赖，而这个格式
/// （可选符号 + 数字 + 可选小数点 + 数字）用不着通用解析器。
fn parse_float_text(text : String) -> Double? {
  let cs = trim_chars(chars_of(text))
  if cs.length() == 0 {
    return None
  }
  let mut i = 0
  let mut sign = 1.0
  if cs[0] == '-' {
    sign = -1.0
    i = 1
  } else if cs[0] == '+' {
    i = 1
  }
  let mut int_part = 0.0
  let mut digits = 0
  while i < cs.length() && is_digit_char(cs[i]) {
    int_part = int_part * 10.0 + (cs[i].to_int() - 48).to_double()
    i = i + 1
    digits = digits + 1
  }
  let mut frac = 0.0
  let mut scale = 1.0
  if i < cs.length() && cs[i] == '.' {
    i = i + 1
    while i < cs.length() && is_digit_char(cs[i]) {
      frac = frac * 10.0 + (cs[i].to_int() - 48).to_double()
      scale = scale * 10.0
      i = i + 1
      digits = digits + 1
    }
  }
  // 一个数字都没有（如 ""、"-"、"."）算解析失败；
  // 还有剩余字符（如 "1.2.3"、"12a"）也算失败，不做「读到哪算哪」的容错。
  if digits == 0 || i != cs.length() {
    return None
  }
  Some(sign * (int_part + frac / scale))
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
  self.items.push({ name, values, comma_before: false, })
}

///|
/// 字段个数。
pub fn DataArea::length(self : DataArea) -> Int32 {
  self.items.length()
}
