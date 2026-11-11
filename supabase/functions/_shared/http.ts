// Small HTTP helpers shared by the Moment Edge Functions.

export class HttpError extends Error {
  constructor(public status: number, public code: string, public detail?: string) {
    super(code);
  }
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Serves a POST-only function, turning HttpError into `{ error, detail }` JSON. */
export function serve(handler: (req: Request) => Promise<Response>): void {
  Deno.serve(async (req) => {
    if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    try {
      return await handler(req);
    } catch (e) {
      if (e instanceof HttpError) return json({ error: e.code, detail: e.detail }, e.status);
      console.error(e);
      return json({ error: "internal" }, 500);
    }
  });
}

export async function body(req: Request): Promise<Record<string, unknown>> {
  try {
    const value = await req.json();
    if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>;
  } catch {
    // fall through
  }
  throw new HttpError(400, "bad_request", "body must be a JSON object");
}

/** Status for each error code the SQL functions raise (see 20261110000000_moment_upload.sql). */
const dbStatus: Record<string, number> = {
  signed_out: 401,
  needs_handle: 409,
  wall_full: 409,
  daily_upload_limit: 429,
  monthly_share_limit: 429,
  not_shareable: 409,
  not_found: 404,
};

export function fromDb(error: { message: string; details?: string | null }): HttpError {
  const status = dbStatus[error.message];
  if (status) return new HttpError(status, error.message, error.details ?? undefined);
  console.error(error);
  return new HttpError(500, "internal");
}
