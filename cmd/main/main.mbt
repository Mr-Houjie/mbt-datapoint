// mbt-datapoint 命令行入口。
//
// 解析逻辑全部在库包里，这里只做三件事：读输入、调度子命令、把结果打出来。

///|
const VERSION : String = "0.4.0"

///|
fn usage() -> String {
  let s = StringBuilder()
  s.write_string(
    "mbt-datapoint \{VERSION} — 设备数据接入、校验与转换\n\n",
  )
  s.write_string("用法:\n")
  s.write_string(
    "  mbt-datapoint explain <报文|文件>     逐字段解释一条报文\n",
  )
  s.write_string(
    "  mbt-datapoint check <报文|文件>       只校验，成功退出码 0\n",
  )
  s.write_string(
    "  mbt-datapoint frames <报文|文件>      按 TCP 流分帧，逐条列出\n",
  )
  s.write_string(
    "  mbt-datapoint pack <报文|文件>        把分包帧按包号重组成完整数据区\n",
  )
  s.write_string(
    "  mbt-datapoint convert <报文|文件> [选项]  转成 JSON / NDJSON / CSV / InfluxDB\n",
  )
  s.write_string(
    "  mbt-datapoint quality <报文|文件> [选项]  按规则校验，列出问题清单\n",
  )
  s.write_string(
    "  mbt-datapoint stats <报文|文件> [选项]    输出全链路处理统计\n",
  )
  s.write_string(
    "  mbt-datapoint encode [选项]           构造一条报文\n",
  )
  s.write_string(
    "  mbt-datapoint crc <数据段>            算数据段的 CRC 与字节长度\n\n",
  )
  s.write_string("convert / quality / stats 选项:\n")
  s.write_string(
    "  --format <格式>         json | ndjson | csv | influx，默认 ndjson\n",
  )
  s.write_string("  --columns <列名>        CSV 字段列，逗号分隔\n")
  s.write_string(
    "  --rules <文件>          规则配置文件，每行一条，见 corpus/rules/demo.rules\n\n",
  )
  s.write_string("encode 选项:\n")
  s.write_string("  --cn <4位命令码>        默认 2011\n")
  s.write_string(
    "  --mn <设备标识>         默认 010000A8900016F000169DC0\n",
  )
  s.write_string("  --cp <数据区>           例如 \"a=1;b=2\"\n")
  s.write_string("  --st <系统编码>         默认 32\n")
  s.write_string("  --pw <访问密码>         默认 123456\n")
  s.write_string("  --qn <请求编码>         默认 20240101000000000\n")
  s.write_string(
    "  --flag <0-255>          直接指定 Flag，优先于 --split/--ack\n",
  )
  s.write_string("  --split                 置分包位\n")
  s.write_string("  --ack                   置应答位\n")
  s.write_string("  --rf                    置补传标志（RF=1，HJ 212-2025）\n")
  s.write_string("  --pnum <总包数> --pno <包号>\n\n")
  s.write_string("退出码:\n")
  s.write_string("  0  成功\n")
  s.write_string(
    "  1  报文不合法，或校验发现问题（quality 的 Error 级）\n",
  )
  s.write_string("  2  用法错误或读写失败\n")
  s.to_string()
}

///|
fn read_input(arg : String) -> Result[String, String] {
  if @fs.path_exists(arg) {
    Ok(@fs.read_file_to_string(arg)) catch {
      _ => Err("无法读取文件「\{arg}」")
    }
  } else {
    Ok(arg)
  }
}

///|
// 命令行里粘一条报文常常丢掉末尾的 \r\n（从终端复制时几乎必然丢）。
// 库层保持严格，CLI 层在这里补一次，让「复制粘贴」也能直接跑通。
fn normalize_input(text : String) -> String {
  if text.has_suffix("\n") {
    text
  } else {
    "\{text}\r\n"
  }
}

///|
fn cmd_explain(arg : String) -> Int32 {
  match read_input(arg) {
    Err(message) => {
      println("错误: \{message}")
      2
    }
    Ok(text) => {
      let events = @lib.decode_all(normalize_input(text))
      let mut good = 0
      let mut bad = 0
      let mut first = true
      for event in events {
        match event {
          @lib.Good(frame) => {
            if !first {
              println("")
            }
            first = false
            println(frame.explain().trim_end(chars="\r\n"))
            good = good + 1
          }
          @lib.Bad(error, raw) => {
            if !first {
              println("")
            }
            first = false
            println(
              "解析失败（\{error.stage().label()}）: \{error.message()}",
            )
            println("原文: \{raw}")
            bad = bad + 1
          }
          @lib.Noise(text) => {
            let n = text.length()
            println("跳过 \{n} 字节噪声")
          }
          @lib.Overflow(n) =>
            println("丢弃 \{n} 字节超长残留（缓冲区已达上限）")
        }
      }
      if good == 0 && bad == 0 {
        println("没有找到 HJ 212 报文")
        return 1
      }
      if bad > 0 {
        1
      } else {
        0
      }
    }
  }
}

///|
fn cmd_check(arg : String) -> Int32 {
  match read_input(arg) {
    Err(message) => {
      println("错误: \{message}")
      2
    }
    Ok(text) => {
      let events = @lib.decode_all(normalize_input(text))
      let mut good = 0
      let mut bad = 0
      for event in events {
        match event {
          @lib.Good(frame) => {
            println("OK   \{frame.summary()}")
            good = good + 1
          }
          @lib.Bad(error, raw) => {
            println("FAIL（\{error.stage().label()}）\{error.message()}")
            println("     \{raw}")
            bad = bad + 1
          }
          @lib.Noise(_) => ()
          @lib.Overflow(_) => ()
        }
      }
      if good == 0 && bad == 0 {
        // 有 ## 却一条也没解出来，多半是帧被截断了（长度字段或 CRC 不全）；
        // 连 ## 都没有，才是真的不像 HJ 212 报文。
        if normalize_input(text).contains("##") {
          println(
            "FAIL 报文不完整：有 \"##\" 包头，但长度字段、CRC 或包尾没写全",
          )
        } else {
          println("FAIL 没有找到 HJ 212 报文")
        }
        return 1
      }
      if bad > 0 {
        1
      } else {
        0
      }
    }
  }
}

///|
fn cmd_frames(arg : String) -> Int32 {
  match read_input(arg) {
    Err(message) => {
      println("错误: \{message}")
      2
    }
    Ok(text) => {
      let events = @lib.decode_all(normalize_input(text))
      let mut index = 0
      let mut bad = 0
      for event in events {
        match event {
          @lib.Good(frame) => {
            index = index + 1
            println("\{pad3(index)}  OK   \{frame.summary()}")
          }
          @lib.Bad(error, raw) => {
            index = index + 1
            bad = bad + 1
            println(
              "\{pad3(index)}  FAIL（\{error.stage().label()}）\{error.message()}",
            )
            println("     原文 \{raw}")
          }
          @lib.Noise(text) =>
            println("      SKIP \{text.length()} 字节噪声")
          @lib.Overflow(n) =>
            println(
              "      DROP \{n} 字节超长残留（缓冲区已达上限）",
            )
        }
      }
      if bad > 0 {
        1
      } else {
        0
      }
    }
  }
}

///|
/// 把一组分包帧按包号重组成完整数据区。
///
/// 输入里混着非分包帧是常态（同一段日志里既有实时数据又有历史数据），
/// 遇到就跳过并说明原因，不算错误。
fn cmd_pack(arg : String) -> Int32 {
  match read_input(arg) {
    Err(message) => {
      println("错误: \{message}")
      2
    }
    Ok(text) => {
      let events = @lib.decode_all(normalize_input(text))
      let r = @lib.Reassembler::new()
      let mut frames = 0
      let mut bad = 0
      let mut done = 0
      for event in events {
        match event {
          @lib.Good(frame) => {
            frames = frames + 1
            match r.push(frame) {
              @lib.NotSplit =>
                println("跳过 CN=\{frame.segment.cn}：未声明分包")
              @lib.Pending(got, total) =>
                println(
                  "  已收 \{got}/\{total}，缺 \{join_ints(r.missing())}",
                )
              @lib.Conflict(reason) => {
                println("冲突: \{reason}")
                bad = bad + 1
              }
              @lib.Complete(area) => {
                done = done + 1
                println("重组完成，共 \{area.length()} 项：")
                let mut i = 0
                while i < area.items.length() {
                  let item = area.items[i]
                  println(
                    "  \{@lib.pad_display(item.name, 18)}\{join_texts(item.values)}",
                  )
                  i = i + 1
                }
              }
            }
          }
          @lib.Bad(error, raw) => {
            bad = bad + 1
            println(
              "解析失败（\{error.stage().label()}）: \{error.message()}",
            )
            println("     \{raw}")
          }
          @lib.Noise(_) => ()
          @lib.Overflow(n) => println("丢弃 \{n} 字节超长残留")
        }
      }
      if frames == 0 {
        println("没有找到 HJ 212 报文")
        return 1
      }
      if r.received() > 0 {
        println(
          "仍有 \{r.received()}/\{r.total()} 未收齐，缺 \{join_ints(r.missing())}",
        )
      }
      if r.dropped() > 0 {
        println("因换组丢弃 \{r.dropped()} 个未完成组")
      }
      if bad > 0 || (done == 0 && r.received() > 0) {
        1
      } else {
        0
      }
    }
  }
}

///|
fn join_ints(values : Array[Int32]) -> String {
  if values.length() == 0 {
    return "（无）"
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < values.length() {
    if i > 0 {
      sb.write_string(", ")
    }
    sb.write_string(values[i].to_string())
    i = i + 1
  }
  sb.to_string()
}

///|
fn join_texts(values : Array[String]) -> String {
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
fn cmd_encode(args : Array[String]) -> Int32 {
  let mut cn = "2011"
  let mut mn = "010000A8900016F000169DC0"
  let mut cp = ""
  let mut st = "32"
  let mut pw = "123456"
  let mut qn = "20240101000000000"
  let mut flag_text = ""
  let mut split = false
  let mut ack = false
  let mut rf = false
  let mut pnum = -1
  let mut pno = -1
  let mut i = 0
  while i < args.length() {
    let key = args[i]
    let has_next = i + 1 < args.length()
    match key {
      "--cn" =>
        if has_next {
          cn = args[i + 1]
          i = i + 1
        }
      "--mn" =>
        if has_next {
          mn = args[i + 1]
          i = i + 1
        }
      "--cp" =>
        if has_next {
          cp = args[i + 1]
          i = i + 1
        }
      "--st" =>
        if has_next {
          st = args[i + 1]
          i = i + 1
        }
      "--pw" =>
        if has_next {
          pw = args[i + 1]
          i = i + 1
        }
      "--qn" =>
        if has_next {
          qn = args[i + 1]
          i = i + 1
        }
      "--flag" =>
        if has_next {
          flag_text = args[i + 1]
          i = i + 1
        }
      "--pnum" =>
        if has_next {
          pnum = parse_int(args[i + 1])
          i = i + 1
        }
      "--pno" =>
        if has_next {
          pno = parse_int(args[i + 1])
          i = i + 1
        }
      "--split" => split = true
      "--ack" => ack = true
      "--rf" => rf = true
      _ => ()
    }
    i = i + 1
  }
  let cp_text = if cp == "" { "&&" + "&&" } else { "&&\{cp}&&" }
  let area = match @lib.DataArea::parse(cp_text) {
    Ok(area) => area
    Err(error) => {
      println("错误: 数据区不合法 — \{error.message()}")
      return 2
    }
  }
  let flag = if flag_text != "" {
    match parse_int_opt(flag_text) {
      Some(v) => @lib.Flag::from_raw(v)
      None => {
        println("错误: --flag 需要 0-255 的整数")
        return 2
      }
    }
  } else {
    @lib.Flag::new(@lib.V2017, split, ack)
  }
  let frame : @lib.Frame = {
    segment: {
      qn,
      st,
      cn,
      pw,
      mn,
      flag,
      pnum: if pnum >= 0 {
        Some(pnum)
      } else {
        None
      },
      pno: if pno >= 0 {
        Some(pno)
      } else {
        None
      },
      rf,
      cp: area,
      extra: [],
    },
  }
  let text = frame.encode()
  // encode() 自带包尾 \r\n；println 会再补一个换行，这里去掉包尾只留一个换行。
  println(text.trim_end(chars="\r\n"))
  0
}

///|
fn parse_int(text : String) -> Int32 {
  match parse_int_opt(text) {
    Some(v) => v
    None => -1
  }
}

///|
fn parse_int_opt(text : String) -> Int32? {
  if text == "" {
    return None
  }
  let mut value = 0
  for c in text {
    if c < '0' || c > '9' {
      return None
    }
    value = value * 10 + (c.to_int() - 48)
  }
  Some(value)
}

///|
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println(usage())
    @sys.exit(0)
  }
  let command = args[1]
  let rest : Array[String] = []
  let mut i = 2
  while i < args.length() {
    rest.push(args[i])
    i = i + 1
  }
  match command {
    "explain" =>
      if rest.length() == 0 {
        println("错误: explain 需要一条报文或一个文件")
        @sys.exit(2)
      } else {
        @sys.exit(cmd_explain(rest[0]))
      }
    "check" =>
      if rest.length() == 0 {
        println("错误: check 需要一条报文或一个文件")
        @sys.exit(2)
      } else {
        @sys.exit(cmd_check(rest[0]))
      }
    "frames" =>
      if rest.length() == 0 {
        println("错误: frames 需要一条报文或一个文件")
        @sys.exit(2)
      } else {
        @sys.exit(cmd_frames(rest[0]))
      }
    "encode" => @sys.exit(cmd_encode(rest))
    "convert" => @sys.exit(cmd_convert(rest))
    "quality" => @sys.exit(cmd_quality(rest))
    "stats" => @sys.exit(cmd_stats(rest))
    "pack" =>
      if rest.length() == 0 {
        println("错误: pack 需要含分包帧的报文或文件")
        @sys.exit(2)
      } else {
        @sys.exit(cmd_pack(rest[0]))
      }
    "crc" =>
      if rest.length() == 0 {
        println(
          "错误: crc 需要一个数据段（不含 ## 与长度字段）",
        )
        @sys.exit(2)
      } else {
        println("CRC      \{@lib.crc16_hex(rest[0])}")
        println("长度     \{@lib.utf8_len(rest[0])} 字节")
        println("数据段   \{rest[0]}")
        @sys.exit(0)
      }
    "-h" | "--help" | "help" => {
      println(usage())
      @sys.exit(0)
    }
    "-v" | "--version" | "version" => {
      println("mbt-datapoint \{VERSION}")
      @sys.exit(0)
    }
    _ => {
      println("未知子命令「\{command}」\n")
      println(usage())
      @sys.exit(2)
    }
  }
}

///|
fn pad3(value : Int32) -> String {
  let s = value.to_string()
  let mut pad = 3 - s.length()
  if pad < 0 {
    pad = 0
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < pad {
    sb.write_char(' ')
    i = i + 1
  }
  sb.write_string(s)
  sb.to_string()
}
