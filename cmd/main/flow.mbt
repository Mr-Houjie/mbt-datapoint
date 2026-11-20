// 数据流子命令。
//
// 前四个子命令（explain / check / frames / pack）回答的是「这条报文对不对」。
// 这一组回答的是「拿到数据之后怎么办」：
//
//   convert  报文 → JSON / NDJSON / CSV / InfluxDB line protocol
//   quality  报文 → 规则校验问题清单
//   stats    报文 → 全链路处理统计
//
// 三者共用同一份规则配置（--rules），现场调完量程后，转换与校验的口径
// 不会各说各话。这一组也是本模块脱离环保场景的地方：convert 的输出
// 格式、quality 的规则语法，都跟 HJ 212 没有任何关系。

///|
/// flow 类子命令的选项。字段可变是因为要逐项扫参数。
struct FlowOptions {
  mut input : String
  mut format : @lib.Format
  mut columns : Array[String]
  mut rules_file : String
}

///|
fn flow_options() -> FlowOptions {
  { input: "", format: @lib.Ndjson, columns: [], rules_file: "", }
}

///|
/// 解析 `convert|quality|stats` 的参数。
///
/// 第一个非选项参数是输入。选项可以写在输入前面或后面——现场复制
/// 命令行时常把选项塞到中间，卡住反而误事。
fn parse_flow_options(args : Array[String]) -> Result[FlowOptions, String] {
  let opt = flow_options()
  let mut i = 0
  while i < args.length() {
    let key = args[i]
    let has_next = i + 1 < args.length()
    match key {
      "--format" => {
        if !has_next {
          return Err("--format 后面缺少取值")
        }
        match @lib.Format::parse(args[i + 1]) {
          Some(f) => opt.format = f
          None =>
            return Err(
              "不支持的格式「\{args[i + 1]}」，可选 json / ndjson / csv / influx",
            )
        }
        i = i + 1
      }
      "--columns" => {
        if !has_next {
          return Err("--columns 后面缺少取值")
        }
        opt.columns = split_commas(args[i + 1])
        i = i + 1
      }
      "--rules" => {
        if !has_next {
          return Err("--rules 后面缺少文件路径")
        }
        opt.rules_file = args[i + 1]
        i = i + 1
      }
      _ =>
        if key.has_prefix("-") {
          return Err("未知选项「\{key}」")
        } else if opt.input != "" {
          return Err("只能指定一个输入，多了「\{key}」")
        } else {
          opt.input = key
        }
    }
    i = i + 1
  }
  if opt.input == "" {
    return Err("缺少输入：一条报文或一个文件")
  }
  Ok(opt)
}

///|
fn split_commas(text : String) -> Array[String] {
  let out : Array[String] = []
  let sb = StringBuilder()
  for c in text {
    if c == ',' {
      let part = sb.to_string().trim().to_owned()
      if part != "" {
        out.push(part)
      }
      sb.reset()
    } else {
      sb.write_char(c)
    }
  }
  let last = sb.to_string().trim().to_owned()
  if last != "" {
    out.push(last)
  }
  out
}

///|
/// 读规则配置。语法错误逐条打出来，不静默丢规则——量程写错了却当成
/// 「没有这条规则」，比直接报错更难查。
fn load_rules(path : String) -> Result[@lib.RuleSet, String] {
  if path == "" {
    return Ok(@lib.RuleSet::new())
  }
  if !@fs.path_exists(path) {
    return Err("规则文件不存在「\{path}」")
  }
  let text = @fs.read_file_to_string(path) catch {
    _ => return Err("无法读取规则文件「\{path}」")
  }
  let (set, errors) = @lib.RuleSet::from_text(text)
  for e in errors {
    println("规则提示: \{e}")
  }
  Ok(set)
}

///|
fn trim_tail(text : String) -> String {
  text.trim_end(chars="\r\n").to_owned()
}

///|
/// 把 `\r\n` 归一成 `\n`，交给标准输出自己决定行尾。
///
/// 因为 Windows 的 stdout 是文本模式，`\n` 会被运行时再加一个 `\r`
/// 变成 `\r\n`。而库层的 `to_csv` 按 RFC 4180 返回的就是 `\r\n`，
/// 若原样 `println` 出去，`\n` 再被转一次，磁盘上就成了 `\r\r\n`
/// ——每行多一个 CR，严格解析器会把行末字段读成 `30\r`。
///
/// 所以约定是：**库层负责规范的字节，CLI 层只输出 `\n`**。这样
/// Windows 落盘是 `\r\n`，Unix 落盘是 `\n`，两边都符合各自习惯。
fn unify_eol(text : String) -> String {
  let cs : Array[Char] = []
  for c in text {
    cs.push(c)
  }
  let n = cs.length()
  let sb = StringBuilder()
  let mut i = 0
  while i < n {
    let c = cs[i]
    if c == '\r' && i + 1 < n && cs[i + 1] == '\n' {
      // 成对的 \r\n 折成一个 \n
      sb.write_char('\n')
      i = i + 2
    } else {
      sb.write_char(c)
      i = i + 1
    }
  }
  sb.to_string()
}

///|
/// 报文 → 目标格式。
///
/// 只把数据写进标准输出，不掺任何统计行，方便直接重定向到文件或
/// 管道给下一个程序。
fn cmd_convert(args : Array[String]) -> Int32 {
  let opt = match parse_flow_options(args) {
    Ok(o) => o
    Err(message) => {
      println("错误: \{message}")
      return 2
    }
  }
  let text = match read_input(opt.input) {
    Ok(t) => t
    Err(message) => {
      println("错误: \{message}")
      return 2
    }
  }
  let rules = match load_rules(opt.rules_file) {
    Ok(r) => r
    Err(message) => {
      println("错误: \{message}")
      return 2
    }
  }
  let pipeline = @lib.Pipeline::new(rules, opt.format, opt.columns)
  let out = pipeline.run(normalize_input(text))
  let stats = pipeline.stats()
  if stats.points() == 0 {
    if stats.rejected() > 0 {
      println(
        "没有产出数据点：\{stats.rejected()} 条报文解码失败",
      )
    } else {
      println("没有产出数据点：输入里没有 HJ 212 报文")
    }
    return 1
  }
  let body = trim_tail(out)
  if body != "" {
    println(unify_eol(body))
  }
  0
}

///|
/// 报文 → 问题清单。
///
/// 逐点列出，而不是只给一个「失败」。现场要的是「哪条数据、哪个字段、
/// 为什么」，才能直接改设备或改规则。
fn cmd_quality(args : Array[String]) -> Int32 {
  let opt = match parse_flow_options(args) {
    Ok(o) => o
    Err(message) => {
      println("错误: \{message}")
      return 2
    }
  }
  let text = match read_input(opt.input) {
    Ok(t) => t
    Err(message) => {
      println("错误: \{message}")
      return 2
    }
  }
  let rules = match load_rules(opt.rules_file) {
    Ok(r) => r
    Err(message) => {
      println("错误: \{message}")
      return 2
    }
  }
  let pipeline = @lib.Pipeline::new(rules, @lib.Ndjson, opt.columns)
  let outputs = pipeline.feed(normalize_input(text))
  let stats = pipeline.stats()
  if outputs.length() == 0 {
    println("没有可校验的数据点：输入里没有 HJ 212 报文")
    return 1
  }
  let mut first = true
  for o in outputs {
    if !first {
      println("")
    }
    first = false
    let p = o.point
    println(
      "\{p.timestamp}  \{p.source}  CN=\{p.measurement}  [\{p.quality.label()}]",
    )
    if o.findings.length() == 0 {
      println("    （无问题）")
    }
    for f in o.findings {
      println("    \{f.text()}")
    }
  }
  let errors = count_by(outputs, @lib.Error)
  let warnings = count_by(outputs, @lib.Warning)
  let infos = count_by(outputs, @lib.Info)
  println("")
  println(
    "数据点 \{stats.points()} · 问题 \{stats.findings()}（错误 \{errors}，警告 \{warnings}，提示 \{infos}）· 解码失败 \{stats.rejected()}",
  )
  if errors > 0 {
    1
  } else {
    0
  }
}

///|
fn count_by(outputs : Array[@lib.Output], level : @lib.Severity) -> Int32 {
  let mut n = 0
  for o in outputs {
    n = n + @lib.count_severity(o.findings, level)
  }
  n
}

///|
/// 报文 → 处理统计。
///
/// 用来回答「这段流里到底丢了多少」：解码失败的、缓冲区溢出的、
/// 分包没收齐的，各自单列。这些数字对不上，说明采集链路有问题，
/// 而不是数据本身有问题。
fn cmd_stats(args : Array[String]) -> Int32 {
  let opt = match parse_flow_options(args) {
    Ok(o) => o
    Err(message) => {
      println("错误: \{message}")
      return 2
    }
  }
  let text = match read_input(opt.input) {
    Ok(t) => t
    Err(message) => {
      println("错误: \{message}")
      return 2
    }
  }
  let rules = match load_rules(opt.rules_file) {
    Ok(r) => r
    Err(message) => {
      println("错误: \{message}")
      return 2
    }
  }
  let pipeline = @lib.Pipeline::new(rules, opt.format, opt.columns)
  let out = pipeline.run(normalize_input(text))
  let stats = pipeline.stats()
  println("处理统计")
  println("  报文帧        \{stats.frames()}")
  println("  解码失败      \{stats.rejected()}")
  println("  数据点        \{stats.points()}")
  println(
    "  校验问题      \{stats.findings()}（错误 \{stats.errors()}）",
  )
  println("  缓冲区溢出    \{stats.overflow()}")
  println("  丢弃分包组    \{stats.dropped_groups()}")
  println("  输出字节      \{out.length()}")
  println("")
  println("  \{stats.to_json()}")
  if stats.frames() == 0 {
    1
  } else {
    0
  }
}
