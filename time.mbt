// QN 请求编码：`YYYYMMDDhhmmsszzz`。
//
// 标准表里写 QN 是 20 位，但同一份标准的示例是 17 位
// （`20160801085857223`），现场设备也基本按 17 位实现。
// 这里按 17 位解析，同时容忍尾部多出的数字。

///|
pub(all) struct QnTime {
  year : Int32
  month : Int32
  day : Int32
  hour : Int32
  minute : Int32
  second : Int32
  millis : Int32
}

///|
pub fn QnTime::parse(qn : String) -> QnTime? {
  let cs = chars_of(trim_text(qn))
  if cs.length() < 17 {
    return None
  }
  let year = parse_uint(cs, 0, 4)
  let month = parse_uint(cs, 4, 2)
  let day = parse_uint(cs, 6, 2)
  let hour = parse_uint(cs, 8, 2)
  let minute = parse_uint(cs, 10, 2)
  let second = parse_uint(cs, 12, 2)
  let millis = parse_uint(cs, 14, 3)
  match (year, month, day, hour, minute, second, millis) {
    (Some(y), Some(mo), Some(d), Some(h), Some(mi), Some(s), Some(ms)) => {
      if mo < 1 || mo > 12 {
        return None
      }
      if d < 1 || d > 31 {
        return None
      }
      if h > 23 || mi > 59 || s > 60 {
        return None
      }
      Some({
        year: y,
        month: mo,
        day: d,
        hour: h,
        minute: mi,
        second: s,
        millis: ms,
      })
    }
    _ => None
  }
}

///|
/// 渲染成 `YYYY-MM-DD hh:mm:ss.zzz`。
pub fn QnTime::text(self : QnTime) -> String {
  "\{zero_pad(self.year, 4)}-\{zero_pad(self.month, 2)}-\{zero_pad(self.day, 2)} " +
  "\{zero_pad(self.hour, 2)}:\{zero_pad(self.minute, 2)}:\{zero_pad(self.second, 2)}.\{zero_pad(self.millis, 3)}"
}

///|
/// 由分段时间构造 QN。
pub fn QnTime::to_qn(self : QnTime) -> String {
  "\{zero_pad(self.year, 4)}\{zero_pad(self.month, 2)}\{zero_pad(self.day, 2)}" +
  "\{zero_pad(self.hour, 2)}\{zero_pad(self.minute, 2)}\{zero_pad(self.second, 2)}\{zero_pad(self.millis, 3)}"
}
