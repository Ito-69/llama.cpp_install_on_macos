#!/usr/bin/env bash
#
# install-llama.sh — Fully automatic llama.cpp installer for macOS
#
# Created because llama.cpp releases don't include an installer —
# every update requires manually downloading, extracting, copying
# binaries, fixing Gatekeeper, and reconfiguring the shell.
# This script automates the entire workflow.
#
# The script auto-downloads the latest macOS build from GitHub if no bundle
# is found locally. You can also place a release archive (llama-bXXXX.zip
# / .tar.gz) or an extracted llama-bXXXX folder manually, then:
#
#   chmod +x install-llama.sh
#   ./install-llama.sh
#
# Works on macOS with zsh/bash. Detects shell and architecture automatically.
# Apple Silicon (M1–M4): requires arm64 archive. Intel Mac: requires x86_64.
#
# Options:
#   --status            show status (+ check GitHub for newer builds)
#   --check-update      only check for a newer build on GitHub
#   --download-update   download the latest macOS build from GitHub
#   --upgrade           = --download-update + --update --skip-server [--install-agent]
#   --no-github-check   skip GitHub check in --status
#   --list-models       list available model presets
#   --choose-model      interactive model selection
#   --model PRESET      qwen14 | qwen7 | llama8 | qwen32
#   --update            update from a new archive (no model download)
#   --install-agent     install LaunchAgent (auto-start at login)
#   --uninstall-agent   remove LaunchAgent
#   --skip-download     skip model download
#   --skip-server       don't start llama-server at the end
#   --install-only      = --skip-download --skip-server
#   --port 8080         HTTP port (default: 8080)
#   --context 8192      context size (default: 8192)
#   --model-repo REPO   Hugging Face repo (manual override)
#   --model-file FILE   GGUF filename (manual override)
#   -h, --help          show this help
#
# Updating to a new release:
#   ./install-llama.sh --check-update          # check for newer build
#   ./install-llama.sh --download-update       # download + install
#   or manually: grab llama-bXXXX from https://github.com/ggml-org/llama.cpp/releases
#

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

info()  { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ── Default configuration ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BIN="${HOME}/.local/bin"
LOCAL_LIB="${HOME}/.local/lib"
MODELS_DIR="${HOME}/models"
CONFIG_DIR="${HOME}/.config/llama"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
LAUNCH_AGENT_LABEL="com.llama.cpp.server"
LAUNCH_AGENT_PLIST="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
START_SCRIPT="${HOME}/.local/bin/llama-server-start.sh"
LOG_OUT="${HOME}/Library/Logs/llama-server.log"
LOG_ERR="${HOME}/Library/Logs/llama-server.err.log"
SHELL_RCS=()

PORT=8080
CONTEXT=8192
HOST="0.0.0.0"
MODE_UPDATE=0
MODE_STATUS=0
MODE_CHECK_UPDATE=0
MODE_DOWNLOAD_UPDATE=0
MODE_UPGRADE=0
SKIP_GITHUB_CHECK=0
MODE_CHOOSE_MODEL=0
MODE_LIST_MODELS=0
GITHUB_REPO="ggml-org/llama.cpp"
GITHUB_API="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
SKIP_DOWNLOAD=0
SKIP_SERVER=0
INSTALL_AGENT=0
UNINSTALL_AGENT=0
RUN_MAIN=1
MODEL_PRESET=""

MODEL_REPO="bartowski/Qwen2.5-7B-Instruct-GGUF"
MODEL_FILE="Qwen2.5-7B-Instruct-Q4_K_M.gguf"
MODEL_PATH="${MODELS_DIR}/${MODEL_FILE}"
MODEL_LABEL="Qwen2.5 7B Q4_K_M (~4.7 GB)"

# ── Argument parsing ───────────────────────────────────────────────────────────
usage() {
  sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)         MODE_STATUS=1; RUN_MAIN=0 ;;
    --check-update)   MODE_CHECK_UPDATE=1; RUN_MAIN=0 ;;
    --download-update) MODE_DOWNLOAD_UPDATE=1; RUN_MAIN=0 ;;
    --upgrade)         MODE_UPGRADE=1; RUN_MAIN=0 ;;
    --no-github-check) SKIP_GITHUB_CHECK=1 ;;
    --list-models)    MODE_LIST_MODELS=1; RUN_MAIN=0 ;;
    --choose-model)   MODE_CHOOSE_MODEL=1 ;;
    --model)          MODEL_PRESET="$2"; shift ;;
    --update)         MODE_UPDATE=1; SKIP_DOWNLOAD=1 ;;
    --install-agent)  INSTALL_AGENT=1 ;;
    --uninstall-agent) UNINSTALL_AGENT=1; RUN_MAIN=0 ;;
    --skip-download)  SKIP_DOWNLOAD=1 ;;
    --skip-server)    SKIP_SERVER=1 ;;
    --install-only)   SKIP_DOWNLOAD=1; SKIP_SERVER=1 ;;
    --port)           PORT="$2"; shift ;;
    --context)        CONTEXT="$2"; shift ;;
    --model-repo)     MODEL_REPO="$2"; shift ;;
    --model-file)     MODEL_FILE="$2"; MODEL_PATH="${MODELS_DIR}/${MODEL_FILE}"; shift ;;
    -h|--help)        usage ;;
    *)                die "Unknown argument: $1 (use --help)" ;;
  esac
  shift
done

# ── System checks ──────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS only."

command -v unzip >/dev/null 2>&1 || die "Missing 'unzip'. Install Xcode Command Line Tools: xcode-select --install"
command -v codesign >/dev/null 2>&1 || die "Missing 'codesign'."
command -v curl >/dev/null 2>&1 || die "Missing 'curl'."

# ── Architecture detection (Apple Silicon vs Intel) ────────────────────────────
get_system_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo "arm64" ;;
    x86_64|amd64)  echo "x86_64" ;;
    *)             uname -m ;;
  esac
}

get_binary_arch() {
  local bin="$1" info
  [[ -f "$bin" ]] || { echo "unknown"; return; }
  info="$(file -b "$bin" 2>/dev/null || true)"
  if [[ "$info" == *"arm64"* ]]; then
    echo "arm64"
  elif [[ "$info" == *"x86_64"* ]]; then
    echo "x86_64"
  else
    echo "unknown"
  fi
}

check_architecture_compat() {
  local bundle="$1" sys_arch bin_arch
  sys_arch="$(get_system_arch)"
  bin_arch="$(get_binary_arch "${bundle}/llama-server")"

  info "System: ${sys_arch} | Bundle: ${bin_arch}"

  if [[ "$bin_arch" == "unknown" ]]; then
    warn "Cannot determine llama-server architecture — continuing…"
    return 0
  fi

  if [[ "$sys_arch" == "$bin_arch" ]]; then
    ok "Architecture matches (${sys_arch})"
    return 0
  fi

  die "Architecture mismatch!
  Your Mac:     ${sys_arch}
  llama bundle: ${bin_arch}

  You need to download the correct build:
    • Apple Silicon (M1/M2/M3/M4) → arm64 package
    • Intel Mac                    → x86_64 package

  GGUF models are the same for both — only the llama.cpp archive needs to change."
}

# ── Shell RC file detection ────────────────────────────────────────────────────
detect_shell_rc_files() {
  local shell_path shell_name
  shell_path="${SHELL:-}"
  shell_name="$(basename "${shell_path:-zsh}")"

  SHELL_RCS=()
  case "$shell_name" in
    zsh)
      SHELL_RCS=("${HOME}/.zshrc")
      ;;
    bash)
      # macOS: login shell reads .bash_profile; Linux: .bashrc
      if [[ "$(uname -s)" == "Darwin" ]]; then
        SHELL_RCS=("${HOME}/.bash_profile")
      else
        SHELL_RCS=("${HOME}/.bashrc")
      fi
      ;;
    fish)
      warn "Fish shell: manually add to ~/.config/fish/config.fish:"
      warn '  set -gx PATH $HOME/.local/bin $PATH'
      warn '  set -gx DYLD_LIBRARY_PATH $HOME/.local/lib $DYLD_LIBRARY_PATH'
      SHELL_RCS=()
      return 0
      ;;
    *)
      warn "Unknown shell (${shell_name}) — using ~/.profile"
      SHELL_RCS=("${HOME}/.profile")
      ;;
  esac

  info "Shell: ${shell_path:-?} (${shell_name}) → ${SHELL_RCS[*]:-(no RC file)}"
}

# ── huggingface-cli discovery ─────────────────────────────────────────────────
find_hf_cli() {
  local candidate
  for candidate in \
    "$(command -v hf 2>/dev/null || true)" \
    "$(command -v huggingface-cli 2>/dev/null || true)" \
    "${HOME}/conda/envs/exo/bin/hf" \
    "${HOME}/miniconda3/bin/hf" \
    "${HOME}/anaconda3/bin/hf" \
    "/opt/homebrew/bin/hf" \
    "/usr/local/bin/hf" \
    "${HOME}/conda/envs/exo/bin/huggingface-cli" \
    "${HOME}/miniconda3/bin/huggingface-cli" \
    "${HOME}/anaconda3/bin/huggingface-cli" \
    "/opt/homebrew/bin/huggingface-cli" \
    "/usr/local/bin/huggingface-cli"
  do
    [[ -n "$candidate" && -x "$candidate" ]] && { echo "$candidate"; return 0; }
  done
  return 1
}

HF_CLI=""

# ── Configuration and model management ────────────────────────────────────────
sync_model_path() {
  MODEL_PATH="${MODELS_DIR}/${MODEL_FILE}"
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  sync_model_path
}

save_config() {
  local llama_ver=""
  mkdir -p "$CONFIG_DIR"
  [[ -x "${LOCAL_BIN}/llama-server" ]] && llama_ver="$(get_llama_version_string "${LOCAL_BIN}/llama-server")"
  cat > "$CONFIG_FILE" <<EOF
# llama.cpp — generated by install-llama.sh
LLAMA_VERSION="${llama_ver}"
MODEL_LABEL="${MODEL_LABEL}"
MODEL_REPO="${MODEL_REPO}"
MODEL_FILE="${MODEL_FILE}"
MODEL_PATH="${MODEL_PATH}"
PORT=${PORT}
CONTEXT=${CONTEXT}
HOST="${HOST}"
EOF
}

apply_model_preset() {
  local preset
  preset="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "$preset" in
    1|qwen14)
      MODEL_LABEL="Qwen2.5 14B Q4_K_M (~8.4 GB)"
      MODEL_REPO="bartowski/Qwen2.5-14B-Instruct-GGUF"
      MODEL_FILE="Qwen2.5-14B-Instruct-Q4_K_M.gguf"
      ;;
    2|qwen7)
      MODEL_LABEL="Qwen2.5 7B Q4_K_M (~4.7 GB)"
      MODEL_REPO="bartowski/Qwen2.5-7B-Instruct-GGUF"
      MODEL_FILE="Qwen2.5-7B-Instruct-Q4_K_M.gguf"
      ;;
    3|llama8)
      MODEL_LABEL="Llama 3.1 8B Q4_K_M (~5 GB)"
      MODEL_REPO="bartowski/Meta-Llama-3.1-8B-Instruct-GGUF"
      MODEL_FILE="Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
      ;;
    4|qwen32)
      MODEL_LABEL="Qwen2.5 32B Q4_K_M (~19 GB)"
      MODEL_REPO="bartowski/Qwen2.5-32B-Instruct-GGUF"
      MODEL_FILE="Qwen2.5-32B-Instruct-Q4_K_M.gguf"
      ;;
    *)
      die "Unknown preset: $1. Use: qwen14 | qwen7 | llama8 | qwen32  (or --list-models)"
      ;;
  esac
  sync_model_path
  ok "Model: ${MODEL_LABEL}"
}

list_models_catalog() {
  echo ""
  echo "Available models (--model PRESET):"
  echo ""
  echo "  qwen14  (1)  Qwen2.5 14B Q4_K_M   ~8.4 GB  — balanced (recommended)"
  echo "  qwen7   (2)  Qwen2.5 7B Q4_K_M    ~4.7 GB  — faster"
  echo "  llama8  (3)  Llama 3.1 8B Q4_K_M  ~5 GB    — fast"
  echo "  qwen32  (4)  Qwen2.5 32B Q4_K_M   ~19 GB   — best quality (24 GB RAM)"
  echo ""
  echo "Examples:"
  echo "  ./install-llama.sh --model qwen7"
  echo "  ./install-llama.sh --choose-model"
  echo ""
}

choose_model_interactive() {
  local choice
  list_models_catalog
  if [[ ! -t 0 ]]; then
    die "Interactive selection requires a TTY. Use: --model qwen14"
  fi
  read -r -p "Choose [1-4] or preset name (qwen14): " choice
  choice="${choice:-1}"
  apply_model_preset "$choice"
  save_config
}

resolve_model_selection() {
  load_config
  if [[ -n "$MODEL_PRESET" ]]; then
    apply_model_preset "$MODEL_PRESET"
    save_config
  elif [[ "$MODE_CHOOSE_MODEL" -eq 1 ]]; then
    choose_model_interactive
  fi
}

if [[ "$MODE_LIST_MODELS" -eq 1 ]]; then
  list_models_catalog
  exit 0
fi

if [[ "$SKIP_DOWNLOAD" -eq 0 && "$RUN_MAIN" -eq 1 ]]; then
  HF_CLI="$(find_hf_cli || true)"
  [[ -n "$HF_CLI" ]] || die "hf / huggingface-cli not found. Install: pip3 install huggingface_hub"
fi

# ── Finding / extracting the llama bundle ──────────────────────────────────────
is_llama_bundle() {
  local dir="$1"
  [[ -d "$dir" && -x "${dir}/llama-server" ]] || return 1
  [[ -f "${dir}/libllama.dylib" || -f "${dir}/libllama-common.dylib" ]] && return 0
  [[ -n "$(find "$dir" -maxdepth 1 -name 'libllama*.dylib' -print -quit 2>/dev/null)" ]]
}

# Extract build number from folder name: llama-b9159 → 9159
bundle_build_number() {
  local name="$1"
  local n
  n="$(basename "$name" | grep -oE '[bB][0-9]+' | tr -d 'bB' | head -1 || true)"
  if [[ -n "$n" ]]; then
    echo "$n"
  else
    # fallback: mtime
    stat -f%m "$name" 2>/dev/null || echo 0
  fi
}

get_llama_version_string() {
  local bin="$1" ver="" lib base
  if [[ ! -x "$bin" ]]; then
    echo "not installed"
    return
  fi

  # 1) From libllama dylib (instant) — e.g. libllama.0.0.9159.dylib
  for lib in "${LOCAL_LIB}"/libllama.[0-9]*.[0-9]*.dylib; do
    [[ -f "$lib" ]] || continue
    base="$(basename "$lib" .dylib)"
    ver="${base##*.}"
    [[ "$ver" =~ ^[0-9]+$ ]] && { echo "build ${ver}"; return; }
  done

  # 2) strings in binary (fast, no Metal init)
  ver="$(strings "$bin" 2>/dev/null | grep -m1 '^version: ' | sed 's/^version: //' | tr -d '\r' || true)"
  [[ -n "$ver" ]] && { echo "$ver"; return; }

  # 3) --version (slow; pipefail + SIGPIPE otherwise yields "unknown")
  set +o pipefail
  ver="$("${bin}" --version 2>&1 | grep -m1 '^version: ' | sed 's/^version: //' | tr -d '\r' || true)"
  set -o pipefail
  [[ -n "$ver" ]] && { echo "$ver"; return; }

  echo "unknown"
}

get_installed_build_number() {
  local v
  if [[ -x "${LOCAL_BIN}/llama-server" ]]; then
    v="$(get_llama_version_string "${LOCAL_BIN}/llama-server")"
    v="$(echo "$v" | grep -oE '[0-9]+' | tail -1)"
    [[ -n "$v" ]] && { echo "$v"; return; }
  fi
  echo "0"
}

# ── GitHub — check and download new releases ───────────────────────────────────
github_fetch_latest_tag() {
  local json tag
  json="$(curl -fsSL --connect-timeout 8 --max-time 25 \
    -H "Accept: application/vnd.github+json" \
    "${GITHUB_API}" 2>/dev/null)" || return 1
  tag="$(echo "$json" | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  [[ -n "$tag" ]] && echo "$tag"
}

github_normalize_tag() {
  local t="$1"
  t="${t#b}"
  t="${t#B}"
  echo "b${t}"
}

github_asset_name() {
  local tag arch
  tag="$(github_normalize_tag "$1")"
  arch="$(get_system_arch)"
  case "$arch" in
    arm64)  echo "llama-${tag}-bin-macos-arm64.tar.gz" ;;
    x86_64) echo "llama-${tag}-bin-macos-x64.tar.gz" ;;
    *)      echo "" ;;
  esac
}

github_release_url() {
  local tag asset
  tag="$(github_normalize_tag "$1")"
  asset="$(github_asset_name "$tag")"
  [[ -n "$asset" ]] || return 1
  echo "https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}"
}

tag_build_number() {
  echo "$1" | tr -d 'bB' | grep -oE '^[0-9]+' || echo "0"
}

check_github_update() {
  local installed latest_tag latest_num asset url releases_url
  releases_url="https://github.com/${GITHUB_REPO}/releases"

  echo -e "  ${BLUE}GitHub:${NC}"
  latest_tag="$(github_fetch_latest_tag)" || {
    echo -e "    ${YELLOW}check failed${NC} (network or API rate limit)"
    echo -e "    ${releases_url}"
    return 1
  }

  installed="$(get_installed_build_number)"
  latest_num="$(tag_build_number "$latest_tag")"
  asset="$(github_asset_name "$latest_tag")"
  url="$(github_release_url "$latest_tag")"

  if [[ "$installed" == "0" ]]; then
    echo -e "    Latest build: ${GREEN}${latest_tag}${NC} (not installed)"
    echo -e "    ${releases_url}"
    [[ -n "$url" ]] && echo -e "    Download: ${url}"
    return 0
  fi

  if [[ "$installed" -ge "$latest_num" ]]; then
    echo -e "    ${GREEN}up to date${NC} — b${installed} (= ${latest_tag})"
  else
    echo -e "    ${YELLOW}newer version available${NC}: ${latest_tag} (installed: b${installed})"
    echo -e "    ${releases_url}"
    [[ -n "$url" ]] && echo -e "    Download: ${url}"
    print_update_next_steps "${latest_tag}"
  fi
  return 0
}

print_update_next_steps() {
  local tag="${1:-}"
  echo ""
  info "Next step:"
  if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
    echo "  ./install-llama.sh --update --skip-server --install-agent"
    echo ""
    info "LaunchAgent is active — the server will restart in the background (model stays untouched)."
  else
    echo "  ./install-llama.sh --update --skip-server"
    echo ""
    info "For auto-start at login:"
    echo "  ./install-llama.sh --install-agent"
  fi
  [[ -n "$tag" ]] && echo ""
  [[ -n "$tag" ]] && info "Full cycle (download + install):"
  [[ -n "$tag" ]] && echo "  ./install-llama.sh --download-update && ./install-llama.sh --update --skip-server$([[ -f "$LAUNCH_AGENT_PLIST" ]] && echo ' --install-agent')"
}

download_github_update() {
  local installed latest_tag latest_num asset url dest
  latest_tag="$(github_fetch_latest_tag)" || die "Failed to connect to GitHub API.
Check your internet connection or visit: https://github.com/${GITHUB_REPO}/releases"

  installed="$(get_installed_build_number)"
  latest_num="$(tag_build_number "$latest_tag")"

  if [[ "$installed" != "0" && "$installed" -ge "$latest_num" ]]; then
    ok "You already have the latest version (${latest_tag})"
    return 0
  fi

  asset="$(github_asset_name "$latest_tag")"
  [[ -n "$asset" ]] || die "No macOS build available for architecture $(get_system_arch)"
  url="$(github_release_url "$latest_tag")"
  dest="${SCRIPT_DIR}/${asset}"

  info "Downloading ${latest_tag} for $(get_system_arch) …"
  warn "The file may be hundreds of MB — please wait…"
  curl -fL --progress-bar -o "$dest" "$url" || die "Download failed: ${url}"
  ok "Downloaded: ${dest}"
  print_update_next_steps "${latest_tag}"
}

# Select the newest extracted llama-* folder
select_newest_bundle_dir() {
  local item best="" best_n=0 n
  for item in "${SCRIPT_DIR}"/llama-*; do
    [[ -e "$item" ]] || continue
    [[ -d "$item" ]] || continue
    is_llama_bundle "$item" || continue
    n="$(bundle_build_number "$item")"
    if [[ -z "$best" ]] || [[ "$n" -gt "$best_n" ]]; then
      best="$item"
      best_n="$n"
    fi
  done
  [[ -n "$best" ]] && echo "$best"
}

# Select the newest llama-*.tar.gz / .zip archive
select_newest_archive() {
  local item best="" best_n=0 n
  for item in "${SCRIPT_DIR}"/llama-*.{zip,tar.gz,tgz,tar.xz} "${SCRIPT_DIR}"/llama-*.zip; do
    [[ -f "$item" ]] || continue
    n="$(bundle_build_number "$item")"
    if [[ -z "$best" ]] || [[ "$n" -gt "$best_n" ]]; then
      best="$item"
      best_n="$n"
    fi
  done
  [[ -n "$best" ]] && echo "$best"
}

# Extract archive and return the bundle directory path
extract_bundle_from_archive() {
  local item="$1" name extract_dir bundle_dir permanent
  name="$(basename "$item")"
  extract_dir="${SCRIPT_DIR}/.llama-extract-$$"
  mkdir -p "$extract_dir"
  info "Extracting: ${name}"

  case "$name" in
    *.zip) unzip -q -o "$item" -d "$extract_dir" ;;
    *.tar.gz|*.tgz) tar -xzf "$item" -C "$extract_dir" ;;
    *.tar.xz) tar -xJf "$item" -C "$extract_dir" ;;
    *)
      rm -rf "$extract_dir"
      die "Unsupported archive format: ${name}"
      ;;
  esac

  bundle_dir="$(find "$extract_dir" -maxdepth 3 -name llama-server -type f 2>/dev/null | head -1)"
  if [[ -z "$bundle_dir" ]]; then
    rm -rf "$extract_dir"
    die "Archive ${name} is corrupted or does not contain llama-server."
  fi

  bundle_dir="$(dirname "$bundle_dir")"
  permanent="${SCRIPT_DIR}/$(basename "$bundle_dir")"
  if [[ "$bundle_dir" != "$permanent" ]]; then
    rm -rf "$permanent" 2>/dev/null || true
    mv "$bundle_dir" "$permanent"
    bundle_dir="$permanent"
    rm -rf "$extract_dir"
  fi
  ok "Extracted bundle: ${bundle_dir}"
  echo "$bundle_dir"
}

# Remove older llama-b* folders after update
cleanup_old_bundle_dirs() {
  local keep_n="$1" item n
  [[ -n "$keep_n" ]] || return 0
  for item in "${SCRIPT_DIR}"/llama-*; do
    [[ -d "$item" ]] || continue
    is_llama_bundle "$item" || continue
    n="$(bundle_build_number "$item")"
    if [[ "$n" -lt "$keep_n" ]]; then
      info "Removing old folder: $(basename "$item") (b${n})"
      rm -rf "$item"
    fi
  done
}

find_and_prepare_bundle() {
  local bundle_dir="" bundle_n=0 archive="" archive_n=0

  info "Searching for llama bundle in: ${SCRIPT_DIR}"

  bundle_dir="$(select_newest_bundle_dir || true)"
  [[ -n "$bundle_dir" ]] && bundle_n="$(bundle_build_number "$bundle_dir")"

  archive="$(select_newest_archive || true)"
  [[ -n "$archive" ]] && archive_n="$(bundle_build_number "$archive")"

  # Newer source wins (archive b9444 > folder b9174)
  if [[ -n "$archive" && ( -z "$bundle_dir" || "$archive_n" -gt "$bundle_n" ) ]]; then
    if [[ -n "$bundle_dir" ]]; then
      info "Archive b${archive_n} is newer than folder b${bundle_n} — extracting…"
    fi
    bundle_dir="$(extract_bundle_from_archive "$archive")"
    [[ "$MODE_UPDATE" -eq 1 ]] && cleanup_old_bundle_dirs "$archive_n"
    echo "$bundle_dir"
    return 0
  fi

  if [[ -n "$bundle_dir" ]]; then
    ok "Found folder: ${bundle_dir} (b${bundle_n})"
    echo "$bundle_dir"
    return 0
  fi

  if [[ -n "$archive" ]]; then
    bundle_dir="$(extract_bundle_from_archive "$archive")"
    echo "$bundle_dir"
    return 0
  fi

  # No bundle found — auto-download from GitHub (skip in --update mode,
  # where --download-update already ran or the user placed an archive manually)
  if [[ "$MODE_UPDATE" -eq 0 ]]; then
    info "No local bundle found — checking GitHub for latest release…"
    download_github_update >&2 || die "No local bundle and GitHub download failed.

Place an archive manually from https://github.com/${GITHUB_REPO}/releases"
    # Retry with the newly downloaded archive
    archive="$(select_newest_archive || true)"
    if [[ -n "$archive" ]]; then
      info "Extracting downloaded bundle …"
      bundle_dir="$(extract_bundle_from_archive "$archive")"
      echo "$bundle_dir"
      return 0
    fi
  fi

  die "No llama bundle found in ${SCRIPT_DIR}.
Place one of the following in the same directory as this script:
  • llama-b9159/                    (extracted folder)
  • llama-b9159-bin-macos-arm64.tar.gz
  • llama-b9159.zip
Or run with --download-update to fetch the latest from GitHub."
}

# ── Stop running server ────────────────────────────────────────────────────────
stop_llama_server() {
  local pid
  if ! pgrep -x llama-server >/dev/null 2>&1; then
    return 0
  fi
  info "Stopping running llama-server …"
  pkill -x llama-server 2>/dev/null || pkill -f llama-server 2>/dev/null || true
  sleep 2
  if pgrep -x llama-server >/dev/null 2>&1; then
    warn "Force stopping (kill -9) …"
    pkill -9 -x llama-server 2>/dev/null || true
    sleep 1
  fi
  if lsof -i ":${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    pid="$(lsof -t -i ":${PORT}" -sTCP:LISTEN 2>/dev/null | head -1)"
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    sleep 1
  fi
  pgrep -x llama-server >/dev/null 2>&1 && warn "llama-server may still be running" || ok "llama-server stopped"
}

# ── Remove old binaries (during update) ────────────────────────────────────────
cleanup_old_install() {
  local f base
  info "Removing old installation …"
  for f in "${LOCAL_BIN}"/llama-*; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    [[ "$base" == "llama-server-start.sh" ]] && continue
    rm -f "$f"
  done
  rm -f "${LOCAL_BIN}"/rpc-server 2>/dev/null || true
  rm -f "${LOCAL_LIB}"/libggml*.dylib "${LOCAL_LIB}"/libllama*.dylib "${LOCAL_LIB}"/libmtmd*.dylib 2>/dev/null || true
  ok "Old files removed"
}

# ── Install binaries and libraries ─────────────────────────────────────────────
install_binaries() {
  local bundle="$1"
  info "Installing to ${LOCAL_BIN} and ${LOCAL_LIB} …"
  mkdir -p "$LOCAL_BIN" "$LOCAL_LIB" "$MODELS_DIR"

  if [[ "$MODE_UPDATE" -eq 1 ]]; then
    cleanup_old_install
  fi

  cp -f "${bundle}"/llama-* "$LOCAL_BIN/" 2>/dev/null || true
  [[ -f "${bundle}/rpc-server" ]] && cp -f "${bundle}/rpc-server" "$LOCAL_BIN/"
  cp -f "${bundle}"/*.dylib "$LOCAL_LIB/" 2>/dev/null || die "No .dylib files found in ${bundle}"

  chmod +x "${LOCAL_BIN}"/llama-* 2>/dev/null || true
  [[ -f "${LOCAL_BIN}/rpc-server" ]] && chmod +x "${LOCAL_BIN}/rpc-server"

  ok "Copied binaries and libraries"
}

# ── Gatekeeper ─────────────────────────────────────────────────────────────────
fix_gatekeeper() {
  local f
  info "Removing quarantine flags and ad-hoc codesigning …"

  xattr -dr com.apple.quarantine "$LOCAL_LIB" "$LOCAL_BIN" 2>/dev/null || true

  for f in "${LOCAL_LIB}"/*.dylib; do
    [[ -f "$f" ]] && codesign -s - --force "$f" 2>/dev/null || warn "codesign: $f"
  done
  for f in "${LOCAL_BIN}"/llama-* "${LOCAL_BIN}"/rpc-server; do
    [[ -f "$f" ]] && codesign -s - --force "$f" 2>/dev/null || true
  done

  ok "Gatekeeper settings applied"
}

# ── Shell configuration (based on detected shell) ──────────────────────────────
configure_shell() {
  local marker="# llama.cpp (install-llama.sh)"
  local rc updated=0

  detect_shell_rc_files

  if [[ ${#SHELL_RCS[@]} -eq 0 ]]; then
    warn "No RC file to update — set PATH manually."
    export PATH="${LOCAL_BIN}:${PATH}"
    export DYLD_LIBRARY_PATH="${LOCAL_LIB}:${DYLD_LIBRARY_PATH:-}"
    return 0
  fi

  for rc in "${SHELL_RCS[@]}"; do
    touch "$rc"
    if grep -qF "$marker" "$rc" 2>/dev/null; then
      continue
    fi
    info "Adding settings to ${rc} …"
    cat >> "$rc" <<'EOF'

# llama.cpp (install-llama.sh)
export PATH="$HOME/.local/bin:$PATH"
export DYLD_LIBRARY_PATH="$HOME/.local/lib:$DYLD_LIBRARY_PATH"
EOF
    updated=1
    ok "Updated: ${rc}"
  done

  if [[ "$updated" -eq 0 ]]; then
    ok "Shell RC files are already configured"
  fi

  export PATH="${LOCAL_BIN}:${PATH}"
  export DYLD_LIBRARY_PATH="${LOCAL_LIB}:${DYLD_LIBRARY_PATH:-}"
}

# ── Verify llama-server ────────────────────────────────────────────────────────
verify_install() {
  info "Verifying llama-server …"
  set +o pipefail
  if "${LOCAL_BIN}/llama-server" --help 2>&1 | grep -qE 'help|usage|version'; then
    set -o pipefail
    ok "llama-server works"
  else
    set -o pipefail
    die "llama-server failed to start. Check Gatekeeper in System Settings → Privacy & Security"
  fi
}

# ── Download model ──────────────────────────────────────────────────────────────
model_is_valid() {
  [[ -f "$MODEL_PATH" && ! -L "$MODEL_PATH" ]] && [[ "$(stat -f%z "$MODEL_PATH" 2>/dev/null || echo 0)" -gt 1000000000 ]]
}

download_model() {
  if model_is_valid; then
    ok "Model already exists: ${MODEL_PATH} ($(du -h "$MODEL_PATH" | cut -f1))"
    return 0
  fi

  # Remove broken symlinks
  if [[ -L "$MODEL_PATH" ]] || [[ ! -f "$MODEL_PATH" ]]; then
    rm -f "$MODEL_PATH"
  fi

  info "Downloading model: ${MODEL_REPO} / ${MODEL_FILE}"
  warn "This is ~8+ GB — may take a while…"

  local hf_cli_name
  hf_cli_name="$(basename "$HF_CLI")"
  if [[ "$hf_cli_name" == "hf" ]]; then
    "$HF_CLI" download "$MODEL_REPO" "$MODEL_FILE" \
      --local-dir "$MODELS_DIR"
  else
    "$HF_CLI" download "$MODEL_REPO" "$MODEL_FILE" \
      --local-dir "$MODELS_DIR" \
      --local-dir-use-symlinks False
  fi

  if model_is_valid; then
    ok "Model downloaded: ${MODEL_PATH}"
  else
    die "Download failed — file missing or too small: ${MODEL_PATH}"
  fi
}

# ── LAN IP (for local network access) ──────────────────────────────────────────
print_network_info() {
  local ip=""
  for iface in en0 en1; do
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    [[ -n "$ip" ]] && break
  done
  echo ""
  ok "Server listening on all interfaces (local network)"
  echo -e "  ${GREEN}Local:${NC}   http://127.0.0.1:${PORT}/v1"
  if [[ -n "$ip" ]]; then
    echo -e "  ${GREEN}LAN:${NC}       http://${ip}:${PORT}/v1"
    echo -e "  ${GREEN}Health:${NC}    http://${ip}:${PORT}/health"
  fi
  print_test_instructions "$ip"
}

print_test_instructions() {
  local ip="${1:-127.0.0.1}"
  local base_url="http://${ip}:${PORT}"
  echo ""
  echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  How to test${NC}"
  echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  ${GREEN}Browser — health check:${NC}"
  echo -e "    ${base_url}/health"
  echo ""
  echo -e "  ${GREEN}Terminal — quick test:${NC}"
  echo "    curl ${base_url}/v1/chat/completions \\"
  echo "      -H \"Content-Type: application/json\" \\"
  echo "      -d '{"
  echo '        "model": "llama",'
  echo '        "messages": [{"role": "user", "content": "Hello!"}]'
  echo "      }'"
  echo ""
  echo -e "  ${GREEN}Chat frontends (point to ${base_url}/v1):${NC}"
  echo -e "    • Open WebUI     — https://openwebui.com"
  echo -e "    • Chatbox        — https://chatboxai.app"
  echo -e "    • Continue.dev   — https://continue.dev (VS Code)"
  echo ""
}

# ── Status ──────────────────────────────────────────────────────────────────────
get_lan_ip() {
  local iface ip=""
  for iface in en0 en1; do
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
  done
  echo ""
}

server_is_running() {
  pgrep -x llama-server >/dev/null 2>&1
}

launch_agent_loaded() {
  launchctl print "gui/$(id -u)/${LAUNCH_AGENT_LABEL}" &>/dev/null
}

launch_agent_state() {
  local out state pid=""
  if [[ ! -f "$LAUNCH_AGENT_PLIST" ]]; then
    echo "not_installed"
    return
  fi
  if ! launch_agent_loaded; then
    echo "not_loaded"
    return
  fi
  out="$(launchctl print "gui/$(id -u)/${LAUNCH_AGENT_LABEL}" 2>/dev/null || true)"
  state="$(echo "$out" | awk '/^\tstate = / && $0 !~ /^\t\t/ { gsub(/.*state = /, ""); print; exit }')"
  pid="$(echo "$out" | awk '/^\tpid = / { gsub(/.*pid = /, ""); print; exit }')"
  if [[ "$state" == "running" ]]; then
    echo "running:${pid:-?}"
  else
    echo "loaded:${state:-unknown}"
  fi
}

show_status() {
  local ip ver model_status server_status agent_status
  load_config
  ip="$(get_lan_ip)"

  echo ""
  echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  llama.cpp — Status${NC}"
  echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  echo ""

  if [[ -x "${LOCAL_BIN}/llama-server" ]]; then
    ver="${LLAMA_VERSION:-}"
    if [[ -z "$ver" || "$ver" == "unknown" ]]; then
      ver="$(get_llama_version_string "${LOCAL_BIN}/llama-server")"
    fi
    echo -e "  ${GREEN}llama.cpp:${NC}  ${ver}"
    echo -e "  ${GREEN}Binaries:${NC}   ${LOCAL_BIN}"
  else
    echo -e "  ${RED}llama.cpp:${NC}  not installed"
  fi

  echo -e "  ${GREEN}Model:${NC}      ${MODEL_LABEL:-—}"
  echo -e "             ${MODEL_PATH}"
  if model_is_valid; then
    model_status="$(du -h "$MODEL_PATH" 2>/dev/null | cut -f1) — OK"
    echo -e "  ${GREEN}File:${NC}       ${model_status}"
  else
    echo -e "  ${YELLOW}File:${NC}       missing or incomplete"
  fi

  if server_is_running; then
    server_status="${GREEN}runnning${NC} (PID $(pgrep -x llama-server | head -1))"
  else
    server_status="${YELLOW}stopped${NC}"
  fi
  echo -e "  ${GREEN}Server:${NC}     ${server_status}"

  echo -e "  ${GREEN}Port:${NC}       ${PORT}"
  echo -e "  ${GREEN}API:${NC}        http://127.0.0.1:${PORT}/v1"
  [[ -n "$ip" ]] && echo -e "  ${GREEN}LAN:${NC}        http://${ip}:${PORT}/v1"

  local la_state
  la_state="$(launch_agent_state)"
  case "$la_state" in
    not_installed)
      agent_status="not installed (./install-llama.sh --install-agent)"
      ;;
    not_loaded)
      agent_status="${YELLOW}installed, not loaded${NC} → ./install-llama.sh --install-agent"
      ;;
    running:*)
      agent_status="${GREEN}active${NC} (LaunchAgent, PID ${la_state#running:})"
      ;;
    loaded:*)
      agent_status="${YELLOW}loaded, not running${NC} (${la_state#loaded:}) — ./install-llama.sh --install-agent"
      ;;
    spawn_scheduled|waiting|exited:*)
      agent_status="${YELLOW}restarting…${NC} (${la_state}) — ./install-llama.sh --install-agent"
      ;;
    *)
      agent_status="${YELLOW}unknown${NC}"
      ;;
  esac
  echo -e "  ${GREEN}LaunchAgent:${NC} ${agent_status}"

  [[ -f "$CONFIG_FILE" ]] && echo -e "  ${GREEN}Config:${NC}     ${CONFIG_FILE}"

  if [[ "$SKIP_GITHUB_CHECK" -eq 0 ]]; then
    echo ""
    check_github_update || true
  fi
  echo ""
}

# ── LaunchAgent (auto-start) ──────────────────────────────────────────────────
write_start_script() {
  load_config
  mkdir -p "$(dirname "$START_SCRIPT")"
  cat > "$START_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
CONFIG="${HOME}/.config/llama/server.conf"
[[ -f "$CONFIG" ]] && source "$CONFIG"
export PATH="${HOME}/.local/bin:${PATH}"
export DYLD_LIBRARY_PATH="${HOME}/.local/lib:${DYLD_LIBRARY_PATH:-}"
exec "${HOME}/.local/bin/llama-server" \
  -m "${MODEL_PATH}" \
  -c "${CONTEXT}" \
  --port "${PORT}" \
  --host "${HOST}"
SCRIPT
  chmod +x "$START_SCRIPT"
  ok "Start script: ${START_SCRIPT}"
}

install_launch_agent() {
  if ! [[ -x "${LOCAL_BIN}/llama-server" ]]; then
    die "Please install llama.cpp first (without --install-only)."
  fi
  model_is_valid || die "No valid model. Download one with: ./install-llama.sh --model qwen14"

  save_config
  write_start_script
  stop_llama_server

  mkdir -p "${HOME}/Library/LaunchAgents" "${HOME}/Library/Logs"

  cat > "$LAUNCH_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCH_AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${START_SCRIPT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_OUT}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_ERR}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>DYLD_LIBRARY_PATH</key>
    <string>${HOME}/.local/lib</string>
  </dict>
</dict>
</plist>
PLIST

  launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"
  launchctl enable "gui/$(id -u)/${LAUNCH_AGENT_LABEL}" 2>/dev/null || true
  sleep 2

  ok "LaunchAgent installed"
  info "Logs: ${LOG_OUT}"

  if server_is_running; then
    ok "llama-server is running via LaunchAgent"
    print_network_info
  else
    warn "Server didn't start. Check: tail -50 ${LOG_ERR}"
  fi
}

uninstall_launch_agent() {
  stop_llama_server
  if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
    launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
    rm -f "$LAUNCH_AGENT_PLIST"
    ok "LaunchAgent removed"
  else
    info "LaunchAgent is not installed"
  fi
}

# ── Start the server ───────────────────────────────────────────────────────────
start_server() {
  if lsof -i ":${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
    warn "Port ${PORT} is already in use. Stopping old process …"
    pkill -f "llama-server.*--port ${PORT}" 2>/dev/null || true
    sleep 1
  fi

  info "Starting llama-server (Ctrl+C to stop) …"
  print_network_info

  exec "${LOCAL_BIN}/llama-server" \
    -m "$MODEL_PATH" \
    -c "$CONTEXT" \
    --port "$PORT" \
    --host "$HOST"
}

# ── MAIN ───────────────────────────────────────────────────────────────────────
main() {
  local bundle sys_arch old_ver new_ver bundle_name

  echo ""
  if [[ "$MODE_UPDATE" -eq 1 ]]; then
    echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  llama.cpp — UPDATE (macOS)${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  else
    echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  llama.cpp — Automated Installer (macOS)${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
  fi
  echo ""

  resolve_model_selection

  sys_arch="$(get_system_arch)"
  info "macOS $(sw_vers -productVersion 2>/dev/null || echo '?') | CPU: ${sys_arch}"
  info "Model: ${MODEL_LABEL} → ${MODEL_FILE}"

  if [[ "$MODE_UPDATE" -eq 1 ]]; then
    old_ver="$(get_llama_version_string "${LOCAL_BIN}/llama-server")"
    info "Current version: ${old_ver}"
    stop_llama_server
  fi

  bundle="$(find_and_prepare_bundle)"
  bundle="${bundle//$'\n'/}"
  bundle="${bundle%%$'\r'*}"
  [[ -d "$bundle" && -x "${bundle}/llama-server" ]] \
    || die "Invalid bundle path: «${bundle}»"
  bundle_name="$(basename "$bundle")"
  check_architecture_compat "$bundle"

  new_ver="$(get_llama_version_string "${bundle}/llama-server")"
  info "New bundle: ${bundle_name} (${new_ver})"

  install_binaries "$bundle"
  fix_gatekeeper
  configure_shell
  verify_install

  if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
    write_start_script
    info "LaunchAgent: restored llama-server-start.sh"
  fi

  new_ver="$(get_llama_version_string "${LOCAL_BIN}/llama-server")"

  if [[ "$SKIP_DOWNLOAD" -eq 0 ]]; then
    download_model
  else
    if [[ "$MODE_UPDATE" -eq 1 ]]; then
      info "Update: model stays untouched (still in ${MODELS_DIR})"
    else
      info "Skipping model download (--skip-download)"
    fi
    model_is_valid || warn "Model missing: ${MODEL_PATH}"
  fi

  echo ""
  if [[ "$MODE_UPDATE" -eq 1 ]]; then
    ok "Update complete!"
    echo -e "  ${YELLOW}Before:${NC}  ${old_ver}"
    echo -e "  ${GREEN}Now:${NC}     ${new_ver}  (${bundle_name})"
  else
    ok "Installation complete!"
    echo -e "  Version:   ${new_ver}"
  fi
  echo -e "  Binaries:    ${LOCAL_BIN}"
  echo -e "  Libraries:   ${LOCAL_LIB}"
  echo -e "  Models:      ${MODELS_DIR}"
  echo ""

  save_config

  if [[ "$INSTALL_AGENT" -eq 1 ]]; then
    install_launch_agent
    return 0
  fi

  if [[ "$SKIP_SERVER" -eq 0 ]]; then
    if model_is_valid; then
      start_server
    else
      die "No valid model. Run: ./install-llama.sh --model qwen7"
    fi
  else
    info "Start manually:"
    echo "  llama-server -m \"${MODEL_PATH}\" -c ${CONTEXT} --port ${PORT} --host ${HOST}"
    info "Or auto-start: ./install-llama.sh --install-agent"
    echo ""
    print_test_instructions "127.0.0.1"
  fi
}

# ── Entry point ────────────────────────────────────────────────────────────────
if [[ "$MODE_CHECK_UPDATE" -eq 1 ]]; then
  echo ""
  echo -e "${BLUE}  llama.cpp — update check (GitHub)${NC}"
  echo ""
  installed="$(get_installed_build_number)"
  [[ "$installed" != "0" ]] && echo -e "  Installed: b${installed}"
  check_github_update || true
  echo ""
  exit 0
fi

if [[ "$MODE_DOWNLOAD_UPDATE" -eq 1 ]]; then
  echo ""
  echo -e "${BLUE}  llama.cpp — downloading from GitHub${NC}"
  echo ""
  download_github_update
  exit 0
fi

if [[ "$MODE_UPGRADE" -eq 1 ]]; then
  echo ""
  echo -e "${BLUE}  llama.cpp — full upgrade${NC}"
  echo ""
  download_github_update
  MODE_UPDATE=1
  SKIP_DOWNLOAD=1
  SKIP_SERVER=1
  [[ -f "$LAUNCH_AGENT_PLIST" ]] && INSTALL_AGENT=1
  RUN_MAIN=1
  main "$@"
  exit 0
fi

if [[ "$MODE_STATUS" -eq 1 ]]; then
  show_status
  exit 0
fi

if [[ "$UNINSTALL_AGENT" -eq 1 ]]; then
  uninstall_launch_agent
  exit 0
fi

if [[ "$INSTALL_AGENT" -eq 1 && "$RUN_MAIN" -eq 0 ]]; then
  load_config
  resolve_model_selection
  install_launch_agent
  exit 0
fi

if [[ "$RUN_MAIN" -eq 1 ]]; then
  main "$@"
fi
