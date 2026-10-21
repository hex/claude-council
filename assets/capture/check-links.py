#!/usr/bin/env python3
# ABOUTME: Checks Markdown file links and heading anchors against the checkout.
# ABOUTME: Includes inline images, reference links, and HTML href and src attributes.

import argparse
import functools
import html
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = []
        self.anchors = set()

    def handle_starttag(self, tag, attributes):
        for name, value in attributes:
            if value is not None:
                if name in ("href", "src"):
                    self.urls.append(value)
                elif name == "id" or (tag == "a" and name == "name"):
                    self.anchors.add(value)


def prose(path):
    lines = []
    fence = None
    for line in path.read_text().splitlines():
        match = re.match(r"^\s*(`{3,}|~{3,})", line)
        if match:
            mark = match[1][0]
            if fence is None:
                fence = mark
            elif fence == mark:
                fence = None
            continue
        if fence is None:
            lines.append(line)
    return "\n".join(lines)


@functools.lru_cache(maxsize=None)
def anchors(path):
    text = prose(path)
    parser = Links()
    parser.feed(text)
    found = parser.anchors
    used = {}
    headings = re.findall(r"^ {0,3}#{1,6}\s+(.+?)(?:\s+#+)?$", text, re.M)
    headings += re.findall(r"^(.+)\n(?:={3,}|-{3,})\s*$", text, re.M)
    for heading in headings:
        heading = html.unescape(re.sub(r"<[^>]*>", "", heading))
        heading = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", heading)
        slug = re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
        suffix = used.get(slug, 0)
        used[slug] = suffix + 1
        found.add(f"{slug}-{suffix}" if suffix else slug)
    return found


def check(path):
    text = prose(path)
    parser = Links()
    parser.feed(text)
    urls = parser.urls + re.findall(r"!?\[[^\]]*\]\(\s*<?([^\s)>]+)>?(?:\s+\"[^\"]*\")?\s*\)", text)
    references = dict(re.findall(r"^\s*\[([^\]]+)\]:\s*<?([^\s>]+)>?", text, re.M))
    references = {key.casefold(): value for key, value in references.items()}
    errors = []
    for label, ref in re.findall(r"!?\[([^\]]+)\]\[([^\]]*)\]", text):
        key = (ref or label).casefold()
        if key not in references:
            errors.append(f"undefined reference [{ref or label}]")
    urls += list(references.values())
    for url in urls:
        parts = urlsplit(html.unescape(url))
        if parts.scheme or parts.netloc:
            continue
        target = path.parent / unquote(parts.path) if parts.path else path
        if not target.exists():
            errors.append(f"missing file: {url}")
        elif parts.fragment and target.suffix.lower() == ".md":
            if unquote(parts.fragment) not in anchors(target):
                errors.append(f"missing anchor: {url}")
    for error in errors:
        print(f"{path}: {error}", file=sys.stderr)
    if not errors:
        print(f"{path}: {len(urls)} links checked")
    return not errors


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    results = [check(path) for path in args.files]
    sys.exit(0 if all(results) else 1)
