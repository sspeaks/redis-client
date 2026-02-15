#!/usr/bin/env python3
"""
HTML renderer module for the comparison document.

Converts assembled Markdown into styled, self-contained HTML with
Chart.js interactive charts.
"""

import json
import re
import sys
from pathlib import Path
from typing import Optional

# Try to import markdown conversion libraries
try:
    import markdown

    def md_to_html(md_text: str) -> str:
        return markdown.markdown(
            md_text,
            extensions=["fenced_code", "tables", "codehilite", "toc"],
            extension_configs={
                "codehilite": {"guess_lang": False, "css_class": "codehilite"},
            },
        )

    HAS_MARKDOWN = True
except ImportError:
    HAS_MARKDOWN = False

try:
    import markdown2

    def md2_to_html(md_text: str) -> str:
        return markdown2.markdown(
            md_text,
            extras=["fenced-code-blocks", "tables", "code-friendly", "header-ids"],
        )

    HAS_MARKDOWN2 = True
except ImportError:
    HAS_MARKDOWN2 = False

# Try Pygments for syntax highlighting
try:
    from pygments import highlight
    from pygments.formatters import HtmlFormatter
    from pygments.lexers import get_lexer_by_name, guess_lexer

    HAS_PYGMENTS = True

    def get_pygments_css() -> str:
        return HtmlFormatter(style="default").get_style_defs(".codehilite")

except ImportError:
    HAS_PYGMENTS = False

    def get_pygments_css() -> str:
        return ""


CHART_JS_CDN = "https://cdn.jsdelivr.net/npm/chart.js"

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>hask-redis-mux vs StackExchange.Redis — Comparison</title>
  <style>
{css}
{pygments_css}
  </style>
  <script src="{chart_js_cdn}"></script>
</head>
<body>
{body}
{chart_scripts}
</body>
</html>
"""


def _highlight_code_blocks(html: str) -> str:
    """
    Post-process HTML to add syntax highlighting via Pygments
    for fenced code blocks that aren't already highlighted.
    """
    if not HAS_PYGMENTS:
        return html

    def replace_code_block(match):
        lang = match.group(1) or ""
        code = match.group(2)
        # Unescape HTML entities in code
        code = code.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
        try:
            lexer = get_lexer_by_name(lang) if lang else guess_lexer(code)
            formatter = HtmlFormatter(cssclass="codehilite", wrapcode=True)
            return highlight(code, lexer, formatter)
        except Exception:
            return match.group(0)

    pattern = r'<pre><code class="language-(\w+)">(.*?)</code></pre>'
    return re.sub(pattern, replace_code_block, html, flags=re.DOTALL)


def render_html(
    markdown_content: str,
    benchmark_data: Optional[dict] = None,
    css_path: Optional[str] = None,
) -> str:
    """
    Convert Markdown content to a self-contained HTML document.

    Args:
        markdown_content: The full Markdown document to render.
        benchmark_data: Chart data dict from render_benchmarks().
        css_path: Path to style.css file. If None, uses default location.

    Returns:
        Complete HTML document as a string.
    """
    # Read CSS
    if css_path is None:
        css_path = str(Path(__file__).parent / "templates" / "style.css")

    try:
        css = Path(css_path).read_text()
    except FileNotFoundError:
        print(f"Warning: CSS file not found at {css_path}", file=sys.stderr)
        css = ""

    # Convert Markdown to HTML
    if HAS_MARKDOWN:
        body = md_to_html(markdown_content)
    elif HAS_MARKDOWN2:
        body = md2_to_html(markdown_content)
    else:
        # Fallback: basic conversion
        print("Warning: Neither 'markdown' nor 'markdown2' installed. "
              "Using basic HTML wrapping.", file=sys.stderr)
        body = f"<pre>{markdown_content}</pre>"

    # Apply syntax highlighting
    body = _highlight_code_blocks(body)

    # Generate Pygments CSS
    pygments_css = get_pygments_css()

    # Generate Chart.js scripts
    chart_scripts = ""
    if benchmark_data:
        # Import the template module for chart snippets
        try:
            sys.path.insert(0, str(Path(__file__).parent / "templates" / "sections"))
            # The template is a Python file
            tmpl_path = Path(__file__).parent / "templates" / "sections" / "06_benchmarks.md.tmpl"
            if tmpl_path.exists():
                import importlib.util
                spec = importlib.util.spec_from_file_location("benchmarks_tmpl", str(tmpl_path))
                tmpl_mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(tmpl_mod)
                chart_scripts = tmpl_mod.render_chart_js_snippets(benchmark_data)
        except Exception as e:
            print(f"Warning: Could not generate chart scripts: {e}", file=sys.stderr)

    html = HTML_TEMPLATE.format(
        css=css,
        pygments_css=pygments_css,
        chart_js_cdn=CHART_JS_CDN,
        body=body,
        chart_scripts=chart_scripts,
    )

    return html
