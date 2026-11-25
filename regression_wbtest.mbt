// 代码审查（2026-11-26）发现的缺陷的回归测试。
//
// 这一批不是「功能测试」，而是「曾经真的错了」的记录。每一条都对应一次
// 实测：改坏之前用探测代码看到过垃圾值或静默丢弃，改好之后这里必须通过。
// 单独放一个文件，是为了让后来的人一眼看出这些边界值不是随手写的。

///|
test "回归：整数溢出必须报 None，不能翻成垃圾值" {
  // 修复前实测：99999999999 -> 1215752191，2147483648 -> -2147483648。
  // 这些值会一路流到包号比较与 Flag 位域判断里。
  let over = ["99999999999", "2147483648", "99999999999999999999", "-2147483649"]
  for raw in over {
    let area = DataArea::new()
    area.set("v", raw)
    match area.get_int("v") {
      None => ()
      Some(v) => fail("\{raw} 应拒绝，实际得到 \{v}")
    }
  }
  // 边界本身必须还能过，否则就是矫枉过正。
  let max = DataArea::new()
  max.set("v", "2147483647")
  match max.get_int("v") {
    Some(v) => assert_eq(v, 2147483647)
    None => fail("2147483647 是合法上界，不应拒绝")
  }
  let neg = DataArea::new()
  neg.set("v", "-2147483647")
  match neg.get_int("v") {
    Some(v) => assert_eq(v, -2147483647)
    None => fail("-2147483647 合法")
  }
  let plain = DataArea::new()
  plain.set("v", "+42")
  match plain.get_int("v") {
    Some(v) => assert_eq(v, 42)
    None => fail("+42 应识别为 42")
  }
}

///|
test "回归：数据段超 9999 字节不可编码" {
  // 修复前：encode 会输出 5 位长度字段（##12086...），自己解不回来。
  let area = DataArea::new()
  let big = StringBuilder()
  let mut i = 0
  while i < 12000 {
    big.write_char('a')
    i = i + 1
  }
  area.set("x", big.to_string())
  let seg = Segment::parse(
    "QN=20240520210600;ST=31;CN=2011;PW=123456;MN=010000A8900016F000169DC0;Flag=9;CP=&&\{area.text()}&&",
  ).unwrap()
  let frame = { segment: seg }
  assert_false(frame.can_encode())
  match frame.encode_checked() {
    Ok(_) => fail("超长却编码成功")
    Err(e) => {
      assert_eq(e.kind(), "TooLong")
      assert_true(e.message().contains("12086"))
      assert_true(e.message().contains("9999"))
    }
  }
}

///|
test "回归：9999 字节边界仍可编码并可解回" {
  // 上一条的反面：恰好在限内必须能走通，否则等于把边界砍错了。
  let head = "QN=20240520210600;ST=31;CN=2011;PW=123456;MN=010000A8900016F000169DC0;Flag=9;CP=&&"
  // segment 总长 = head + "x=" + n 个 'a' + "&&"，令其为 9999
  let n = 9999 - utf8_len(head) - 2 - 2
  let sb = StringBuilder()
  let mut i = 0
  while i < n {
    sb.write_char('a')
    i = i + 1
  }
  let area = DataArea::new()
  area.set("x", sb.to_string())
  let seg = Segment::parse("\{head}\{area.text()}&&").unwrap()
  let frame = { segment: seg }
  assert_eq(utf8_len(frame.segment.text()), 9999)
  assert_true(frame.can_encode())
  let text = frame.encode()
  // 长度字段必须是 4 位十进制，且正好 9999
  assert_eq(slice_chars(chars_of(text), 2, 6), "9999")
  match Frame::decode(text) {
    Ok(back) => assert_eq(utf8_len(back.segment.text()), 9999)
    Err(e) => fail("边界长度编码后解不回：\{e.kind()} / \{e.message()}")
  }
}

///|
test "回归：decode_all 不能静默丢掉末尾残帧" {
  // 修复前：decode_all("##0010QN=2024") 返回 0 个事件，调用方以为没有帧。
  let ev = decode_all("##0016QN=2024")
  assert_eq(ev.length(), 1)
  match ev[0] {
    Bad(e, raw) => {
      assert_eq(e.kind(), "Truncated")
      assert_eq(raw, "##0016QN=2024")
    }
    _ => fail("残帧应报 Bad")
  }
  // 纯噪声没有帧头，仍按 Noise 抛，不该被误报成残帧。
  let noise = decode_all("hello")
  assert_eq(noise.length(), 1)
  match noise[0] {
    Noise(s) => assert_eq(s, "hello")
    _ => fail("纯噪声应报 Noise")
  }
  // 完整单帧仍只有一条 Good，不该被追加残帧事件。
  let seg = Segment::parse(
    "QN=20240520210600;ST=31;CN=2011;PW=123456;MN=010000A8900016F000169DC0;Flag=9;CP=&&&&",
  ).unwrap()
  let ok = decode_all({ segment: seg }.encode())
  assert_eq(ok.length(), 1)
  match ok[0] {
    Good(_) => ()
    _ => fail("完整帧应报 Good")
  }
}

///|
test "回归：PNUM/PNO 按标准「字符 6」限制在 999999 内" {
  let mk = fn(pnum : String) -> String {
    "QN=20240520210600;ST=31;CN=2011;PW=123456;MN=010000A8900016F000169DC0;Flag=10;PNUM=\{pnum};PNO=1;CP=&&&&"
  }
  // 合法上界
  match Segment::parse(mk("999999")) {
    Ok(s) =>
      match s.pnum {
        Some(v) => assert_eq(v, 999999)
        None => fail("PNUM 应被解析出来")
      }
    Err(e) => fail("999999 应通过：\{e.message()}")
  }
  // 超一位就该拒——否则 Reassembler::missing 会被拖进百万级循环
  match Segment::parse(mk("1000000")) {
    Ok(_) => fail("1000000 应被拒")
    Err(e) => assert_eq(e.kind(), "BadFieldValue")
  }
  match Segment::parse(mk("2147483647")) {
    Ok(_) => fail("2147483647 应被拒")
    Err(e) => assert_eq(e.kind(), "BadFieldValue")
  }
}

///|
test "回归：missing 在大 total 下仍按包号正确返回" {
  let seg = match Segment::parse(
    "QN=20240520210600;ST=31;CN=2011;PW=123456;MN=010000A8900016F000169DC0;Flag=10;PNUM=999999;PNO=1;CP=&&&&",
  ) {
    Ok(s) => s
    Err(e) => abort(e.message())
  }
  let r = Reassembler::new()
  match r.push({ segment: seg }) {
    Pending(got, total) => {
      assert_eq(got, 1)
      assert_eq(total, 999999)
    }
    _ => fail("应为 Pending")
  }
  let m = r.missing()
  assert_eq(m.length(), 999998)
  // 第 1 包已收到，所以缺的第一个是 2，最后一个是 999999
  assert_eq(m[0], 2)
  assert_eq(m[m.length() - 1], 999999)
}

///|
test "回归：字段名校验公开可见" {
  let good = ["a01011-Avg", "Data-Flag", "x_1", "A"]
  for n in good {
    assert_true(is_valid_field_name(n))
  }
  let bad = ["a b", "a=b", "a,b", "a;b", "", "中文"]
  for n in bad {
    assert_false(is_valid_field_name(n))
  }
}

///|
test "回归：Pipeline::pending 能看出末尾残帧" {
  // run 是一次性入口，残片既不出数据点也不进 rejected。没有这个访问器，
  // 调用方无法区分「文本里没有报文」和「末尾被截断」。
  let p = Pipeline::new(RuleSet::new(), Ndjson, [])
  let _ = p.feed("##0016QN=2024")
  assert_eq(p.pending(), 13)
  // 完整帧不该留下残余
  let seg = match Segment::parse(
    "QN=20240520210600;ST=31;CN=2011;PW=123456;MN=010000A8900016F000169DC0;Flag=9;CP=&&&&",
  ) {
    Ok(s) => s
    Err(e) => abort(e.message())
  }
  let q = Pipeline::new(RuleSet::new(), Ndjson, [])
  let _ = q.feed({ segment: seg }.encode())
  assert_eq(q.pending(), 0)
}
