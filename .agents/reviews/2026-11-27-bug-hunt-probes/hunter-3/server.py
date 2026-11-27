# Loopback-only fake Blob service (path-style: /<account>/<container>/<blob>), with fault modes.
import sys, os, json, urllib.parse, email.utils, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT = sys.argv[1]; PORT = int(sys.argv[2]); OTHER = int(sys.argv[3])
STATE = {"mode": "", "log": [], "count": {}}
def esc(s): return s.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;")
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def send(self, status, headers=None, body=b"", declared=None, close=False):
        self.send_response(status)
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(body) if declared is None else declared))
        if close: self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(body)
        self.wfile.flush()
        if close: self.close_connection = True
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path); q = dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True))
        if u.path == "/__mode":
            STATE["mode"] = q.get("m", ""); STATE["log"] = []; STATE["count"] = {}
            return self.send(200, {}, b"ok")
        if u.path == "/__log":
            return self.send(200, {}, json.dumps(STATE["log"]).encode())
        path = urllib.parse.unquote(u.path)
        rec = {"port": PORT, "method": self.command, "path": path, "query": q, "headers": {k.lower(): v for k, v in self.headers.items()}}
        STATE["log"].append(rec)
        mode = STATE["mode"]
        n = STATE["count"][path + "?" + u.query] = STATE["count"].get(path + "?" + u.query, 0) + 1
        parts = path.lstrip("/").split("/", 2)
        blob = parts[2] if len(parts) > 2 else ""
        is_list = q.get("comp") == "list"
        is_commit = blob.endswith(".json"); is_data = blob.endswith(".parquet")
        if mode == "redirect_list" and is_list and PORT != OTHER:
            return self.send(307, {"Location": "http://127.0.0.1:%d%s" % (OTHER, self.path)})
        if mode == "redirect_data" and is_data and PORT != OTHER:
            return self.send(302, {"Location": "http://127.0.0.1:%d%s" % (OTHER, self.path)})
        if mode == "redirect_data_localhost" and is_data and PORT != OTHER:
            return self.send(302, {"Location": "http://localhost:%d%s" % (OTHER, self.path)})
        if mode == "503_once" and n == 1:
            return self.send(503, {"x-ms-error-code": "ServerBusy"}, b"busy")
        if mode == "drop_once" and n == 1 and is_data:
            self.close_connection = True; self.connection.close(); return
        if mode == "drop_data" and is_data:
            self.close_connection = True; self.connection.close(); return
        if is_list:
            prefix = q.get("prefix", ""); files = []
            for d, _, fs in os.walk(ROOT):
                for f in fs:
                    rel = os.path.relpath(os.path.join(d, f), ROOT)
                    if rel.startswith(prefix) and "/" not in rel[len(prefix):]: files.append(rel)
            files.sort()
            items = "".join("<Blob><Name>%s</Name><Properties><Last-Modified>%s</Last-Modified><Content-Length>%d</Content-Length></Properties><Metadata /></Blob>" % (esc(f), email.utils.formatdate(os.path.getmtime(os.path.join(ROOT, f)), usegmt=True), os.path.getsize(os.path.join(ROOT, f))) for f in files)
            body = ('<?xml version="1.0" encoding="utf-8"?><EnumerationResults><Blobs>%s</Blobs><NextMarker /></EnumerationResults>' % items).encode()
            if mode == "short_list": return self.send(200, {}, body[:len(body)//2], declared=len(body), close=True)
            return self.send(200, {"Content-Type": "application/xml"}, body)
        f = os.path.join(ROOT, blob)
        if not blob or not os.path.isfile(f): return self.send(404, {"x-ms-error-code": "BlobNotFound"})
        data = open(f, "rb").read()
        h = {"Last-Modified": email.utils.formatdate(os.path.getmtime(f), usegmt=True)}
        if mode == "short_commit" and is_commit and blob.endswith("1.json"):
            cut = data.rfind(b"\n", 0, len(data) - 1) + 1
            return self.send(200, h, data[:cut], declared=len(data), close=True)
        if mode == "short_commit_nolen" and is_commit and blob.endswith("1.json"):
            cut = data.rfind(b"\n", 0, len(data) - 1) + 1
            self.send_response(200); self.send_header("Connection", "close"); self.end_headers(); self.wfile.write(data[:cut]); self.close_connection = True; return
        if mode == "short_commit_chunked" and is_commit and blob.endswith("1.json"):
            cut = data.rfind(b"\n", 0, len(data) - 1) + 1
            self.send_response(200); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            self.wfile.write(b"%x\r\n%s\r\n" % (cut, data[:cut])); self.wfile.flush(); self.close_connection = True; self.connection.close(); return
        if mode == "short_data" and is_data:
            return self.send(200, h, data[:len(data)//2], declared=len(data), close=True)
        if mode == "gzip_commit" and is_commit:
            import gzip
            return self.send(200, dict(h, **{"Content-Encoding": "gzip"}), gzip.compress(data))
        rng = self.headers.get("Range")
        if rng:
            a, b = rng.replace("bytes=", "").split("-"); a = int(a); b = min(int(b), len(data) - 1)
            if mode == "range_short": return self.send(206, dict(h, **{"Content-Range": "bytes %d-%d/%d" % (a, b, len(data))}), data[a:b], declared=b - a + 1, close=True)
            return self.send(206, dict(h, **{"Content-Range": "bytes %d-%d/%d" % (a, b, len(data))}), data[a:b+1])
        return self.send(200, h, data)
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
