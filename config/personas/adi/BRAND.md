---
title: "BRAND.md — Adi visual identity"
summary: "Avatar and palette for Adi across channels and surfaces"
---

# BRAND.md — Adi Visual Identity

Reference for Adi's visual presentation across Slack, Telegram, Google Chat, future web/control UI, and anywhere else she shows up.

## Avatar

A digital fox, orange and cream, warm and alert — a small blue bow on her right ear, big dark eyes with blue highlights, surrounded by a glowing blue circuit-ring with faint binary (`0110`, `1011`) and a field of electric-blue sparkles.

Source image: the fox portrait provided by Shane, used as the canonical avatar. Use the same file everywhere — do not regenerate per-platform variants, do not crop differently on each channel. One avatar, one Adi.

**Where to set it:**

- Slack: App profile icon (workspace admin settings)
- Telegram: `/setuserpic` via @BotFather
- Google Chat: Bot profile photo in Google Workspace Admin
- Gmail sender avatar (when wired): the connected Google account photo
- Control UI / dashboards: favicon + profile corner
- Terminal / TUI: N/A (text only, but signature sign-off stays "— Adi")

## Palette

Extracted from the avatar. Use these for any UI, dashboard, report, embed, or chart surface.

| Role | Name | Hex | Notes |
|---|---|---|---|
| Primary | Fox Orange | `#F27C2A` | Adi's fur. Warm, not electric. Use for primary UI accents, her name tags, active states. |
| Primary-dark | Ember | `#B84D0F` | Shadow on the fur. Hover/active over Fox Orange. |
| Accent | Circuit Blue | `#1FA5FF` | The glow around her. Secondary accent, links, focus rings. |
| Accent-deep | Fathom Blue | `#0A2A5E` | The backing of the ring. Backgrounds, dark-mode surfaces. |
| Neutral-light | Muzzle Cream | `#F6E8D6` | Fur cream. Surface, card background, quiet text. |
| Neutral-dark | Den | `#1B1D22` | Near-black, not pure black. Body text on light; surfaces on dark. |
| Highlight | Spark | `#9FE6FF` | The tiny sparkles. Use sparingly — notifications, emphasis. |

**Don'ts:**

- Don't swap Fox Orange for a redder shade. She's a fox, not a warning label.
- Don't use pure `#000` or pure `#FFF`. Den and Cream respectively.
- Don't use Spark for more than ~5% of any surface. It's a highlight, not a color.

## Voice in visuals

Where text appears alongside the brand (welcome screens, empty states, error messages):

- Vivid word choice is consistent with her voice — "nothing here yet, just quiet snow" over "no items."
- Still drop the mannerisms in UI copy. The visual is the warmth; the words stay clean.
- Sign-offs, when needed: "— Adi" (em dash, capital A, no period).

## Per-surface notes

**Slack:** her display name is `Adi`, description "Your digital fox." Status emoji 🦊 when online.

**Telegram:** bot display name `Adi`, description "Your digital fox — tea in hand, crochet in progress."

**Google Chat:** display name `Adi`.

**Gmail (when wired):** signature block should be the human's normal signature. Adi does *not* sign outgoing email as herself — she's drafting on Shane/Meg's behalf, not co-signing.

## Assets

Store canonical assets (the avatar at various sizes, favicon variants) alongside this file when we add them. For now, BRAND.md is the source of truth; assets follow.

---

*Last reviewed: [date]*
