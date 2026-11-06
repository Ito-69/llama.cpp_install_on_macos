#!/usr/bin/env bash
#
# llama-server-start.sh — launches llama-server from ~/.config/llama/server.conf
#
# SINGLE SOURCE OF TRUTH. Do not fork this logic.
#   • The app bundles this file in LlamaMate.app/Contents/Resources and copies
#     it verbatim to ~/.local/bin/llama-server-start.sh (ConfigManager.writeStartScript).
#   • install-llama.sh (write_start_script) copies this file when it is found
#     next to the installer, and only falls back to an embedded copy otherwise.
#
set -euo pipefail

CONFIG="${HOME}/.config/llama/server.conf"
[[ -f "$CONFIG" ]] && source "$CONFIG"

BIN="${LLAMA_SERVER_BIN:-${HOME}/.local/bin/llama-server}"
export PATH="${HOME}/.local/bin:${PATH}"
export DYLD_LIBRARY_PATH="${HOME}/.local/lib:${DYLD_LIBRARY_PATH:-}"

# ── Sanitize numeric settings ────────────────────────────────────────────────
# server.conf is sourced, so a hand-edited non-numeric value could misbehave;
# any numeric field that isn't all digits falls back to its default with a
# warning. (Empty THREADS_BATCH means "auto" and is left empty.)
san() {
  local name="$1" def="$2" val="${!1-}"
  if [[ -n "$val" && ! "$val" =~ ^[0-9]+$ ]]; then
    echo "[LlamaMate] Invalid ${name}='${val}' in server.conf; using '${def:-auto}'." >&2
    printf -v "$name" '%s' "$def"
  fi
}
san PORT 8080
san CONTEXT 8192
san NGL 99
san THREADS 0
san BATCH_SIZE 2048
san UBATCH_SIZE 512
san CACHE_REUSE 256
san THREADS_BATCH ""
san REASONING_BUDGET ""

# ── Effective values (with defaults) ─────────────────────────────────────────
FA_VAL="${FA:-1}"
CTK_VAL="${CTK:-q8_0}"
CTV_VAL="${CTV:-q8_0}"
CTX_VAL="${CONTEXT:-8192}"
CACHE_REUSE="${CACHE_REUSE:-256}"

# ── Flash Attention / KV-cache guard ─────────────────────────────────────────
# On Metal a quantized KV cache (q8_0/q4_0) requires Flash Attention. If a
# hand-edited server.conf turns FA off while leaving a quantized cache type,
# llama-server refuses to start — so fall back to f16 and warn.
case "$FA_VAL" in
  0 | off | OFF | false | no)
    if [[ "$CTK_VAL" != "f16" || "$CTV_VAL" != "f16" ]]; then
      echo "[LlamaMate] Flash Attention is off; forcing f16 KV cache (quantized KV requires FA on Metal)." >&2
      CTK_VAL="f16"
      CTV_VAL="f16"
    fi
    ;;
esac

# ── RAM warning (non-blocking) ───────────────────────────────────────────────
TOTAL_RAM=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
MODEL_SIZE=$(stat -f%z "${MODEL_PATH:-/dev/null}" 2>/dev/null || echo 0)
CTX_FACTOR=$(( CTX_VAL / 8192 ))
[ "$CTX_FACTOR" -lt 1 ] && CTX_FACTOR=1
case "$CTK_VAL" in
  q4_0) CTX_RAM=$(( (MODEL_SIZE / 12) * CTX_FACTOR )) ;;
  q8_0) CTX_RAM=$(( (MODEL_SIZE / 6) * CTX_FACTOR )) ;;
  *)    CTX_RAM=$(( (MODEL_SIZE / 3) * CTX_FACTOR )) ;;
esac
NEEDED=$(( MODEL_SIZE + CTX_RAM ))
if [ "$TOTAL_RAM" -gt 0 ] && [ "$NEEDED" -gt "$TOTAL_RAM" ]; then
  echo "[LlamaMate] WARNING: model needs ~$(( NEEDED / 1073741824 )) GB RAM but system has $(( TOTAL_RAM / 1073741824 )) GB; it may be killed under memory pressure." >&2
fi

# ── Capability detection ─────────────────────────────────────────────────────
# Only pass flags the installed binary understands, so older llama.cpp builds
# do not fail on unknown options.
HELP="$("$BIN" --help 2>&1 || true)"
supports() { grep -q -- "$1" <<<"$HELP"; }

# ── Build argument list ──────────────────────────────────────────────────────
ARGS=(
  -m "${MODEL_PATH}"
  -c "${CTX_VAL}"
  --port "${PORT:-8080}"
  --host "${HOST:-127.0.0.1}"
  -ngl "${NGL:-99}"
  -fa "${FA_VAL}"
  -t "${THREADS:-0}"
  -b "${BATCH_SIZE:-2048}"
  -ub "${UBATCH_SIZE:-512}"
)

# KV cache type flags, only if this build understands them.
if supports '--cache-type-k' || supports '-ctk,'; then
  ARGS+=( -ctk "${CTK_VAL}" -ctv "${CTV_VAL}" )
fi

# API key, only if one is configured. Prefer --api-key-file (keeps the secret
# out of the process argument list) and fall back to --api-key.
KEY_FILE="${HOME}/.config/llama/api_key"
if [[ -n "${API_KEY:-}" ]]; then
  if supports '--api-key-file'; then
    mkdir -p "$(dirname "$KEY_FILE")"
    ( umask 077; printf '%s\n' "${API_KEY}" > "$KEY_FILE" )
    ARGS+=( --api-key-file "$KEY_FILE" )
  elif supports '--api-key'; then
    ARGS+=( --api-key "${API_KEY}" )
  fi
else
  # No key configured — never leave a stale key file on disk.
  rm -f "$KEY_FILE"
fi

# ── Optional performance flags (each gated on --help support) ────────────────
# Prompt/chat KV reuse across requests.
if [[ "${CACHE_REUSE}" != "0" ]] && supports '--cache-reuse'; then
  ARGS+=( --cache-reuse "${CACHE_REUSE}" )
fi

# Keep the model resident in RAM. Newer builds use -lm mmap+mlock; older ones
# use --mlock; if neither exists, skip with a note.
if [[ "${MLOCK:-0}" == "1" ]]; then
  if supports '--load-mode'; then
    ARGS+=( -lm mmap+mlock )
  elif supports '--mlock'; then
    ARGS+=( --mlock )
  else
    echo "[LlamaMate] mlock not supported by this llama-server; skipping." >&2
  fi
fi

# Separate thread count for prompt/batch processing.
if [[ -n "${THREADS_BATCH:-}" ]] && { supports '-tb,' || supports '--threads-batch'; }; then
  ARGS+=( -tb "${THREADS_BATCH}" )
fi

# ── Reasoning controls ───────────────────────────────────────────────────────
# Effort level is handed to the model's chat template; it only has an effect on
# models whose template understands it (e.g. gpt-oss). "default" = don't pass.
case "${REASONING_EFFORT:-default}" in
  "" | default) ;;
  minimal | low | medium | high | xhigh | max)
    if supports '--reasoning-effort'; then
      ARGS+=( --reasoning-effort "${REASONING_EFFORT}" )
    else
      echo "[LlamaMate] --reasoning-effort not supported by this llama-server; update llama.cpp. Skipping." >&2
    fi
    ;;
  *)
    echo "[LlamaMate] Invalid REASONING_EFFORT='${REASONING_EFFORT}' in server.conf; ignoring." >&2
    ;;
esac

# Thinking token limit — works for any thinking model (Qwen3, DeepSeek-R1, …).
# Empty = unlimited. 0 = no thinking. N>0 needs a build with real budgets;
# older builds only accept -1/0, so N>0 is skipped there instead of crashing.
if [[ -n "${REASONING_BUDGET:-}" ]] && supports '--reasoning-budget'; then
  if [[ "${REASONING_BUDGET}" == "0" ]] || supports 'N>0 for token budget'; then
    ARGS+=( --reasoning-budget "${REASONING_BUDGET}" )
    if [[ "${REASONING_BUDGET}" != "0" ]] && supports '--reasoning-budget-message'; then
      ARGS+=( --reasoning-budget-message "Okay, I have thought enough. Let me give the final answer now." )
    fi
  else
    echo "[LlamaMate] This llama-server only supports a thinking limit of 0 (off); update llama.cpp for token limits. Skipping." >&2
  fi
fi

# ── Log rotation ─────────────────────────────────────────────────────────────
# launchd opens the log files in append mode, so trimming them here (before the
# server starts writing) is safe: subsequent writes go to the new EOF.
rotate_log() {
  local lf="$1" sz tmp
  [[ -f "$lf" ]] || return 0
  sz=$(stat -f%z "$lf" 2>/dev/null || echo 0)
  if [[ "$sz" -gt 20971520 ]]; then   # > 20 MB
    tmp="${lf}.rot.$$"
    if tail -c 5242880 "$lf" > "$tmp" 2>/dev/null; then  # keep last 5 MB
      cat "$tmp" > "$lf"
    fi
    rm -f "$tmp"
  fi
}
rotate_log "${HOME}/Library/Logs/llama-server.log"
rotate_log "${HOME}/Library/Logs/llama-server.err.log"

exec "$BIN" "${ARGS[@]}"
