#!/usr/bin/env python3
"""Loopback-only, synthetic Subsonic catalog for the authenticated UI listening journey."""
import argparse
import base64
import io
import hashlib
import json
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

SONG = dict(id="fixture-track", title="Cassette Fixture Track", artist="Fixture Artist",
            artistId="fixture-artist", album="Fixture Album", albumId="fixture-album",
            duration=60, suffix="wav", contentType="audio/wav", bitRate=706,
            coverArt="fixture-cover", isDir=False, track=1, samplingRate=44100, channelCount=1)
ALBUM = dict(id="fixture-album", name="Fixture Album", artist="Fixture Artist",
             artistId="fixture-artist", coverArt="fixture-cover", songCount=1, duration=60)
ARTIST = dict(id="fixture-artist", name="Fixture Artist", albumCount=1)
buffer = io.BytesIO()
with wave.open(buffer, "wb") as audio:
    audio.setparams((1, 2, 44100, 0, "NONE", "not compressed"))
    audio.writeframes(b"\0\0" * 44100 * 60)
AUDIO = buffer.getvalue()
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aDXsAAAAASUVORK5CYII=")
lock = threading.Lock()
offline = False
media_requests = 0


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, body, content_type="application/json", status=200, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        global offline, media_requests
        path = urlparse(self.path).path
        if path not in ("/__offline", "/__reset"):
            self.send(b"{}", status=404)
            return
        with lock:
            offline = path == "/__offline"
            if not offline:
                media_requests = 0
        self.send(b"{}")

    def do_GET(self):
        global media_requests
        parsed = urlparse(self.path)
        if parsed.path == "/__state":
            with lock:
                data = dict(offline=offline, mediaRequests=media_requests)
            self.send(json.dumps(data).encode())
            return
        if not parsed.path.startswith("/rest/"):
            self.send(b"{}", status=404)  # Jellyfin discovery must not detect a second server.
            return
        with lock:
            is_offline = offline
            if parsed.path.rsplit("/", 1)[-1].removesuffix(".view") in ("stream", "download"):
                media_requests += 1
        if is_offline:
            self.send(b"{}", status=503)
            return
        endpoint = parsed.path.rsplit("/", 1)[-1].removesuffix(".view")
        query = parse_qs(parsed.query)
        salt = query.get("s", [""])[0]
        token = hashlib.md5(("fixture" + salt).encode()).hexdigest()
        authenticated = query.get("u") == ["fixture"] and (
            query.get("t") == [token] or query.get("p", [""])[0] in ("fixture", "enc:66697874757265"))
        if not authenticated:
            self.send(json.dumps({"subsonic-response": {"status": "failed", "version": "1.16.1",
                "error": {"code": 40, "message": "Wrong username or password"}}}).encode())
            return
        if endpoint in ("stream", "download"):
            start, end = 0, len(AUDIO) - 1
            requested = self.headers.get("Range", "")
            if requested.startswith("bytes="):
                first, last = requested[6:].split("-", 1)
                start = int(first or 0)
                end = min(end, int(last or end))
            headers = {"Accept-Ranges": "bytes"}
            if requested:
                headers["Content-Range"] = f"bytes {start}-{end}/{len(AUDIO)}"
            self.send(AUDIO[start:end + 1], "audio/wav", 206 if requested else 200, headers)
            return
        if endpoint == "getCoverArt":
            self.send(PNG, "image/png")
            return
        envelope = dict(status="ok", version="1.16.1", type="navidrome", serverVersion="fixture", openSubsonic=True)
        values = {
            "getOpenSubsonicExtensions": {"openSubsonicExtensions": []},
            "getArtists": {"artists": {"index": [{"name": "F", "artist": [ARTIST]}]}},
            "getArtist": {"artist": dict(ARTIST, album=[ALBUM])},
            "getAlbum": {"album": dict(ALBUM, song=[SONG])},
            "getSong": {"song": SONG},
            "getPlaylists": {"playlists": {"playlist": []}},
            "getStarred2": {"starred2": {}},
            "getScanStatus": {"scanStatus": {"scanning": False, "count": 1}},
            "getRandomSongs": {"randomSongs": {"song": [SONG]}},
            "getGenres": {"genres": {"genre": []}},
            "getInternetRadioStations": {"internetRadioStations": {}},
            "getLyricsBySongId": {"lyricsList": {"structuredLyrics": []}},
            "getUser": {"user": {"username": "fixture", "streamRole": True, "downloadRole": True}},
        }
        if endpoint == "search3":
            offset = int(query.get("songOffset", ["0"])[0])
            envelope["searchResult3"] = {"song": [SONG] if offset == 0 else [], "album": [], "artist": []}
        elif endpoint in ("getAlbumList", "getAlbumList2"):
            key = "albumList2" if endpoint.endswith("2") else "albumList"
            envelope[key] = {"album": [ALBUM] if int(query.get("offset", ["0"])[0]) == 0 else []}
        else:
            envelope.update(values.get(endpoint, {}))
        self.send(json.dumps({"subsonic-response": envelope}).encode())


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18765)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
