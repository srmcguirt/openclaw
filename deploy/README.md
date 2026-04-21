# Adi — Fly.io deploy artifacts

Everything in this directory is for deploying **Adi** — our personalized openclaw assistant — to Fly.io. Two Fly apps, one per person, fully isolated.

## Architecture

```
┌─────────────────────────┐      ┌─────────────────────────┐
│  adi-shane (Fly app)    │      │  adi-meg (Fly app)      │
│  ────────────────────   │      │  ────────────────────   │
│  Machine: iad           │      │  Machine: iad           │
│  VM: shared-cpu-2x 2GB  │      │  VM: shared-cpu-2x 2GB  │
│  Volume: 10GB /data     │      │  Volume: 10GB /data     │
│                         │      │                         │
│  ┌─ container ─────┐    │      │  ┌─ container ─────┐    │
│  │ openclaw :3000  │────┼──┐ ┌─┼──│ openclaw :3000  │    │
│  │    │            │    │  │ │ │  │    │            │    │
│  │    ▼ loopback   │    │  │ │ │  │    ▼ loopback   │    │
│  │ cliproxy :8317  │    │  │ │ │  │ cliproxy :8317  │    │
│  │ (OAuth sidecar) │    │  │ │ │  │ (OAuth sidecar) │    │
│  └─────────────────┘    │  │ │ │  └─────────────────┘    │
│                         │  │ │ │                         │
│  Workspace:             │  │ │ │  Workspace:             │
│    /data/.openclaw/     │  │ │ │    /data/.openclaw/     │
│      workspace/         │  │ │ │      workspace/         │
│        IDENTITY.md      │  │ │ │        IDENTITY.md      │
│        SOUL.md          │  │ │ │        SOUL.md          │
│        AGENTS.md        │  │ │ │        AGENTS.md        │
│        FOXY.md          │  │ │ │        FOXY.md          │
│        USER.md ←Shane   │  │ │ │        USER.md ←Meg     │
│        USER.shane.*     │  │ │ │        (no appendices)  │
│        MEMORY.md        │  │ │ │        MEMORY.md        │
│                         │  │ │ │                         │
│  Agent memory:          │  │ │ │  Agent memory:          │
│    LanceDB on volume    │  │ │ │    LanceDB on volume    │
│                         │  │ │ │                         │
│  CLIProxy auth:         │  │ │ │  CLIProxy auth:         │
│    /data/cliproxy/auth  │  │ │ │    /data/cliproxy/auth  │
│    (Shane's OAuth       │  │ │ │    (Meg's OAuth         │
│     tokens — Claude.ai, │  │ │ │     tokens)             │
│     ChatGPT, Gemini)    │  │ │ │                         │
└──────────┬──────────────┘  │ │ └──────────┬──────────────┘
           │                 │ │            │
           │           public HTTPS (Fly)    │
           │                 │ │            │
           ▼                 ▼ ▼            ▼
      Slack / Telegram     (channel DMs routed to right agent)
           │                                 │
           └──────────────┬──────────────────┘
                          │
                          ▼
           ┌──────────────────────────────┐
           │  Shared Supabase project     │
           │  (second brain, RLS-scoped)  │
           │  — provisioned in Phase 1b   │
           └──────────────────────────────┘
```

## What lives where

| File | Purpose |
|---|---|
| `Dockerfile.adi` | Thin overlay on openclaw's root `Dockerfile`. Bakes in persona files, CLIProxyAPI binary, and the entrypoint. |
| `entrypoint.sh` | Syncs persona files image → volume, seeds configs on first boot, launches CLIProxyAPI sidecar, then execs openclaw. |
| `fly.shane.toml` | Fly app config for Shane's instance. |
| `fly.meg.toml` | Fly app config for Meg's instance. |
| `openclaw.shane.json` | Base openclaw config for Shane (copied to volume on first boot). Routes model calls through CLIProxyAPI with Anthropic fallback. |
| `openclaw.meg.json` | Base openclaw config for Meg. |
| `cliproxy.config.yaml` | Base CLIProxyAPI config seeded to `/data/cliproxy/config.yaml` on first boot. |
| `secrets.template.txt` | Checklist of `fly secrets set` commands to run per app. |
| `DEPLOY.md` | Step-by-step deploy runbook, including CLIProxyAPI OAuth login step. |
| `PRIVACY_MODEL.md` | Documents the one-Supabase-project-with-RLS decision and the tradeoff. |

## What this doesn't do (yet)

Phase 1a lands Adi live on Fly with Slack, Telegram, and Todoist. **Phase 1b** wires her into the shared Supabase second brain. **Phase 2** adds Google Workspace via MCP.

Each phase has its own deploy notes. See `DEPLOY.md` for the Phase 1a runbook.

## Naming and git safety

- Fly app names are globally unique. `adi-shane` and `adi-meg` may be taken — if so, try `adi-shane-mcguirt` etc. The `fly.*.toml` files set the `app =` field; update both the toml and the volume name if you have to change.
- Filled-in `USER.md` files (with personal context) are `.gitignore`d at the repo root. This directory contains only templates and infrastructure — no secrets, no personal content.
- `fly.toml` files contain no secrets and are safe to commit. Secrets go through `fly secrets set`.
