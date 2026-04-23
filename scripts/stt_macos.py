#!/usr/bin/env python3
"""
macOS STT daemon for claude-voice.

Runs stt_listen (Swift, SFSpeechRecognizer) as a subprocess and injects
finalized transcripts into the active Claude Code tmux pane.

Behaviour:
  - Always-on listening while daemon runs
  - Drops transcripts when arbiter is in 'silent' mode (call in progress)
  - Auto-submits with Enter (speak → Claude receives it immediately)
  - Set STT_AUTOSUBMIT=0 env var to type-only (no Enter)
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

VOICE_DIR       = Path("~/.claude/local/voice").expanduser()
MODE_STATE      = VOICE_DIR / "mode-state"
ACTIVE_PANE     = VOICE_DIR / "active-pane"   # written by SessionStart hook (optional)
STT_ACTIVE_PATH = VOICE_DIR / "stt-active"    # flag: STT is currently capturing

_THIS_DIR  = Path(__file__).resolve().parent
STT_LISTEN = _THIS_DIR / "helpers" / "stt_listen"

AUTOSUBMIT = os.environ.get("STT_AUTOSUBMIT", "1") != "0"


# ── Helpers ───────────────────────────────────────────────────────────────────

def log(msg: str) -> None:
    print(f"stt_macos: {msg}", flush=True)


SPEAKING_NOW = VOICE_DIR / "speaking-now.json"


def current_mode() -> str:
    try:
        return MODE_STATE.read_text().strip()
    except Exception:
        return "ambient"


def tts_is_speaking() -> bool:
    """Return True if the arbiter is currently playing TTS audio."""
    try:
        state = json.loads(SPEAKING_NOW.read_text())
        return state.get("speaking_pane") is not None
    except Exception:
        return False


def inject_osascript(text: str) -> bool:
    """Type text into the frontmost app using System Events (works without tmux)."""
    # Escape backslashes and double-quotes for AppleScript string literal
    safe = text.replace("\\", "\\\\").replace('"', '\\"')
    enter = "\n    keystroke return" if AUTOSUBMIT else ""
    script = f'tell application "System Events"\n    keystroke "{safe}"{enter}\nend tell'
    try:
        subprocess.run(["osascript", "-e", script], timeout=5, check=True)
        return True
    except Exception as e:
        log(f"osascript inject failed: {e}")
        return False


def inject_tmux(text: str) -> bool:
    """Inject via tmux send-keys (used when Claude Code is running inside tmux)."""
    # Check tracked pane first, then active pane
    pane = None
    if ACTIVE_PANE.exists():
        try:
            pane = ACTIVE_PANE.read_text().strip() or None
        except Exception:
            pass
    if not pane:
        try:
            r = subprocess.run(
                ["tmux", "display-message", "-p", "#{pane_id}"],
                capture_output=True, text=True, timeout=2,
            )
            pane = r.stdout.strip() or None
        except Exception:
            pass
    if not pane:
        return False
    try:
        keys = [text, "Enter"] if AUTOSUBMIT else [text]
        subprocess.run(["tmux", "send-keys", "-t", pane] + keys, timeout=3, check=True)
        return True
    except Exception:
        return False


def inject(text: str) -> bool:
    # Try tmux first (lower latency), fall back to osascript
    if inject_tmux(text):
        log(f"→ tmux{' + Enter' if AUTOSUBMIT else ''}: {text!r}")
        return True
    if inject_osascript(text):
        log(f"→ osascript{' + Enter' if AUTOSUBMIT else ''}: {text!r}")
        return True
    log(f"inject failed — dropped: {text!r}")
    return False


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    if not STT_LISTEN.exists():
        log(f"ERROR — stt_listen binary not found at {STT_LISTEN}")
        log("Run install_macos.sh to compile it.")
        sys.exit(1)

    log(f"starting stt_listen (autosubmit={'on' if AUTOSUBMIT else 'off'})")
    STT_ACTIVE_PATH.parent.mkdir(parents=True, exist_ok=True)

    proc = subprocess.Popen(
        [str(STT_LISTEN)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    def _relay_stderr() -> None:
        for line in proc.stderr:
            print(f"stt_listen: {line.rstrip()}", flush=True)

    threading.Thread(target=_relay_stderr, daemon=True).start()

    log("listening — speak to inject into Claude Code")

    for raw in proc.stdout:
        transcript = raw.strip()
        if not transcript:
            continue

        mode = current_mode()
        if mode == "silent":
            log(f"silent mode — dropped: {transcript!r}")
            continue

        if tts_is_speaking():
            log(f"TTS active — dropped (feedback guard): {transcript!r}")
            continue

        inject(transcript)

    code = proc.wait()
    log(f"stt_listen exited with code {code}")
    STT_ACTIVE_PATH.unlink(missing_ok=True)
    sys.exit(max(code, 0))


if __name__ == "__main__":
    main()
