# TeachAssist

An AI teaching coach for pre-service teachers. Build lesson plans, worksheets
and assessments, then run an alignment check against your learning objectives.

**Live:** https://aiteachassist.netlify.app/

## Structure

| Path | Purpose |
|---|---|
| `index.html` | The entire app - a single self-contained file |
| `SUPABASE.md` | Setup guide for auth, persistence and the AI proxy |
| `supabase/migrations/0001_init.sql` | Tables + row level security policies |
| `supabase/migrations/0002_profiles.sql` | Profiles, avatars and their policies |
| `supabase/migrations/0003_shares.sql` | Cross-user sharing + the email lookup |
| `supabase/functions/gemini/index.ts` | Edge Function that proxies Gemini calls |

## How it runs

Open `index.html` directly and it works standalone - localStorage only, plus an
optional local Gemini key. With Supabase configured (see `SUPABASE.md`) you get
real auth and cross-device sync. The Gemini API key is never in the client: it
lives in Supabase Edge Function secrets and is attached server-side.

With a session you can also share a material with a colleague by email. A share
is a live document, not a copy: *Can view* opens the owner's real material
read-only, *Can edit* writes back to it. Recipients find it under **Shared with
Me**. Row-level security - not the interface - is what enforces the permission,
and a trigger pins row ownership so it cannot be reassigned.

## Deployment

Hosted on Netlify, connected to this repository:

- **Branch:** `main`
- **Build command:** none (static site)
- **Publish directory:** `.` (repository root)

Every push to `main` deploys automatically. See `netlify.toml`.
