-- Moment uploads: the steps the Edge Functions run with the service role. Each check and the
-- row it guards happen in one transaction with the owner's profile row locked, so two
-- uploads (or shares) at once cannot both slip under a limit. Design: PLAN-moment.md

-- Every upload ever started, kept after deletes so a daily cap cannot be dodged by deleting
-- and re-uploading. Only read when app_config limits.uploads_per_day is a number.
create table public.upload_log (
  id         bigint generated always as identity primary key,
  owner      uuid not null references public.profiles (id) on delete cascade,
  photo_id   uuid,
  created_at timestamptz not null default now()
);

create index upload_log_owner on public.upload_log (owner, created_at desc);
alter table public.upload_log enable row level security;   -- no policies: service role only
revoke all on public.upload_log from anon, authenticated;

-- Errors carry a stable code in MESSAGE and the limit in DETAIL; the functions map them to
-- the app's MomentError.

-- Starts an upload: checks handle, wall limit and (when set) the daily cap, then inserts the
-- photo as 'uploading'. Returns the new photo id; the Edge Function then hands out upload URLs.
create function public.begin_upload(p_owner uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  prof profiles;
  wall_used int;
  per_day int := (select (value ->> 'uploads_per_day')::int from app_config where key = 'limits');
  today int;
  new_id uuid;
begin
  select * into prof from profiles where id = p_owner for update;
  if not found then raise exception 'signed_out'; end if;
  if prof.handle is null then raise exception 'needs_handle'; end if;

  select count(*) into wall_used from photos where owner = p_owner;
  if wall_used >= prof.wall_limit then
    raise exception 'wall_full' using detail = prof.wall_limit::text;
  end if;

  if per_day is not null then
    select count(*) into today from upload_log
      where owner = p_owner and created_at >= date_trunc('day', now() at time zone 'UTC') at time zone 'UTC';
    if today >= per_day then raise exception 'daily_upload_limit' using detail = per_day::text; end if;
  end if;

  insert into photos (owner, caption, width, height, thumb_width, thumb_height,
                      display_bytes, thumb_bytes, camera, exposure, image_control,
                      taken_at, lat, lon)
  values (p_owner,
          nullif(p ->> 'caption', ''),
          (p ->> 'width')::int, (p ->> 'height')::int,
          (p ->> 'thumb_width')::int, (p ->> 'thumb_height')::int,
          (p ->> 'display_bytes')::int, (p ->> 'thumb_bytes')::int,
          p #>> '{info,camera}',
          p #> '{info,exposure}',
          p #> '{info,image_control}',
          (p #>> '{info,taken_at}')::timestamptz,
          round((p #>> '{info,lat}')::numeric, 2)::double precision,   -- never finer than ~1 km
          round((p #>> '{info,lon}')::numeric, 2)::double precision)
  returning id into new_id;

  insert into upload_log (owner, photo_id) values (p_owner, new_id);
  return new_id;
end $$;

-- Finishes an upload once both files are confirmed in R2: publishes the photo and hangs it
-- on the wall (first in the grid, next free spot in the free layout).
create function public.finish_upload(p_owner uuid, p_photo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  n int;
  first_order int;
begin
  update photos set status = 'published', published_at = now()
    where id = p_photo and owner = p_owner and status = 'uploading';
  if not found then raise exception 'not_found'; end if;

  select count(*), coalesce(min(grid_order), 0) into n, first_order
    from wall_items where owner = p_owner;
  insert into wall_items (photo_id, owner, x, y, width, grid_order)
  values (p_photo, p_owner,
          (n % 3) * 0.34, (n / 3) * 0.3,   -- three across, rows down; the owner moves them after
          0.3, first_order - 1);
end $$;

-- Shares for a given owner (the Edge Function's "share right after upload" path). The
-- signed-in path, share_photo, now calls this with auth.uid().
create function public.share_photo_for(p_owner uuid, p_photo uuid) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  used int;
  limit_n int := coalesce((select (value ->> 'shares_per_month')::int
                           from app_config where key = 'limits'), 5);
  now_ts timestamptz := now();
begin
  if p_owner is null then raise exception 'signed_out'; end if;
  perform 1 from profiles where id = p_owner for update;
  perform 1 from photos
    where id = p_photo and owner = p_owner and status = 'published' and shared_at is null
    for update;
  if not found then raise exception 'not_shareable'; end if;
  select count(*) into used from shares
    where owner = p_owner
      and created_at >= date_trunc('month', now_ts at time zone 'UTC') at time zone 'UTC';
  if used >= limit_n then raise exception 'monthly_share_limit' using detail = limit_n::text; end if;
  insert into shares (owner, photo_id, created_at) values (p_owner, p_photo, now_ts);
  update photos set shared_at = now_ts where id = p_photo;
  return now_ts;
end $$;

create or replace function public.share_photo(p_photo uuid) returns timestamptz
language sql security definer set search_path = public as $$
  select public.share_photo_for(auth.uid(), p_photo)
$$;

-- Service role only.
revoke execute on function public.begin_upload(uuid, jsonb), public.finish_upload(uuid, uuid),
  public.share_photo_for(uuid, uuid) from public, anon, authenticated;
grant execute on function public.begin_upload(uuid, jsonb), public.finish_upload(uuid, uuid),
  public.share_photo_for(uuid, uuid) to service_role;
grant all on public.upload_log to service_role;
