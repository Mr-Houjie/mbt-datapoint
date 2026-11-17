// 数据质量规则引擎。
//
// 编解码只能回答「这帧收得下来吗」，回答不了「这个数可信吗」。
// 采集链路里真正费人工的是后一件事：传感器超量程、时间戳缺失、
// 状态码出现没登记的值，这些帧都是合法的，但数据不能直接入库。
//
// 规则层刻意只作用于 Point，不认识 HJ 212。任何来源的数据点都能
// 拿同一套规则校验，也都能用同一份文本配置描述规则。

///|
pub(all) enum Severity {
  Info
  Warning
  Error
}

///|
pub impl Eq for Severity with fn equal(self : Severity, other : Severity) -> Bool {
  self.label() == other.label()
}

///|
pub extend Severity with Eq::{not_equal, equal}

///|
pub fn Severity::label(self : Severity) -> String {
  match self {
    Info => "info"
    Warning => "warning"
    Error => "error"
  }
}

///|
/// 一条校验结果。
pub(all) struct Finding {
  severity : Severity
  field : String
  message : String
}

///|
pub fn Finding::text(self : Finding) -> String {
  "[\{self.severity.label()}] \{self.field}: \{self.message}"
}

///|
/// 一条规则。
pub(all) enum Rule {
  /// 数值字段必须落在闭区间内
  Range(String, Double, Double)
  /// 字段必须存在且至少有一个非缺失值
  Required(String)
  /// 字段的取值必须都是数值
  Numeric(String)
  /// 文本字段只允许给定取值（设备状态码白名单）
  AllowedText(String, Array[String])
}

///|
pub fn Rule::text(self : Rule) -> String {
  match self {
    Range(name, lo, hi) => "range \{name} \{lo} \{hi}"
    Required(name) => "required \{name}"
    Numeric(name) => "numeric \{name}"
    AllowedText(name, allowed) => "allowed \{name} \{join_with(allowed, ",")}"
  }
}

///|
fn join_with(values : Array[String], sep : String) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < values.length() {
    if i > 0 {
      sb.write_string(sep)
    }
    sb.write_string(values[i])
    i = i + 1
  }
  sb.to_string()
}

///|
/// 一组规则。
pub(all) struct RuleSet {
  rules : Array[Rule]
}

///|
pub fn RuleSet::new() -> RuleSet {
  { rules: [], }
}

///|
pub fn RuleSet::add(self : RuleSet, rule : Rule) -> Unit {
  self.rules.push(rule)
}

///|
pub fn RuleSet::length(self : RuleSet) -> Int32 {
  self.rules.length()
}

///|
/// 校验一个数据点，返回全部发现的问题。
///
/// 分工：Range 只管数值越界，Required 只管缺失，Numeric 只管类型。
/// 缺字段时 Range 不重复报一次「越界」，否则同一个问题会在报告里
/// 出现两遍，反而看不出根因。
pub fn RuleSet::check(self : RuleSet, point : Point) -> Array[Finding] {
  let out : Array[Finding] = []
  for rule in self.rules {
    match rule {
      Range(name, lo, hi) =>
        match point.field(name) {
          None => ()
          Some(f) =>
            for v in f.values {
              match v {
                Num(n) =>
                  if n < lo || n > hi {
                    out.push({
                      severity: Error,
                      field: name,
                      message: "数值 \{n} 超出允许区间 [\{lo}, \{hi}]",
                    })
                  }
                _ => ()
              }
            }
        }
      Required(name) =>
        match point.field(name) {
          None =>
            out.push({
              severity: Error,
              field: name,
              message: "缺少必需字段",
            })
          Some(f) =>
            if f.numbers().length() == 0 && all_missing(f) {
              out.push({
                severity: Error,
                field: name,
                message: "字段存在但没有有效取值",
              })
            }
        }
      Numeric(name) =>
        match point.field(name) {
          None => ()
          Some(f) =>
            for v in f.values {
              match v {
                Num(_) | Missing => ()
                Text(s) =>
                  out.push({
                    severity: Warning,
                    field: name,
                    message: "期望数值，实际是 \"\{s}\"",
                  })
              }
            }
        }
      AllowedText(name, allowed) =>
        match point.field(name) {
          None => ()
          Some(f) =>
            for v in f.values {
              match v {
                Text(s) =>
                  if !allowed.contains(s) {
                    out.push({
                      severity: Warning,
                      field: name,
                      message: "未登记的取值 \"\{s}\"",
                    })
                  }
                _ => ()
              }
            }
        }
    }
  }
  out
}

///|
fn all_missing(f : Field) -> Bool {
  for v in f.values {
    match v {
      Missing => ()
      _ => return false
    }
  }
  true
}

///|
/// 一组发现里最严重的级别。没有问题时返回 None。
pub fn worst(findings : Array[Finding]) -> Severity? {
  let mut result : Severity? = None
  for f in findings {
    match (result, f.severity) {
      (_, Error) => return Some(Error)
      (Some(Warning), _) => ()
      (_, Warning) => result = Some(Warning)
      (None, Info) => result = Some(Info)
      _ => ()
    }
  }
  result
}

///|
pub fn count_severity(findings : Array[Finding], level : Severity) -> Int32 {
  let mut n = 0
  for f in findings {
    match (f.severity, level) {
      (Error, Error) | (Warning, Warning) | (Info, Info) => n = n + 1
      _ => ()
    }
  }
  n
}

// ---------------------------------------------------------------------------
// 文本规则配置
//
// 每行一条规则，用空白分隔，# 开头是注释。这样现场调量程、加必填项
// 不用改代码、不用重新编译。
//
//   range   a34013-Rtd  0   500
//   required DataTime
//   numeric  cpu_load
//   allowed  a34013-Flag N,T,B,D,F
// ---------------------------------------------------------------------------

///|
/// 解析文本配置。语法不对的行原样跳过并返回说明，不静默忽略。
pub fn RuleSet::from_text(text : String) -> (RuleSet, Array[String]) {
  let set = RuleSet::new()
  let errors : Array[String] = []
  for line in text.split("\n") {
    let parts = split_whitespace(trim_text(line.to_owned()))
    if parts.length() == 0 || parts[0].has_prefix("#") {
      continue
    }
    match parts[0] {
      "range" =>
        if parts.length() != 4 {
          errors.push("range 需要 4 段: range <字段> <最小> <最大>")
        } else {
          match (parse_float_text(parts[2]), parse_float_text(parts[3])) {
            (Some(lo), Some(hi)) => set.add(Range(parts[1], lo, hi))
            _ => errors.push("range 的上下界不是数字: \{line}")
          }
        }
      "required" =>
        if parts.length() != 2 {
          errors.push("required 需要 2 段: required <字段>")
        } else {
          set.add(Required(parts[1]))
        }
      "numeric" =>
        if parts.length() != 2 {
          errors.push("numeric 需要 2 段: numeric <字段>")
        } else {
          set.add(Numeric(parts[1]))
        }
      "allowed" =>
        if parts.length() != 3 {
          errors.push("allowed 需要 3 段: allowed <字段> <值,值,...>")
        } else {
          set.add(AllowedText(parts[1], split_on(parts[2], ',')))
        }
      other => errors.push("未知规则 \"\{other}\"")
    }
  }
  (set, errors)
}

///|
fn split_whitespace(s : String) -> Array[String] {
  let out : Array[String] = []
  let cs = chars_of(s)
  let mut start = 0
  let mut i = 0
  while i <= cs.length() {
    if i == cs.length() || is_space_char(cs[i]) {
      if i > start {
        out.push(slice_chars(cs, start, i))
      }
      start = i + 1
    }
    i = i + 1
  }
  out
}

///|
fn split_on(s : String, sep : Char) -> Array[String] {
  let out : Array[String] = []
  let sb = StringBuilder()
  for c in s {
    if c == sep {
      out.push(sb.to_string())
      sb.reset()
    } else {
      sb.write_char(c)
    }
  }
  out.push(sb.to_string())
  out
}
