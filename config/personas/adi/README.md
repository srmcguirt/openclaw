# Adi — Persona Files

This directory holds the persona files for **Adi**, our digital fox assistant.

## What's here

| File | Purpose | Loaded by openclaw? |
|---|---|---|
| `IDENTITY.md` | Core identity override — "you are Adi, not Clawd" | Yes (workspace file) |
| `SOUL.md` | Personality, voice, mannerisms, moods, sports, tea | Yes (workspace file) |
| `AGENTS.md` | Operational rules — how she behaves during real work | Yes (workspace file) |
| `FOXY.md` | Tonal calibration for her fox humor — reference, not a script | Yes (workspace file) |
| `USER.shane.template.md` | Profile template for Shane's instance | No — fill in and rename to `USER.md` on Shane's machine |
| `USER.meg.template.md` | Profile template for Meg's instance | No — fill in and rename to `USER.md` on Meg's machine |
| `BRAND.md` | Avatar, palette, per-surface visual notes | No — human reference only |
| `README.md` | This file | No |

## How these get deployed

Each Fly machine (one for Shane, one for Meg) has a persistent volume with an openclaw workspace at roughly `/data/.openclaw/workspace/`. At boot, the four `.md` files that openclaw reads (`IDENTITY.md`, `SOUL.md`, `AGENTS.md`, `USER.md`) get copied into that workspace if they don't already exist there — or updated if we change the source.

**What differs between machines:**

- `USER.md` — Shane's machine gets the filled-in Shane profile; Meg's machine gets hers. These are the only files that differ.

**What's identical between machines:**

- `IDENTITY.md`, `SOUL.md`, `AGENTS.md` — same Adi, two homes.

## Editing

- `SOUL.md` and `AGENTS.md` are the source of truth for who Adi is and how she behaves. Edit thoughtfully — the files are her.
- Changes to `SOUL.md` should be rare. It's her identity.
- Changes to `AGENTS.md` happen when we learn something new about how she should operate (e.g., "she should always confirm before deleting a calendar event").
- `USER.md` can be updated freely by the person it describes. Adi reads it on every session.

## Before deploying

1. Copy `USER.shane.template.md` → working copy → fill in with Shane.
2. Copy `USER.meg.template.md` → working copy → fill in with Meg.
3. Rename each to `USER.md` (in its machine-specific deploy path, not back into this directory).
4. Do not commit filled-in `USER.md` files to the repo unless we've decided the privacy tradeoff is acceptable. For now: keep them out of git; deploy them to the volume directly.

## Avatar

The fox avatar lives outside this directory (or will, once we commit the image). `BRAND.md` describes where it gets used and what the palette is.
