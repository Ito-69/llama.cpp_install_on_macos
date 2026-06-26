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
- **Model downloads** — built-in presets (Qwen2.5 14B, 7B, Llama 3.1 8B, Qwen2.5 32B) via Hugging Face
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
6. Download the default model (Qwen2.5 14B Q4_K_M, ~8.4 GB)
7. Start `llama-server` with an OpenAI-compatible API on port 8080

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
| `--model qwen14` | Qwen2.5 14B Q4_K_M (~8.4 GB) — balanced (default) |
| `--model qwen7` | Qwen2.5 7B Q4_K_M (~4.7 GB) — faster |
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

# Check server health
curl http://127.0.0.1:8080/health

# Who's using port 8080
lsof -i :8080

# Kill all llama-server processes
pkill -9 llama-server

# Start server manually in terminal
llama-server -m ~/models/Qwen2.5-14B-Instruct-Q4_K_M.gguf \
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
| `~/models/` | GGUF model files |
| `~/.config/llama/server.conf` | Server configuration |
| `~/Library/LaunchAgents/com.llama.cpp.server.plist` | LaunchAgent (if installed) |
| `~/Library/Logs/llama-server.log` | Server stdout |
| `~/Library/Logs/llama-server.err.log` | Server stderr |

## Uninstallation

To fully remove llama.cpp:

```bash
# Stop and remove LaunchAgent
./install-llama.sh --uninstall-agent

# Remove binaries and libraries
rm -rf ~/.local/bin/llama-* ~/.local/bin/rpc-server
rm -f ~/.local/bin/llama-server-start.sh
rm -rf ~/.local/lib/libggml*.dylib ~/.local/lib/libllama*.dylib ~/.local/lib/libmtmd*.dylib

# Remove configuration
rm -rf ~/.config/llama

# Remove models (optional)
rm -rf ~/models/*.gguf

# Remove shell RC additions
# Edit ~/.zshrc (or ~/.bash_profile) and remove the llama.cpp sections
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
