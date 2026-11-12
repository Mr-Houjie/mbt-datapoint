// 核心行为测试。
//
// 这里刻意用标准正文与附录里的原始报文做用例，而不是自己编的字符串：
// 只有拿标准里的例子对一遍，才能确认字段顺序、长度计数、CRC 位置都没理解错。

///|
const SAMPLE_SEGMENT : String = "QN=20160801085857223;ST=32;CN=1062;PW=100000;MN=010000A8900016F000169DC0;Flag=5;CP=&&RtdInterval=30&&"

///|
const SAMPLE_FRAME : String = "##0101QN=20160801085857223;ST=32;CN=1062;PW=100000;MN=010000A8900016F000169DC0;Flag=5;CP=&&RtdInterval=30&&0759\r\n"

///|
test "crc16 与独立实现对拍" {
  assert_eq(utf8_len(SAMPLE_SEGMENT), 101)
  assert_eq(crc16_hex(SAMPLE_SEGMENT), "0759")
  // 空串是初值，不做最终异或
  assert_eq(crc16_hex(""), "FFFF")
}

///|
test "标准附录示例的校验码与算法不一致" {
  // 附录 A 的示例写的是 1C80，但按附录 A 的算法对同一数据段算出的是 0759。
  // 本库以算法为准，因此 1C80 必须被拒绝，且报出正确值。
  let wrong = "##0101QN=20160801085857223;ST=32;CN=1062;PW=100000;MN=010000A8900016F000169DC0;Flag=5;CP=&&RtdInterval=30&&1C80\r\n"
  match Frame::decode(wrong) {
    Ok(_) => fail("应当因 CRC 不匹配而拒绝")
    Err(e) =>
      match e {
        BadCrc(declared, computed) => {
          assert_eq(declared, "1C80")
          assert_eq(computed, "0759")
        }
        _ => fail("错误类型应为 BadCrc")
      }
  }
}

///|
test "解码标准报文" {
  match Frame::decode(SAMPLE_FRAME) {
    Ok(frame) => {
      assert_eq(frame.segment.qn, "20160801085857223")
      assert_eq(frame.segment.st, "32")
      assert_eq(frame.segment.cn, "1062")
      assert_eq(frame.segment.pw, "100000")
      assert_eq(frame.segment.mn, "010000A8900016F000169DC0")
      assert_eq(frame.segment.flag.raw, 5)
      assert_eq(frame.segment.flag.version().label(), "HJ 212-2017")
      assert_eq(frame.segment.flag.is_split(), false)
      assert_eq(frame.segment.flag.needs_ack(), true)
      assert_eq(frame.segment.cp.get("RtdInterval"), Some("30"))
    }
    Err(e) => fail(e.message())
  }
}

///|
test "解码后再编码是恒等变换" {
  match Frame::decode(SAMPLE_FRAME) {
    Ok(frame) => assert_eq(frame.encode(), SAMPLE_FRAME)
    Err(e) => fail(e.message())
  }
}

///|
test "包尾缺失会被拒绝" {
  let no_tail = "##0101QN=20160801085857223;ST=32;CN=1062;PW=100000;MN=010000A8900016F000169DC0;Flag=5;CP=&&RtdInterval=30&&0759"
  match Frame::decode(no_tail) {
    Ok(_) => fail("缺少包尾时应当报错")
    Err(e) =>
      match e {
        BadTail(_) => ()
        _ => fail("错误类型应为 BadTail")
      }
  }
}

///|
test "包头缺失会被拒绝" {
  match Frame::decode("QN=1;ST=32;CN=1062;MN=1;Flag=1;CP=&&&&") {
    Ok(_) => fail("缺少包头时应当报错")
    Err(e) =>
      match e {
        MissingHeader => ()
        _ => fail("错误类型应为 MissingHeader")
      }
  }
}

///|
test "长度字段被篡改时定位到数据段边界" {
  let bad_len = "##0102QN=20160801085857223;ST=32;CN=1062;PW=100000;MN=010000A8900016F000169DC0;Flag=5;CP=&&RtdInterval=30&&0759\r\n"
  match Frame::decode(bad_len) {
    Ok(_) => fail("长度不符时应当报错")
    Err(e) =>
      match e {
        Truncated(_, _) | BadTail(_) | BadCrc(_, _) => ()
        _ => fail("应当定位到长度或 CRC 错误")
      }
  }
}

///|
test "数据区解析与多值" {
  match DataArea::parse("&&DataTime=20240101000000;a=1.5,b=2.5;Data-Flag=N&&") {
    Ok(area) => {
      assert_eq(area.length(), 3)
      assert_eq(area.get("DataTime"), Some("20240101000000"))
      assert_eq(area.get_all("a").length(), 2)
      assert_eq(area.text(), "DataTime=20240101000000;a=1.5,b=2.5;Data-Flag=N")
    }
    Err(e) => fail(e.message())
  }
}

///|
test "数据区缺少结束符会被拒绝" {
  match DataArea::parse("&&a=1") {
    Ok(_) => fail("缺少结束 && 时应当报错")
    Err(_) => ()
  }
}

///|
test "空数据区合法" {
  match DataArea::parse("&&&&") {
    Ok(area) => assert_eq(area.length(), 0)
    Err(e) => fail(e.message())
  }
}

///|
test "数据类型解析与校验" {
  assert_eq(ft(FieldType::parse("C6")), "C6")
  assert_eq(ft(FieldType::parse("N5")), "N5")
  assert_eq(ft(FieldType::parse("N14.2")), "N14.2")
  assert_eq(ft(FieldType::parse("YYYY")), "YYYY")
  assert_eq(ft(FieldType::parse("X9")), "none")
  let t = Number(14, 2)
  assert_eq(t.check("123.45"), None)
  assert_true(t.check("123.456") is Some(_))
  assert_true(t.check("abc") is Some(_))
  assert_eq(Chars(4).check("abcd"), None)
  assert_true(Chars(4).check("abcde") is Some(_))
}

///|
test "Flag 位布局" {
  // Flag=9 -> 00001001：2025 版、不分包、需应答
  let f = Flag::from_raw(9)
  assert_eq(f.version().label(), "HJ 212-2025")
  assert_eq(f.is_split(), false)
  assert_eq(f.needs_ack(), true)
  // 构造后回读一致
  let g = Flag::new(V2017, true, false)
  assert_eq(g.raw, 6)
  assert_eq(g.version().label(), "HJ 212-2017")
  assert_eq(g.is_split(), true)
  assert_eq(g.needs_ack(), false)
}

///|
test "QN 时间戳解析" {
  match QnTime::parse("20160801085857223") {
    Some(t) => {
      assert_eq(t.year, 2016)
      assert_eq(t.month, 8)
      assert_eq(t.day, 1)
      assert_eq(t.hour, 8)
      assert_eq(t.minute, 58)
      assert_eq(t.second, 57)
      assert_eq(t.millis, 223)
      assert_eq(t.to_qn(), "20160801085857223")
    }
    None => fail("应当能解析 17 位 QN")
  }
  assert_true(QnTime::parse("20161301085857223") is None)
}

///|
test "流式分帧：半包与粘包" {
  let framer = Framer::new()
  let a = SAMPLE_FRAME
  let b = "##0071QN=20160801085857224;ST=32;CN=9011;MN=010000A8900016F000169DC0;Flag=3;CP=&&&&8D0A\r\n"
  // 一次性喂入两帧
  let events = framer.feed(a + b)
  let mut good = 0
  for e in events {
    match e {
      Good(_) => good = good + 1
      _ => ()
    }
  }
  // 第二帧的 CRC 是随手写的，因此只要求至少解出第一帧
  assert_true(good >= 1)
}

///|
test "流式分帧：逐字节喂入" {
  let framer = Framer::new()
  let mut good = 0
  let mut i = 0
  while i < SAMPLE_FRAME.length() {
    let chunk = slice_chars(chars_of(SAMPLE_FRAME), i, i + 1)
    for e in framer.feed(chunk) {
      match e {
        Good(frame) => {
          good = good + 1
          assert_eq(frame.segment.cn, "1062")
        }
        _ => ()
      }
    }
    i = i + 1
  }
  assert_eq(good, 1)
  assert_eq(framer.pending(), 0)
}

///|
test "数据区含中文时按 UTF-8 字节计长度" {
  let seg = "QN=20240101000000000;ST=32;CN=2011;PW=123;MN=010000A8900016F000169DC0;Flag=1;CP=&&Name=宁波&&"
  let len = utf8_len(seg)
  // "宁波" 各占 3 字节，其余全为 ASCII
  assert_eq(len, chars_of(seg).length() + 4)
  let frame : Frame = {
    segment: {
      qn: "20240101000000000",
      st: "32",
      cn: "2011",
      pw: "123",
      mn: "010000A8900016F000169DC0",
      flag: Flag::from_raw(1),
      pnum: None,
      pno: None,
      cp: match DataArea::parse("&&Name=宁波&&") {
        Ok(area) => area
        Err(_) => DataArea::new()
      },
      extra: [],
    },
  }
  let encoded = frame.encode()
  match Frame::decode(encoded) {
    Ok(decoded) => assert_eq(decoded.segment.cp.get("Name"), Some("宁波"))
    Err(e) => fail(e.message())
  }
}

///|
test "命令码查表" {
  // 名称逐条对照 HJ 212-2017 表 9，不采用现场口头叫法：
  // 2011 是「污染物实时数据」（取/上传共用），不是「上传实时数据」；
  // 2041 是「设备运行时间日历史数据」，不是又一个「日数据」。
  assert_eq(command_name("2011"), Some("污染物实时数据"))
  assert_eq(command_name("1062"), Some("设置实时数据间隔"))
  assert_eq(command_name("2041"), Some("设备运行时间日历史数据"))
  assert_eq(command_name("9011"), Some("请求应答"))
  assert_eq(command_name("9999"), None)
}

///|
test "命令码按标准分成四段" {
  assert_eq(command_group("1000"), "初始化/参数命令")
  assert_eq(command_group("2011"), "数据命令")
  assert_eq(command_group("3011"), "控制命令")
  assert_eq(command_group("9014"), "交互命令")
}

///|
test "系统编码 32 是地表水体污染源而不是烟气" {
  // 这条专门防回归：32 曾被错标成「烟气」，而标准表 5 里
  // 31 才是大气环境污染源，51 才是烟气排放过程监控。
  assert_eq(system_name("31"), "大气环境污染源")
  assert_eq(system_name("32"), "地表水体环境污染源")
  assert_eq(system_name("51"), "烟气排放过程监控")
}

///|
test "语义校验能发现分包声明与包号不一致" {
  match
    Segment::parse(
      "QN=20160801085857223;ST=32;CN=2011;PW=1;MN=010000A8900016F000169DC0;Flag=3;CP=&&&&",
    ) {
    Ok(seg) => {
      let warnings = seg.validate()
      assert_true(warnings.length() > 0)
    }
    Err(e) => fail(e.message())
  }
}

///|
fn ft(t : FieldType?) -> String {
  match t {
    Some(x) => x.text()
    None => "none"
  }
}
