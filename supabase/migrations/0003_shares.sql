-- TeachAssist - real cross-user sharing
--
--   public.shares   one row per (owner, recipient, material scope)
--   drafts/autosave gains read policies for the recipient, plus write
--                     policies when the share says "edit"
--
-- Apply with the Supabase CLI from the repo root:
--
--   supabase db push
--
-- or paste this whole file into the dashboard:
--   SQL Editor -> New query -> paste -> Run
--
-- Sharing is a LIVE document, not a copy: the recipient opens the owner's
-- real row. "view" only reads it; "edit" writes back to it. Nothing here
-- lets a recipient take ownership - see keep_row_owner() at the bottom.

create table if not exists public.shares (
    owner_id     uuid        not null references auth.users (id) on delete cascade,
    recipient_id uuid        not null references auth.users (id) on delete cascade,
    scope        text        not null,
    permission   text        not null default 'view' check (permission in ('view', 'edit')),
    shared_at    timestamptz not null default now(),
    primary key (owner_id, recipient_id, scope),
    constraint shares_not_self check (owner_id <> recipient_id)
);

create index if not exists shares_recipient_idx on public.shares (recipient_id, shared_at desc);
create index if not exists shares_owner_idx      on public.shares (owner_id, scope);

alter table public.shares enable row level security;

-- You can always see shares you sent and shares you received; nothing else.
drop policy if exists "read shares you sent or received" on public.shares;
create policy "read shares you sent or received"
    on public.shares for select to authenticated
    using (auth.uid() in (owner_id, recipient_id));

-- You may only share material you own, and never to yourself.
drop policy if exists "send shares for your own materials" on public.shares;
create policy "send shares for your own materials"
    on public.shares for insert to authenticated
    with check (owner_id = auth.uid() and recipient_id <> auth.uid());

-- Only the sender can change a permission (view -> edit) later.
drop policy if exists "change shares you sent" on public.shares;
create policy "change shares you sent"
    on public.shares for update to authenticated
    using (owner_id = auth.uid())
    with check (owner_id = auth.uid());

-- The sender can revoke it; the recipient can drop it from their own list.
drop policy if exists "revoke shares" on public.shares;
create policy "revoke shares"
    on public.shares for delete to authenticated
    using (auth.uid() in (owner_id, recipient_id));

revoke all on public.shares from anon;
grant select, insert, update, delete on public.shares to authenticated;

-- ---------- Reading someone else's material ----------
-- The EXISTS reads public.shares under the caller's own RLS, which is what
-- we want: the shares read policy only reveals rows you sent or received.

drop policy if exists "read drafts shared with you" on public.drafts;
create policy "read drafts shared with you"
    on public.drafts for select to authenticated
    using (exists (
        select 1 from public.shares s
        where s.owner_id    = drafts.user_id
          and s.recipient_id = auth.uid()
          and s.scope        = drafts.scope
    ));

drop policy if exists "read autosave shared with you" on public.autosave;
create policy "read autosave shared with you"
    on public.autosave for select to authenticated
    using (exists (
        select 1 from public.shares s
        where s.owner_id    = autosave.user_id
          and s.recipient_id = auth.uid()
          and s.scope        = autosave.scope
    ));

-- ---------- Writing to someone else's material ----------
-- Only when permission = 'edit'. The WITH CHECK repeats the lookup against
-- the NEW row, so writing user_id = <me> finds no share and is rejected.

drop policy if exists "edit drafts shared with you" on public.drafts;
create policy "edit drafts shared with you"
    on public.drafts for update to authenticated
    using (exists (
        select 1 from public.shares s
        where s.owner_id    = drafts.user_id
          and s.recipient_id = auth.uid()
          and s.scope        = drafts.scope
          and s.permission   = 'edit'
    ))
    with check (exists (
        select 1 from public.shares s
        where s.owner_id    = drafts.user_id
          and s.recipient_id = auth.uid()
          and s.scope        = drafts.scope
          and s.permission   = 'edit'
    ));

-- The client saves with UPSERT, so an edit recipient also needs the insert
-- branch - it only succeeds when the share already points at them.
drop policy if exists "insert drafts shared with you" on public.drafts;
create policy "insert drafts shared with you"
    on public.drafts for insert to authenticated
    with check (exists (
        select 1 from public.shares s
        where s.owner_id    = drafts.user_id
          and s.recipient_id = auth.uid()
          and s.scope        = drafts.scope
          and s.permission   = 'edit'
    ));

drop policy if exists "edit autosave shared with you" on public.autosave;
create policy "edit autosave shared with you"
    on public.autosave for update to authenticated
    using (exists (
        select 1 from public.shares s
        where s.owner_id    = autosave.user_id
          and s.recipient_id = auth.uid()
          and s.scope        = autosave.scope
          and s.permission   = 'edit'
    ))
    with check (exists (
        select 1 from public.shares s
        where s.owner_id    = autosave.user_id
          and s.recipient_id = auth.uid()
          and s.scope        = autosave.scope
          and s.permission   = 'edit'
    ));

drop policy if exists "insert autosave shared with you" on public.autosave;
create policy "insert autosave shared with you"
    on public.autosave for insert to authenticated
    with check (exists (
        select 1 from public.shares s
        where s.owner_id    = autosave.user_id
          and s.recipient_id = auth.uid()
          and s.scope        = autosave.scope
          and s.permission   = 'edit'
    ));

-- ---------- Finding a colleague by email ----------
-- profiles deliberately holds no email address, so the picker resolves the
-- address to a user id here. Returns nothing for an unknown address.
-- SECURITY DEFINER is required to read auth.users; execute is granted to
-- authenticated only, and the value handed back is a bare uuid.

create or replace function public.find_user_by_email(p_email text)
returns table (user_id uuid)
language sql
stable
security definer
set search_path = public, pg_catalog
as $$
    select u.id
    from auth.users u
    where lower(u.email) = lower(trim(p_email))
    limit 1;
$$;

revoke all on function public.find_user_by_email(text) from public, anon;
grant execute on function public.find_user_by_email(text) to authenticated;

-- ---------- Ownership cannot move ----------
-- Policies already refuse a changed owner. This trigger makes it structural:
-- no sequence of grants, updates or future policies can reassign a row.

create or replace function public.keep_row_owner()
returns trigger
language plpgsql
as $$
begin
    new.user_id := old.user_id;
    return new;
end;
$$;

drop trigger if exists drafts_keep_owner on public.drafts;
create trigger drafts_keep_owner
    before update on public.drafts
    for each row execute function public.keep_row_owner();

drop trigger if exists autosave_keep_owner on public.autosave;
create trigger autosave_keep_owner
    before update on public.autosave
    for each row execute function public.keep_row_owner();
