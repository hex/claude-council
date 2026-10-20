#!/usr/bin/env python3
# ABOUTME: Launches a real subscription seat at most once per capture theme.
# ABOUTME: Passes arguments unchanged and rejects accidental retries before another call.

import os
import sys
from pathlib import Path


binary = Path(sys.argv[0]).name
executable = os.environ[f"COUNCIL_CAPTURE_EXECUTABLE_{binary.replace('-', '_')}"]
if sys.argv[1:] != ["--version"]:
    marker = Path(os.environ["COUNCIL_CAPTURE_CALLS"]) / f"{os.environ['COUNCIL_CAPTURE_THEME']}-{binary}"
    try:
        descriptor = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        sys.exit(f"Capture refused a second real {binary} invocation in this theme")
    os.close(descriptor)
os.execv(executable, [executable, *sys.argv[1:]])
