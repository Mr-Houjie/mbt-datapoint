// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "Mr-Houjie/mbt-hj212"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/Mr-Houjie/mbt-hj212"

license = "MIT"

keywords = [
  "hj212",
  "environmental",
  "pollution-monitoring",
  "protocol",
  "codec",
  "iot",
  "cli",
]

preferred_target = "native"

description = "纯 MoonBit 的 HJ 212 污染物在线监控数据传输协议实现：帧编解码、数据区解析、命令层与流式分帧，核心零依赖。"

// 核心库（根包）不 import 任何外部模块，保持零依赖。
// 只有 cmd/main 与 cmd/verify 这两个可执行包用到 moonbitlang/x 的 fs/sys。
import {
  "moonbitlang/x@0.5.7",
}
