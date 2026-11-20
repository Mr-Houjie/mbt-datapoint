# mbt-datapoint

设备数据接入与转换：分帧、解码、协议无关数据模型、质量规则、多格式导出。

```
raw bytes ─┬─ Framer ── TCP 字节流 → 一条条完整消息（跨 read 保持状态）
           ├─ Decode ── 结构校验（长度 / CRC / 包尾），分包按包号重组
           ├─ Point  ── {时间, 来源, 测量, 字段}，与协议无关
           ├─ Rules  ── 规则引擎，输出「哪个字段、为什么」而不是一个布尔值
           └─ Sink   ── JSON / NDJSON / CSV / InfluxDB line protocol
```

核心库零依赖，只用 MoonBit 标准库。**首个 adapter 是 HJ 212** —— 国内污染源在线监测联网的强制国标，全国每一台数采仪都在按它报送数据。选它打头阵不是因为要做环保，而是因为它有公开的标准正文可以拿来做对错依据，且坑足够多（见下文三处静默失败）。

目标版本是现行有效的 **HJ 212-2025**（2026-01-01 实施，HJ 212-2017 同日废止），向下兼容 2017 与 2005。三版的帧结构与 CRC 算法完全一致，差异集中在数据段字段。标准版本、兼容边界、以及用官方附录报文做的 CRC 计算 / 接收 / 转换实证，全部整理在 [`STANDARD-COMPLIANCE.md`](STANDARD-COMPLIANCE.md)。

## 两层结构，只有协议层跟具体行业有关

`record.mbt` / `quality.mbt` / `sink.mbt` / `pipeline.mbt` 这四个模块不认识 HJ 212 的任何字段：

| 模块 | 内容 | 谁能用 |
| --- | --- | --- |
| `record.mbt` | `Point` / `Field` / `Value` / `Quality`，缺失与零严格分开 | 任何时序采集：传感器、日志事件、指标 |
| `quality.mbt` | 规则引擎：量程、必填、数值类型、取值白名单，含文本规则配置 | 任何需要判断「这个数可信吗」的场景 |
| `sink.mbt` | JSON / NDJSON / CSV / InfluxDB line protocol，手写转义 | 任何要把数据交给下游系统的场景 |
| `pipeline.mbt` | 上面几步串成一次 `feed`，附全程计数 | 抓包回放、离线批处理、在线流处理 |

`Frame::to_point()` 是唯一的适配函数——把一条 HJ 212 帧翻译成通用的 `Point`。换一种协议（Modbus 采集、自有二进制帧、MQTT 载荷），只需要再写一个这样的函数，后面的校验与导出原样复用。

```moonbit
let p = @datapoint.Point::new("2024-01-15T10:30:00", "sensor-01", "cpu")
p.add("load", @datapoint.Num(0.5))
p.add("status", @datapoint.Text("N"))
p.add("spare", @datapoint.Missing)     // 缺失，不是 0

let (rules, _) = @datapoint.RuleSet::from_text(
  "range load 0 1\nrequired status\nallowed status N,T,B,D\n",
)
for f in rules.check(p) {
  println(f.text())                // [warning] status: 未登记的取值 "Z"
}
println(p.to_json())               // {"timestamp":...,"fields":{"load":[0.5],...}}
println(p.to_influx_line())        // cpu,source=sensor-01 load=0.5,status="N"
```

## 协议层的三处静默失败

HJ 212 报文本身不难，难的是它有三处地方特别容易实现错，而且错了不报错、只是悄悄丢数据：

1. **长度字段按 UTF-8 字节数算，不是字符数。** 数据区里出现一个中文（比如 `Info=备用通道`），按字符数算就会少 6 个字节，接收端随之错位到 CRC，整帧被丢。这个库里长度、CRC 共用同一套字节计数。
2. **`CP` 的取值自己也用 `;` 分隔字段。** 把数据段直接按 `;` 切开再找 `CP`，数据区会被撕成碎片。必须先定位 `CP=`，之前的按 `;` 切字段，之后的整体交给数据区。
3. **TCP 是字节流，粘包半包是常态。** 一次 `read` 可能拿到两条半报文，也可能只拿到 `##01`。分帧器必须能跨 `read` 保持状态。

这三条都有对应的测试和语料，不是靠注释声明的。

## 安装

```bash
moon add Mr-Houjie/mbt-datapoint
```

## 用法

### 解码一条报文

```moonbit
match @datapoint.Frame::decode(raw) {
  Ok(frame) => {
    println(frame.segment.cn)                    // "2011"
    println(frame.segment.cp.get("a34013-Rtd"))  // Some("1.52")
  }
  Err(error) => println(error.message())         // 直接给人看的中文描述
}
```

错误分两类，刻意分开：

- `Frame::decode` 只管**结构**——包头、长度、CRC、包尾。任何一项不对就拒绝整帧，绝不"尽力而为"地猜。
- `Segment::validate` 只管**语义**——MN 长度与版本是否匹配、Flag 声明分包却没带 PNUM/PNO 之类。这些不影响解码，只作为提示返回。

`DecodeError::kind()` 给出稳定的错误标识（`"BadCrc"`、`"Truncated"`……），适合写日志或做分支；`message()` 是给人看的中文描述；`stage()` 说明错误落在哪一层——帧层出错整条必须丢弃，数据段层和数据区层的报文边界是好的，可以单独排查。

### 取数据项

```moonlit
let cp = frame.segment.cp
cp.get("a34013-Rtd")            // Some("1.52")
cp.get_float("a34013-Rtd")      // Some(1.52)
cp.get_int("RtdInterval")       // Some(30)
cp.get_or("Info", "（无备注）")  // 缺失时的默认值
```

`get_float` / `get_int` 在取值是 `N`（标准里表示无有效数据）时返回 `None`，**不会**变成 0——0 是一个合法的监测值，两者不能混。

### 转成数据点

```moonbit
let point = frame.to_point()
point.timestamp      // QN 解析成 "2024-01-15 10:30:00.123"，解析不了就保留原文
point.source         // MN
point.measurement    // CN
point.quality        // Good / Suspect / Invalid
point.number("a34013-Rtd")  // Some(1.52)

point.to_json()          // 一行 JSON
point.to_csv_row(cols)   // 一行 CSV
point.to_influx_line()   // 一行 InfluxDB line protocol
```

三个判断写在这里，都不静默丢数据：

- `N` 与空值映射成 `Value::Missing`，不是 `0`。采集现场最常见的错就是把缺失当 0 入库，之后所有统计被悄悄拉偏。
- 语义有问题（MN 长度不对、分包声明不一致）降级为 `Suspect`，照样输出；只有整帧一个有效值都没有才标 `Invalid`。
- 同名多值不覆盖，`Field::values` 保留全部。实时数据里一项多采是常态，只取第一个就丢数据。

### 规则校验

```moonbit
let (rules, errors) = @datapoint.RuleSet::from_text(
  "range a34013-Rtd 0 500\nrequired DataTime\nallowed a34013-Flag N,T,B,D,F,S\n",
)
let findings = rules.check(point)
for f in findings {
  println(f.text())    // [error] a34013-Rtd: 数值 812.5 超出允许区间 [0, 500]
}
```

输出是问题清单而不是布尔值。缺字段时只报一次「缺少必需字段」，不会再报一遍「越界」——同一个根因报两遍，报告反而看不出根因。文本配置写错的行会被原样报出来，不静默忽略。

### 端到端管道

```moonbit
let pipe = @datapoint.Pipeline::new(rules, @datapoint.Ndjson, [])
for chunk in chunks {
  for out in pipe.feed(chunk) {
    save(out.line)           // 已渲染好的一行
    log(out.findings)        // 这条数据的全部问题
  }
}
println(pipe.stats().text())  // 帧 / 拒绝 / 数据点 / 问题 / 溢出 / 未完成分包组
```

分包帧不会逐片吐数据点：先送进重组器，收齐后拼成一条完整记录再输出，上层拿到的永远是逻辑完整的一条。

### 流式分帧

```moonbit
let framer = @datapoint.Framer::new()
for chunk in chunks {
  for event in framer.feed(chunk) {
    match event {
      @datapoint.Good(frame) => handle(frame)
      @datapoint.Bad(error, raw) => log(error, raw)
      @datapoint.Noise(text) => ()          // 日志前缀、半包残片
    }
  }
}
```

`feed` 返回的是数组，一次喂入可能吐出多条帧。不足一帧的部分留在 `framer.pending()` 里等下一次。

缓冲区有上限（默认 16 KiB）。对端声明了长度却始终补不齐数据时，超限会得到 `Overflow` 事件并清空残留，不会无限攒下去。

### 分包重组

历史数据动辄几十包，`Flag` 的分包位 + `PNUM` / `PNO` 标识分包。`Reassembler` 负责按包号拼回去：

```moonlit
let r = @datapoint.Reassembler::new()
for frame in frames {
  match r.push(frame) {
    @datapoint.NotSplit        => ()                  // 不是分包帧
    @datapoint.Pending(got, n) => println("\{got}/\{n}")
    @datapoint.Complete(area)  => save(area)          // 收齐，按包号升序拼接
    @datapoint.Conflict(reason) => log(reason)
  }
}
r.missing()   // 还缺哪些包号
r.dropped()   // 因换组而丢弃的未完成组数
```

组键是 `MN` + `CN` + `QN`：同一台设备、同一种命令、同一时刻的多帧才属于同一条逻辑报文。分包协议本身不含重传，丢包只能由上层重新请求，所以 `dropped()` 必须让调用方看得见。

### 构造报文

```moonbit
let frame : @datapoint.Frame = {
  segment: {
    qn: "20240115103000123",
    st: "31",
    cn: "2011",
    pw: "123456",
    mn: "010000A8900016F000169DC0",
    flag: @datapoint.Flag::new(@datapoint.V2017, false, true),
    pnum: None,
    pno: None,
    cp: @datapoint.DataArea::new()
      ..set("DataTime", "20240115103000")
      ..set("a34013-Rtd", "1.52"),
    extra: [],
  },
}
println(frame.encode())
```

`encode` 会重新生成数据段（而不是复用输入原文），所以输出是规范形式：字段顺序固定、`&&` 包装一定存在、CRC 与长度一定自洽。

## 命令行

```
mbt-datapoint explain <报文|文件>            逐字段解释一条报文
mbt-datapoint check   <报文|文件>            只校验，不合法时退出码 1
mbt-datapoint frames  <报文|文件>            按 TCP 流分帧，逐条列出
mbt-datapoint pack    <报文|文件>            把分包帧按包号重组成完整数据区
mbt-datapoint convert <报文|文件> [选项]     转成 JSON / NDJSON / CSV / InfluxDB
mbt-datapoint quality <报文|文件> [选项]     按规则校验，列出问题清单
mbt-datapoint stats   <报文|文件> [选项]     输出全链路处理统计
mbt-datapoint encode  [选项]                 构造一条报文
mbt-datapoint crc     <数据段>               算数据段的 CRC 与字节长度
```

`convert` / `quality` / `stats` 共用 `--format`、`--columns`、`--rules` 三个选项，所以「转换出来的数据」和「校验判定」不会各说各话。

```
$ mbt-datapoint convert corpus/good/2011__real-time-gas.frame --format csv \
      --columns DataTime,a34013-Rtd,a34013-Flag
timestamp,source,measurement,quality,DataTime,a34013-Rtd,a34013-Flag
2024-01-15 10:30:00.123,010000A8900016F000169DC0,2011,good,20240115103000,1.52,N

$ mbt-datapoint quality corpus/edge/many-items.frame --rules corpus/rules/demo.rules
2024-01-15 10:30:00.123  010000A8900016F000169DC0  CN=2011  [good]
    [error] DataTime: 缺少必需字段

数据点 1 · 问题 1（错误 1，警告 0，提示 0）· 解码失败 0
```

`convert` 只把数据写进标准输出，不掺统计行，方便直接重定向或接管道。`quality` 有 Error 级问题时退出码 1，能直接当 CI 门禁。

`explain` 把一条报文摊成表，每一行都标出来源：

```
$ mbt-datapoint explain '##0140QN=20240115103000123;ST=31;CN=2011;PW=123456;MN=010000A8900016F000169DC0;Flag=5;CP=&&DataTime=20240115103000;a34013-Rtd=1.52;a34013-Flag=N&&D801'

长度    140 字节（数据段）
CRC     D801                          校验通过
版本    HJ 212-2017
Flag    5                             版本位 000001 · 不分包 · 需应答
QN      20240115103000123             2024-01-15 10:30:00.123
ST      31                            大气环境污染源
CN      2011                          污染物实时数据 · 双向
PW      123456
MN      010000A8900016F000169DC0      24 位
CP      3 项
  DataTime          20240115103000
  a34013-Rtd        1.52
  a34013-Flag       N
```

命令行直接粘报文时末尾的 `\r\n` 常被终端吃掉，`explain`/`check`/`frames` 会自动补一次；库层保持严格，不做这种妥协。

## 语料自检

```bash
moon run cmd/verify
```

`corpus/` 下的帧是**文件**，不是代码里的字符串常量。自检会：

1. 合法帧必须能解码，且长度、CRC 与算法一致；
2. 解码再编码必须与原文件字节相同（往返一致）；
3. 非法帧必须被拒绝，且**错误类型要与文件名前缀一致**（`BadCrc__xxx.frame` 就必须报 `BadCrc`）；
4. `split/` 下同前缀的分包帧必须能重组成一条完整数据区；
5. `stream/` 下混着正常帧、坏帧、分包与噪声的整段流，用管道跑一遍，核对帧数 / 拒绝数 / 数据点数；
6. `rules/` 下的规则配置必须零语法错误，且对已知有问题的报文必须命中期数量的错误。

第 3 条是这个命令的价值所在。它把"我以为它会报错"变成了可执行断言。开发过程中它抓出了两个真实缺陷——重复字段被静默接受、缺少 `&&` 包装的 `CP` 被当成合法数据区。

语料由 `corpus/generate.py` 生成。这个脚本**不复用** MoonBit 实现，而是用 Python 重写一遍 CRC16，让校验码来自一套独立实现。两边算得不一样，生成阶段就会暴露。

## 适用范围与已知边界

**标准版本与官方示例。** 目标版本为 HJ 212-2025，附录 A.1 的 CRC 算法与 2017 版逐字相同。两条附录示例报文原样收在语料里，是全部实现的锚点：

| 来源 | 数据段长度 | 标准标注 | 本库 `crc16_hex` |
| --- | --- | --- | --- |
| HJ 212-2017 附录 A | 101 字节 | `1C80` | `1C80` |
| HJ 212-2025 附录 A.1 示例 | 87 字节 | `2200` | `2200` |

`corpus/good/appendix-a__标准附录A示例.frame` 与 `appendix-a-2025__标准附录A示例.frame` 就是这两条原文，已用 `cmp` 与标准逐字节核对。`corpus/generate.py` 内置同一自检：长度或 CRC 对不上，脚本直接退出、不生成任何语料。

**CRC 不是 MODBUS，只差一行。** 附录 A 给出的 C 代码，每个字节的入口是：

```c
crc_reg = (crc_reg>>8) ^ puchMsg[i];
```

而 CRC-16/MODBUS 是 `crc_reg ^= puchMsg[i]`。初值 `0xFFFF`、多项式 `0xA001`、无最终异或，两者完全一样，只有这一处不同——但结果毫无关系。用附录 A 自己的示例报文可以一眼分清：

| 对同一数据段（101 字节） | 结果 |
| --- | --- |
| 附录 A 的写法 | `1C80` ← 与标准标注的校验码一致 |
| CRC-16/MODBUS | `0759` |

本库 0.3.x 及更早版本误用了 MODBUS，于是附录 A 的示例被判成「校验错」，文档里还写了段话认定「示例沿用了旧稿」。**那个判断是错的。**标准没有问题，附录 A 的示例完全自洽，是实现的入口写错了。0.4.0 起改用标准写法，`core_wbtest.mbt` 里直接断言 `crc16_hex(附录A数据段) == "1C80"`，另有一条测试固定住两个算法的差异，防止以后被「顺手优化」回去。

**这个 CRC 只有 8 位强度。** 每字节入口只剩低 8 位有效，所以输出空间只有 256 种取值——高字节任意，低字节只能是 `00`/`01`/`40`/`41`/`80`/`81`/`C0`/`C1` 八种。随机噪声撞对校验码的概率约 **1/256**，而不是 CRC16 通常的 1/65536。这是标准算法本身的性质，库改不了，所以 CRC 通过之后**必须**再做结构校验。`Frame::decode` 正是这个顺序：先验 CRC，再 `Segment::parse`，任何一层不过就拒绝整帧，不存在「校验通过就放行」。

**校验码可能不足 4 位。** `0x0000`、`0x0ABC` 这类结果在数值上只有 3 位十六进制，但报文里必须补足 4 位（`0000`、`0ABC`）。现场有实现忘了补零，导致对端解析错位。`hex4` 负责这件事，而 `corpus/edge/no-password.frame` 的校验码恰好算出来就是 `0000`，正好当回归用例。

**命令表与系统编码表。** 逐条对照 HJ 212-2017 表 9 与表 5 录入，没有采用现场口头叫法。例如 `2011` 是「污染物实时数据」（取与上传共用同一码），`2041` 是「设备运行时间日历史数据」而不是又一个「日数据」；`ST=32` 是「地表水体环境污染源」（水质），烟气是 `ST=31`，烟气工况是 `ST=51`。这三处都是常见误记，代码里有专门的回归测试盯着。

**版本号。** `Flag` 的 V5–V0 位：`000000` 是 HJ/T 212-2005，`000001` 是 HJ 212-2017，`000010` 是 HJ 212-2025。注意 2017 与 2025 两次修订把最后两位的**字母**换过名（2017 写作 D=分包、A=应答，2025 写作 A=分包、D=应答），位权没变。本库只按位权判断，不引用字母。2025 版另新增 `RF` 补传标志（位于 `PNO` 之后、`CP` 之前，非补传时无此字段），已作一等字段解析、往返与校验。

**2025 版的 SM4 数据段加密不在本库范围内。** 新版允许用 SM4（16 字节密钥、ECB、Nopadding）加密 `CP=&&` 与 `&&` 之间的内容。关键点是：**长度字段与 CRC 都基于加密前的明文**——附录 A.2 示例 1 与示例 2 明文相同、密文不同，长度同为 `0295`、CRC 同为 `2200`，可直接验证。所以解密属于接入层的事，解开后把明文交给本库即可；本库的编解码与校验对加密无感知，也不需要感知。

**没有做的部分。** 监测因子编码表（附录 B，水/气各数百项）没有收录——那是查表数据而不是协议逻辑，塞进库只会让包变大。数据区里的因子名按不透明字符串处理，`DataArea::get("a34013-Rtd")` 照样能用。规则引擎也不预置任何行业规则：量程该设多少是现场的事，不是库的事。

## 项目结构

```
record.mbt       协议无关数据模型：Point / Field / Value / Quality
quality.mbt      规则引擎：量程 / 必填 / 数值类型 / 取值白名单 + 文本配置
sink.mbt         导出：JSON / NDJSON / CSV / InfluxDB，手写转义
pipeline.mbt     端到端管道：一次 feed 走完全流程，附计数

types.mbt        公共类型：Version、Flag、DecodeError、ErrorStage、Segment、Frame
text.mbt         字符/字节工具：UTF-8 计数、十六进制、显示宽度对齐
crc.mbt          CRC16，附录 A 的写法（非 MODBUS）
field_type.mbt   数据类型表：C4、N5、N14.2、YYYY/MM/DD/hh/mm/ss/zzz
data_area.mbt    数据区：&& 包装、名称=值、逗号分隔多值、数值访问器
segment.mbt      数据段：字段切分（先定位 CP=）、序列化、语义校验
time.mbt         QN 时间戳
frame.mbt        帧编解码 + 流式分帧器
reassemble.mbt   分包重组
commands.mbt     命令码表（表 9）
explain.mbt      逐字段解释，供 CLI 使用
corpus/          语料、规则配置、生成脚本
cmd/main/        命令行
cmd/verify/      语料与管道自检
```

前四个文件不 import 任何协议概念，可以单独拿去做别的采集场景。

## 测试

```bash
moon test              # 109 个单元测试（含对抗性测试）
moon run cmd/verify    # 34 个语料用例（含 2 组分包重组、1 段混合流、1 份规则配置、2 条标准原文示例）
moon check --deny-warn # 零告警
```

## 开发历程

选题为什么从文本换行换到 HJ 212、为什么第二次又把重心从「协议解析」挪到「数据管道」、AI 在哪儿帮了倒忙、测试抓出过哪三个真 bug，都记在 [`DEVLOG.md`](DEVLOG.md)。

标准符合性单独立了一份 [`STANDARD-COMPLIANCE.md`](STANDARD-COMPLIANCE.md)：目标标准版本、完整兼容边界（哪些必拒、哪些降级、哪些明确不做）、以及拿官方附录报文跑出来的 CRC 计算 / 接收 / 转换实际输出。

## 许可

MIT
