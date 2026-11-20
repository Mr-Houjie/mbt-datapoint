# -*- coding: utf-8 -*-
"""核对 STANDARD-COMPLIANCE.md 里贴的命令输出与真实运行结果是否逐字一致。

文档里每个代码块形如：

    $ mbt-datapoint <args>
    <输出第 1 行>
    <输出第 2 行>
    ...

本脚本抽出所有以 `$ mbt-datapoint ` 开头的块，真跑一遍，逐行比对。
任何差异都报出来并退出非零——这份材料是给审核方照着重跑的，
少一行、多一个空格都算不准。
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "STANDARD-COMPLIANCE.md")
_BIN_CANDIDATES = (
    os.path.join("_build", "native", "debug", "build", "cmd", "main", "main"),
    os.path.join("_build", "native", "debug", "build", "cmd", "main", "main.exe"),
)
BIN = next(
    (os.path.join(ROOT, p) for p in _BIN_CANDIDATES
     if os.path.exists(os.path.join(ROOT, p))),
    os.path.join(ROOT, _BIN_CANDIDATES[0]),
)

# 文档里对输出做了两处编排，比对时先规整掉：
# 1. 退出码单独写成一行「退出码 1」，真实程序不打这行，由 returncode 体现
# 2. 行尾空白、CRLF
EXIT_LINE = re.compile(r"^退出码\s+(-?\d+)$")


def blocks(md):
    """产出 (命令行, [期望输出行], 期望退出码) 的序列。"""
    for m in re.finditer(r"```[a-z]*\n(.*?)```", md, re.S):
        lines = m.group(1).split("\n")
        # 反引号前的换行会split出一个尾部空串，先去掉它。
        # 注意别用 `ln is lines[-1]` 判断末行——空字符串会被 intern，
        # 中间空行也会命中，导致多行输出被误当一行。
        if lines and lines[-1] == "":
            lines.pop()
        if not lines or not lines[0].startswith("$ mbt-datapoint "):
            continue
        cmd = lines[0][2:].strip()
        expect, want_code = [], None
        for ln in lines[1:]:
            hit = EXIT_LINE.match(ln.strip())
            if hit:
                want_code = int(hit.group(1))
            else:
                expect.append(ln.rstrip())
        while expect and expect[-1] == "":
            expect.pop()
        yield cmd, expect, want_code


def run(cmd):
    # 按 shell 语义切参数：命令里有单引号包住的长报文，用 shlex 会保留引号内空格
    import shlex
    parts = shlex.split(cmd, posix=True)
    parts[0] = BIN
    # 文档里写的是相对仓库根的文件路径
    p = subprocess.run(parts, cwd=ROOT, capture_output=True)
    out = p.stdout.decode("utf-8", "replace").replace("\r\n", "\n")
    return out.rstrip("\n").split("\n") if out.strip() else [], p.returncode


def main():
    if not os.path.exists(BIN):
        print("先构建：moon build --target native cmd/main", file=sys.stderr)
        sys.exit(2)
    md = open(DOC, encoding="utf-8").read()
    total = bad = 0
    for cmd, expect, want_code in blocks(md):
        total += 1
        actual, code = run(cmd)
        problems = []
        if actual != expect:
            # 逐行指出首个差异，便于定位
            for i in range(max(len(expect), len(actual))):
                e = expect[i] if i < len(expect) else "<缺失>"
                a = actual[i] if i < len(actual) else "<多余>"
                if e != a:
                    problems.append("  第 %d 行\n    文档: %r\n    实际: %r" % (i + 1, e, a))
                    break
            if len(actual) != len(expect):
                problems.append("  行数 文档 %d / 实际 %d" % (len(expect), len(actual)))
        if want_code is not None and code != want_code:
            problems.append("  退出码 文档 %d / 实际 %d" % (want_code, code))
        if problems:
            bad += 1
            print("FAIL  %s" % cmd)
            print("\n".join(problems))
        else:
            print("OK    %s" % cmd)
    print("\n%d 个输出块，%d 个不一致" % (total, bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
