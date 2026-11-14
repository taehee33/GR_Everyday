-- 순간들 likes apart from gallery likes (2026-11-14). A like is given in one place: on the
-- photo in someone's 갤러리 ('gallery') or on 순간들 ('moment'), each with its own count.
-- Every like given so far counts as a gallery like. Taking a photo off 순간들 deletes its
-- 순간들 likes, so sharing it again starts from 0.

alter table public.likes add column place text not null default 'gallery'
  check (place in ('gallery', 'moment'));
alter table public.likes drop constraint likes_pkey;
alter table public.likes add primary key (user_id, photo_id, place);

alter table public.photos add column moment_like_count int not null default 0;

create or replace function public.count_like() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.place = 'moment' then
      update photos set moment_like_count = moment_like_count + 1 where id = new.photo_id;
    else
      update photos set like_count = like_count + 1 where id = new.photo_id;
    end if;
  else
    if old.place = 'moment' then
      update photos set moment_like_count = greatest(moment_like_count - 1, 0) where id = old.photo_id;
    else
      update photos set like_count = greatest(like_count - 1, 0) where id = old.photo_id;
    end if;
  end if;
  return null;
end $$;

-- A 순간들 like only on a photo that is on 순간들 now.
drop policy "like as me" on public.likes;
create policy "like as me" on public.likes for insert with check (
  user_id = auth.uid()
  and (place = 'gallery'
       or exists (select 1 from photos p where p.id = photo_id and p.shared_at is not null))
);

create or replace function public.unshare_photo(p_photo uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update photos set shared_at = null where id = p_photo and owner = auth.uid();
  if found then
    delete from likes where photo_id = p_photo and place = 'moment';
    update photos set moment_like_count = 0 where id = p_photo;
  end if;
end $$;
