-- 이달의 사진관: a monthly contest whose winner becomes one of the app's icons (2026-11-14).
-- Design: PLAN-contest.md
--
-- A month runs from the 1st to its last day in Korean time (Asia/Seoul). Every photo shared to
-- 순간들 in that month is a candidate; nothing is entered separately. When the month is over
-- the operator looks at the photos by 순간들 likes (contest_ranking) and picks the winner
-- (announce_contest), usually the first. The app then shows the winner, and the icon is
-- made from it (scripts/contest-icon.swift) and ships in the next app update.
--
-- Operator, until there is an admin page (SQL editor):
--   insert into contests (month, title, theme, intro) values ('2026-12-01', '12월 사진관', '…', '…');
--   select * from contest_ranking('2026-11-01');
--   select announce_contest('2026-11-01', '<photo id>', '{"x":0.1,"y":0,"size":0.8}');
--     (the crop is optional: the icon's square, as fractions of the photo. x and y are its
--      top-left corner over the width and height, size its side over the shorter side.
--      Left out = the middle square.)

create table public.contests (
  month        date primary key check (extract(day from month) = 1),
  title        text not null check (char_length(title) between 1 and 40),
  theme        text check (char_length(theme) <= 80),
  intro        text check (char_length(intro) <= 400),
  winner       uuid references public.photos (id) on delete set null,
  icon_crop    jsonb check (icon_crop is null or (
                 jsonb_typeof(icon_crop -> 'x') = 'number' and jsonb_typeof(icon_crop -> 'y') = 'number'
                 and jsonb_typeof(icon_crop -> 'size') = 'number'
                 and (icon_crop ->> 'size')::float8 > 0 and (icon_crop ->> 'size')::float8 <= 1)),
  announced_at timestamptz,
  created_at   timestamptz not null default now()
);

alter table public.contests enable row level security;
create policy "contests readable" on public.contests for select using (true);
grant select on public.contests to anon, authenticated;
grant all on public.contests to service_role;

-- When a month starts and ends, in Korean time.
create function public.contest_start(p_month date) returns timestamptz
language sql immutable set search_path = public as $$
  select (date_trunc('month', p_month)::timestamp) at time zone 'Asia/Seoul';
$$;

create function public.contest_end(p_month date) returns timestamptz
language sql immutable set search_path = public as $$
  select ((date_trunc('month', p_month) + interval '1 month')::timestamp) at time zone 'Asia/Seoul';
$$;

-- The month's photos by 순간들 likes. Only likes given before the month ended count, so the
-- order no longer moves once it is over. Photos taken off 순간들 or hidden are left out.
create function public.contest_ranking(p_month date, p_limit int default 30)
returns table (rank bigint, photo_id uuid, likes bigint, likes_now int, author text,
               caption text, shared_at timestamptz, thumb_url text)
language sql stable security definer set search_path = public as $$
  with base as (
    select (value #>> '{}') url from app_config where key = 'image_base_url'
  )
  select rank() over (order by count(l.user_id) desc),
         p.id,
         count(l.user_id),
         p.moment_like_count,
         coalesce(pr.display_name, pr.handle),
         p.caption,
         p.shared_at,
         (select url from base) || '/p/' || p.id || '/thumb'
  from photos p
  join profiles pr on pr.id = p.owner
  left join likes l on l.photo_id = p.id and l.place = 'moment'
                   and l.created_at < public.contest_end(p_month)
  where p.status = 'published'
    and p.shared_at >= public.contest_start(p_month)
    and p.shared_at < public.contest_end(p_month)
  group by p.id, pr.display_name, pr.handle
  order by count(l.user_id) desc, p.shared_at
  limit greatest(coalesce(p_limit, 30), 1);
$$;

-- Picks the month's winner and announces it. Can be run again to change the pick or the crop
-- (announced_at stays the first time).
create function public.announce_contest(p_month date, p_photo uuid, p_crop jsonb default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if now() < public.contest_end(p_month) then
    raise exception 'the month is not over yet';
  end if;
  if not exists (select 1 from photos where id = p_photo and status = 'published'
                 and shared_at >= public.contest_start(p_month)
                 and shared_at < public.contest_end(p_month)) then
    raise exception 'that photo was not shared to 순간들 in this month';
  end if;
  update contests
     set winner = p_photo, icon_crop = p_crop, announced_at = coalesce(announced_at, now())
   where month = date_trunc('month', p_month)::date;
  if not found then
    raise exception 'no contest for this month: insert it into contests first';
  end if;
end $$;

-- Operator only: not callable from the app.
revoke execute on function public.contest_ranking(date, int), public.announce_contest(date, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.contest_ranking(date, int), public.announce_contest(date, uuid, jsonb)
  to service_role;
