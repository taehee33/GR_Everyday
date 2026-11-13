-- Comments on photos (in someone's 갤러리 and on 순간들), with reports like photos have.
-- Anyone who can see the photo can read its comments; signed-in users comment as themselves.
-- A comment is deleted by whoever wrote it or by the photo's owner. Comments from people I
-- blocked are not shown to me. Five reports (limits.reports_to_hide) hide a comment.

create table public.comments (
  id           bigint generated always as identity primary key,
  photo_id     uuid not null references public.photos (id) on delete cascade,
  author       uuid not null references public.profiles (id) on delete cascade,
  body         text not null check (char_length(btrim(body)) between 1 and 300),
  hidden       boolean not null default false,
  report_count int not null default 0,
  created_at   timestamptz not null default now()
);

create index comments_photo on public.comments (photo_id, created_at);
create index comments_author on public.comments (author);

alter table public.photos add column comment_count int not null default 0;

create function public.count_comment() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update photos set comment_count = comment_count + 1 where id = new.photo_id;
  else
    update photos set comment_count = greatest(comment_count - 1, 0) where id = old.photo_id;
  end if;
  return null;
end $$;

create trigger comments_count after insert or delete on public.comments
  for each row execute function public.count_comment();

create table public.comment_reports (
  reporter   uuid not null references public.profiles (id) on delete cascade,
  comment_id bigint not null references public.comments (id) on delete cascade,
  reason     text not null check (reason in ('nudity', 'violence', 'spam', 'copyright', 'other')),
  created_at timestamptz not null default now(),
  primary key (reporter, comment_id)
);

create function public.count_comment_report() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  hide_at int := coalesce((select (value ->> 'reports_to_hide')::int
                           from app_config where key = 'limits'), 5);
begin
  update comments
     set report_count = report_count + 1,
         hidden = hidden or report_count + 1 >= hide_at
   where id = new.comment_id;
  return null;
end $$;

create trigger comment_reports_count after insert on public.comment_reports
  for each row execute function public.count_comment_report();

alter table public.comments enable row level security;
alter table public.comment_reports enable row level security;

-- Readable when I can see the photo (the photos policy applies inside the subquery), the
-- writer is not someone I blocked, and it is not hidden (writers still see their own).
create policy "comments readable" on public.comments for select using (
  exists (select 1 from public.photos p where p.id = photo_id)
  and not public.blocked_by_me(author)
  and (not hidden or author = auth.uid())
);
create policy "comment as me" on public.comments for insert with check (
  author = auth.uid()
  and exists (select 1 from public.photos p where p.id = photo_id and p.status = 'published')
);
create policy "delete own or on my photo" on public.comments for delete using (
  author = auth.uid()
  or exists (select 1 from public.photos p where p.id = photo_id and p.owner = auth.uid())
);

create policy "report comment as me" on public.comment_reports for insert
  with check (reporter = auth.uid());
create policy "my comment reports" on public.comment_reports for select
  using (reporter = auth.uid());

revoke all on public.comments, public.comment_reports from anon, authenticated;
grant select on public.comments to anon, authenticated;
grant insert (photo_id, author, body), delete on public.comments to authenticated;
grant select, insert on public.comment_reports to authenticated;
grant all on public.comments, public.comment_reports to service_role;
grant usage, select on all sequences in schema public to service_role;
grant usage, select on sequence public.comments_id_seq to authenticated;
