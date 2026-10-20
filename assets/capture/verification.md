# Verification record

Checked on 2026-10-20. The council capture used checkout `9059e08`;
the tmux capture used `5bc859b`. Production code and API transport did not change.
The council host used Claude Code with Haiku.

| Image | Provenance | States | Bytes | Canvas |
|---|---|---:|---:|---|
| `council-run.svg` | Two subscription seats, two API seats, fake Kimi | 5 | 58082 | 906 by 774 |
| `tmux-pane.svg` | Two subscription seats, two API seats, fake Kimi | 3 | 23271 | 906 by 1280 |
| `heads-up.svg` | Existing fake seat capture, real Claude Code host | 4 | 16395 | 906 by 290 |
| `banner.svg` | Existing hand-written title card | 1 | 2114 | 1536 by 614 |

The real question was "Should a single-node demo app use SQLite or Postgres?"
Both themes finished with four answers and one fixture error. The hero shows
Kimi's row-level retry control while the four real seats are still querying.
The captures keep the real answers unchanged, with no repeated runs.

| Seat | Version or model | Outcome in both images and themes |
|---|---|---|
| Codex subscription | `codex-cli 0.163.0` | Answered |
| Antigravity subscription | `agy 1.4.3` | Answered |
| Gemini API | `gemini-flash-latest` | Answered |
| OpenAI API | `gpt-6-astra` | Answered |
| Kimi fixture | `fake-kimi 0.0.1` | `Error: 429 Too Many Requests` |

Each real binary ran once per theme for each image, apart from version probes.
Each manifest records four command-line invocation markers. The API seats used explicit
models and no transport retries. Grok and Cursor were absent from the capture
`PATH`. Heads-up still uses `fake-codex 0.0.1`; the banner invokes no binary.

Only `GEMINI_API_KEY` and `OPENAI_API_KEY` entered the capture's API key
environment. The harness removed both before invoking the subscription CLIs.
The shell loaded them from the session secret store; the harness does not
depend on that store. The existing API helper uses temporary mode-600 header
files and removes them on exit. The brief approved that production path unchanged.

Codex used a temporary mode-700 home seeded with only a mode-600 copy of
`auth.json`. The seed excluded personal instructions, configuration, and hooks.
The native version probe creates a `tmp` directory; setup removes that directory
before checking the auth-only seed. Native processes can create their own
runtime files during a query. The harness removes the whole temporary home on exit.

Preflight checks verified the copied auth bytes and permissions without
printing them, the two-key allowlist, the command-line environment, and the excluded
binaries. Normal exit and a setup failure caused by an occupied private tmux
server both removed the temporary home. The occupied server remained intact.
The fixture roster remains separate from the real roster.

All saved raw-capture hashes match their manifests. The three terminal manifests
rebuild byte-identical SVGs with `render.py`. The largest raw capture is 7,693
bytes. The harness normalizes home prefixes when writing captures. Crops select
original terminal rows and keep all 110 columns; they do not rewrite answers.
The existing heads-up focus-hint crops remain unchanged.

Google Chrome `155.0.8059.85` rasterized all 26 state/theme combinations.
Visual inspection covered every screenshot. Static previews kept one frame and one
theme, removed animation, and applied the theme's CSS at the SVG's canvas size:

```bash
chrome --headless --disable-gpu --no-first-run \
  --no-default-browser-check --disable-background-networking \
  --user-data-dir=assets/capture/.checks/chrome-profile \
  --window-size=WIDTH,HEIGHT --screenshot=FRAME.png file:///ABSOLUTE/FRAME.svg
```

`raster-check.json` records the source SVG and screenshot hashes. Captured logs
contained only the known macOS diagnostics for display-link creation, repeated
allocator loading, task category policy, and task suppression policy, plus
screenshot paths. Every invocation exited 0 and produced its screenshot.

The animation check sampled the SVG clock at 0, 2.6, 5.1, 7.6, 10.1, and 12.6
seconds. Exactly one council frame was visible at each sample, cycling back to
the first. With `--force-prefers-reduced-motion=reduce`, only the first frame
remained visible. `browser-check.json` records the values and source hash.

The council states and final tmux answers fit. The middle tmux capture caught
OpenAI's header before the terminal painted its answer body; the final state contains
all four full answers. The existing heads-up intro tip truncates at 110 columns.
These are terminal capture limits, not text removed by the SVG renderer.

An optional `git diff --check` reported trailing blank rows in six council raw
captures: state 1 in both themes, state 2 in both themes, and states 3 and 4 in
dark. The captures keep those original 80-row terminal blanks.
The commits ran without bypassing hooks.

The required check passed:

```bash
set -o pipefail
xmllint --noout assets/*.svg &&
  for f in assets/capture/*.sh; do bash -n "$f"; done &&
  python3 assets/capture/check-links.py README.md &&
  ! grep -rl '/''Users/' assets/ &&
  ! grep -rli 'al''ex' assets/
```

The adjacent quoted strings avoid matching this record itself; the shell
passes the original patterns to grep. Both scans found no matches. README
passed 35 link checks. XML parsing, Python syntax, and shell syntax passed.
Every SVG is below 80 KB and contains no scripts or external resources.
An exact-byte scan for both API key values found no matches in the assets,
including capture scratch files and logs, without printing either value.

Vale passed for README, the capture README, this record, and the changed
captions. Cleanup removed this run's scratch projects and Chrome profiles.
No copied Codex home, request header file, capture host, private tmux server,
or capture trust entry remained.

The process and filesystem review found no captured text used as executable
code, external SVG references, or production changes. The contribution gate
passed: real runs, honest data and names, checked failure paths, and review of
every changed file. Neither `bats` nor `git push` ran.
