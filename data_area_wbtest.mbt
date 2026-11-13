// 数据区取值与数值解析的测试。
//
// 数值解析是「看起来最简单、实际最容易放宽过头」的一块：把 `N` 当 0、
// 把 `1.2.3` 读成 1.2，都会让上层拿到一个看似正常、实际不存在的数。

///|
test "取整数：正负号与非法值" {
  let area = DataArea::new()
  area.set("a", "30")
  area.set("b", "-1")
  area.set("c", "+7")
  area.set("d", "N")
  area.set("e", "1.5")
  assert_eq(area.get_int("a"), Some(30))
  assert_eq(area.get_int("b"), Some(-1))
  assert_eq(area.get_int("c"), Some(7))
  // 无有效数据必须是 None，不能悄悄变成 0
  assert_eq(area.get_int("d"), None)
  assert_eq(area.get_int("e"), None)
  assert_eq(area.get_int("missing"), None)
}

///|
test "取浮点：标准里的常见写法" {
  let area = DataArea::new()
  area.set("a34013-Rtd", "1.52")
  area.set("neg", "-3.00")
  area.set("int", "0")
  area.set("dot_first", ".5")
  area.set("dot_last", "5.")
  area.set("bad", "N")
  assert_eq(area.get_float("a34013-Rtd"), Some(1.52))
  assert_eq(area.get_float("neg"), Some(-3.0))
  assert_eq(area.get_float("int"), Some(0.0))
  assert_eq(area.get_float("dot_first"), Some(0.5))
  assert_eq(area.get_float("dot_last"), Some(5.0))
  assert_eq(area.get_float("bad"), None)
}

///|
test "浮点解析不做事后容错" {
  let area = DataArea::new()
  area.set("a", "1.2.3")
  area.set("b", "12a")
  area.set("c", "-")
  area.set("d", ".")
  area.set("e", "1e5")
  // 科学计数法不在标准的数值类型里，拒绝而不是猜
  for name in ["a", "b", "c", "d", "e"] {
    assert_eq(area.get_float(name), None)
  }
}

///|
test "get_or 提供默认值" {
  let area = DataArea::new()
  area.set("DataTime", "20240115103000")
  assert_eq(area.get_or("DataTime", "?"), "20240115103000")
  assert_eq(area.get_or("Info", "（无）"), "（无）")
}

///|
test "remove 删除字段并返回是否命中" {
  let area = DataArea::new()
  area.set("a", "1")
  area.set("b", "2")
  assert_true(area.remove("a"))
  assert_eq(area.length(), 1)
  assert_eq(area.get("a"), None)
  assert_eq(area.get("b"), Some("2"))
  assert_false(area.remove("a"))
}
