// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "Mr-Houjie/mbt-hj212"

version = "0.2.0"

readme = "README.md"

repository = "https://github.com/Mr-Houjie/mbt-hj212"

license = "MIT"

keywords = [
  "hj212",
  "time-series",
  "data-quality",
  "protocol",
  "codec",
  "etl",
  "iot",
  "cli",
]

preferred_target = "native"

description = "HJ 212 报文 → 可入库的时序数据：流式分帧、分包重组、协议无关数据模型、规则校验引擎、JSON/CSV/InfluxDB 导出与端到端管道。核心零依赖。"

// 核心库（根包）不 import 任何外部模块，保持零依赖。
// 只有 cmd/main 与 cmd/verify 这两个可执行包用到 moonbitlang/x 的 fs/sys。
import {
  "moonbitlang/x@0.5.7",
}
