// 多格式导出测试。
//
// 重点在转义：JSON 里的引号与控制字符、CSV 的公式注入、
// Influx tag 里的空格。这些错了不会报错，只会产出别人解析不了
// 或者在表格软件里被执行的数据。

///|
fn sample_point() -> Point {
  let p = Point::new("2024-01-15T10:30:00", "sensor-01", "cpu")
  p.add("load", Num(0.5))
  p.add("status", Text("N"))
  p.add("spare", Missing)
  p
}

///|
test "JSON 输出含全部元信息与字段" {
  let j = sample_point().to_json()
  assert_true(j.contains("\"timestamp\":\"2024-01-15T10:30:00\""))
  assert_true(j.contains("\"source\":\"sensor-01\""))
  assert_true(j.contains("\"measurement\":\"cpu\""))
  assert_true(j.contains("\"quality\":\"good\""))
  assert_true(j.contains("\"load\":[0.5]"))
  assert_true(j.contains("\"status\":[\"N\"]"))
  assert_true(j.contains("\"spare\":[null]"))
}

///|
test "JSON 转义引号、反斜杠、换行与控制字符" {
  let p = Point::new("t", "s", "m")
  p.add("note", Text("a\"b\\c\nd\te\u{01}f"))
  let j = p.to_json()
  assert_true(j.contains("\\\""))
  assert_true(j.contains("\\\\"))
  assert_true(j.contains("\\n"))
  assert_true(j.contains("\\t"))
  assert_true(j.contains("\\u0001"))
  // 原文里的裸换行不该出现，否则一行 JSON 会被截断
  assert_false(j.contains("c\nd"))
}

///|
test "中文字段名与取值原样保留" {
  let p = Point::new("t", "s", "m")
  p.add("Info", Text("备用通道"))
  assert_true(p.to_json().contains("备用通道"))
}

///|
test "CSV 表头与数据行" {
  let cols : Array[String] = ["load", "status", "spare"]
  let h = csv_header(cols)
  assert_eq(h, "timestamp,source,measurement,quality,load,status,spare")
  let row = sample_point().to_csv_row(cols)
  assert_eq(row, "2024-01-15T10:30:00,sensor-01,cpu,good,0.5,N,")
}

///|
test "CSV 公式注入被阻断" {
  let p = Point::new("=1+2", "s", "m")
  p.add("x", Text("@SUM(A1:A9)"))
  let row = p.to_csv_row(["x"])
  assert_true(row.has_prefix("'=1+2"))
  assert_true(row.contains("'@SUM(A1:A9)"))
}

///|
test "CSV 逗号、引号、换行被正确包裹" {
  let p = Point::new("t", "s", "m")
  p.add("x", Text("a,b"))
  p.add("y", Text("say \"hi\""))
  p.add("z", Text("line1\nline2"))
  let row = p.to_csv_row(["x", "y", "z"])
  assert_true(row.contains("\"a,b\""))
  assert_true(row.contains("\"say \"\"hi\"\"\""))
  assert_true(row.contains("\"line1\nline2\""))
}

///|
test "完整 CSV 用 CRLF 且只有一行表头" {
  let points : Array[Point] = [sample_point(), sample_point()]
  let csv = to_csv(points, ["load"])
  assert_true(csv.has_prefix("timestamp,source,measurement,quality,load\r\n"))
  let mut count = 0
  for c in csv {
    if c == '\n' {
      count = count + 1
    }
  }
  assert_eq(count, 3)
}

///|
test "NDJSON 每点一行" {
  let points : Array[Point] = [sample_point(), sample_point()]
  let s = to_ndjson(points)
  let mut lines = 0
  for c in s {
    if c == '\n' {
      lines = lines + 1
    }
  }
  assert_eq(lines, 2)
  assert_true(s.has_prefix("{"))
}

///|
test "Influx line protocol 转义 tag 空格" {
  let p = Point::new("t", "sensor 1", "cpu")
  p.add("load", Num(0.5))
  p.add("note", Text("ok"))
  let line = p.to_influx_line()
  assert_true(line.has_prefix("cpu,source=sensor\\ 1 "))
  assert_true(line.contains("load=0.5"))
  assert_true(line.contains("note=\"ok\""))
  // 刻意不带时间戳，避免把毫秒精度伪装成纳秒
  assert_false(line.contains("1705"))
}

///|
test "空数据点也能产出合法 line protocol" {
  let line = Point::new("t", "s", "m").to_influx_line()
  assert_true(line.contains("field_count=0"))
}

///|
test "Format 解析与别名" {
  assert_true(Format::parse("json") is Some(_))
  assert_true(Format::parse("JSONL") is Some(_))
  assert_true(Format::parse("lineprotocol") is Some(_))
  assert_eq(Format::parse("???"), None)
  assert_eq(Json.label(), "json")
  assert_eq(Ndjson.label(), "ndjson")
  assert_eq(Csv.label(), "csv")
  assert_eq(Influx.label(), "influx")
}

///|
test "render_all 四种格式都可输出" {
  let points : Array[Point] = [sample_point()]
  let cols : Array[String] = ["load"]
  assert_true(render_all(points, Json, cols).has_prefix("["))
  assert_true(render_all(points, Ndjson, cols).has_prefix("{"))
  assert_true(render_all(points, Csv, cols).has_prefix("timestamp,"))
  assert_true(render_all(points, Influx, cols).contains("load=0.5"))
  assert_eq(render_all([], Json, cols), "[]")
}
