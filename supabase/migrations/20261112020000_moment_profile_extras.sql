-- The rest of a 내 사진전 profile: picture, links, and the camera in use.
--   avatar_version : the profile picture is R2 key a/{id}/{version}.jpg; null = none. Written
--                    only by the profile-avatar Edge Function, so the file is checked first.
--                    A new picture gets a new version, so the immutable cache never goes stale.
--   instagram      : Instagram username, without "@" (Instagram allows a–z, 0–9, "." and "_").
--   website        : one http(s) link.
--   camera         : the camera shown on the profile ("GR IV HDF"). Null = not shown: hiding it
--                    clears it, so a hidden camera is not stored where everyone can read it.
-- bio already exists (<= 300 characters; the app keeps it to 150).

alter table public.profiles
  add column avatar_version int check (avatar_version > 0),
  add column instagram text check (instagram ~ '^[A-Za-z0-9._]{1,30}$'),
  add column website text check (char_length(website) <= 200 and website ~* '^https?://[^\s]+$'),
  add column camera text check (char_length(camera) between 1 and 40);

grant update (instagram, website, camera) on public.profiles to authenticated;
