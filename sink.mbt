// 多格式导出。
//
// 解析出来的数据如果不能接进现有系统，就只是又一种内部对象。
// 这一层把 Point 渲染成日志系统、数据库、时序库都能直接吃的格式，
// 全部手写、零依赖，保持 native / wasm / js 后端行为一致。
//
// 安全上两处必须做对：
//   - JSON 字符串里的引号、反斜杠、控制字符必须转义；
//   - CSV 单元格以 = + - @ 开头时会被表格软件当公式执行，要加前缀阻断。

///|
pub(all) enum Format {
  Json
  Ndjson
  Csv
  Influx
}

///|
pub impl Eq for Format with fn equal(self : Format, other : Format) -> Bool {
  self.label() == other.label()
}

///|
pub extend Format with Eq::{not_equal, equal}

///|
pub fn Format::parse(text : String) -> Format? {
  match trim_text(text).to_lower() {
    "json" => Some(Json)
    "ndjson" | "jsonl" => Some(Ndjson)
    "csv" => Some(Csv)
    "influx" | "line" | "lineprotocol" => Some(Influx)
    _ => None
  }
}

///|
pub fn Format::label(self : Format) -> String {
  match self {
    Json => "json"
    Ndjson => "ndjson"
    Csv => "csv"
    Influx => "influx"
  }
}

///|
/// JSON 字符串转义。控制字符统一走 \u00XX，避免生成不可打印的输出。
fn json_escape(s : String) -> String {
  let sb = StringBuilder()
  sb.write_char('"')
  for c in s {
    let cp = c.to_int()
    if c == '"' {
      sb.write_string("\\\"")
    } else if c == '\\' {
      sb.write_string("\\\\")
    } else if cp == 10 {
      sb.write_string("\\n")
    } else if cp == 13 {
      sb.write_string("\\r")
    } else if cp == 9 {
      sb.write_string("\\t")
    } else if cp < 32 {
      sb.write_string("\\u00\{pad_hex2(cp)}")
    } else {
      sb.write_char(c)
    }
  }
  sb.write_char('"')
  sb.to_string()
}

///|
fn value_json(v : Value) -> String {
  match v {
    Num(n) => n.to_string()
    Text(s) => json_escape(s)
    Missing => "null"
  }
}

///|
fn field_json(f : Field) -> String {
  let sb = StringBuilder()
  sb.write_char('[')
  let mut i = 0
  while i < f.values.length() {
    if i > 0 {
      sb.write_char(',')
    }
    sb.write_string(value_json(f.values[i]))
    i = i + 1
  }
  sb.write_char(']')
  sb.to_string()
}

///|
/// 渲染成一行 JSON 对象。
pub fn Point::to_json(self : Point) -> String {
  let sb = StringBuilder()
  sb.write_string("{\"timestamp\":")
  sb.write_string(json_escape(self.timestamp))
  sb.write_string(",\"source\":")
  sb.write_string(json_escape(self.source))
  sb.write_string(",\"measurement\":")
  sb.write_string(json_escape(self.measurement))
  sb.write_string(",\"quality\":")
  sb.write_string(json_escape(self.quality.label()))
  sb.write_string(",\"fields\":{")
  let mut i = 0
  while i < self.fields.length() {
    if i > 0 {
      sb.write_char(',')
    }
    sb.write_string(json_escape(self.fields[i].name))
    sb.write_char(':')
    sb.write_string(field_json(self.fields[i]))
    i = i + 1
  }
  sb.write_string("}}")
  sb.to_string()
}

///|
/// 每个数据点一行 JSON，适合流式写入日志文件。
pub fn to_ndjson(points : Array[Point]) -> String {
  let sb = StringBuilder()
  for p in points {
    sb.write_string(p.to_json())
    sb.write_char('\n')
  }
  sb.to_string()
}

///|
/// CSV 单元格转义。
///
/// 含逗号、引号、换行的值要整体加引号并把引号翻倍；以 = + - @ 或
/// 制表符 / 回车开头的值要加单引号前缀，防止 Excel / WPS 把它当公式。
fn csv_cell(text : String) -> String {
  let mut guarded = text
  if text.length() > 0 {
    let first = text[0]
    if first == '=' ||
      first == '+' ||
      first == '-' ||
      first == '@' ||
      first == '\t' ||
      first == '\r' {
      guarded = "'" + text
    }
  }
  let needs_quote = guarded.contains(",") ||
    guarded.contains("\"") ||
    guarded.contains("\n") ||
    guarded.contains("\r")
  if !needs_quote {
    return guarded
  }
  let sb = StringBuilder()
  sb.write_char('"')
  for c in guarded {
    if c == '"' {
      sb.write_string("\"\"")
    } else {
      sb.write_char(c)
    }
  }
  sb.write_char('"')
  sb.to_string()
}

///|
/// CSV 表头。columns 是调用方指定的字段列，顺序即输出顺序。
pub fn csv_header(columns : Array[String]) -> String {
  let cells : Array[String] = ["timestamp", "source", "measurement", "quality"]
  for c in columns {
    cells.push(c)
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < cells.length() {
    if i > 0 {
      sb.write_char(',')
    }
    sb.write_string(csv_cell(cells[i]))
    i = i + 1
  }
  sb.to_string()
}

///|
/// CSV 数据行（不含表头）。
pub fn Point::to_csv_row(self : Point, columns : Array[String]) -> String {
  let cells : Array[String] = [
    self.timestamp,
    self.source,
    self.measurement,
    self.quality.label(),
  ]
  for name in columns {
    match self.field(name) {
      Some(f) => cells.push(f.first().text())
      None => cells.push("")
    }
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < cells.length() {
    if i > 0 {
      sb.write_char(',')
    }
    sb.write_string(csv_cell(cells[i]))
    i = i + 1
  }
  sb.to_string()
}

///|
/// 完整 CSV（含表头，每行以 \r\n 结尾，符合 RFC 4180）。
pub fn to_csv(points : Array[Point], columns : Array[String]) -> String {
  let sb = StringBuilder()
  sb.write_string(csv_header(columns))
  sb.write_string("\r\n")
  for p in points {
    sb.write_string(p.to_csv_row(columns))
    sb.write_string("\r\n")
  }
  sb.to_string()
}

///|
/// InfluxDB line protocol 的 tag 转义。
fn influx_escape(s : String) -> String {
  let sb = StringBuilder()
  for c in s {
    if c == ' ' || c == ',' || c == '=' {
      sb.write_char('\\')
    }
    sb.write_char(c)
  }
  sb.to_string()
}

///|
/// 渲染成一行 InfluxDB line protocol。
///
/// 两处刻意为之：
///   - **不带时间戳**：QN 是本地时钟且精度只有毫秒，硬转成纳秒会制造
///     一个看起来精确、实际不可信的时间。需要原始采样时间请用 NDJSON。
///   - **缺失值整对省略**，不写 `field=0`。line protocol 没有 null，
///     但补一个 0 等于编造数据，下游分不清「没采到」和「采到就是 0」。
pub fn Point::to_influx_line(self : Point) -> String {
  let sb = StringBuilder()
  sb.write_string(influx_escape(self.measurement))
  sb.write_string(",source=")
  sb.write_string(influx_escape(self.source))
  sb.write_char(' ')
  let mut written = 0
  for f in self.fields {
    for v in f.values {
      // 缺失的值整对跳过，不写 field=0。
      // line protocol 没有 null，但写 0 是**编造数据**——0 是一个合法的
      // 测量值，下游拿到分不清「传感器没采到」和「采到就是 0」。这正是
      // 本库把 Missing 与 Num(0) 分开的原因，不能在这一层又混回去。
      match v {
        Missing => ()
        _ => {
          if written > 0 {
            sb.write_char(',')
          }
          sb.write_string(influx_escape(f.name))
          sb.write_char('=')
          match v {
            Num(n) => sb.write_string(n.to_string())
            Text(s) => sb.write_string(json_escape(s))
            Missing => ()
          }
          written = written + 1
        }
      }
    }
  }
  // line protocol 不允许只有 tag 没有 field，给一个占位计数
  if written == 0 {
    sb.write_string("field_count=0")
  }
  sb.to_string()
}

///|
/// 按格式渲染单个数据点的一行。
pub fn render_line(
  point : Point,
  format : Format,
  columns : Array[String],
) -> String {
  match format {
    Json | Ndjson => point.to_json()
    Csv => point.to_csv_row(columns)
    Influx => point.to_influx_line()
  }
}

///|
/// 按格式批量渲染。
pub fn render_all(
  points : Array[Point],
  format : Format,
  columns : Array[String],
) -> String {
  match format {
    Json =>
      if points.length() == 0 {
        "[]"
      } else {
        let sb = StringBuilder()
        sb.write_char('[')
        let mut i = 0
        while i < points.length() {
          if i > 0 {
            sb.write_char(',')
          }
          sb.write_string("\n  ")
          sb.write_string(points[i].to_json())
          i = i + 1
        }
        sb.write_string("\n]")
        sb.to_string()
      }
    Ndjson => to_ndjson(points)
    Csv => to_csv(points, columns)
    Influx => {
      let sb = StringBuilder()
      for p in points {
        sb.write_string(p.to_influx_line())
        sb.write_char('\n')
      }
      sb.to_string()
    }
  }
}
