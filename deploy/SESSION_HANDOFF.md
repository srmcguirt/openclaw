# Session Handoff — Adi Deploy (2026-04-21)

> **If you're a new session picking this up:** read this file first, then skim `DEPLOY.md` (deploy runbook), `PRIVACY_MODEL.md` (architecture rationale), and `README.md` (file inventory). Check `git log --oneline -5` to see recent commits. You should be able to pick up cleanly without me briefing you.

Last updated: 2026-04-21, end of second working session. Operator stepped away due to cognitive fatigue from two long debug cycles; handing off cleanly is the right move.

---

## TL;DR — what's running, what's broken, what's next

**Running fine right now:**
- Shane's Adi (`adi-shane`) — Slack + Telegram + Todoist + cliproxy (OAuth just re-authed, works)
- Meg's Adi (`adi-meg`) — Slack (working as of her last confirmed test)

**Known broken (non-blocking):**
- **Meg's Telegram** keeps re-issuing pairing codes despite correct `allowFrom` entries in both the repo config and the on-disk allowlist (`/data/credentials/telegram-default-allowFrom.json` with user ID `8636712032`). We spent a long time on it. Final theory: stale in-memory allowlist cache that doesn't re-read after approval, and our fresh-config reseed didn't propagate correctly on the last restart. See **Known quirks** below.

**Not done yet:**
- **Tailnet family relay deploy** (§7.5 in DEPLOY.md). Designed + image-ready + config-ready. Needs operator actions: create tailnet, apply ACL, mint 2 auth keys, set 4 Fly secrets, rebuild both images, redeploy. ~60–90 min of focused operator work.

**Parked (do NOT retry without plan):**
- **gbrain integration.** Tried `openclaw plugins install /opt/gbrain` — fails because gbrain's `openclaw.plugin.json` uses `family: bundle-plugin` format but openclaw's installer expects `openclaw.extensions` in `package.json`. The proper integration path is via gbrain's **MCP server** (`mcpServers.gbrain` in its manifest), which requires different wiring. Supabase data is intact; client is absent. Don't retry the plugins-install path — it's a dead end.

---

## Current git state

**Last commit:** `9f4329231e` — `feat: Adi personas + Fly deployment + tailnet relay (Phase 1a)`

25 files, 2929 insertions. Working tree clean. This commit contains everything that should be in git; filled-in `USER.*.md`, memory appendices, and filled-in `USER.shane.*` files are all correctly `.gitignore`d.

Check: `git log --oneline -5` and `git status` should show clean tree.

---

## What's on Fly right now

Both apps in `personal` org, both `iad`, both 4GB memory (bumped up from 2GB after OOM-during-first-boot issue on Meg).

### adi-shane (`287397eae6e508`, version 16)

- Volume `adi_shane_data` — 10GB, populated with workspace, memory files, cliproxy auth, `openclaw.json`
- Secrets set: `OPENCLAW_GATEWAY_TOKEN`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` (for gbrain embeddings), `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_SIGNING_SECRET`, `TELEGRAM_BOT_TOKEN`, `TODOIST_API_TOKEN`, `SUPABASE_URL`, `SUPABASE_SERVICE_KEY`, `CLIPROXY_API_KEY`, `GBRAIN_DATABASE_URL`
- **Missing (for tailnet):** `TAILSCALE_AUTHKEY`, `ADI_MEG_GATEWAY_TOKEN`
- cliproxy OAuth freshly re-authed earlier today; `/data/cliproxy/auth/claude-srmcguirt@gmail.com.json` is the live token
- Primary model route: `cliproxy/claude-sonnet-4-6` → Shane's Claude.ai Pro OAuth
- Fallback: `anthropic/claude-sonnet-4-6` (paid API)
- Todoist plugin installed to volume via `openclaw plugins install openclaw-todoist-plugin` — persisted at `/data/extensions/todoist/`
- Residual cruft in on-disk `openclaw.json`: `plugins.allow` contains `"gbrain"`, `plugins.entries.gbrain` exists — from earlier failed integration attempt. Warns on every boot but is harmless ("plugin not found: gbrain"). Will clean up on next redeploy.

### adi-meg (`6839617fed0968`, version ~7)

- Volume `adi_meg_data` — 10GB, populated
- Secrets set: same list as Shane minus gbrain-specific ones; has `CLIPROXY_API_KEY` set but no cliproxy OAuth (no Claude.ai login on her side — the tailnet design routes her through Shane's)
- **Missing (for tailnet):** `TAILSCALE_AUTHKEY`, `TAILNET_DOMAIN`
- Primary model route: `anthropic/claude-sonnet-4-6` direct (paid API). **Will become** `cliproxy/claude-sonnet-4-6` over tailnet when deploy happens.
- `memory-core` disabled in her config (was hanging gateway startup with embedding-index CPU burn; disable was the fix that let her deploy at all).
- Telegram allowlist has her user ID `8636712032` on disk but gateway isn't respecting it — see Known quirks.

### Volumes — what NOT to wipe

- `/data/.openclaw/workspace/` — persona files (IDENTITY/SOUL/AGENTS/FOXY/USER.md) live here. Entrypoint re-syncs IDENTITY/SOUL/AGENTS/FOXY from image on every boot; USER.md is first-boot-seed-only.
- `/data/.openclaw/agents/main/agent/` — per-agent state including `auth-profiles.json`
- `/data/cliproxy/` — Shane only. cliproxy config + OAuth tokens. **Do NOT delete `/data/cliproxy/auth/`** unless you want to force re-OAuth-login.
- `/data/credentials/` — pairing allowlists (`slack-default-allowFrom.json`, `telegram-default-allowFrom.json`)
- `/data/openclaw.json` — the live gateway config. Entrypoint only seeds this on first boot; volume version is authoritative. To force re-seed: delete it then restart the machine.

---

## Two Slack apps, two workspaces

- **Fellwork Slack** → "Adi (Fellwork)" app → routes to `adi-shane`
- **Broadnax House Slack** → "Adi" (original app) → routes to `adi-meg`

Both manifests committed at `deploy/slack-app.fellwork.manifest.json` and `deploy/slack-app.broadnax.manifest.json`. Manifests differ — Fellwork has `/adi-fellwork`, `/adi-ministry`, `/adi-regent` slash commands; Broadnax has `/adi-discipleship`, `/adi-recipe`, `/adi-chore`, `/adi-schedule`, `/adi-money`.

Users:
- Shane's Slack user ID (Fellwork): `U0ATMP4SGDD` — locked in `deploy/openclaw.shane.json`
- Meg's Slack user ID (Broadnax): `U0ATQKX5ZGD` — locked in `deploy/openclaw.meg.json`
- Shane's Telegram user ID: `7559901218` — locked
- Meg's Telegram user ID: `8636712032` — locked in config, flaky in live gateway

---

## Pending operator actions — tailnet deploy

Follow `deploy/DEPLOY.md §7.5` step-by-step. High-level sequence:

1. Create Tailscale tailnet (if not already created)
2. **Apply ACL** (`deploy/tailscale-acl.json`) BEFORE minting auth keys — the ACL defines the `tag:fly-gw` tag that the auth keys will claim. Keys minted before ACL apply are silently broken at node-join time.
3. Mint **two** auth keys with tag `tag:fly-gw` — separate keys for independent revocation. Settings: reusable=YES, ephemeral=NO, pre-approved=YES.
4. Set 4 Fly secrets:
   - `fly secrets set TAILSCALE_AUTHKEY=<shane-key> -a adi-shane`
   - `fly secrets set TAILSCALE_AUTHKEY=<meg-key> -a adi-meg`
   - `fly secrets set TAILNET_DOMAIN=<your-tailnet>.ts.net -a adi-meg`
   - `fly secrets set CLIPROXY_API_KEY=<shane-current-key> -a adi-meg` (must match Shane's)
   - `fly secrets set ADI_MEG_GATEWAY_TOKEN=<meg-OPENCLAW_GATEWAY_TOKEN> -a adi-shane`
5. Rebuild both images (Docker context already has Tailscale in Dockerfile.adi):
   ```
   docker build -t openclaw:local .
   docker build -f deploy/Dockerfile.adi --build-arg ADI_USER=shane --build-arg UPSTREAM_IMAGE=openclaw:local -t adi-shane:local .
   docker build -f deploy/Dockerfile.adi --build-arg ADI_USER=meg --build-arg UPSTREAM_IMAGE=openclaw:local -t adi-meg:local .
   ```
6. Redeploy both:
   ```
   fly deploy -c deploy/fly.shane.toml --image adi-shane:local --local-only
   fly deploy -c deploy/fly.meg.toml --image adi-meg:local --local-only
   ```
7. Smoke test: `fly logs -a adi-meg | grep -iE "cliproxy|adi-shane"` should show Meg routing to Shane's tailnet hostname.

**Side effect we expect:** Meg's Telegram allowlist quirk likely resolves after this deploy because it rebuilds her volume state from fresh config.

---

## Known quirks / things NOT to waste time on

### Fly SSH "Error: The handle is invalid"

Windows Git Bash SSH shell exit produces this error *after* the command completed successfully. The command output before it is real; ignore the error. Don't debug it. It does not affect the command's result.

### Meg's Telegram allowlist

Approving a Telegram pairing code writes the user ID to `/data/credentials/telegram-default-allowFrom.json` but the running gateway keeps issuing new codes on next DM. We tried:
- Approving the code multiple times ✗
- Restarting the machine ✗
- Deleting `/data/openclaw.json` and restarting to force re-seed ✗ (didn't appear to trigger fresh-seed log)

Slack works for her; Telegram doesn't. **Don't spin on this**. Next rebuild+redeploy (tailnet deploy) is expected to resolve it as a side effect. If it doesn't after tailnet deploy, look at openclaw's Telegram plugin session-key generation to see if it's caching the provider's `allowFrom` in memory and never re-reading the disk file.

### gbrain integration

`openclaw plugins install /opt/gbrain` fails with:
```
blocked plugin candidate: suspicious ownership (uid=1000, expected uid=0 or root)
package.json missing openclaw.extensions
```

gbrain uses `family: bundle-plugin` with its own manifest file, not openclaw's `package.json` extension list. **Don't retry this path.** The correct integration is via MCP — gbrain's manifest has `mcpServers.gbrain` pointing at `./bin/gbrain serve`. Future session: look at how openclaw registers external MCP servers (not plugins) and wire gbrain that way. Dockerfile comment in `Dockerfile.adi` documents this.

### Fly SSH interactive flows

`fly ssh console -a <app>` interactive mode is *unreliable* on Windows — handles get invalidated. For interactive work (cliproxy OAuth login, openclaw pairing approve with prompts), **use PowerShell or CMD, not Git Bash**. One-shot `-C "command"` invocations work in Git Bash though.

### Fly "could not find a good candidate within 40 attempts at load balancing"

Noise during restart/deploy cycles. Not actionable. Ignore unless it persists >2 min after a deploy lands.

### cliproxy `401 Invalid authentication credentials`

If openclaw falls back to paid Anthropic and logs this, it means the Fly secret `CLIPROXY_API_KEY` doesn't match the key in cliproxy's volume config (`/data/cliproxy/config.yaml`, field `api-keys`). Fix: read the current key via `fly ssh console -a adi-shane -C "grep api-keys -A1 /data/cliproxy/config.yaml"`, then `fly secrets set CLIPROXY_API_KEY=<that value> -a adi-shane`. Both must agree or auth fails.

### cliproxy `503 auth_unavailable: no auth available`

Different from 401. This means cliproxy has no Claude.ai OAuth session (token expired or invalidated). Fix: re-run OAuth login per DEPLOY.md §6.

---

## What worked — capture the wins before forgetting

- **4GB memory per Fly machine** (was 2GB). Fixed a real OOM-during-startup problem on Meg that looked like "hanging."
- **`memory-core` disabled on Meg** only. Don't enable until we understand why it hung her gateway at startup. Shane's works — unclear what's different.
- **Seed-once entrypoint for `openclaw.json`** — don't make it always-sync; openclaw rewrites the config itself with migration metadata. Always-sync fights openclaw's own writes. Seed-once lets the volume version be authoritative.
- **`allowFrom` baked into repo config** — better than relying on runtime pairing approval for per-user deploys. Pairing is useful for bootstrap/discovery; `allowFrom` is durable.
- **Agent ID `main`** — not custom IDs like `shane`/`meg`. The bundled plugin auto-auth logic is wired to `main`. Custom IDs require manually bootstrapping auth profiles per agent — fragile.
- **`claude-sonnet-4-6` not `claude-opus-4-7`** — the 4-7 name isn't in openclaw's canonical model list. Using it causes "Unknown model" errors. 4-6 is the current Opus; Sonnet 4-6 is the lighter/faster option.

---

## Next-session starting checklist

If you're picking this up in a new session:

1. `git log --oneline -5` — confirm `9f4329231e` is the head or near it
2. `git status` — confirm clean working tree
3. `fly status -a adi-shane && fly status -a adi-meg` — confirm both machines healthy
4. `curl https://adi-shane.fly.dev/healthz && curl https://adi-meg.fly.dev/healthz` — both should return `{"ok":true}`
5. Confirm with operator whether Meg's Telegram is still issuing pairing codes on fresh DMs (may have self-healed)
6. Ask operator whether we're proceeding with tailnet deploy (DEPLOY.md §7.5) or something else

Then either drive DEPLOY.md §7.5 with operator, or address whatever the operator raises first.

---

## Honest handoff notes

**What went well:** Fly + Docker + openclaw integration took some iteration but all the fundamentals work. Both machines are stable. Persona files are cleanly architected with lean-workspace-plus-memory-files design. Config is git-committed.

**What went poorly:** Meg's Telegram allowlist issue genuinely unresolved. gbrain detour burned ~90 min on a dead-end plugin-install path before concluding MCP is the right integration. Fly SSH flakiness on Windows produced many false-fail signals.

**What I'd do differently starting from scratch:** (a) not attempt gbrain via `plugins install`, go straight to MCP server wiring; (b) set 4GB from day one; (c) bake `allowFrom` into repo config before first deploy so pairing is purely ceremonial.

**Operator (Shane) observations:**
- Doing real architectural work with a spouse's instance that'll see real use
- Ships strong taste calls quickly (chose option B before I could make the case), tolerant of diagnostic uncertainty but impatient with performative caveats
- Has a second agent doing tailnet work in parallel — respect their file ownership scope during their sessions (Dockerfile.adi, entrypoint.sh, openclaw.meg.json, cliproxy.config.yaml, DEPLOY.md, secrets.template.txt, tailscale-acl.json)

Don't re-brief unless asked. Read the code; ask clarifying questions only when scope is ambiguous.
