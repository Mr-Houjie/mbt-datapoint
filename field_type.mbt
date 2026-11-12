// 数据类型（标准 6.3.3.2.2 类型定义表）。
//
// 这一层只回答两个问题：这个类型字符串怎么解析、某个取值是否满足该类型。
// 它不认识具体字段名，也不绑定任何命令，方便上层用同一套规则校验数据区。

///|
/// 解析类型字符串，例如 `C4`、`N5`、`N14.2`、`YYYY`。
pub fn FieldType::parse(text : String) -> FieldType? {
  let t = trim_text(text)
  if t == "YYYY" {
    return Some(Year)
  }
  if t == "MM" {
    return Some(Month)
  }
  if t == "DD" {
    return Some(Day)
  }
  if t == "hh" {
    return Some(Hour)
  }
  if t == "mm" {
    return Some(Minute)
  }
  if t == "ss" {
    return Some(Second)
  }
  if t == "zzz" {
    return Some(Millisecond)
  }
  let cs = chars_of(t)
  if cs.length() < 2 {
    return None
  }
  let head = cs[0]
  if head == 'C' {
    let n = parse_uint(cs, 1, cs.length() - 1)
    match n {
      Some(width) => if width > 0 { Some(Chars(width)) } else { None }
      None => None
    }
  } else if head == 'N' {
    // N5 或者 N14.2
    let mut dot = -1
    let mut i = 1
    while i < cs.length() {
      if cs[i] == '.' {
        dot = i
        break
      } else if !is_digit_char(cs[i]) {
        return None
      }
      i = i + 1
    }
    if dot < 0 {
      match parse_uint(cs, 1, cs.length() - 1) {
        Some(int_digits) =>
          if int_digits > 0 {
            Some(Number(int_digits, 0))
          } else {
            None
          }
        None => None
      }
    } else {
      let int_part = parse_uint(cs, 1, dot - 1)
      let frac_part = parse_uint(cs, dot + 1, cs.length() - dot - 1)
      match (int_part, frac_part) {
        (Some(id), Some(fd)) => if id > 0 { Some(Number(id, fd)) } else { None }
        _ => None
      }
    }
  } else {
    None
  }
}

///|
/// 把类型渲染回字符串形式。
pub fn FieldType::text(self : FieldType) -> String {
  match self {
    Chars(n) => "C\{n}"
    Number(id, 0) => "N\{id}"
    Number(id, fd) => "N\{id}.\{fd}"
    Year => "YYYY"
    Month => "MM"
    Day => "DD"
    Hour => "hh"
    Minute => "mm"
    Second => "ss"
    Millisecond => "zzz"
  }
}

///|
/// 校验取值是否满足类型；满足返回 `None`，否则返回原因。
pub fn FieldType::check(self : FieldType, value : String) -> String? {
  let cs = chars_of(value)
  let n = cs.length()
  match self {
    Chars(max) =>
      if n <= max {
        None
      } else {
        Some("最多 \{max} 个字符，实际 \{n} 个")
      }
    Number(int_digits, frac_digits) => {
      let mut i = 0
      if n > 0 && (cs[0] == '-' || cs[0] == '+') {
        i = 1
      }
      let int_start = i
      while i < n && is_digit_char(cs[i]) {
        i = i + 1
      }
      let int_len = i - int_start
      if int_len == 0 {
        return Some("缺少整数部分")
      }
      if int_len > int_digits {
        return Some(
          "整数部分最多 \{int_digits} 位，实际 \{int_len} 位",
        )
      }
      if i == n {
        return None
      }
      if cs[i] != '.' {
        return Some("出现非数字字符 \"\{cs[i]}\"")
      }
      let frac_start = i + 1
      let mut j = frac_start
      while j < n && is_digit_char(cs[j]) {
        j = j + 1
      }
      let frac_len = j - frac_start
      if frac_len > frac_digits {
        return Some(
          "小数部分最多 \{frac_digits} 位，实际 \{frac_len} 位",
        )
      }
      if j != n {
        return Some("小数部分出现非数字字符")
      }
      None
    }
    Year => check_digit_width(cs, 4, "年")
    Month => check_digit_width(cs, 2, "月")
    Day => check_digit_width(cs, 2, "日")
    Hour => check_digit_width(cs, 2, "时")
    Minute => check_digit_width(cs, 2, "分")
    Second => check_digit_width(cs, 2, "秒")
    Millisecond => check_digit_width(cs, 3, "毫秒")
  }
}

///|
fn check_digit_width(
  cs : Array[Char],
  width : Int32,
  label : String,
) -> String? {
  if cs.length() != width {
    return Some("\{label}应为 \{width} 位数字，实际 \{cs.length()} 位")
  }
  let mut i = 0
  while i < cs.length() {
    if !is_digit_char(cs[i]) {
      return Some("\{label}必须是数字")
    }
    i = i + 1
  }
  None
}
