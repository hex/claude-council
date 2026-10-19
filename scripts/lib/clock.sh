#!/bin/bash
# ABOUTME: Millisecond clock shared by the scripts that time a seat or a run
# ABOUTME: Whole seconds scaled to ms without python3, so elapsed-time math stays unit-correct

now_ms() {
    python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo $(( $(date +%s) * 1000 ))
}
