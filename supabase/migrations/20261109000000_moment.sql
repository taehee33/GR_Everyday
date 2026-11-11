-- Moment: each user's Photowall and the feed of photos shared to it ("Share your moment").
-- Design: PLAN-moment.md
-- Image files live in Cloudflare R2 at p/{photos.id}/display.jpg and p/{photos.id}/thumb.webp,
-- served by the moment-img Worker; the base URL comes from app_config.
-- Rows in `photos` are created, published and deleted only by Edge Functions (service role),
-- because those steps must also touch R2 and enforce the wall limit (profiles.wall_limit,
-- 15 free) plus, when set, a cap of uploads per day. Clients may edit the caption, turn off
-- shot-info sharing, and share to the feed through share_photo (5 a month).

-- App config --------------------------------------------------------------------------------

create table public.app_config (
  key   text primary key,
  value jsonb not null
);

insert into public.app_config (key, value) values
  ('image_base_url', '"https://moment-img.CHANGE-ME.workers.dev"'),
  ('limits', '{"wall_photos_free": 15, "uploads_per_day": null, "shares_per_month": 5, "reports_to_hide": 5}');
-- uploads_per_day: null = no daily cap (off for now). Set a number later to turn it on;
-- moment-upload reads it on every call, so no app update is needed.

-- Profiles ----------------------------------------------------------------------------------

create table public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  handle       text unique check (handle ~ '^[a-z0-9_.]{3,20}$'),  -- chosen before the first upload
  display_name text check (char_length(display_name) <= 40),
  bio          text check (char_length(bio) <= 300),
  wall_style   text not null default 'grid' check (wall_style in ('grid', 'free')),
  -- How many photos the wall may hold. 15 free; a purchase raises it (written by the
  -- purchase-verification function with the service role, never by the client).
  wall_limit   int  not null default 15 check (wall_limit >= 0),
  created_at   timestamptz not null default now()
);

create function public.create_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.create_profile();

-- Photos ------------------------------------------------------------------------------------

create type public.photo_status as enum ('uploading', 'published', 'hidden');

create table public.photos (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null references public.profiles (id) on delete cascade,
  status        public.photo_status not null default 'uploading',
  caption       text check (char_length(caption) <= 500),
  width         int not null check (width between 1 and 3072),
  height        int not null check (height between 1 and 3072),
  thumb_width   int not null,
  thumb_height  int not null,
  display_bytes int not null,
  thumb_bytes   int not null,
  -- Shot info the owner chose to share; null = not shared. The image files carry no EXIF.
  camera        text,
  exposure      jsonb,   -- {shutter, aperture, iso, ev, focal35, mode}
  image_control jsonb,   -- {code, name, settings: [{name, value}], hdf}
  taken_at      timestamptz,
  lat           double precision check (lat between -90 and 90),    -- rounded to 0.01 by the client
  lon           double precision check (lon between -180 and 180),
  like_count    int not null default 0,
  report_count  int not null default 0,
  created_at    timestamptz not null default now(),
  published_at  timestamptz,
  shared_at  timestamptz   -- on the feed since; null = only on the owner's wall
);

create index photos_feed on public.photos (shared_at desc)
  where status = 'published' and shared_at is not null;
create index photos_owner on public.photos (owner, created_at desc);

-- Every share ever made, kept after an unshare or delete so the monthly limit holds.
create table public.shares (
  id         bigint generated always as identity primary key,
  owner      uuid not null references public.profiles (id) on delete cascade,
  photo_id   uuid,   -- no foreign key: the photo may be deleted later
  created_at timestamptz not null default now()
);

create index shares_owner on public.shares (owner, created_at desc);

-- Share one of my published photos to the feed. Five per calendar month (UTC).
create function public.share_photo(p_photo uuid) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  used int;
  limit_n int := coalesce((select (value ->> 'shares_per_month')::int
                           from app_config where key = 'limits'), 5);
  now_ts timestamptz := now();
begin
  if me is null then raise exception 'not signed in' using errcode = '28000'; end if;
  -- One share at a time per user, so two at once cannot both pass the count.
  perform 1 from profiles where id = me for update;
  perform 1 from photos
    where id = p_photo and owner = me and status = 'published' and shared_at is null
    for update;
  if not found then raise exception 'photo not shareable' using errcode = 'P0002'; end if;
  select count(*) into used from shares
    where owner = me and created_at >= date_trunc('month', now_ts at time zone 'UTC') at time zone 'UTC';
  if used >= limit_n then raise exception 'monthly share limit reached' using errcode = 'P0001'; end if;
  insert into shares (owner, photo_id, created_at) values (me, p_photo, now_ts);
  update photos set shared_at = now_ts where id = p_photo;
  return now_ts;
end $$;

-- Take a photo off the feed; it stays on the wall and the used share is not returned.
create function public.unshare_photo(p_photo uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update photos set shared_at = null where id = p_photo and owner = auth.uid();
end $$;

-- How many shares I have left this month, for the "3/5" label.
create function public.shares_left() returns int
language sql stable security definer set search_path = public as $$
  select greatest(coalesce((select (value ->> 'shares_per_month')::int
                            from app_config where key = 'limits'), 5)
                  - (select count(*)::int from shares
                     where owner = auth.uid()
                       and created_at >= date_trunc('month', now() at time zone 'UTC') at time zone 'UTC'), 0)
$$;

revoke execute on function public.share_photo(uuid), public.unshare_photo(uuid),
  public.shares_left() from public, anon;
grant execute on function public.share_photo(uuid), public.unshare_photo(uuid),
  public.shares_left() to authenticated;

-- Photowall ---------------------------------------------------------------------------------
-- Both layouts are stored so switching wall_style never loses the other arrangement.
-- Free layout: positions are fractions of the wall's width so every screen lays it out alike.
-- Grid layout: order plus how many cells the photo spans.

create table public.wall_items (
  photo_id   uuid primary key references public.photos (id) on delete cascade,
  owner      uuid not null references public.profiles (id) on delete cascade,
  x          real not null default 0,
  y          real not null default 0,
  width      real not null default 0.3 check (width > 0 and width <= 1),
  z          int  not null default 0,
  rotation   real not null default 0,
  grid_order int  not null default 0,
  grid_span  text not null default '1x1' check (grid_span in ('1x1', '2x1', '1x2', '2x2'))
);

create index wall_items_owner on public.wall_items (owner);

-- Likes, reports, blocks --------------------------------------------------------------------

create table public.likes (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  photo_id   uuid not null references public.photos (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, photo_id)
);

create table public.reports (
  id         bigint generated always as identity primary key,
  reporter   uuid not null references public.profiles (id) on delete cascade,
  photo_id   uuid not null references public.photos (id) on delete cascade,
  reason     text not null check (reason in ('nudity', 'violence', 'spam', 'copyright', 'other')),
  note       text check (char_length(note) <= 500),
  created_at timestamptz not null default now(),
  unique (reporter, photo_id)
);

create table public.blocks (
  blocker    uuid not null references public.profiles (id) on delete cascade,
  blocked    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);

-- Counters ----------------------------------------------------------------------------------

create function public.count_like() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update photos set like_count = like_count + 1 where id = new.photo_id;
  else
    update photos set like_count = greatest(like_count - 1, 0) where id = old.photo_id;
  end if;
  return null;
end $$;

create trigger likes_count after insert or delete on public.likes
  for each row execute function public.count_like();

-- Five reports (app_config limits.reports_to_hide) hide a photo until someone reviews it.
create function public.count_report() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  hide_at int := coalesce((select (value ->> 'reports_to_hide')::int
                           from app_config where key = 'limits'), 5);
begin
  update photos
     set report_count = report_count + 1,
         status = case when report_count + 1 >= hide_at and status = 'published'
                       then 'hidden'::photo_status else status end
   where id = new.photo_id;
  return null;
end $$;

create trigger reports_count after insert on public.reports
  for each row execute function public.count_report();

-- Row level security ------------------------------------------------------------------------

alter table public.app_config  enable row level security;
alter table public.shares enable row level security;
alter table public.profiles   enable row level security;
alter table public.photos     enable row level security;
alter table public.wall_items enable row level security;
alter table public.likes      enable row level security;
alter table public.reports    enable row level security;
alter table public.blocks     enable row level security;

-- App config: anyone reads; only the dashboard (service role) writes.
create policy "config readable" on public.app_config for select using (true);
revoke insert, update, delete on public.app_config from anon, authenticated;

-- Shares: I see my own; written only by share_photo.
create policy "my shares" on public.shares for select using (owner = auth.uid());
revoke all on public.shares from anon;
revoke insert, update, delete on public.shares from authenticated;

-- Profiles: anyone reads; owners edit their own text fields and wall style.
create policy "profiles readable" on public.profiles for select using (true);
create policy "edit own profile" on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());
revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (handle, display_name, bio, wall_style) on public.profiles to authenticated;

-- Photos: published ones from people I haven't blocked, plus all of my own.
create policy "photos readable" on public.photos for select using (
  owner = auth.uid()
  or (status = 'published'
      and not exists (select 1 from public.blocks b
                      where b.blocker = auth.uid() and b.blocked = photos.owner))
);
create policy "edit own photo" on public.photos for update
  using (owner = auth.uid()) with check (owner = auth.uid());
revoke insert, update, delete on public.photos from anon, authenticated;
grant update (caption, camera, exposure, image_control, taken_at, lat, lon)
  on public.photos to authenticated;

-- Photowall: anyone reads; owners arrange their own photos.
create policy "walls readable" on public.wall_items for select using (true);
create policy "arrange own wall" on public.wall_items for all
  using (owner = auth.uid())
  with check (owner = auth.uid()
              and exists (select 1 from public.photos p
                          where p.id = photo_id and p.owner = auth.uid()));
revoke insert, update, delete on public.wall_items from anon;

-- Likes: anyone reads; signed-in users like and unlike as themselves.
create policy "likes readable" on public.likes for select using (true);
create policy "like as me" on public.likes for insert with check (user_id = auth.uid());
create policy "unlike as me" on public.likes for delete using (user_id = auth.uid());
revoke update on public.likes from anon, authenticated;
revoke insert, delete on public.likes from anon;

-- Reports: file as me, see only my own.
create policy "report as me" on public.reports for insert with check (reporter = auth.uid());
create policy "my reports" on public.reports for select using (reporter = auth.uid());
revoke all on public.reports from anon;
revoke update, delete on public.reports from authenticated;

-- Blocks: entirely private to the blocker.
create policy "my blocks" on public.blocks for all
  using (blocker = auth.uid()) with check (blocker = auth.uid());
revoke all on public.blocks from anon;

-- Grants ------------------------------------------------------------------------------------
-- The project is created with "Automatically expose new tables" off, so nothing reaches the
-- Data API unless granted here. RLS above still decides which rows each role sees.
grant usage on schema public to anon, authenticated, service_role;

grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;

grant select on public.app_config, public.profiles, public.photos, public.wall_items,
  public.likes to anon, authenticated;
grant update (handle, display_name, bio, wall_style) on public.profiles to authenticated;
grant update (caption, camera, exposure, image_control, taken_at, lat, lon)
  on public.photos to authenticated;
grant select on public.shares to authenticated;
grant insert, update, delete on public.wall_items to authenticated;
grant insert, delete on public.likes to authenticated;
grant select, insert on public.reports to authenticated;
grant select, insert, delete on public.blocks to authenticated;
