-- 어드민 › 사용자, 2026-11-14 (2): the wall limit works like the monthly share limit.
-- Design: PLAN-admin.md
--
-- profiles.wall_limit stays the number the upload functions read. wall_limit_own says whether
-- it is this person's own number (set by an admin, later by a purchase); when it is not, it
-- follows app_config.limits.wall_photos_free, and changing that default updates everyone who
-- has no own number. Also: the default monthly shares go from 5 to 3 (user's choice).

alter table public.profiles add column wall_limit_own boolean not null default false;

update public.app_config set value = value || '{"shares_per_month": 3}' where key = 'limits';

create or replace function public.wall_default() returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select (value ->> 'wall_photos_free')::int from app_config where key = 'limits'), 15);
$$;
revoke execute on function public.wall_default() from public, anon, authenticated;

drop function public.admin_users(text, int);

create function public.admin_users(p_search text default null, p_limit int default 50)
returns table (id uuid, handle text, display_name text, created_at timestamptz,
               wall_used int, wall_limit int, wall_own boolean,
               shares_used int, shares_limit int, shares_override int, is_admin boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  q text := nullif(trim(leading '@' from trim(coalesce(p_search, ''))), '');
begin
  perform public.require_admin();
  return query
    select p.id, p.handle, p.display_name, p.created_at,
           (select count(*)::int from photos ph where ph.owner = p.id),
           p.wall_limit, p.wall_limit_own,
           public.shares_used(p.id), public.share_limit(p.id), p.shares_per_month,
           exists (select 1 from admins a where a.user_id = p.id)
    from profiles p
    where q is null or p.handle ilike '%' || q || '%' or p.display_name ilike '%' || q || '%'
    order by p.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200);
end $$;

-- null = back to the default.
create or replace function public.admin_set_wall_limit(p_user uuid, p_limit int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_admin();
  if p_limit < 0 or p_limit > 10000 then raise exception 'invalid_value'; end if;
  update profiles
     set wall_limit = coalesce(p_limit, public.wall_default()), wall_limit_own = p_limit is not null
   where id = p_user;
  if not found then raise exception 'not_found'; end if;
end $$;

-- Both defaults now apply at once to everyone without their own number.
create or replace function public.admin_set_defaults(p_shares_per_month int, p_wall_photos_free int) returns void
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
  update profiles set wall_limit = p_wall_photos_free where not wall_limit_own and wall_limit <> p_wall_photos_free;
end $$;

-- Everyone so far follows the default.
update public.profiles set wall_limit = public.wall_default() where not wall_limit_own;

revoke execute on function public.admin_users(text, int) from public, anon;
grant execute on function public.admin_users(text, int) to authenticated;
