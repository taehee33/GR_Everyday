-- The photos read policy looked into `blocks`, which anon cannot read, so signed-out
-- browsing failed with "permission denied for table blocks". The check now goes through a
-- security definer function that only answers "have I blocked this owner?".

create function public.blocked_by_me(p_owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from blocks where blocker = auth.uid() and blocked = p_owner)
$$;

revoke execute on function public.blocked_by_me(uuid) from public;
grant execute on function public.blocked_by_me(uuid) to anon, authenticated, service_role;

drop policy "photos readable" on public.photos;
create policy "photos readable" on public.photos for select using (
  owner = auth.uid()
  or (status = 'published' and not public.blocked_by_me(owner))
);
