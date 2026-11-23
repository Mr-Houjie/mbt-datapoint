// 加密链路的端到端验证。
//
// 这是「加密上报 → 可用数据点」的完整案例，用 HJ 212-2025 附录 A.2 的
// 原文示例跑通，不用自拟样本：
//
//   明文内容 → SM4-ECB 加密 → 组装加密报文（示例 2 的形态，长度与 CRC
//   按明文算）→ 按 CN 判定属于加密范围 → 注入的外部组件解密 → 用明文
//   复核 CRC → 解析字段 → 产出数据点 → 三种格式输出
//
// 任何一环理解偏了都会在这里失败：加密范围差一个字节、尾部明文规则
// 处理错、长度/CRC 改成按密文算——都不可能同时通过。

///|
/// 标准 A.2 的示例密钥：16 个 0x30。
const SEC_KEY_HEX : String = "30303030303030303030303030303030"

///|
const SEC_PREFIX : String = "QN=20240520210700000;ST=31;CN=2051;PW=123456;MN=010000A8900016F000169DC0;Flag=9;CP=&&"

///|
/// 示例 1 的加密内容（208 字符 = 13 组）。
const SEC_CONTENT : String = "DataTime=20240520210600;a01011-Min=1.35,a01011-Avg=1.35,a01011-Max=1.35,a01011-Flag=N;a01012-Min=9.3,a01012-Avg=9.3,a01012-Max=9.3,a01012-Flag=N;a01014-Min=3.20,a01014-Avg=3.211,a01014-Max=3.212,a01014-Flag=N"

///|
/// 示例 2 的密文（208 字节），标准原文。
const SEC_CIPHER_HEX : String = "E43E159ACFAB242CB53155FB8B9281A1A242577ABFAED881BE88B72D69FC55ED1A80119FAAC8B3CD33D285CC76F57F2CA7F88B9573C6647E0F07E24609BD6B63EB20C5B9784F28E71D2F4994FF61D9E1C2B3075592B4D1E09C4D8BB27BE97B559E3DA6643781A6F477769DEEB009B10DFFF3426922725D607DC4480F0CAC5F70DB2587B124BCB281592721D6E4BC180A97E5E111499CBE822E31C8D7761553543AA24207C290997BBDE64F9266BC5F529A172E381C1D898CA1A0D771A914A7B2D7467C70B94F1D4A7B0350A48DBF8B41"

///|
fn sec_ascii(s : String) -> Array[Byte] {
  let out : Array[Byte] = []
  for c in s {
    out.push(c.to_int().to_byte())
  }
  out
}

///|
fn sec_cat(a : Array[Byte], b : Array[Byte]) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = 0
  while i < a.length() {
    out.push(a[i])
    i = i + 1
  }
  let mut j = 0
  while j < b.length() {
    out.push(b[j])
    j = j + 1
  }
  out
}

///|
fn sec_hex_of(b : Array[Byte]) -> String {
  let digits = "0123456789ABCDEF"
  let cs : Array[Char] = []
  for c in digits {
    cs.push(c)
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < b.length() {
    let v = b[i].to_int() & 0xFF
    sb.write_char(cs[(v >> 4) & 0xF])
    sb.write_char(cs[v & 0xF])
    i = i + 1
  }
  sb.to_string()
}

///|
fn sec_pad4(v : Int32) -> String {
  let d = v.to_string()
  let sb = StringBuilder()
  let mut i = d.length()
  while i < 4 {
    sb.write_char('0')
    i = i + 1
  }
  sb.write_string(d)
  sb.to_string()
}

///|
/// 跑一遍完整加密链路，返回是否全部通过。
fn secure_demo() -> Bool {
  let mut ok = true

  println("加密接入  HJ 212-2025 6.4.2 / 6.4.4 / 附录 A.2")
  println("  密钥          16 字节（标准示例用 16 个 0x30）")
  println("  算法          SM4 · ECB · Nopadding")
  println("  加密范围      数据段 \"CP=&&\" 之后到结尾 \"&&\" 之前")
  println("  加密单位      每 16 字符一组，不足一组的部分保持明文")
  println("")

  // [1] 命令编码判定
  let cn = 2051
  let need = @lib.requires_cipher(cn)
  println("  [1] 命令编码 \{cn} → \{(if need { "属于加密范围（2000~2999）" } else { "无需加密" })}")
  if !need {
    println("      FAIL：按 6.4.4 该命令应加密")
    ok = false
  }

  // [2] 加密：内容 → 密文，与标准示例 2 比对
  let cipher = match @sm4.Sm4::from_hex(SEC_KEY_HEX) {
    Some(c) => c
    None => {
      println("      FAIL：密钥构造失败")
      return false
    }
  }
  let content = sec_ascii(SEC_CONTENT)
  let enc = match cipher.encrypt_ecb(content) {
    Some(v) => v
    None => {
      println("      FAIL：加密失败")
      return false
    }
  }
  let same_as_standard = sec_hex_of(enc) == SEC_CIPHER_HEX
  println("  [2] 内容 \{content.length()} 字符 → 密文 \{enc.length()} 字节")
  println(
    "      与标准示例 2 逐字节比对  \{(if same_as_standard { "一致 ✓" } else { "不一致 ✗" })}",
  )
  if !same_as_standard {
    ok = false
  }

  // [3] 组装加密报文：长度与 CRC 均按明文
  let seg = "\{SEC_PREFIX}\{SEC_CONTENT}&&"
  let frame_text = "##\{sec_pad4(@lib.utf8_len(seg))}\{seg}\{@lib.crc16_hex(seg)}\r\n"
  let raw_cipher_frame = sec_cat(
    sec_cat(sec_ascii("##\{sec_pad4(@lib.utf8_len(seg))}\{SEC_PREFIX}"), enc),
    sec_ascii("&&\{@lib.crc16_hex(seg)}\r\n"),
  )
  println("  [3] 组装加密报文")
  println("      长度字段     \{sec_pad4(@lib.utf8_len(seg))}（按明文计，不是按密文）")
  println("      CRC          \{@lib.crc16_hex(seg)}（按明文算）")
  println("      链路字节     \{raw_cipher_frame.length()} 字节（与明文报文等长）")
  let plain_frame = sec_ascii(frame_text)
  if raw_cipher_frame.length() != plain_frame.length() {
    println("      FAIL：Nopadding 下密文报文应与明文报文等长")
    ok = false
  }

  // [4] 解密并复核
  let decryptor = cipher.decryptor()
  let decoded = match @lib.Frame::decode_bytes(raw_cipher_frame, decryptor) {
    Ok(f) => f
    Err(e) => {
      println("      FAIL：解密解码失败 \{e.kind()} / \{e.message()}")
      return false
    }
  }
  let plain_decoded = match @lib.Frame::decode_bytes(plain_frame, fn(_) { None }) {
    Ok(f) => f
    Err(e) => {
      println("      FAIL：明文对照解码失败 \{e.message()}")
      return false
    }
  }
  let same_segment = decoded.segment.text() == plain_decoded.segment.text()
  println("  [4] 解密 → 数据段 \{@lib.utf8_len(decoded.segment.text())} 字节")
  println(
    "      与示例 1（明文）逐字符比对  \{(if same_segment { "一致 ✓" } else { "不一致 ✗" })}",
  )
  println("      CRC 复核     \{@lib.crc16_hex(decoded.segment.text())}（用明文重算，与报文声明相符）")
  if !same_segment {
    ok = false
  }

  // 无组件时必须报 CipherRequired，而不是含糊的 CRC 错误
  match @lib.Frame::decode_bytes(raw_cipher_frame, fn(_) { None }) {
    Ok(_) => {
      println("      FAIL：未配组件却解码成功")
      ok = false
    }
    Err(e) => {
      println("      未配组件时     \{e.kind()} —— \{e.message()}")
      if e.kind() != "CipherRequired" {
        ok = false
      }
    }
  }

  // [5] 数据点
  let points = @lib.points_from_frames([decoded])
  println("  [5] 产出数据点 \{points.length()} 个")
  let sb = StringBuilder()
  for p in points {
    sb.write_string("      ")
    sb.write_string(p.to_influx_line())
    sb.write_string("\n")
  }
  println(sb.to_string())

  // [6] 三种格式输出
  let json = @lib.to_ndjson(points)
  let csv = @lib.to_csv(points, ["a01011-Min", "a01014-Avg"])
  let influx = {
    let s = StringBuilder()
    for p in points {
      s.write_string(p.to_influx_line())
      s.write_string("\n")
    }
    s.to_string()
  }
  println("  [6] 三种格式输出")
  println("      json         \{@lib.utf8_len(json)} 字节")
  println("      csv          \{@lib.utf8_len(csv)} 字节")
  println("      influx       \{@lib.utf8_len(influx)} 字节")
  if @lib.utf8_len(json) == 0 || @lib.utf8_len(csv) == 0 || @lib.utf8_len(influx) == 0 {
    println("      FAIL：存在空输出")
    ok = false
  }
  println(
    "  结果          \{(if ok { "通过" } else { "失败" })}",
  )
  ok
}
