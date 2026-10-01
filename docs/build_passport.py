#!/usr/bin/env python3
"""Render docs/passport.md to docs/Паспорт.pdf (four A4 pages at most)."""

from pathlib import Path

from fpdf import FPDF

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "passport.md"
OUTPUT = ROOT / "Паспорт.pdf"
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


class Passport(FPDF):
    def footer(self):
        self.set_y(-12)
        self.set_font("DejaVu", "", 8)
        self.set_text_color(80, 80, 80)
        self.cell(0, 8, f"стр. {self.page_no()}", align="R")


def draw_diagram(pdf: Passport) -> None:
    pdf.ln(1)
    x0 = pdf.l_margin
    y0 = pdf.get_y()
    width = pdf.w - pdf.l_margin - pdf.r_margin
    height = 42
    pdf.set_draw_color(40, 70, 90)
    pdf.set_fill_color(236, 244, 246)
    pdf.rect(x0, y0, width, height, style="DF")
    pdf.set_font("DejaVu", "", 8)
    pdf.set_text_color(20, 30, 40)
    rows = [
        (6, "пользователь"),
        (14, "↓  HTTPS, VIP MetalLB, testy.local / api.testy.local"),
        (22, "kubeadm: Envoy Gateway только на двух узлах gateway"),
        (30, "↓ UI-маршрут          ↓ API-маршрут"),
        (38, "TestY frontend        TestY API + sidecar access-log"),
    ]
    for dy, text in rows:
        pdf.set_xy(x0 + 4, y0 + dy - 4)
        pdf.cell(width - 8, 5, text)
    pdf.set_xy(x0, y0 + height + 1)
    pdf.set_font("DejaVu", "", 8)
    pdf.multi_cell(width, 4, "Рядом: Prometheus и Grafana смотрят метрики; Fluentd забирает access-лог и пишет в Loki, Grafana читает Loki.")
    pdf.ln(1)


def render() -> None:
    pdf = Passport(format="A4", unit="mm")
    pdf.set_auto_page_break(auto=True, margin=14)
    pdf.add_font("DejaVu", "", FONT)
    pdf.add_font("DejaVu", "B", FONT_BOLD)
    pdf.set_margins(14, 12, 14)
    pdf.add_page()
    for raw in SOURCE.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        if not line:
            pdf.ln(1.5)
            continue
        if line == "[[diagram]]":
            draw_diagram(pdf)
            continue
        if line.startswith("# "):
            pdf.set_font("DejaVu", "B", 14)
            pdf.set_text_color(15, 40, 55)
            pdf.multi_cell(0, 7, line[2:])
            pdf.ln(1)
            continue
        if line.startswith("## "):
            pdf.set_font("DejaVu", "B", 11)
            pdf.set_text_color(20, 55, 75)
            pdf.multi_cell(0, 6, line[3:])
            pdf.ln(0.5)
            continue
        pdf.set_x(pdf.l_margin)
        if line.startswith("- "):
            pdf.set_font("DejaVu", "", 9)
            pdf.set_text_color(20, 20, 20)
            pdf.multi_cell(0, 4.3, "- " + line[2:])
            continue
        pdf.set_font("DejaVu", "", 9)
        pdf.set_text_color(20, 20, 20)
        pdf.multi_cell(0, 4.3, line)
    if pdf.page_no() > 4:
        raise SystemExit(f"passport is {pdf.page_no()} pages, limit is 4")
    pdf.output(str(OUTPUT))
    print(f"wrote {OUTPUT} ({pdf.page_no()} pages)")


if __name__ == "__main__":
    render()
