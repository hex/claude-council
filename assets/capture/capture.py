#!/usr/bin/env python3
# ABOUTME: Captures the checkout's council renderers in a private tmux server.
# ABOUTME: Uses fixture seats, bounds every wait, and restores trust and plugin state.

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path

from render import THEMES, render


ROOT = Path(__file__).resolve().parents[2]
CAPTURE = ROOT / "assets/capture"
TMUX = shutil.which("tmux")
KEYS = {"heads-up", "heads-up-counts", "heads-up-intro-shown", "pane_host",
        "specialist-runs", "specialists-latest", "specialists-intro-shown"}
ANSI = re.compile(r"\x1b\[[0-9;]*m")
ROSTER = "codex,antigravity,grok-cli,kimi-cli,cursor-cli"
TITLES = {
    "council-run": "Five council seats inside Claude Code",
    "heads-up": "A heads-up note and an unsent draft",
    "tmux-pane": "Council answers in a tmux side pane",
}


def run(*args, env=None, check=True):
    return subprocess.run(args, cwd=ROOT, env=env, check=check, capture_output=True, text=True)


class Capture:
    def __init__(self, name):
        self.name = name
        self.work = Path(tempfile.mkdtemp(prefix=f".{name}-", dir=CAPTURE))
        self.project = self.work / "project"
        self.temp = self.work / "tmp"
        self.fake = self.work / "fakebin"
        self.raw = self.work / "fixture-bin"
        self.frames = []
        self.theme = "light"
        self.target = "capture:0.0"
        self.stores = Path.home() / ".claude/plugins/store"
        self.trust = Path.home() / ".claude.json"
        self.before_stores = {}
        self.before_project = None
        self.had_project = False
        self.started = False
        self.seeded = False

    def tmux(self, *args, check=True):
        return run(TMUX, "-L", "svgcap", *args, env=self.env, check=check)

    def __enter__(self):
        if not TMUX:
            raise RuntimeError("tmux is required")
        for path in (self.project / ".claude", self.temp, self.fake, self.raw, self.work / "fake-state"):
            path.mkdir(parents=True, exist_ok=True)
        self.env = {
            "HOME": str(Path.home()), "PATH": f"{self.fake}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "USER": os.environ["USER"],
            "TMPDIR": str(self.temp), "TERM": "xterm-256color", "COLORTERM": "truecolor",
            "LANG": "en_US.UTF-8", "SHELL": "/bin/bash",
            "BASH_ENV": "/dev/null", "ENV": "/dev/null",
            "CLAUDE_CODE_SHELL": str(self.fake / "bash"),
            "COUNCIL_FAKE_STATE_DIR": str(self.work / "fake-state"),
            "COUNCIL_FAKE_BEHAVIOR": "heads-up-note" if self.name == "heads-up" else "slow",
            "COUNCIL_FAKE_SLEEP": "20", "COUNCIL_PROVIDERS": ROSTER,
            "COUNCIL_RETRY_WAIT": "12", "COUNCIL_JOBS_DIR": str(self.work / "jobs"),
            "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1",
            "CLAUDE_CODE_NO_FLICKER": "0",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        }
        existing = self.tmux("list-sessions", check=False)
        if existing.returncode == 0:
            raise RuntimeError("tmux -L svgcap already has sessions; refusing to touch them")
        if "no server running" not in existing.stderr and "error connecting" not in existing.stderr:
            raise RuntimeError(f"Cannot check svgcap server: {existing.stderr}")
        installer = 'source "$1"; for bin in codex agy grok kimi cursor-agent; do write_fake_cli "$bin"; done'
        run("/bin/bash", "-c", installer, "capture-fixtures", str(ROOT / "tests/fixtures/fake-clis.bash"),
            env={**self.env, "FAKE_BIN_DIR": str(self.raw)})
        (self.fake / "bash").symlink_to(CAPTURE / "shell.sh")
        for binary, seconds in (("codex", 45), ("agy", 65), ("grok", 15), ("kimi", 0), ("cursor-agent", 30)):
            # Positional arguments keep paths out of shell source.
            script = self.fake / binary
            if self.name == "heads-up":
                script.symlink_to(self.raw / binary)
                continue
            body = ['#!/bin/bash', 'set -euo pipefail',
                    'if [[ "${1:-}" == "--version" ]]; then exec "${0%/*}/../fixture-bin/${0##*/}" "$@"; fi']
            if binary == "kimi":
                body += ['sleep 12', 'export COUNCIL_FAKE_BEHAVIOR=rate-limit']
            elif binary == "cursor-agent":
                body += [f"sleep {seconds}", "export COUNCIL_FAKE_BEHAVIOR=valid"]
            else:
                body += [f"export COUNCIL_FAKE_SLEEP={seconds}", "export COUNCIL_FAKE_BEHAVIOR=slow"]
            body += ['exec "${0%/*}/../fixture-bin/${0##*/}" "$@"']
            script.write_text("\n".join(body) + "\n")
            script.chmod(0o755)
        if self.name != "tmux-pane":
            for path in self.stores.glob("claude-council_inline-*.json"):
                self.before_stores[path] = json.loads(path.read_text())
            data = json.loads(self.trust.read_text())
            self.had_project = str(self.project) in data.get("projects", {})
            self.before_project = data.get("projects", {}).get(str(self.project))
            data.setdefault("projects", {})[str(self.project)] = {"hasTrustDialogAccepted": True}
            self.trust.write_text(json.dumps(data, indent=2) + "\n")
            self.seeded = True
        return self

    def __exit__(self, kind, error, traceback):
        try:
            self.stop()
        finally:
            if self.seeded:
                for path in self.stores.glob("claude-council_inline-*.json"):
                    data = json.loads(path.read_text())
                    before = self.before_stores.get(path, {})
                    for key in KEYS:
                        if key in before:
                            data[key] = before[key]
                        else:
                            data.pop(key, None)
                    if data or path in self.before_stores:
                        path.write_text(json.dumps(data, indent=2) + "\n")
                    else:
                        path.unlink()
                data = json.loads(self.trust.read_text())
                if self.had_project:
                    data["projects"][str(self.project)] = self.before_project
                else:
                    data.get("projects", {}).pop(str(self.project), None)
                self.trust.write_text(json.dumps(data, indent=2) + "\n")
        print(f"Capture records: {self.work}", flush=True)

    def stop(self):
        if not self.started:
            return
        self.tmux("send-keys", "-t", "capture:0.0", "C-c", check=False)
        self.tmux("kill-server", check=False)
        self.started = False
        # A host can survive its terminal. Match this run's unique debug path.
        processes = run("/bin/ps", "-axo", "pid=,command=").stdout.splitlines()
        own = []
        for line in processes:
            if str(self.work / "debug-") in line and "--plugin-dir" in line:
                pid = int(line.strip().split(maxsplit=1)[0])
                own.append(pid)
                os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            alive = []
            for pid in own:
                try:
                    os.kill(pid, 0)
                    alive.append(pid)
                except ProcessLookupError:
                    pass
            if not alive:
                break
            time.sleep(.1)
        for pid in alive if own else []:
            os.kill(pid, signal.SIGKILL)
        for path in self.temp.glob("council-mod.*"):
            shutil.rmtree(path)

    def start(self, theme):
        self.theme = theme
        self.target = "capture:0.0"
        self.env["COUNCIL_THEME"] = theme
        fg, bg = THEMES[theme]
        config = self.work / "tmux.conf"
        config.write_text(f"set -g status off\nset -g default-shell /bin/bash\nset -g default-terminal xterm-256color\nset -g window-style 'fg={fg},bg={bg}'\nset -g history-limit 1000\n")
        if self.name == "tmux-pane":
            command = ["/bin/bash", str(ROOT / "scripts/run-council.sh"),
                       f"--providers={ROSTER}", "--no-cache", "--no-auto-context",
                       "--", "Should a single-node demo use SQLite?"]
        else:
            for path in self.stores.glob("claude-council_inline-*.json"):
                data = json.loads(path.read_text())
                for key in ("heads-up", "heads-up-counts", "heads-up-intro-shown"):
                    data.pop(key, None)
                data["pane_host"] = "mod"
                path.write_text(json.dumps(data, indent=2) + "\n")
            (self.project / ".claude/council-heads-up.json").write_text(
                '{"enabled":false,"seat":"codex","every":2}\n')
            settings = self.work / f"{theme}.json"
            settings.write_text(json.dumps({"theme": theme, "enabledPlugins": {}}))
            command = [str(Path.home() / ".local/bin/claude"),
                       "--plugin-dir", str(ROOT), "--model", "haiku",
                       "--permission-mode", "bypassPermissions", "--allow-dangerously-skip-permissions",
                       "--setting-sources", "", "--settings", str(settings),
                       "--strict-mcp-config", "--debug-file", str(self.work / f"debug-{theme}.log"),
                       "--append-system-prompt",
                       "This is a terminal capture with fake council seats. Keep replies short. "
                       "Do not change files except council runtime state. Follow the requested commands. "
                       "Do not load other skills, run git, or delegate. Run the council once only. "
                       "The FAKE responses and the Kimi error are expected fixtures. "
                       "Write a one-sentence synthesis under ## Synthesis, then Full output saved."]
        self.tmux("-f", str(config), "new-session", "-d", "-s", "capture", "-x", "110", "-y", "80",
                  "-c", str(self.project), *command)
        self.started = True

    def screen(self):
        return self.tmux("capture-pane", "-t", self.target, "-p", "-e").stdout

    def wait(self, phrase, seconds=150):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            text = ANSI.sub("", self.screen())
            if phrase in text:
                return
            if "Not logged in" in text:
                raise RuntimeError("The host Claude is not logged in")
            if "Where should the council pane open?" in text:
                self.key("Enter")
            time.sleep(.5)
        (self.work / f"failure-{self.theme}.ansi").write_text(self.screen())
        raise RuntimeError(f"Never saw {phrase!r}; capture is in {self.work}")

    def key(self, *keys):
        self.tmux("send-keys", "-t", self.target, *keys)
        time.sleep(.6)

    def type(self, text, send=True):
        self.tmux("send-keys", "-t", self.target, "-l", text)
        time.sleep(.7)
        if send:
            self.key("Enter")

    def save(self, label, first):
        raw = self.screen()
        lines = ANSI.sub("", raw).splitlines()
        matches = [i for i, line in enumerate(lines) if first in line]
        if not matches:
            raise RuntimeError(f"Crop marker {first!r} missing for {label}")
        start = matches[-1] if first == "❯" else matches[0]
        stop = len(lines)
        while stop > start and not lines[stop - 1].strip():
            stop -= 1
        filename = f"{self.name}-{len(self.frames) if self.theme == 'light' else self.frame_index}-{self.theme}.ansi"
        (self.work / filename).write_text(raw)
        item = {"file": filename, "crop": [start, stop]}
        if self.theme == "light":
            self.frames.append({"label": label, "captures": {"light": item}})
        else:
            frame = self.frames[self.frame_index]
            if frame["label"] != label:
                raise RuntimeError(f"Theme frame mismatch: {label}")
            frame["captures"]["dark"] = item
        self.frame_index += 1
        print(f"{self.theme}: {label}, rows {start + 1}..{stop}", flush=True)

    def heads_up(self):
        self.wait("Tip: /heads-up on")
        self.save("The intro hint", "❯")
        self.type("/heads-up on")
        self.wait("Heads-up side-check: on for this project")
        self.type("Run date, then ls, then pwd, as three separate shell commands, one per step. Then say ok.")
        self.wait("1: Learn more")
        self.save("The note and its four choices", "✦ Heads up")
        time.sleep(2)
        self.key("1")
        self.wait("1: Tell Claude")
        self.save("Learn more opens the note", "The backfill path never ran")
        time.sleep(2)
        self.key("1")
        self.wait("What do you make of it?")
        self.save("Tell Claude leaves an unsent draft", "❯")

    def council(self):
        self.wait("❯")
        self.type(f'/claude-council:ask --providers={ROSTER} --verbosity=brief --no-auto-context --no-cache '
                  '"Should a single-node demo use SQLite?"')
        self.save("The council command was sent", "/claude-council:ask")
        self.wait("COUNCIL")
        self.key("C-x", "Tab")
        self.key("o")
        self.wait("codex        ")
        self.save("Seats querying", "╭")
        self.wait("retry", seconds=90)
        self.wait("4: retry", seconds=90)
        self.save("A failed seat can be retried while others query", "╭")
        self.wait("FAKE-GROK-RESPONSE", seconds=90)
        self.save("Answers arrive with their banners", "╭")
        self.wait("▾ SYNTHESIS", seconds=180)
        self.wait("4 of 5 answered", seconds=5)
        time.sleep(3)
        self.save("Answers fold around the synthesis", "╭")

    def tmux_pane(self):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            panes = self.tmux("list-panes", "-t", "capture", "-F", "#{pane_id}").stdout.splitlines()
            if len(panes) > 1:
                self.target = panes[-1]
                self.tmux("resize-pane", "-t", self.target, "-Z")
                break
            time.sleep(.2)
        else:
            raise RuntimeError("The renderer did not open a side pane")
        time.sleep(2)
        self.save("Seats querying in tmux", "")
        self.wait("FAKE-GROK-RESPONSE", seconds=90)
        self.save("An answer lands in tmux", "")
        self.wait("[r] retry failed", seconds=100)
        self.save("The retry offer", "")

    def finish(self):
        head = run("git", "rev-parse", "HEAD").stdout.strip()
        data = {
            "title": TITLES[self.name],
            "description": "Real terminal captures with fixture council seats. Each state lasts 2.5 seconds.",
            "provenance": {
                "checkout_head": head,
                "capture_commands": [f"bash assets/capture/{self.name}.sh",
                                     "tmux -L svgcap capture-pane -p -e"],
                "fixture": {
                    "source": "tests/fixtures/fake-clis.bash",
                    "host": None if self.name == "tmux-pane" else "Claude Code --model haiku",
                    "behavior": "heads-up-note" if self.name == "heads-up" else
                    {"codex": "slow 45s", "agy": "slow 65s", "grok": "slow 15s",
                     "kimi": "rate-limit after 12s", "cursor-agent": "valid after 30s"},
                },
                "crop": "Each capture records a half-open range of original terminal rows; all 110 columns remain.",
                "terminal_defaults": THEMES,
                "palette": "RGB and indexed ANSI colors are preserved; default colors are set in tmux.conf.",
            },
            "frames": self.frames,
        }
        manifest = self.work / "manifest.json"
        manifest.write_text(json.dumps(data, indent=2) + "\n")
        render(manifest, ROOT / f"assets/{self.name}.svg")
        for frame in self.frames:
            for item in frame["captures"].values():
                source = self.work / item["file"]
                if source.stat().st_size < 100_000:
                    shutil.copyfile(source, CAPTURE / source.name)
        shutil.copyfile(manifest, CAPTURE / f"{self.name}.json")


if __name__ == "__main__":
    def interrupt(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    parser = argparse.ArgumentParser()
    parser.add_argument("name", choices=TITLES)
    args = parser.parse_args()
    with Capture(args.name) as capture:
        for theme in THEMES:
            capture.frame_index = 0
            capture.start(theme)
            {"heads-up": capture.heads_up, "council-run": capture.council,
             "tmux-pane": capture.tmux_pane}[args.name]()
            capture.stop()
        capture.finish()
