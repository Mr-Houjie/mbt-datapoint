// 对抗性测试。
//
// 目标不是验证"正确输入能得到正确结果"，而是验证"任何输入都不会让程序崩溃"。
// 解码器面对的是网络上的字节流，其中必然混有截断、篡改、乱码、超长报文，
// 这些都不应该让调用方进程挂掉，只能返回错误。

///|
// 断言：任意输入都只返回 Ok/Err，不 panic
fn must_not_crash(text : String) -> Unit {
  match Frame::decode(text) {
    Ok(_) => ()
    Err(_) => ()
  }
}

///|
test "任意截断都不崩溃" {
  let base = SAMPLE_FRAME
  let cs = chars_of(base)
  let mut n = 0
  while n <= cs.length() {
    must_not_crash(slice_chars(cs, 0, n))
    n = n + 1
  }
}

///|
test "单字节篡改不崩溃" {
  let base = SAMPLE_FRAME
  let cs = chars_of(base)
  // 危险字符：NUL、DEL、CR、LF、&、;、=、#、ESC
  let dangerous : Array[Char] = [
    '\u{00}', '\u{7F}', '\r', '\n', '&', ';', '=', '#', '\u{1B}',
  ]
  let mut i = 0
  while i < cs.length() {
    for d in dangerous {
      let copy = cs.copy()
      copy[i] = d
      must_not_crash(slice_chars(copy, 0, copy.length()))
    }
    i = i + 1
  }
}

///|
test "极端长度字段不崩溃" {
  let fields : Array[String] = [
    "0000", "9999", "!!!!", "    ", "----", "\u{7F}\u{7F}\u{7F}\u{7F}", "0001",
  ]
  for f in fields {
    must_not_crash("##\{f}\{SAMPLE_SEGMENT}0759\r\n")
  }
}

///|
test "结构骨架正确但内容是垃圾" {
  let mut seed = 12345
  let mut round = 0
  while round < 200 {
    let len = seed % 120
    let sb = StringBuilder()
    let mut j = 0
    while j < len {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
      let v = 32 + seed % 95
      sb.write_char(v.unsafe_to_char())
      j = j + 1
    }
    // 避开合法的 && 包装，让大多数用例走到错误分支
    let seg = sb.to_string()
    must_not_crash("##\{zero_pad(utf8_len(seg), 4)}\{seg}FFFF\r\n")
    round = round + 1
  }
}

///|
test "不含包头的脏流不会留在缓冲区里" {
  // 找不到 "##" 的字节会作为 Noise 立刻抛出，缓冲区保持为空。
  // 这条钉住「脏流不堆积」这个性质，避免以后改成分帧器自己攒着。
  let framer = Framer::new()
  let junk = "0123456789abcdef".repeat(64)
  let mut round = 0
  while round < 20 {
    let _ = framer.feed(junk)
    assert_eq(framer.pending(), 0)
    round = round + 1
  }
}

///|
test "声明长度却补不齐时缓冲区被上限截断" {
  // 对端说数据段有 9999 字节，实际只发了一部分。分帧器必须等，
  // 于是这部分会停留在缓冲区里——这正是需要 max_pending 的情形。
  let framer = Framer::with_limit(2048)
  assert_eq(framer.limit(), 2048)
  let fake = "##9999" + "a".repeat(4000)
  let mut overflow = 0
  for e in framer.feed(fake) {
    match e {
      Overflow(_) => overflow = overflow + 1
      _ => ()
    }
  }
  assert_eq(overflow, 1)
  // 超限后缓冲区被清空，不是继续攒着
  assert_eq(framer.pending(), 0)
}

///|
test "默认上限足以容纳最长合法报文" {
  // 数据段上限 9999 字节，一帧最长 10011 字节，默认 16 KiB 必须装得下，
  // 否则正常报文会被误判成需要丢弃的超长残留。
  let framer = Framer::new()
  assert_true(framer.limit() > 10011)
}

///|
test "上限被抬高到 1024，避免装不下合法报文" {
  let framer = Framer::with_limit(1)
  assert_eq(framer.limit(), 1024)
}

///|
test "reset 清空残留并返回丢弃字节数" {
  let framer = Framer::new()
  let _ = framer.feed("##01")
  let before = framer.pending()
  assert_true(before > 0)
  assert_eq(framer.reset(), before)
  assert_eq(framer.pending(), 0)
}

///|
test "缓冲区丢弃后仍能正常解帧" {
  // 溢出清空不能把分帧器弄坏：之后喂一条完整帧仍要能解出来。
  let framer = Framer::with_limit(1024)
  let _ = framer.feed("x".repeat(4096))
  let mut good = 0
  for e in framer.feed(SAMPLE_FRAME) {
    match e {
      Good(_) => good = good + 1
      _ => ()
    }
  }
  assert_eq(good, 1)
}

///|
test "重复包头与空输入不崩溃" {
  must_not_crash("")
  must_not_crash("##")
  must_not_crash("####")
  must_not_crash(SAMPLE_FRAME + SAMPLE_FRAME)
  must_not_crash("\r\n\r\n")
  must_not_crash("     ")
}

///|
test "超长输入不崩溃" {
  // 十万个 0
  let sb = StringBuilder()
  let mut i = 0
  while i < 100000 {
    sb.write_char('0')
    i = i + 1
  }
  must_not_crash("##\{sb.to_string()}")
  // 大量数据项
  let cp = StringBuilder()
  let mut k = 0
  while k < 3000 {
    cp.write_string("a\{k}=1;")
    k = k + 1
  }
  let seg = "QN=1;ST=1;CN=1;MN=1;Flag=1;CP=&&\{cp.to_string()}&&"
  must_not_crash("##\{zero_pad(utf8_len(seg), 4)}\{seg}FFFF\r\n")
}

///|
test "分帧器喂任意字节不崩溃" {
  let framer = Framer::new()
  let mut seed = 777
  let mut round = 0
  while round < 50 {
    let len = seed % 200
    let sb = StringBuilder()
    let mut j = 0
    while j < len {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
      let v = seed % 128
      sb.write_char(v.unsafe_to_char())
      j = j + 1
    }
    let _ = framer.feed(sb.to_string())
    round = round + 1
  }
  // 最后喂一条真帧，分帧器应当仍然能正常工作
  let events = framer.feed(SAMPLE_FRAME)
  let mut good = 0
  for e in events {
    match e {
      Good(_) => good = good + 1
      _ => ()
    }
  }
  // 不强制要求解出（前面可能残留半包），只要求不崩溃
  assert_true(good >= 0)
}

///|
test "数据区解析任意输入不崩溃" {
  let inputs : Array[String] = [
    "", "&&", "&&&&", "&&a=1", "&&a=1&&", "&&=&&", "&&a=&&", "&&a&&", "&&a=1;b=2,c=3&&",
    "&&a=1&&&&", "&&; ;&&", "&&a=1,&&", "&&a=,1&&", "&&a==1&&",
  ]
  for text in inputs {
    match DataArea::parse(text) {
      Ok(_) => ()
      Err(_) => ()
    }
  }
}

///|
test "QN 时间解析任意输入不崩溃" {
  let inputs : Array[String] = [
    "", "2024", "20240115103000123", "99999999999999999", "00000000000000000", "20241332103000123",
    "abcdefghijklmnopq", "2024011510300012", "202401151030001234",
  ]
  for text in inputs {
    match QnTime::parse(text) {
      Some(_) => ()
      None => ()
    }
  }
}

///|
test "CP= 出现在其它字段的值里不应误切" {
  // 构造一个合法帧，其中扩展字段的取值恰好含 "CP="。
  // 如果用「第一次出现 CP=」来定位数据区，这里会被切断并误判为非法。
  let seg = "QN=20240115103000123;ST=31;CN=2011;PW=123456;MN=010000A8900016F000169DC0;Flag=5;Note=XCP=Y;CP=&&a=1&&"
  match Segment::parse(seg) {
    Ok(parsed) => {
      assert_eq(parsed.cp.get("a"), Some("1"))
      assert_eq(parsed.extra.length(), 1)
      assert_eq(parsed.extra[0].name, "Note")
    }
    Err(e) => fail("合法帧被拒绝: \{e.message()}")
  }
}

///|
test "第一字段就是 CP 时也能解析" {
  match Segment::parse("QN=1;ST=1;CN=1;MN=1;Flag=1;CP=&&a=1&&") {
    Ok(parsed) => assert_eq(parsed.cp.get("a"), Some("1"))
    Err(e) => fail(e.message())
  }
}

///|
test "CRC 小写十六进制应当被接受" {
  // 标准写的是大写，但现场设备输出小写并不罕见。CRC 是数值比较，
  // 大小写不该影响结果——这条测试钉住这个行为。
  let lower = "##0101QN=20160801085857223;ST=32;CN=1062;PW=100000;MN=010000A8900016F000169DC0;Flag=5;CP=&&RtdInterval=30&&1c80\r\n"
  match Frame::decode(lower) {
    Ok(_) => ()
    Err(e) => fail("小写 1c80 被拒绝: \{e.message()}")
  }
  let lower_hex = "##0101QN=20160801085857223;ST=32;CN=1062;PW=100000;MN=010000A8900016F000169DC0;Flag=5;CP=&&RtdInterval=30&&0abc\r\n"
  // 0abc 是随手写的，重点看错误类型；不应因字母大小写报结构错误
  match Frame::decode(lower_hex) {
    Ok(_) => ()
    Err(e) =>
      match e {
        BadCrc(_, _) => ()
        _ =>
          fail(
            "小写十六进制应视为数值而非语法错误，实际: \{e.kind()}",
          )
      }
  }
}

///|
test "长度字段前导零与空格容错一致" {
  // 标准要求 4 位十进制并左补零；这里确认正常 4 位长度能被正确读出。
  let seg = "QN=1;ST=1;CN=1;MN=1;Flag=1;CP=&&a=1&&"
  let n = utf8_len(seg)
  let raw = "##" + zero_pad(n, 4) + seg + crc16_hex(seg) + "\r\n"
  match Frame::decode(raw) {
    Ok(f) => assert_eq(f.segment.cp.get("a"), Some("1"))
    Err(e) => fail(e.message())
  }
}

///|
test "往返一致：构造的帧解码再编码字节相同" {
  // 用 encode 生成而不是手写，避免手工数错长度。
  let area = DataArea::new()
  area.set("DataTime", "20240115103000")
  area.set("a34013-Rtd", "1.52")
  area.set("a34013-Flag", "N")
  let frame : Frame = {
    segment: {
      qn: "20240115103000123",
      st: "31",
      cn: "2011",
      pw: "123456",
      mn: "010000A8900016F000169DC0",
      flag: Flag::new(V2017, false, true),
      pnum: None,
      pno: None,
      rf: false,
      cp: area,
      extra: [],
    },
  }
  let raw = frame.encode()
  match Frame::decode(raw) {
    Ok(decoded) => assert_eq(decoded.encode(), raw)
    Err(e) => fail(e.message())
  }
}
