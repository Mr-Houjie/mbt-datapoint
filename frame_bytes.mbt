// 字节路径的帧解码。
//
// 为什么需要单独一条路径：加密报文的载荷是任意字节，不是合法 UTF-8。
// `String` 在 MoonBit 里是码点序列，任何按 UTF-8 解释的通道都会把 0x80
// 以上的孤立字节弄坏，而密文里这种字节是常态。所以加密报文只能按字节收、
// 按字节切、按字节交给解密组件，最后一步才把明文解成字符串。
//
// 明文报文也可以走这条路径（不注入解密组件即可），两条路径的校验规则
// 完全一致，只是明文路径多一层 UTF-8 编码/解码。

///|
/// 从字节数组解码一条报文，可注入外部解密组件。
///
/// 处理顺序：
///
/// 1. 结构定位：包头、4 位长度、数据段、4 位 CRC、包尾——全部按字节
/// 2. 读 `CN`：它总在 `CP=&&` 之前，因此明文、密文都能读到
/// 3. 若 `CN` 属于加密范围（6.4.4），把载荷交给 `decrypt` 换成明文
/// 4. 用**明文**算 CRC 并比对——标准 A.2 规定「先 CRC 后加密」，
///    所以解错了必然在这一步暴露
/// 5. 明文段解成字符串，交给 `Segment::parse`
pub fn Frame::decode_bytes(
  raw : Array[Byte],
  decrypt : Decryptor,
) -> Result[Frame, DecodeError] {
  // 允许前置空白，方便从文件里读取带缩进的样本
  let mut start = 0
  while start < raw.length() {
    let c = raw[start].to_int()
    if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A {
      start = start + 1
    } else {
      break
    }
  }
  let missing_header = start + 2 > raw.length()
  if missing_header || raw[start].to_int() != 0x23 || raw[start + 1].to_int() != 0x23 {
    return Err(MissingHeader)
  }
  let len_start = start + 2
  if len_start + 4 > raw.length() {
    return Err(Truncated(0, raw.length() - len_start))
  }
  let len_field = ascii_string(raw, len_start, len_start + 4)
  let declared = match parse_uint_all(len_field) {
    Some(v) => v
    None => return Err(BadLengthField(len_field))
  }
  let seg_start = len_start + 4
  let seg_end = seg_start + declared
  if seg_end > raw.length() {
    return Err(Truncated(declared, raw.length() - seg_start))
  }
  if seg_end == seg_start {
    return Err(EmptySegment)
  }
  if seg_end + 4 > raw.length() {
    return Err(Truncated(declared, declared))
  }
  let crc_field = ascii_string(raw, seg_end, seg_end + 4)
  let raw_segment = bytes_slice(raw, seg_start, seg_end)

  // 先按 CN 判断该不该解密。CN 位于 CP=&& 之前，密文中也能读到。
  let cn = cn_of_segment_bytes(raw_segment)
  let encrypted = match cn {
    Some(code) => requires_cipher(code)
    None => false
  }
  let mut plain_segment = raw_segment
  let mut decrypted = false
  if encrypted {
    match decrypt_segment_bytes(raw_segment, decrypt) {
      Ok(v) => {
        plain_segment = v
        decrypted = true
      }
      Err(e) => {
        // 组件自身有缺陷（恒等返回、长度不对、定界符缺失）时立即返回——
        // 这类错误不可能是「这条报文其实是明文」，继续往下走只会把它
        // 掩盖成 CipherRequired，现场反而查不到真正的问题。
        // `DecryptFailed` 例外：它也可能意味着报文本来就是明文，留待
        // 后面的 CRC 判定统一处理。
        match e.kind() {
          "DecryptFailed" => ()
          _ => return Err(e)
        }
      }
    }
  }

  // 用明文算 CRC
  let computed = crc16_bytes(plain_segment)
  let mut declared_crc = 0
  let mut bad_hex = false
  let crc_chars = chars_of(crc_field)
  let mut k = 0
  while k < 4 {
    let v = hex_value(crc_chars[k])
    if v < 0 {
      bad_hex = true
      break
    }
    declared_crc = declared_crc * 16 + v
    k = k + 1
  }
  if bad_hex {
    return Err(BadCrc(crc_field, hex4(computed)))
  }
  if declared_crc != computed {
    // CRC 对不上时给最有用的那个诊断：如果这条报文本来就该加密，
    // 报 CipherRequired 比报 BadCrc 有用得多——现场看到 BadCrc 会去查
    // 链路，看到 CipherRequired 才知道是没配组件或密钥不对。
    match cn {
      Some(code) =>
        if !decrypted && requires_cipher(code) {
          return Err(CipherRequired(code))
        }
      None => ()
    }
    return Err(BadCrc(crc_field, hex4(computed)))
  }

  // 包尾
  let tail_start = seg_end + 4
  let mut tail : Array[Byte] = []
  if tail_start <= raw.length() {
    tail = bytes_slice(raw, tail_start, raw.length())
  }
  let tail_ok = if tail.length() == 2 {
    tail[0].to_int() == 0x0D && tail[1].to_int() == 0x0A
  } else if tail.length() == 1 {
    let c = tail[0].to_int()
    c == 0x0A || c == 0x0D
  } else {
    false
  }
  if !tail_ok {
    return Err(BadTail(ascii_string(tail, 0, tail.length())))
  }

  // 明文段必须是合法 UTF-8（标准要求 ASCII 字段名，取值允许中文）
  let segment_text = match utf8_string(plain_segment) {
    Some(v) => v
    None => {
      return Err(BadDataArea("数据段不是合法的 UTF-8 字节序列"))
    }
  }
  match Segment::parse(segment_text) {
    Ok(segment) => Ok({ segment, })
    Err(e) => {
      // 走到这里说明 CRC 对上了但字段结构不像话。对本该加密的报文来说，
      // 这几乎一定是「密文碰巧通过 CRC」——本 CRC 只有 8 位有效强度，
      // 碰撞率约 1/256，不是理论上的极端情况。此时报 CipherRequired
      // 比报「字段名含非法字符」有用得多：现场一看就知道是没配密钥。
      match cn {
        Some(code) =>
          if encrypted && !decrypted {
            return Err(CipherRequired(code))
          }
        None => ()
      }
      Err(e)
    }
  }
}

///|
/// 只做校验的字节版本，成功时返回数据段字节数。
pub fn Frame::check_bytes(
  raw : Array[Byte],
  decrypt : Decryptor,
) -> Result[Int32, DecodeError] {
  match Frame::decode_bytes(raw, decrypt) {
    Ok(frame) => Ok(utf8_len(frame.segment.text()))
    Err(e) => Err(e)
  }
}

///|
/// 把字节数组按 UTF-8 解码成字符串。
///
/// 只接受合法序列；遇到截断的多字节序列、非法首字节、或编码过长的形式
/// 一律返回 `None`。这一步发生在 CRC 已经通过之后，所以正常不会失败——
/// 失败意味着明文本身有问题，应当拒绝而不是猜。
fn utf8_string(b : Array[Byte]) -> String? {
  let sb = StringBuilder()
  let n = b.length()
  let mut i = 0
  let mut ok = true
  while i < n {
    let b0 = b[i].to_int() & 0xFF
    if b0 < 0x80 {
      sb.write_char(b0.unsafe_to_char())
      i = i + 1
    } else if b0 >= 0xC2 && b0 <= 0xDF {
      if i + 1 >= n {
        ok = false
        break
      }
      let b1 = b[i + 1].to_int() & 0xFF
      if b1 < 0x80 || b1 > 0xBF {
        ok = false
        break
      }
      let cp = ((b0 & 0x1F) << 6) | (b1 & 0x3F)
      sb.write_char(cp.unsafe_to_char())
      i = i + 2
    } else if b0 >= 0xE0 && b0 <= 0xEF {
      if i + 2 >= n {
        ok = false
        break
      }
      let b1 = b[i + 1].to_int() & 0xFF
      let b2 = b[i + 2].to_int() & 0xFF
      if b1 < 0x80 || b1 > 0xBF || b2 < 0x80 || b2 > 0xBF {
        ok = false
        break
      }
      let cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F)
      if cp < 0x800 {
        ok = false
        break
      }
      sb.write_char(cp.unsafe_to_char())
      i = i + 3
    } else if b0 >= 0xF0 && b0 <= 0xF4 {
      if i + 3 >= n {
        ok = false
        break
      }
      let b1 = b[i + 1].to_int() & 0xFF
      let b2 = b[i + 2].to_int() & 0xFF
      let b3 = b[i + 3].to_int() & 0xFF
      if b1 < 0x80 || b1 > 0xBF || b2 < 0x80 || b2 > 0xBF || b3 < 0x80 || b3 > 0xBF {
        ok = false
        break
      }
      let cp = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
      if cp < 0x10000 || cp > 0x10FFFF {
        ok = false
        break
      }
      sb.write_char(cp.unsafe_to_char())
      i = i + 4
    } else {
      ok = false
      break
    }
  }
  if ok {
    Some(sb.to_string())
  } else {
    None
  }
}

///|
/// 把报文文本编码成字节，供 `decode_bytes` 使用。
///
/// 明文报文直接 UTF-8 编码即可；密文报文必须从原始字节流读入，不能先经过
/// 任何文本解码。
pub fn wire_bytes(text : String) -> Array[Byte] {
  utf8_bytes(text)
}
