-- 순간들 heart color, set by an admin in 어드민 › 당선작 to match the month's winner.
-- The app reads app_config.heart_color ("#RRGGBB") at launch and whenever it comes back to
-- the front; until then it keeps the last color it saw (white the first time).

insert into public.app_config (key, value) values ('heart_color', '"#FFFFFF"')
on conflict (key) do nothing;

create or replace function public.admin_set_heart_color(p_color text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.require_admin();
  if p_color is null or p_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'invalid_value';
  end if;
  insert into app_config (key, value) values ('heart_color', to_jsonb(upper(p_color)))
  on conflict (key) do update set value = excluded.value;
end $$;

revoke execute on function public.admin_set_heart_color(text) from public, anon;
grant execute on function public.admin_set_heart_color(text) to authenticated;
