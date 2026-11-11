-- Names on 순간들 (Moments), decided 2026-11-11:
--   display name: any script (한글, emoji, spaces), 1–20 characters, unique ignoring case and
--                 Unicode composition (NFC), change any time.
--   @handle:      a–z 0–9 _ . (2–20), unique; after it has been set once it can change once
--                 every 30 days, and the old handle is held for its owner for 14 days so
--                 nobody else can take it right away.
-- Handles change only through set_handle(), so the limits cannot be skipped by the client.

alter table public.profiles add column handle_changed_at timestamptz;

-- Display name: trimmed, no control characters, 1–20 characters.
alter table public.profiles drop constraint profiles_display_name_check;
alter table public.profiles add constraint profiles_display_name_check check (
  char_length(display_name) between 1 and 20
  and display_name = btrim(display_name)
  and display_name !~ '[[:cntrl:]]'
);

create unique index profiles_display_name_unique
  on public.profiles (lower(normalize(display_name, NFC)));

-- Old handles held for their previous owner.
create table public.handle_holds (
  handle text primary key,
  owner  uuid not null references public.profiles (id) on delete cascade,
  until  timestamptz not null
);
alter table public.handle_holds enable row level security;   -- no policies: functions only
revoke all on public.handle_holds from anon, authenticated;
grant all on public.handle_holds to service_role;

-- Clients may no longer write the handle directly.
revoke update (handle) on public.profiles from authenticated;

-- Is this handle free for me? (My own current or held handle counts as free.)
create function public.handle_available(p_handle text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from profiles where handle = p_handle and id is distinct from auth.uid())
     and not exists (select 1 from handle_holds
                     where handle = p_handle and until > now() and owner is distinct from auth.uid())
$$;

-- Is this display name free for me? Same comparison as the unique index.
create function public.display_name_available(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from profiles
    where lower(normalize(display_name, NFC)) = lower(normalize(btrim(p_name), NFC))
      and id is distinct from auth.uid())
$$;

-- Sets or changes my handle. Errors (in MESSAGE, detail in DETAIL):
--   signed_out, invalid_handle, handle_taken, handle_change_too_soon (detail: when it is allowed)
create function public.set_handle(p_handle text) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  prof profiles;
  next_change timestamptz;
begin
  if me is null then raise exception 'signed_out'; end if;
  select * into prof from profiles where id = me for update;
  if not found then raise exception 'signed_out'; end if;
  if p_handle is null or p_handle !~ '^[a-z0-9_.]{2,20}$' then raise exception 'invalid_handle'; end if;
  if prof.handle = p_handle then return; end if;

  if prof.handle is not null and prof.handle_changed_at is not null then
    next_change := prof.handle_changed_at + interval '30 days';
    if next_change > now() then
      raise exception 'handle_change_too_soon' using detail = to_char(next_change at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    end if;
  end if;

  if exists (select 1 from profiles where handle = p_handle and id <> me)
     or exists (select 1 from handle_holds where handle = p_handle and until > now() and owner <> me) then
    raise exception 'handle_taken';
  end if;

  delete from handle_holds where handle = p_handle;   -- my own hold, or an expired one
  if prof.handle is not null then
    insert into handle_holds (handle, owner, until) values (prof.handle, me, now() + interval '14 days')
      on conflict (handle) do update set owner = excluded.owner, until = excluded.until;
  end if;

  -- The first handle does not start the 30-day clock; every change after it does.
  update profiles
     set handle = p_handle,
         handle_changed_at = case when prof.handle is null then null else now() end
   where id = me;
end $$;

revoke execute on function public.handle_available(text), public.display_name_available(text),
  public.set_handle(text) from public, anon;
grant execute on function public.handle_available(text), public.display_name_available(text),
  public.set_handle(text) to authenticated, service_role;
