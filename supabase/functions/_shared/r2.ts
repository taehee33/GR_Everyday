import { AwsClient } from "npm:aws4fetch@1.0.20";

// Cloudflare R2 through its S3-compatible API. Secrets (supabase secrets set ...):
// R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and optionally R2_BUCKET.
// The app never holds these; it only gets short-lived presigned upload URLs.

const accountId = Deno.env.get("R2_ACCOUNT_ID") ?? "";
const bucket = Deno.env.get("R2_BUCKET") ?? "moments";
const base = `https://${accountId}.r2.cloudflarestorage.com/${bucket}`;

const client = new AwsClient({
  accessKeyId: Deno.env.get("R2_ACCESS_KEY_ID") ?? "",
  secretAccessKey: Deno.env.get("R2_SECRET_ACCESS_KEY") ?? "",
  service: "s3",
  region: "auto",
});

/** Files never change once uploaded, so every cache may keep them for good. */
export const CACHE_CONTROL = "public, max-age=31536000, immutable";

/** Object keys for a photo. The Worker serves the same paths. */
export function keys(photoId: string) {
  return { display: `p/${photoId}/display.jpg`, thumb: `p/${photoId}/thumb` };
}

export interface PresignedPut {
  url: string;
  /** Headers the app must send with the PUT, exactly as given (they are signed). */
  headers: Record<string, string>;
}

/** A URL the app can PUT one file to for `expiresIn` seconds. */
export async function presignPut(key: string, contentType: string, expiresIn = 600): Promise<PresignedPut> {
  const url = new URL(`${base}/${key}`);
  url.searchParams.set("X-Amz-Expires", String(expiresIn));
  const headers = { "Content-Type": contentType, "Cache-Control": CACHE_CONTROL };
  const signed = await client.sign(new Request(url, { method: "PUT", headers }), {
    aws: { signQuery: true },
  });
  return { url: signed.url, headers };
}

export interface ObjectInfo {
  size: number;
  contentType: string | null;
}

/** Size and type of a stored object, or null when it is not there. */
export async function head(key: string): Promise<ObjectInfo | null> {
  const res = await client.fetch(`${base}/${key}`, { method: "HEAD" });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`R2 HEAD ${key}: ${res.status}`);
  return {
    size: Number(res.headers.get("Content-Length") ?? "-1"),
    contentType: res.headers.get("Content-Type"),
  };
}

/** Deletes an object; a missing one counts as deleted. */
export async function remove(key: string): Promise<void> {
  const res = await client.fetch(`${base}/${key}`, { method: "DELETE" });
  if (!res.ok && res.status !== 404) throw new Error(`R2 DELETE ${key}: ${res.status}`);
}

/** Deletes both files of each photo. */
export async function removePhotos(photoIds: string[]): Promise<void> {
  for (const id of photoIds) {
    const k = keys(id);
    await Promise.all([remove(k.display), remove(k.thumb)]);
  }
}
