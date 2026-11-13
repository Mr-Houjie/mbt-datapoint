# 变更记录

版本号遵循语义化版本：`0.x` 阶段允许在次版本号里加入新 API。

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
