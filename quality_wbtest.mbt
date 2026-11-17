// 规则引擎测试。
//
// 校验最容易出的问题不是漏报，是同一个根因被报好几遍：
// 缺字段时既报「缺少」又报「越界」，报告反而没法看。

///|
test "文本配置解析四种规则" {
  let config = "# 现场量程\nrange a34013-Rtd 0 500\nrequired DataTime\nnumeric cpu_load\nallowed a34013-Flag N,T,B,D,F\n"
  let (set, errors) = RuleSet::from_text(config)
  assert_eq(errors.length(), 0)
  assert_eq(set.length(), 4)
  assert_eq(set.rules[0].text(), "range a34013-Rtd 0 500")
}

///|
test "配置里的错误行会被说明，不静默忽略" {
  let config = "range a 0\nbogus x\nrange b x 5\nrequired\nallowed c\n"
  let (set, errors) = RuleSet::from_text(config)
  assert_eq(set.length(), 0)
  assert_eq(errors.length(), 5)
}

///|
test "数值越界报 Error" {
  let (set, _) = RuleSet::from_text("range temp_c -10 40\n")
  let p = Point::new("t", "s", "m")
  p.add("temp_c", Num(41.5))
  let findings = set.check(p)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].severity.label(), "error")
  assert_eq(findings[0].field, "temp_c")
  assert_true(findings[0].message.contains("超出"))
}

///|
test "区间端点算合法，多个取值逐个检查" {
  let (set, _) = RuleSet::from_text("range x 0 10\n")
  let p = Point::new("t", "s", "m")
  p.add("x", Num(0.0))
  p.add("x", Num(10.0))
  assert_eq(set.check(p).length(), 0)
  p.add("x", Num(10.1))
  assert_eq(set.check(p).length(), 1)
}

///|
test "缺字段只报一次，不与 Range 重复" {
  let (set, _) = RuleSet::from_text("range x 0 10\nrequired x\n")
  let p = Point::new("t", "s", "m")
  let findings = set.check(p)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].severity.label(), "error")
  assert_true(findings[0].message.contains("缺少"))
}

///|
test "字段存在但全为空值报 Error" {
  let (set, _) = RuleSet::from_text("required x\n")
  let p = Point::new("t", "s", "m")
  p.add("x", Missing)
  let findings = set.check(p)
  assert_eq(findings.length(), 1)
  assert_true(findings[0].message.contains("没有有效取值"))
}

///|
test "Numeric 对文本报 Warning，对数值和空值不报" {
  let (set, _) = RuleSet::from_text("numeric v\n")
  let p = Point::new("t", "s", "m")
  p.add("v", Num(1.0))
  p.add("v", Missing)
  assert_eq(set.check(p).length(), 0)
  p.add("v", Text("N"))
  let findings = set.check(p)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].severity.label(), "warning")
}

///|
test "状态码白名单" {
  let (set, _) = RuleSet::from_text("allowed flag N,T,B,D\n")
  let p = Point::new("t", "s", "m")
  p.add("flag", Text("N"))
  assert_eq(set.check(p).length(), 0)
  p.add("flag", Text("Z"))
  let findings = set.check(p)
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].severity.label(), "warning")
  assert_true(findings[0].message.contains("未登记"))
}

///|
test "worst 与 count_severity" {
  let findings : Array[Finding] = [
    { severity: Info, field: "a", message: "", },
    { severity: Warning, field: "b", message: "", },
    { severity: Error, field: "c", message: "", },
    { severity: Error, field: "d", message: "", },
  ]
  assert_true(worst(findings) == Some(Error))
  assert_eq(count_severity(findings, Error), 2)
  assert_eq(count_severity(findings, Warning), 1)
  assert_eq(count_severity(findings, Info), 1)
  assert_true(worst([]) is None)
}

///|
test "Finding 文本带级别与字段名" {
  let f : Finding = { severity: Warning, field: "x", message: "偏低", }
  assert_eq(f.text(), "[warning] x: 偏低")
}
