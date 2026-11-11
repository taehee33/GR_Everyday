-- A place name the owner may type or pick on the map ("성수동", "남산타워"), shown with the
-- photo. Optional, with or without coordinates; up to 40 characters.
alter table public.photos add column place text
  check (char_length(place) between 1 and 40 and place = btrim(place));
grant update (place) on public.photos to authenticated;

-- begin_upload stores info.place too.
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
          round((p #>> '{info,lat}')::numeric, 2)::double precision,   -- never finer than ~1 km
          round((p #>> '{info,lon}')::numeric, 2)::double precision,
          nullif(btrim(p #>> '{info,place}'), ''))
  returning id into new_id;

  insert into upload_log (owner, photo_id) values (p_owner, new_id);
  return new_id;
end $$;
