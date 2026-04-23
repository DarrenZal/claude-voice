#!/usr/bin/env bash
# install_macos.sh — Set up claude-voice for macOS (Apple Silicon or Intel)
#
# What this does:
#   1. Creates a venv at ~/.local/share/kokoro-onnx-env/ with kokoro-onnx + deps
#   2. Downloads model files to ~/.local/share/kokoro-onnx-models/
#   3. Installs the LaunchAgent for the TTS daemon (auto-start on login)
#   4. Patches Claude Code settings.json to wire up all hooks
#
# Requirements: Python 3.11+, curl, ~700MB free disk space
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$HOME/.local/share/kokoro-onnx-env"
MODELS_DIR="$HOME/.local/share/kokoro-onnx-models"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/com.claude-voice.tts.plist"
ARBITER_PLIST="$HOME/Library/LaunchAgents/com.claude-voice.arbiter.plist"
VOICE_DATA_DIR="$HOME/.claude/local/voice"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }
step() { echo -e "\n${YELLOW}▶${NC} $*"; }

# ── 1. Python version check ──────────────────────────────────────────────────
step "Checking Python version"
PYTHON=$(command -v python3.11 || command -v python3.12 || command -v python3 || true)
[[ -z "$PYTHON" ]] && fail "Python 3.11+ required. Install via: brew install python@3.11"
PY_VER=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_MAJOR=${PY_VER%%.*}; PY_MINOR=${PY_VER##*.}
[[ $PY_MAJOR -lt 3 || ($PY_MAJOR -eq 3 && $PY_MINOR -lt 11) ]] && \
    fail "Python 3.11+ required (found $PY_VER). Install via: brew install python@3.11"
ok "Python $PY_VER at $PYTHON"

# ── 2. Create kokoro-onnx venv ───────────────────────────────────────────────
step "Creating kokoro-onnx venv at $VENV_DIR"
if [[ -f "$VENV_DIR/bin/python3" ]]; then
    warn "venv already exists — skipping creation (run with --reinstall to force)"
else
    "$PYTHON" -m venv "$VENV_DIR"
    ok "venv created"
fi

PIP="$VENV_DIR/bin/pip"

step "Installing Python packages into venv"
"$PIP" install --quiet --upgrade pip

# onnxruntime-silicon for Apple Silicon (MPS acceleration); falls back gracefully on Intel
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    "$PIP" install --quiet onnxruntime-silicon || \
        { warn "onnxruntime-silicon failed, falling back to onnxruntime (CPU-only)"; \
          "$PIP" install --quiet onnxruntime; }
    ok "onnxruntime-silicon installed (Apple Silicon MPS acceleration)"
else
    "$PIP" install --quiet onnxruntime
    ok "onnxruntime installed (Intel CPU)"
fi

"$PIP" install --quiet \
    "kokoro-onnx>=0.4.0" \
    soundfile \
    scipy \
    numpy \
    pyloudnorm

ok "kokoro-onnx + deps installed"

# ── 3. Download model files ───────────────────────────────────────────────────
step "Downloading Kokoro ONNX model files to $MODELS_DIR"
mkdir -p "$MODELS_DIR"

GH_BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
VOICES_FILE="$MODELS_DIR/voices-v1.0.bin"

# Use fp16 on Apple Silicon (M1/M2/M3 — onnxruntime-silicon leverages ANE/Metal for fp16)
# Use full-precision on Intel (fp16 has no speed benefit on x86 CPU)
if [[ "$(uname -m)" == "arm64" ]]; then
    MODEL_FILE="$MODELS_DIR/kokoro-v1.0.fp16.onnx"
    MODEL_URL="$GH_BASE/kokoro-v1.0.fp16.onnx"
    MODEL_LABEL="kokoro-v1.0.fp16.onnx (~165MB, Apple Silicon optimized)"
else
    MODEL_FILE="$MODELS_DIR/kokoro-v1.0.onnx"
    MODEL_URL="$GH_BASE/kokoro-v1.0.onnx"
    MODEL_LABEL="kokoro-v1.0.onnx (~310MB)"
fi

download_if_missing() {
    local url="$1" dest="$2" label="$3"
    if [[ -f "$dest" ]]; then
        ok "$label already present ($(du -sh "$dest" | cut -f1))"
    else
        echo "  Downloading $label..."
        curl -fL --progress-bar -o "$dest" "$url" || fail "Download failed: $url"
        ok "$label downloaded ($(du -sh "$dest" | cut -f1))"
    fi
}

download_if_missing "$MODEL_URL" "$MODEL_FILE" "$MODEL_LABEL"
download_if_missing "$GH_BASE/voices-v1.0.bin" "$VOICES_FILE" "voices-v1.0.bin (~1MB)"

# ── 4. Quick synthesis smoke test ────────────────────────────────────────────
step "Running synthesis smoke test"
SMOKE_WAV=$(mktemp /tmp/claude-voice-smoke-XXXXX.wav)
"$VENV_DIR/bin/python3" - <<PYEOF
import sys, os
sys.path.insert(0, '$PLUGIN_DIR/lib')

from kokoro_onnx import Kokoro
import soundfile as sf
import numpy as np

kokoro = Kokoro('$MODEL_FILE', '$VOICES_FILE')
samples, sr = kokoro.create("Claude Voice ready.", voice="af_heart", speed=1.0, lang="en-us")
assert len(samples) > 0, "No audio generated"

stereo = np.column_stack([samples, samples])
sf.write('$SMOKE_WAV', stereo.astype(np.float32), sr, subtype='PCM_16')
print(f"OK — {len(samples)} samples at {sr}Hz → {os.path.getsize('$SMOKE_WAV')} bytes")
PYEOF
ok "Synthesis smoke test passed"

# Play the smoke test wav so the user can hear it
afplay "$SMOKE_WAV" &
rm -f "$SMOKE_WAV"

# ── 5. Create voice data dir ──────────────────────────────────────────────────
mkdir -p "$VOICE_DATA_DIR/cache/tts" "$VOICE_DATA_DIR/events"

# ── 6. Install LaunchAgent (TTS daemon) ──────────────────────────────────────
step "Installing TTS daemon LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"

PLIST_SRC="$PLUGIN_DIR/launchd/voice-tts.plist"
if [[ -f "$PLIST_SRC" ]]; then
    # Substitute actual paths into the plist
    sed \
        -e "s|PLUGIN_DIR_PLACEHOLDER|$PLUGIN_DIR|g" \
        -e "s|VENV_DIR_PLACEHOLDER|$VENV_DIR|g" \
        "$PLIST_SRC" > "$LAUNCHD_PLIST"

    # Unload existing agent if present
    launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    launchctl load -w "$LAUNCHD_PLIST"
    ok "LaunchAgent installed + loaded (auto-starts on login)"
else
    warn "launchd/voice-tts.plist not found — skipping daemon auto-start"
    warn "Start the daemon manually: $VENV_DIR/bin/python3 $PLUGIN_DIR/scripts/tts_daemon.py"
fi

# ── 6b. Install LaunchAgent (voice arbiter) ───────────────────────────────────
step "Installing voice arbiter LaunchAgent"

ARBITER_SRC="$PLUGIN_DIR/launchd/voice-arbiter.plist"
if [[ -f "$ARBITER_SRC" ]]; then
    sed \
        -e "s|PLUGIN_DIR_PLACEHOLDER|$PLUGIN_DIR|g" \
        -e "s|VENV_DIR_PLACEHOLDER|$VENV_DIR|g" \
        "$ARBITER_SRC" > "$ARBITER_PLIST"

    launchctl unload "$ARBITER_PLIST" 2>/dev/null || true
    launchctl load -w "$ARBITER_PLIST"
    ok "Arbiter LaunchAgent installed + loaded (serializes TTS across panes)"
else
    warn "launchd/voice-arbiter.plist not found — skipping arbiter auto-start"
    warn "Start manually: $VENV_DIR/bin/python3 $PLUGIN_DIR/scripts/voice_arbiter.py"
fi

# ── 7. Wire Claude Code hooks ──────────────────────────────────────────────────
step "Checking Claude Code settings"
SETTINGS="$HOME/.claude/settings.json"
if [[ ! -f "$SETTINGS" ]]; then
    warn "No ~/.claude/settings.json found — create it or add hooks manually"
    warn "See: $PLUGIN_DIR/CLAUDE.md for hook configuration"
else
    # Check if hooks are already wired
    if grep -q "voice_event.py" "$SETTINGS" 2>/dev/null; then
        ok "Hooks already wired in settings.json"
    else
        warn "Hooks not detected in ~/.claude/settings.json"
        echo "  Add the following to your settings.json hooks section:"
        echo '  "hooks": {'
        echo '    "SessionStart": [{"matcher":"","hooks":[{"type":"command","command":"echo '"'"'{}'"'"' | uv run '"$PLUGIN_DIR/hooks/voice_event.py"' SessionStart"}]}],'
        echo '    "Stop":         [{"matcher":"","hooks":[{"type":"command","command":"cat | uv run '"$PLUGIN_DIR/hooks/voice_event.py"' Stop"}]}]'
        echo '    ... (see CLAUDE.md for full hook list)'
        echo '  }'
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  claude-voice macOS install complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Venv:    $VENV_DIR"
echo "  Models:  $MODELS_DIR"
echo "  Config:  $VOICE_DATA_DIR/config.yaml"
echo ""
echo "  To enable TTS, set in config.yaml:"
echo "    tts:"
echo "      enabled: true"
echo "      voice: af_heart    # or am_onyx, af_sky, af_nicole, etc."
echo ""
echo "  Available voices: af_heart, am_onyx, af_sky, af_nicole, am_michael, bf_emma"
echo ""
echo "  Test earcons: uv run $PLUGIN_DIR/scripts/play_test.py"
echo "  Test TTS:     $VENV_DIR/bin/python3 $PLUGIN_DIR/scripts/tts_test_macos.py"
echo ""
