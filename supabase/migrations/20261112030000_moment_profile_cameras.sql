-- The cameras in use become a list (a profile may show several, e.g. GR IV HDF and GR IIIx).
-- profiles.camera (one name) is copied into profiles.cameras and dropped. Null = none shown;
-- hiding them clears the list, so hidden cameras are not stored where everyone can read them.

alter table public.profiles
  add column cameras text[] check (
    cardinality(cameras) between 1 and 5
    and array_position(cameras, '') is null
    and char_length(array_to_string(cameras, '')) <= 200
  );

update public.profiles set cameras = array[camera] where camera is not null;

alter table public.profiles drop column camera;

grant update (cameras) on public.profiles to authenticated;
