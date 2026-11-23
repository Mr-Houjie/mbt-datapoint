// 加密接入层。
//
// 本库不实现任何加密算法，一行都没有。HJ 212-2025 要求数据段用 SM4 加密，
// 但把「用哪个实现、密钥从哪来、要不要走 KMS」留给部署方——这些是运维
// 决策，不是协议逻辑。本层只负责四件事：
//
//   1. 按 CN 判定这条报文是否属于加密范围（标准 6.4.4）
//   2. 把数据段里的密文整块切出来，交给注入的 `Decryptor`
//   3. 把组件返回的明文拼回数据段
//   4. 用明文复核长度与 CRC —— 解错了必然在这里暴露
//
// 第 4 条是这个设计能成立的关键。标准 A.2 规定「先完成 CRC 校验并组包，
// 再对数据段加密」，所以长度字段与 CRC 都是按明文算的。密钥不对时组件
// 照样会吐出 16 字节的乱码，但那串乱码算出的 CRC 几乎不可能与报文声明的
// 相符（该 CRC 只有 8 位有效强度，但仍有 1/256 的漏网率，故同时校验长度
// 与结构）。于是「解密是否正确」不需要靠猜，也不需要任何额外的校验字段。
//
// 关于标准里的写法：附录 A.2 的密文示例写成 `{0xE4,0x3E,...}`，那只是
// 文档的排版表示法，实际链路上传的是原始字节（208 个字节，不是 200 多个
// 可见字符）。所以加密路径必须按字节处理，不能走 `String`——密文里出现
// 0x80 以上的孤立字节是常态，任何按 UTF-8 解释的通道都会把它弄坏。

///|
/// 分组长度：16 字节。
///
/// 标准 A.2 的原文是「每 16 个字符为一组加密」，措辞用「字符」；由于
/// 数据段是 ASCII，字符与字节在这里等价，实现按字节处理。
pub const CIPHER_BLOCK : Int32 = 16

///|
/// 需要加密传输的命令编码，见 HJ 212-2025 6.4.4：
///
/// - `2000`~`2999`：现场机向上位机发送的数据命令
/// - `1014`：现场机获取新密钥 / 上位机设置新密钥
/// - `3020`：现场机向上位机发送的现场机信息
///
/// 标准同时写明「其他命令无须加密」，且专网传输"宜加密传输"——意味着
/// 同一 CN 的报文既可能是密文也可能是明文，两种都要能处理。
pub fn requires_cipher(cn : Int32) -> Bool {
  (cn >= 2000 && cn <= 2999) || cn == 1014 || cn == 3020
}

///|
/// 外部解密组件。
///
/// 入参是待解密的密文，长度必为 `CIPHER_BLOCK` 的整数倍；返回等长的明文。
/// 无法解密（密钥不对、算法不匹配、KMS 不可用）时返回 `None`。
///
/// 组件可以是任何东西，本库不关心：
///
/// - 本仓库 `sm4/` 子包的参考实现（用于自测与演示）
/// - 调用 KMS / 密码机 / 硬件加密卡
/// - 通过 FFI 调系统的 libcrypto
/// - 测试里用固定密钥的替身
///
/// 之所以把整段密文一次性传入、而不是逐个分组调用，是因为真实组件往往
/// 需要成批处理（一次 KMS 请求比 13 次便宜）。分组循环由组件自己决定。
pub type Decryptor = (Array[Byte]) -> Array[Byte]?

///|
/// 一段密文里可以整块加密的字节数：不足一组的尾部按标准保持明文。
pub fn cipher_bulk_len(payload_len : Int32) -> Int32 {
  payload_len / CIPHER_BLOCK * CIPHER_BLOCK
}

///|
/// 在字节数组里查找子串，找不到返回 `-1`。
fn bytes_find(hay : Array[Byte], needle : Bytes, from : Int32) -> Int32 {
  let n = needle.length()
  if n == 0 {
    return from
  }
  let mut i = if from < 0 { 0 } else { from }
  while i + n <= hay.length() {
    let mut j = 0
    let mut matched = true
    while j < n {
      if hay[i + j] != needle[j] {
        matched = false
        break
      }
      j = j + 1
    }
    if matched {
      return i
    }
    i = i + 1
  }
  -1
}

///|
/// 取字节区间 `[start, end)`，越界自动截断。
fn bytes_slice(b : Array[Byte], start : Int32, end : Int32) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = if start < 0 { 0 } else { start }
  let stop = if end > b.length() { b.length() } else { end }
  while i < stop {
    out.push(b[i])
    i = i + 1
  }
  out
}

///|
/// 拼接两个字节数组。
fn bytes_concat(a : Array[Byte], b : Array[Byte]) -> Array[Byte] {
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
/// 把纯 ASCII 的字节区间转成字符串。
///
/// 只在确认全 ASCII 之后调用；含高位字节的区间应该交给解密组件，或者作为
/// 非法报文拒绝，绝不能在这里做有损转换。
fn ascii_string(b : Array[Byte], start : Int32, end : Int32) -> String {
  let sb = StringBuilder()
  let mut i = if start < 0 { 0 } else { start }
  let stop = if end > b.length() { b.length() } else { end }
  while i < stop {
    sb.write_char(b[i].to_int().unsafe_to_char())
    i = i + 1
  }
  sb.to_string()
}

///|
/// 从一个字节数组形式的数据段里取出 `CN` 的命令编码。
///
/// `CN` 一定位于 `CP=&&` 之前，因此即使数据段已被加密也能读到——这是
/// 「先按 CN 判断该不该解密」能够成立的前提。
pub fn cn_of_segment_bytes(seg : Array[Byte]) -> Int32? {
  let marker = b";CN="
  let mut at = bytes_find(seg, marker, 0)
  let mut skip = 4
  if at < 0 {
    // 数据段以 CN 开头的情形
    let head = b"CN="
    if seg.length() >= 3 && bytes_find(seg, head, 0) == 0 {
      at = 0
      skip = 3
    } else {
      return None
    }
  }
  let start = at + skip
  if start + 4 > seg.length() {
    return None
  }
  let mut value = 0
  let mut i = 0
  while i < 4 {
    let c = seg[start + i].to_int()
    if c < 48 || c > 57 {
      return None
    }
    value = value * 10 + (c - 48)
    i = i + 1
  }
  Some(value)
}

///|
/// 解密一个字节形式的数据段，返回明文数据段。
///
/// 处理顺序严格照标准 A.2：
///
/// 1. 定位 `CP=&&` 之后、最后一个 `&&` 之前的内容
/// 2. 前 `floor(len/16)*16` 字节整块交给组件，尾部不足一组的部分保持明文
/// 3. 拼回 `前缀 + 明文块 + 尾部明文 + 后缀`
///
/// 失败情形分三类，错误码不同，便于现场定位：
/// - 组件返回 `None`：密钥不对或组件不可用
/// - 组件返回的长度不等于入参：组件实现有 bug
/// - 组件是恒等函数（原样返回）：配置错误，把「不加密」当成了「加密」
fn decrypt_segment_bytes(
  seg : Array[Byte],
  decrypt : Decryptor,
) -> Result[Array[Byte], DecodeError] {
  let cp = b"CP=&&"
  let open = bytes_find(seg, cp, 0)
  if open < 0 {
    return Err(BadDataArea("加密报文缺少 \"CP=&&\" 定界符"))
  }
  let content_start = open + cp.length()
  // 结尾的 && 不能靠搜索——密文是随机字节，完全可能包含 0x26 0x26。
  // 位置由数据段总长直接推出：最后两个字节就是它。
  if seg.length() < 2 {
    return Err(BadDataArea("加密报文过短，缺少结尾 \"&&\" 定界符"))
  }
  let close = seg.length() - 2
  if close < content_start {
    return Err(BadDataArea("加密报文的 \"CP=&&\" 与结尾 \"&&\" 之间没有内容"))
  }
  if seg[close].to_int() != 0x26 || seg[close + 1].to_int() != 0x26 {
    return Err(BadDataArea("加密报文未以 \"&&\" 结束"))
  }
  let payload = bytes_slice(seg, content_start, close)
  let bulk = cipher_bulk_len(payload.length())
  if bulk == 0 {
    // 整段都不足一组，按标准全部保持明文
    return Ok(seg)
  }
  let cipher_bytes = bytes_slice(payload, 0, bulk)
  let tail_plain = bytes_slice(payload, bulk, payload.length())
  let plain = match decrypt(cipher_bytes) {
    Some(v) => v
    None => return Err(DecryptFailed)
  }
  if plain.length() != bulk {
    return Err(DecryptBadLength(bulk, plain.length()))
  }
  // 恒等返回通常意味着调用方把「明文当密文」送进来了
  if bytes_equal(plain, cipher_bytes) {
    return Err(DecryptNoOp)
  }
  let head = bytes_slice(seg, 0, content_start)
  let rest = bytes_slice(seg, close, seg.length())
  Ok(bytes_concat(bytes_concat(bytes_concat(head, plain), tail_plain), rest))
}

///|
/// 字节数组相等比较。
fn bytes_equal(a : Array[Byte], b : Array[Byte]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut i = 0
  let mut ok = true
  while i < a.length() {
    if a[i] != b[i] {
      ok = false
      break
    }
    i = i + 1
  }
  ok
}

///|
/// 把密文字节渲染成标准 A.2 的表示法 `{0xE4,0x3E,...}`，便于日志与比对。
///
/// 不用于收报文——链路上传的是原始字节，这只是给人看的。
pub fn cipher_bytes_to_display(b : Array[Byte]) -> String {
  let sb = StringBuilder()
  sb.write_char('{')
  let mut i = 0
  while i < b.length() {
    if i > 0 {
      sb.write_char(',')
    }
    sb.write_string("0x")
    let v = b[i].to_int() & 0xFF
    sb.write_string(hex_digit((v >> 4) & 0xF))
    sb.write_string(hex_digit(v & 0xF))
    i = i + 1
  }
  sb.write_char('}')
  sb.to_string()
}

///|
/// 解析标准 A.2 的 `{0xE4,0x3E,...}` 表示法，得到原始字节。
///
/// 用于把标准示例里的密文抄进语料与测试。接受空白与大小写混写；
/// 遇到非 `0x` 开头的内容一律报错，不做猜测。
pub fn cipher_bytes_from_display(text : String) -> Array[Byte]? {
  let cs = chars_of(text)
  let out : Array[Byte] = []
  let mut i = 0
  let mut ok = true
  while i < cs.length() {
    let c = cs[i]
    if c == '{' || c == '}' || c == ',' || c == ' ' || c == '\n' || c == '\r' {
      i = i + 1
      continue
    }
    if c == '0' && i + 3 < cs.length() && (cs[i + 1] == 'x' || cs[i + 1] == 'X') {
      let hi = hex_value(cs[i + 2])
      let lo = hex_value(cs[i + 3])
      if hi < 0 || lo < 0 {
        ok = false
        break
      }
      out.push((hi * 16 + lo).to_byte())
      i = i + 4
    } else {
      ok = false
      break
    }
  }
  if ok {
    Some(out)
  } else {
    None
  }
}
