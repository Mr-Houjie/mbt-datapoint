// 分包重组测试。
//
// 分包是现场上报历史数据时的常态（一段日数据动辄几十分包）。这里重点
// 验证的不是「收齐了能拼对」，而是各种不齐的情况：缺包、重包、跨组、
// 组内总包数前后不一致——这些在现场都会遇到，且都不会有明显报错。

///|
fn make_split(
  qn : String,
  mn : String,
  total : Int32,
  pno : Int32,
  name : String,
  value : String,
) -> Frame {
  let area = DataArea::new()
  area.set(name, value)
  {
    segment: {
      qn,
      st: "32",
      cn: "2051",
      pw: "100000",
      mn,
      flag: Flag::new(V2017, true, true),
      pnum: Some(total),
      pno: Some(pno),
      cp: area,
      extra: [],
    },
  }
}

///|
test "分包乱序到达，收齐后按包号顺序拼接" {
  let r = Reassembler::new()
  // 故意按 3、1、2 的顺序喂
  let a = r.push(make_split("20240115103000123", "MN01", 3, 3, "c", "3"))
  match a {
    Pending(got, total) => {
      assert_eq(got, 1)
      assert_eq(total, 3)
    }
    _ => fail("第 1 帧应为 Pending")
  }
  let _ = r.push(make_split("20240115103000123", "MN01", 3, 1, "a", "1"))
  let last = r.push(make_split("20240115103000123", "MN01", 3, 2, "b", "2"))
  match last {
    Complete(area) => {
      assert_eq(area.length(), 3)
      // 拼接顺序必须按包号，不是按到达顺序
      assert_eq(area.items[0].name, "a")
      assert_eq(area.items[1].name, "b")
      assert_eq(area.items[2].name, "c")
    }
    _ => fail("收齐后应为 Complete")
  }
  // 收齐后自动清空，可以接着收下一组
  assert_eq(r.received(), 0)
}

///|
test "缺包时能报出缺哪些包号" {
  let r = Reassembler::new()
  let _ = r.push(make_split("20240115103000123", "MN01", 5, 1, "a", "1"))
  let _ = r.push(make_split("20240115103000123", "MN01", 5, 3, "c", "3"))
  assert_eq(r.missing(), [2, 4, 5])
  assert_eq(r.received(), 2)
  assert_eq(r.total(), 5)
}

///|
test "上一组没齐就换组，计入 dropped" {
  let r = Reassembler::new()
  let _ = r.push(make_split("20240115103000123", "MN01", 3, 1, "a", "1"))
  assert_eq(r.dropped(), 0)
  // QN 变了，说明是另一条逻辑报文
  let _ = r.push(make_split("20240115104000123", "MN01", 2, 1, "x", "1"))
  assert_eq(r.dropped(), 1)
  assert_eq(r.received(), 1)
  assert_eq(r.total(), 2)
}

///|
test "上一组已收齐再换组不算丢弃" {
  let r = Reassembler::new()
  let _ = r.push(make_split("20240115103000123", "MN01", 2, 1, "a", "1"))
  let _ = r.push(make_split("20240115103000123", "MN01", 2, 2, "b", "2"))
  let _ = r.push(make_split("20240115104000123", "MN01", 2, 1, "x", "1"))
  assert_eq(r.dropped(), 0)
}

///|
test "包号重复被拒绝" {
  let r = Reassembler::new()
  let _ = r.push(make_split("20240115103000123", "MN01", 3, 1, "a", "1"))
  match r.push(make_split("20240115103000123", "MN01", 3, 1, "a", "1")) {
    Conflict(reason) => assert_true(reason.contains("重复"))
    _ => fail("重复包号应报 Conflict")
  }
}

///|
test "包号越界被拒绝" {
  let r = Reassembler::new()
  match r.push(make_split("20240115103000123", "MN01", 3, 4, "d", "4")) {
    Conflict(reason) => assert_true(reason.contains("超出"))
    _ => fail("PNO > PNUM 应报 Conflict")
  }
  match r.push(make_split("20240115103000123", "MN01", 3, 0, "z", "0")) {
    Conflict(_) => ()
    _ => fail("PNO=0 应报 Conflict")
  }
  // 被拒绝的帧不该进缓冲区
  assert_eq(r.received(), 0)
}

///|
test "同组内 PNUM 前后不一致被拒绝" {
  let r = Reassembler::new()
  let _ = r.push(make_split("20240115103000123", "MN01", 3, 1, "a", "1"))
  match r.push(make_split("20240115103000123", "MN01", 4, 2, "b", "2")) {
    Conflict(reason) => assert_true(reason.contains("PNUM"))
    _ => fail("PNUM 不一致应报 Conflict")
  }
}

///|
test "非分包帧不参与重组" {
  let r = Reassembler::new()
  let frame : Frame = {
    segment: {
      qn: "20240115103000123",
      st: "32",
      cn: "2051",
      pw: "100000",
      mn: "MN01",
      flag: Flag::new(V2017, false, true),
      pnum: None,
      pno: None,
      cp: DataArea::new(),
      extra: [],
    },
  }
  match r.push(frame) {
    NotSplit => ()
    _ => fail("未声明分包的帧应为 NotSplit")
  }
}

///|
test "声明分包却缺 PNUM 报冲突" {
  let r = Reassembler::new()
  let frame : Frame = {
    segment: {
      qn: "20240115103000123",
      st: "32",
      cn: "2051",
      pw: "100000",
      mn: "MN01",
      flag: Flag::new(V2017, true, true),
      pnum: None,
      pno: None,
      cp: DataArea::new(),
      extra: [],
    },
  }
  match r.push(frame) {
    Conflict(reason) => assert_true(reason.contains("PNUM"))
    _ => fail("缺 PNUM 应报 Conflict")
  }
}

///|
test "同名项在分包间重复出现时原样保留" {
  // 每个分包通常都自带 DataTime。重组不做去重，保证可追溯。
  let r = Reassembler::new()
  let _ = r.push(make_split("20240115103000123", "MN01", 2, 1, "DataTime", "1"))
  let done = r.push(make_split("20240115103000123", "MN01", 2, 2, "DataTime", "2"))
  match done {
    Complete(area) => {
      assert_eq(area.length(), 2)
      assert_eq(area.get_all("DataTime"), ["1", "2"])
    }
    _ => fail("应为 Complete")
  }
}
