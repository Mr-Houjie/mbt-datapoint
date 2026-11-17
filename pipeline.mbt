// 端到端处理管道。
//
// 前面几层各自都能单独用，但现场最常见的诉求是一句话：
// 「给我一段 TCP 字节流，还我可以直接写进库的数据」。
// Pipeline 把 分帧 → 解码 → 分包重组 → 转 Point → 规则校验 → 导出
// 串成一次 feed，并保留全过程统计，方便接监控。

///|
/// 全链路计数。字段对外只读，通过访问器取值，避免调用方直接改统计。
pub struct Stats {
  mut frames : Int32
  mut rejected : Int32
  mut points : Int32
  mut findings : Int32
  mut errors : Int32
  mut overflow : Int32
  mut dropped_groups : Int32
  mut pending_parts : Int32
}

///|
pub fn Stats::new() -> Stats {
  {
    frames: 0,
    rejected: 0,
    points: 0,
    findings: 0,
    errors: 0,
    overflow: 0,
    dropped_groups: 0,
    pending_parts: 0,
  }
}

///|
pub fn Stats::frames(self : Stats) -> Int32 {
  self.frames
}

///|
pub fn Stats::rejected(self : Stats) -> Int32 {
  self.rejected
}

///|
pub fn Stats::points(self : Stats) -> Int32 {
  self.points
}

///|
pub fn Stats::errors(self : Stats) -> Int32 {
  self.errors
}

///|
pub fn Stats::findings(self : Stats) -> Int32 {
  self.findings
}

///|
pub fn Stats::overflow(self : Stats) -> Int32 {
  self.overflow
}

///|
pub fn Stats::dropped_groups(self : Stats) -> Int32 {
  self.dropped_groups
}

///|
pub fn Stats::pending_parts(self : Stats) -> Int32 {
  self.pending_parts
}

///|
pub fn Stats::text(self : Stats) -> String {
  "帧 \{self.frames} · 拒绝 \{self.rejected} · 数据点 \{self.points} · 发现 \{self.findings}（错误 \{self.errors}） · 缓冲区丢弃 \{self.overflow} · 未完成分包组 \{self.dropped_groups} · 待收分片 \{self.pending_parts}"
}

///|
pub fn Stats::to_json(self : Stats) -> String {
  "{\"frames\":\{self.frames},\"rejected\":\{self.rejected},\"points\":\{self.points},\"findings\":\{self.findings},\"errors\":\{self.errors},\"overflow\":\{self.overflow},\"dropped_groups\":\{self.dropped_groups},\"pending_parts\":\{self.pending_parts}}"
}

///|
/// 一条产出：数据点、校验结果、按目标格式渲染好的一行。
pub(all) struct Output {
  point : Point
  findings : Array[Finding]
  line : String
}

///|
/// 管道本体。构造后反复 feed 即可，内部保留分帧与重组的残余状态。
pub struct Pipeline {
  framer : Framer
  reassembler : Reassembler
  rules : RuleSet
  format : Format
  columns : Array[String]
  stats : Stats
  mut group_meta : Point?
}

///|
pub fn Pipeline::new(
  rules : RuleSet,
  format : Format,
  columns : Array[String],
) -> Pipeline {
  {
    framer: Framer::new(),
    reassembler: Reassembler::new(),
    rules,
    format,
    columns,
    stats: Stats::new(),
    group_meta: None,
  }
}

///|
pub fn Pipeline::stats(self : Pipeline) -> Stats {
  self.stats
}

///|
pub fn Pipeline::format(self : Pipeline) -> Format {
  self.format
}

///|
pub fn Pipeline::header(self : Pipeline) -> String {
  match self.format {
    Csv => csv_header(self.columns)
    _ => ""
  }
}

///|
fn is_error(s : Severity) -> Bool {
  match s {
    Error => true
    _ => false
  }
}

///|
fn emit(
  point : Point,
  rules : RuleSet,
  format : Format,
  columns : Array[String],
  stats : Stats,
  out : Array[Output],
) -> Unit {
  let findings = rules.check(point)
  stats.points = stats.points + 1
  stats.findings = stats.findings + findings.length()
  for f in findings {
    if is_error(f.severity) {
      stats.errors = stats.errors + 1
    }
  }
  out.push({ point, findings, line: render_line(point, format, columns), })
}

///|
/// 喂入一段文本，返回这段文本里能确认的全部产出。
///
/// 分包帧不会逐片出数据点：会先送进重组器，收齐后按包号拼成一条
/// 完整数据点再输出。这样上层拿到的永远是逻辑完整的一条记录。
pub fn Pipeline::feed(self : Pipeline, chunk : String) -> Array[Output] {
  let out : Array[Output] = []
  for event in self.framer.feed(chunk) {
    match event {
      Good(frame) => {
        self.stats.frames = self.stats.frames + 1
        if frame.segment.flag.is_split() {
          let meta = frame.to_point()
          if self.group_meta is None {
            self.group_meta = Some(
              Point::new(meta.timestamp, meta.source, meta.measurement),
            )
          }
          self.stats.pending_parts = self.stats.pending_parts + 1
          match self.reassembler.push(frame) {
            Pending(_, _) => ()
            Complete(area) => {
              let merged = match self.group_meta {
                Some(m) => Point::new(m.timestamp, m.source, m.measurement)
                None =>
                  Point::new(meta.timestamp, meta.source, meta.measurement)
              }
              merged.add_area(area)
              emit(
                merged,
                self.rules,
                self.format,
                self.columns,
                self.stats,
                out,
              )
              self.group_meta = None
              self.stats.pending_parts = 0
            }
            Conflict(_) => {
              self.stats.rejected = self.stats.rejected + 1
              self.group_meta = None
              self.stats.pending_parts = 0
            }
            NotSplit => ()
          }
        } else {
          emit(
            frame.to_point(),
            self.rules,
            self.format,
            self.columns,
            self.stats,
            out,
          )
        }
      }
      Bad(_, _) => self.stats.rejected = self.stats.rejected + 1
      Noise(_) => ()
      Overflow(_) => self.stats.overflow = self.stats.overflow + 1
    }
  }
  self.stats.dropped_groups = self.reassembler.dropped()
  out
}

///|
/// 一次性处理整段文本，返回渲染结果。
///
/// 刻意复用 feed，而不是另写一遍：统计口径与流式调用必须完全一致，
/// 否则「批量跑一遍看看」和「上线跑流」会得到两套数字。
pub fn Pipeline::run(self : Pipeline, text : String) -> String {
  let outputs = self.feed(text)
  let points : Array[Point] = []
  for o in outputs {
    points.push(o.point)
  }
  render_all(points, self.format, self.columns)
}
