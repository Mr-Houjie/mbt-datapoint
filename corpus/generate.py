# -*- coding: utf-8 -*-
"""生成 mbt-datapoint 的语料文件。

这里刻意不调用 MoonBit 实现，而是用 Python 重新写一遍 CRC16/MODBUS，
让语料的校验码来自一套独立实现——如果两边算得不一样，生成阶段就会暴露。
"""
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc


def make_frame(seg: str) -> bytes:
    body = seg.encode("utf-8")
    return (
        b"##"
        + ("%04d" % len(body)).encode("ascii")
        + body
        + ("%04X" % crc16(body)).encode("ascii")
        + b"\r\n"
    )


def seg(qn, st, cn, pw, mn, flag, cp, pnum=None, pno=None):
    s = "QN=%s;ST=%s;CN=%s" % (qn, st, cn)
    if pw is not None:
        s += ";PW=%s" % pw
    s += ";MN=%s;Flag=%s" % (mn, flag)
    if pnum is not None:
        s += ";PNUM=%d" % pnum
    if pno is not None:
        s += ";PNO=%d" % pno
    s += ";CP=&&%s&&" % cp
    return s


MN = "010000A8900016F000169DC0"
QN = "20240115103000123"

GOOD = {
    "2011__real-time-gas.frame": seg(
        QN, "31", "2011", "123456", MN, "5",
        "DataTime=20240115103000;a34013-Rtd=1.52;a34013-Flag=N",
    ),
    "2011__real-time-water.frame": seg(
        QN, "32", "2011", "123456", MN, "5",
        "DataTime=20240115103000;w01018-Rtd=12.5;w01018-Flag=N",
    ),
    "2031__day-data.frame": seg(
        "20240116083000123", "31", "2031", "123456", MN, "5",
        "DataTime=20240115000000;a34013-Avg=1.44;a34013-Cou=126.5;a34013-Flag=N",
    ),
    "2041__device-runtime.frame": seg(
        "20240116083000123", "31", "2041", "123456", MN, "5",
        "DataTime=20240115000000;SB1-RT=23.5",
    ),
    "2051__minute-data.frame": seg(
        "20240115103100123", "32", "2051", "123456", MN, "5",
        "DataTime=20240115103000;w01018-Rtd=12.5;w01018-Flag=N",
    ),
    "2061__hour-data.frame": seg(
        "20240115110000123", "31", "2061", "123456", MN, "5",
        "DataTime=20240115100000;a34013-Avg=1.48;a34013-Max=2.10;a34013-Min=0.92;a34013-Flag=N",
    ),
    "1062__set-interval.frame": seg(
        "20240115103000123", "31", "1062", "123456", MN, "4",
        "RtdInterval=30",
    ),
    "1011__get-time.frame": seg(
        "20240115103000123", "31", "1011", "123456", MN, "5", "",
    ),
    "9011__request-ack.frame": seg(
        "20240115103000123", "91", "9011", "123456", MN, "4",
        "QN=20240115103000123;QnRtn=1",
    ),
    "9014__data-ack.frame": seg(
        "20240115103000123", "91", "9014", "123456", MN, "4",
        "QN=20240115103000123;ExeRtn=1",
    ),
}

EDGE = {
    "empty-cp.frame": seg(QN, "31", "1011", "123456", MN, "5", ""),
    "split-packet.frame": seg(
        "20240115103000123", "31", "2011", "123456", MN, "6",
        "DataTime=20240115103000;a34013-Rtd=1.52", pnum=2, pno=1,
    ),
    "utf8-in-cp.frame": seg(
        QN, "31", "2011", "123456", MN, "5",
        "DataTime=20240115103000;a34013-Rtd=1.52;Info=备用通道",
    ),
    "no-password.frame": seg(QN, "31", "1011", None, MN, "5", ""),
    "cp-in-value.frame": seg(
        QN, "31", "2011", "123456", MN, "5",
        "Note=XCP=Y;a34013-Rtd=1.52",
    ),
    "many-items.frame": seg(
        QN, "31", "2011", "123456", MN, "5",
        ";".join("a%05d-Rtd=%d" % (i, i) for i in range(1, 21)),
    ),
}

# 分包组。同一组的多帧共用文件名前缀，verify 会把它们喂进同一台
# 重组器，要求最终拼成一条完整数据区。文件名里的 p1、p2 只是排序用，
# 真正的包号在报文体的 PNO 字段里。
SPLIT = {
    "split-2__p1.frame": seg(
        QN, "32", "2051", "123456", MN, "6",
        "DataTime=20240115103000;w01018-Rtd=12.5", pnum=2, pno=1,
    ),
    "split-2__p2.frame": seg(
        QN, "32", "2051", "123456", MN, "6",
        "w01018-Flag=N", pnum=2, pno=2,
    ),
    "split-3__p1.frame": seg(
        "20240116083000123", "31", "2031", "123456", MN, "6",
        "DataTime=20240115000000;a34013-Avg=1.44", pnum=3, pno=1,
    ),
    "split-3__p2.frame": seg(
        "20240116083000123", "31", "2031", "123456", MN, "6",
        "a34013-Max=2.10;a34013-Min=0.92", pnum=3, pno=2,
    ),
    # 分包边界正好落在一个中文字段上：长度字段必须按字节算，
    # 按字符算会让这一组拼接失败。
    "split-3__p3.frame": seg(
        "20240116083000123", "31", "2031", "123456", MN, "6",
        "Info=备用通道;a34013-Flag=N", pnum=3, pno=3,
    ),
}

BAD = {
    "BadCrc__校验码被改动.frame": seg(
        QN, "31", "2011", "123456", MN, "5",
        "DataTime=20240115103000;a34013-Rtd=1.52",
    ),
    "BadLengthField__长度字段含字母.frame": seg(
        QN, "31", "2011", "123456", MN, "5", "RtdInterval=30",
    ),
    "Truncated__声明长度超出实际.frame": seg(
        QN, "31", "2011", "123456", MN, "5", "RtdInterval=30",
    ),
    "BadTail__包尾缺换行.frame": seg(
        QN, "31", "2011", "123456", MN, "5", "RtdInterval=30",
    ),
    "EmptySegment__数据段为空.frame": "",
    "MissingHeader__包头错误.frame": seg(
        QN, "31", "2011", "123456", MN, "5", "RtdInterval=30",
    ),
    # 以下四条的校验码是对的，错误发生在字段解析层
    "MissingField__缺 MN.frame": (
        "QN=%s;ST=31;CN=2011;PW=123456;Flag=5;CP=&&&&" % QN
    ),
    "DuplicateField__MN 重复.frame": (
        "QN=%s;ST=31;CN=2011;PW=123456;MN=%s;MN=%s;Flag=5;CP=&&&&"
        % (QN, MN, MN)
    ),
    "BadField__字段缺等号.frame": (
        "QN=%s;ST=31;CN=2011;PW=123456;MN=%s;Flag=5;OOPS;CP=&&&&" % (QN, MN)
    ),
    "BadFieldValue__Flag 不是数字.frame": (
        "QN=%s;ST=31;CN=2011;PW=123456;MN=%s;Flag=abc;CP=&&&&" % (QN, MN)
    ),
    "BadDataArea__CP 缺 && 包装.frame": (
        "QN=%s;ST=31;CN=2011;PW=123456;MN=%s;Flag=5;CP=RtdInterval=30"
        % (QN, MN)
    ),
}


def write(path: str, data: bytes) -> None:
    with open(path, "wb") as f:
        f.write(data)


def build_bad(name: str, seg_text: str) -> bytes:
    if name.startswith("BadCrc__"):
        body = seg_text.encode("utf-8")
        crc = "%04X" % ((crc16(body) + 1) & 0xFFFF)
        return b"##" + ("%04d" % len(body)).encode() + body + crc.encode() + b"\r\n"
    if name.startswith("BadLengthField__"):
        frame = make_frame(seg_text)
        return frame[:2] + b"01A1" + frame[6:]
    if name.startswith("Truncated__"):
        frame = make_frame(seg_text)
        return frame[:2] + b"0900" + frame[6:]
    if name.startswith("BadTail__"):
        frame = make_frame(seg_text)
        return frame[:-2] + b"\rX"
    if name.startswith("EmptySegment__"):
        return b"##0000FFFF\r\n"
    if name.startswith("MissingHeader__"):
        frame = make_frame(seg_text)
        return b"#X" + frame[2:]
    # 字段级错误：校验码是对的，直接按正常帧输出
    return make_frame(seg_text)


def main() -> None:
    for sub in ("good", "edge", "bad", "split"):
        d = os.path.join(ROOT, sub)
        os.makedirs(d, exist_ok=True)
        for old in os.listdir(d):
            os.remove(os.path.join(d, old))

    for name, s in GOOD.items():
        write(os.path.join(ROOT, "good", name), make_frame(s))
    for name, s in EDGE.items():
        write(os.path.join(ROOT, "edge", name), make_frame(s))
    for name, s in SPLIT.items():
        write(os.path.join(ROOT, "split", name), make_frame(s))
    for name, s in BAD.items():
        write(os.path.join(ROOT, "bad", name), build_bad(name, s))

    total = len(GOOD) + len(EDGE) + len(SPLIT) + len(BAD)
    sys.stdout.write("生成 %d 个语料文件\n" % total)


if __name__ == "__main__":
    main()
