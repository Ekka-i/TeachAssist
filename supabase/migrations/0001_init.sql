-- TeachAssist Phase 2 - persistence + row level security
--
-- Paste this whole file into the Supabase dashboard:
--   SQL Editor -> New query -> paste -> Run
--
-- Two tables, mirroring the two layers that already exist in localStorage:
--
--   ta_materials            ->  public.drafts
--   ta_autosave::<scope>    ->  public.autosave
--
-- Both are keyed (user_id, scope): one row per workspace, which is exactly
-- the upsert-per-workspace shape saveDraft() already uses. Nothing in
-- index.html changes shape - Store just mirrors what it already writes.
--
-- Until this has run, the client hits PGRST205 ("could not find the table"),
-- detects it, logs one console warning and quietly stays on localStorage.

create table if not exists public.drafts (
    user_id    uuid        not null references auth.users (id) on delete cascade,
    scope      text        not null,
    title      text        not null default '',
    type_label text        not null default '',
    -- icon / soft / solid / text / border / filter plus the original record id,
    -- so a row can be turned back into a library card on any device.
    card       jsonb       not null default '{}'::jsonb,
    meta       jsonb       not null default '[]'::jsonb,
    sections   jsonb       not null default '{}'::jsonb,
    progress   integer     not null default 0,
    updated_at timestamptz not null default now(),
    primary key (user_id, scope)
);

create table if not exists public.autosave (
    user_id    uuid        not null references auth.users (id) on delete cascade,
    scope      text        not null,
    data       jsonb       not null,
    updated_at timestamptz not null default now(),
    primary key (user_id, scope)
);

create index if not exists drafts_user_updated_idx
    on public.drafts (user_id, updated_at desc);

create index if not exists autosave_user_updated_idx
    on public.autosave (user_id, updated_at desc);

-- ---------- Row level security ----------
-- The anon key is public by design; these policies are the security
-- boundary. Without a matching row policy a caller sees nothing at all.

alter table public.drafts   enable row level security;
alter table public.autosave enable row level security;

drop policy if exists "own rows" on public.drafts;
create policy "own rows"
    on public.drafts
    for all
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

drop policy if exists "own rows" on public.autosave;
create policy "own rows"
    on public.autosave
    for all
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- Signed-out visitors get read/write on nothing - they fall back to
-- localStorage, which is why the app still works before you sign in.
revoke all on public.drafts   from anon;
revoke all on public.autosave from anon;

grant select, insert, update, delete on public.drafts   to authenticated;
grant select, insert, update, delete on public.autosave to authenticated;
