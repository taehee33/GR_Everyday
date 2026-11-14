-- 탐색 지역, finer and on a map (2026-11-14).
--   district  under the region: 시·군·구 in Korea ("성동구", "수원시"), the city abroad
--             ("시부야구"). Written by the app with region, from the shared location.
--   explore_photos  + p_district, and a box (p_min_lat … p_max_lon) for "the photos on the
--             map as it is now" and "near me".
--   explore_map  where the photos are, for the map: one point per ~1 km cell (coordinates
--             rounded to 0.01°), with a count and the newest photo for its thumbnail. The map
--             never shows an exact spot.

alter table public.photos add column district text
  check (district is null or char_length(district) between 1 and 30);
alter table public.photos add constraint photos_district_with_location
  check (district is null or lat is not null);
grant update (district) on public.photos to authenticated;

create index photos_explore_area on public.photos (lat, lon)
  where status = 'published' and shared_at is not null and lat is not null;

drop function public.explore_photos(text, text, text, text, text, int, int, text);

create function public.explore_photos(
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
  where p.status = 'published' and p.shared_at is not null
    and (p_camera is null or p.camera = p_camera)
    and (p_kind is null or (p_kind = 'film') = public.is_film_gr(p.camera))
    and (p_look is null or p.look = p_look)
    and (p_region is null or p.region = p_region)
    and (p_district is null or p.district = p_district)
    and (p_min_lat is null or p.lat >= p_min_lat)
    and (p_max_lat is null or p.lat <= p_max_lat)
    and (p_min_lon is null or p.lon >= p_min_lon)
    and (p_max_lon is null or p.lon <= p_max_lon)
    and (coalesce(p_period, 'all') = 'all' or p.shared_at >= now() - case p_period
           when 'week' then interval '7 days'
           when 'month' then interval '30 days'
           when 'year' then interval '365 days'
           else interval '100 years' end)
  order by
    case when p_sort = 'likes' then p.moment_like_count end desc nulls last,
    case when p_sort = 'recommended' then
      (p.moment_like_count + 1)::float8
        / power(greatest(extract(epoch from now() - p.shared_at), 0) / 3600 + 2, 1.5)
    end desc nulls last,
    p.shared_at desc, p.id
  offset greatest(coalesce(p_offset, 0), 0)
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

-- The map's points: [{lat, lon, count, photo}], cells of 0.01°, with the camera/look filters.
create or replace function public.explore_map(
  p_camera text default null,
  p_look text default null,
  p_kind text default null
) returns jsonb
language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('lat', lat, 'lon', lon, 'count', n, 'photo', photo)), '[]')
  from (
    select round(p.lat::numeric, 2)::float8 lat, round(p.lon::numeric, 2)::float8 lon, count(*)::int n,
           (array_agg(p.id order by p.shared_at desc))[1] photo
    from photos p
    where p.status = 'published' and p.shared_at is not null and p.lat is not null
      and (p_camera is null or p.camera = p_camera)
      and (p_kind is null or (p_kind = 'film') = public.is_film_gr(p.camera))
      and (p_look is null or p.look = p_look)
    group by 1, 2
    limit 5000
  ) cells;
$$;

-- Facets gain districts: [{value, region, count}].
create or replace function public.explore_facets() returns jsonb
language sql stable security invoker set search_path = public as $$
  with shared as (
    select camera, look, film, region, district from photos where status = 'published' and shared_at is not null
  ),
  counted as (
    select 'cameras' list, camera v, null::text r, count(*) n from shared where camera is not null group by camera
    union all
    select 'looks', look, null, count(*) from shared where look is not null group by look
    union all
    select 'films', film, null, count(*) from shared where film is not null group by film
    union all
    select 'controls', look, null, count(*) from shared where film is null and look is not null group by look
    union all
    select 'regions', region, null, count(*) from shared where region is not null group by region
    union all
    select 'districts', district, region, count(*) from shared where district is not null and region is not null group by region, district
  )
  select jsonb_object_agg(list, items) from (
    select l.list, coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('value', v, 'region', r, 'count', n)) order by n desc, v)
                             from counted c where c.list = l.list), '[]') items
    from (values ('cameras'), ('looks'), ('films'), ('controls'), ('regions'), ('districts')) l(list)
  ) lists;
$$;

revoke execute on function public.explore_photos(text, text, text, text, text, int, int, text, text,
  double precision, double precision, double precision, double precision) from public;
grant execute on function public.explore_photos(text, text, text, text, text, int, int, text, text,
  double precision, double precision, double precision, double precision) to anon, authenticated;
revoke execute on function public.explore_map(text, text, text) from public;
grant execute on function public.explore_map(text, text, text) to anon, authenticated;
