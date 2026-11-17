// 协议无关数据模型的测试。
//
// 重点不是「能存值」，而是三个容易悄悄丢数据的地方：
// 同名多值不覆盖、空值不等于 0、语义可疑时降级而非丢弃。

///|
test "手工构造数据点，同名多值不覆盖" {
  let p = Point::new("2024-01-15T10:30:00", "sensor-01", "cpu")
  p.add("load", Num(0.5))
  p.add("load", Num(0.7))
  p.add("note", Text("ok"))
  assert_eq(p.field_count(), 2)
  assert_eq(p.count_values(), 3)
  match p.field("load") {
    Some(f) => {
      assert_eq(f.values.length(), 2)
      assert_eq(f.numbers(), [0.5, 0.7])
      assert_eq(f.first().number(), Some(0.5))
    }
    None => fail("load 应当存在")
  }
  assert_eq(p.number("load"), Some(0.5))
  assert_eq(p.number("note"), None)
  assert_eq(p.number("missing"), None)
}

///|
test "缺失与零是两回事" {
  let p = Point::new("t", "s", "m")
  p.add("zero", Num(0.0))
  p.add("empty", Missing)
  assert_eq(p.number("zero"), Some(0.0))
  assert_eq(p.number("empty"), None)
  assert_true(p.field("empty") is Some(_))
  assert_false(p.field("zero").unwrap().first().is_missing())
  assert_eq(p.count_values(), 1)
}

///|
test "Value 的文本渲染" {
  assert_eq(Num(1.5).text(), "1.5")
  assert_eq(Text("N").text(), "N")
  assert_eq(Missing.text(), "")
  assert_eq(Num(-3.0).number(), Some(-3.0))
  assert_eq(Text("12").number(), None)
}

///|
test "HJ 212 报文转成数据点" {
  match Frame::decode(SAMPLE_FRAME) {
    Err(e) => fail(e.message())
    Ok(frame) => {
      let p = frame.to_point()
      assert_eq(p.source, "010000A8900016F000169DC0")
      assert_eq(p.measurement, "1062")
      assert_eq(p.number("RtdInterval"), Some(30.0))
      // QN 能解析成时间戳，应当用规范形式而不是原始的 17 位数字
      assert_true(p.timestamp != "20160801085857223")
    }
  }
}

///|
test "数据区里的文本与空值按值本身判定类型" {
  let seg = "QN=20240115103000123;ST=32;CN=2011;PW=123456;MN=010000A8900016F000169DC0;Flag=5;CP=&&DataTime=20240115103000;a34013-Rtd=1.52;a34013-Flag=N;Info=;Note=备用通道&&"
  match Segment::parse(seg) {
    Err(e) => fail(e.message())
    Ok(s) => {
      let area = s.cp
      let p = Point::new("t", "s", "m")
      p.add_area(area)
      assert_eq(p.number("a34013-Rtd"), Some(1.52))
      // N 是设备状态码，不是「没有值」，原样保留为文本
      match p.field("a34013-Flag") {
        Some(f) => assert_eq(f.first(), Text("N"))
        None => fail("a34013-Flag 应当存在")
      }
      assert_true(p.field("Info") is Some(_))
      assert_eq(p.field("Info").unwrap().first(), Missing)
      match p.field("Note") {
        Some(f) => assert_eq(f.first(), Text("备用通道"))
        None => fail("Note 应当存在")
      }
    }
  }
}

///|
test "语义有问题的帧降级为 suspect，不是丢弃" {
  // MN 只有 4 位，与 2017 版要求的 24 位不符，validate 会报提示
  let seg = "QN=20240115103000123;ST=32;CN=2011;PW=123456;MN=ABCD;Flag=5;CP=&&a=1&&"
  match Segment::parse(seg) {
    Err(e) => fail(e.message())
    Ok(s) => {
      let frame : Frame = { segment: s, }
      let p = frame.to_point()
      assert_eq(p.quality, Suspect)
      assert_eq(p.number("a"), Some(1.0))
    }
  }
}

///|
test "没有任何有效取值时标为 invalid" {
  let s = match
    Segment::parse("QN=20240115103000123;ST=32;CN=2011;MN=1;Flag=5;CP=&&&&") {
    Ok(v) => v
    Err(e) => fail(e.message())
  }
  let p : Frame = { segment: s, }
  assert_eq(p.to_point().quality, Invalid)
}

///|
test "批量转换保留全部报文" {
  let frames : Array[Frame] = []
  match Frame::decode(SAMPLE_FRAME) {
    Ok(f) => {
      frames.push(f)
      frames.push(f)
    }
    Err(e) => fail(e.message())
  }
  assert_eq(points_from_frames(frames).length(), 2)
}
