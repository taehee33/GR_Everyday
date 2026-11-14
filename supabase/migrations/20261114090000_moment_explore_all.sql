-- 탐색, 2026-11-14 (3): every published photo, not only those on 순간들, and people search.
-- Design: PLAN-explore.md
--
--   explore_photos / explore_map / explore_facets  all published photos (갤러리 photos too).
--     A photo's time is when it went on 순간들, else when it was published. Its likes are its
--     순간들 likes when it is on 순간들, else its 갤러리 likes (the app shows the same number).
--   search_people  사용자명 or 표시 이름 containing the text (case-insensitive), people with a
--     사용자명 only, without the ones I blocked. Exact and prefix matches of the 사용자명 first.

create or replace function public.explore_time(p public.photos) returns timestamptz
language sql immutable set search_path = public as $$
  select coalesce(p.shared_at, p.published_at, p.created_at);
$$;

create or replace function public.explore_likes(p public.photos) returns int
language sql immutable set search_path = public as $$
  select case when p.shared_at is not null then p.moment_like_count else p.like_count end;
$$;

create or replace function public.explore_photos(
  p_sort text default 'recommended',
  p_period text default 'all',
  p_camera text default null,
  p_look text default null,
  p_region text default null,
  p_offset int default 0,
  p_limit int default 30,
  p_kind text default null,
  p_district text default null,
  p_min_lat double precision default null,
  p_max_lat double precision default null,
  p_min_lon double precision default null,
  p_max_lon double precision default null
) returns setof public.photos
language sql stable security invoker set search_path = public as $$
  select p.* from photos p
  where p.status = 'published'
    and (p_camera is null or p.camera = p_camera)
    and (p_kind is null or (p_kind = 'film') = public.is_film_gr(p.camera))
    and (p_look is null or p.look = p_look)
    and (p_region is null or p.region = p_region)
    and (p_district is null or p.district = p_district)
    and (p_min_lat is null or p.lat >= p_min_lat)
    and (p_max_lat is null or p.lat <= p_max_lat)
    and (p_min_lon is null or p.lon >= p_min_lon)
    and (p_max_lon is null or p.lon <= p_max_lon)
    and (coalesce(p_period, 'all') = 'all' or public.explore_time(p) >= now() - case p_period
           when 'week' then interval '7 days'
           when 'month' then interval '30 days'
           when 'year' then interval '365 days'
           else interval '100 years' end)
  order by
    case when p_sort = 'likes' then public.explore_likes(p) end desc nulls last,
    case when p_sort = 'recommended' then
      (public.explore_likes(p) + 1)::float8
        / power(greatest(extract(epoch from now() - public.explore_time(p)), 0) / 3600 + 2, 1.5)
    end desc nulls last,
    public.explore_time(p) desc, p.id
  offset greatest(coalesce(p_offset, 0), 0)
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

create or replace function public.explore_map(
  p_camera text default null,
  p_look text default null,
  p_kind text default null
) returns jsonb
language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('lat', lat, 'lon', lon, 'count', n, 'photo', photo)), '[]')
  from (
    select round(p.lat::numeric, 2)::float8 lat, round(p.lon::numeric, 2)::float8 lon, count(*)::int n,
           (array_agg(p.id order by public.explore_time(p) desc))[1] photo
    from photos p
    where p.status = 'published' and p.lat is not null
      and (p_camera is null or p.camera = p_camera)
      and (p_kind is null or (p_kind = 'film') = public.is_film_gr(p.camera))
      and (p_look is null or p.look = p_look)
    group by 1, 2
    limit 5000
  ) cells;
$$;

create or replace function public.explore_facets() returns jsonb
language sql stable security invoker set search_path = public as $$
  with shown as (
    select camera, look, film, region, district from photos where status = 'published'
  ),
  counted as (
    select 'cameras' list, camera v, null::text r, count(*) n from shown where camera is not null group by camera
    union all
    select 'looks', look, null, count(*) from shown where look is not null group by look
    union all
    select 'films', film, null, count(*) from shown where film is not null group by film
    union all
    select 'controls', look, null, count(*) from shown where film is null and look is not null group by look
    union all
    select 'regions', region, null, count(*) from shown where region is not null group by region
    union all
    select 'districts', district, region, count(*) from shown where district is not null and region is not null group by region, district
  )
  select jsonb_object_agg(list, items) from (
    select l.list, coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('value', v, 'region', r, 'count', n)) order by n desc, v)
                             from counted c where c.list = l.list), '[]') items
    from (values ('cameras'), ('looks'), ('films'), ('controls'), ('regions'), ('districts')) l(list)
  ) lists;
$$;

create index if not exists photos_explore_all on public.photos (owner) where status = 'published';

-- People ------------------------------------------------------------------------------------

create or replace function public.search_people(p_query text, p_limit int default 30)
returns table (id uuid, handle text, display_name text, avatar_version int, photo_count int)
language sql stable security invoker set search_path = public as $$
  with q as (
    select lower(btrim(coalesce(p_query, ''))) t,
           '%' || replace(replace(replace(lower(btrim(coalesce(p_query, ''))), '\', '\\'), '%', '\%'), '_', '\_') || '%' pattern
  )
  select pr.id, pr.handle, pr.display_name, pr.avatar_version,
         (select count(*)::int from photos p where p.owner = pr.id and p.status = 'published') photo_count
  from profiles pr, q
  where q.t <> ''
    and pr.handle is not null
    and (pr.handle like q.pattern or lower(coalesce(pr.display_name, '')) like q.pattern)
    and (auth.uid() is null or not public.blocked_by_me(pr.id))
  order by
    case when pr.handle = q.t then 0
         when starts_with(pr.handle, q.t) then 1
         when lower(coalesce(pr.display_name, '')) = q.t then 2
         else 3 end,
    photo_count desc, pr.handle
  limit least(greatest(coalesce(p_limit, 30), 1), 50);
$$;

revoke execute on function public.search_people(text, int) from public;
grant execute on function public.search_people(text, int) to anon, authenticated;
