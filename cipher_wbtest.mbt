// 加密接入层的流程测试。
//
// 这里用一个「假密码」而不是真 SM4，原因是依赖方向：主库不应该依赖任何
// 加密实现，否则「核心库不含算法」这句话就不成立了。所以本文件只验证
// **流程与错误处理**——判定、切块、拼接、复核、诊断。
//
// 真算法的验证分两处：
//   - `sm4/` 子包：用 GB/T 32907 与 HJ 212-2025 附录 A.2 的原文向量
//     证明 SM4 实现与标准逐字节一致
//   - `cmd/verify`：用真 SM4 跑「加密报文 → 数据点」的端到端链路
//
// 假密码取 XOR 0x5A，作用于整块；它没有密码学意义，只要求可逆且等长。

///|
/// 测试用假密码的核变换：逐字节 XOR 0x5A。加解密相同。
fn fake_xor(data : Array[Byte]) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = 0
  while i < data.length() {
    out.push(((data[i].to_int() & 0xFF) ^ 0x5A).to_byte())
    i = i + 1
  }
  out
}

///|
/// 包装成 `Decryptor` 的形状。
fn fake_cipher(data : Array[Byte]) -> Array[Byte]? {
  Some(fake_xor(data))
}

///|
fn ascii_of(s : String) -> Array[Byte] {
  let out : Array[Byte] = []
  for c in s {
    out.push(c.to_int().to_byte())
  }
  out
}

///|
fn cat(a : Array[Byte], b : Array[Byte]) -> Array[Byte] {
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
fn slice_first(b : Array[Byte], n : Int32) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = 0
  while i < n && i < b.length() {
    out.push(b[i])
    i = i + 1
  }
  out
}

///|
fn slice_text(s : String, start : Int32, end : Int32) -> String {
  let cs : Array[Char] = []
  for c in s {
    cs.push(c)
  }
  let sb = StringBuilder()
  let mut i = start
  while i < end && i < cs.length() {
    sb.write_char(cs[i])
    i = i + 1
  }
  sb.to_string()
}

///|
fn slice_bytes_range(b : Array[Byte], start : Int32, end : Int32) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = start
  while i < end && i < b.length() {
    out.push(b[i])
    i = i + 1
  }
  out
}

///|
fn find_bytes(hay : Array[Byte], needle : Array[Byte], from : Int32) -> Int32 {
  let n = needle.length()
  let mut i = from
  while i + n <= hay.length() {
    let mut j = 0
    let mut ok = true
    while j < n {
      if hay[i + j] != needle[j] {
        ok = false
        break
      }
      j = j + 1
    }
    if ok {
      return i
    }
    i = i + 1
  }
  -1
}

///|
fn rfind_bytes(hay : Array[Byte], needle : Array[Byte]) -> Int32 {
  let n = needle.length()
  let mut i = hay.length() - n
  while i >= 0 {
    let mut j = 0
    let mut ok = true
    while j < n {
      if hay[i + j] != needle[j] {
        ok = false
        break
      }
      j = j + 1
    }
    if ok {
      return i
    }
    i = i - 1
  }
  -1
}

///|
/// 用假密码把一条明文报文改造成加密报文。
///
/// 严格照标准 A.2 的顺序：先算 CRC、组好包，再把 `CP=&&` 与结尾 `&&`
/// 之间的前 `floor(len/16)*16` 字节替换成密文，尾部不足一组保持明文。
fn encrypt_frame(plain : String) -> Array[Byte] {
  let bytes = ascii_of(plain)
  let seg_start = 6
  let declared = match parse_uint_all(slice_text(plain, 2, 6)) {
    Some(v) => v
    None => 0
  }
  let seg_end = seg_start + declared
  let seg = slice_bytes_range(bytes, seg_start, seg_end)
  let cp_at = find_bytes(seg, ascii_of("CP=&&"), 0)
  let tail_at = rfind_bytes(seg, ascii_of("&&"))
  let content_start = cp_at + 5
  let bulk = (tail_at - content_start) / 16 * 16
  let head = slice_bytes_range(seg, 0, content_start)
  let body = slice_bytes_range(seg, content_start, content_start + bulk)
  let tail_plain = slice_bytes_range(seg, content_start + bulk, tail_at)
  let rest = slice_bytes_range(seg, tail_at, seg.length())
  let new_seg = cat(cat(cat(head, fake_xor(body)), tail_plain), rest)
  cat(
    cat(slice_bytes_range(bytes, 0, seg_start), new_seg),
    slice_bytes_range(bytes, seg_end, bytes.length()),
  )
}

///|
/// 按给定前缀与内容拼一条报文，长度与 CRC 都算出来，不手抄。
fn build_frame(prefix : String, content : String) -> String {
  let seg = "\{prefix}\{content}&&"
  "##\{zero_pad(utf8_len(seg), 4)}\{seg}\{crc16_hex(seg)}\r\n"
}

///|
/// 一条 CN=2051（属加密范围）的样本，内容正好 32 字节 = 两组。
const SAMPLE_PREFIX : String = "QN=20240520210700000;ST=31;CN=2051;PW=123456;MN=010000A8900016F000169DC0;Flag=9;CP=&&"

///|
const SAMPLE_CONTENT : String = "a01011-Avg=1.35,a01011-Max=1.3"

///|
test "CN 判定与标准 6.4.4 一致" {
  assert_true(requires_cipher(2000))
  assert_true(requires_cipher(2051))
  assert_true(requires_cipher(2999))
  assert_true(requires_cipher(1014))
  assert_true(requires_cipher(3020))
  assert_false(requires_cipher(1999))
  assert_false(requires_cipher(3000))
  assert_false(requires_cipher(1011))
  assert_false(requires_cipher(1062))
}

///|
test "加密报文经组件解密后与明文报文解码结果一致" {
  assert_eq(utf8_len(SAMPLE_CONTENT), 30)
  let plain = build_frame(SAMPLE_PREFIX, SAMPLE_CONTENT)
  let enc = encrypt_frame(plain)
  // Nopadding 不改变长度
  assert_eq(enc.length(), ascii_of(plain).length())
  let base = match Frame::decode_bytes(ascii_of(plain), fn(_) { None }) {
    Ok(f) => f.segment.text()
    Err(e) => fail("明文应当解码成功：\{e.message()}")
  }
  match Frame::decode_bytes(enc, fake_cipher) {
    Ok(f) => assert_eq(f.segment.text(), base)
    Err(e) => fail("加密报文应当解码成功：\{e.kind()} / \{e.message()}")
  }
}

///|
test "未提供组件时加密报文报 CipherRequired" {
  let enc = encrypt_frame(build_frame(SAMPLE_PREFIX, SAMPLE_CONTENT))
  match Frame::decode_bytes(enc, fn(_) { None }) {
    Ok(_) => fail("应当失败")
    Err(e) => {
      assert_eq(e.kind(), "CipherRequired")
      assert_true(e.is_structural())
    }
  }
}

///|
test "组件恒等返回时报告配置错误" {
  let enc = encrypt_frame(build_frame(SAMPLE_PREFIX, SAMPLE_CONTENT))
  match Frame::decode_bytes(enc, fn(d) { Some(d) }) {
    Ok(_) => fail("应当失败")
    Err(e) => assert_eq(e.kind(), "DecryptNoOp")
  }
}

///|
test "组件返回长度不符时报告实现错误" {
  let enc = encrypt_frame(build_frame(SAMPLE_PREFIX, SAMPLE_CONTENT))
  match Frame::decode_bytes(enc, fn(d) { Some(slice_first(d, 8)) }) {
    Ok(_) => fail("应当失败")
    Err(e) => assert_eq(e.kind(), "DecryptBadLength")
  }
}

///|
test "内容不足一组时整段保持明文，组件不会被调用" {
  // 内容只有 8 字节，小于 16
  let short = build_frame("QN=20240520210700000;ST=31;CN=2051;PW=1;CP=&&", "a01011=1")
  let mut called = false
  let spy = fn(d) {
    called = true
    Some(fake_xor(d))
  }
  let _ = Frame::decode_bytes(ascii_of(short), spy)
  assert_false(called)
}

///|
test "尾部不足一组的明文在解密后被原样保留" {
  // 内容 35 字节：前 32 加密，尾部 "=1" 之外的 3 字节保持明文
  let content = "a01011-Avg=1.35,a01011-Max=1.35,a01"
  assert_eq(utf8_len(content), 35)
  let bulk = utf8_len(content) / 16 * 16
  assert_eq(bulk, 32)
  let prefix = "QN=20240520210700000;ST=31;CN=2051;PW=1;CP=&&"
  let plain_seg = "\{prefix}\{content}&&"
  let head = ascii_of(prefix)
  let body = ascii_of(slice_text(content, 0, 32))
  let tail = ascii_of(slice_text(content, 32, 35))
  let enc_seg = cat(cat(head, fake_xor(body)), cat(tail, ascii_of("&&")))
  match decrypt_segment_bytes(enc_seg, fake_cipher) {
    Ok(plain) => assert_eq(ascii_string(plain, 0, plain.length()), plain_seg)
    Err(e) => fail("应当解密成功：\{e.message()}")
  }
}

///|
test "cn_of_segment_bytes 能从密文段里读出 CN" {
  let seg = ascii_of("QN=20240520210700000;ST=31;CN=2051;PW=1;CP=&&")
  assert_eq(cn_of_segment_bytes(seg), Some(2051))
  assert_eq(cn_of_segment_bytes(ascii_of("CN=1014;PW=1;CP=&&x&&")), Some(1014))
  assert_eq(cn_of_segment_bytes(ascii_of("ST=32;CP=&&x&&")), None)
  assert_eq(cn_of_segment_bytes(ascii_of("CN=20x1;CP=&&x&&")), None)
}

///|
test "cipher_bytes_to_display 与标准写法一致" {
  let b = cipher_bytes_from_display("{0xE4,0x3E,0x15}").unwrap()
  assert_eq(cipher_bytes_to_display(b), "{0xE4,0x3E,0x15}")
}

///|
test "cipher_bytes_from_display 能解析标准写法并可往返" {
  let shape = "{0xE4,0x3E,0x15,0x9A}"
  let parsed = cipher_bytes_from_display(shape).unwrap()
  assert_eq(parsed.length(), 4)
  assert_eq(parsed[0].to_int(), 0xE4)
  assert_eq(parsed[3].to_int(), 0x9A)
  assert_eq(cipher_bytes_to_display(parsed), shape)
  assert_true(cipher_bytes_from_display("{zz}") is None)
}

///|
test "cipher_bulk_len 按 16 向下取整" {
  assert_eq(cipher_bulk_len(0), 0)
  assert_eq(cipher_bulk_len(15), 0)
  assert_eq(cipher_bulk_len(16), 16)
  assert_eq(cipher_bulk_len(31), 16)
  assert_eq(cipher_bulk_len(208), 208)
  assert_eq(cipher_bulk_len(147), 144)
}
