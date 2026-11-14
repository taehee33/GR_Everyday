-- The film loaded in a film GR (2026-11-14). Picked from a list or typed by the owner when
-- uploading a film GR scan; shown where a digital GR shows its image control. Only a
-- photo with a camera can carry a film (moment-upload also requires a film GR picked by
-- the owner).

alter table public.photos add column film text
  check (film is null or char_length(film) between 1 and 40);
alter table public.photos add constraint photos_film_with_camera
  check (film is null or camera is not null);

grant update (film) on public.photos to authenticated;

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
                      taken_at, lat, lon, place, film)
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
          nullif(btrim(p #>> '{info,place}'), ''),
          case when cam is null then null else nullif(btrim(p #>> '{info,film}'), '') end)
  returning id into new_id;

  insert into upload_log (owner, photo_id) values (p_owner, new_id);
  return new_id;
end $$;
