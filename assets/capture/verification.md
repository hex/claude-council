# Verification record

Checked on 2026-10-20. The real captures used checkout
`afff4c5a2f7dbeb3669e6c2f9df78290f0ffbae1`. Production code did not change.
The council host was Claude Code 2.1.304 with Haiku.

| Image | Mode | States | Bytes | Canvas |
|---|---|---:|---:|---|
| `council-run.svg` | real seats, fake Kimi | 5 | 57967 | 906 by 774 |
| `heads-up.svg` | fake seat | 4 | 16395 | 906 by 290 |
| `tmux-pane.svg` | real seats, fake Kimi | 3 | 18656 | 906 by 950 |
| `banner.svg` | hand-written | 1 | 2114 | 1536 by 614 |

The real question was "Should a single-node demo app use SQLite or Postgres?"
Each real binary ran once per theme for each image, apart from version probes.
Each manifest records eight invocation markers. The guard allowed no retries.
No provider API key entered the explicit capture environment.

| Binary | Council version probe | Tmux version probe | Outcome in both themes |
|---|---|---|---|
| `codex` | `codex-cli 0.163.0` | `codex-cli 0.163.0` | Answered |
| `agy` | `1.4.2` | `1.4.3` | Answered |
| `grok` | `grok 1.0.60 (01a8e1c591c0) [stable]` | same | `Not signed in` |
| `cursor-agent` | `2026.10.14-0f9edde` | same | `You've hit your usage limit` |
| `kimi` | `fake-kimi 0.0.1` | same | `Error: 429 Too Many Requests` |

Antigravity's version probe changed between captures. Both recorded values
remain in the provenance. Heads-up uses the unchanged
`fake-codex 0.0.1` fixture from its original capture. The banner invokes no binary.
Frames keep each real answer and failure from its only run.

The first real council conversion failed its size check at 90,501 bytes.
Sharing identical text elements through internal SVG references reduced it
to 57,796 bytes before normalization. Expanding those references reproduced
the original XML byte for byte. Chrome screenshots of the expanded-answer
state before and after compression had zero differing pixels in both themes.

All 24 committed raw captures differ from item 1 only by replacement of the
current home directory prefix with `~`. All manifest and SVG hashes match
those saved files. The largest raw capture is 7,552 bytes. All three terminal
manifests rebuild byte-identical SVGs with `render.py`.

Before cropping, the heads-up SVG was byte-identical outside metadata after
home normalization. Cropping changed five heads-up row ranges and no raw
bytes. Each removed hint was the last row in its range. The real council
frames contain no focus hint. No required content blocked a hint crop.

The capture driver also passed two bounded checks against a live private
tmux server. Normal and timeout captures wrote `home=~`. The timeout raised
the expected missing-marker error. A trailing focus hint produced a one-row
crop; the same hint followed by required content produced a three-row crop.
Both raw files retained the hint.

The invocation guard passed a native-process check: the first call printed
`seat guard probe`, and the second exited 1 with exactly
`Capture refused a second real codex invocation in this theme`.
An invalid mode exited before setup with
`ValueError: COUNCIL_CAPTURE_SEATS must be real or fake`.
The updated fake council harness also completed both themes before the real
calls.

Google Chrome `155.0.8059.85` rasterized all 26 state/theme combinations.
Visual inspection covered the first frame of every image in both themes, plus the
council retry row, answers and synthesis, the expanded heads-up note and
unsent draft, and the tmux retry offer. Static preview copies retained one
frame and one theme, removed animation, and applied that theme's CSS.
The screenshots used each SVG's own canvas size:

```bash
chrome --headless --disable-gpu --no-first-run \
  --no-default-browser-check --disable-background-networking \
  --user-data-dir=assets/capture/.checks/chrome-profile \
  --window-size=WIDTH,HEIGHT --screenshot=FRAME.png file:///ABSOLUTE/FRAME.svg
```

`raster-check.json` records the source SVG and screenshot hashes. Chrome
logged four macOS diagnostic classes: display-link creation, repeated
allocator loading, task category policy, and task suppression policy.
Inspection covered those captured logs. Every invocation exited 0 and
produced its screenshot.

The Chrome check sampled its SVG clock at 0, 2.6, 5.1, 7.6, 10.1, and 12.6 seconds.
Exactly one council frame was opaque at each sample, cycling back to the
first. With `--force-prefers-reduced-motion=reduce`, only the first frame
remained visible. `browser-check.json` records the values, Chrome version,
and source hash.

All requested states fit. The dark council pane clips the end of
Antigravity's expanded answer at its own lower border. The heads-up intro
tail truncates at 110 columns. Both limits are present in the raw terminal;
the SVG does not replace or shorten that text.

The required check passed:

```bash
set -o pipefail
xmllint --noout assets/*.svg &&
  for f in assets/capture/*.sh; do bash -n "$f"; done &&
  python3 assets/capture/check-links.py README.md &&
  ! grep -rl '/''Users/' assets/
```

The split quoted pattern avoids matching this record itself. The shell
passes the same pattern to grep. README passed 35 link checks. XML parsing,
Python syntax, and every shell script's syntax passed. All SVGs remain below
80 KB and contain no scripts or external resources. Credential-pattern
checks found no exposed keys in the committed assets.

Vale reported no alerts for README, the capture README, or this record.
The private tmux server, capture hosts, capture trust entries, and
`council-mod.*` directories were absent after the runs. Cleanup removed capture
scratch projects and Chrome profiles after inspection.

The process and filesystem review found no captured text used as executable
code, external SVG references, or writes to production code. The contribution
gate passed: real runs, honest data, literal naming, checked failure paths,
and review of the changed files. Neither `bats` nor `git push` ran.
