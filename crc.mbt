// CRC16 校验。
//
// 算法取自 HJ 212 附录 A：初值 0xFFFF，反向多项式 0xA001（即 CRC-16/MODBUS），
// 不做最终异或，结果以 4 位大写十六进制写入报文。
//
// 附录 A 给出的示例报文 `##0101QN=...&&1C80` 里的 `1C80` 与按该算法
// 对同一数据段算出的结果（0x0759）对不上——示例的校验码沿用了旧稿。
// 本库以附录 A 的算法为准，并在测试里固定该期望值；这一点写在 README
// 的「已知差异」里，避免使用者拿标准示例来对拍时误判成实现错误。

///|
const CRC_POLY : Int32 = 0xA001

///|
const CRC_INIT : Int32 = 0xFFFF

///|
/// 计算一段字节的 CRC16。
pub fn crc16_bytes(data : Array[Byte]) -> Int32 {
  let mut crc = CRC_INIT
  let mut i = 0
  while i < data.length() {
    crc = crc ^ data[i].to_int()
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
pub fn crc16_hex(text : String) -> String {
  hex4(crc16_text(text))
}
