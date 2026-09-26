# TeachAssist - Supabase setup

Phase 2 adds real auth and cross-device persistence. Everything is written
so the app still runs standalone: **if you skip all of this, `index.html`
behaves exactly as it did in Phase 1** (localStorage only, plus the local
Gemini dev key).

Your project is already referenced in `index.html`:

```
SUPABASE_URL      https://sprwgppmyifpjykfaasq.supabase.co
SUPABASE_ANON_KEY sb_publishable_9BTuhMYQ9fEuBQk1lKko_w_Ha13cr1m
```

Those two values are public by design - row level security is the actual
security boundary. Your **Gemini key must never go into `index.html`.**

There are three steps, in order. Each one is a paste.

---

## Step 1 - Allow email sign-in without a confirmation link

**Authentication -> Sign In / Providers -> Email -> "Confirm email" -> off**

Leave the **Email** provider itself enabled (it is on by default).

Without this, signing up returns a user with no session and the app will
ask you to confirm your inbox first - fine in production, annoying while
testing.

---

## Step 2 - Create the tables

**SQL Editor -> New query** -> paste the entire contents of
[`supabase/migrations/0001_init.sql`](supabase/migrations/0001_init.sql) -> **Run**.

Then repeat with
[`supabase/migrations/0002_profiles.sql`](supabase/migrations/0002_profiles.sql).

You should see `Success. No rows returned` both times.

What this creates:

| Table | Mirrors | Key |
|---|---|---|
| `public.drafts` | `ta_materials` (My Materials cards) | `(user_id, scope)` |
| `public.autosave` | `ta_autosave::<scope>` (workspace contents) | `(user_id, scope)` |
| `public.profiles` | Account Settings (name, description, avatar) | `user_id` |

`drafts` and `autosave` have RLS enabled with an `auth.uid() = user_id`
policy, so a signed-in user can only ever touch their own rows. `profiles` is
readable by **any** signed-in user - that is what makes *Shared by ...* work -
but only writable by its owner.

The second file also creates the public **`avatars`** storage bucket. Its
policies key off the object path: you may only write inside your own
`<user_id>/` folder, and the bucket is readable by anyone (a picture is not
private). If Storage is ever unavailable the app stores a downscaled copy of
the picture in `profiles.avatar_url` instead, so the feature never breaks.

**You can skip this step safely.** If the tables are missing the client
detects `PGRST205`, logs one console warning, sets the header chip to
"Local only" and keeps working from localStorage.

---

## Step 3 - Deploy the Gemini proxy

**Edge Functions -> Create a function** -> name it exactly **`gemini`**
-> paste the entire contents of
[`supabase/functions/gemini/index.ts`](supabase/functions/gemini/index.ts)
-> save/deploy.

Then two settings on the same function:

1. **Verify JWT -> off.** The gateway would otherwise answer the browser's
   `OPTIONS` preflight with a 401 and the real request would never be sent.
   This does not expose anything: the function re-checks the caller's
   session itself before touching the API key.

2. **Secrets -> add `GEMINI_API_KEY`** (Settings -> Edge Functions -> Secrets,
   or the Secrets tab on the function).
   Get the value from [aistudio.google.com](https://aistudio.google.com) -> *Get API key*.

> If you ever publish this project or share the chat where that key was
> pasted, rotate it there - you only need to update the secret, never a file.

### What the function does

- rejects callers with no valid session (`401`)
- attaches `GEMINI_API_KEY` server-side - the key never reaches the browser
- owns the retry chain (`gemini-3.6-flash` -> `gemini-3.5-flash` ->
  `gemini-3.5-flash-lite`, exponential backoff, 24s budget) that used to run
  in the browser, so one page load makes one round trip
- returns Google's payload unchanged, so the client parses it exactly as before
- translates Google's `401/403` (a bad *server* key) into `502`, so the
  browser never confuses it with an expired session
- full CORS, including the `Origin: null` that a `file://` page sends

---

## Verifying it works

Open the browser console on `index.html`.

| Situation | Header chip | Console |
|---|---|---|
| Tables not deployed yet | `Local only` | `Supabase tables not found...` (once) |
| Function not deployed, signed in | `Synced` then `Offline` | coach says *"The AI service is not deployed yet"* |
| Everything deployed | `Synced` | nothing |
| Signed out, no config | `Local only` | nothing |

Sign in, edit a workspace, then reload - the work is still there. Sign out,
reload - still there (nothing is deleted on logout, including
`ta_autosave::<uid>::*`).

---

## If you prefer the CLI

```bash
npm i -g supabase
supabase login
supabase link --project-ref sprwgppmyifpjykfaasq
supabase db push
supabase secrets set GEMINI_API_KEY=<your-key>
supabase functions deploy gemini --no-verify-jwt
```

`--no-verify-jwt` matches the dashboard toggle in Step 3.

---

## Troubleshooting

**CORS error / "Failed to fetch" from `file://`** - the function is not
handling `OPTIONS`. Confirm the file in Step 3 is deployed and that the
function is named exactly `gemini`.

**`401 Sign in to use the coach`** - your session expired. The chip in the
header says `Sign in`; click it.

**`The AI service is not deployed yet`** - Step 3 is incomplete.

**`GEMINI_API_KEY is not set`** - Step 3, item 2.

**Tables exist but nothing syncs** - check you are actually signed in (the
header shows your avatar rather than the **Sign in** button), and that the
`auth.users` row matches the `user_id` you are querying with.

**Account Settings says your changes were not saved** - `profiles` is missing.
Re-run Step 2, second file. Until then your name and description stay on this
device only.

**Profile picture does not upload** - the `avatars` bucket is missing. Re-run
Step 2, second file. The picture still saves, as a downscaled inline copy.
