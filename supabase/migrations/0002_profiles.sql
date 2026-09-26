-- TeachAssist - Account Settings persistence
--
--   Display name + description  ->  public.profiles
--   Profile picture             ->  storage bucket "avatars"
--
-- Apply with the Supabase CLI from the repo root:
--
--   supabase db push
--
-- or paste this whole file into the dashboard:
--   SQL Editor -> New query -> paste -> Run
--
-- Read is deliberately open to any signed-in user: that is what makes
-- "Shared by <name>" and the sender's avatar work in Shared with Me.
-- Write is restricted to your own row, so nobody can edit anyone else's
-- name, description or picture.

create table if not exists public.profiles (
    user_id      uuid        primary key references auth.users (id) on delete cascade,
    display_name text        not null default '',
    bio          text        not null default '',
    avatar_url   text        not null default '',
    updated_at   timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "read profiles" on public.profiles;
create policy "read profiles"
    on public.profiles
    for select
    to authenticated
    using (true);

drop policy if exists "write own profile" on public.profiles;
create policy "write own profile"
    on public.profiles
    for all
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);

-- Signed-out visitors read and write nothing; the header falls back to the
-- blank avatar template and localStorage.
revoke all on public.profiles from anon;
grant select, insert, update, delete on public.profiles to authenticated;

-- ---------- Profile pictures ----------
-- Public bucket so the picture renders anywhere without a token. Folder names
-- are <user_id>/avatar-<timestamp>.jpg, so the first folder is what ties an
-- object to its owner in the policies below.
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

drop policy if exists "avatars are publicly readable" on storage.objects;
create policy "avatars are publicly readable"
    on storage.objects
    for select
    to public
    using (bucket_id = 'avatars');

drop policy if exists "users upload their own avatar" on storage.objects;
create policy "users upload their own avatar"
    on storage.objects
    for insert
    to authenticated
    with check (
        bucket_id = 'avatars'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

drop policy if exists "users replace their own avatar" on storage.objects;
create policy "users replace their own avatar"
    on storage.objects
    for update
    to authenticated
    using (
        bucket_id = 'avatars'
        and (storage.foldername(name))[1] = auth.uid()::text
    )
    with check (
        bucket_id = 'avatars'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

drop policy if exists "users delete their own avatar" on storage.objects;
create policy "users delete their own avatar"
    on storage.objects
    for delete
    to authenticated
    using (
        bucket_id = 'avatars'
        and (storage.foldername(name))[1] = auth.uid()::text
    );

grant select, insert, update, delete on storage.objects to authenticated;
