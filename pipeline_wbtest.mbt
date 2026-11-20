// 端到端管道测试。
//
// 管道是给上层用的那一层，所以断言写的是「从原始字节进去，
// 能不能直接拿到可入库的一行」，以及全程计数是否对得上。

///|
fn encoded_frame(s : Segment) -> String {
  let frame : Frame = { segment: s, }
  frame.encode()
}

///|
fn normal_segment() -> Segment raise {
  match Segment::parse(SAMPLE_SEGMENT) {
    Ok(s) => s
    Err(e) => fail(e.message())
  }
}

///|
fn split_segment(total : Int32, pno : Int32, name : String) -> Segment {
  let area = DataArea::new()
  area.set(name, "1")
  {
    qn: "20240115103000123",
    st: "32",
    cn: "2051",
    pw: "100000",
    mn: "010000A8900016F000169DC0",
    flag: Flag::new(V2017, true, true),
    pnum: Some(total),
    pno: Some(pno),
    rf: false,
    cp: area,
    extra: [],
  }
}

///|
test "一次喂入两条帧，输出两条可直接用的行" {
  let p = Pipeline::new(RuleSet::new(), Ndjson, [])
  let text = encoded_frame(normal_segment()) + encoded_frame(normal_segment())
  let outputs = p.feed(text)
  assert_eq(outputs.length(), 2)
  assert_true(outputs[0].line.contains("\"RtdInterval\":[30]"))
  assert_eq(p.stats().frames(), 2)
  assert_eq(p.stats().points(), 2)
  assert_eq(p.stats().rejected(), 0)
}

///|
test "半包跨两次 feed 仍能解出" {
  let p = Pipeline::new(RuleSet::new(), Json, [])
  let raw = encoded_frame(normal_segment())
  let cut = 12
  let cs = chars_of(raw)
  let first = slice_chars(cs, 0, cut)
  let second = slice_chars(cs, cut, cs.length())
  assert_eq(p.feed(first).length(), 0)
  let out = p.feed(second)
  assert_eq(out.length(), 1)
  assert_eq(p.stats().frames(), 1)
}

///|
test "坏帧计入 rejected，不中断后续帧" {
  let p = Pipeline::new(RuleSet::new(), Ndjson, [])
  let bad = "##0001XFFFF\r\n"
  let text = bad + encoded_frame(normal_segment())
  let outputs = p.feed(text)
  assert_eq(outputs.length(), 1)
  assert_eq(p.stats().rejected(), 1)
}

///|
test "规则在管道里生效并累计错误数" {
  let (rules, errors) = RuleSet::from_text("range RtdInterval 0 10\n")
  assert_eq(errors.length(), 0)
  let p = Pipeline::new(rules, Ndjson, [])
  let outputs = p.feed(encoded_frame(normal_segment()))
  assert_eq(outputs.length(), 1)
  assert_eq(outputs[0].findings.length(), 1)
  assert_eq(p.stats().errors(), 1)
}

///|
test "分包帧收齐后才输出一条合并数据点" {
  let p = Pipeline::new(RuleSet::new(), Ndjson, [])
  let a = encoded_frame(split_segment(2, 1, "x"))
  let b = encoded_frame(split_segment(2, 2, "y"))
  assert_eq(p.feed(a).length(), 0)
  assert_eq(p.stats().pending_parts, 1)
  let out = p.feed(b)
  assert_eq(out.length(), 1)
  assert_eq(out[0].point.field_count(), 2)
  assert_eq(out[0].point.number("x"), Some(1.0))
  assert_eq(out[0].point.number("y"), Some(1.0))
  assert_eq(p.stats().pending_parts, 0)
}

///|
test "统计文本与 JSON 都可读" {
  let p = Pipeline::new(RuleSet::new(), Csv, ["RtdInterval"])
  let _ = p.feed(encoded_frame(normal_segment()))
  assert_true(p.stats().text().contains("数据点 1"))
  assert_true(p.stats().to_json().contains("\"points\":1"))
  assert_eq(p.header(), "timestamp,source,measurement,quality,RtdInterval")
}

///|
test "run 一次性返回渲染结果" {
  let p = Pipeline::new(RuleSet::new(), Csv, ["RtdInterval"])
  let text = encoded_frame(normal_segment()) + encoded_frame(normal_segment())
  let out = p.run(text)
  assert_true(
    out.has_prefix("timestamp,source,measurement,quality,RtdInterval\r\n"),
  )
  assert_true(out.contains("30"))
  assert_eq(p.stats().points(), 2)
}

///|
test "run 输出 JSON 数组格式" {
  let p = Pipeline::new(RuleSet::new(), Json, [])
  let out = p.run(encoded_frame(normal_segment()))
  assert_true(out.has_prefix("[\n  {"))
  assert_true(out.contains("\"measurement\":\"1062\""))
}
