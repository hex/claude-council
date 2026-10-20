# Verification record

Checked on 2026-10-20 in this worktree. Renderer source was at
`34bb74a2e0ae5c9d0321b754cd94a704b765ebd3`. Production code did not change.
The host was Claude Code 2.1.304 with Haiku.

| Image | States | Bytes | Canvas |
|---|---:|---:|---|
| `council-run.svg` | 5 | 79336 | 906 by 664 |
| `heads-up.svg` | 4 | 24888 | 906 by 312 |
| `tmux-pane.svg` | 3 | 14859 | 906 by 620 |
| `banner.svg` | 1 title card | 2069 | 1536 by 614 |

The three terminal manifests rebuild byte-identical SVGs with `render.py`.
All 24 raw captures match the hashes in SVG metadata. The largest raw file
is 7,345 bytes. XML parsing, Python syntax, and every shell script's syntax
passed. Each SVG has a title, description, metadata, theme rules, and the
required animation and reduced-motion rules. No SVG loads external content
or contains a script.

The requested check passed:

```bash
set -o pipefail
xmllint --noout assets/*.svg &&
  bash -n assets/capture/*.sh &&
  python3 assets/capture/check-links.py README.md
```

The shell check also ran once per script because `bash -n` accepts one script;
the remaining arguments in the command above would become its arguments.
The README passed 35 link checks. Reference passed 19, the mod README passed
5, and Architecture had no file links. The link checker's recorded positive
and negative controls are in `link-check.txt`.

Vale reported no alerts for the final README or capture README. New prose in
Reference and the mod README also passed. Extracting added lines from the
Architecture tree produced two alerts for `USAGE.md`; those are false
positives because extraction removed the surrounding code fence and the
capitalization is the real filename. A broader Vale run also reported
pre-existing guide prose alerts; that prose was outside this rewrite.

ImageMagick 7.1.2-31 rasterized the first state of all four SVGs in both
themes. Static preview copies retained one state and one theme, removed
animation, and applied the selected theme's CSS. The command used the
installed Menlo font:

```bash
/opt/homebrew/bin/magick -font /System/Library/Fonts/Menlo.ttc first-state.svg first-state.png
```

The first states were inspected at the canvas sizes above. Magick misrenders
the terminal prompt glyph beside the cursor and differs in text spacing.
Chrome renders those glyphs and positions correctly. Browser screenshots
also confirmed the failed-seat retry row, open synthesis, unsent heads-up
draft, and tmux retry offer. No captured text or color was changed to work
around a rasterizer.

Chrome's SVG clock was sampled at 0, 2.6, 5.1, 7.6, 10.1, and 12.6 seconds.
Exactly one council frame was opaque at each sample, cycling back to the
first. With `--force-prefers-reduced-motion=reduce`, only the first frame
remained visible at every sample. `browser-check.json` records computed
opacity and display values. An earlier invocation with the bare reduced-motion
flag failed, and a fresh-profile attempt timed out; the explicit value on the
working profile passed.

The accepted council and tmux runs each recorded two calls per fake binary,
one for each theme. Heads-up recorded two fake codex calls. No provider API
key entered the explicit capture environment. The credential-pattern scan
found no matches in raw captures, manifests, or SVGs.

The private tmux server, capture hosts, capture trust entries, and
`council-mod.*` scratch directories were absent after the runs. The harness
restores the store keys it changes. Generated scratch projects and preview
profiles were removed after inspection.

Every requested state fit. The heads-up intro tail truncates naturally at
110 columns; the raw terminal does the same. The tmux pane uses the actual
renderer, zoomed to 110 columns.

The post-commit process and filesystem review found no shell interpolation
from captured data, exposed credentials, or writes to production code.
The five-question contribution gate passed: actual runs, honest data,
literal naming, failure paths, and review of every changed file.
No bats suite ran. Nothing was pushed.
