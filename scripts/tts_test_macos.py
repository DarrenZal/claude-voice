#!/usr/bin/env python3
"""Quick macOS TTS smoke test — verifies kokoro-onnx synthesis + afplay playback.

Run from the plugin root:
    ~/.local/share/kokoro-onnx-env/bin/python3 scripts/tts_test_macos.py
    ~/.local/share/kokoro-onnx-env/bin/python3 scripts/tts_test_macos.py --voice am_onyx
    ~/.local/share/kokoro-onnx-env/bin/python3 scripts/tts_test_macos.py --list-voices
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PLUGIN_ROOT / "lib"))

MODELS_DIR = Path("~/.local/share/kokoro-onnx-models").expanduser()

def _find_model() -> Path:
    for name in ("kokoro-v1.0.fp16.onnx", "kokoro-v1.0.onnx", "kokoro-v1.0.int8.onnx"):
        p = MODELS_DIR / name
        if p.exists():
            return p
    return MODELS_DIR / "kokoro-v1.0.onnx"  # missing — caller will error clearly

VOICE_SAMPLES = {
    "af_heart":   "Hello. This is the af_heart voice. Claude Voice is ready on macOS.",
    "am_onyx":    "Hello. This is am_onyx. Claude Voice is operational.",
    "af_sky":     "Hello. This is af_sky. Your agent is listening.",
    "af_nicole":  "Hello. This is af_nicole. Ready to assist.",
    "am_michael": "Hello. This is am_michael. Standing by.",
    "bf_emma":    "Hello. This is bf_emma. Claude Voice initialized.",
}


def list_voices() -> None:
    print("Available voices:")
    for v, sample in VOICE_SAMPLES.items():
        print(f"  {v:<14} — {sample[:50]}...")


def test_voice(voice: str, text: str | None = None) -> None:
    model_file = _find_model()
    voices_file = MODELS_DIR / "voices-v1.0.bin"

    if not model_file.exists():
        print(f"ERROR: No model found in {MODELS_DIR}")
        print("Run scripts/install_macos.sh first.")
        sys.exit(1)

    speak_text = text or VOICE_SAMPLES.get(voice, f"Hello from {voice}.")

    print(f"Voice:   {voice}")
    print(f"Text:    {speak_text[:80]}{'...' if len(speak_text) > 80 else ''}")
    print(f"Model:   {model_file.name}")
    print(f"Models:  {MODELS_DIR}")
    print()

    try:
        from kokoro_onnx import Kokoro
    except ImportError:
        print("ERROR: kokoro-onnx not installed. Run: pip install kokoro-onnx")
        sys.exit(1)

    print("Loading model...", end=" ", flush=True)
    t0 = time.monotonic()
    kokoro = Kokoro(str(model_file), str(voices_file))
    load_ms = int((time.monotonic() - t0) * 1000)
    print(f"done ({load_ms}ms)")

    print("Synthesizing...", end=" ", flush=True)
    t1 = time.monotonic()
    samples, sr = kokoro.create(speak_text, voice=voice, speed=1.0, lang="en-us")
    synth_ms = int((time.monotonic() - t1) * 1000)
    print(f"done ({synth_ms}ms, {len(samples)} samples @ {sr}Hz)")

    # Write to temp file and play via afplay
    import tempfile
    import subprocess
    import numpy as np
    import soundfile as sf

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmp_path = f.name

    stereo = np.column_stack([samples, samples]).astype(np.float32)
    sf.write(tmp_path, stereo, sr, subtype="PCM_16")

    print("Playing...", end=" ", flush=True)
    result = subprocess.run(["afplay", tmp_path], capture_output=True)
    Path(tmp_path).unlink(missing_ok=True)

    if result.returncode == 0:
        print("done")
        print(f"\n✓ Total: {int((time.monotonic() - t0) * 1000)}ms (load+synth+play)")
    else:
        print(f"FAILED (afplay exit {result.returncode})")
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description="macOS TTS smoke test")
    parser.add_argument("--voice", default="af_heart", help="Kokoro voice to test")
    parser.add_argument("--text", help="Custom text to synthesize")
    parser.add_argument("--list-voices", action="store_true", help="List available voices")
    parser.add_argument("--all-voices", action="store_true", help="Test all voices")
    args = parser.parse_args()

    if args.list_voices:
        list_voices()
        return

    if args.all_voices:
        for voice in VOICE_SAMPLES:
            print(f"\n{'─'*50}")
            test_voice(voice)
        return

    test_voice(args.voice, args.text)


if __name__ == "__main__":
    main()
