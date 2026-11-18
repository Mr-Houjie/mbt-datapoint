# 变更记录

版本号遵循语义化版本：`0.x` 阶段允许在次版本号里加入新 API。

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
