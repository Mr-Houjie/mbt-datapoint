// 语料自检。
//
// 把 corpus/ 下的帧逐条跑一遍，确认三件事：
//   1. 合法帧能解码，且长度字段、CRC 与算法一致；
//   2. 解码再编码得到的字节与原文件完全相同（往返一致）；
//   3. 非法帧必须被拒绝，且错误类型与文件名声明的一致。
//
// 这个命令的价值不在于"再跑一遍单测"，而在于它把语料当成外部输入：
// 语料是文件，不是代码里的字符串常量，换一批现场报文不用改一行代码。

///|
fn join_path(dir : String, name : String) -> String {
  if dir.has_suffix("/") || dir.has_suffix("\\") {
    "\{dir}\{name}"
  } else {
    "\{dir}/\{name}"
  }
}

///|
fn read_text(path : String) -> String? {
  let mut result : String? = None
  try {
    result = Some(@fs.read_file_to_string(path))
  } catch {
    _ => ()
  }
  result
}

///|
fn list_files(dir : String) -> Array[String] {
  let out : Array[String] = []
  try {
    for name in @fs.read_dir(dir) {
      if name.has_suffix(".frame") {
        out.push(name)
      }
    }
  } catch {
    _ => ()
  }
  out.sort()
  out
}

///|
// 文件名形如 `badcrc__重复的校验码.frame`，下划线前是期望的错误类型。
fn expected_error(name : String) -> String {
  let sb = StringBuilder()
  for c in name {
    if c == '_' {
      break
    }
    sb.write_char(c)
  }
  sb.to_string()
}

///|
// 分包组的文件名形如 `split-3__p1.frame`，`__` 前是同组前缀。
fn group_prefix(name : String) -> String {
  let sb = StringBuilder()
  let mut prev_underscore = false
  for c in name {
    if c == '_' {
      if prev_underscore {
        break
      }
      prev_underscore = true
    } else {
      prev_underscore = false
    }
    sb.write_char(c)
  }
  let raw = sb.to_string()
  raw.trim_end(chars="_").to_owned()
}

///|
/// 把同一组的分包帧喂进同一台重组器，要求最终拼成一条完整数据区。
fn check_split_group(
  dir : String,
  prefix : String,
  names : Array[String],
) -> Bool {
  let r = @lib.Reassembler::new()
  let mut merged : @lib.DataArea? = None
  let mut failure = ""
  for name in names {
    if merged is Some(_) {
      // 已经收齐，同组不该再有帧；有就说明语料本身写错了
      continue
    }
    let raw = match read_text(join_path(dir, name)) {
      Some(text) => text
      None => {
        println("  FAIL \{name}  读不出文件")
        return false
      }
    }
    match @lib.Frame::decode(raw) {
      Err(error) => {
        println("  FAIL \{name}  \{error.kind()}：\{error.message()}")
        return false
      }
      Ok(frame) =>
        match r.push(frame) {
          @lib.Pending(_, _) => ()
          @lib.Complete(area) => merged = Some(area)
          @lib.Conflict(reason) => failure = reason
          @lib.NotSplit => failure = "未声明分包"
        }
    }
  }
  match merged {
    Some(area) => {
      println(
        "  OK   \{prefix}  \{names.length()} 包 → \{area.length()} 项",
      )
      true
    }
    None => {
      let why = if failure == "" { "未收齐" } else { failure }
      println("  FAIL \{prefix}  \{why}")
      false
    }
  }
}

///|
/// 校验一条合法帧。返回 `true` 表示通过。
fn check_good(dir : String, name : String) -> Bool {
  let path = join_path(dir, name)
  let raw = match read_text(path) {
    Some(text) => text
    None => {
      println("  FAIL \{name}  读不出文件")
      return false
    }
  }
  match @lib.Frame::decode(raw) {
    Err(error) => {
      println("  FAIL \{name}  \{error.kind()}：\{error.message()}")
      false
    }
    Ok(frame) => {
      let segment = frame.segment.text()
      let bytes = @lib.utf8_len(segment)
      let crc = @lib.crc16_hex(segment)
      let again = frame.encode()
      if again != raw {
        println("  FAIL \{name}  解码再编码与原文件不一致")
        return false
      }
      println("  OK   \{name}  \{bytes} 字节  CRC \{crc}")
      true
    }
  }
}

///|
fn main {
  let args = @env.args()
  let dir = if args.length() > 1 { args[1] } else { "corpus" }
  let good_dir = join_path(dir, "good")
  let edge_dir = join_path(dir, "edge")
  let split_dir = join_path(dir, "split")
  let bad_dir = join_path(dir, "bad")
  let stream_dir = join_path(dir, "stream")
  let rules_dir = join_path(dir, "rules")

  if !@fs.path_exists(dir) {
    println("找不到语料目录「\{dir}」")
    println("用法: mbt-hj212-verify [语料目录]")
    @sys.exit(2)
  }

  let mut total = 0
  let mut passed = 0

  println("合法帧  \{good_dir}")
  for name in list_files(good_dir) {
    total = total + 1
    if check_good(good_dir, name) {
      passed = passed + 1
    }
  }

  println("")
  println("扩展帧  \{edge_dir}")
  for name in list_files(edge_dir) {
    total = total + 1
    if check_good(edge_dir, name) {
      passed = passed + 1
    }
  }

  println("")
  println("分包组  \{split_dir}")
  let split_names = list_files(split_dir)
  let seen : Array[String] = []
  for name in split_names {
    let prefix = group_prefix(name)
    if !seen.contains(prefix) {
      seen.push(prefix)
      total = total + 1
      let group : Array[String] = []
      for other in split_names {
        if group_prefix(other) == prefix {
          group.push(other)
        }
      }
      if check_split_group(split_dir, prefix, group) {
        passed = passed + 1
      }
    }
  }

  println("")
  println("非法帧  \{bad_dir}")
  for name in list_files(bad_dir) {
    total = total + 1
    let path = join_path(bad_dir, name)
    let raw = match read_text(path) {
      Some(text) => text
      None => {
        println("  FAIL \{name}  读不出文件")
        continue
      }
    }
    let want = expected_error(name)
    match @lib.Frame::decode(raw) {
      Ok(_) => println("  FAIL \{name}  本应被拒绝，却解码成功")
      Err(error) =>
        if error.kind() == want {
          passed = passed + 1
          println("  OK   \{name}")
        } else {
          println(
            "  FAIL \{name}  期望 \{want}，实际 \{error.kind()}（\{error.message()}）",
          )
        }
    }
  }

  println("")
  println("数据流  \{stream_dir}")
  // 期望值：mixed.stream 里 5 条合法帧、1 条 CRC 坏帧、1 组 2 片分包合成 1 条，
  // 初始还有一行噪声被跳过，所以是 帧 5 / 拒绝 1 / 数据点 4。
  for name in list_files_ext(stream_dir, ".stream") {
    total = total + 1
    if check_stream(stream_dir, name, 5, 1, 4) {
      passed = passed + 1
    }
  }

  println("")
  println("规则  \{rules_dir}")
  for name in list_files_ext(rules_dir, ".rules") {
    total = total + 1
    // demo.rules 目前 8 条规则：5 个 range、1 个 required、2 个 allowed
    if check_rules(rules_dir, name, 8) {
      passed = passed + 1
    }
  }
  total = total + 1
  if check_rule_hit(
      join_path(edge_dir, "many-items.frame"),
      join_path(rules_dir, "demo.rules"),
      1,
      1,
    ) {
    passed = passed + 1
  }

  println("")
  println("\{passed}/\{total} 通过")
  if passed != total {
    @sys.exit(1)
  }
}
