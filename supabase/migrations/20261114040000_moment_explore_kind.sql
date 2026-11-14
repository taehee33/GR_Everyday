-- 탐색: film GRs apart from digital GRs (2026-11-14).
--   p_kind    'film' | 'digital' | null: only photos from that kind of GR (photos without a
--             camera are in neither). The film GRs are MomentShotInfo.filmCameras in the app.
--   facets    films (photos.film) and controls (image control names) as separate lists, so
--             the 화상 filter can show the one that fits the camera kind. 'looks' stays for
--             app builds from before this.

create or replace function public.is_film_gr(p_camera text) returns boolean
language sql immutable set search_path = public as $$
  select p_camera in ('GR1', 'GR10', 'GR1s', 'GR21', 'GR1v');
$$;

drop function public.explore_photos(text, text, text, text, text, int, int);

create function public.explore_photos(
  p_sort text default 'recommended',
  p_period text default 'all',
  p_camera text default null,
  p_look text default null,
  p_region text default null,
  p_offset int default 0,
  p_limit int default 30,
  p_kind text default null
) returns setof public.photos
language sql stable security invoker set search_path = public as $$
  select p.* from photos p
  where p.status = 'published' and p.shared_at is not null
    and (p_camera is null or p.camera = p_camera)
    and (p_kind is null or (p_kind = 'film') = public.is_film_gr(p.camera))
    and (p_look is null or p.look = p_look)
    and (p_region is null or p.region = p_region)
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

create or replace function public.explore_facets() returns jsonb
language sql stable security invoker set search_path = public as $$
  with shared as (
    select camera, look, film, region from photos where status = 'published' and shared_at is not null
  ),
  counted as (
    select 'cameras' list, camera v, count(*) n from shared where camera is not null group by camera
    union all
    select 'looks', look, count(*) from shared where look is not null group by look
    union all
    select 'films', film, count(*) from shared where film is not null group by film
    union all
    select 'controls', look, count(*) from shared where film is null and look is not null group by look
    union all
    select 'regions', region, count(*) from shared where region is not null group by region
  )
  select jsonb_build_object(
    'cameras',  coalesce((select jsonb_agg(jsonb_build_object('value', v, 'count', n) order by n desc, v) from counted where list = 'cameras'), '[]'),
    'looks',    coalesce((select jsonb_agg(jsonb_build_object('value', v, 'count', n) order by n desc, v) from counted where list = 'looks'), '[]'),
    'films',    coalesce((select jsonb_agg(jsonb_build_object('value', v, 'count', n) order by n desc, v) from counted where list = 'films'), '[]'),
    'controls', coalesce((select jsonb_agg(jsonb_build_object('value', v, 'count', n) order by n desc, v) from counted where list = 'controls'), '[]'),
    'regions',  coalesce((select jsonb_agg(jsonb_build_object('value', v, 'count', n) order by n desc, v) from counted where list = 'regions'), '[]')
  );
$$;

revoke execute on function public.explore_photos(text, text, text, text, text, int, int, text) from public;
grant execute on function public.explore_photos(text, text, text, text, text, int, int, text) to anon, authenticated;
