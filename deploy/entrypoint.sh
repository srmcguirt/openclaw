#!/usr/bin/env bash
# entrypoint.sh — runs inside the Adi container on every boot.
#
# Responsibilities:
# 1. Ensure workspace/agent dirs exist on the volume.
# 2. Sync persona files from image → volume (IDENTITY/SOUL/AGENTS/FOXY).
#    Seed USER.md and appendices on first boot only.
# 3. Seed openclaw.json on first boot from the image.
# 4. (Optional) Start tailscaled in userspace-networking mode if
#    TAILSCALE_AUTHKEY is set; joins the family relay tailnet.
# 5. On Shane's box: seed CLIProxyAPI config, rebind to 0.0.0.0 if on
#    the tailnet, inject secrets, start it in the background on :8317.
#    On Meg's box: skip the CLIProxyAPI sidecar — she routes through
#    Shane's box over Tailscale instead.
# 6. Exec openclaw gateway.
# 7. Trap exits so sidecars are killed cleanly on container stop.

set -euo pipefail

# ADI_USER is baked into the image by the Dockerfile LABEL, but we
# re-derive it from the volume's USER.md header as the authoritative
# runtime check — avoids a stale-image footgun if someone somehow
# deploys the wrong image to the wrong volume.
ADI_USER="${ADI_USER:-}"
if [[ -z "$ADI_USER" ]]; then
  # Fallback: peek at the persona label in the image
  if [[ -f /app/adi-persona/USER.md ]]; then
    if grep -q 'Shane' /app/adi-persona/USER.md 2>/dev/null; then
      ADI_USER="shane"
    elif grep -q 'Meagan\|Meg' /app/adi-persona/USER.md 2>/dev/null; then
      ADI_USER="meg"
    fi
  fi
fi

WORKSPACE="/data/.openclaw/workspace"
AGENT_DIR="/data/.openclaw/agents/main/agent"
IMAGE_PERSONA_DIR="/app/adi-persona"

OPENCLAW_CONFIG="/data/openclaw.json"
IMAGE_OPENCLAW_CONFIG_SEED="/app/adi-config.seed.json"

CLIPROXY_DIR="/data/cliproxy"
CLIPROXY_CONFIG="${CLIPROXY_DIR}/config.yaml"
CLIPROXY_AUTH_DIR="${CLIPROXY_DIR}/auth"
CLIPROXY_LOG="${CLIPROXY_DIR}/cliproxy.log"
IMAGE_CLIPROXY_CONFIG_SEED="/app/cliproxy.config.seed.yaml"

TAILSCALE_DIR="/data/tailscale"
TAILSCALE_STATE="${TAILSCALE_DIR}/tailscaled.state"
TAILSCALE_SOCKET="${TAILSCALE_DIR}/tailscaled.sock"
TAILSCALE_LOG="${TAILSCALE_DIR}/tailscaled.log"

# PIDs of background sidecars (empty until started).
TAILSCALED_PID=""
CLIPROXY_PID=""

log() { echo "[adi-entrypoint] $*"; }

# Unified cleanup: kill whichever sidecars we started, in reverse order
# of startup so cliproxy drains before tailscaled yanks the network.
cleanup() {
  if [[ -n "$CLIPROXY_PID" ]]; then
    log "shutting down, killing cliproxy ($CLIPROXY_PID)"
    kill "$CLIPROXY_PID" 2>/dev/null || true
  fi
  if [[ -n "$TAILSCALED_PID" ]]; then
    log "shutting down, killing tailscaled ($TAILSCALED_PID)"
    kill "$TAILSCALED_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT TERM INT

# ── Ensure dirs exist ──────────────────────────────────────────────
mkdir -p "$WORKSPACE" "$AGENT_DIR" "$CLIPROXY_DIR" "$CLIPROXY_AUTH_DIR" "$TAILSCALE_DIR"

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

# ── Memory directory: always-in-sync from image ───────────────────
# Memory files (e.g. /app/adi-persona/memory/navy-service-record.md)
# get mirrored to /data/.openclaw/memory/. openclaw's builtin memory
# engine indexes the directory tree and retrieves chunks on demand.
# We sync every file, overwriting the volume copy when the image is
# newer. If user-authored memory files appear on the volume (Adi
# writing to MEMORY.md during use), they stay untouched — we only
# manage files that ship with the image.
MEMORY_DIR="/data/.openclaw/memory"
IMAGE_MEMORY_DIR="$IMAGE_PERSONA_DIR/memory"
mkdir -p "$MEMORY_DIR"
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

# ── openclaw.json: first-boot seed only ──────────────────────────
# We seed openclaw.json on first boot only. Afterwards the volume copy is
# authoritative because openclaw itself rewrites the file (adding migration
# metadata, auto-enabling plugins like anthropic/memory-core, etc). An
# always-sync strategy fights openclaw's own writes on every restart.
#
# To ship a config change from the repo, use `fly ssh console` to edit
# /data/openclaw.json in place, or `fly ssh console -C 'rm /data/openclaw.json'`
# to force a re-seed on next boot. Future: wire a config-sync tool that
# diff-merges changes instead of overwriting.
if [[ ! -f "$OPENCLAW_CONFIG" && -f "$IMAGE_OPENCLAW_CONFIG_SEED" ]]; then
  cp "$IMAGE_OPENCLAW_CONFIG_SEED" "$OPENCLAW_CONFIG"
  log "seeded openclaw.json from image (first boot)"
fi

# ── Tailscale (family relay mesh) ──────────────────────────────────
# Started only when the TAILSCALE_AUTHKEY Fly secret is present. Without
# it, skip silently — that's the normal Phase-1a deploy path, where
# both Adis run standalone with their own (or shared Anthropic-API)
# model providers.
#
# When active:
#   - tailscaled runs in userspace-networking mode (the container runs
#     as node, not root, and we don't have /dev/net/tun access).
#   - Node identity is persisted at /data/tailscale/tailscaled.state so
#     the Tailscale IP/hostname survive redeploys.
#   - Hostname is adi-<user> (adi-shane or adi-meg) so MagicDNS names
#     are stable regardless of Fly machine IDs.
#   - The node is tagged `tag:fly-gw` and the ACL in deploy/tailscale-
#     acl.json enforces what traffic is allowed.
if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
  if [[ -x /usr/local/bin/tailscaled && -x /usr/local/bin/tailscale ]]; then
    tailscale_hostname="adi-${ADI_USER:-unknown}"
    # --outbound-http-proxy-listen binds a local HTTP proxy on loopback
    # that routes outbound HTTP(S) connections THROUGH the tailnet.
    # Required when running userspace-networking: without a proxy, host
    # apps can't reach 100.x.x.x tailnet IPs at all — normal sockets
    # don't see the tailnet. openclaw picks this up via HTTP_PROXY /
    # HTTPS_PROXY env vars (set later in this entrypoint for Meg only).
    log "starting tailscaled (userspace mode, hostname=${tailscale_hostname})"
    /usr/local/bin/tailscaled \
      --tun=userspace-networking \
      --state="$TAILSCALE_STATE" \
      --socket="$TAILSCALE_SOCKET" \
      --statedir="$TAILSCALE_DIR" \
      --outbound-http-proxy-listen=127.0.0.1:1055 \
      --socks5-server=127.0.0.1:1056 \
      >> "$TAILSCALE_LOG" 2>&1 &
    TAILSCALED_PID=$!
    log "tailscaled pid=$TAILSCALED_PID (logs: $TAILSCALE_LOG)"

    # Wait briefly for the socket to appear before running `tailscale up`.
    # tailscaled typically listens within a second; cap at 10s so a broken
    # tailscaled can't hang the whole boot.
    for _ in $(seq 1 20); do
      [[ -S "$TAILSCALE_SOCKET" ]] && break
      sleep 0.5
    done

    if [[ ! -S "$TAILSCALE_SOCKET" ]]; then
      log "WARN: tailscaled socket did not appear after 10s; continuing without tailnet"
    else
      # `tailscale up` is idempotent — on re-boots where the node is
      # already authenticated via the persistent state file, the authkey
      # is silently ignored. Accept-routes=false because we don't want
      # Meg's box routing arbitrary subnets through Shane's box (or
      # vice versa); only direct node-to-node traffic is in scope.
      # --accept-dns=true is REQUIRED: without it, tailscaled's outbound
      # HTTP proxy can't resolve MagicDNS names like
      # adi-shane.springhare-typhon.ts.net because the container's
      # resolver points at Fly's DNS which doesn't know .ts.net. With
      # accept-dns, tailscaled installs itself as a resolver and forwards
      # non-tailnet queries upstream, so Anthropic/Slack/Telegram still
      # resolve normally.
      if /usr/local/bin/tailscale \
          --socket="$TAILSCALE_SOCKET" \
          up \
          --authkey="$TAILSCALE_AUTHKEY" \
          --hostname="$tailscale_hostname" \
          --advertise-tags=tag:fly-gw \
          --accept-routes=false \
          --accept-dns=true \
          --reset >> "$TAILSCALE_LOG" 2>&1; then
        tailnet_ip="$(/usr/local/bin/tailscale --socket="$TAILSCALE_SOCKET" ip -4 2>/dev/null | head -n1 || true)"
        log "tailscale up OK (tailnet_ip=${tailnet_ip:-unknown})"

        # Meg's openclaw needs to reach Shane's CLIProxyAPI over the
        # tailnet. In userspace-networking mode, that REQUIRES routing
        # through tailscaled's outbound HTTP proxy. Setting HTTP_PROXY
        # globally on Shane's box would route HIS outbound traffic
        # (Slack API, Anthropic fallback, etc) through his own tailnet
        # proxy — unnecessary and slower. So only set on Meg.
        #
        # Note: NO_PROXY excludes Fly's internal addresses (loopback for
        # Meg's own gateway, Fly's private 6PN, etc.) from proxying.
        if [[ "${ADI_USER:-}" == "meg" ]]; then
          export HTTP_PROXY="http://127.0.0.1:1055"
          export HTTPS_PROXY="http://127.0.0.1:1055"
          export NO_PROXY="127.0.0.1,localhost,::1,*.fly.dev,fly.dev,*.internal,*.flycast"
          log "set HTTP(S)_PROXY to tailnet proxy (adi-meg routes inference through adi-shane)"
        fi
      else
        log "WARN: tailscale up failed — see $TAILSCALE_LOG; continuing without tailnet"
      fi
    fi
  else
    log "WARN: TAILSCALE_AUTHKEY set but tailscale binaries missing from image"
  fi
else
  log "TAILSCALE_AUTHKEY not set — skipping tailnet (standalone mode)"
fi

# ── CLIProxyAPI: Shane runs the sidecar, Meg routes through Shane ─
# Branching logic:
#   - ADI_USER=shane → run CLIProxyAPI locally. If on tailnet, rebind
#                      from 127.0.0.1 to 0.0.0.0 so adi-meg can reach it.
#   - ADI_USER=meg   → skip sidecar entirely. openclaw.meg.json points
#                      the cliproxy provider at adi-shane.<tailnet>.
#                      If the relay is down, Meg falls back to Anthropic
#                      via her fallback list.
#   - ADI_USER=other → legacy behavior: run sidecar on loopback.
run_cliproxy_sidecar=true
if [[ "${ADI_USER:-}" == "meg" ]]; then
  run_cliproxy_sidecar=false
  log "ADI_USER=meg — skipping CLIProxyAPI sidecar (routes through adi-shane via tailnet)"
fi

# ── CLIProxyAPI config: first-boot seed + secret injection ─────────
if $run_cliproxy_sidecar; then
  if [[ ! -f "$CLIPROXY_CONFIG" && -f "$IMAGE_CLIPROXY_CONFIG_SEED" ]]; then
    cp "$IMAGE_CLIPROXY_CONFIG_SEED" "$CLIPROXY_CONFIG"
    log "seeded cliproxy config.yaml from image (first boot)"
  fi

  # On Shane's box with tailscale up, rebind cliproxy from loopback to
  # 0.0.0.0 so adi-meg's tailnet node can reach tcp/8317. Auth is the
  # `api-keys` list (shared CLIPROXY_API_KEY secret between both boxes);
  # Tailscale ACL (deploy/tailscale-acl.json) is defense-in-depth.
  #
  # Idempotent: only rewrites if the host line is still the loopback
  # default. If you've manually set it to something else, we respect
  # that. To undo, `fly ssh console` and edit /data/cliproxy/config.yaml.
  if [[ "${ADI_USER:-}" == "shane" && -n "${TAILSCALE_AUTHKEY:-}" && -f "$CLIPROXY_CONFIG" ]]; then
    if grep -qE '^host:\s*"127\.0\.0\.1"' "$CLIPROXY_CONFIG"; then
      sed -i 's/^host:\s*"127\.0\.0\.1"/host: "0.0.0.0"/' "$CLIPROXY_CONFIG"
      log "rebound cliproxy host 127.0.0.1 → 0.0.0.0 (tailnet exposure for adi-meg)"
    fi
  fi
fi

# Generate management key if not set and not yet in config.
if $run_cliproxy_sidecar && [[ -f "$CLIPROXY_CONFIG" ]]; then
  # Inject management key: use CLIPROXY_MGMT_KEY env (Fly secret) or generate.
  mgmt_key="${CLIPROXY_MGMT_KEY:-}"
  if [[ -z "$mgmt_key" ]]; then
    # Only generate if the config still has empty secret-key.
    if grep -qE '^\s*secret-key:\s*""' "$CLIPROXY_CONFIG"; then
      mgmt_key="$(openssl rand -hex 32)"
      log "generated cliproxy management key (no CLIPROXY_MGMT_KEY set)"
    fi
  fi
  if [[ -n "$mgmt_key" ]]; then
    # Replace the first `secret-key: ""` line under remote-management.
    # Keep this escape-safe: mgmt_key is hex or a Fly-injected token.
    sed -i "0,/^\(\s*\)secret-key:\s*\"\"/s//\1secret-key: \"${mgmt_key}\"/" "$CLIPROXY_CONFIG"
  fi

  # Inject at least one API key for openclaw → cliproxy calls.
  # CLIPROXY_API_KEY (Fly secret) is preferred; generate if absent.
  api_key="${CLIPROXY_API_KEY:-}"
  if [[ -z "$api_key" ]]; then
    if grep -qE '^\s*api-keys:\s*\[\]' "$CLIPROXY_CONFIG"; then
      api_key="$(openssl rand -hex 32)"
      log "generated cliproxy api key (no CLIPROXY_API_KEY set)"
    fi
  fi
  if [[ -n "$api_key" ]]; then
    # Replace `api-keys: []` with a one-entry list.
    sed -i "0,/^\(\s*\)api-keys:\s*\[\]/s//\1api-keys:\n\1  - \"${api_key}\"/" "$CLIPROXY_CONFIG"
  fi

  # Always export the effective api-key so openclaw's entrypoint logic
  # (and any user who shells in) can find it.
  if [[ -n "${api_key:-}" ]]; then
    echo "$api_key" > "${CLIPROXY_DIR}/current-api-key"
    chmod 600 "${CLIPROXY_DIR}/current-api-key"
    export CLIPROXY_API_KEY="$api_key"
  elif [[ -f "${CLIPROXY_DIR}/current-api-key" ]]; then
    export CLIPROXY_API_KEY="$(cat "${CLIPROXY_DIR}/current-api-key")"
  fi
fi

# ── Start CLIProxyAPI in the background ────────────────────────────
# Binary is at /usr/local/bin/cliproxy. Run it with the seeded config;
# background it; capture PID for shutdown handling.
#
# Shared trap at top of script kills both tailscaled + cliproxy on
# exit, so we only need to populate CLIPROXY_PID here — no local trap.
if $run_cliproxy_sidecar; then
  if [[ -x /usr/local/bin/cliproxy ]]; then
    # Show the actual bind in the log line so you don't have to grep
    # config.yaml to know whether the tailnet rebind took effect.
    cliproxy_host="$(grep -E '^host:' "$CLIPROXY_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo '127.0.0.1')"
    log "starting cliproxy (${cliproxy_host}:8317)"
    /usr/local/bin/cliproxy --config "$CLIPROXY_CONFIG" \
      >> "$CLIPROXY_LOG" 2>&1 &
    CLIPROXY_PID=$!
    log "cliproxy pid=$CLIPROXY_PID (logs: $CLIPROXY_LOG)"

    # Previously we waited for cliproxy to be listening on :8317 before
    # launching openclaw. In practice cliproxy starts in <1s and openclaw
    # takes 30+ seconds to initialize before its first model call, so the
    # wait is unnecessary. A buggy port-check was hanging the entrypoint
    # indefinitely; dropping the wait avoids that class of bug entirely.
    # If openclaw hits cliproxy before it's listening, it retries with
    # backoff or falls back to the Anthropic provider automatically.
  else
    log "WARN: /usr/local/bin/cliproxy not found; skipping sidecar (install check failed at build?)"
  fi
fi

# ── Hand off to openclaw ───────────────────────────────────────────
log "starting openclaw gateway"
exec node /app/dist/index.js gateway --allow-unconfigured --port 3000 --bind lan
