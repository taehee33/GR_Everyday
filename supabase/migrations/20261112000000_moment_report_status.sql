-- What became of a report, so the reporter can be told (설정 › 계정 › 신고 내역).
--   received  : filed, nothing decided yet
--   hidden    : enough reports came in (limits.reports_to_hide); hidden until reviewed
--   removed   : the photo is gone (taken down after review, or deleted by its owner)
--   dismissed : reviewed and found to be fine
-- A report now outlives its photo: photo_id becomes null when the photo is deleted.

alter table public.reports
  add column status text not null default 'received'
    check (status in ('received', 'hidden', 'removed', 'dismissed')),
  add column resolved_at timestamptz;

alter table public.reports alter column photo_id drop not null;
alter table public.reports drop constraint reports_photo_id_fkey;
alter table public.reports add constraint reports_photo_id_fkey
  foreign key (photo_id) references public.photos (id) on delete set null;

create or replace function public.count_report() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  hide_at int := coalesce((select (value ->> 'reports_to_hide')::int
                           from app_config where key = 'limits'), 5);
  now_hidden boolean;
begin
  update photos
     set report_count = report_count + 1,
         status = case when report_count + 1 >= hide_at and status = 'published'
                       then 'hidden'::photo_status else status end
   where id = new.photo_id
   returning status = 'hidden' into now_hidden;
  if now_hidden then
    update reports set status = 'hidden', resolved_at = now()
     where photo_id = new.photo_id and status = 'received';
  end if;
  return null;
end $$;

create function public.close_reports() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update reports set status = 'removed', resolved_at = now()
   where photo_id = old.id and status in ('received', 'hidden');
  return old;
end $$;

create trigger photos_close_reports before delete on public.photos
  for each row execute function public.close_reports();

-- Reviewing by hand (dashboard SQL), when a hidden photo turns out to be fine:
--   update photos set status = 'published', report_count = 0 where id = '<photo>';
--   update reports set status = 'dismissed', resolved_at = now() where photo_id = '<photo>';
