-- Handles may now be 2–20 characters (was 3–20). Same rule as MomentProfile.isValidHandle.
alter table public.profiles drop constraint profiles_handle_check;
alter table public.profiles add constraint profiles_handle_check check (handle ~ '^[a-z0-9_.]{2,20}$');
