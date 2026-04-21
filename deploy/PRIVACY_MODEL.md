# Privacy model — single Supabase project with RLS

**Decision (2026-04-20):** Adi's second brain runs on **one Supabase project**, shared between Shane's and Meg's instances, with row-level security (RLS) enforcing per-user isolation.

## What this means

- One Supabase project holds all personal data for both Shane and Meg.
- Every row in every table is tagged with an `owner_id` (either `shane` or `meg`, or `shared` for data explicitly scoped to both).
- RLS policies enforce that Shane's Adi can only read/write rows where `owner_id = 'shane' OR owner_id = 'shared' AND visibility = 'both'`. Same for Meg in reverse.
- The gift-protection firewall is implemented as an RLS rule: rows tagged `sensitive_category = 'gift'` are never visible to the other user's Adi, regardless of any other policy.

## Tradeoff accepted

This is not the architecture I'd recommend for a production multi-tenant system. In a single-project-with-RLS setup:

- A single RLS bug can leak Shane's data into Meg's instance (or vice versa).
- A compromised Supabase service key (used by either Adi) has access to both users' data.
- Sensitive content (Shane's Navy appendix material, disability detail, pastoral content; Meg's gift planning, family confidences) lives in the same physical database as ordinary life logging.

**Mitigations:**

1. **RLS-first schema.** Every table gets an RLS policy before any row is inserted. No policy-less tables exist, ever.
2. **Per-user Supabase service keys.** Shane's Adi uses a key that has been RLS-verified to only see Shane's rows. Meg's Adi uses a separate key. If one is compromised, the other is untouched.
3. **Sensitive-class rows get defense-in-depth.** Gift rows, pastoral rows, and disability-related rows are additionally encrypted at rest with a per-user key held only on that user's Fly machine. RLS failure alone doesn't expose plaintext.
4. **Audit logging on every read.** Supabase logs every row access; we review periodically.
5. **Escape hatch.** If this architecture stops feeling safe, migrating to two projects is a scripted export/import. We have the privilege of time to change our mind.

## When to revisit

Any of these should trigger migrating from one-project-RLS to per-user separate projects:

- Any incident where data crossed the boundary unintentionally.
- Introducing a third user (kids' instances, a family-admin instance, etc.). More users means more RLS surface area.
- Wiring in a new Adi capability (e.g., sub-agents) that calls Supabase from new contexts — each new context is a new RLS audit.
- Any moment where either of us looks at the RLS policies and feels less-than-confident about what they do.

## What lives in this database vs. not

**In Supabase (second brain):**
- Contacts and people
- Interactions, meetings, calls, notes
- Health log (migraines, pain days, sleep) — Shane only, sensitive class
- Gifts and surprise planning — sensitive class per user
- Projects, reminders, anniversaries
- Mirrored Gmail/Calendar/Contacts metadata (Phase 2)

**Not in Supabase:**
- Adi's agent memory (vector recall for conversations) — lives as LanceDB on the Fly volume per user
- Adi's persona files (SOUL, AGENTS, USER, FOXY) — on the Fly volume per user
- Secrets (API tokens, OAuth credentials) — Fly secrets, per app
- Fellwork production data (`plsxseyazhtmgsyynnty`) — separate project, Shane-only access
- Alive Church data (`qdhbsphoadnxopwilscx`) — separate project, Shane's work there, RLS there

The second brain is personal, not institutional. Adi never stores Fellwork customer data or Alive Church pastoral data in the second brain — those live in their own production projects with their own trust boundaries.
