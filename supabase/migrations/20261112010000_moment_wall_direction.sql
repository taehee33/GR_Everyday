-- Which way a gallery wall (wall_style = 'free') runs: down the screen or across it.
-- wall_items keeps x (across) and y (along) in units of the wall's short side, so the same
-- numbers draw either direction; the owner picks the direction in 내 사진전 › 편집.

alter table public.profiles
  add column wall_direction text not null default 'vertical'
    check (wall_direction in ('vertical', 'horizontal'));

grant update (wall_direction) on public.profiles to authenticated;

comment on column public.wall_items.x is 'Free layout: across the wall, in units of its short side';
comment on column public.wall_items.y is 'Free layout: along the wall, in units of its short side';
comment on column public.wall_items.width is 'Free layout: frame width, in units of the short side';
