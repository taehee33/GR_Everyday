// POST /moment-delete — take one of my photos off the wall for good (files and row).
// Body: { id }. The share it used this month stays used (shares keeps its record).

import { admin, requireUser } from "../_shared/auth.ts";
import { body, fromDb, HttpError, json, serve } from "../_shared/http.ts";
import { removePhotos } from "../_shared/r2.ts";

serve(async (req) => {
  const owner = await requireUser(req);
  const b = await body(req);
  if (typeof b.id !== "string") throw new HttpError(400, "bad_request", "id");

  const { data: photo, error } = await admin.from("photos").select("id, owner").eq("id", b.id).maybeSingle();
  if (error) throw fromDb(error);
  if (!photo || photo.owner !== owner) throw new HttpError(404, "not_found");
  const id = photo.id as string;   // lowercase, as in the R2 keys (Swift sends uppercase)

  await removePhotos([id]);
  const deleted = await admin.from("photos").delete().eq("id", id);
  if (deleted.error) throw fromDb(deleted.error);
  return json({ deleted: id });
});
