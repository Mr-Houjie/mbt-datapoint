// 加密报文子命令。
//
// HJ 212-2025 6.4.4 规定：现场机发来的数据命令（CN 2000~2999）、新密钥
// 应答（CN 1014）、现场机信息（CN 3020）**必须加密**，其余命令不加密。
// 报文里没有加密标志位，是否加密完全由 CN 判定——所以「解密」这一步不是
// 可选的润色，而是拿到数据的前置条件。
//
// 这里演示的正是本项目的接入方式：
//
//   外部组件（HSM / 国密库 / 硬件网关，本项目附 sm4/ 参考实现）
//        ↓ 以 Decryptor 函数注入，核心库不认识任何算法
//   Frame::decode_bytes(raw, decrypt)
//        ↓ 按 CN 判定是否解密、按明文算 CRC、解析字段
//   Frame → 数据点
//
// `--key` 不给时不是「报错退出」了事，而是走完整条链路后给出
// CipherRequired：现场看到这条提示，才知道该配组件，而不是去查链路误码。

///|
struct CipherOptions {
  mut input : String
  mut key : String
}

///|
fn parse_cipher_options(args : Array[String]) -> Result[CipherOptions, String] {
  let opt : CipherOptions = { input: "", key: "" }
  let mut i = 0
  while i < args.length() {
    let key = args[i]
    match key {
      "--key" => {
        if i + 1 >= args.length() {
          return Err("--key 后面需要 32 位十六进制密钥")
        }
        opt.key = args[i + 1]
        i = i + 1
      }
      _ =>
        if key.has_prefix("-") {
          return Err("未知选项「\{key}」")
        } else if opt.input != "" {
          return Err("只能指定一个输入，多了「\{key}」")
        } else {
          opt.input = key
        }
    }
    i = i + 1
  }
  if opt.input == "" {
    return Err("缺少输入：一个含加密报文的文件")
  }
  Ok(opt)
}

///|
/// 读原始字节。文件按二进制读——密文是任意字节，当文本读会坏在编码上。
fn read_bytes(arg : String) -> Result[Array[Byte], String] {
  if @fs.path_exists(arg) {
    let raw = @fs.read_file_to_bytes(arg) catch {
      _ => return Err("无法读取文件「\{arg}」")
    }
    Ok(byte_view_to_array(raw))
  } else {
    // 允许直接粘一条报文，但粘进来的只能是 ASCII —— 密文没法用键盘敲
    Ok(@lib.wire_bytes(arg))
  }
}

///|
fn byte_view_to_array(view : Bytes) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut i = 0
  let n = view.length()
  while i < n {
    out.push(view[i])
    i = i + 1
  }
  out
}

///|
/// 数据区内容的长度：`CP=&&` 之后到结尾 `&&` 之前。
///
/// 加密只作用于这一段（标准 6.4.2），所以「几组密文」要按这一段算，
/// 不能按整个数据段算——数据段的包头部分始终是明文。
fn data_area_length(segment : String) -> Int32 {
  let marker : Array[Char] = ['C', 'P', '=', '&', '&']
  let cs : Array[Char] = []
  for c in segment {
    cs.push(c)
  }
  let mut i = 0
  while i + 5 <= cs.length() {
    let mut hit = true
    let mut k = 0
    while k < 5 {
      if cs[i + k] != marker[k] {
        hit = false
        break
      }
      k = k + 1
    }
    if hit {
      return cs.length() - (i + 5) - 2
    }
    i = i + 1
  }
  -1
}

///|
fn cmd_cipher(args : Array[String]) -> Int32 {
  let opt = match parse_cipher_options(args) {
    Ok(o) => o
    Err(message) => {
      println("错误: \{message}")
      return 2
    }
  }
  let raw = match read_bytes(opt.input) {
    Ok(b) => b
    Err(message) => {
      println("错误: \{message}")
      return 2
    }
  }

  // 组件装配：有密钥用内置 SM4 参考实现，没有就注入「永远拿不到明文」的
  // 空组件，让库自己给出 CipherRequired。后者才是要给人看的诊断。
  let mut decryptor_ready = false
  let decrypt : @lib.Decryptor = if opt.key == "" {
    fn(_) { None }
  } else {
    match @sm4.Sm4::from_hex(opt.key) {
      Some(sm4) => {
        decryptor_ready = true
        sm4.decryptor()
      }
      None => {
        println("错误: --key 需要 32 位十六进制字符（16 字节）")
        return 2
      }
    }
  }

  println("文件     \{opt.input}")
  println("字节     \{raw.length()}")
  match @lib.Frame::decode_bytes(raw, decrypt) {
    Err(error) => {
      println("FAIL（\{error.stage().label()}）\{error.message()}")
      1
    }
    Ok(frame) => {
      let segment = frame.segment.text()
      let code = @lib.cn_of_segment_bytes(@lib.wire_bytes(segment))
      let need = match code {
        Some(c) => @lib.requires_cipher(c)
        None => false
      }
      println(
        "CN       \{frame.segment.cn}  \{(if need { "按 6.4.4 属于加密范围，须解密" } else { "按 6.4.4 不加密" })}",
      )
      let area = data_area_length(segment)
      if need && area >= 0 {
        let bulk = @lib.cipher_bulk_len(area)
        println(
          "密文     \{bulk} 字节 = \{bulk / 16} 组 × 16，尾部 \{(if area > bulk { area - bulk } else { 0 })} 字节保持明文",
        )
      }
      println(
        "组件     \{(if decryptor_ready { "已注入 SM4 参考实现（子包 sm4，核心库不含算法）" } else { "未注入" })}",
      )
      println("")
      println(frame.explain().trim_end(chars="\r\n"))
      let points = @lib.points_from_frames([frame])
      println("")
      println("数据点   \{points.length()} 个")
      let sb = StringBuilder()
      for p in points {
        sb.write_string("  ")
        sb.write_string(p.to_influx_line())
        sb.write_string("\n")
      }
      println(sb.to_string().trim_end(chars="\n"))
      0
    }
  }
}
