// POST /moment-cleanup — removes uploads that never finished (still 'uploading' after a day),
// so they stop holding wall slots. Called once an hour by pg_cron (see PLAN-moment.md);
// deployed with verify_jwt = false and guarded by the CRON_SECRET header instead.

import { admin } from "../_shared/auth.ts";
import { fromDb, HttpError, json, serve } from "../_shared/http.ts";
import { removePhotos } from "../_shared/r2.ts";

serve(async (req) => {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret || req.headers.get("x-cron-secret") !== secret) throw new HttpError(401, "unauthorized");

  const cutoff = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await admin
    .from("photos")
    .select("id")
    .eq("status", "uploading")
    .lt("created_at", cutoff)
    .limit(200);
  if (error) throw fromDb(error);

  const ids = (data ?? []).map((p) => p.id as string);
  await removePhotos(ids);
  if (ids.length) {
    const deleted = await admin.from("photos").delete().in("id", ids);
    if (deleted.error) throw fromDb(deleted.error);
  }
  return json({ removed: ids.length });
});
