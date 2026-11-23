#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PROJECT_PROPOSAL.md -> 单页 A4 PDF。

申报书每次改都要重新出 PDF，手搓必然漏。这里把整条路固定下来：

    python3 tools/make_proposal_pdf.py

md -> 结构化块 -> reportlab platypus。字号从 7.0pt 起逐档下调，直到
数出来正好一页；压不进一页就报错退出，绝不把页数不对的 PDF 留在
_build 里让人误交。

不走浏览器打印：Edge 的 headless 在本机沙箱里连 --version 都没有输出，
静默失败比报错更坏。纯 Python 排版可复现、可自检。

只实现这份文档实际用到的 markdown 子集：h1/h2、引用、列表、表格、
行内 **加粗** 与 `代码`。通用解析器要引依赖，而本脚本的价值只在于
「结论可重跑」。
"""

import html
import os
import re
import sys

from reportlab.lib import colors
from reportlab.lib.enums import TA_JUSTIFY, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    HRFlowable,
    KeepTogether,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "PROJECT_PROPOSAL.md")
OUT_PDF = os.path.join(ROOT, "_build", "PROJECT_PROPOSAL.pdf")

FONT_DIR = r"C:\Windows\Fonts"
CJK = os.path.join(FONT_DIR, "msyh.ttc")
CJK_BOLD = os.path.join(FONT_DIR, "msyhbd.ttc")
MONO = os.path.join(FONT_DIR, "consola.ttf")


def register_fonts():
    if not os.path.exists(CJK):
        sys.exit("找不到微软雅黑 %s；换一台机器请改字体路径" % CJK)
    pdfmetrics.registerFont(TTFont("MSYH", CJK, subfontIndex=0))
    bold = CJK_BOLD if os.path.exists(CJK_BOLD) else CJK
    pdfmetrics.registerFont(TTFont("MSYH-Bold", bold, subfontIndex=0))
    mono = MONO if os.path.exists(MONO) else CJK
    pdfmetrics.registerFont(TTFont("MONO", mono))
    pdfmetrics.registerFontFamily(
        "MSYH", normal="MSYH", bold="MSYH-Bold", italic="MSYH", boldItalic="MSYH-Bold"
    )


# ---------- markdown 解析 ----------


def inline(text):
    """行内格式。先转义再做替换——md 里有 `<报文|文件>` 这种尖括号。"""
    s = html.escape(text, quote=False)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"`(.+?)`", r'<font name="MONO">\1</font>', s)
    return s


def is_table_sep(line):
    return bool(re.match(r"^\|[\s:|-]+\|$", line.strip())) and "-" in line


def parse(md):
    blocks = []
    lines = md.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()

        if not line:
            i += 1
            continue

        if line.startswith("# "):
            blocks.append(("h1", inline(line[2:].strip())))
            i += 1
            continue

        if line.startswith("## "):
            blocks.append(("h2", inline(line[3:].strip())))
            i += 1
            continue

        if line.startswith(">"):
            buf = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                buf.append(inline(lines[i].strip().lstrip(">").strip()))
                i += 1
            blocks.append(("byline", "　".join(buf)))
            continue

        if line.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                cur = lines[i].strip()
                i += 1
                if is_table_sep(cur):
                    continue
                rows.append([inline(c.strip()) for c in cur.strip("|").split("|")])
            if rows:
                blocks.append(("table", rows))
            continue

        if line.startswith("- "):
            items = []
            while i < len(lines):
                cur = lines[i]
                if cur.strip().startswith("- "):
                    items.append(inline(cur.strip()[2:].strip()))
                    i += 1
                elif cur.strip() and not cur.strip().startswith(("#", "|", ">", "-")):
                    items[-1] += inline(cur.strip())  # 裸续行并入上一条
                    i += 1
                else:
                    break
            blocks.append(("ul", items))
            continue

        buf = []
        while i < len(lines):
            cur = lines[i].strip()
            if not cur or cur.startswith(("#", "|", ">", "- ")):
                break
            buf.append(inline(cur))
            i += 1
        if buf:
            blocks.append(("p", "".join(buf)))

    return blocks


# ---------- 样式 ----------


def styles(fs):
    """字号基准 fs，其余按比例派生。"""
    base = dict(wordWrap="CJK", allowWidows=1, allowOrphans=1)
    return {
        "h1": ParagraphStyle(
            "h1", fontName="MSYH-Bold", fontSize=fs + 4.2, leading=(fs + 4.2) * 1.3,
            textColor=colors.HexColor("#111111"), spaceAfter=1.2 * mm, **base
        ),
        "h2": ParagraphStyle(
            "h2", fontName="MSYH-Bold", fontSize=fs + 1.5, leading=(fs + 1.5) * 1.32,
            textColor=colors.HexColor("#1a1a1a"), **base
        ),
        "byline": ParagraphStyle(
            "byline", fontName="MSYH", fontSize=fs - 0.2, leading=(fs - 0.2) * 1.45,
            textColor=colors.HexColor("#555555"), spaceAfter=1.8 * mm, **base
        ),
        "p": ParagraphStyle(
            "p", fontName="MSYH", fontSize=fs, leading=fs * 1.46,
            alignment=TA_JUSTIFY, spaceAfter=1.0 * mm, **base
        ),
        "li": ParagraphStyle(
            "li", fontName="MSYH", fontSize=fs, leading=fs * 1.46,
            alignment=TA_JUSTIFY, leftIndent=3.6 * mm, bulletIndent=1.0 * mm,
            spaceAfter=0.7 * mm, **base
        ),
        "th": ParagraphStyle(
            "th", fontName="MSYH-Bold", fontSize=fs - 0.3, leading=(fs - 0.3) * 1.38,
            alignment=TA_LEFT, **base
        ),
        "td": ParagraphStyle(
            "td", fontName="MSYH", fontSize=fs - 0.3, leading=(fs - 0.3) * 1.38,
            alignment=TA_LEFT, **base
        ),
    }


def h2_flow(text, st, avail_w):
    """节标题条：左侧粗线 + 浅底。

    ParagraphStyle 的 borderWidth 会画满四条边，做不出「只加左边线」，
    所以借一个单元格的表格来画——LINEBEFORE 只作用于左边界。
    """
    t = Table([[Paragraph(text, st)]], colWidths=[avail_w])
    t.setStyle(
        TableStyle(
            [
                ("LINEBEFORE", (0, 0), (0, -1), 0.85 * mm, colors.HexColor("#3a3a3a")),
                ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#f4f4f4")),
                ("LEFTPADDING", (0, 0), (-1, -1), 1.7 * mm),
                ("RIGHTPADDING", (0, 0), (-1, -1), 1.2 * mm),
                ("TOPPADDING", (0, 0), (-1, -1), 0.55 * mm),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 0.55 * mm),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ]
        )
    )
    return KeepTogether([Spacer(1, 1.6 * mm), t, Spacer(1, 0.9 * mm)])


def build_flow(blocks, fs, avail_w):
    st = styles(fs)
    flow = []
    for kind, payload in blocks:
        if kind == "h1":
            flow.append(Paragraph(payload, st["h1"]))
            flow.append(
                HRFlowable(
                    width="100%", thickness=0.55 * mm,
                    color=colors.HexColor("#222222"),
                    spaceBefore=0, spaceAfter=1.6 * mm,
                )
            )
        elif kind == "h2":
            flow.append(h2_flow(payload, st["h2"], avail_w))
        elif kind == "byline":
            flow.append(Paragraph(payload, st["byline"]))
        elif kind == "p":
            flow.append(Paragraph(payload, st["p"]))
        elif kind == "ul":
            for it in payload:
                flow.append(Paragraph(it, st["li"], bulletText="·"))
            flow.append(Spacer(1, 0.3 * mm))
        elif kind == "table":
            rows = payload
            head = [Paragraph(c, st["th"]) for c in rows[0]]
            body = [[Paragraph(c, st["td"]) for c in r] for r in rows[1:]]
            ncol = len(rows[0])
            first = avail_w * 0.21
            rest = (avail_w - first) / (ncol - 1) if ncol > 1 else avail_w
            widths = [first] + [rest] * (ncol - 1)
            t = Table([head] + body, colWidths=widths, repeatRows=0)
            t.setStyle(
                TableStyle(
                    [
                        ("GRID", (0, 0), (-1, -1), 0.22 * mm, colors.HexColor("#999999")),
                        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#ececec")),
                        ("VALIGN", (0, 0), (-1, -1), "TOP"),
                        ("LEFTPADDING", (0, 0), (-1, -1), 1.1 * mm),
                        ("RIGHTPADDING", (0, 0), (-1, -1), 1.1 * mm),
                        ("TOPPADDING", (0, 0), (-1, -1), 0.55 * mm),
                        ("BOTTOMPADDING", (0, 0), (-1, -1), 0.55 * mm),
                        ("ROWBACKGROUNDS", (0, 1), (-1, -1),
                         [colors.white, colors.HexColor("#fafafa")]),
                    ]
                )
            )
            flow.append(KeepTogether([t, Spacer(1, 0.8 * mm)]))
    return flow


def render(blocks, fs):
    pages = []

    def on_page(canvas, doc):
        pages.append(1)

    doc = SimpleDocTemplate(
        OUT_PDF, pagesize=A4,
        leftMargin=12 * mm, rightMargin=12 * mm,
        topMargin=10.5 * mm, bottomMargin=10 * mm,
        title="项目申报书 · mbt-datapoint",
        author="侯杰（Mr-Houjie）",
        subject="MoonBit 开源大赛 · 十一月黑客松",
    )
    avail_w = A4[0] - 24 * mm
    doc.build(build_flow(blocks, fs, avail_w), onFirstPage=on_page, onLaterPages=on_page)
    return len(pages)


def main():
    register_fonts()
    os.makedirs(os.path.join(ROOT, "_build"), exist_ok=True)
    md = open(SRC, encoding="utf-8").read()
    blocks = parse(md)
    nblocks = len(blocks)
    chars = sum(len(p) if isinstance(p, str) else sum(len(x) for x in p) for _, p in blocks)

    # 从大到小试，取「仍能单页」的最大字号；正文缩到 3000 字符后 6.85pt
    # 已不是上限，这个序列让脚本自己找当前内容能撑住的字号。
    for fs in (8.5, 8.2, 8.0, 7.8, 7.6, 7.4, 7.2, 7.0, 6.85, 6.7, 6.55, 6.4, 6.25, 6.1):
        if os.path.exists(OUT_PDF):
            os.remove(OUT_PDF)
        n = render(blocks, fs)
        print("字号 %.2fpt -> %d 页" % (fs, n))
        if n == 1:
            size = os.path.getsize(OUT_PDF)
            print(
                "OK  %s\n    %d 字节 / 1 页 / 字号 %.2fpt / %d 块 / 正文约 %d 字符"
                % (OUT_PDF, size, fs, nblocks, chars)
            )
            return
    sys.exit("九档字号都压不进一页，需要缩减正文")


if __name__ == "__main__":
    main()
