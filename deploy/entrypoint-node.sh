#!/usr/bin/env bash
# entrypoint-node.sh — runs inside the Adi container as the `node` user.
#
# Invoked by entrypoint.sh via `exec runuser -u node -- /app/entrypoint-node.sh`
# after root has brought up /data ownership and tailscaled. This file
# does everything that belongs under the node user's authority:
#
#  1. Sync persona files from image → volume.
#  2. Seed USER.md + openclaw.json on first boot.
#  3. Sync memory tree from image → volume.
#  4. On Shane's box: seed CLIProxyAPI config, inject secrets, rebind
#     to 0.0.0.0 if on tailnet, start it in the background on :8317.
#     On Meg's box: skip CLIProxyAPI entirely — she routes through
#     Shane's box over the tailnet.
#  5. exec openclaw gateway.
#
# ADI_USER is inherited from entrypoint.sh via --preserve-environment.

set -euo pipefail

WORKSPACE="/data/.openclaw/workspace"
AGENT_DIR="/data/.openclaw/agents/main/agent"
MEMORY_DIR="/data/.openclaw/memory"
IMAGE_PERSONA_DIR="/app/adi-persona"
IMAGE_MEMORY_DIR="$IMAGE_PERSONA_DIR/memory"

OPENCLAW_CONFIG="/data/openclaw.json"
IMAGE_OPENCLAW_CONFIG_SEED="/app/adi-config.seed.json"

CLIPROXY_DIR="/data/cliproxy"
CLIPROXY_CONFIG="${CLIPROXY_DIR}/config.yaml"
CLIPROXY_LOG="${CLIPROXY_DIR}/cliproxy.log"
IMAGE_CLIPROXY_CONFIG_SEED="/app/cliproxy.config.seed.yaml"

CLIPROXY_PID=""

log() { echo "[adi-entrypoint:node] $*"; }

# Clean up the cliproxy sidecar on exit. tailscaled stays with root/Fly
# init — it was started before we dropped privilege and will be reaped
# when the container is torn down. Not our concern from here.
cleanup() {
  if [[ -n "$CLIPROXY_PID" ]]; then
    log "shutting down, killing cliproxy ($CLIPROXY_PID)"
    kill "$CLIPROXY_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT TERM INT

# ── Persona files: always-in-sync from image ───────────────────────
for f in IDENTITY.md SOUL.md AGENTS.md FOXY.md; do
  src="$IMAGE_PERSONA_DIR/$f"
  dst="$WORKSPACE/$f"
  if [[ -f "$src" ]]; then
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
      cp "$src" "$dst"
      log "synced $f"
    fi
  else
    log "WARN: $src missing from image — skipping"
  fi
done

# ── USER.md: first-boot seed only ──────────────────────────────────
if [[ ! -f "$WORKSPACE/USER.md" && -f "$IMAGE_PERSONA_DIR/USER.md" ]]; then
  cp "$IMAGE_PERSONA_DIR/USER.md" "$WORKSPACE/USER.md"
  log "seeded USER.md from image (first boot)"
fi

# ── Memory tree: always-in-sync from image ─────────────────────────
if [[ -d "$IMAGE_MEMORY_DIR" ]]; then
  shopt -s nullglob
  for src in "$IMAGE_MEMORY_DIR"/*.md "$IMAGE_MEMORY_DIR"/*/*.md; do
    [[ -f "$src" ]] || continue
    relpath="${src#$IMAGE_MEMORY_DIR/}"
    dst="$MEMORY_DIR/$relpath"
    mkdir -p "$(dirname "$dst")"
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
      cp "$src" "$dst"
      log "synced memory/$relpath"
    fi
  done
  shopt -u nullglob
fi

# ── openclaw.json: first-boot seed only ────────────────────────────
# openclaw rewrites this file with migration metadata after first boot.
# Always-sync would fight openclaw's own writes. To ship a config
# change, `fly ssh console` → delete the volume copy → restart to
# re-seed.
if [[ ! -f "$OPENCLAW_CONFIG" && -f "$IMAGE_OPENCLAW_CONFIG_SEED" ]]; then
  cp "$IMAGE_OPENCLAW_CONFIG_SEED" "$OPENCLAW_CONFIG"
  log "seeded openclaw.json from image (first boot)"
fi

# ── CLIProxyAPI: Shane runs the sidecar, Meg routes through Shane ──
run_cliproxy_sidecar=true
if [[ "${ADI_USER:-}" == "meg" ]]; then
  run_cliproxy_sidecar=false
  log "ADI_USER=meg — skipping CLIProxyAPI sidecar (routes through adi-shane via tailnet)"
fi

if $run_cliproxy_sidecar; then
  # First-boot seed.
  if [[ ! -f "$CLIPROXY_CONFIG" && -f "$IMAGE_CLIPROXY_CONFIG_SEED" ]]; then
    cp "$IMAGE_CLIPROXY_CONFIG_SEED" "$CLIPROXY_CONFIG"
    log "seeded cliproxy config.yaml from image (first boot)"
  fi

  # Rebind Shane's cliproxy to 0.0.0.0 when on the tailnet so adi-meg
  # can reach it. Idempotent — only rewrites the default loopback host.
  if [[ "${ADI_USER:-}" == "shane" && -n "${TAILSCALE_AUTHKEY:-}" && -f "$CLIPROXY_CONFIG" ]]; then
    if grep -qE '^host:\s*"127\.0\.0\.1"' "$CLIPROXY_CONFIG"; then
      sed -i 's/^host:\s*"127\.0\.0\.1"/host: "0.0.0.0"/' "$CLIPROXY_CONFIG"
      log "rebound cliproxy host 127.0.0.1 → 0.0.0.0 (tailnet exposure for adi-meg)"
    fi
  fi

  # Inject management key + API key if not present.
  if [[ -f "$CLIPROXY_CONFIG" ]]; then
    mgmt_key="${CLIPROXY_MGMT_KEY:-}"
    if [[ -z "$mgmt_key" ]] && grep -qE '^\s*secret-key:\s*""' "$CLIPROXY_CONFIG"; then
      mgmt_key="$(openssl rand -hex 32)"
      log "generated cliproxy management key (no CLIPROXY_MGMT_KEY set)"
    fi
    if [[ -n "$mgmt_key" ]]; then
      sed -i "0,/^\(\s*\)secret-key:\s*\"\"/s//\1secret-key: \"${mgmt_key}\"/" "$CLIPROXY_CONFIG"
    fi

    api_key="${CLIPROXY_API_KEY:-}"
    if [[ -z "$api_key" ]] && grep -qE '^\s*api-keys:\s*\[\]' "$CLIPROXY_CONFIG"; then
      api_key="$(openssl rand -hex 32)"
      log "generated cliproxy api key (no CLIPROXY_API_KEY set)"
    fi
    if [[ -n "$api_key" ]]; then
      sed -i "0,/^\(\s*\)api-keys:\s*\[\]/s//\1api-keys:\n\1  - \"${api_key}\"/" "$CLIPROXY_CONFIG"
    fi

    if [[ -n "${api_key:-}" ]]; then
      echo "$api_key" > "${CLIPROXY_DIR}/current-api-key"
      chmod 600 "${CLIPROXY_DIR}/current-api-key"
      export CLIPROXY_API_KEY="$api_key"
    elif [[ -f "${CLIPROXY_DIR}/current-api-key" ]]; then
      export CLIPROXY_API_KEY="$(cat "${CLIPROXY_DIR}/current-api-key")"
    fi
  fi

  # Start the sidecar.
  if [[ -x /usr/local/bin/cliproxy ]]; then
    cliproxy_host="$(grep -E '^host:' "$CLIPROXY_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo '127.0.0.1')"
    log "starting cliproxy (${cliproxy_host}:8317)"
    /usr/local/bin/cliproxy --config "$CLIPROXY_CONFIG" \
      >> "$CLIPROXY_LOG" 2>&1 &
    CLIPROXY_PID=$!
    log "cliproxy pid=$CLIPROXY_PID (logs: $CLIPROXY_LOG)"
  else
    log "WARN: /usr/local/bin/cliproxy not found; skipping sidecar"
  fi
fi

# ── Hand off to openclaw ───────────────────────────────────────────
log "starting openclaw gateway"
exec node /app/dist/index.js gateway --allow-unconfigured --port 3000 --bind lan
