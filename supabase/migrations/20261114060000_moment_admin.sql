-- 어드민 페이지 (2026-11-14): 설정 › 계정 › 어드민, for the people in `admins`.
-- Design: PLAN-admin.md
--
-- What an admin can do from the app, all through the functions below (each checks is_admin()):
--   · 어드민 명단: list, add by 사용자명, remove (never the last one).
--   · 사용자: this month's shares used and the monthly limit (per person, or the default),
--     change either; the wall's photo limit (profiles.wall_limit).
--   · 기본값: shares per month and the wall limit new accounts start with.
--   · 당선작: add/edit/delete a month, see its ranking, set or clear the winner at any time
--     (unlike announce_contest, which waits for the month to end), for testing.
--
-- The first admin is the account with 사용자명 soongone. More: 어드민 › 어드민 명단, or
--   insert into admins (user_id) select id from profiles where handle = '…';

-- Admins ------------------------------------------------------------------------------------

create table public.admins (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  added_by   uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

-- No policies: read and written only through the functions below.
alter table public.admins enable row level security;
grant all on public.admins to service_role;

insert into public.admins (user_id) select id from public.profiles where handle = 'soongone';

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

create function public.require_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
end $$;

create function public.admin_list()
returns table (user_id uuid, handle text, display_name text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin();
  return query
    select a.user_id, p.handle, p.display_name, a.created_at
    from admins a join profiles p on p.id = a.user_id
    order by a.created_at;
end $$;

create function public.admin_add(p_handle text) returns void
language plpgsql security definer set search_path = public as $$
declare
  target uuid;
begin
  perform public.require_admin();
  select id into target from profiles where handle = lower(trim(leading '@' from trim(p_handle)));
  if target is null then raise exception 'not_found'; end if;
  insert into admins (user_id, added_by) values (target, auth.uid()) on conflict do nothing;
end $$;

create function public.admin_remove(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_admin();
  perform 1 from admins for update;
  if (select count(*) from admins) <= 1 and exists (select 1 from admins where user_id = p_user) then
    raise exception 'last_admin';
  end if;
  delete from admins where user_id = p_user;
end $$;

-- Monthly shares per person -----------------------------------------------------------------

-- null = app_config.limits.shares_per_month.
alter table public.profiles add column shares_per_month int check (shares_per_month >= 0);

-- How many shares a person gets this month.
create function public.share_limit(p_owner uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select shares_per_month from profiles where id = p_owner),
                  (select (value ->> 'shares_per_month')::int from app_config where key = 'limits'), 5);
$$;

create function public.shares_used(p_owner uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from shares
  where owner = p_owner
    and created_at >= date_trunc('month', now() at time zone 'UTC') at time zone 'UTC';
$$;

revoke execute on function public.share_limit(uuid), public.shares_used(uuid) from public, anon, authenticated;

create or replace function public.share_photo_for(p_owner uuid, p_photo uuid) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  used int;
  limit_n int := public.share_limit(p_owner);
  now_ts timestamptz := now();
begin
  if p_owner is null then raise exception 'signed_out'; end if;
  perform 1 from profiles where id = p_owner for update;
  perform 1 from photos
    where id = p_photo and owner = p_owner and status = 'published' and shared_at is null
    for update;
  if not found then raise exception 'not_shareable'; end if;
  used := public.shares_used(p_owner);
  if used >= limit_n then raise exception 'monthly_share_limit' using detail = limit_n::text; end if;
  insert into shares (owner, photo_id, created_at) values (p_owner, p_photo, now_ts);
  update photos set shared_at = now_ts where id = p_photo;
  return now_ts;
end $$;

create or replace function public.shares_left() returns int
language sql stable security definer set search_path = public as $$
  select greatest(public.share_limit(auth.uid()) - public.shares_used(auth.uid()), 0)
$$;

-- New accounts start with app_config.limits.wall_photos_free photos on the wall.
create or replace function public.create_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, wall_limit) values (new.id, coalesce(
    (select (value ->> 'wall_photos_free')::int from public.app_config where key = 'limits'), 15));
  return new;
end $$;

-- Users -------------------------------------------------------------------------------------

-- Accounts matching `p_search` (사용자명 or 표시 이름; empty = everyone), newest first.
create function public.admin_users(p_search text default null, p_limit int default 50)
returns table (id uuid, handle text, display_name text, created_at timestamptz,
               wall_used int, wall_limit int,
               shares_used int, shares_limit int, shares_override int, is_admin boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  q text := nullif(trim(leading '@' from trim(coalesce(p_search, ''))), '');
begin
  perform public.require_admin();
  return query
    select p.id, p.handle, p.display_name, p.created_at,
           (select count(*)::int from photos ph where ph.owner = p.id),
           p.wall_limit,
           public.shares_used(p.id), public.share_limit(p.id), p.shares_per_month,
           exists (select 1 from admins a where a.user_id = p.id)
    from profiles p
    where q is null or p.handle ilike '%' || q || '%' or p.display_name ilike '%' || q || '%'
    order by p.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200);
end $$;

create function public.admin_set_wall_limit(p_user uuid, p_limit int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_admin();
  if p_limit is null or p_limit < 0 or p_limit > 10000 then raise exception 'invalid_value'; end if;
  update profiles set wall_limit = p_limit where id = p_user;
  if not found then raise exception 'not_found'; end if;
end $$;

-- null = back to the default.
create function public.admin_set_share_limit(p_user uuid, p_limit int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_admin();
  if p_limit < 0 or p_limit > 10000 then raise exception 'invalid_value'; end if;
  update profiles set shares_per_month = p_limit where id = p_user;
  if not found then raise exception 'not_found'; end if;
end $$;

-- Sets how many shares count as used this month: removes the newest share records, or adds
-- records with no photo. Photos already on 순간들 stay there either way.
create function public.admin_set_shares_used(p_user uuid, p_used int) returns void
language plpgsql security definer set search_path = public as $$
declare
  used int;
  month_start timestamptz := date_trunc('month', now() at time zone 'UTC') at time zone 'UTC';
begin
  perform public.require_admin();
  if p_used is null or p_used < 0 or p_used > 1000 then raise exception 'invalid_value'; end if;
  perform 1 from profiles where id = p_user for update;
  if not found then raise exception 'not_found'; end if;
  used := public.shares_used(p_user);
  if p_used < used then
    delete from shares where id in (
      select s.id from shares s where s.owner = p_user and s.created_at >= month_start
      order by s.created_at desc limit used - p_used);
  elsif p_used > used then
    insert into shares (owner, photo_id, created_at)
      select p_user, null, now() from generate_series(1, p_used - used);
  end if;
end $$;

-- Defaults ----------------------------------------------------------------------------------

create function public.admin_defaults()
returns table (shares_per_month int, wall_photos_free int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin();
  return query
    select coalesce((value ->> 'shares_per_month')::int, 5), coalesce((value ->> 'wall_photos_free')::int, 15)
    from app_config where key = 'limits';
end $$;

-- Shares per month: everyone without their own limit, from now. Wall: new accounts only.
create function public.admin_set_defaults(p_shares_per_month int, p_wall_photos_free int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_admin();
  if p_shares_per_month is null or p_shares_per_month < 0 or p_shares_per_month > 10000
     or p_wall_photos_free is null or p_wall_photos_free < 0 or p_wall_photos_free > 10000 then
    raise exception 'invalid_value';
  end if;
  update app_config
     set value = value || jsonb_build_object('shares_per_month', p_shares_per_month,
                                             'wall_photos_free', p_wall_photos_free)
   where key = 'limits';
end $$;

-- 당선작 ------------------------------------------------------------------------------------

create function public.admin_save_contest(p_month date, p_title text, p_theme text, p_intro text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_admin();
  insert into contests (month, title, theme, intro)
    values (date_trunc('month', p_month)::date, p_title, nullif(trim(p_theme), ''), nullif(trim(p_intro), ''))
  on conflict (month) do update
    set title = excluded.title, theme = excluded.theme, intro = excluded.intro;
end $$;

create function public.admin_delete_contest(p_month date) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_admin();
  delete from contests where month = date_trunc('month', p_month)::date;
end $$;

-- Sets the winner (any published photo, any time) or, with null, takes it back out.
create function public.admin_set_winner(p_month date, p_photo uuid, p_crop jsonb default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_admin();
  if p_photo is not null and not exists (select 1 from photos where id = p_photo and status = 'published') then
    raise exception 'not_found';
  end if;
  update contests
     set winner = p_photo,
         icon_crop = case when p_photo is null then null else p_crop end,
         announced_at = case when p_photo is null then null else coalesce(announced_at, now()) end
   where month = date_trunc('month', p_month)::date;
  if not found then raise exception 'not_found'; end if;
end $$;

create function public.admin_contest_ranking(p_month date, p_limit int default 30)
returns table (rank bigint, photo_id uuid, likes bigint, likes_now int, author text,
               caption text, shared_at timestamptz, thumb_url text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin();
  return query select * from public.contest_ranking(p_month, p_limit);
end $$;

-- Grants ------------------------------------------------------------------------------------

revoke execute on function
  public.require_admin(), public.admin_list(), public.admin_add(text), public.admin_remove(uuid),
  public.admin_users(text, int), public.admin_set_wall_limit(uuid, int),
  public.admin_set_share_limit(uuid, int), public.admin_set_shares_used(uuid, int),
  public.admin_defaults(), public.admin_set_defaults(int, int),
  public.admin_save_contest(date, text, text, text), public.admin_delete_contest(date),
  public.admin_set_winner(date, uuid, jsonb), public.admin_contest_ranking(date, int)
  from public, anon;
grant execute on function
  public.is_admin(), public.admin_list(), public.admin_add(text), public.admin_remove(uuid),
  public.admin_users(text, int), public.admin_set_wall_limit(uuid, int),
  public.admin_set_share_limit(uuid, int), public.admin_set_shares_used(uuid, int),
  public.admin_defaults(), public.admin_set_defaults(int, int),
  public.admin_save_contest(date, text, text, text), public.admin_delete_contest(date),
  public.admin_set_winner(date, uuid, jsonb), public.admin_contest_ranking(date, int)
  to authenticated;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;
