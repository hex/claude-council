# ABOUTME: Council-tuned Rich markdown renderer for the streaming pane
# ABOUTME: Runs as `$py_cmd render.py`; theme/width via COUNCIL_THEME_RESOLVED and COLUMNS
# Council-tuned Rich markdown renderer for the streaming pane. Sparse
# terminal-palette styling (no background fills, terminal's own colors),
# left-aligned headings, OSC 8 hyperlinks, and the council's <think> block
# treatment. Theme and width arrive via COUNCIL_THEME_RESOLVED and COLUMNS.
import os
import re
import sys

from rich.console import Console, Group
from rich.markdown import Heading, Markdown
from rich.padding import Padding
from rich.text import Text
from rich.theme import Theme

theme = os.environ.get("COUNCIL_THEME_RESOLVED", "unknown")
# ansi_* pygments themes color code with the terminal's 16-color palette and
# no background fill, so highlighting inherits the user's terminal theme.
code_theme = "ansi_light" if theme == "light" else "ansi_dark"

# Council visual language (mirrors the perl renderer): cyan headings,
# yellow inline code, cyan bullets, dim rules.
council = Theme(
    {
        "markdown.h1": "bold reverse cyan",
        "markdown.h2": "bold cyan",
        "markdown.h3": "bold cyan",
        "markdown.h4": "bold",
        "markdown.h5": "bold italic",
        "markdown.h6": "dim italic",
        "markdown.code": "yellow",
        "markdown.block_quote": "italic",
        "markdown.item.bullet": "cyan",
        "markdown.item.number": "cyan",
        "markdown.hr": "dim",
        "markdown.link": "underline cyan",
        # With hyperlinks=True Rich styles the visible anchor text via
        # link_url (the URL itself is never printed), so this key carries
        # the perl renderer's underline-cyan anchor style.
        "markdown.link_url": "underline cyan",
        "markdown.table.header": "bold cyan",
    }
)


class PlainHeading(Heading):
    """Left-aligned headings, no panel box around h1."""

    def __rich_console__(self, console, options):
        text = self.text
        text.justify = "left"
        if self.tag == "h1":
            text.pad(1)
        yield text


Markdown.elements["heading_open"] = PlainHeading

source = sys.stdin.read()

# Providers wrap reasoning in <think> blocks. Rich's Markdown treats them as
# raw HTML and drops them, so split them out and style them here. Tags are
# line-anchored (perl parity) so an inline mention in prose or a fence is not
# ripped out of context; an unclosed tag (response truncated mid-reasoning)
# keeps the tail visible as think content instead of Rich dropping it.
THINK_PAIR = re.compile(r"(?ms)^[ \t]*<think>[ \t]*\n?(.*?)\n?^[ \t]*</think>[ \t]*\n?")
THINK_OPEN = re.compile(r"(?m)^[ \t]*<think>[ \t]*\n?")

parts = []
pos = 0
for m in THINK_PAIR.finditer(source):
    if m.start() > pos:
        parts.append(("md", source[pos : m.start()]))
    parts.append(("think", m.group(1)))
    pos = m.end()
tail = source[pos:]
open_m = THINK_OPEN.search(tail)
if open_m:
    if open_m.start():
        parts.append(("md", tail[: open_m.start()]))
    parts.append(("think", tail[open_m.end() :]))
elif tail:
    parts.append(("md", tail))

env_cols = os.environ.get("COLUMNS", "")
# Reject 0: width 0 renders zero bytes with exit 0. Scrub the variable too,
# because Console reads COLUMNS from the environment on its own.
if env_cols.isdigit() and int(env_cols) > 0:
    width = int(env_cols)
else:
    os.environ.pop("COLUMNS", None)
    width = None
console = Console(force_terminal=True, theme=council, width=width)
renderables = []
for kind, body in parts:
    if kind == "think":
        renderables.append(Text("▸ thinking", style="dim italic"))
        renderables.append(Padding(Text(body.strip(), style="dim italic"), (0, 0, 1, 2)))
    else:
        renderables.append(Markdown(body, code_theme=code_theme, hyperlinks=True))
console.print(Group(*renderables))
