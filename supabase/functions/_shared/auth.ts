import { createClient } from "npm:@supabase/supabase-js@2";
import { HttpError } from "./http.ts";

// Service-role client: bypasses RLS, so every function checks ownership itself.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided to Edge Functions by Supabase.
export const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

/** The signed-in user's id, from the app's `Authorization: Bearer <access token>`. */
export async function requireUser(req: Request): Promise<string> {
  const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) throw new HttpError(401, "signed_out");
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) throw new HttpError(401, "signed_out");
  return data.user.id;
}
