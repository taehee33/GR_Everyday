// POST /account-delete — delete the caller's account and everything in it (App Store
// guideline 5.1.1(v)). Files first, then the auth user; the database cascades from there
// (profile, photos, wall, likes, reports, blocks, shares, upload log). The profile picture
// goes with the files.

import { admin, requireUser } from "../_shared/auth.ts";
import { fromDb, json, serve } from "../_shared/http.ts";
import { avatarKey, remove, removePhotos } from "../_shared/r2.ts";

serve(async (req) => {
  const owner = await requireUser(req);

  const { data: photos, error } = await admin.from("photos").select("id").eq("owner", owner);
  if (error) throw fromDb(error);
  await removePhotos((photos ?? []).map((p) => p.id as string));

  const { data: profile } = await admin.from("profiles").select("avatar_version").eq("id", owner).maybeSingle();
  if (profile?.avatar_version) await remove(avatarKey(owner, profile.avatar_version as number));

  const { error: deleteError } = await admin.auth.admin.deleteUser(owner);
  if (deleteError) throw deleteError;
  return json({ deleted: true });
});
