// POST /moment-upload — start putting one photo on the caller's Photowall.
//
// Body (sizes from MomentImage.Rendered, info from MomentShotInfo.shared):
//   { width, height, thumb_width, thumb_height, display_bytes, thumb_bytes,
//     thumb_type: "image/webp" | "image/jpeg", caption?, info: { camera?, camera_source?,
//     exposure?, image_control?, taken_at?, lat?, lon?, place?, film? } }
// camera_source: "exif" (read from a GR original) or "declared" (picked by the owner, only from
// DECLARED_CAMERAS: GRs whose files carry no GR shot info). film: only with a declared film GR
// (FILM_CAMERAS), 1–40 characters.
// Reply: { id, display: { url, headers }, thumb: { url, headers }, expires_in }
// The app PUTs both files, then calls moment-publish. Limits are checked in begin_upload.

import { admin, requireUser } from "../_shared/auth.ts";
import { body, fromDb, HttpError, json, serve } from "../_shared/http.ts";
import { keys, presignPut } from "../_shared/r2.ts";

const MAX_EDGE = 3072;
const MIN_EDGE = 1080;
const MAX_THUMB_EDGE = 800;
const MAX_DISPLAY_BYTES = 8_000_000;
const MAX_THUMB_BYTES = 300_000;
const THUMB_TYPES = ["image/webp", "image/jpeg"];
const EXPIRES_IN = 600;
/** Keep in sync with MomentShotInfo.declarableCameras in the app. */
const DECLARED_CAMERAS = [
  "GR1", "GR10", "GR1s", "GR21", "GR1v",
  "GR DIGITAL", "GR DIGITAL II", "GR DIGITAL III", "GR DIGITAL IV",
  "GR", "GR II", "GR III", "GR III HDF", "GR IIIx", "GR IIIx HDF", "GR IV", "GR IV HDF",
];
/** Keep in sync with MomentShotInfo.filmCameras in the app. */
const FILM_CAMERAS = ["GR1", "GR10", "GR1s", "GR21", "GR1v"];

function int(v: unknown, name: string, min: number, max: number): number {
  if (typeof v !== "number" || !Number.isInteger(v) || v < min || v > max) {
    throw new HttpError(400, "bad_request", `${name} must be an integer in ${min}...${max}`);
  }
  return v;
}

/** Small JSON object or nothing; keeps clients from parking large blobs in the DB. */
function smallObject(v: unknown, name: string, maxBytes: number): Record<string, unknown> | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "object" || Array.isArray(v) || JSON.stringify(v).length > maxBytes) {
    throw new HttpError(400, "bad_request", `${name} must be an object under ${maxBytes} bytes`);
  }
  return v as Record<string, unknown>;
}

function optionalNumber(v: unknown, name: string, min: number, max: number): number | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "number" || !Number.isFinite(v) || v < min || v > max) {
    throw new HttpError(400, "bad_request", `${name} out of range`);
  }
  return v;
}

function shotInfo(v: unknown) {
  const info = smallObject(v, "info", 8_000) ?? {};
  const camera = info.camera;
  if (camera !== undefined && camera !== null && (typeof camera !== "string" || camera.length > 60)) {
    throw new HttpError(400, "bad_request", "info.camera");
  }
  const source = info.camera_source ?? "exif";
  if (source !== "exif" && source !== "declared") throw new HttpError(400, "bad_request", "info.camera_source");
  if (typeof camera === "string") {
    if (source === "declared" && !DECLARED_CAMERAS.includes(camera)) {
      throw new HttpError(400, "bad_request", "info.camera is not a camera that can be picked");
    }
    if (source === "exif" && !camera.toUpperCase().includes("GR")) {
      throw new HttpError(400, "bad_request", "info.camera is not a GR");
    }
  }
  const takenAt = info.taken_at;
  if (takenAt !== undefined && takenAt !== null &&
      (typeof takenAt !== "string" || Number.isNaN(Date.parse(takenAt)))) {
    throw new HttpError(400, "bad_request", "info.taken_at");
  }
  const place = info.place;
  if (place !== undefined && place !== null &&
      (typeof place !== "string" || place.trim().length === 0 || place.trim().length > 40)) {
    throw new HttpError(400, "bad_request", "info.place must be 1–40 characters");
  }
  const film = info.film;
  if (film !== undefined && film !== null) {
    if (typeof film !== "string" || film.trim().length === 0 || film.trim().length > 40) {
      throw new HttpError(400, "bad_request", "info.film must be 1–40 characters");
    }
    if (source !== "declared" || typeof camera !== "string" || !FILM_CAMERAS.includes(camera)) {
      throw new HttpError(400, "bad_request", "info.film goes only with a film GR");
    }
  }
  const lat = optionalNumber(info.lat, "info.lat", -90, 90);
  const lon = optionalNumber(info.lon, "info.lon", -180, 180);
  if ((lat === null) !== (lon === null)) throw new HttpError(400, "bad_request", "info.lat and info.lon go together");
  return {
    camera: camera ?? null,
    camera_source: typeof camera === "string" ? source : null,
    exposure: smallObject(info.exposure, "info.exposure", 1_000),
    image_control: smallObject(info.image_control, "info.image_control", 4_000),
    taken_at: takenAt ?? null,
    lat,
    lon,
    place: typeof place === "string" ? place.trim() : null,
    film: typeof film === "string" ? film.trim() : null,
  };
}

serve(async (req) => {
  const owner = await requireUser(req);
  const b = await body(req);

  const width = int(b.width, "width", 1, MAX_EDGE);
  const height = int(b.height, "height", 1, MAX_EDGE);
  if (Math.max(width, height) < MIN_EDGE) throw new HttpError(400, "too_small", String(MIN_EDGE));
  const thumbType = b.thumb_type;
  if (typeof thumbType !== "string" || !THUMB_TYPES.includes(thumbType)) {
    throw new HttpError(400, "bad_request", "thumb_type");
  }
  const caption = b.caption;
  if (caption !== undefined && caption !== null && (typeof caption !== "string" || caption.length > 500)) {
    throw new HttpError(400, "bad_request", "caption");
  }

  const payload = {
    width,
    height,
    thumb_width: int(b.thumb_width, "thumb_width", 1, MAX_THUMB_EDGE),
    thumb_height: int(b.thumb_height, "thumb_height", 1, MAX_THUMB_EDGE),
    display_bytes: int(b.display_bytes, "display_bytes", 1, MAX_DISPLAY_BYTES),
    thumb_bytes: int(b.thumb_bytes, "thumb_bytes", 1, MAX_THUMB_BYTES),
    caption: caption ?? null,
    info: shotInfo(b.info),
  };

  const { data: id, error } = await admin.rpc("begin_upload", { p_owner: owner, p: payload });
  if (error) throw fromDb(error);

  const k = keys(id as string);
  const [display, thumb] = await Promise.all([
    presignPut(k.display, "image/jpeg", EXPIRES_IN),
    presignPut(k.thumb, thumbType, EXPIRES_IN),
  ]);
  return json({ id, display, thumb, expires_in: EXPIRES_IN });
});
