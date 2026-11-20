// 错误分层的测试。
//
// 分层是给调用方做决策用的，所以断言的重点是「哪种错误落在哪一层」，
// 而不是字符串长什么样。一旦哪天调整了某个变体的归属，这里必须先改。

///|
test "帧层错误：包头、长度、CRC、包尾" {
  let frame_errors : Array[DecodeError] = [
    MissingHeader,
    BadLengthField("XXXX"),
    Truncated(100, 20),
    BadCrc("1C81", "1C80"),
    BadTail("xx"),
    EmptySegment,
    TrailingGarbage("abc"),
  ]
  for e in frame_errors {
    assert_true(e.is_structural())
    assert_eq(e.stage().label(), "帧层")
  }
}

///|
test "数据段层错误" {
  let segment_errors : Array[DecodeError] = [
    MissingField("MN"),
    DuplicateField("MN"),
    BadField("MN"),
    BadFieldValue("Flag", "abc"),
  ]
  for e in segment_errors {
    assert_false(e.is_structural())
    assert_eq(e.stage().label(), "数据段层")
  }
}

///|
test "数据区层错误" {
  let e = BadDataArea("缺少 &&")
  assert_false(e.is_structural())
  assert_eq(e.stage().label(), "数据区层")
}

///|
test "从真实报文得到的错误归属正确" {
  // 截断：帧层
  match Frame::decode("##0101QN=1") {
    Err(e) => assert_true(e.is_structural())
    Ok(_) => fail("应解码失败")
  }
  // 缺 MN：数据段层
  let no_mn = "QN=20240115103000123;ST=31;CN=2011;Flag=5;CP=&&a=1&&"
  match Segment::parse(no_mn) {
    Err(e) => {
      assert_false(e.is_structural())
      assert_eq(e.stage().label(), "数据段层")
    }
    Ok(_) => fail("缺 MN 应失败")
  }
  // CP 没有 && 包装：数据区层
  match Segment::parse("QN=1;ST=1;CN=1;MN=1;Flag=1;CP=a=1") {
    Err(e) => assert_eq(e.stage().label(), "数据区层")
    Ok(_) => fail("缺 && 包装应失败")
  }
}
