// 命令码表。
//
// 逐条对照 HJ 212-2017 表 9《命令编码表》录入。命令码是四位数字，
// 标准把它分成四段：
//
//   1000~1999  初始化命令与参数命令
//   2000~2999  数据命令
//   3000~3999  控制命令
//   9000~9999  交互命令
//
// 标准允许厂家扩充，因此查不到时返回 `None` 而不是报错——未知命令仍然
// 可以正常编解码，只是没有中文名。

///|
pub(all) enum Direction {
  /// 上位机 -> 现场机
  Down
  /// 现场机 -> 上位机
  Up
  /// 请求与上传共用同一个命令码
  Both
}

///|
pub fn Direction::label(self : Direction) -> String {
  match self {
    Down => "上位机→现场机"
    Up => "现场机→上位机"
    Both => "双向"
  }
}

///|
pub(all) struct CommandInfo {
  code : String
  name : String
  direction : Direction
  note : String
}

///|
pub fn CommandInfo::text(self : CommandInfo) -> String {
  if self.note == "" {
    self.name
  } else {
    "\{self.name}（\{self.note}）"
  }
}

///|
/// 命令码所属的段。
pub fn command_group(code : String) -> String {
  let n = match parse_uint_all(code) {
    Some(v) => v
    None => return "未知"
  }
  if n >= 1000 && n <= 1999 {
    "初始化/参数命令"
  } else if n >= 2000 && n <= 2999 {
    "数据命令"
  } else if n >= 3000 && n <= 3999 {
    "控制命令"
  } else if n >= 9000 && n <= 9999 {
    "交互命令"
  } else {
    "未知"
  }
}

///|
/// 全部已登记的命令，顺序与标准表 9 一致。
pub fn all_commands() -> Array[CommandInfo] {
  [
    // ---- 初始化命令 ----
    {
      code: "1000",
      name: "设置超时时间及重发次数",
      direction: Down,
      note: "OverTime / ReCount",
    },
    // ---- 参数命令 ----
    {
      code: "1011",
      name: "现场机时间",
      direction: Both,
      note: "提取/上传",
    },
    { code: "1012", name: "设置现场机时间", direction: Down, note: "", },
    {
      code: "1013",
      name: "现场机时间校准请求",
      direction: Up,
      note: "通知命令",
    },
    {
      code: "1061",
      name: "实时数据间隔",
      direction: Both,
      note: "提取/上传",
    },
    {
      code: "1062",
      name: "设置实时数据间隔",
      direction: Down,
      note: "RtdInterval",
    },
    {
      code: "1063",
      name: "分钟数据间隔",
      direction: Both,
      note: "提取/上传",
    },
    {
      code: "1064",
      name: "设置分钟数据间隔",
      direction: Down,
      note: "MinInterval",
    },
    {
      code: "1072",
      name: "设置现场机密码",
      direction: Down,
      note: "NewPW",
    },
    // ---- 数据命令 ----
    {
      code: "2011",
      name: "污染物实时数据",
      direction: Both,
      note: "取/上传",
    },
    {
      code: "2012",
      name: "停止察看实时数据",
      direction: Down,
      note: "通知命令",
    },
    {
      code: "2021",
      name: "设备运行状态数据",
      direction: Both,
      note: "取/上传",
    },
    {
      code: "2022",
      name: "停止察看设备运行状态",
      direction: Down,
      note: "通知命令",
    },
    {
      code: "2031",
      name: "污染物日历史数据",
      direction: Both,
      note: "取/上传",
    },
    {
      code: "2041",
      name: "设备运行时间日历史数据",
      direction: Both,
      note: "取/上传",
    },
    {
      code: "2051",
      name: "污染物分钟数据",
      direction: Both,
      note: "取/上传",
    },
    {
      code: "2061",
      name: "污染物小时数据",
      direction: Both,
      note: "取/上传",
    },
    {
      code: "2081",
      name: "数采仪开机时间",
      direction: Up,
      note: "RestartTime",
    },
    // ---- 控制命令 ----
    {
      code: "3011",
      name: "零点/量程校准与调整",
      direction: Down,
      note: "",
    },
    { code: "3012", name: "即时采样", direction: Down, note: "", },
    { code: "3013", name: "启动清洗/反吹", direction: Down, note: "", },
    // ---- 交互命令 ----
    {
      code: "9011",
      name: "请求应答",
      direction: Both,
      note: "现场机回应上位机的请求",
    },
    { code: "9012", name: "执行结果", direction: Up, note: "ExeRtn", },
    {
      code: "9013",
      name: "通知应答",
      direction: Both,
      note: "回应通知命令",
    },
    {
      code: "9014",
      name: "数据应答",
      direction: Both,
      note: "含分包确认",
    },
  ]
}

///|
/// 按命令码查表。
pub fn lookup_command(code : String) -> CommandInfo? {
  let table = all_commands()
  let target = trim_text(code)
  let mut i = 0
  while i < table.length() {
    if table[i].code == target {
      return Some(table[i])
    }
    i = i + 1
  }
  None
}

///|
/// 命令码的中文名，查不到时返回 `None`。
pub fn command_name(code : String) -> String? {
  match lookup_command(code) {
    Some(info) => Some(info.name)
    None => None
  }
}
