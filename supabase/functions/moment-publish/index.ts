// POST /moment-publish — after both PUTs, check the files and hang the photo on the wall.
//
// Body: { id, share_now?: boolean }
// Reply: { photo, share_error? }  (the photo is published even if sharing hits the monthly
// limit; share_error then says why it is not on the feed)
// When a file is missing or does not match what moment-upload was told, the upload is
// thrown away (files and row) so it does not hold a wall slot, and 422 is returned.

import { admin, requireUser } from "../_shared/auth.ts";
import { body, fromDb, HttpError, json, serve } from "../_shared/http.ts";
import { head, keys, removePhotos } from "../_shared/r2.ts";

serve(async (req) => {
  const owner = await requireUser(req);
  const b = await body(req);
  if (typeof b.id !== "string") throw new HttpError(400, "bad_request", "id");

  const { data: photo, error } = await admin
    .from("photos")
    .select("id, owner, status, display_bytes, thumb_bytes")
    .eq("id", b.id)
    .maybeSingle();
  if (error) throw fromDb(error);
  if (!photo || photo.owner !== owner || photo.status !== "uploading") throw new HttpError(404, "not_found");
  // The id as the database writes it (lowercase). Swift sends UUIDs in uppercase, and R2 keys
  // are case-sensitive, so never build keys from the request's spelling.
  const id = photo.id as string;

  const k = keys(id);
  const [display, thumb] = await Promise.all([head(k.display), head(k.thumb)]);
  const ok = display !== null && thumb !== null &&
    display.size === photo.display_bytes && display.contentType === "image/jpeg" &&
    thumb.size === photo.thumb_bytes &&
    (thumb.contentType === "image/webp" || thumb.contentType === "image/jpeg");
  if (!ok) {
    await removePhotos([id]);
    await admin.from("photos").delete().eq("id", id);
    throw new HttpError(422, "upload_mismatch");
  }

  const finished = await admin.rpc("finish_upload", { p_owner: owner, p_photo: id });
  if (finished.error) throw fromDb(finished.error);

  let shareError: string | undefined;
  if (b.share_now === true) {
    const shared = await admin.rpc("share_photo_for", { p_owner: owner, p_photo: id });
    if (shared.error) shareError = fromDb(shared.error).code;
  }

  const { data: published, error: readError } = await admin.from("photos").select("*").eq("id", id).single();
  if (readError) throw fromDb(readError);
  return json({ photo: published, share_error: shareError });
});
