// 命令行层的测试。库层测的是「生成的字节对不对」，这里测的是
// 「写进标准输出后还对不对」——两者之间隔着运行时对行尾的处理，
// CSV 的 `\r\r\n` 就是从这道缝里漏出去的。

///|
test "unify_eol 把 CRLF 折成 LF" {
  assert_eq(unify_eol("a\r\nb\r\n"), "a\nb\n")
}

///|
test "unify_eol 不动单独的 LF 和单独的 CR" {
  assert_eq(unify_eol("a\nb"), "a\nb")
  assert_eq(unify_eol("a\rb"), "a\rb")
}

///|
test "unify_eol 处理混合与连续空行" {
  assert_eq(unify_eol("a\r\n\r\nb"), "a\n\nb")
  assert_eq(unify_eol("\r\n"), "\n")
  assert_eq(unify_eol(""), "")
}

///|
test "unify_eol 不会把已是 LF 的内容改坏" {
  let src = "x\ny\nz"
  assert_eq(unify_eol(src), src)
}

///|
// 这是那个缺陷的回归断言：库层 to_csv 按 RFC 4180 返回 CRLF，
// 归一化之后送进 println，磁盘上才不会出现 \r\r\n。
test "库层 CSV 的 CRLF 经归一化后只剩 LF" {
  let p = @lib.Point::new("t", "s", "m")
  p.add("load", @lib.Num(0.5))
  let csv = @lib.to_csv([p], ["load"])
  assert_true(csv.contains("\r\n"))
  let sent = unify_eol(csv)
  assert_false(sent.contains("\r"))
  assert_true(sent.has_prefix("timestamp,source,measurement,quality,load\n"))
}

///|
test "失败回显的报文不带行尾" {
  // 坏帧回显时 raw 带着原报文的 \r\n，去掉才不会在 Windows 上打出 \r\r\n
  let raw = "##0101QN=x1C81\r\n"
  assert_eq(trim_tail(raw), "##0101QN=x1C81")
  assert_false(trim_tail(raw).contains("\r"))
}
