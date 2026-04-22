# Adi deploy runbook — Phase 1a

This is the step-by-step for deploying Adi to Fly.io for both Shane and Meg. Do them one at a time; run the full sequence for Shane first, confirm working, then repeat for Meg.

**Time estimate:** 45–60 minutes for the first deploy, 20–30 for the second (once you've done it once).

## Before you start — prerequisites

- [ ] **Docker Desktop running locally.** Verify: `docker version`. We do a two-pass local build (upstream openclaw + Adi overlay) and push the image via `--local-only`, so your Docker daemon does the heavy lifting.
- [ ] **`flyctl` installed and logged in.** Verify: `fly version` and `fly auth whoami`.
- [ ] **Fly.io account with a payment method.** Two always-on machines with persistent volumes exceed the free tier (~$15–25/month total).
- [ ] **Slack app for Shane** with Socket Mode enabled and the scopes listed below. **Separate Slack app for Meg.**
- [ ] **Telegram bot for Shane** via @BotFather. **Separate Telegram bot for Meg.**
- [ ] **Todoist API tokens** — one per person. Todoist → Settings → Integrations → Developer.
- [ ] **Anthropic API key.** One key can power both apps (your billing), or two separate keys — your call.
- [ ] **Supabase project provisioned** (you confirmed it exists). You'll need the project URL and a service-role key.
- [ ] **Filled-in `USER.shane.md` and `USER.meg.md`** present in `config/personas/adi/` on your local disk. They're `.gitignore`d, so a fresh checkout won't have them — seed from your secure backup if needed.

### Slack app scopes Adi needs

Bot token scopes: `app_mentions:read`, `channels:history`, `channels:read`, `chat:write`, `groups:history`, `groups:read`, `im:history`, `im:read`, `im:write`, `users:read`. App-level token scope: `connections:write`. Enable Socket Mode.

## Step 1 — Confirm persona files are in place

All Adi persona files should already exist in `config/personas/adi/`. Verify:

```bash
ls config/personas/adi/
# Expected: AGENTS.md BRAND.md FOXY.md IDENTITY.md README.md SOUL.md
#           USER.meg.md USER.shane.md
#           USER.shane.fellwork-appendix.md USER.shane.navy-appendix.md
```

If `USER.shane.md` or `USER.meg.md` are missing, the Docker build will fail by design. Seed them first.

## Step 2 — Update `.gitignore` to protect filled-in personas

The filled-in `USER.*.md` files contain personal context and should stay out of public git. Confirm `.gitignore` has these entries:

```
# Adi — personal profile content
config/personas/adi/USER.shane.md
config/personas/adi/USER.meg.md
config/personas/adi/USER.shane.navy-appendix.md
config/personas/adi/USER.shane.fellwork-appendix.md
```

**Note:** This means the Docker build needs those files on your local disk but they won't travel with `git push`. If you rebuild on a different machine, you'll need to seed them first from a secure channel (1Password vault, encrypted disk, etc.).

## Step 3 — Build the images locally

The Adi deploy uses a **two-pass build**: first build upstream openclaw, then build the Adi overlay that bakes in the persona files and entrypoint.

Fly deploys these by picking up the locally-built image and pushing it to Fly's registry via `--local-only` — no external registry needed. Your Docker daemon does the work.

### 3a. Build the upstream openclaw image

```bash
# From the repo root (c:\git\openclaw)
docker build -t openclaw:local .
```

First build: 5–10 minutes. Subsequent builds cache heavily. Verify:

```bash
docker images openclaw
# Expected:  openclaw  local  <hash>  <recent timestamp>
```

### 3b. Build the Adi overlay images

One image per user. Build both now so Step 4/5 are quick.

```bash
# Shane's image
docker build \
  -f deploy/Dockerfile.adi \
  --build-arg ADI_USER=shane \
  --build-arg UPSTREAM_IMAGE=openclaw:local \
  -t adi-shane:local \
  .

# Meg's image
docker build \
  -f deploy/Dockerfile.adi \
  --build-arg ADI_USER=meg \
  --build-arg UPSTREAM_IMAGE=openclaw:local \
  -t adi-meg:local \
  .
```

Each takes ~30 seconds (just layers on top of the upstream). Verify:

```bash
docker images | grep adi-
# Expected:
#   adi-shane  local  <hash>  <recent>
#   adi-meg    local  <hash>  <recent>
```

**Sanity check the Adi image has the right USER.md baked in:**

```bash
docker run --rm adi-shane:local cat /app/adi-persona/USER.md | head -5
# Expected: "# USER.md — Shane McGuirt"

docker run --rm adi-meg:local cat /app/adi-persona/USER.md | head -5
# Expected: "# USER.md — Meagan McGuirt"

# Confirm Shane has appendices, Meg doesn't:
docker run --rm adi-shane:local ls /app/adi-persona/ | grep appendix
# Expected: USER.shane.fellwork-appendix.md USER.shane.navy-appendix.md

docker run --rm adi-meg:local ls /app/adi-persona/ | grep appendix
# Expected: (nothing — empty result)
```

If either image has the wrong USER.md or Meg's image still carries Shane's appendices, do not proceed. Rebuild and re-verify.

## Step 4 — Deploy Shane's Adi

### 4a. Create the Fly app

```bash
fly apps create adi-shane
```

If `adi-shane` is taken globally, pick another name (e.g. `adi-shane-mcguirt`) and update `deploy/fly.shane.toml`:

```toml
app = "adi-shane-mcguirt"
...
[mounts]
  source = "adi_shane_mcguirt_data"  # keep volume name aligned
```

### 4b. Create the persistent volume

```bash
fly volumes create adi_shane_data \
  --size 10 \
  --region iad \
  -a adi-shane
```

You'll be asked to confirm because single-volume setups aren't HA. Say yes — single-machine is intentional here.

### 4c. Set secrets

Open `deploy/secrets.template.txt`, fill in Shane's real tokens, run each `fly secrets set ... -a adi-shane` line. Verify:

```bash
fly secrets list -a adi-shane
```

You should see all ~10 secrets listed. Values are not shown; names only.

### 4d. Deploy

Fly deploys the locally-built `adi-shane:local` image. `--local-only` pushes from your Docker daemon to Fly's registry — no remote registry credentials needed.

```bash
fly deploy -c deploy/fly.shane.toml \
  --image adi-shane:local \
  --local-only
```

Because we're passing `--image`, Fly skips its own build step. The `[build]` block in `fly.shane.toml` is ignored on this path — it's retained there for documentation and for any future case where you want Fly to build remotely.

First deploy: 3–8 minutes (image push dominates — it's the full openclaw image with Adi layered on, ~1–2 GB). Watch for:
- `✓ pushed image`
- `✓ machine created`
- `✓ passing health checks`

### 4e. Verify

```bash
fly logs -a adi-shane
```

Look for:
- `[adi-entrypoint] synced SOUL.md` (first boot only)
- `[adi-entrypoint] seeded USER.md from image (first boot)`
- `[adi-entrypoint] starting openclaw gateway`
- `[gateway] listening on ws://0.0.0.0:3000`
- `[slack] connected via Socket Mode`
- `[telegram] bot registered`

Hit the health endpoint:

```bash
curl https://adi-shane.fly.dev/healthz
# Expected: 200 OK
```

Open the control UI:

```bash
fly open -a adi-shane
# Use OPENCLAW_GATEWAY_TOKEN to authenticate
```

### 4f. Smoke test from Slack

In Shane's Slack workspace, DM the Adi bot: `hi adi`. She should respond as Adi — fox character, using context from Shane's USER.md. If she introduces herself as "Clawd" or generic, the persona files didn't load; check `fly ssh console -a adi-shane` and `ls /data/.openclaw/workspace/`.

### 4g. Smoke test from Telegram

Message Shane's bot directly. Same expected behavior.

### 4h. Smoke test Todoist

In either Slack or Telegram: `adi, what's in my todoist inbox?` She should call `todoist_inbox` and return the list.

## Step 5 — Deploy Meg's Adi

Same sequence as Step 4, substituting `meg` for `shane`:

```bash
fly apps create adi-meg
fly volumes create adi_meg_data --size 10 --region iad -a adi-meg

# Fill in deploy/secrets.template.txt Meg section, run the fly secrets set -a adi-meg lines

fly deploy -c deploy/fly.meg.toml \
  --image adi-meg:local \
  --local-only

fly logs -a adi-meg
```

Meg's Slack app, Telegram bot, and Todoist token are **different** from Shane's. Do not reuse.

Smoke tests: same as Step 4f/g/h but from Meg's Slack workspace and Telegram chat.

## Step 6 — CLIProxyAPI OAuth logins (per user, one-time)

Adi uses CLIProxyAPI as her **primary** model gateway — it wraps your OAuth-backed Claude.ai / ChatGPT / Gemini sessions and exposes them as an OpenAI-compatible API. This means Adi can run on your existing subscriptions instead of burning paid Anthropic API credits.

Until OAuth is completed, Adi falls back to the paid Anthropic API (via `ANTHROPIC_API_KEY`), so she's functional from first boot — but each conversation costs money. Finish this step early.

### 6a. SSH into Shane's machine

```bash
fly ssh console -a adi-shane
```

### 6b. Check CLIProxyAPI is running

```bash
# Inside the SSH session:
curl -s http://127.0.0.1:8317/health || curl -s http://127.0.0.1:8317/
# Expect a response (may be 200, 404, or JSON — anything non-error means it's up).

tail -n 50 /data/cliproxy/cliproxy.log
# Expect startup logs, no repeated crash/restart loops.
```

If it's not running, check `/data/cliproxy/config.yaml` and `/data/cliproxy/cliproxy.log`. Usual culprit: permissions on `/data/cliproxy/auth`.

### 6c. Run OAuth login for each provider you want to use

CLIProxyAPI ships interactive login subcommands. Inside the SSH session:

```bash
# Claude.ai (uses Shane's Claude.ai Pro session)
cliproxy --config /data/cliproxy/config.yaml login claude

# ChatGPT (uses Shane's ChatGPT Plus session)
cliproxy --config /data/cliproxy/config.yaml login openai

# Gemini (uses Shane's Google account)
cliproxy --config /data/cliproxy/config.yaml login gemini
```

Each command prints a URL. Open the URL on your laptop, sign in with **Shane's** account, paste the resulting token/code back into the SSH session as prompted. Tokens land in `/data/cliproxy/auth/` on the volume and persist across redeploys.

**Important:** you're logging in as Shane on Shane's machine. Do **not** use Meg's accounts here.

### 6d. Verify routing

From Slack or Telegram, ask Adi something substantive enough that she'll call the LLM. Then inside the SSH session:

```bash
tail -n 100 /data/cliproxy/cliproxy.log | grep -iE "claude|openai|gemini"
```

You should see the proxy receiving and forwarding the request. If Adi is still routing through paid Anthropic (check openclaw logs for `anthropic` vs `cliproxy`), the OAuth token may have failed; re-run the login.

### 6e. Repeat for Meg

```bash
fly ssh console -a adi-meg

# Then inside Meg's session:
cliproxy --config /data/cliproxy/config.yaml login claude
cliproxy --config /data/cliproxy/config.yaml login openai
cliproxy --config /data/cliproxy/config.yaml login gemini
```

**Using Meg's accounts this time.** Shane's and Meg's OAuth tokens live on different Fly volumes and never cross.

### Notes on CLIProxyAPI

- **ToS gray zone.** Claude.ai and ChatGPT aren't designed to be automated this way. Personal-use deployments rarely trip anything, but be aware: commercial use of this proxy would be a different conversation.
- **Session expiry.** OAuth sessions eventually expire. When Adi starts falling back to paid Anthropic, re-run the matching `cliproxy login` command.
- **Port is internal.** The proxy binds to `127.0.0.1:8317` inside the container. Nothing external can reach it; only openclaw (in the same container) calls it.

## Step 7 — Post-deploy hardening (recommended)

### 6a. IP allowlist the control UI

The control UI at `https://adi-shane.fly.dev/` is auth-protected but still discoverable. Optionally restrict by IP:

```bash
# Find your current public IPv4
curl -4 ifconfig.me

# Release default public IPs
fly ips release <ipv4> -a adi-shane
fly ips release <ipv6> -a adi-shane

# Reallocate shared IPv4 + private IPv6
fly ips allocate-v4 --shared -a adi-shane
fly ips allocate-v6 --private -a adi-shane
```

After this, access the control UI via `fly proxy 3000:3000 -a adi-shane` on localhost:3000. Slack/Telegram still work because they use outbound Socket Mode / long-polling, no inbound webhook.

Repeat for adi-meg.

### 6b. Set up automated deploys from the repo

Optional. For now, manual `fly deploy -c deploy/fly.shane.toml` / `fly.meg.toml` keeps things simple.

### 6c. Backup strategy

Fly volumes are durable but not backed up. Options:
- **Snapshot to another volume**: `fly volumes snapshots create <volume-id>`.
- **Rsync sensitive files** (`USER.md`, `MEMORY.md`) to your local machine periodically.
- **Accept risk** for Phase 1a; revisit once the second brain is on Supabase (which is backed up by Supabase).

## Step 7.5 — Tailscale family relay (optional, post-Phase-1a)

This step is **optional** and is NOT required for Phase 1a to work. Meg's Adi runs fine on her own Anthropic API key alone (`openclaw.meg.json` has `anthropic/*` in her fallback list). This step wires her box to route AI inference through Shane's CLIProxyAPI sidecar over a private Tailscale mesh — so she uses Shane's Claude.ai OAuth instead of burning Anthropic API credits.

**When to do this:** After both boxes are live and smoke-tested. Skipping it entirely is fine.

**What it does:**
- Adds a Tailscale mesh between `adi-shane` and `adi-meg` Fly machines.
- Meg's openclaw sends model calls to `http://adi-shane.<tailnet>.ts.net:8317/v1` instead of her own loopback.
- Shane's CLIProxyAPI sidecar (previously loopback-only) also binds the Tailscale interface.
- Adi-on-Shane's-box gains the ability to query Meg's gateway status (health, channels, sessions) over the mesh.
- Public internet never sees the inference traffic — it rides WireGuard.

**ToS note (repeats from Step 6):** routing two humans' traffic through one Claude.ai OAuth session is in a gray zone. Anthropic has flagged similar patterns before. Shane's Claude Max account also powers his personal coding — if it's suspended, that breaks too. If you consider this risk unacceptable, skip this section and leave Meg on her own Anthropic API key.

### 7.5a. Mint a Tailnet and find your tailnet domain

If you don't already have a Tailscale account: sign up at [tailscale.com](https://tailscale.com). Free personal tier is fine.

Find your tailnet's MagicDNS domain:

- Tailscale admin → DNS → **Tailnet name**. Looks like `tail1abcd.ts.net` or `your-name.github.ts.net`.

Note this value — you'll set it as `TAILNET_DOMAIN` later.

### 7.5b. Apply the ACL

**Before** you mint any auth keys. The ACL creates the `tag:fly-gw` tag; auth keys that use a tag fail if the tag isn't defined.

1. Open `deploy/tailscale-acl.json` in this repo.
2. Strip the `//` comments (Tailscale's editor accepts HuJSON but paste-of-record should be clean JSON — easiest: `node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('deploy/tailscale-acl.json','utf8').replace(/\/\/[^\n]*\n/g,'\n').replace(/,(\s*[}\]])/g,'$1')), null, 2))"` or just hand-strip them).
3. Tailscale admin → **Access Controls** → paste → **Save**.
4. Tailscale runs the test assertions in the ACL on save. If save fails, the error message tells you which rule assertion failed — fix and retry. The tailnet is not updated until save succeeds.

### 7.5c. Mint auth keys

One key per Fly app. Each must be **reusable, non-ephemeral, pre-approved, tagged `tag:fly-gw`**. Do NOT reuse one key for both — independent keys = independent revocation.

1. Tailscale admin → **Settings** → **Keys** → **Generate auth key**.
2. Set: Reusable ✓, Ephemeral ✗, Pre-approved ✓, Tags: `tag:fly-gw`.
3. Copy the key (starts `tskey-auth-`). Tailscale shows it exactly once.
4. Repeat for the second app.

Set the keys as Fly secrets (see `deploy/secrets.template.txt` for the exact commands):

```bash
fly secrets set TAILSCALE_AUTHKEY=tskey-auth-SHANES_KEY -a adi-shane
fly secrets set TAILSCALE_AUTHKEY=tskey-auth-MEGS_KEY   -a adi-meg
```

### 7.5d. Set the cross-gateway secrets on Meg's app

Meg's box needs three new secrets beyond her original Phase 1a set:

```bash
# (1) Shane's tailnet IP (for cliproxy baseUrl). We use a raw IP rather
#     than MagicDNS because Fly containers don't support Tailscale's
#     DNS takeover. Non-ephemeral keys + persistent state keep this
#     stable across redeploys.
#
#     After Shane's first deploy, grab his IP:
fly ssh console -a adi-shane -C "tailscale --socket=/data/tailscale/tailscaled.sock ip -4"
#     Typical value looks like 100.111.92.71.
fly secrets set SHANE_TAILNET_IP=100.111.92.71 -a adi-meg

# (2) The CLIProxyAPI key Shane's box uses — both sides MUST match.
#     Grab it from Shane's machine first:
fly ssh console -a adi-shane
cat /data/cliproxy/current-api-key      # copy the value
exit

# Then on your laptop:
fly secrets set CLIPROXY_API_KEY=<value-you-just-copied> -a adi-meg
```

### 7.5e. Set the cross-gateway status token on Shane's app

Adi-on-Shane's-box will use this token to query Meg's gateway:

```bash
# Grab Meg's OPENCLAW_GATEWAY_TOKEN (it's the one you already set in Step 4c).
# If you didn't save it when you first ran `fly secrets set`, Fly doesn't
# show secret values, so you'll need to rotate: set a new token on Meg's
# app, then set the SAME value as ADI_MEG_GATEWAY_TOKEN on Shane's app.

fly secrets set OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32) -a adi-meg
# Copy the value shown in your shell history, then:
fly secrets set ADI_MEG_GATEWAY_TOKEN=<same-value> -a adi-shane
```

### 7.5f. Deploy with the new image

The Dockerfile and entrypoint need updated to install `tailscaled`, run it as a background process before the openclaw gateway, and for Shane's box, rebind CLIProxyAPI to `0.0.0.0:8317`. Those changes are tracked separately — confirm they're landed before redeploying.

Rebuild and redeploy both apps:

```bash
docker build -t openclaw:local .
docker build -f deploy/Dockerfile.adi --build-arg ADI_USER=shane \
  --build-arg UPSTREAM_IMAGE=openclaw:local -t adi-shane:local .
docker build -f deploy/Dockerfile.adi --build-arg ADI_USER=meg \
  --build-arg UPSTREAM_IMAGE=openclaw:local -t adi-meg:local .

fly deploy -c deploy/fly.shane.toml --image adi-shane:local --local-only
fly deploy -c deploy/fly.meg.toml   --image adi-meg:local   --local-only
```

### 7.5g. Verify the mesh

Both machines should appear in your Tailscale admin's **Machines** tab as `adi-shane` and `adi-meg`, both tagged `tag:fly-gw`, both showing as connected.

From Shane's machine:

```bash
fly ssh console -a adi-shane
tailscale status        # Expect: your own node + adi-meg listed as peer
tailscale ping adi-meg  # Expect: "pong ... via DERP" or "via <ip>" — both fine
```

From Meg's machine, confirm she can reach Shane's CLIProxyAPI:

```bash
fly ssh console -a adi-meg
# Using the CLIPROXY_API_KEY that both sides share:
curl -s -H "Authorization: Bearer $CLIPROXY_API_KEY" \
  "http://adi-shane.$TAILNET_DOMAIN:8317/v1/models" | head -20
# Expect: JSON listing claude-sonnet-4-6, claude-opus-4-6, etc.
```

### 7.5h. Verify routing end-to-end

DM Meg's Adi in Slack or Telegram. She should respond. Then check which provider handled it:

```bash
# Should show the request fan out to Shane's tailnet URL:
fly logs -a adi-meg | grep -iE "cliproxy|adi-shane"

# On Shane's box, the CLIProxyAPI logs should show a request from
# Meg's tailnet IP:
fly ssh console -a adi-shane
tail -n 50 /data/cliproxy/cliproxy.log
# Expect: request lines with source IP = Meg's 100.x.x.x
```

If Meg's logs show `anthropic/*` instead of `cliproxy/*`, the relay didn't reach — she fell back to her own Anthropic API. Troubleshoot in order:

1. `tailscale status` on both sides — are both nodes online?
2. ACL — is the `meg → shane:8317` rule present? Did the Tailscale test assertions pass?
3. `CLIPROXY_API_KEY` — is the value on Meg's box identical to Shane's? Whitespace-sensitive.
4. `TAILNET_DOMAIN` — does it match your tailnet's MagicDNS suffix exactly?

### 7.5i. Operational notes

- **Auth key rotation:** mint a new key in Tailscale admin → `fly secrets set TAILSCALE_AUTHKEY=... -a <app>` → `fly machine restart <machine-id>`. Old key keeps working until you delete it in the admin.
- **Revoke Meg:** Tailscale admin → **Machines** → adi-meg → **Disable**. Meg's openclaw immediately falls back to Anthropic (per her fallback list).
- **If Shane's Claude.ai OAuth is suspended:** Shane's own CLIProxyAPI stops working, which means Meg's relay stops working, which means both of your Adis fall back to Anthropic. Neither is dead — both just get more expensive.
- **Do not add this to `/healthz`:** a full model round-trip belongs in a separate deeper health check, not the Fly liveness probe.

### 7.5j. Known quirks learned during this deploy

- **CGNAT/SSRF guard:** openclaw's fetch guard blocks 100.64.0.0/10 (RFC 6598, where Tailscale lives) by default. `models.providers.cliproxy.request.allowPrivateNetwork: true` is the per-provider opt-in that lets this work. Already baked into `deploy/openclaw.meg.json` — don't remove it.
- **Userspace-networking mode is a dead end for openclaw.** We tried `tailscaled --tun=userspace-networking` + `--outbound-http-proxy-listen=127.0.0.1:1055` + `request.proxy.url` on the provider. `curl --proxy ...` works correctly via this setup. openclaw's undici ProxyAgent does NOT — every call fails with "network connection error" and falls through to Anthropic fallback. We haven't root-caused the undici+ProxyAgent+Tailscale-userspace interaction; the fix was to switch to TUN mode.
- **TUN mode requires root startup.** Our entrypoint now starts as `root`, brings up `tailscaled` with native `/dev/net/tun` access (Fly Firecracker microVMs expose it), then `runuser -u node -- exec` openclaw to drop privilege. Final Dockerfile ends with `USER root` (not `USER node`); the entrypoint does `chown -R node:node /data` on every boot so any `fly ssh console` root-owned artifacts self-heal.
- **No MagicDNS on Fly containers:** Fly refuses tailscaled's DNS takeover (`getting OS base config is not supported`). `--accept-dns=true` partially corrupts the resolver config. We use raw tailnet IPs instead; `SHANE_TAILNET_IP` secret carries Shane's 100.x IP.
- **Do NOT set HTTP_PROXY globally:** it routes ALL outbound (Slack/Telegram/Anthropic) through the tailnet proxy and stalls everything.
- **openclaw's `/v1/chat/completions` endpoint is disabled by default.** To reproduce the e2e smoke-test, enable it on Meg's volume with a `fly ssh console` node one-liner, restart, test, then disable.
- **memory-core is disabled on BOTH boxes.** It hangs gateway startup if it needs to build an index. Don't re-enable without a plan.

### 7.5k. How to verify the relay actually works

Log-count diff on Shane is the ground truth (openclaw's `provider=cliproxy` in error logs reports the *attempted* provider, not what actually served the response):

```bash
# Before:
fly ssh console -a adi-shane -C "wc -l /data/cliproxy/cliproxy.log"
# Fire a request via Meg's /v1/chat/completions (endpoint must be enabled).
# After:
fly ssh console -a adi-shane -C "wc -l /data/cliproxy/cliproxy.log"
# Count MUST grow for each successful relay. Also check openclaw logs:
fly logs -a adi-meg --no-tail | grep model-fallback
# Expect: decision=candidate_succeeded candidate=cliproxy/... (NOT anthropic/...)
```



Once both machines are running and you've verified Adi works for both of you, we move to Phase 1b:

1. Provision the Supabase schema (tables, RLS policies, views).
2. Wire Adi tools that talk to Supabase.
3. Deploy Adi updates that let her log interactions, note gifts, journal, etc.

See `deploy/PHASE_1B.md` (to be written once Phase 1a is running).

## Troubleshooting

### Build fails with "USER.shane.md: no such file or directory"

The filled-in `USER.md` files aren't in the local checkout. They're `.gitignore`d, so they don't arrive via `git clone`. Seed them from your secure backup, then rebuild.

### Adi responds as "Clawd" not "Adi"

Persona files didn't sync. SSH in and check:

```bash
fly ssh console -a adi-shane
ls /data/.openclaw/workspace/
cat /data/.openclaw/workspace/IDENTITY.md
```

If the workspace is empty or missing files, the entrypoint didn't run or the image doesn't have `/app/adi-persona/`. Check the image:

```bash
fly ssh console -a adi-shane -C "ls /app/adi-persona/"
```

### Slack connects but Adi doesn't respond to DMs

Check Slack app scopes. `im:history`, `im:read`, `im:write` are required for DMs. Reinstall the Slack app after adding scopes.

### Telegram bot is silent

Verify the token is correct and the bot is not already running elsewhere (only one connection per bot token). If you moved the bot from local to Fly, stop the local instance.

### Todoist calls fail with 401

The `TODOIST_API_TOKEN` secret is wrong or missing. `fly secrets list -a adi-shane` should show it; if not, re-run the set command. Then `fly machine restart <machine-id>` to pick up.

### Machine won't start, "No space left on device"

LanceDB filled the 10GB volume faster than expected. Grow it:

```bash
fly volumes extend <volume-id> -s 20 -a adi-shane
```

## What success looks like

- `fly status -a adi-shane` shows a running machine.
- `fly status -a adi-meg` shows a running machine.
- Both of you can DM your respective Slack/Telegram bots and get Adi-the-fox responses.
- Both Adis can read your Todoist inbox.
- Neither Adi can see the other's data (no cross-talk; each volume is physically separate).
- The Supabase project has `SUPABASE_URL` and `SUPABASE_SERVICE_KEY` secrets set on both apps but no tables yet (Phase 1b).

Then we move to Phase 1b.
