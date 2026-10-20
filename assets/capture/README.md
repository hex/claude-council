# Rebuild the README images

Run these commands from the checkout root. Each script runs on its own.

```bash
bash assets/capture/council-run.sh
bash assets/capture/heads-up.sh
bash assets/capture/tmux-pane.sh
bash assets/capture/banner.sh
```

The captures need Python 3, Bash, tmux, jq, and an authenticated
`~/.local/bin/claude`. The host runs Haiku on your account. Council seats default to
`tests/fixtures/fake-clis.bash`. No provider API key enters their environment.
The host keeps `HOME` and `USER` for its saved login.

The committed council and tmux animations use real subscription seats. Their
question is "Should a single-node demo app use SQLite or Postgres?" Run them
in that mode with:

```bash
COUNCIL_CAPTURE_SEATS=real bash assets/capture/council-run.sh
COUNCIL_CAPTURE_SEATS=real bash assets/capture/tmux-pane.sh
```

`COUNCIL_CAPTURE_SEATS=fake` is the default. In real mode, `codex`, `agy`,
`grok`, and `cursor-agent` use their saved logins through `HOME`; Kimi stays
the rate-limit fixture. Each real binary runs at most once per theme, apart
from `--version` probes. A guard rejects retries. Answers and failures stay
as the renderer displays them. Metadata records the mode, question, versions,
and invocation markers. Heads-up always uses fake seats.

Codex and Antigravity answered in the committed captures. Grok reported
`Not signed in`; Cursor reported a usage limit. Those errors remain visible.

The scripts use `tmux -L svgcap`. They refuse to start if that server already
has a session. They never use the default tmux server. Each terminal has 110
columns and 80 rows. The script zooms the tmux side pane to that width after the runner opens it.
Claude Code receives `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, a theme settings
file, and this checkout through `--plugin-dir`. The council capture opens the
inline pane with `ctrl+x tab` followed by `o`. At 110 columns the engine waits
for that action before it draws a pane opened by a timer.

Scratch projects live under `assets/capture/.<image>-<random>/`. Their
`.claude/` files belong to the capture. Existing session files stay untouched.
The scripts save and restore the workspace trust entry and the council's
heads-up and pane-host store keys. They stop their tmux server, stop
their host, and remove their `council-mod.*` directories on exit.
Scratch captures and failure logs remain available for inspection.

`capture.py` writes raw `.ansi` files and a frame manifest. `render.py`
converts those captures to SVG without replacing text or recoloring it.
Each frame names the source file, its `SHA-256` hash, and a half-open range of
terminal rows. Capture writes replace the current home directory prefix with
`~`, including failure captures and manifest text. The converter hashes the
saved files and writes those hashes back to the manifest.
The converter keeps all 110 columns. Light and dark are
separate captures. Captured colors remain literal; tmux sets the default
foreground and background recorded in the metadata.
Terminal hyperlink controls become plain text, so the SVG contains no links
to external resources. Identical text elements share internal SVG references
to keep the files below 80 KB. `shell.sh` keeps personal shell startup files out of
the capture environment.

In fake mode, Codex, Antigravity, and Grok use the fixture's `slow` behavior. Kimi uses
`rate-limit`. Cursor waits before the fixture's `valid` JSON response.
The heads-up script uses `heads-up-note` and the E2E's three-command host
prompt. The resulting draft stays unsent.

Each state lasts 2.5 seconds. Reduced motion shows the first state.
The font is 13 px, cells are 7.8 px, lines are 22 px, and padding is 24 px.
The banner is the only hand-written image. It uses the cs banner's
1536 by 614 viewBox and has no terminal capture.

The scripts keep raw captures below 100 KB beside them. Rebuild an SVG from
those records without making model calls:

```bash
python3 assets/capture/render.py assets/capture/council-run.json assets/council-run.svg
```

Check the XML, shell syntax, and README links:

```bash
xmllint --noout assets/*.svg
for script in assets/capture/*.sh; do bash -n "$script"; done
python3 assets/capture/check-links.py README.md
```
