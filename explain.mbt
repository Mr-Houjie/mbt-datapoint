// 把一条报文渲染成人能读的形式。
//
// 设计目标：别人拿到一条现场抓包的原始字节，粘进 CLI 就能看懂每个字段
// 是什么、为什么 CRC 过不了。所以这里的输出不是「调试打印」，而是解释。

///|
/// 一条报文的单行摘要，适合日志与批量扫描。
pub fn Frame::summary(self : Frame) -> String {
  let seg = self.segment
  let name = match command_name(seg.cn) {
    Some(n) => n
    None => "未知命令"
  }
  let qn = match QnTime::parse(seg.qn) {
    Some(t) => t.text()
    None => seg.qn
  }
  "#\{seg.cn} \{name} · MN=\{seg.mn} · \{qn} · CP \{seg.cp.length()} 项"
}

///|
/// 一条报文的逐字段解释。
pub fn Frame::explain(self : Frame) -> String {
  let seg = self.segment
  let sb = StringBuilder()
  let segment_text = seg.text()
  let bytes = utf8_len(segment_text)
  let crc = crc16_hex(segment_text)

  sb.write_string(line_kv("长度", "\{bytes} 字节（数据段）", ""))
  sb.write_string(line_kv("CRC", crc, "校验通过"))
  sb.write_string(line_kv("版本", seg.flag.version().label(), ""))
  sb.write_string(line_kv("Flag", seg.flag.text(), flag_note(seg.flag)))
  sb.write_string(line_kv("QN", seg.qn, qn_note(seg.qn)))
  sb.write_string(line_kv("ST", seg.st, system_name(seg.st)))
  sb.write_string(line_kv("CN", seg.cn, cn_note(seg.cn)))
  sb.write_string(
    line_kv("PW", if seg.pw == "" { "（未提供）" } else { seg.pw }, ""),
  )
  sb.write_string(line_kv("MN", seg.mn, mn_note(seg.mn)))
  match seg.pnum {
    Some(v) => sb.write_string(line_kv("PNUM", v.to_string(), "总包数"))
    None => ()
  }
  match seg.pno {
    Some(v) => sb.write_string(line_kv("PNO", v.to_string(), "当前包号"))
    None => ()
  }
  let mut i = 0
  while i < seg.extra.length() {
    sb.write_string(
      line_kv(
        seg.extra[i].name,
        join_values(seg.extra[i].values),
        "扩展字段",
      ),
    )
    i = i + 1
  }
  if seg.cp.length() == 0 {
    sb.write_string(line_kv("CP", "（空）", ""))
  } else {
    sb.write_string(line_kv("CP", "\{seg.cp.length()} 项", ""))
    let mut j = 0
    while j < seg.cp.items.length() {
      let item = seg.cp.items[j]
      sb.write_string(
        "  \{pad_display(item.name, 18)}\{join_values(item.values)}\n",
      )
      j = j + 1
    }
  }
  let warnings = seg.validate()
  if warnings.length() > 0 {
    sb.write_string("\n")
    sb.write_string("提示:\n")
    for w in warnings {
      sb.write_string("  · \{w}\n")
    }
  }
  sb.to_string()
}

///|
fn line_kv(label : String, value : String, note : String) -> String {
  let head = pad_display(label, 8)
  if note == "" {
    "\{head}\{value}\n"
  } else {
    "\{head}\{pad_display(value, 30)}\{note}\n"
  }
}

///|
fn join_values(values : Array[String]) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < values.length() {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(values[i])
    i = i + 1
  }
  sb.to_string()
}

///|
fn flag_note(flag : Flag) -> String {
  let version_bits = bin_pad((flag.raw >> 2) & 0x3F, 6)
  let split = if flag.is_split() { "分包" } else { "不分包" }
  let ack = if flag.needs_ack() { "需应答" } else { "不需应答" }
  "版本位 \{version_bits} · \{split} · \{ack}"
}

///|
fn qn_note(qn : String) -> String {
  match QnTime::parse(qn) {
    Some(t) => t.text()
    None => "无法解析为时间戳"
  }
}

///|
fn cn_note(cn : String) -> String {
  match lookup_command(cn) {
    Some(info) => "\{info.name} · \{info.direction.label()}"
    None => "未登记的命令码"
  }
}

///|
fn mn_note(mn : String) -> String {
  "\{chars_of(mn).length()} 位"
}

///|
/// 系统编码的中文名，逐条对应 HJ 212-2017 表 5《系统编码表》。
///
/// 编码分段：10~29 环境质量、30~49 环境污染源、50~69 工况、91~99 系统交互。
/// 最容易被记错的是 32 —— 它是「地表水体环境污染源」（水质），不是烟气；
/// 烟气是 31「大气环境污染源」，而烟气工况是 51。
fn system_name(st : String) -> String {
  match st {
    "21" => "地表水质量监测"
    "22" => "空气质量监测"
    "23" => "声环境质量监测"
    "24" => "地下水质量监测"
    "25" => "土壤质量监测"
    "26" => "海水质量监测"
    "27" => "挥发性有机物监测"
    "31" => "大气环境污染源"
    "32" => "地表水体环境污染源"
    "33" => "地下水体环境污染源"
    "34" => "海洋环境污染源"
    "35" => "土壤环境污染源"
    "36" => "声环境污染源"
    "37" => "振动环境污染源"
    "38" => "放射性环境污染源"
    "39" => "工地扬尘污染源"
    "41" => "电磁环境污染源"
    "51" => "烟气排放过程监控"
    "52" => "污水排放过程监控"
    "91" => "系统交互"
    _ => ""
  }
}
