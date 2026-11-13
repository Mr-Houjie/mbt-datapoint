// 分包重组。
//
// 现场设备上报大段历史数据时会把一条逻辑报文拆成多帧发，用 `Flag` 的
// 分包位表示，靠 `PNUM`（总包数）与 `PNO`（当前包号）标识。单个分包
// 只携带自己那一段数据区，必须按包号拼起来才有意义。
//
// 本模块只做「按包号收集并拼接数据区」，不解释业务语义：拼出来的
// 数据区里同名项可能重复出现（各分包各自带了 `DataTime`），原样保留
// 比擅自去重更安全——去重会让「哪一段覆盖了哪一段」变得不可追溯。

///|
/// 一个已收到的分包。
pub(all) struct Part {
  pno : Int32
  cp : DataArea
}

///|
/// 分包重组的结果。
pub(all) enum ReassembleResult {
  /// 这一帧的 Flag 没有声明分包，无法参与重组
  NotSplit
  /// 已收下，仍在等其余分包：已收包数、总包数
  Pending(Int32, Int32)
  /// 收齐了，返回按包号升序拼接后的数据区
  Complete(DataArea)
  /// 与同一组内已收到的分包冲突，原因见字符串
  Conflict(String)
}

///|
/// 分包重组器。
///
/// 同一组分包由 `MN` + `CN` + `QN` 三者共同标识：同一台设备（MN）、
/// 同一种命令（CN）、同一时刻（QN）上报的多帧才属于同一条逻辑报文。
/// 三者中任一变化即视为新的一组。
pub(all) struct Reassembler {
  mut key : String
  mut total : Int32
  mut parts : Array[Part]
  mut dropped : Int32
}

///|
pub fn Reassembler::new() -> Reassembler {
  { key: "", total: 0, parts: [], dropped: 0, }
}

///|
/// 已收到但尚未拼成完整报文的组数（0 或 1）。
pub fn Reassembler::received(self : Reassembler) -> Int32 {
  self.parts.length()
}

///|
/// 当前组声明的总包数，未开始收包时为 0。
pub fn Reassembler::total(self : Reassembler) -> Int32 {
  self.total
}

///|
/// 当前组还缺哪些包号，按升序返回。未开始收包时返回空数组。
pub fn Reassembler::missing(self : Reassembler) -> Array[Int32] {
  let out : Array[Int32] = []
  if self.total <= 0 {
    return out
  }
  let mut n = 1
  while n <= self.total {
    let mut found = false
    for p in self.parts {
      if p.pno == n {
        found = true
      }
    }
    if !found {
      out.push(n)
    }
    n = n + 1
  }
  out
}

///|
/// 因换组而丢弃的未完成组数。
///
/// 上一组还没收齐，下一组的帧就到了——说明中间有丢包或乱序跨越了组边界。
/// 这个计数让调用方能区分「正常处理」和「一直在丢」。
pub fn Reassembler::dropped(self : Reassembler) -> Int32 {
  self.dropped
}

///|
/// 清空当前组。
pub fn Reassembler::reset(self : Reassembler) -> Unit {
  self.key = ""
  self.total = 0
  self.parts = []
}

///|
/// 推入一帧。
pub fn Reassembler::push(self : Reassembler, frame : Frame) -> ReassembleResult {
  let seg = frame.segment
  if !seg.flag.is_split() {
    return NotSplit
  }
  let (total, pno) = match (seg.pnum, seg.pno) {
    (Some(t), Some(n)) => (t, n)
    _ => return Conflict("Flag 声明分包，但缺少 PNUM 或 PNO")
  }
  if total < 1 {
    return Conflict("PNUM=0，分包总数至少为 1")
  }
  if pno < 1 || pno > total {
    return Conflict("PNO=\{pno} 超出 1..\{total}")
  }
  let key = "\{seg.mn}|\{seg.cn}|\{seg.qn}"
  if self.key != key {
    // 换组。上一组若没收齐，只能丢弃——分包协议本身不含重传，
    // 丢了的包只能靠上层重新请求整段历史数据。
    if self.parts.length() > 0 && self.parts.length() < self.total {
      self.dropped = self.dropped + 1
    }
    self.reset()
    self.key = key
    self.total = total
  } else if self.total != total {
    return Conflict(
      "同一组内 PNUM 不一致：先前 \{self.total}，本帧 \{total}",
    )
  }
  for p in self.parts {
    if p.pno == pno {
      return Conflict("PNO=\{pno} 重复出现")
    }
  }
  self.parts.push({ pno, cp: seg.cp, })
  if self.parts.length() < self.total {
    return Pending(self.parts.length(), self.total)
  }
  let merged = merge_parts(self.parts)
  self.reset()
  Complete(merged)
}

///|
/// 按包号升序拼接各分包的数据区。
fn merge_parts(parts : Array[Part]) -> DataArea {
  let ordered = sort_by_pno(parts)
  let area = DataArea::new()
  for p in ordered {
    for item in p.cp.items {
      area.items.push(item)
    }
  }
  area
}

///|
/// 按包号做插入排序。分包数量很小（现场一般不超过几十），
/// 用插入排序比引入排序接口更直接。
fn sort_by_pno(parts : Array[Part]) -> Array[Part] {
  let out : Array[Part] = []
  for p in parts {
    let mut at = out.length()
    let mut i = 0
    let mut placed = false
    while i < out.length() && !placed {
      if p.pno < out[i].pno {
        at = i
        placed = true
      }
      i = i + 1
    }
    out.insert(at, p)
  }
  out
}
