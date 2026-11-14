-- 탐색 (Explore, 2026-11-14): sort and filter what is on 순간들. See PLAN-explore.md.
--   region  where it was taken, short: 시·도 in Korea ("서울", "제주"), else the country ("일본").
--           The app reverse-geocodes the shared coordinates (Korean names) and writes it; no
--           region without a location.
--   look    the image control's name, or the film in a film GR. Kept by the DB.

alter table public.photos add column region text
  check (region is null or char_length(region) between 1 and 20);
alter table public.photos add constraint photos_region_with_location
  check (region is null or lat is not null);
grant update (region) on public.photos to authenticated;

alter table public.photos add column look text
  generated always as (coalesce(film, nullif(btrim(image_control ->> 'name'), ''))) stored;

create index photos_explore_likes on public.photos (moment_like_count desc, shared_at desc)
  where status = 'published' and shared_at is not null;
create index photos_explore_camera on public.photos (camera, shared_at desc)
  where status = 'published' and shared_at is not null;
create index photos_explore_look on public.photos (look, shared_at desc)
  where status = 'published' and shared_at is not null;
create index photos_explore_region on public.photos (region, shared_at desc)
  where status = 'published' and shared_at is not null;

-- One page of 탐색. Runs as the caller, so "photos readable" (blocks) applies.
--   p_sort    'recommended' | 'likes' | 'latest'
--   p_period  'week' | 'month' | 'year' | 'all' (how far back photos were shared)
-- Recommended: (순간들 likes + 1) / (hours since shared + 2)^1.5, newer and liked photos first.
create or replace function public.explore_photos(
  p_sort text default 'recommended',
  p_period text default 'all',
  p_camera text default null,
  p_look text default null,
  p_region text default null,
  p_offset int default 0,
  p_limit int default 30
) returns setof public.photos
language sql stable security invoker set search_path = public as $$
  select p.* from photos p
  where p.status = 'published' and p.shared_at is not null
    and (p_camera is null or p.camera = p_camera)
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

-- What the filters can offer: the cameras, looks and regions on 순간들 now, with counts.
create or replace function public.explore_facets() returns jsonb
language sql stable security invoker set search_path = public as $$
  with shared as (
    select camera, look, region from photos where status = 'published' and shared_at is not null
  )
  select jsonb_build_object(
    'cameras', coalesce((select jsonb_agg(jsonb_build_object('value', v, 'count', n) order by n desc, v)
                         from (select camera v, count(*) n from shared where camera is not null group by camera) c), '[]'),
    'looks',   coalesce((select jsonb_agg(jsonb_build_object('value', v, 'count', n) order by n desc, v)
                         from (select look v, count(*) n from shared where look is not null group by look) l), '[]'),
    'regions', coalesce((select jsonb_agg(jsonb_build_object('value', v, 'count', n) order by n desc, v)
                         from (select region v, count(*) n from shared where region is not null group by region) r), '[]')
  );
$$;

revoke execute on function public.explore_photos(text, text, text, text, text, int, int) from public;
revoke execute on function public.explore_facets() from public;
grant execute on function public.explore_photos(text, text, text, text, text, int, int) to anon, authenticated;
grant execute on function public.explore_facets() to anon, authenticated;
