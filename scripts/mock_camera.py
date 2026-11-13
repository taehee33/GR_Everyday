"""Fake RICOH GR HTTP API for developing GR Everyday without a camera.

    python3 scripts/mock_camera.py            # serves http://127.0.0.1:8765
    GRLINK_CAMERA_URL=http://127.0.0.1:8765 "build/GR Everyday.app/Contents/MacOS/GR Everyday"

MOCK_FAIL=R0001002.JPG,R0001005.JPG makes those files fail when saved: the first one listed
drops the connection halfway, the rest answer 500 (to try the app's failure UI).

Sample photos are rendered from macOS desktop pictures with `sips`.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PORT = 8765
SOURCES = sorted(Path("/System/Library/Desktop Pictures").glob("*.heic"))[:12]
# Any short system movie stands in for a GR clip.
MOVIE = next(iter(sorted(Path("/System/Library/CoreServices").glob("*.app/Contents/Resources/*.mov"))), None)

PROPS = {
    "errCode": 200, "errMsg": "OK", "model": "RICOH GR IV (mock)", "firmwareVersion": "1.04",
    "battery": 78, "batteryUsed": "battery", "ssid": os.environ.get("MOCK_SSID", "GR_MOCK01"),
    "storages": [{"name": "in", "impossible": False, "remain": 3298, "numFiles": 11}],
    "effect": "off",
    "effectList": ["off", "col_vivid", "col_custom1", "efc_monochrome", "efc_softMonochrome",
                   "efc_hardMonochrome", "efc_highContrast", "efc_posiFilm", "efc_bleachBypass",
                   "efc_retro", "efc_HDRTone", "efc_negaFilm", "efc_cinemaYellow"],
    "exposureMode": "P", "exposureModeList": ["P", "Av", "Tv", "M"],
    "tv": "1.250", "tvList": ["1.1000", "1.500", "1.250", "1.125", "1.60", "1.30"],
    "av": "2.8", "avList": ["2.8", "4.0", "5.6", "8.0", "11", "16"],
    "sv": "auto", "svList": ["auto", "100", "200", "400", "800", "1600", "3200"],
    "xv": "0.0", "xvList": ["-1.0", "-0.7", "-0.3", "0.0", "0.3", "0.7", "1.0"],
    "WBMode": "auto", "WBModeList": ["auto", "multiwb", "daylight", "shade", "cloud", "tungsten"],
    "meteringMode": "multi", "meteringModeList": ["multi", "center", "spot", "highlight"],
    "stillFormat": "jpeg", "stillFormatList": ["jpeg", "dng", "rawdng"],
}

FAIL = [n for n in os.environ.get("MOCK_FAIL", "").split(",") if n]

work = Path(tempfile.mkdtemp(prefix="grmock-"))
files = []  # (dir, name)
lock = threading.Lock()


def render(src: Path, out: Path, width: int, portrait: bool = False) -> None:
    # 3:2 landscape pixels, like the camera's files. A portrait shot is framed 2:3 and then
    # stored turned on its side (EXIF orientation 6), so its pixels are landscape too.
    h, w = (width, width * 2 // 3) if portrait else (width * 2 // 3, width)
    subprocess.run(["sips", "-s", "format", "jpeg", "-z", str(h), str(w), str(src), "--out", str(out)],
                   check=True, capture_output=True)
    if portrait:
        subprocess.run(["sips", "-r", "-90", str(out)], check=True, capture_output=True)


infos = {}  # name -> (datetime, orientation)


def add_photo(src: Path) -> None:
    n = 1000 + len(files)
    name = f"R000{n}.JPG"
    # Every fourth shot is "portrait": stored sideways with EXIF orientation 6, like the camera.
    portrait = len(files) % 4 == 1
    for size, width in (("full", 3000), ("xs", 1920), ("view", 720), ("thumb", 160)):
        render(src, work / f"{name}.{size}", width, portrait)
    day = 29 + min(len(files) // 6, 2)
    infos[name] = (f"2026-10-{day:02d}T1{len(files) % 10}:2{len(files) % 6}:00", 6 if portrait else 1)
    files.append(("100RICOH", name))
    if n % 3 == 0:  # some RAW companions
        shutil.copy(work / f"{name}.full", work / f"R000{n}.DNG.full")
        for size in ("xs", "view", "thumb"):
            shutil.copy(work / f"{name}.{size}", work / f"R000{n}.DNG.{size}")
        files.append(("100RICOH", f"R000{n}.DNG"))
        infos[f"R000{n}.DNG"] = infos[name]


def add_movie() -> None:
    if MOVIE is None:
        return
    name = f"R000{1000 + len(files)}.MOV"
    shutil.copy(MOVIE, work / f"{name}.full")
    render(SOURCES[0], work / f"{name}.thumb", 160)
    infos[name] = ("2026-10-31T18:00:00", 1)
    files.append(("100RICOH", name))


class Handler(BaseHTTPRequestHandler):
    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def form(self):
        length = int(self.headers.get("Content-Length") or 0)
        return {k: v[0] for k, v in parse_qs(self.rfile.read(length).decode()).items()}

    def do_GET(self):
        url = urlparse(self.path)
        parts = url.path.strip("/").split("/")
        if url.path == "/v1/ping":
            return self.send_json({"errCode": 200, "errMsg": "OK", "datetime": time.strftime("%Y-%m-%dT%H:%M:%S")})
        if url.path == "/v1/props":
            return self.send_json(PROPS)
        if url.path == "/v1/photos":
            dirs = {}
            for d, n in files:
                dirs.setdefault(d, []).append(n)
            return self.send_json({"errCode": 200, "errMsg": "OK",
                                   "dirs": [{"name": d, "files": f} for d, f in dirs.items()]})
        if len(parts) == 5 and parts[:2] == ["v1", "photos"] and parts[4] == "info":
            dt, orientation = infos.get(parts[3], ("2026-10-31T12:00:00", 1))
            return self.send_json({"errCode": 200, "errMsg": "OK", "cameraModel": "RICOH GR IV (mock)",
                                   "dir": parts[2], "file": parts[3], "orientation": orientation,
                                   "datetime": dt, "av": "2.8", "tv": "1/250", "sv": "200", "xv": "0.0"})
        if len(parts) == 4 and parts[:2] == ["v1", "photos"]:
            size = parse_qs(url.query).get("size", ["full"])[0]
            path = work / f"{parts[3]}.{size}"
            if not path.exists():
                return self.send_json({"errCode": 404, "errMsg": "not found"}, 404)
            data = path.read_bytes()
            if size == "full" and parts[3] in FAIL:
                if parts[3] != FAIL[0]:
                    return self.send_json({"errCode": 500, "errMsg": "card busy"}, 500)
                # Half the file, then the connection drops, as when the camera powers off.
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data[: len(data) // 2])
                self.wfile.flush()
                self.close_connection = True
                self.connection.shutdown(2)
                return
            movie = parts[3].upper().endswith(".MOV") and size == "full"
            rng = self.headers.get("Range")
            if movie and rng and rng.startswith("bytes="):
                # AVPlayer streams with byte ranges.
                start, _, end = rng[6:].partition("-")
                start = int(start or 0)
                end = min(int(end) if end else len(data) - 1, len(data) - 1)
                chunk = data[start:end + 1]
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            else:
                chunk = data
                self.send_response(200)
            self.send_header("Content-Type", "video/quicktime" if movie else "image/jpeg")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(chunk)))
            self.end_headers()
            time.sleep(0.05)
            try:
                return self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                return
        if url.path == "/v1/liveview":
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.end_headers()
            frames = [(work / f"{n}.view").read_bytes() for _, n in files if n.endswith(".JPG")][:4]
            i = 0
            try:
                while True:
                    frame = frames[(i // 15) % len(frames)]
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\n"
                                     + f"Content-Length: {len(frame)}\r\n\r\n".encode() + frame + b"\r\n")
                    i += 1
                    time.sleep(1 / 15)
            except (BrokenPipeError, ConnectionResetError):
                return
        self.send_json({"errCode": 404, "errMsg": "not found"}, 404)

    def do_PUT(self):
        if self.path == "/v1/params/camera":
            for k, v in self.form().items():
                if k + "List" in PROPS and v not in PROPS[k + "List"]:
                    return self.send_json({"errCode": 400, "errMsg": f"bad {k}"}, 400)
                PROPS[k] = v
            return self.send_json(PROPS)
        self.send_json({"errCode": 404, "errMsg": "not found"}, 404)

    def do_POST(self):
        if self.path == "/v1/camera/shoot":
            with lock:
                add_photo(SOURCES[len(files) % len(SOURCES)])
            return self.send_json({"errCode": 200, "errMsg": "OK", "captureId": len(files), "captured": True})
        if self.path == "/v1/lens/focus":
            self.form()
            return self.send_json({"errCode": 200, "errMsg": "OK", "focused": True})
        if self.path in ("/v1/device/wlan/finish", "/v1/device/finish"):
            return self.send_json({"errCode": 200, "errMsg": "OK"})
        self.send_json({"errCode": 404, "errMsg": "not found"}, 404)

    def log_message(self, fmt, *args):
        sys.stderr.write("mock: " + fmt % args + "\n")


if __name__ == "__main__":
    for src in SOURCES[:8]:
        add_photo(src)
    add_movie()
    print(f"mock GR on http://127.0.0.1:{PORT} with {len(files)} files ({work})", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
