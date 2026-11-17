// 协议无关的时序数据模型。
//
// 这一层不引用 HJ 212 的任何字段定义。其它 MoonBit 项目可以只用
// Point / Field / Value 来表达自己的设备数据、日志事件或指标，
// 完全不必接触环保协议。HJ 212 只是本模块的一个 adapter（见文件末尾）。
//
// 设计上刻意把「空」和「零」分开：Value::Missing 表示这一项没有值，
// 0 是一个完全合法的数值。采集现场最常出的错就是把缺失当成 0 存进库，
// 之后做任何统计都会被悄悄拉偏。

///|
/// 一个字段的取值。
pub(all) enum Value {
  /// 十进制数值
  Num(Double)
  /// 原样保留的文本（设备状态码、备注、非数值标记等）
  Text(String)
  /// 缺失 / 无有效数据
  Missing
} derive(Eq, Debug)

///|
pub extend Value with Eq::{not_equal, equal}

///|
pub extend Value with Debug::{to_repr}

///|
/// 渲染成可读文本，供日志与 CSV 使用。
pub fn Value::text(self : Value) -> String {
  match self {
    Num(n) => n.to_string()
    Text(s) => s
    Missing => ""
  }
}

///|
pub fn Value::is_missing(self : Value) -> Bool {
  self is Missing
}

///|
pub fn Value::number(self : Value) -> Double? {
  match self {
    Num(n) => Some(n)
    _ => None
  }
}

///|
/// 一个数据项：名称 + 一个或多个取值。
///
/// 允许多个取值，因为现场协议里同一项的多次采样用逗号分隔，
/// 擅自只取第一个会丢数据。
pub(all) struct Field {
  name : String
  values : Array[Value]
}

///|
pub fn Field::new(name : String) -> Field {
  { name, values: [], }
}

///|
pub fn Field::first(self : Field) -> Value {
  if self.values.length() == 0 {
    Missing
  } else {
    self.values[0]
  }
}

///|
/// 这一项的全部数值（非数值取值被跳过）。
pub fn Field::numbers(self : Field) -> Array[Double] {
  let out : Array[Double] = []
  for v in self.values {
    match v {
      Num(n) => out.push(n)
      _ => ()
    }
  }
  out
}

///|
/// 整条数据的可信程度。
pub(all) enum Quality {
  /// 结构与语义均无问题
  Good
  /// 能解析，但有语义提示（字段数与版本不符、分包声明不一致等）
  Suspect
  /// 数据本身不可用（例如没有任何有效字段）
  Invalid
} derive(Eq, Debug)

///|
pub extend Quality with Eq::{not_equal, equal}

///|
pub extend Quality with Debug::{to_repr}

///|
pub fn Quality::label(self : Quality) -> String {
  match self {
    Good => "good"
    Suspect => "suspect"
    Invalid => "invalid"
  }
}

///|
/// 一个时序数据点：某一时刻、某个来源、某类测量下的一组字段。
///
/// 字段名不预设任何行业字典：`a34013-Rtd`、`cpu_load`、`temp_c`
/// 在这里地位相同。上层想解释监测因子编码，是上层的事。
pub(all) struct Point {
  timestamp : String
  source : String
  measurement : String
  fields : Array[Field]
  mut quality : Quality
}

///|
pub fn Point::new(
  timestamp : String,
  source : String,
  measurement : String,
) -> Point {
  { timestamp, source, measurement, fields: [], quality: Good, }
}

///|
/// 追加一个取值。同名项会归到同一个 Field 下，不覆盖先前的值。
pub fn Point::add(self : Point, name : String, value : Value) -> Unit {
  let mut i = 0
  while i < self.fields.length() {
    if self.fields[i].name == name {
      self.fields[i].values.push(value)
      return
    }
    i = i + 1
  }
  let field = Field::new(name)
  field.values.push(value)
  self.fields.push(field)
}

///|
pub fn Point::field(self : Point, name : String) -> Field? {
  for f in self.fields {
    if f.name == name {
      return Some(f)
    }
  }
  None
}

///|
/// 取某个字段的第一个数值。缺失、文本、字段不存在都返回 None。
pub fn Point::number(self : Point, name : String) -> Double? {
  match self.field(name) {
    Some(f) => f.first().number()
    None => None
  }
}

///|
pub fn Point::field_count(self : Point) -> Int32 {
  self.fields.length()
}

///|
pub fn Point::count_values(self : Point) -> Int32 {
  let mut n = 0
  for f in self.fields {
    for v in f.values {
      match v {
        Missing => ()
        _ => n = n + 1
      }
    }
  }
  n
}

///|
pub fn Point::set_quality(self : Point, quality : Quality) -> Unit {
  self.quality = quality
}

///|
/// 把一个数据区的全部项追加进来（分包重组后的合并数据区用得上）。
pub fn Point::add_area(self : Point, area : DataArea) -> Unit {
  for item in area.items {
    for raw in item.values {
      self.add(item.name, parse_value(raw))
    }
  }
}

// ---------------------------------------------------------------------------
// HJ 212 adapter
//
// 从这里往下才涉及具体协议。把 frame 翻译成 Point 时保留三件事：
//   - 时间戳优先用 QN 解析出的规范形式，解析不了就保留原文，绝不丢弃；
//   - 数据区每一项按值本身决定类型，不按字段名猜；
//   - 语义层面的问题降级为 Suspect，而不是把整条数据扔掉。
// ---------------------------------------------------------------------------

///|
fn parse_value(text : String) -> Value {
  let t = trim_text(text)
  if t == "" {
    return Missing
  }
  match parse_float_text(t) {
    Some(n) => Num(n)
    None => Text(t)
  }
}

///|
/// 把一条 HJ 212 报文转成协议无关的数据点。
pub fn Frame::to_point(self : Frame) -> Point {
  let seg = self.segment
  let timestamp = match QnTime::parse(seg.qn) {
    Some(t) => t.text()
    None => seg.qn
  }
  let point = Point::new(timestamp, seg.mn, seg.cn)
  for item in seg.cp.items {
    for raw in item.values {
      point.add(item.name, parse_value(raw))
    }
  }
  if seg.validate().length() > 0 {
    point.set_quality(Suspect)
  }
  if point.count_values() == 0 {
    point.set_quality(Invalid)
  }
  point
}

///|
/// 批量转换，跳过解不出来或重组后不完整的报文。
pub fn points_from_frames(frames : Array[Frame]) -> Array[Point] {
  let out : Array[Point] = []
  for frame in frames {
    out.push(frame.to_point())
  }
  out
}
