# llama.cpp macOS Installer

A fully automated installer, updater, and manager for [llama.cpp](https://github.com/ggml-org/llama.cpp) on macOS (Apple Silicon & Intel).

### Why this exists

llama.cpp releases ship as bare tarballs — no installer, no PATH setup, no
Gatekeeper handling, no auto-start, no easy update path. Every new build meant
the same manual ritual: download, extract, copy files, fix macOS security warnings,
update the shell RC, restart the server. This script wraps the entire process
into a single command so you never think about it again.

## Features

- **One-command setup** — auto-downloads the latest build from GitHub, no manual download needed
- **Automatic architecture detection** — picks the right binaries for your CPU (arm64 / x86_64)
- **Model downloads** — built-in presets (Qwen2.5 7B, 14B, Llama 3.1 8B, Qwen2.5 32B) via Hugging Face
- **Auto-start at login** — optional LaunchAgent for background server operation
- **Effortless updates** — `--check-update`, `--download-update`, `--upgrade` from GitHub releases
- **Gatekeeper handling** — removes quarantine flags and ad-hoc codesigns to avoid macOS warnings
- **Shell configuration** — automatically sets up `PATH` and `DYLD_LIBRARY_PATH` in your shell RC file
- **LAN access** — prints local network URL for accessing the API from other devices

## Quick Start

### Prerequisites

- macOS (Apple Silicon or Intel)
- `hf` (or legacy `huggingface-cli`) for model downloads: `pip3 install huggingface_hub` (or use conda)
- Xcode Command Line Tools: `xcode-select --install`

### Run the installer

```bash
chmod +x install-llama.sh
./install-llama.sh
```

The script automatically downloads the latest macOS build from GitHub — no manual download needed. Optionally, you can also place a pre-downloaded release archive from the [llama.cpp releases page](https://github.com/ggml-org/llama.cpp/releases) in the same directory:
- **Apple Silicon (M1–M4)**: `llama-bXXXX-bin-macos-arm64.tar.gz`
- **Intel Mac**: `llama-bXXXX-bin-macos-x64.tar.gz`

The script will:
1. Auto-download (or find locally) and extract the llama bundle
2. Verify architecture compatibility
3. Copy binaries to `~/.local/bin/` and libraries to `~/.local/lib/`
4. Fix Gatekeeper (quarantine + ad-hoc codesign)
5. Configure your shell RC file
6. Download the default model (Qwen2.5 7B Q4_K_M, ~4.7 GB)
7. Start `llama-server` in background with built-in WebUI on port 8080

### How to use

Once installed and running, open the **built-in WebUI** in your browser for a full chat interface:

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

## Usage Reference

### Installation

| Command | Description |
|---------|-------------|
| `./install-llama.sh` | Full install: llama.cpp + model + start server |
| `./install-llama.sh --model qwen7` | Install with a smaller/faster model |
| `./install-llama.sh --choose-model` | Interactive model menu |
| `./install-llama.sh --install-only` | llama.cpp only (no model, no server) |
| `./install-llama.sh --model qwen14 --install-agent --skip-server` | Install + LaunchAgent (headless server) |

### Status & Info

| Command | Description |
|---------|-------------|
| `./install-llama.sh --status` | Version, model, server status, port, LAN URL, LaunchAgent, GitHub check |
| `./install-llama.sh --status --no-github-check` | Status without internet request |
| `./install-llama.sh --check-update` | Check for newer build on GitHub |
| `./install-llama.sh --list-models` | List available model presets |
| `./install-llama.sh --help` | Short help text |

### Models

| Command | Description |
|---------|-------------|
| `--model qwen7` | Qwen2.5 7B Q4_K_M (~4.7 GB) — faster (default) |
| `--model qwen14` | Qwen2.5 14B Q4_K_M (~8.4 GB) — balanced |
| `--model llama8` | Llama 3.1 8B Q4_K_M (~5 GB) |
| `--model qwen32` | Qwen2.5 32B Q4_K_M (~19 GB) — best quality (24 GB+ RAM) |
| `--model-repo REPO --model-file FILE` | Custom Hugging Face repo and GGUF file |

Configuration is saved to `~/.config/llama/server.conf`.

### Updates

| Command | Description |
|---------|-------------|
| `./install-llama.sh --check-update` | Check for a newer build |
| `./install-llama.sh --download-update` | Download latest macOS build to current directory |
| `./install-llama.sh --update` | Install the newest local bundle (keeps model untouched) |
| `./install-llama.sh --upgrade` | **All-in-one:** download + update + restore LaunchAgent |

### Menu Bar App (llama-menubar)

A companion **menu bar app** for managing llama-server without touching the terminal.
Shows the server status via the llama-cpp icon (green = running, faded = stopped) and
provides start/stop/restart, WebUI launcher, log viewer, and built-in update checks.

**Download:** grab `llama-menubar-1.0.0.zip` from
[GitHub Releases](https://github.com/Ito-69/llama.cpp_install_on_macos/releases/tag/v1.0.0),
extract, and drag `llama-menubar.app` to `/Applications`.

```bash
# Or build it yourself from source:
cd llama-menubar
./build.sh
cp -r llama-menubar.app /Applications/
```

Open the app from `/Applications` — it appears in the menu bar.

| Feature | Details |
|---------|---------|
| **Size** | 92 KB binary, 108 KB zip |
| **Arch** | Native arm64, Swift + AppKit |
| **Icon** | [selfhst/icons](https://cdn.jsdelivr.net/gh/selfhst/icons/svg/llama-cpp.svg) llama-cpp logo |
| **Status** | Green = running, faded = stopped (polls every 5s) |
| **Controls** | Start / Stop / Restart via LaunchAgent |
| **Update** | Check for Update / Apply Update (runs `install-llama.sh --check-update` / `--upgrade`) |
| **Script discovery** | Looks in app bundle → `~/Documents/llama.cpp-macos-installer/` → `~/.config/llama/` → file picker |

#### Changelog (v1.0.0)

- **Auto-download** — installer fetches the latest llama.cpp build from GitHub if no local bundle is found
- **`hf` CLI support** — uses `hf` (huggingface_hub v1.x) first, falls back to legacy `huggingface-cli`
- **macOS `pip3`** — all pip commands use `pip3` (macOS standard)
- **`--local-dir-use-symlinks`** skipped for `hf` CLI (not supported in v1.x)
- **`hf` search path** — also checks `python3 -m site --user-base` (macOS user bin dir)
- **Default model** changed from 14B to **Qwen2.5 7B Q4_K_M** (~4.7 GB, faster for most users)
- **Non-blocking server** — uses `nohup` + `&` + `disown` so the terminal is freed after install
- **WebUI URL** shown in status and test instructions
- **Uninstall docs** — `--uninstall-agent` and cleanup paths printed after install

**Recommended update workflow (with LaunchAgent):**

```bash
./install-llama.sh --check-update
./install-llama.sh --download-update
./install-llama.sh --update --skip-server --install-agent
```

**Or a single command:**

```bash
./install-llama.sh --upgrade
```

### LaunchAgent (auto-start)

| Command | Description |
|---------|-------------|
| `./install-llama.sh --install-agent` | Install/reload LaunchAgent; server runs in background |
| `./install-llama.sh --uninstall-agent` | Stop and remove LaunchAgent |

**Recommended setup with the menu bar app:**

```bash
# 1. Install llama.cpp + LaunchAgent (headless)
./install-llama.sh --install-agent

# 2. Open the menu bar app to control the server
open /Applications/llama-menubar.app
```

**LaunchAgent files:**

| File | Description |
|------|-------------|
| `~/Library/LaunchAgents/com.llama.cpp.server.plist` | LaunchAgent config |
| `~/.local/bin/llama-server-start.sh` | Start script (do not delete manually) |
| `~/Library/Logs/llama-server.log` | Standard output |
| `~/Library/Logs/llama-server.err.log` | Error log |

### Server Options

| Option | Default | Description |
|--------|---------|-------------|
| `--port 8080` | `8080` | HTTP port |
| `--context 8192` | `8192` | Context size (tokens) |
| `--host` | `0.0.0.0` | `0.0.0.0` = local network; `127.0.0.1` = this Mac only |

Saved to `~/.config/llama/server.conf`.

### Common Scenarios

```bash
# Daily check
./install-llama.sh --status

# Open WebUI in browser
open http://127.0.0.1:8080

# First-time headless server setup
./install-llama.sh --model qwen14 --install-agent --skip-server

# Update llama.cpp to the latest build
./install-llama.sh --upgrade

# Reinstall current build (archive already in directory)
./install-llama.sh --update --skip-server --install-agent

# Switch to a different model
./install-llama.sh --model qwen7

# Stop and remove LaunchAgent
./install-llama.sh --uninstall-agent
pkill -9 llama-server
```

## Manual Commands

```bash
source ~/.zshrc

# Open the WebUI in your browser
open http://127.0.0.1:8080

# Check server health
curl http://127.0.0.1:8080/health

# Who's using port 8080
lsof -i :8080

# Kill all llama-server processes
pkill -9 llama-server

# Start server manually in terminal
llama-server -m ~/models/Qwen2.5-7B-Instruct-Q4_K_M.gguf \
  -c 8192 --port 8080 --host 0.0.0.0

# Follow LaunchAgent logs
tail -f ~/Library/Logs/llama-server.log
tail -f ~/Library/Logs/llama-server.err.log
```

## Files & Directories

| Path | Purpose |
|------|---------|
| `~/.local/bin/` | llama.cpp binaries (`llama-server`, `llama-cli`, …) |
| `~/.local/lib/` | Shared libraries (`libllama*.dylib`, `libggml*.dylib`) |
| `~/.local/bin/llama-server-start.sh` | LaunchAgent start script |
| `~/models/` | GGUF model files |
| `~/.config/llama/server.conf` | Server configuration |
| `~/Library/LaunchAgents/com.llama.cpp.server.plist` | LaunchAgent (if installed) |
| `~/Library/Logs/llama-server.log` | Server stdout (background mode) |
| `~/Library/Logs/llama-server.err.log` | Server stderr (background mode) |

## Uninstallation

To fully remove llama.cpp, run these commands in order:

```bash
# 1. Stop and remove LaunchAgent (if installed)
./install-llama.sh --uninstall-agent

# 2. Remove binaries and start script
rm -rf ~/.local/bin/llama-* ~/.local/bin/rpc-server
rm -f ~/.local/bin/llama-server-start.sh

# 3. Remove shared libraries
rm -f ~/.local/lib/libggml*.dylib ~/.local/lib/libllama*.dylib ~/.local/lib/libmtmd*.dylib

# 4. Remove configuration
rm -rf ~/.config/llama

# 5. Remove model files (optional — keeps ~4–8 GB)
rm -rf ~/models/*.gguf

# 6. Remove shell RC additions
# Edit ~/.zshrc (or ~/.bash_profile) and delete the
# "# llama.cpp (install-llama.sh)" section
```

## Requirements

- macOS 12+ (Monterey or newer)
- Bash 3.2+ (macOS ships with 3.2, fully compatible)
- `curl`, `unzip`, `codesign` (all present on macOS by default or via Xcode CLT)
- `hf` (or legacy `huggingface-cli`) for model downloads (`pip3 install huggingface_hub`)

## License

MIT — feel free to use, modify, and share.

---

*Inspired by the [llama.cpp](https://github.com/ggml-org/llama.cpp) project by ggerganov.*
