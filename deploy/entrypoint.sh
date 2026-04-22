#!/usr/bin/env bash
# entrypoint.sh — runs inside the Adi container on every boot.
#
# Starts as ROOT (required for tailscaled's native TUN mode via
# /dev/net/tun), does root-only setup, then execs into entrypoint-node.sh
# as the `node` user for all user-level work + openclaw itself.
#
# Root phase responsibilities:
#  1. Derive ADI_USER from env or USER.md fallback.
#  2. Ensure /data subdirs exist and are owned by node:node.
#     (Heals any root-owned files left by fly-ssh-console sessions.)
#  3. If TAILSCALE_AUTHKEY is set: start tailscaled in native TUN mode
#     and `tailscale up`. tailscaled stays running as root in the
#     background — the container's kernel + Fly's init manage its
#     lifecycle along with ours.
#  4. exec runuser -u node -- /app/entrypoint-node.sh
#
# The node phase is entirely in entrypoint-node.sh. Keep the two files
# separate so privilege drop is a hard boundary and there's no
# accidental root code run via `su` tricks.

set -euo pipefail

# Resolve ADI_USER. The Dockerfile bakes `ENV ADI_USER=${ADI_USER}` so
# it's normally set. Fall back to inspecting USER.md if the image was
# built without it, to avoid deploys that mismatch user + volume.
ADI_USER="${ADI_USER:-}"
if [[ -z "$ADI_USER" ]]; then
  if [[ -f /app/adi-persona/USER.md ]]; then
    if grep -qi 'shane mcguirt' /app/adi-persona/USER.md 2>/dev/null; then
      ADI_USER="shane"
    elif grep -qi 'meagan\|# USER.md — Meg' /app/adi-persona/USER.md 2>/dev/null; then
      ADI_USER="meg"
    fi
  fi
fi
export ADI_USER

log() { echo "[adi-entrypoint:root] $*"; }

TAILSCALE_DIR="/data/tailscale"
TAILSCALE_STATE="${TAILSCALE_DIR}/tailscaled.state"
TAILSCALE_SOCKET="${TAILSCALE_DIR}/tailscaled.sock"
TAILSCALE_LOG="${TAILSCALE_DIR}/tailscaled.log"

# ── 1/2: dirs + ownership ──────────────────────────────────────────
# /data is a Fly volume mounted as uid 1000 (node) by Fly init, but
# subdirs created by earlier `fly ssh console` sessions may be root-
# owned. Heal defensively on every boot so openclaw-as-node can always
# read+write everything it needs.
mkdir -p \
  /data/.openclaw/workspace \
  /data/.openclaw/agents/main/agent \
  /data/.openclaw/memory \
  /data/cliproxy/auth \
  /data/extensions \
  /data/cron \
  "$TAILSCALE_DIR"

chown -R node:node /data

# Tailscale state dir wants tighter perms (state file contains node key).
chmod 700 "$TAILSCALE_DIR"

# ── 3: tailscaled in TUN mode ──────────────────────────────────────
# Only start if TAILSCALE_AUTHKEY is set — without it, this is a
# standalone deploy and the tailnet relay is irrelevant.
if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
  if [[ -x /usr/local/bin/tailscaled && -x /usr/local/bin/tailscale ]]; then
    tailscale_hostname="adi-${ADI_USER:-unknown}"

    # Ensure /dev/net/tun is available (Fly Firecracker microVMs expose
    # it by default; fail loudly if somehow missing so we don't silently
    # fall back to userspace mode).
    if [[ ! -c /dev/net/tun ]]; then
      log "ERROR: /dev/net/tun not present — TUN mode requires it; check Fly platform"
      log "Continuing without tailnet to avoid hanging the deploy."
    else
      log "starting tailscaled (native TUN mode, hostname=${tailscale_hostname})"
      # No --tun=userspace-networking (default is TUN).
      # No --outbound-http-proxy-listen / --socks5-server: with TUN,
      # normal sockets see 100.x tailnet IPs directly, no proxy hop
      # required.
      /usr/local/bin/tailscaled \
        --state="$TAILSCALE_STATE" \
        --socket="$TAILSCALE_SOCKET" \
        --statedir="$TAILSCALE_DIR" \
        >> "$TAILSCALE_LOG" 2>&1 &
      TAILSCALED_PID=$!
      log "tailscaled pid=$TAILSCALED_PID (logs: $TAILSCALE_LOG)"

      # Wait briefly for the control socket.
      for _ in $(seq 1 20); do
        [[ -S "$TAILSCALE_SOCKET" ]] && break
        sleep 0.5
      done

      if [[ ! -S "$TAILSCALE_SOCKET" ]]; then
        log "WARN: tailscaled socket did not appear after 10s; continuing without tailnet"
      else
        # `tailscale up` is idempotent via the persistent state file.
        # --accept-dns=false stays: Fly's container env refuses DNS
        # takeover, and accept-dns=true partially corrupts resolv.conf.
        # We use raw tailnet IPs (SHANE_TAILNET_IP secret) instead of
        # MagicDNS on this platform.
        if /usr/local/bin/tailscale \
            --socket="$TAILSCALE_SOCKET" \
            up \
            --authkey="$TAILSCALE_AUTHKEY" \
            --hostname="$tailscale_hostname" \
            --advertise-tags=tag:fly-gw \
            --accept-routes=false \
            --accept-dns=false \
            --reset >> "$TAILSCALE_LOG" 2>&1; then
          tailnet_ip="$(/usr/local/bin/tailscale --socket="$TAILSCALE_SOCKET" ip -4 2>/dev/null | head -n1 || true)"
          log "tailscale up OK (tailnet_ip=${tailnet_ip:-unknown})"
        else
          log "WARN: tailscale up failed — see $TAILSCALE_LOG; continuing without tailnet"
        fi
      fi

      # Ownership of tailscaled state files post-`up`: root owns them,
      # which is correct (only tailscaled reads/writes). The `node`
      # user doesn't need access.
    fi
  else
    log "WARN: TAILSCALE_AUTHKEY set but tailscale binaries missing from image"
  fi
else
  log "TAILSCALE_AUTHKEY not set — skipping tailnet (standalone mode)"
fi

# ── 4: drop to node for the rest ───────────────────────────────────
# Exec so PID 1 becomes the node-phase shell (cleaner signal handling).
# runuser is in util-linux (Debian bookworm ships it by default).
log "dropping to node user and execing entrypoint-node.sh"
exec runuser -u node --preserve-environment -- /app/entrypoint-node.sh
