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


def current_mode() -> str:
    try:
        return MODE_STATE.read_text().strip()
    except Exception:
        return "ambient"


def get_target_pane() -> str | None:
    # Prefer the pane tracked by the SessionStart hook
    if ACTIVE_PANE.exists():
        try:
            pane = ACTIVE_PANE.read_text().strip()
            if pane:
                return pane
        except Exception:
            pass
    # Fall back to whatever tmux pane is currently focused
    try:
        r = subprocess.run(
            ["tmux", "display-message", "-p", "#{pane_id}"],
            capture_output=True, text=True, timeout=2,
        )
        pane = r.stdout.strip()
        return pane or None
    except Exception:
        return None


def inject(text: str) -> bool:
    pane = get_target_pane()
    if not pane:
        log(f"no active tmux pane — dropping: {text!r}")
        return False
    try:
        keys = [text, "Enter"] if AUTOSUBMIT else [text]
        subprocess.run(
            ["tmux", "send-keys", "-t", pane] + keys,
            timeout=3, check=True,
        )
        suffix = " + Enter" if AUTOSUBMIT else ""
        log(f"→ pane {pane}{suffix}: {text!r}")
        return True
    except Exception as e:
        log(f"inject failed: {e}")
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

        inject(transcript)

    code = proc.wait()
    log(f"stt_listen exited with code {code}")
    STT_ACTIVE_PATH.unlink(missing_ok=True)
    sys.exit(max(code, 0))


if __name__ == "__main__":
    main()
