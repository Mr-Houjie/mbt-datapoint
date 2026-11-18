// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "Mr-Houjie/mbt-datapoint"

version = "0.3.0"

readme = "README.md"

repository = "https://github.com/Mr-Houjie/mbt-datapoint"

license = "MIT"

keywords = [
  "time-series",
  "telemetry",
  "data-quality",
  "sensor",
  "etl",
  "iot",
  "hj212",
  "cli",
]

preferred_target = "native"

description = "设备数据接入与转换：流式分帧、协议无关数据模型（缺失与零严格区分）、质量规则引擎、JSON/CSV/InfluxDB 导出与端到端管道。首个 adapter 是 HJ 212 国标。核心零依赖。"

// 核心库（根包）不 import 任何外部模块，保持零依赖。
// 只有 cmd/main 与 cmd/verify 这两个可执行包用到 moonbitlang/x 的 fs/sys。
import {
  "moonbitlang/x@0.5.7",
}
