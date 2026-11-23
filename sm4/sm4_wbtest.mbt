// SM4 参考实现的自测。
//
// 测试向量全部来自 HJ 212-2025 附录 A.2，不是自拟样本。这一组测试的作用
// 不只是「证明 SM4 写对了」，更是**用标准原文反向确认三件事同时理解正确**：
//
//   1. 加密范围是 `CP=&&` 之后到最后一个 `&&` 之前
//   2. 每 16 个字符一组，不足 16 字符的尾部保持明文
//   3. 密钥是 16 个 0x30（即 ASCII 的 "0000000000000000"）
//
// 任何一条理解偏了，密文都不可能逐字节对上。

///|
const A2_KEY_HEX : String = "30303030303030303030303030303030"

///|
/// 示例 1 的加密内容（208 字符，正好 13 组）。
const A2_EX1_CONTENT : String = "DataTime=20240520210600;a01011-Min=1.35,a01011-Avg=1.35,a01011-Max=1.35,a01011-Flag=N;a01012-Min=9.3,a01012-Avg=9.3,a01012-Max=9.3,a01012-Flag=N;a01014-Min=3.20,a01014-Avg=3.211,a01014-Max=3.212,a01014-Flag=N"

///|
/// 示例 2 的密文（208 字节）。
const A2_EX2_CIPHER_HEX : String = "E43E159ACFAB242CB53155FB8B9281A1A242577ABFAED881BE88B72D69FC55ED1A80119FAAC8B3CD33D285CC76F57F2CA7F88B9573C6647E0F07E24609BD6B63EB20C5B9784F28E71D2F4994FF61D9E1C2B3075592B4D1E09C4D8BB27BE97B559E3DA6643781A6F477769DEEB009B10DFFF3426922725D607DC4480F0CAC5F70DB2587B124BCB281592721D6E4BC180A97E5E111499CBE822E31C8D7761553543AA24207C290997BBDE64F9266BC5F529A172E381C1D898CA1A0D771A914A7B2D7467C70B94F1D4A7B0350A48DBF8B41"

///|
/// 示例 3 的加密内容（147 字符，前 144 加密，尾部 "g=N" 明文）。
const A2_EX3_CONTENT : String = "DataTime=20240520210600;a01011-Min=1.35,a01011-Avg=1.35,a01011-Max=1.35,a01011-Flag=N;a01014-Min=3.20,a01014-Avg=3.20,a01014-Max=3.20,a01014-Flag=N"

///|
/// 示例 4 的密文（144 字节）。
const A2_EX4_CIPHER_HEX : String = "E43E159ACFAB242CB53155FB8B9281A1A242577ABFAED881BE88B72D69FC55ED1A80119FAAC8B3CD33D285CC76F57F2CA7F88B9573C6647E0F07E24609BD6B63EB20C5B9784F28E71D2F4994FF61D9E13B391A1D2A454B65388D5D9435DBF021528C7BF9755EF16518710C0CAC0ADEF9C5156CD0A5A17674AC0ED2ABC40023E9EF70128554B82438E91ADCE98A0D03A4"

///|
/// GB/T 32907-2016 附录 A 的标准测试向量：
/// 密钥与明文均为 0123456789ABCDEFFEDCBA9876543210，密文如下。
const GB_KEY_HEX : String = "0123456789ABCDEFFEDCBA9876543210"

///|
fn hex_to_bytes(hex : String) -> Array[Byte] {
  let cs : Array[Char] = []
  for c in hex {
    cs.push(c)
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i + 1 < cs.length() {
    out.push((hex_digit_value(cs[i]) * 16 + hex_digit_value(cs[i + 1])).to_byte())
    i = i + 2
  }
  out
}

///|
fn bytes_to_hex(b : Array[Byte]) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < b.length() {
    let v = b[i].to_int() & 0xFF
    sb.write_char(hex_char((v >> 4) & 0xF))
    sb.write_char(hex_char(v & 0xF))
    i = i + 1
  }
  sb.to_string()
}

///|
fn hex_char(v : Int) -> Char {
  if v < 10 {
    (v + 48).unsafe_to_char()
  } else {
    (v - 10 + 65).unsafe_to_char()
  }
}

///|
/// ASCII 字符串转字节（测试用，输入全是 ASCII）。
fn ascii_bytes(s : String) -> Array[Byte] {
  let out : Array[Byte] = []
  for c in s {
    out.push(c.to_int().to_byte())
  }
  out
}

///|
test "SM4 复现 GB/T 32907 附录 A 的标准向量" {
  let cipher = Sm4::new(hex_to_bytes(GB_KEY_HEX)).unwrap()
  let plain = hex_to_bytes("0123456789ABCDEFFEDCBA9876543210")
  let want = "681EDF34D206965E86B3E94F536E4246"
  let got = cipher.encrypt_ecb(plain).unwrap()
  assert_eq(bytes_to_hex(got), want)
  let back = cipher.decrypt_ecb(got).unwrap()
  assert_eq(bytes_to_hex(back), "0123456789ABCDEFFEDCBA9876543210")
}

///|
test "SM4 复现 2025 附录 A.2 示例 2 的密文（208 字节，逐字节一致）" {
  let cipher = Sm4::new(hex_to_bytes(A2_KEY_HEX)).unwrap()
  let plain = ascii_bytes(A2_EX1_CONTENT)
  assert_eq(plain.length(), 208)
  let got = cipher.encrypt_ecb(plain).unwrap()
  assert_eq(got.length(), 208)
  assert_eq(bytes_to_hex(got), A2_EX2_CIPHER_HEX)
}

///|
test "SM4 复现 2025 附录 A.2 示例 4 的密文（144 字节 + 尾部 3 字符明文）" {
  let cipher = Sm4::new(hex_to_bytes(A2_KEY_HEX)).unwrap()
  let plain = ascii_bytes(A2_EX3_CONTENT)
  assert_eq(plain.length(), 147)
  let bulk = plain.length() / 16 * 16
  assert_eq(bulk, 144)
  let head = slice_bytes(plain, 0, bulk)
  let got = cipher.encrypt_ecb(head).unwrap()
  assert_eq(bytes_to_hex(got), A2_EX4_CIPHER_HEX)
  // 尾部不足一组的 3 个字符按标准保持明文
  assert_eq(slice_bytes(plain, bulk, plain.length()).length(), 3)
}

///|
test "示例 3 的尾部三个字符正是 g=N" {
  let plain = ascii_bytes(A2_EX3_CONTENT)
  let bulk = plain.length() / 16 * 16
  let tail = slice_bytes(plain, bulk, plain.length())
  assert_eq(tail.length(), 3)
  assert_eq(tail[0].to_int(), 103) // 'g'
  assert_eq(tail[1].to_int(), 61) // '='
  assert_eq(tail[2].to_int(), 78) // 'N'
}

///|
test "密钥长度不是 16 字节时构造失败" {
  assert_true(Sm4::new([]) is None)
  assert_true(Sm4::new(hex_to_bytes("30303030")) is None)
  assert_true(Sm4::new(hex_to_bytes(A2_KEY_HEX)) is Some(_))
}

///|
test "hex 构造与字节构造等价" {
  let a = Sm4::new(hex_to_bytes(A2_KEY_HEX)).unwrap()
  let b = Sm4::from_hex(A2_KEY_HEX).unwrap()
  let plain = ascii_bytes("0123456789abcdef")
  assert_eq(
    bytes_to_hex(a.encrypt_ecb(plain).unwrap()),
    bytes_to_hex(b.encrypt_ecb(plain).unwrap()),
  )
}

///|
test "ECB 加解密往返" {
  let cipher = Sm4::new(hex_to_bytes(A2_KEY_HEX)).unwrap()
  let plain = ascii_bytes(A2_EX1_CONTENT)
  let enc = cipher.encrypt_ecb(plain).unwrap()
  let dec = cipher.decrypt_ecb(enc).unwrap()
  assert_eq(bytes_to_hex(dec), bytes_to_hex(plain))
}

///|
test "长度不是 16 的倍数时 ECB 拒绝" {
  let cipher = Sm4::new(hex_to_bytes(A2_KEY_HEX)).unwrap()
  assert_true(cipher.encrypt_ecb(ascii_bytes("short")) is None)
  assert_true(cipher.decrypt_ecb(ascii_bytes("short")) is None)
}
