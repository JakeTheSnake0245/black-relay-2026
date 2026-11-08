#!/usr/bin/env python3
"""Render multipath/docs/diagrams.md (Mermaid) into a PDF with the graphs drawn.

  python3 multipath/scripts/render-diagrams.py [out.pdf]

Default output: docs/Black-Relay-Diagrams.pdf at the workspace root. Needs Google
Chrome (headless) and internet for the pinned Mermaid script.
"""
import html
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "docs", "diagrams.md")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "docs", "Black-Relay-Diagrams.pdf")
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
MERMAID = "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"

md = open(SRC, encoding="utf-8").read()
parts, title, intro = [], "Black Relay — diagrams", []
for block in re.split(r"(?m)^## ", md)[1:]:
    head, _, body = block.partition("\n")
    m = re.search(r"```mermaid\n(.*?)```", body, re.S)
    text = re.sub(r"```mermaid\n.*?```", "", body, flags=re.S).strip()
    parts.append((head.strip(), text, m.group(1) if m else ""))

def para(t):
    t = html.escape(t)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    return "".join(f"<p>{p.strip()}</p>" for p in t.split("\n\n") if p.strip())

toc = "".join(f"<li>{html.escape(re.sub(r'^[0-9]+[.] ', '', h))}</li>" for h, _, _ in parts)
sections = "\n".join(
    f'<section><h2>{html.escape(h)}</h2>{para(t)}<pre class="mermaid">{html.escape(g)}</pre></section>'
    for h, t, g in parts)

page = f"""<!doctype html><html><head><meta charset="utf-8"><title>{html.escape(title)}</title>
<style>
@page {{ size: 11in 8.5in; margin: 0.45in; }}
body {{ font: 10.5pt/1.4 -apple-system, "Helvetica Neue", Arial, sans-serif; color: #1b2117; margin: 0; }}
h1 {{ font-size: 24pt; margin: 0 0 4px; }}
.sub {{ color: #5a6454; margin-bottom: 10px; }}
section {{ break-inside: avoid; page-break-inside: avoid; border-top: 2px solid #1b2117; padding-top: 8px; margin-bottom: 18px; }}
section {{ break-before: page; }}
ol.toc {{ font-size: 13pt; line-height: 1.9; margin-top: 18px; }}
h2 {{ font-size: 15pt; margin: 0 0 6px; }}
p {{ margin: 0 0 6px; color: #3a4235; }}
code {{ font-family: Menlo, monospace; font-size: 9pt; }}
pre.mermaid {{ display: flex; justify-content: center; margin: 6px 0 0; }}
pre.mermaid svg {{ max-width: 100%; max-height: 6.6in; height: auto; }}
</style></head><body>
<h1>Black Relay — how it fits together</h1>
<div class="sub">CWWK site box · multipath tunnel · BR2026 hub · site lock · Sensor Fusion. Source: multipath/docs/diagrams.md</div>
<ol class="toc">{toc}</ol>
{sections}
<script src="{MERMAID}"></script>
<script>
mermaid.initialize({{ startOnLoad: false, theme: "neutral", securityLevel: "strict",
  flowchart: {{ useMaxWidth: true, htmlLabels: true }}, sequence: {{ useMaxWidth: true }} }});
mermaid.run({{ querySelector: "pre.mermaid" }}).then(() => {{ document.title = "RENDERED"; }});
</script></body></html>"""

with tempfile.TemporaryDirectory() as d:
    src = os.path.join(d, "diagrams.html")
    open(src, "w", encoding="utf-8").write(page)
    os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                    "--virtual-time-budget=20000", "--run-all-compositor-stages-before-draw",
                    f"--print-to-pdf={os.path.abspath(OUT)}", "file://" + src],
                   check=True, capture_output=True, timeout=180)
print("wrote", os.path.abspath(OUT))
