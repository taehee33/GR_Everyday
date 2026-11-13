-- Location is shared as recorded (2026-11-13, owner's call: sharing it at all is already a
-- per-photo choice). begin_upload no longer rounds lat/lon to 0.01; photos uploaded before keep
-- their rounded values.

create or replace function public.begin_upload(p_owner uuid, p jsonb) returns uuid
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
                      taken_at, lat, lon, place)
  values (p_owner,
          nullif(p ->> 'caption', ''),
          (p ->> 'width')::int, (p ->> 'height')::int,
          (p ->> 'thumb_width')::int, (p ->> 'thumb_height')::int,
          (p ->> 'display_bytes')::int, (p ->> 'thumb_bytes')::int,
          p #>> '{info,camera}',
          p #> '{info,exposure}',
          p #> '{info,image_control}',
          (p #>> '{info,taken_at}')::timestamptz,
          (p #>> '{info,lat}')::double precision,
          (p #>> '{info,lon}')::double precision,
          nullif(btrim(p #>> '{info,place}'), ''))
  returning id into new_id;

  insert into upload_log (owner, photo_id) values (p_owner, new_id);
  return new_id;
end $$;
