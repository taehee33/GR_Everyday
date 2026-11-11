// moment-img: serves Moment photo files from R2, read-only, on the free workers.dev address
// (no domain needed). Paths: /p/{photo id}/display.jpg and /p/{photo id}/thumb.
// Files never change, so they are sent as immutable; the app keeps its own disk cache because
// the Cache API does not work on workers.dev. See PLAN-moment.md section 5.

export interface Env {
  BUCKET: R2Bucket;
}

const PATH = /^\/p\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/(display\.jpg|thumb)$/;

function headersFor(object: R2Object): Headers {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);
  headers.set("Cache-Control", "public, max-age=31536000, immutable");
  headers.set("Access-Control-Allow-Origin", "*");
  headers.set("X-Content-Type-Options", "nosniff");
  return headers;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    const match = PATH.exec(new URL(request.url).pathname);
    if (!match) return new Response("Not found", { status: 404 });
    const key = `p/${match[1]}/${match[2]}`;

    if (request.method === "HEAD") {
      const object = await env.BUCKET.head(key);
      if (!object) return new Response(null, { status: 404 });
      return new Response(null, { headers: headersFor(object) });
    }

    // onlyIf answers If-None-Match / If-Modified-Since: no body comes back when unchanged.
    const object = await env.BUCKET.get(key, { onlyIf: request.headers });
    if (!object) return new Response("Not found", { status: 404 });
    if (!("body" in object)) return new Response(null, { status: 304, headers: headersFor(object) });
    return new Response(object.body, { headers: headersFor(object) });
  },
} satisfies ExportedHandler<Env>;
