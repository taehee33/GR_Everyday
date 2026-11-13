// POST /profile-avatar — set or remove the caller's profile picture (내 사진전).
//
// Body: { action: "start", bytes }   → { version, put: { url, headers }, expires_in }
//       { action: "finish", version } → { avatar_version }
//       { action: "remove" }          → { avatar_version: null }
// The app sends a square sRGB JPEG (512 px, under 300 KB): start, PUT, then finish. finish
// checks the file in R2, points profiles.avatar_version at it and deletes the old picture.

import { admin, requireUser } from "../_shared/auth.ts";
import { body, fromDb, HttpError, json, serve } from "../_shared/http.ts";
import { avatarKey, head, presignPut, remove } from "../_shared/r2.ts";

const MAX_BYTES = 300_000;
const EXPIRES_IN = 600;

async function currentVersion(owner: string): Promise<number | null> {
  const { data, error } = await admin.from("profiles").select("avatar_version").eq("id", owner).single();
  if (error) throw fromDb(error);
  return (data?.avatar_version as number | null) ?? null;
}

serve(async (req) => {
  const owner = await requireUser(req);
  const b = await body(req);

  switch (b.action) {
    case "start": {
      const bytes = b.bytes;
      if (typeof bytes !== "number" || !Number.isInteger(bytes) || bytes < 1 || bytes > MAX_BYTES) {
        throw new HttpError(400, "bad_request", `bytes must be 1...${MAX_BYTES}`);
      }
      // Versions only grow: a fresh key per picture, never overwritten.
      const version = ((await currentVersion(owner)) ?? 0) + 1;
      const put = await presignPut(avatarKey(owner, version), "image/jpeg", EXPIRES_IN);
      return json({ version, put, expires_in: EXPIRES_IN });
    }
    case "finish": {
      const version = b.version;
      if (typeof version !== "number" || !Number.isInteger(version) || version < 1) {
        throw new HttpError(400, "bad_request", "version");
      }
      const key = avatarKey(owner, version);
      const file = await head(key);
      if (!file || file.contentType !== "image/jpeg" || file.size < 1 || file.size > MAX_BYTES) {
        if (file) await remove(key);
        throw new HttpError(422, "upload_mismatch");
      }
      const old = await currentVersion(owner);
      const { error } = await admin.from("profiles").update({ avatar_version: version }).eq("id", owner);
      if (error) throw fromDb(error);
      if (old !== null && old !== version) await remove(avatarKey(owner, old));
      return json({ avatar_version: version });
    }
    case "remove": {
      const old = await currentVersion(owner);
      const { error } = await admin.from("profiles").update({ avatar_version: null }).eq("id", owner);
      if (error) throw fromDb(error);
      if (old !== null) await remove(avatarKey(owner, old));
      return json({ avatar_version: null });
    }
    default:
      throw new HttpError(400, "bad_request", "action");
  }
});
