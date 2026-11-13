// 帧层：包头、长度、数据段、CRC、包尾，以及流式分帧。
//
// 一条报文形如：
//
//     ##0101QN=...;ST=32;CN=1062;...;CP=&&RtdInterval=30&&1C80\r\n
//     └┬─┘└──┘└────────────────── 数据段 ──────────────────┘└──┘└──┘
//     包头 长度                       CRC  包尾
//
// 长度字段是数据段的 UTF-8 字节数，CRC 也按字节计算；两者必须用同一套
// 计数方式，否则含中文的数据区会算错长度，进而错位到 CRC。

///|
/// 编码一条报文。
///
/// 数据段由字段重新生成（而不是复用输入原文），因此输出是规范形式，
/// 空格、字段顺序、`&&` 包装都会被归一化。
pub fn Frame::encode(self : Frame) -> String {
  let segment = self.segment.text()
  let len = utf8_len(segment)
  let crc = crc16_text(segment)
  "##\{zero_pad(len, 4)}\{segment}\{hex4(crc)}\r\n"
}

///|
/// 解码一条报文。
///
/// 严格校验：包头、长度、CRC、包尾全部通过才算成功。字段取值范围是否
/// 符合行业惯例不在这一步判断，交给 `Segment::validate`。
pub fn Frame::decode(text : String) -> Result[Frame, DecodeError] {
  let cs = chars_of(text)
  // 允许前置空白，方便从文档里复制粘贴
  let mut start = 0
  while start < cs.length() && is_space_char(cs[start]) {
    start = start + 1
  }
  if start + 2 > cs.length() || cs[start] != '#' || cs[start + 1] != '#' {
    return Err(MissingHeader)
  }
  let len_start = start + 2
  if len_start + 4 > cs.length() {
    return Err(Truncated(0, cs.length() - len_start))
  }
  let len_field = slice_chars(cs, len_start, len_start + 4)
  let declared = match parse_uint_all(len_field) {
    Some(v) => v
    None => return Err(BadLengthField(len_field))
  }
  // 按 UTF-8 字节累加，定位数据段结束位置
  let seg_start = len_start + 4
  let mut i = seg_start
  let mut acc = 0
  while acc < declared {
    if i >= cs.length() {
      return Err(Truncated(declared, acc))
    }
    acc = acc + utf8_char_len(cs[i])
    i = i + 1
  }
  if acc != declared {
    return Err(Truncated(declared, acc))
  }
  let seg_end = i
  if seg_end == seg_start {
    return Err(EmptySegment)
  }
  let crc_start = seg_end
  if crc_start + 4 > cs.length() {
    return Err(Truncated(declared, declared))
  }
  let crc_field = slice_chars(cs, crc_start, crc_start + 4)
  let crc_chars = chars_of(crc_field)
  let mut declared_crc = 0
  let mut k = 0
  while k < 4 {
    let v = hex_value(crc_chars[k])
    if v < 0 {
      return Err(
        BadCrc(crc_field, crc16_hex(slice_chars(cs, seg_start, seg_end))),
      )
    }
    declared_crc = declared_crc * 16 + v
    k = k + 1
  }
  let segment_text = slice_chars(cs, seg_start, seg_end)
  let computed = crc16_text(segment_text)
  if declared_crc != computed {
    return Err(BadCrc(crc_field, hex4(computed)))
  }
  // 包尾：CRLF、LF、CR 都接受，其余内容视为错误
  let tail_start = crc_start + 4
  let tail = slice_chars(cs, tail_start, cs.length())
  if tail != "\r\n" && tail != "\n" && tail != "\r" {
    return Err(BadTail(tail))
  }
  match Segment::parse(segment_text) {
    Ok(segment) => Ok({ segment, })
    Err(e) => Err(e)
  }
}

///|
/// 只做校验，成功时返回数据段长度。
pub fn Frame::check(text : String) -> Result[Int32, DecodeError] {
  match Frame::decode(text) {
    Ok(frame) => Ok(utf8_len(frame.segment.text()))
    Err(e) => Err(e)
  }
}

///|
/// 流式分帧的结果。
pub(all) enum FrameEvent {
  /// 解出一条合法报文
  Good(Frame)
  /// 一条报文结构不合法，附带原始文本
  Bad(DecodeError, String)
  /// 不是报文的字节，属于噪声（半包残片、日志前缀等）
  Noise(String)
  /// 缓冲区里堆积的超长残留被丢弃，附带丢弃的字节数
  Overflow(Int32)
}

///|
/// 分帧缓冲区默认上限，单位字节。
///
/// 长度字段是 4 位十进制，数据段最多 9999 字节，加包头（2）、长度（4）、
/// CRC（4）、包尾（2）后一帧最多 10011 字节。取 16 KiB 留出余量。
const DEFAULT_MAX_PENDING : Int32 = 16384

///|
/// 增量分帧器。
///
/// 现场设备按 TCP 流发送，一次 `read` 可能拿到半条报文，也可能拿到三条半。
/// 分帧器负责在任意切分点保持状态：喂进去一段文本，吐出这段文本里能确认的
/// 全部事件，剩下的留在缓冲区里等下一段。
///
/// 关于缓冲区上限：不含 `##` 的字节会立刻作为 `Noise` 抛出、不留在缓冲区，
/// 所以脏流本身撑不爆它。会堆积的是另一种情形——对端声明了长度却始终补不齐
/// 数据（例如 `##9999` 之后只发了几个字节），缓冲区会一直等到声明长度。
/// 长度字段上限 9999，理论上界约 10 KB；`max_pending` 是把这件事写成显式
/// 契约，超限即丢弃并抛出 `Overflow`，避免逻辑改动后悄悄退化成无界缓存。
pub(all) struct Framer {
  mut buffer : String
  max_pending : Int32
}

///|
pub fn Framer::new() -> Framer {
  { buffer: "", max_pending: DEFAULT_MAX_PENDING }
}

///|
/// 指定缓冲区上限（字节）。小于 1024 会被抬到 1024，
/// 因为再小就装不下一条中等长度的合法报文了。
pub fn Framer::with_limit(max_pending : Int32) -> Framer {
  let limit = if max_pending < 1024 { 1024 } else { max_pending }
  { buffer: "", max_pending: limit }
}

///|
/// 缓冲区上限。
pub fn Framer::limit(self : Framer) -> Int32 {
  self.max_pending
}

///|
/// 缓冲区里尚未成帧的字节数。
pub fn Framer::pending(self : Framer) -> Int32 {
  utf8_len(self.buffer)
}

///|
/// 主动清空缓冲区里无法成帧的残留，返回丢弃的字节数。
///
/// 调用方发现 `pending()` 长期不下降时可以调用，例如在连接空闲超时、
/// 或者已经判定对端不是 HJ 212 设备时。
pub fn Framer::reset(self : Framer) -> Int32 {
  let dropped = utf8_len(self.buffer)
  self.buffer = ""
  dropped
}

///|
/// 喂入一段文本，返回能确认的事件。
pub fn Framer::feed(self : Framer, chunk : String) -> Array[FrameEvent] {
  self.buffer = self.buffer + chunk
  let cs = chars_of(self.buffer)
  let events : Array[FrameEvent] = []
  let mut cursor = 0
  let mut scanning = true
  while scanning {
    let hdr = find_seq(cs, "##", cursor)
    if hdr < 0 {
      // 末尾可能是半个包头，留一个字符等下一段
      let mut keep = cs.length()
      if keep > cursor && cs[keep - 1] == '#' {
        keep = keep - 1
      }
      if keep > cursor {
        events.push(Noise(slice_chars(cs, cursor, keep)))
      }
      cursor = keep
      scanning = false
    } else {
      if hdr > cursor {
        events.push(Noise(slice_chars(cs, cursor, hdr)))
      }
      if hdr + 6 > cs.length() {
        cursor = hdr
        scanning = false
      } else {
        let len_field = slice_chars(cs, hdr + 2, hdr + 6)
        match parse_uint_all(len_field) {
          None => {
            events.push(Bad(BadLengthField(len_field), len_field))
            cursor = hdr + 1
          }
          Some(declared) => {
            let mut i = hdr + 6
            let mut acc = 0
            let mut complete = true
            while acc < declared {
              if i >= cs.length() {
                complete = false
                break
              }
              acc = acc + utf8_char_len(cs[i])
              i = i + 1
            }
            if !complete {
              cursor = hdr
              scanning = false
            } else if acc != declared {
              events.push(Bad(Truncated(declared, acc), len_field))
              cursor = hdr + 1
            } else if i + 4 > cs.length() {
              // CRC 还没到齐，等下一段
              cursor = hdr
              scanning = false
            } else {
              let crc_end = i + 4
              let mut end = crc_end
              let mut need_more = false
              if crc_end >= cs.length() {
                // CRC 刚够，包尾还没到；TCP 可能正好切在这里
                need_more = true
              } else if cs[crc_end] == '\r' {
                if crc_end + 1 >= cs.length() {
                  // 只有 \r，\n 可能在下一次 read
                  need_more = true
                } else if cs[crc_end + 1] == '\n' {
                  end = crc_end + 2
                } else {
                  end = crc_end + 1
                }
              } else if cs[crc_end] == '\n' {
                end = crc_end + 1
              }
              if need_more {
                cursor = hdr
                scanning = false
              } else {
                let raw = slice_chars(cs, hdr, end)
                match Frame::decode(raw) {
                  Ok(frame) => events.push(Good(frame))
                  Err(e) => events.push(Bad(e, raw))
                }
                if end > cursor {
                  cursor = end
                } else {
                  cursor = hdr + 1
                }
              }
            }
          }
        }
      }
    }
  }
  self.buffer = slice_chars(cs, cursor, cs.length())
  // 剩下的都是拼不成帧的残片。超过上限说明对端发的不是 HJ 212（或者链路
  // 已经错位），继续攒只会吃内存，直接丢弃并告知调用方。
  let pending = utf8_len(self.buffer)
  if pending > self.max_pending {
    events.push(Overflow(pending))
    self.buffer = ""
  }
  events
}

///|
/// 一次性解码多帧文本，返回全部事件。
pub fn decode_all(text : String) -> Array[FrameEvent] {
  let framer = Framer::new()
  framer.feed(text)
}
