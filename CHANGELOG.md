# 变更记录

版本号遵循语义化版本：`0.x` 阶段允许在次版本号里加入新 API。

## 0.4.0

**CRC 实现错了，标准没错。** 这是本次唯一的主线，其余条目都是它的连带后果。

0.3.x 及更早版本把 HJ 212 的 CRC 当成 CRC-16/MODBUS 实现（每字节入口 `crc ^= byte`），于是标准附录 A 自己的示例报文算出来是 `0759`，而标准标注 `1C80`。当时的结论是「标准里的示例沿用了旧稿、与正文算法不符」，并把这条写进了文档、申报书和一句测试名里。**这个结论是错的。**

附录 A 的 C 代码逐字照抄是这样：

```c
crc_reg = 0xffff;
for (i = 0; i < usDataLen; i++)
    crc_reg = (crc_reg >> 8) ^ puchMsg[i];   /* ← 与高字节异或 */
/* 之后按 0xA001 右移 8 次 */
```

MODBUS 是 `crc_reg ^= puchMsg[i]`（与整个寄存器异或）。初值、多项式、移位方向、无最终异或全都一样，只差这一个入口——但两者结果毫无关系。改用 `(crc_reg >> 8) ^ puchMsg[i]` 之后，标准示例立刻复现。

**用四条官方示例交叉验证**（跨两个版本，全部命中）：

| 来源 | 数据段长度 | 标准标注 | 本库（附录 A 写法） | CRC-16/MODBUS |
| --- | --- | --- | --- | --- |
| HJ 212-2017 附录 A | 101 字节 | `1C80` | `1C80` ✓ | `0759` ✗ |
| HJ 212-2025 附录 A.1 | 87 字节 | `2200` | `2200` ✓ | `CCF4` ✗ |
| HJ 212-2025 附录 A.2 示例 1 | 295 字节 | `2200` | `2200` ✓ | `B649` ✗ |
| HJ 212-2025 附录 A.2 示例 3 | 234 字节 | `B541` | `B541` ✓ | `5103` ✗ |

**破坏性变更：校验码数值变了。** `crc16_bytes` / `crc16` / `crc16_hex` 的输出与 0.3.x 完全不同。凡是用本库生成的帧，其校验码必须按新实现重算；凡是以 0.3.x 的校验码为准写下的期望值，都要一并更新。这不是可兼容的修正。

- `crc.mbt` 整文件重写：入口改为 `(crc >> 8) ^ data[i]`，注释贴出标准 C 代码并解释与 MODBUS 的差异
- `core_wbtest.mbt`：删掉 `test "标准附录示例的校验码与算法不一致"`，换成三条正反测试——复现 `1C80`、固定住两个算法的差异、篡改一位必须报 `BadCrc`
- `corpus/generate.py` 的独立 Python 实现同步改为标准写法，并在 `main()` 开头加了自检：两条附录示例的长度与 CRC 任一不符就 `sys.exit(1)`，一条语料都不生成
- 全部 34 条语料重新生成

**目标标准版本上调到 HJ 212-2025。** HJ 212-2025 于 2025-06-06 发布、**2026-01-01 实施**，HJ 212-2017 同日废止。2025 版的帧结构与 CRC 算法与 2017 逐字相同，新增的是数据段字段与 SM4 加密选项，因此此前按 2017 做的工作全部有效。

- 新增 `Segment.rf : Bool`——2025 版补传标志 `RF`，位于 `PNO` 之后、`CP` 之前，非补传时无此字段。已支持解析、`text()` 往返、CLI `--rf` 选项
- 2025 版 `PNUM`/`PNO` 长度从 9/8 字符改为 6/5 字符，解析按实际分隔符定位，不依赖定长
- `Flag` 的 `A`/`D` 字母在 2017→2025 间对调（2017: D=分包、A=应答；2025: A=分包、D=应答），位权未变，本库只按位权判断，行为不变

**SM4 加密明确划在库外，且理由可验证。** 新版允许用 SM4（16 字节密钥、ECB、Nopadding）加密 `CP=&&` 与 `&&` 之间的内容。附录 A.2 示例 1 与示例 2 明文相同、密文不同，长度同为 `0295`、CRC 同为 `2200`——**长度与 CRC 都基于加密前明文**。所以解密属接入层职责，本库对加密无感知。

**新增语料与文档。**

- `corpus/good/appendix-a__标准附录A示例.frame`：2017 附录 A 原文，101 字节，已用 `cmp` 与标准逐字节核对
- `corpus/good/appendix-a-2025__标准附录A示例.frame`：2025 附录 A.1 原文，87 字节
- 新增 `STANDARD-COMPLIANCE.md`：目标版本、完整兼容边界（结构层必拒 / 语义层降级 / 明确不做）、官方附录报文的 CRC 计算 / 接收 / 转换实证，全部为真实 CLI 输出
- README「适用范围与已知边界」重写：删掉全部「标准示例是错的」表述，补官方示例对账表、8 位有效强度的说明、2025 版 SM4 边界

**顺手修掉的：** `explain` 的版本位原先按十进制补零显示成 `000002`，改为二进制补零 `000010`（新增 `text.bin_pad`）。

**一条测试数的教训。** 这个错误活了三个版本、躲过 97 个测试，因为测试和实现在同一个错误假设下写成——`SAMPLE_FRAME` 的期望值本身就是拿错算法算出来的，测试通过只证明代码与自身一致。现在加了官方示例做外部锚点，它不由本库算出，只由标准给出。

## 0.3.1

修复。

- **InfluxDB line protocol 把缺失值写成了 `0`**。`Point::to_influx_line` 原先对 `Value::Missing` 输出 `field=0`，这与本库最核心的主张直接矛盾——`Missing` 与 `Num(0)` 严格分开，就是为了避免把「没采到」当成「采到就是 0」。line protocol 没有 null，但补一个 0 等同于编造数据。改为整对省略该字段；若所有字段都缺失，仍输出 `field_count=0` 占位，保证行合法。

  该缺陷存在于 0.2.0 及更早版本。JSON / CSV 输出不受影响（前者写 `null`，后者写空串）。发现方式是改名后做外部项目安装冒烟测试，串一遍 `to_json` 与 `to_influx_line` 才看出来——单元测试里没有一条同时断言「有正常值 + 有缺失值」的输出。

## 0.3.0

**改名：`mbt-hj212` → `mbt-datapoint`**

上一次驳回的理由是「选题非常窄，局限于环保监测设备的 HJ 212 报文接入」。0.2.0 已经把交付补成通用的数据接入层，但包名、仓库名、README 首句三处仍然全是 HJ 212——正文主张复用性，标题在反驳它。这次把名字和首屏一起改过来。

```diff
- moon add Mr-Houjie/mbt-hj212
+ moon add Mr-Houjie/mbt-datapoint
```

- 模块名 `Mr-Houjie/mbt-datapoint`，CLI 命令同步改为 `mbt-datapoint`
- README 标题改为「设备数据接入与转换」，开头改成通用数据流图，HJ 212 降为「首个 adapter」并说明选它的理由（有公开标准正文可作对错依据）
- 申报书同步重写（1）节，把「不是再实现一个环保协议」的辩解改成正面陈述目标
- `keywords` 调整：通用词前置（`time-series` / `telemetry` / `data-quality` / `sensor` / `etl` / `iot`），`hj212` 保留在后

**兼容性**：公共 API 与 0.2.0 完全一致，没有任何代码层面的破坏性变更。旧包 `Mr-Houjie/mbt-hj212@0.2.0` 保留可用，不再更新。

## 0.2.0

补上「报文解开之后」那一段：数据模型、规则校验、多格式导出、端到端管道。
HJ 212 从此只是本模块的一个适配器，其余部分离开环保场景照样能用。

四个新模块都不引用 HJ 212 的任何字段定义。

**`record.mbt` — 协议无关数据模型**
- 新增 `Point`（时间 / 来源 / 测量 / 字段）与 `Field`（名称 + 多值）
- 新增 `Value`：`Num` / `Text` / `Missing`。`Missing` 与 `Num(0)` 严格区分，`N` 与空值一律映射成 `Missing`
- 新增 `Quality`：`Good` / `Suspect` / `Invalid`，语义问题降级而非丢弃
- `Point::add` 同名多值追加，不覆盖；`Point::add_area` 直接吃 `DataArea`
- `Frame::to_point` 是唯一的 HJ 212 适配函数：时间戳优先用 `QN` 解析出的规范形式，解析不了保留原文

**`quality.mbt` — 规则引擎**
- `Rule`：`Range` / `Required` / `Numeric` / `AllowedText`
- `RuleSet::check` 返回 `Finding` 数组（级别 + 字段 + 说明），不是布尔值
- 缺字段时只报一次，不与 `Range` 重复报「越界」
- `RuleSet::from_text` 支持文本配置，语法错误的行原样报出，不静默忽略
- `worst` / `count_severity` 汇总

**`sink.mbt` — 多格式导出**
- `Point::to_json` / `to_csv_row` / `to_influx_line`
- `to_ndjson` / `to_csv` / `render_all` / `render_line`
- 手写 JSON 转义（引号、反斜杠、控制字符走 `\u00XX`），保持零依赖
- CSV 单元格以 `= + - @` 开头时加 `'` 前缀，阻断表格软件公式注入
- InfluxDB 输出刻意不带时间戳：`QN` 精度只到毫秒，硬转纳秒会制造看起来精确、实际不可信的时间

**`pipeline.mbt` — 端到端管道**
- `Pipeline::feed` 把分帧 → 解码 → 分包重组 → 转 Point → 规则校验 → 渲染串成一次调用
- 分包帧收齐后才输出，上层拿到的永远是逻辑完整的一条记录
- `Stats` 记录帧、拒绝、数据点、问题、错误、溢出、丢弃分包组、待收分片
- `Pipeline::run` 复用 `feed`，保证批处理与流式口径一致

**CLI**
- 新增 `convert`：报文 → JSON / NDJSON / CSV / InfluxDB，只写数据到标准输出
- 新增 `quality`：按规则校验并列出问题清单，有 Error 时退出码 1
- 新增 `stats`：输出全链路处理统计
- 三者共用 `--format` / `--columns` / `--rules`

**语料与自检**
- 新增 `corpus/stream/mixed.stream`：正常帧 + 坏帧 + 分包 + 噪声混在一段流里
- 新增 `corpus/rules/demo.rules`：8 条规则的现场配置示例
- 自检从上往下多出两节：整段流的帧数 / 拒绝数 / 数据点数，以及规则配置语法与命中数

**API 调整（0.x 内允许）**
- `Stats` 与 `Pipeline` 的字段改为包内可见，对外统一走访问器
- `Stats` 补 `findings` / `overflow` / `dropped_groups` / `pending_parts` 访问器
- `Value` / `Quality` / `Severity` / `Format` 实现 `Eq`（手写，不用 `derive`）

**兼容性**
- 不使用 `derive(Eq, Debug)`：这个写法已进入弃用流程，新写法 `#derive(...)` 又不被当前稳定版识别，两条语法互斥。手写 `Eq` 加 `pub extend`，新旧两条工具链都能在 `--deny-warn` 下编译通过。

## 0.1.2

新增功能，全部向后兼容。

**分包重组**
- 新增 `Reassembler`：按 `MN` + `CN` + `QN` 分组，按 `PNO` 升序把分包帧拼成完整数据区
- `push` 返回 `NotSplit` / `Pending` / `Complete` / `Conflict` 四态
- `missing()` 列出缺失包号，`dropped()` 记录因换组丢弃的未完成组数
- CLI 新增 `pack` 子命令

**数值访问**
- `DataArea::get_int` / `get_float`：取值为 `N`（无有效数据）时返回 `None` 而非 0
- `DataArea::get_or`：带默认值取值
- `DataArea::remove`：删除字段

**错误分级**
- 新增 `ErrorStage`（帧层 / 数据段层 / 数据区层）与 `DecodeError::stage`、`is_structural`
- CLI 的失败信息标注层级

**分帧器**
- `Framer` 增加缓冲区上限，默认 16 KiB，超限抛 `FrameEvent::Overflow`
- 新增 `Framer::with_limit`、`Framer::limit`、`Framer::reset`

**其他**
- `pad_display` 改为公开
- 语料新增 `split/` 目录，自检覆盖分包重组路径

## 0.1.1

修复。

- **`CP=` 出现在其他字段取值里时误切数据区**。例如 `Note=XCP=Y`，此前用「第一次出现 `CP=`」定位，会把字段从中间切断、把合法帧判为 `BadDataArea`。改为要求 `CP` 处在字段边界（0 号位或紧跟 `;`）。该缺陷存在于 0.1.0，建议所有 0.1.0 使用者升级。

## 0.1.0

首个版本。

- 帧编解码：包头、4 位长度（UTF-8 字节数）、CRC16/MODBUS、包尾
- 数据段解析与规范化序列化，字段顺序 `QN;ST;CN;PW;MN;Flag;PNUM;PNO;CP`
- 数据区解析：`&&` 包装、`名称=值`、同项多值逗号分隔
- 流式分帧器：处理粘包、半包、日志噪声
- `Segment::validate` 语义检查（MN 长度、分包声明一致性）
- 命令码表（HJ 212-2017 表 9）、系统编码（表 5）
- CLI：`explain` / `check` / `frames` / `encode` / `crc`
- 语料自检 `cmd/verify`，语料由 Python 独立实现 CRC 生成
