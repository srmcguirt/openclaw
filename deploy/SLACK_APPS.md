# Adi — Slack app configuration

Two Slack apps, one per workspace. Same name ("Adi") in both, same brand color, same shared primitive commands, but **different slash command surfaces** reflecting the context each workspace lives in.

## Files

- `slack-app.fellwork.manifest.json` — Fellwork workspace. Shane's company + pastoral + coursework surface.
- `slack-app.broadnax.manifest.json` — Broadnax House workspace. Household + shared discipleship + family logistics surface.

## Why two apps and not one

Slack lets a single app install into multiple workspaces. For most apps, that's the right move. For Adi we went the other way because:

1. The slash commands differ meaningfully by workspace — `/adi-fellwork` and `/adi-regent` don't belong in Broadnax; `/adi-recipe` and `/adi-chore` don't belong in Fellwork.
2. A single-app "one manifest for both installs" would force every command to exist in both workspaces. Forcing symmetry would make the UX worse for both.
3. Two apps means two sets of credentials, which we needed anyway (one per Fly machine — `adi-shane` + `adi-meg`).
4. Slack distribution paperwork is avoided — each app installs natively into its home workspace.

## Shared commands (present in both manifests)

- `/adi` — general chat
- `/adi-task` — create Todoist task
- `/adi-note` — capture to second brain
- `/adi-brief` — on-demand daily brief
- `/adi-who` — look up a person from second brain

## Workspace-specific commands

**Fellwork:**
- `/adi-fellwork` — company operations
- `/adi-ministry` — Shane's Alive pastoral writing, intercessory prayer drafting (§5 confidentiality applies)
- `/adi-regent` — Regent coursework help

**Broadnax:**
- `/adi-discipleship` — Core group, couples group, Philippines trip prep, shared serving
- `/adi-recipe` — recipe API (future)
- `/adi-chore` — chore tracker (future)
- `/adi-schedule` — family schedule — kids, appointments, events
- `/adi-money` — household finance reference (future)

## Settings (both manifests)

- **Socket Mode:** on. No public webhooks needed.
- **Is MCP Enabled:** off. Adi talks to Slack via openclaw's Slack plugin over the bot token, not via Slack's hosted MCP server.
- **App Home:** enabled (empty for now; Phase 2 populates with a dashboard).
- **Interactivity:** on (for button-based approvals on outbound drafts — Phase 1b+).
- **Org deploy:** off.
- **Token rotation:** off for now (enable later if operationally desired; requires handling rotation on the Fly side).

## Scopes

**User scopes (intentionally minimal):**
- `chat:write` — so Adi can post *as you* in approved cases (drafted reply posts in your voice, not the bot's)
- `search:read.public` — public-channel search only

We explicitly removed broader user scopes (`search:read.private`, `search:read.im`, `search:read.files`, `search:read.mpim`, `users:read.email`, canvas read/write). Each of those is re-addable later by editing the manifest and reinstalling; the lean default reduces blast radius if either app-install is ever compromised.

**Bot scopes:** standard messaging, channel, DM, reaction, pin, and user read surfaces. `files:write` is NOT included — add back only if we wire a file-posting workflow.

## How to update a manifest

1. Edit the JSON file here in the repo.
2. Go to https://api.slack.com/apps/<APP_ID>/app-manifest
3. Paste the new manifest content.
4. Slack will prompt you to reinstall if scopes changed. Approve.
5. **Tokens regenerate on reinstall.** Capture the new tokens from "OAuth & Permissions" and "Basic Information" pages.
6. `fly secrets set SLACK_BOT_TOKEN=... -a <app>` and the two other Slack secrets.
7. `fly machine restart -a <app>` to pick up.

## First-time installation

See `deploy/DEPLOY.md` Step 4/5. Summary:

1. **Fellwork manifest:** api.slack.com/apps → Create New App → From a manifest → pick Fellwork workspace → paste `slack-app.fellwork.manifest.json` → Install.
2. **Broadnax manifest:** the existing "Adi" app in Broadnax House already exists — update its manifest with `slack-app.broadnax.manifest.json` → reinstall to apply new scopes + commands.
3. Collect 3 tokens per workspace (bot, app-level, signing secret) → 6 tokens total.
4. Set on respective Fly apps (`-a adi-shane` for Fellwork tokens, `-a adi-meg` for Broadnax tokens).
