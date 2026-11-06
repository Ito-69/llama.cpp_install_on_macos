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

BIN="${HOME}/.local/bin/llama-server"
export PATH="${HOME}/.local/bin:${PATH}"
export DYLD_LIBRARY_PATH="${HOME}/.local/lib:${DYLD_LIBRARY_PATH:-}"

# ── Effective values (with defaults) ─────────────────────────────────────────
FA_VAL="${FA:-1}"
CTK_VAL="${CTK:-q8_0}"
CTV_VAL="${CTV:-q8_0}"
CTX_VAL="${CONTEXT:-8192}"

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

# API key, only if one is configured and the binary supports it.
if [[ -n "${API_KEY:-}" ]] && supports '--api-key'; then
  ARGS+=( --api-key "${API_KEY}" )
fi

# NOTE (Phase 3b): optional perf flags (--cache-reuse, -tb, mlock via -lm/--mlock)
# will be appended here, each guarded by `supports`.

exec "$BIN" "${ARGS[@]}"
