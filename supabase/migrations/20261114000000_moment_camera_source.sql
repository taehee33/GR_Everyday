-- Photos without GR shot info (film GR scans, GR DIGITAL files) can be uploaded after the
-- owner picks the camera (2026-11-14). photos.camera_source says where photos.camera came from:
--   'exif'     read from the original by the app (Ricoh maker note + GR model name)
--   'declared' picked by the owner; the (i) sheet says so
-- null when no camera is shared. Clients cannot write it: begin_upload sets it on insert, and
-- photos_camera_source flips it to 'declared' whenever the owner changes the camera later.

alter table public.photos add column camera_source text
  check (camera_source in ('exif', 'declared'));
update public.photos set camera_source = 'exif' where camera is not null;
alter table public.photos add constraint photos_camera_source_with_camera
  check ((camera is null) = (camera_source is null));

create or replace function public.photos_camera_source() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.camera is null then
    new.camera_source := null;
  elsif new.camera is distinct from old.camera then
    new.camera_source := 'declared';
  end if;
  return new;
end $$;

create trigger photos_camera_source before update of camera on public.photos
  for each row execute function public.photos_camera_source();

-- A report reason for photos that were not taken with a GR (photos only, not comments).
alter table public.reports drop constraint reports_reason_check;
alter table public.reports add constraint reports_reason_check
  check (reason in ('nudity', 'violence', 'spam', 'copyright', 'not_gr', 'other'));

create or replace function public.begin_upload(p_owner uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  prof profiles;
  wall_used int;
  per_day int := (select (value ->> 'uploads_per_day')::int from app_config where key = 'limits');
  today int;
  new_id uuid;
  cam text := nullif(btrim(p #>> '{info,camera}'), '');
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
                      display_bytes, thumb_bytes, camera, camera_source, exposure, image_control,
                      taken_at, lat, lon, place)
  values (p_owner,
          nullif(p ->> 'caption', ''),
          (p ->> 'width')::int, (p ->> 'height')::int,
          (p ->> 'thumb_width')::int, (p ->> 'thumb_height')::int,
          (p ->> 'display_bytes')::int, (p ->> 'thumb_bytes')::int,
          cam,
          case when cam is null then null
               when p #>> '{info,camera_source}' = 'declared' then 'declared'
               else 'exif' end,
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
