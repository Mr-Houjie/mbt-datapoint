// CRC16 校验。
//
// 算法严格照 HJ 212-2017 附录 A 给出的 C 代码，一字不改：
//
//     unsigned int CRC16_Checkout(unsigned char *puchMsg, unsigned int usDataLen)
//     {
//         unsigned int i, j, crc_reg, check;
//         crc_reg = 0xFFFF;
//         for (i = 0; i < usDataLen; i++) {
//             crc_reg = (crc_reg >> 8) ^ puchMsg[i];   // 与「高字节」异或
//             for (j = 0; j < 8; j++) {
//                 check = crc_reg & 0x0001;
//                 crc_reg >>= 1;
//                 if (check == 0x0001) { crc_reg ^= 0xA001; }
//             }
//         }
//         return crc_reg;
//     }
//
// 初值 0xFFFF、多项式 0xA001 都跟 CRC-16/MODBUS 一样，差别只在每个字节
// 的入口：MODBUS 写 `crc ^= byte`，本标准写 `crc = (crc >> 8) ^ byte`。
// 一处之差，两者结果毫无关系——所以直接套 MODBUS 实现，附录 A 的示例
// `##0101...&&1C80` 永远对不上。本库早期版本正是这么错的，误判标准示例
// 有误并写进文档；改用标准写法后该示例复现为 0x1C80，见 core_wbtest.mbt。
//
// 另需知道：每字节入口只剩低 8 位有效，故本算法的输出空间仅 256 种取值
// （低字节只可能是 0x00/0x01/0x40/0x41/0x80/0x81/0xC0/0xC1），碰撞概率
// 约 1/256，而非 CRC16 通常的 1/65536。CRC 通过之后仍必须做结构校验，
// frame.mbt 里「CRC 校验 → Segment::parse」的分层正是为此。

///|
const CRC_POLY : Int32 = 0xA001

///|
const CRC_INIT : Int32 = 0xFFFF

///|
/// 计算一段字节的 CRC16。
///
/// 按附录 A 的写法，每个字节先与校验寄存器的高字节异或，再走 8 位移位。
pub fn crc16_bytes(data : Array[Byte]) -> Int32 {
  let mut crc = CRC_INIT
  let mut i = 0
  while i < data.length() {
    crc = (crc >> 8) ^ data[i].to_int()
    let mut bit = 0
    while bit < 8 {
      if (crc & 1) == 1 {
        crc = (crc >> 1) ^ CRC_POLY
      } else {
        crc = crc >> 1
      }
      bit = bit + 1
    }
    i = i + 1
  }
  crc & 0xFFFF
}

///|
/// 计算一段文本的 CRC16（按 UTF-8 字节）。
pub fn crc16_text(text : String) -> Int32 {
  crc16_bytes(utf8_bytes(text))
}

///|
/// 计算 CRC 并格式化成报文里的 4 位大写十六进制。
///
/// 附录 A 规定「校验码按照先高字节后低字节的顺序存放」，`hex4` 先输出高位
/// 半字节，与之相符。另注意本算法结果可能小于 0x1000（例如 0x0ABC），
/// 报文中仍须补足 4 位，`hex4` 负责这件事。
pub fn crc16_hex(text : String) -> String {
  hex4(crc16_text(text))
}
