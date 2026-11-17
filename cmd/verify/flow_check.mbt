// 自检的第二部分：整条流，而不是单帧。
//
// 前面的检查逐条读文件，证明「一帧能解开」。但真正上线跑的是
// 「一段 TCP 流里混着正常帧、坏帧、分包和噪声」，这一节就是把
// 那种情况做成语料，用管道跑一遍，核对每个计数。
//
// 期望值写死在调用处，而不是从文件名里猜：数字对不上时应当立刻
// 失败，而不是"自动适应"。

///|
fn list_files_ext(dir : String, ext : String) -> Array[String] {
  let out : Array[String] = []
  try {
    for name in @fs.read_dir(dir) {
      if name.has_suffix(ext) {
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
/// 跑一遍数据流，核对帧数、拒绝数、数据点数。
fn check_stream(
  dir : String,
  name : String,
  want_frames : Int32,
  want_rejected : Int32,
  want_points : Int32,
) -> Bool {
  let path = join_path(dir, name)
  let raw = match read_text(path) {
    Some(text) => text
    None => {
      println("  FAIL \{name}  读不出文件")
      return false
    }
  }
  let pipeline = @lib.Pipeline::new(@lib.RuleSet::new(), @lib.Ndjson, [])
  let out = pipeline.run(raw)
  let stats = pipeline.stats()
  let ok = stats.frames() == want_frames &&
    stats.rejected() == want_rejected &&
    stats.points() == want_points &&
    out != ""
  if ok {
    println(
      "  OK   \{name}  帧 \{stats.frames()} · 拒绝 \{stats.rejected()} · 数据点 \{stats.points()}",
    )
  } else {
    println(
      "  FAIL \{name}  期望 帧 \{want_frames} · 拒绝 \{want_rejected} · 数据点 \{want_points}，实际 帧 \{stats.frames()} · 拒绝 \{stats.rejected()} · 数据点 \{stats.points()}",
    )
  }
  ok
}

///|
/// 解析一份规则配置，要求语法零错误、规则条数与预期一致。
fn check_rules(dir : String, name : String, want_count : Int32) -> Bool {
  let path = join_path(dir, name)
  let raw = match read_text(path) {
    Some(text) => text
    None => {
      println("  FAIL \{name}  读不出文件")
      return false
    }
  }
  let (set, errors) = @lib.RuleSet::from_text(raw)
  if errors.length() > 0 {
    println(
      "  FAIL \{name}  有 \{errors.length()} 行语法不对：\{errors[0]}",
    )
    return false
  }
  if set.length() != want_count {
    println(
      "  FAIL \{name}  期望 \{want_count} 条规则，实际 \{set.length()} 条",
    )
    return false
  }
  println("  OK   \{name}  \{set.length()} 条规则，语法无误")
  true
}

///|
/// 用规则校验一条已知有问题的报文，核对命中的问题数。
///
/// 这里盯的是「规则真的接上了」，而不是规则本身写得对不对：
/// many-items 没有 DataTime 字段，而规则里 required DataTime 必须命中。
fn check_rule_hit(
  frame_path : String,
  rules_path : String,
  want_findings : Int32,
  want_errors : Int32,
) -> Bool {
  let frame_raw = match read_text(frame_path) {
    Some(text) => text
    None => {
      println("  FAIL 读不出 \{frame_path}")
      return false
    }
  }
  let rules_raw = match read_text(rules_path) {
    Some(text) => text
    None => {
      println("  FAIL 读不出 \{rules_path}")
      return false
    }
  }
  let (rules, _) = @lib.RuleSet::from_text(rules_raw)
  let pipeline = @lib.Pipeline::new(rules, @lib.Ndjson, [])
  let outputs = pipeline.feed(frame_raw)
  if outputs.length() != 1 {
    println(
      "  FAIL 规则命中检查  期望 1 个数据点，实际 \{outputs.length()} 个",
    )
    return false
  }
  let findings = outputs[0].findings
  let errors = @lib.count_severity(findings, @lib.Error)
  let ok = findings.length() == want_findings && errors == want_errors
  if ok {
    println(
      "  OK   rules-hit  命中 \{findings.length()} 项（错误 \{errors}）",
    )
  } else {
    println(
      "  FAIL rules-hit  期望 \{want_findings} 项 / 错误 \{want_errors}，实际 \{findings.length()} 项 / 错误 \{errors}",
    )
  }
  ok
}
