#!/usr/bin/env python3
"""
Watches the microphone state and auto-switches the voice arbiter mode.

When mic is captured by another app (call detected):
  → switches arbiter to 'silent'

When mic is released (call ended, after debounce):
  → restores the mode that was active before the call

Runs as a LaunchAgent alongside the TTS daemon and arbiter.
"""
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

POLL_INTERVAL   = 1.0   # seconds between mic checks
RELEASE_DEBOUNCE = 5.0  # seconds to wait after mic released before restoring
                         # (handles brief mic drops mid-call without false restores)

VOICE_DIR    = Path("~/.claude/local/voice").expanduser()
ARBITER_SOCK = VOICE_DIR / "arbiter.sock"
MODE_STATE   = VOICE_DIR / "mode-state"

_THIS_DIR = Path(__file__).resolve().parent
MIC_CHECK  = _THIS_DIR / "helpers" / "mic_check"


# ── Mic detection ─────────────────────────────────────────────────────────────

def is_mic_in_use() -> bool:
    if not MIC_CHECK.exists():
        return False
    try:
        r = subprocess.run([str(MIC_CHECK)], capture_output=True, timeout=2)
        return r.returncode == 1
    except Exception:
        return False


# ── Arbiter communication ─────────────────────────────────────────────────────

def send_mode(mode: str) -> bool:
    if not ARBITER_SOCK.exists():
        return False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(3)
            s.connect(str(ARBITER_SOCK))
            s.sendall((json.dumps({"type": "mode", "mode": mode}) + "\n").encode())
            s.recv(256)  # drain ack
        return True
    except Exception:
        return False


def current_mode() -> str:
    try:
        return MODE_STATE.read_text().strip() or "ambient"
    except Exception:
        return "ambient"


# ── Main loop ─────────────────────────────────────────────────────────────────

def main() -> None:
    print(f"mic_watcher: starting (poll={POLL_INTERVAL}s debounce={RELEASE_DEBOUNCE}s)",
          flush=True)

    if not MIC_CHECK.exists():
        print(f"mic_watcher: ERROR — mic_check binary not found at {MIC_CHECK}", flush=True)
        print("mic_watcher: run install_macos.sh to compile it", flush=True)
        sys.exit(1)

    in_call        = False
    pre_call_mode  = "ambient"
    release_at     = 0.0  # epoch time when debounce expires

    while True:
        mic_active = is_mic_in_use()
        now        = time.monotonic()

        if mic_active:
            release_at = 0.0  # reset any pending release

            if not in_call:
                pre_call_mode = current_mode()
                if pre_call_mode != "silent":
                    if send_mode("silent"):
                        print(f"mic_watcher: call detected → silent (was: {pre_call_mode})",
                              flush=True)
                in_call = True

        else:  # mic free
            if in_call:
                if release_at == 0.0:
                    # first tick after mic released — start debounce
                    release_at = now + RELEASE_DEBOUNCE
                elif now >= release_at:
                    # debounce expired — call is genuinely over
                    if send_mode(pre_call_mode):
                        print(f"mic_watcher: call ended → {pre_call_mode}", flush=True)
                    in_call    = False
                    release_at = 0.0

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
