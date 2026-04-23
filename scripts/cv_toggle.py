#!/usr/bin/env python3
"""cv-on / cv-off — toggle all claude-voice audio + STT.

Usage:
    cv_toggle.py on   → unmute earcons + TTS, resume STT
    cv_toggle.py off  → mute earcons + TTS, pause STT
"""
import re
import subprocess
import sys
from pathlib import Path

CONFIG = Path("~/.claude/local/voice/config.yaml").expanduser()


def set_mute(muted: bool) -> None:
    text = CONFIG.read_text()
    text = re.sub(r"^mute:.*$", f"mute: {'true' if muted else 'false'}", text, flags=re.MULTILINE)
    CONFIG.write_text(text)


def launchctl(verb: str, service: str) -> None:
    subprocess.run(["launchctl", verb, service], capture_output=True)


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in ("on", "off"):
        print(f"usage: {sys.argv[0]} on|off", file=sys.stderr)
        sys.exit(1)

    turning_on = sys.argv[1] == "on"

    set_mute(not turning_on)

    if turning_on:
        launchctl("start", "com.claude-voice.stt")
        print("claude-voice: ON  (earcons + TTS + STT)")
    else:
        launchctl("stop", "com.claude-voice.stt")
        print("claude-voice: OFF (earcons + TTS + STT paused)")


if __name__ == "__main__":
    main()
