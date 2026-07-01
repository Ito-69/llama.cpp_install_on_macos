# llama.cpp macOS Installer

A fully automated installer, updater, and manager for [llama.cpp](https://github.com/ggml-org/llama.cpp) on macOS (Apple Silicon & Intel), packaged as a single self-contained menu bar app.

### Why this exists

llama.cpp releases ship as bare tarballs — no installer, no PATH setup, no
Gatekeeper handling, no auto-start, no easy update path. Every new build meant
the same manual ritual: download, extract, copy files, fix macOS security warnings,
update the shell RC, restart the server. **llama-menubar** wraps the entire
process into a single `.app` so you never think about it again.

## Features

- **One-click install** — download the `.app`, double-click, press **Install**
- **Self-contained** — `install-llama.sh` is bundled inside the `.app`; no separate script
- **Automatic architecture detection** — universal binary (arm64 + x86_64)
- **Menu bar control** — start / stop / restart, status icon (green = running)
- **Model downloads** — built-in presets (Qwen2.5 7B, 14B, Llama 3.1 8B, Qwen2.5 32B) via Hugging Face
- **Auto-start at login** — optional LaunchAgent for background server operation
- **App auto-update** — checks GitHub releases; one-click download
- **llama.cpp update** — check / apply from inside the app
- **Gatekeeper handling** — ad-hoc codesign + quarantine removal baked into the build
- **Shell configuration** — automatically sets up `PATH` and `DYLD_LIBRARY_PATH` in your shell RC file
- **One-click uninstall** — removes everything: server, LaunchAgent, binaries, libraries, config, models, shell RC entries, and the app itself

## Quick Start

### Install

1. Download `llama-menubar-2.x.x.zip` from [GitHub Releases](https://github.com/Ito-69/llama.cpp_install_on_macos/releases)
2. Unzip and move `llama-menubar.app` to `/Applications`
3. **Right-click → Open** the first time (because the app is not notarized)
4. Click **Install** in the welcome dialog

The app handles everything: downloads llama.cpp, downloads a model, sets up the LaunchAgent, and starts the server. You'll see a green llama icon in your menu bar when it's running.

### Use

| URL | What it is |
|-----|------------|
| `http://127.0.0.1:8080` | WebUI — chat with the AI agent |
| `http://127.0.0.1:8080/health` | Health check endpoint |
| `http://127.0.0.1:8080/v1` | OpenAI-compatible API |

Quick test via terminal:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

The WebUI supports chat, PDF/image attachments, multiple conversations, JSON schema output, and more — all fully local.

## Menu Bar App

The app lives in your menu bar with a green llama icon (faded = stopped, full = running). Click it to access:

| Menu item | Description |
|-----------|-------------|
| `Open WebUI` | Open `http://127.0.0.1:8080` in your browser (⌘O) |
| `Start Server` / `Stop Server` / `Restart Server` | Control the llama-server LaunchAgent |
| `Check for App Update...` | Check for a newer llama-menubar release on GitHub |
| `Check for llama.cpp Update...` | Check for a newer llama.cpp build |
| `Apply llama.cpp Update...` | Download and install the latest llama.cpp build |
| `Launch at Login` | Toggle auto-start of the menu bar app itself |
| `Uninstall...` | Remove everything (with option to keep models) |
| `About llama-menubar` | Show version and GitHub link |
| `Quit` | Exit the menu bar app (⌘Q) |

The status icon polls every 5 seconds.

## Build from Source

```bash
# Build the universal .app
cd llama-menubar
./build.sh

# Copy to /Applications
cp -r llama-menubar.app /Applications/

# Open
open /Applications/llama-menubar.app
```

Build outputs:
- `llama-menubar.app` — universal binary (arm64 + x86_64), ad-hoc codesigned
- macOS 13+ required

## Files & Directories

| Path | Purpose |
|------|---------|
| `~/.local/bin/` | llama.cpp binaries (`llama-server`, `llama-cli`, …) |
| `~/.local/lib/` | Shared libraries (`libllama*.dylib`, `libggml*.dylib`) |
| `~/models/` | GGUF model files |
| `~/.config/llama/server.conf` | Server configuration |
| `~/Library/Application Support/llama-menubar/` | App support (bundled script) |
| `~/Library/LaunchAgents/com.llama.cpp.server.plist` | LaunchAgent (auto-start server) |
| `~/Library/Logs/llama-server.log` | Server stdout (background mode) |
| `~/Library/Logs/llama-server.err.log` | Server stderr (background mode) |

## Uninstallation

Click **Uninstall...** in the menu bar app. Choose:

- **Remove Everything** — server, LaunchAgent, binaries, libraries, config, app support, shell RC entries, and downloaded models
- **Keep Models** — same as above but keeps `~/models/*.gguf`
- **Cancel** — do nothing

The app removes itself from `/Applications` after quitting.

## Requirements

- macOS 13+ (Ventura or newer)
- Xcode Command Line Tools: `xcode-select --install`
- Internet connection (for initial download + model fetch)

The app installs its own `huggingface_hub` Python package on first run.

## License

MIT — feel free to use, modify, and share.

---

*Inspired by the [llama.cpp](https://github.com/ggml-org/llama.cpp) project by ggerganov.*
